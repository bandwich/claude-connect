#!/usr/bin/env python3
"""
Test server for E2E integration tests.

Provides:
- WebSocket server that mimics the real ConnectServer's message protocol
- HTTP control interface for test harness to inject content
- Session simulation (responds to list_projects, open_session, etc.)

Usage:
    python -m server.integration_tests.test_server
"""

import asyncio
import json
import sys
import os
import time
import base64
import logging

from aiohttp import web

from server.integration_tests.test_config import (
    TEST_HOST, TEST_PORT, CONTROL_PORT, LOG_LEVEL,
    TEST_TRANSCRIPT_PATH, MOCK_TTS, TEST_AUDIO_PATH,
    CHUNK_SIZE, AUDIO_CHUNK_DELAY, cleanup_temp_dir,
)
from server.integration_tests.mock_transcript import MockTranscript, create_empty_transcript

try:
    import websockets
except ImportError:
    print("ERROR: websockets package required. Install with: pip install websockets")
    sys.exit(1)

logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class TestConnectServer:
    """Test WebSocket server with HTTP control interface.

    Mimics the real ConnectServer's WebSocket protocol so the iOS app
    can connect and behave as if talking to a real server. Tests inject
    content via HTTP endpoints; the server broadcasts it to connected clients.
    """

    def __init__(self):
        self.clients = set()
        self.transcript_path = TEST_TRANSCRIPT_PATH
        self.mock_transcript = None
        self.logs = []
        self._seq = 0

        # Mock data for session simulation
        self.mock_projects = [
            {
                "name": "e2e_test_project",
                "path": "/private/tmp/e2e_test_project",
                "folder_name": "-private-tmp-e2e-test-project",
                "session_count": 1,
            }
        ]
        self.mock_sessions = [
            {
                "id": "test-session-1",
                "title": "Test session",
                "timestamp": time.time(),
                "message_count": 2,
            }
        ]
        self.mock_directory_entries = [
            {"name": "README.md", "type": "file"},
            {"name": "src", "type": "directory"},
            {"name": "test.txt", "type": "file"},
        ]
        self.active_session_ids = []

    def _next_seq(self) -> int:
        """Get next sequence number for message ordering."""
        seq = self._seq
        self._seq += 1
        return seq

    def log(self, message):
        self.logs.append(f"{time.time()}: {message}")
        logger.info(message)

    # ------------------------------------------------------------------
    # WebSocket broadcasting
    # ------------------------------------------------------------------

    async def broadcast(self, message: dict):
        """Send a message to all connected WebSocket clients."""
        data = json.dumps(message)
        for ws in list(self.clients):
            try:
                await ws.send(data)
            except Exception as e:
                logger.error(f"Error broadcasting: {e}")

    async def broadcast_assistant_response(self, content_blocks: list):
        """Broadcast an assistant_response matching real server format.

        Real format (from ConnectServer.handle_content_response):
            {"type": "assistant_response", "content_blocks": [...],
             "timestamp": ..., "is_incremental": true,
             "session_id": "...", "seq": N}
        """
        message = {
            "type": "assistant_response",
            "content_blocks": content_blocks,
            "timestamp": time.time(),
            "is_incremental": True,
            "session_id": "",  # Empty = shown regardless of viewed session
            "seq": self._next_seq(),
        }
        await self.broadcast(message)
        self.log(f"Broadcast assistant_response: {len(content_blocks)} blocks")

    async def broadcast_user_message(self, text: str):
        """Broadcast a user_message matching real server format."""
        message = {
            "type": "user_message",
            "role": "user",
            "content": text,
            "timestamp": time.time(),
            "session_id": self.active_session_ids[0] if self.active_session_ids else "test-session-1",
            "seq": self._next_seq(),
        }
        await self.broadcast(message)

    # ------------------------------------------------------------------
    # WebSocket client handling
    # ------------------------------------------------------------------

    async def handle_client(self, websocket, path=None):
        """Handle a new WebSocket client connection."""
        client_addr = websocket.remote_address
        self.log(f"Client connected: {client_addr}")
        self.clients.add(websocket)

        try:
            # Send initial status (real server does this on connect)
            await websocket.send(json.dumps({
                "type": "status",
                "state": "idle",
                "message": "Connected",
                "timestamp": time.time(),
            }))

            # Send connection_status with active sessions
            await websocket.send(json.dumps({
                "type": "connection_status",
                "connected": True,
                "active_session_ids": self.active_session_ids,
            }))

            async for message in websocket:
                await self.handle_message(websocket, message)

        except websockets.exceptions.ConnectionClosed:
            self.log(f"Client disconnected: {client_addr}")
        except Exception as e:
            logger.error(f"Error with client {client_addr}: {e}")
        finally:
            self.clients.discard(websocket)

    async def handle_message(self, websocket, message):
        """Handle incoming WebSocket message from iOS app."""
        try:
            data = json.loads(message)
            msg_type = data.get("type")
            self.log(f"Received: {msg_type}")

            if msg_type == "list_projects":
                await websocket.send(json.dumps({
                    "type": "projects",
                    "projects": self.mock_projects,
                }))

            elif msg_type == "list_sessions":
                await websocket.send(json.dumps({
                    "type": "sessions_list",
                    "sessions": self.mock_sessions,
                    "active_session_ids": self.active_session_ids,
                }))

            elif msg_type in ("open_session", "resume_session", "view_session"):
                session_id = data.get("session_id", "test-session-1")
                if session_id not in self.active_session_ids:
                    self.active_session_ids.append(session_id)

                # Send session history (empty for test)
                await websocket.send(json.dumps({
                    "type": "session_history",
                    "messages": [],
                }))
                # Send session_resumed with success (triggers navigation to SessionView)
                response_type = "session_resumed" if msg_type == "resume_session" else "session_resumed"
                await websocket.send(json.dumps({
                    "type": response_type,
                    "success": True,
                    "session_id": session_id,
                }))
                # Send connection_status update
                await websocket.send(json.dumps({
                    "type": "connection_status",
                    "connected": True,
                    "active_session_ids": self.active_session_ids,
                }))

            elif msg_type == "new_session":
                new_id = f"test-session-{int(time.time())}"
                self.active_session_ids.append(new_id)
                await websocket.send(json.dumps({
                    "type": "session_created",
                    "success": True,
                    "session_id": new_id,
                }))
                await websocket.send(json.dumps({
                    "type": "connection_status",
                    "connected": True,
                    "active_session_ids": self.active_session_ids,
                }))

            elif msg_type == "close_session":
                await websocket.send(json.dumps({
                    "type": "session_closed",
                }))

            elif msg_type == "stop_session":
                session_id = data.get("session_id", "")
                if session_id in self.active_session_ids:
                    self.active_session_ids.remove(session_id)
                await websocket.send(json.dumps({
                    "type": "session_stopped",
                    "session_id": session_id,
                    "success": True,
                }))

            elif msg_type == "list_directory":
                await websocket.send(json.dumps({
                    "type": "directory_listing",
                    "path": data.get("path", "/"),
                    "entries": self.mock_directory_entries,
                }))

            elif msg_type == "read_file":
                await websocket.send(json.dumps({
                    "type": "file_contents",
                    "path": data.get("path", ""),
                    "contents": "mock file contents\nline 2\nline 3",
                }))

            elif msg_type == "voice_input":
                text = data.get("text", "").strip()
                self.log(f"Voice input: '{text}'")
                # Broadcast as user_message so iOS sees it
                await self.broadcast_user_message(text)

            elif msg_type == "user_input":
                text = data.get("text", "").strip()
                self.log(f"User input: '{text}'")
                await self.broadcast_user_message(text)

            elif msg_type == "set_preference":
                pass  # Acknowledge silently

            elif msg_type == "resync_request":
                await websocket.send(json.dumps({
                    "type": "resync_response",
                    "messages": [],
                }))

            elif msg_type == "usage_request":
                await websocket.send(json.dumps({
                    "type": "usage_response",
                    "session": {"percent": 10, "remaining_minutes": 50},
                    "week_all_models": {"percent": 20},
                    "week_sonnet": {"percent": 15},
                }))

            elif msg_type == "permission_response":
                self.log(f"Permission response: {data.get('decision')}")

            elif msg_type == "question_response":
                self.log(f"Question response: {data.get('answer', data.get('dismissed'))}")

            elif msg_type == "stop_audio":
                pass

            else:
                self.log(f"Unhandled message type: {msg_type}")

        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON: {e}")
        except Exception as e:
            logger.error(f"Error handling message: {e}")

    # ------------------------------------------------------------------
    # HTTP Control Interface
    # ------------------------------------------------------------------

    async def handle_inject_content_blocks(self, request):
        """Inject content blocks → broadcast as assistant_response."""
        try:
            data = await request.json()
            blocks = data.get("blocks", [])
            await self.broadcast_assistant_response(blocks)
            return web.Response(text=f"Broadcast {len(blocks)} blocks")
        except Exception as e:
            return web.Response(text=f"Error: {e}", status=500)

    async def handle_inject_response(self, request):
        """Legacy: inject plain text → broadcast as text block."""
        text = await request.text()
        await self.broadcast_assistant_response([{"type": "text", "text": text}])
        return web.Response(text="Response injected")

    async def handle_inject_permission(self, request):
        """Inject a permission_request → broadcast to iOS."""
        try:
            data = await request.json()
            message = {
                "type": "permission_request",
                "request_id": data.get("request_id", f"test-perm-{int(time.time())}"),
                "session_id": "",  # Empty = shown regardless of viewed session
                "prompt_type": data.get("prompt_type", "bash"),
                "tool_name": data.get("tool_name", "Bash"),
                "tool_input": data.get("tool_input", {}),
                "context": data.get("context"),
                "permission_suggestions": data.get("permission_suggestions"),
                "timestamp": time.time(),
            }
            await self.broadcast(message)
            self.log(f"Broadcast permission_request: {message['tool_name']}")
            return web.Response(text="Permission injected")
        except Exception as e:
            return web.Response(text=f"Error: {e}", status=500)

    async def handle_inject_question(self, request):
        """Inject a question_prompt → broadcast to iOS."""
        try:
            data = await request.json()
            # Convert plain string options to QuestionOption objects
            raw_options = data.get("options", [])
            options = []
            for opt in raw_options:
                if isinstance(opt, str):
                    options.append({"label": opt, "description": ""})
                else:
                    options.append(opt)
            message = {
                "type": "question_prompt",
                "request_id": data.get("request_id", f"test-q-{int(time.time())}"),
                "session_id": "",  # Empty = shown regardless of viewed session
                "header": data.get("header", ""),
                "question": data.get("question", ""),
                "options": options,
                "multi_select": data.get("multi_select", False),
                "question_index": 0,
                "total_questions": 1,
            }
            await self.broadcast(message)
            self.log(f"Broadcast question_prompt: {message['question'][:50]}")
            return web.Response(text="Question injected")
        except Exception as e:
            return web.Response(text=f"Error: {e}", status=500)

    async def handle_inject_activity(self, request):
        """Inject an activity_status → broadcast to iOS."""
        try:
            data = await request.json()
            message = {
                "type": "activity_status",
                "state": data.get("state", "idle"),
                "detail": data.get("detail", ""),
            }
            await self.broadcast(message)
            return web.Response(text="Activity injected")
        except Exception as e:
            return web.Response(text=f"Error: {e}", status=500)

    async def handle_inject_directory(self, request):
        """Inject a directory_listing → broadcast to iOS."""
        try:
            data = await request.json()
            message = {
                "type": "directory_listing",
                "path": data.get("path", "/"),
                "entries": data.get("entries", []),
            }
            await self.broadcast(message)
            return web.Response(text="Directory injected")
        except Exception as e:
            return web.Response(text=f"Error: {e}", status=500)

    async def handle_inject_file(self, request):
        """Inject file_contents → broadcast to iOS."""
        try:
            data = await request.json()
            message = {
                "type": "file_contents",
                "path": data.get("path", ""),
                "contents": data.get("contents", ""),
            }
            await self.broadcast(message)
            return web.Response(text="File injected")
        except Exception as e:
            return web.Response(text=f"Error: {e}", status=500)

    async def handle_inject_status(self, request):
        """Inject a status message → broadcast to iOS."""
        try:
            data = await request.json()
            message = {
                "type": "status",
                "state": data.get("state", "idle"),
                "message": data.get("message", ""),
                "timestamp": time.time(),
            }
            await self.broadcast(message)
            return web.Response(text=f"Status '{data.get('state')}' sent")
        except Exception as e:
            return web.Response(text=f"Error: {e}", status=500)

    async def handle_get_logs(self, request):
        return web.Response(text="\n".join(self.logs))

    async def handle_clear_logs(self, request):
        self.logs = []
        return web.Response(text="Logs cleared")

    async def handle_reset(self, request):
        """Reset all server state for test isolation."""
        self.logs = []
        self._seq = 0
        self.active_session_ids = []
        if self.mock_transcript:
            self.mock_transcript.clear()
        return web.Response(text="Server reset")

    async def handle_permission(self, request):
        """Handle permission requests from hooks (same endpoint as real server).

        This allows the existing injectPermissionRequest() in E2ETestBase
        to work against the test server without modification.

        Uses empty session_id so iOS shows it regardless of which session
        is being viewed (backward compatibility pass-through).
        """
        try:
            data = await request.json()
            tool_name = data.get("tool_name", "")
            prompt_type_map = {"Bash": "bash", "Write": "write", "Edit": "edit", "Task": "task"}

            message = {
                "type": "permission_request",
                "request_id": f"test-perm-{int(time.time() * 1000)}",
                "session_id": "",  # Empty = shown regardless of viewed session
                "prompt_type": prompt_type_map.get(tool_name, "bash"),
                "tool_name": tool_name,
                "tool_input": data.get("tool_input", {}),
                "context": data.get("context"),
                "permission_suggestions": data.get("permission_suggestions"),
                "timestamp": data.get("timestamp", time.time()),
            }
            await self.broadcast(message)
            self.log(f"Broadcast permission (via /permission): {tool_name}")

            return web.json_response({"behavior": "allow"})
        except Exception as e:
            return web.Response(text=f"Error: {e}", status=500)

    async def handle_health(self, request):
        return web.json_response({"status": "ok"})

    # ------------------------------------------------------------------
    # Server lifecycle
    # ------------------------------------------------------------------

    async def start_control_server(self):
        """Start HTTP control server."""
        app = web.Application()

        # Injection endpoints for tests
        app.router.add_post("/inject_content_blocks", self.handle_inject_content_blocks)
        app.router.add_post("/inject_response", self.handle_inject_response)
        app.router.add_post("/inject_permission", self.handle_inject_permission)
        app.router.add_post("/inject_question", self.handle_inject_question)
        app.router.add_post("/inject_activity", self.handle_inject_activity)
        app.router.add_post("/inject_directory", self.handle_inject_directory)
        app.router.add_post("/inject_file", self.handle_inject_file)
        app.router.add_post("/inject_status", self.handle_inject_status)

        # Compatibility with real server endpoints
        app.router.add_post("/permission", self.handle_permission)
        app.router.add_post("/reset", self.handle_reset)
        app.router.add_get("/health", self.handle_health)
        app.router.add_get("/logs", self.handle_get_logs)
        app.router.add_post("/clear_logs", self.handle_clear_logs)

        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, TEST_HOST, CONTROL_PORT)
        await site.start()
        self.log(f"Control server on http://{TEST_HOST}:{CONTROL_PORT}")

    async def start(self):
        """Start the test server."""
        # Create test transcript
        create_empty_transcript(self.transcript_path)
        self.mock_transcript = MockTranscript(self.transcript_path)
        self.log(f"Created transcript: {self.transcript_path}")

        # Start HTTP control server
        await self.start_control_server()

        # Start WebSocket server
        self.log(f"WebSocket server on ws://{TEST_HOST}:{TEST_PORT}")
        print("READY")
        sys.stdout.flush()

        async with websockets.serve(self.handle_client, TEST_HOST, TEST_PORT):
            await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(TestConnectServer().start())
    except KeyboardInterrupt:
        logger.info("Server stopped")
        cleanup_temp_dir()
