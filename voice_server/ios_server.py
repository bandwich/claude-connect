#!/usr/bin/env python3
"""
iOS Voice Mode Server
WebSocket server that bridges iOS app with Claude Code
"""

import asyncio
import websockets
import json
import sys
import os
import subprocess
import time
import glob
import base64
from typing import Optional

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from .tts_utils import generate_tts_audio, samples_to_wav_bytes
from .content_models import TextBlock, ThinkingBlock, ToolUseBlock, ContentBlock, AssistantResponse
from .session_manager import SessionManager
from .context_tracker import ContextTracker
from .usage_checker import UsageChecker
from .tmux_controller import TmuxController
from .permission_handler import PermissionHandler
from .http_server import start_http_server, set_tmux_controller, set_voice_server

# Configuration
PORT = 8765
TRANSCRIPT_DIR = os.path.expanduser("~/.claude/projects/")
PROJECTS_BASE_PATH = os.path.expanduser("~/Desktop/code")


def extract_text_for_tts(content_blocks: list[ContentBlock]) -> str:
    """Extract only text blocks for TTS (maintains current behavior)"""
    text_parts = []
    for block in content_blocks:
        if isinstance(block, TextBlock):
            text_parts.append(block.text)
    return ' '.join(text_parts).strip()


class TranscriptHandler(FileSystemEventHandler):
    """Monitors transcript file for new assistant messages

    Uses line-position tracking to stream ALL assistant content,
    regardless of whether voice input initiated the interaction.

    Only processes events from the expected session file, ignoring
    sub-agent transcripts (agent-*.jsonl) and other sessions.
    """

    def __init__(self, content_callback, audio_callback, loop, server):
        self.content_callback = content_callback  # Sends AssistantResponse
        self.audio_callback = audio_callback       # Sends text for TTS
        self.loop = loop
        self.server = server
        self.last_modified = 0
        self.processed_line_count = 0
        self.expected_session_file = None  # Only process events from this file
        self.context_tracker = ContextTracker()

    def on_modified(self, event):
        if event.is_directory or not event.src_path.endswith('.jsonl'):
            return

        # Ignore sub-agent transcripts (they have their own sessions)
        filename = os.path.basename(event.src_path)
        if filename.startswith('agent-'):
            return

        # Only process events from the expected session file
        # Use realpath to normalize paths - watchdog may report resolved paths
        # while expected_session_file uses unresolved paths (e.g., /tmp vs /private/tmp on macOS)
        if self.expected_session_file:
            if os.path.realpath(event.src_path) != os.path.realpath(self.expected_session_file):
                return

        try:
            new_blocks = self.extract_new_assistant_content(event.src_path)

            if new_blocks:
                response = AssistantResponse(
                    content_blocks=new_blocks,
                    timestamp=time.time(),
                    is_incremental=True
                )

                asyncio.run_coroutine_threadsafe(
                    self.content_callback(response),
                    self.loop
                )

                text = extract_text_for_tts(new_blocks)
                if text:
                    asyncio.run_coroutine_threadsafe(
                        self.audio_callback(text),
                        self.loop
                    )

            # Broadcast context update after processing
            if self.server.active_session_id:
                self.broadcast_context_update(event.src_path, self.server.active_session_id)
        except Exception as e:
            print(f"Error processing transcript: {e}")
            import traceback
            traceback.print_exc()

    def extract_new_assistant_content(self, filepath) -> list[ContentBlock]:
        """Extract assistant content from lines not yet processed"""
        all_blocks = []

        with open(filepath, 'r') as f:
            lines = f.readlines()

        # Reset if file was truncated/overwritten (fewer lines than we've processed)
        if len(lines) < self.processed_line_count:
            self.processed_line_count = 0

        new_lines = lines[self.processed_line_count:]

        for line in new_lines:
            try:
                entry = json.loads(line.strip())
                msg = entry.get('message', {})
                role = msg.get('role') or entry.get('role')

                if role == 'assistant':
                    content = msg.get('content', entry.get('content', ''))

                    if isinstance(content, str) and content.strip():
                        all_blocks.append(TextBlock(type="text", text=content.strip()))
                    elif isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict):
                                block_type = block.get('type')
                                try:
                                    if block_type == 'text':
                                        all_blocks.append(TextBlock(**block))
                                    elif block_type == 'thinking':
                                        all_blocks.append(ThinkingBlock(**block))
                                    elif block_type == 'tool_use':
                                        all_blocks.append(ToolUseBlock(**block))
                                except Exception:
                                    continue
            except json.JSONDecodeError:
                continue

        self.processed_line_count = len(lines)

        if all_blocks:
            print(f"[DEBUG] Extracted {len(all_blocks)} blocks from {len(new_lines)} new lines")

        return all_blocks

    def broadcast_context_update(self, filepath: str, session_id: str):
        """Calculate and broadcast context usage for the session."""
        context_data = self.context_tracker.calculate_context(filepath)
        context_data["type"] = "context_update"
        context_data["session_id"] = session_id

        asyncio.run_coroutine_threadsafe(
            self.server.broadcast_message(context_data),
            self.loop
        )

    def set_session_file(self, file_path: Optional[str]):
        """Set the expected session file and initialize line count.

        When switching sessions, we initialize the line count to the current
        number of lines in the file, so only NEW content triggers callbacks.
        """
        self.expected_session_file = file_path
        if file_path and os.path.exists(file_path):
            with open(file_path, 'r') as f:
                self.processed_line_count = sum(1 for _ in f)
            print(f"[INFO] Watching session file: {file_path} (starting at line {self.processed_line_count})")
        else:
            self.processed_line_count = 0
            print(f"[INFO] Watching session file: {file_path} (new file)")

    def reset_tracking_state(self):
        """Reset tracking state (legacy - prefer set_session_file)"""
        self.processed_line_count = 0
        self.expected_session_file = None

class VoiceServer:
    """WebSocket server for iOS voice mode"""

    def __init__(self):
        self.clients = set()
        self.transcript_path = None
        self.observer = None
        self.transcript_handler = None
        self.loop = None
        self.waiting_for_response = False  # Track if we're waiting for a response to voice input
        self.last_voice_input = None  # Track the last voice input text
        self.last_content_blocks = []  # New: store for future reference
        self.session_manager = SessionManager()
        self.tmux = TmuxController()
        set_tmux_controller(self.tmux)  # Enable HTTP endpoints to access tmux
        set_voice_server(self)  # Enable HTTP endpoints to access server state
        self.permission_handler = PermissionHandler()
        self.usage_checker = UsageChecker()
        self.projects_base_path = PROJECTS_BASE_PATH
        self.active_session_id = None  # Track which session is active in tmux
        self.active_folder_name = None  # Track which project folder is active

    def find_transcript_path(self):
        """Find the transcript file to watch.

        If E2E_TRANSCRIPT_PATH is set, use that exact path (for testing).
        Otherwise, find the most recent transcript file (normal operation).
        """
        # Check for explicit test transcript path
        explicit_path = os.environ.get('E2E_TRANSCRIPT_PATH')
        if explicit_path and os.path.exists(explicit_path):
            print(f"[E2E] Using explicit transcript path: {explicit_path}")
            return explicit_path

        # Normal operation: find most recent transcript
        pattern = os.path.join(TRANSCRIPT_DIR, "**/*.jsonl")
        files = glob.glob(pattern, recursive=True)
        if not files:
            return None
        files.sort(key=os.path.getmtime, reverse=True)
        return files[0]

    def get_session_transcript_path(self, folder_name: str, session_id: str) -> Optional[str]:
        """Get the transcript path for a specific session.

        Args:
            folder_name: The project folder name (e.g., "-Users-aaron-Desktop-max")
            session_id: The session ID (filename without .jsonl)

        Returns:
            Full path to the transcript file, or None if not found
        """
        transcript_path = os.path.join(TRANSCRIPT_DIR, folder_name, f"{session_id}.jsonl")
        if os.path.exists(transcript_path):
            return transcript_path
        return None

    def switch_watched_session(self, folder_name: str, session_id: str) -> bool:
        """Switch the file watcher to watch a different session's transcript.

        Args:
            folder_name: The project folder name
            session_id: The session ID to watch

        Returns:
            True if switch was successful, False otherwise
        """
        new_path = self.get_session_transcript_path(folder_name, session_id)
        if not new_path:
            print(f"[WARN] Transcript not found for session {session_id}")
            return False

        new_dir = os.path.dirname(new_path)
        old_dir = os.path.dirname(self.transcript_path) if self.transcript_path else None

        # Update tracking state
        self.transcript_path = new_path
        self.active_folder_name = folder_name
        self.active_session_id = session_id

        # Set expected session file (initializes line count from existing content)
        if self.transcript_handler:
            self.transcript_handler.set_session_file(new_path)

        # Only reschedule observer if directory changed
        if old_dir != new_dir and self.observer and self.transcript_handler:
            # Remove all existing watches
            self.observer.unschedule_all()
            # Add new watch for the session's directory
            self.observer.schedule(self.transcript_handler, new_dir)
            print(f"[INFO] Switched file watcher to: {new_dir}")

        print(f"[INFO] Now watching session: {session_id}")

        # Send initial context update for the session
        if self.transcript_handler and new_path:
            self.transcript_handler.broadcast_context_update(new_path, session_id)

        return True

    async def send_status(self, websocket, state, message):
        """Send status update to client"""
        await websocket.send(json.dumps({
            "type": "status",
            "state": state,
            "message": message,
            "timestamp": time.time()
        }))

    async def send_connection_status(self, websocket):
        """Send connection status to a single client"""
        response = {
            "type": "connection_status",
            "connected": self.tmux.session_exists(),
            "active_session_id": self.active_session_id
        }
        await websocket.send(json.dumps(response))

    async def broadcast_connection_status(self):
        """Broadcast connection status to all connected clients"""
        for websocket in list(self.clients):
            try:
                await self.send_connection_status(websocket)
            except Exception as e:
                print(f"Error broadcasting status: {e}")

    async def send_to_terminal(self, text: str):
        """Send text to Claude Code terminal via tmux"""
        print(f"[DEBUG] send_to_terminal: session_exists={self.tmux.session_exists()}")
        result = self.tmux.send_input(text)
        print(f"[DEBUG] send_input returned: {result}")

    async def stream_audio(self, websocket, text):
        """Generate TTS and stream audio to client"""
        try:
            print(f"[{time.strftime('%H:%M:%S')}] Generating TTS audio for text: '{text[:50]}...'")
            samples = generate_tts_audio(text, voice="af_heart")
            print(f"[{time.strftime('%H:%M:%S')}] TTS generated {len(samples)} samples")
            wav_bytes = samples_to_wav_bytes(samples)
            print(f"[{time.strftime('%H:%M:%S')}] WAV bytes: {len(wav_bytes)} bytes")

            chunk_size = 8192
            total_chunks = (len(wav_bytes) + chunk_size - 1) // chunk_size
            print(f"Streaming {total_chunks} audio chunks...")

            for i in range(0, len(wav_bytes), chunk_size):
                chunk = wav_bytes[i:i+chunk_size]
                await websocket.send(json.dumps({
                    "type": "audio_chunk",
                    "format": "wav",
                    "sample_rate": 24000,
                    "chunk_index": i // chunk_size,
                    "total_chunks": total_chunks,
                    "data": base64.b64encode(chunk).decode('utf-8')
                }))
                await asyncio.sleep(0.01)

            print(f"Finished streaming {total_chunks} chunks")

        except Exception as e:
            print(f"Error streaming audio: {e}")
            import traceback
            traceback.print_exc()

    async def handle_voice_input(self, websocket, data):
        """Handle voice input from iOS"""
        text = data.get('text', '').strip()
        print(f"[{time.strftime('%H:%M:%S')}] Voice input received: '{text}'")
        if text:
            # CRITICAL: Set state FIRST, before any async calls that might fail
            # (e.g., test WebSocket may close immediately after sending)
            # NOTE: Don't reset transcript tracking here - line-based tracking
            # should persist across voice inputs. File-change detection handles
            # resetting when switching to a different transcript file.
            self.waiting_for_response = True
            self.last_voice_input = text

            print(f"[{time.strftime('%H:%M:%S')}] Sending to terminal...")
            for client in list(self.clients):
                try:
                    await self.send_status(client, "processing", "Sending to Claude...")
                except Exception:
                    pass

            await self.send_to_terminal(text)
            print(f"[{time.strftime('%H:%M:%S')}] Sent to terminal successfully")
        else:
            print("Empty text received, ignoring")

    async def handle_content_response(self, response: AssistantResponse):
        """Send structured content to iOS clients"""
        print(f"[{time.strftime('%H:%M:%S')}] Sending structured content: {len(response.content_blocks)} blocks")

        # Serialize using Pydantic and add session tracking
        message = response.model_dump()
        message["session_id"] = self.active_session_id  # Include session for filtering

        for websocket in list(self.clients):
            try:
                await websocket.send(json.dumps(message))
                print(f"[{time.strftime('%H:%M:%S')}] Sent content to client (session: {self.active_session_id})")
            except Exception as e:
                print(f"Error sending content: {e}")

    async def handle_claude_response(self, text):
        """Handle Claude's response - generate and stream TTS audio"""
        print(f"[{time.strftime('%H:%M:%S')}] Claude response received: '{text[:100]}...'")

        # NOTE: With streaming, this is called multiple times (once per text block)
        # Don't check/reset waiting_for_response here - let reset happen on new voice input

        for websocket in list(self.clients):
            print(f"[{time.strftime('%H:%M:%S')}] Sending 'speaking' status to client")
            await self.send_status(websocket, "speaking", "Playing response")
            print(f"[{time.strftime('%H:%M:%S')}] Streaming audio to client...")
            await self.stream_audio(websocket, text)
            print(f"[{time.strftime('%H:%M:%S')}] Audio streaming complete, sending 'idle' status")
            await self.send_status(websocket, "idle", "Ready")

    async def send_idle_to_all_clients(self):
        """Send idle status to all connected clients.

        Called when content is sent but there's no TTS audio (e.g., only thinking blocks).
        This ensures the client's outputState is reset even without audio playback.
        """
        for websocket in list(self.clients):
            try:
                print(f"[{time.strftime('%H:%M:%S')}] Sending idle status (no TTS)")
                await self.send_status(websocket, "idle", "Ready")
            except Exception:
                pass  # Client may have disconnected, that's OK

    async def broadcast_message(self, message: dict):
        """Broadcast a JSON message to all connected clients."""
        message_json = json.dumps(message)
        for websocket in list(self.clients):
            try:
                await websocket.send(message_json)
            except Exception:
                pass

    async def handle_list_projects(self, websocket):
        """Handle list_projects request"""
        projects = self.session_manager.list_projects()
        response = {
            "type": "projects",
            "projects": [
                {
                    "path": p.path,
                    "name": p.name,
                    "session_count": p.session_count,
                    "folder_name": p.folder_name  # For direct lookup without re-encoding
                }
                for p in projects
            ]
        }
        await websocket.send(json.dumps(response))

    async def handle_list_sessions(self, websocket, data):
        """Handle list_sessions request"""
        folder_name = data.get("folder_name", "")
        sessions = self.session_manager.list_sessions(folder_name)
        response = {
            "type": "sessions",
            "sessions": [
                {
                    "id": s.id,
                    "title": s.title,
                    "timestamp": s.timestamp,
                    "message_count": s.message_count
                }
                for s in sessions
            ]
        }
        await websocket.send(json.dumps(response))

    async def handle_get_session(self, websocket, data):
        """Handle get_session request"""
        folder_name = data.get("folder_name", "")
        session_id = data.get("session_id", "")
        messages = self.session_manager.get_session_history(folder_name, session_id)
        response = {
            "type": "session_history",
            "messages": [
                {
                    "role": m.role,
                    "content": m.content,
                    "timestamp": m.timestamp
                }
                for m in messages
            ]
        }
        await websocket.send(json.dumps(response))

    async def handle_close_session(self, websocket):
        """Handle close_session request - kills the active tmux session"""
        success = self.tmux.kill_session()
        if success:
            self.active_session_id = None

        response = {
            "type": "session_closed",
            "success": success
        }
        await websocket.send(json.dumps(response))

        if success:
            await self.broadcast_connection_status()

    def reset_state(self):
        """Reset all server state for test isolation

        Called by /reset HTTP endpoint to ensure clean state between E2E tests.
        """
        # Kill any active tmux session
        self.tmux.kill_session()

        # Reset session tracking
        self.active_session_id = None
        self.active_folder_name = None
        self.transcript_path = None

        # Reset transcript handler
        if self.transcript_handler:
            self.transcript_handler.reset_tracking_state()
            self.transcript_handler.expected_session_file = None

        print("[RESET] Server state cleared for test isolation")

    async def handle_new_session(self, websocket, data):
        """Handle new_session request - starts claude in tmux"""
        project_path = data.get("project_path", "")
        print(f"[DEBUG] handle_new_session: project_path={project_path}")
        success = self.tmux.start_session(working_dir=project_path if project_path else None)
        print(f"[DEBUG] start_session returned: {success}, session_exists: {self.tmux.session_exists()}")

        if success:
            self.active_session_id = None  # New session has no ID yet
            await asyncio.sleep(2.0)  # Wait for Claude to initialize

            # Find and watch the new session's transcript
            if project_path:
                folder_name = self.session_manager.encode_path_to_folder(project_path)
                print(f"[DEBUG] Encoded folder name: {folder_name}")
                session_id = self.session_manager.find_newest_session(folder_name)
                if session_id:
                    print(f"[DEBUG] Found new session: {session_id}")
                    self.active_session_id = session_id
                    self.switch_watched_session(folder_name, session_id)

        response = {
            "type": "session_created",
            "success": success
        }
        await websocket.send(json.dumps(response))

        if success:
            await self.broadcast_connection_status()

    async def handle_resume_session(self, websocket, data):
        """Handle resume_session request - runs 'claude --resume <id>' in tmux"""
        session_id = data.get("session_id", "")
        folder_name = data.get("folder_name", "")
        success = False

        if session_id:
            # Get the actual cwd from the session file
            working_dir = None
            if folder_name and session_id:
                working_dir = self.session_manager.get_session_cwd(folder_name, session_id)
                print(f"[DEBUG] handle_resume_session: get_session_cwd -> {working_dir}")

            success = self.tmux.start_session(working_dir=working_dir, resume_id=session_id)
            print(f"[DEBUG] start_session(resume_id={session_id}) returned: {success}, session_exists: {self.tmux.session_exists()}")

            if success:
                self.active_session_id = session_id
                await asyncio.sleep(2.0)  # Wait for Claude to initialize
                if folder_name:
                    self.switch_watched_session(folder_name, session_id)
            else:
                print(f"[ERROR] Failed to start tmux session for resume_id={session_id}")

        response = {
            "type": "session_resumed",
            "success": success,
            "session_id": session_id
        }
        await websocket.send(json.dumps(response))

        if success:
            await self.broadcast_connection_status()

    async def handle_list_directory(self, websocket, data):
        """Handle list_directory request - returns files and folders in a directory"""
        path = data.get("path", "")

        if not path or not os.path.isdir(path):
            response = {
                "type": "directory_listing",
                "path": path,
                "entries": [],
                "error": "invalid_path"
            }
            await websocket.send(json.dumps(response))
            return

        try:
            entries = []
            for name in os.listdir(path):
                full_path = os.path.join(path, name)
                entry_type = "directory" if os.path.isdir(full_path) else "file"
                entries.append({"name": name, "type": entry_type})

            # Sort: directories first, then files, both alphabetical
            entries.sort(key=lambda e: (0 if e["type"] == "directory" else 1, e["name"].lower()))

            response = {
                "type": "directory_listing",
                "path": path,
                "entries": entries
            }
        except PermissionError:
            response = {
                "type": "directory_listing",
                "path": path,
                "entries": [],
                "error": "permission_denied"
            }

        await websocket.send(json.dumps(response))

    async def handle_read_file(self, websocket, data):
        """Handle read_file request - returns file contents as text"""
        path = data.get("path", "")

        if not path or not os.path.isfile(path):
            response = {
                "type": "file_contents",
                "path": path,
                "error": "not_found"
            }
            await websocket.send(json.dumps(response))
            return

        try:
            with open(path, 'r', encoding='utf-8') as f:
                contents = f.read()

            response = {
                "type": "file_contents",
                "path": path,
                "contents": contents
            }
        except UnicodeDecodeError:
            response = {
                "type": "file_contents",
                "path": path,
                "error": "binary_file"
            }
        except PermissionError:
            response = {
                "type": "file_contents",
                "path": path,
                "error": "permission_denied"
            }

        await websocket.send(json.dumps(response))

    async def handle_add_project(self, websocket, data):
        """Handle add_project request - creates directory and starts Claude"""
        name = data.get("name", "").strip()
        success = False
        project_path = ""

        if not name:
            response = {
                "type": "project_created",
                "success": False,
                "error": "Project name is required"
            }
            await websocket.send(json.dumps(response))
            return

        safe_name = "".join(c for c in name if c.isalnum() or c in "-_. ")
        project_path = os.path.join(self.projects_base_path, safe_name)

        try:
            os.makedirs(project_path, exist_ok=True)
            success = self.tmux.start_session(working_dir=project_path)

            if success:
                await asyncio.sleep(2.0)  # Wait for Claude to initialize
                # Send Enter to accept any prompts
                self.tmux.send_input("")

        except Exception as e:
            print(f"Error creating project: {e}")

        response = {
            "type": "project_created",
            "success": success,
            "path": project_path,
            "name": safe_name
        }
        await websocket.send(json.dumps(response))

    async def handle_permission_response(self, data):
        """Handle permission response from iOS"""
        request_id = data.get('request_id', '')
        decision = data.get('decision', 'deny')

        if self.permission_handler.is_request_pending(request_id):
            # Normal flow - resolve the waiting hook
            self.permission_handler.resolve_request(request_id, {
                "decision": decision,
                "input": data.get('input'),
                "selected_option": data.get('selected_option')
            })
            # Notify iOS that the permission was resolved
            await self.permission_handler.broadcast({
                "type": "permission_resolved",
                "request_id": request_id,
                "answered_in": "ios"
            })
        elif self.permission_handler.is_request_timed_out(request_id):
            # Late response - inject into terminal
            await self.inject_terminal_response(decision, data)

    async def inject_terminal_response(self, decision, data):
        """Inject permission response into terminal after timeout"""
        if decision == "allow":
            text = data.get('input', 'y')
        else:
            text = 'n'

        self.tmux.send_input(text)
        print(f"Injected late response: {text}")

    async def handle_usage_request(self, websocket):
        """Handle usage_request - send cached immediately, then fetch fresh."""
        # Send cached immediately if available
        cached = self.usage_checker.get_cached()
        if cached:
            await websocket.send(json.dumps(cached))

        # Fetch fresh in background
        fresh = await self.usage_checker.check_usage()
        await websocket.send(json.dumps(fresh))

    async def handle_message(self, websocket, message):
        """Handle incoming message with state validation"""
        try:
            data = json.loads(message)
            msg_type = data.get('type')

            # Validate permission_response has a pending request
            if msg_type == 'permission_response':
                request_id = data.get('request_id', '')
                if not self.permission_handler.is_request_pending(request_id) and \
                   not self.permission_handler.is_request_timed_out(request_id):
                    await websocket.send(json.dumps({
                        "type": "error",
                        "message": "No pending permission request"
                    }))
                    return

            # Reject voice_input while permission is pending
            if msg_type == 'voice_input':
                if self.permission_handler.pending_permissions:
                    await websocket.send(json.dumps({
                        "type": "error",
                        "message": "Cannot send voice input while permission pending"
                    }))
                    return

            if msg_type == 'voice_input':
                await self.handle_voice_input(websocket, data)
            elif msg_type == 'list_projects':
                await self.handle_list_projects(websocket)
            elif msg_type == 'list_sessions':
                await self.handle_list_sessions(websocket, data)
            elif msg_type == 'get_session':
                await self.handle_get_session(websocket, data)
            elif msg_type == 'close_session':
                await self.handle_close_session(websocket)
            elif msg_type == 'new_session':
                await self.handle_new_session(websocket, data)
            elif msg_type == 'resume_session':
                await self.handle_resume_session(websocket, data)
            elif msg_type == 'add_project':
                await self.handle_add_project(websocket, data)
            elif msg_type == 'list_directory':
                await self.handle_list_directory(websocket, data)
            elif msg_type == 'read_file':
                await self.handle_read_file(websocket, data)
            elif msg_type == 'permission_response':
                await self.handle_permission_response(data)
            elif msg_type == 'usage_request':
                await self.handle_usage_request(websocket)
        except Exception as e:
            print(f"Error: {e}")

    async def handle_client(self, websocket, path):
        """Handle client connection"""
        self.clients.add(websocket)
        self.permission_handler.websocket_clients.add(websocket)
        print(f"Client connected. Total clients: {len(self.clients)}")

        # Preserve active_session_id across reconnects - app receives current state
        # via send_connection_status below

        try:
            await self.send_status(websocket, "idle", "Connected")
            await self.send_connection_status(websocket)
            async for message in websocket:
                print(f"Received message: {message[:100]}...")
                await self.handle_message(websocket, message)
        except Exception as e:
            print(f"Client error: {e}")
        finally:
            self.clients.discard(websocket)
            self.permission_handler.websocket_clients.discard(websocket)
            print(f"Client disconnected. Total clients: {len(self.clients)}")

    async def start(self):
        """Start server"""
        # Get the running event loop
        self.loop = asyncio.get_running_loop()

        # Check tmux availability
        if not self.tmux.is_available():
            print("WARNING: tmux not installed. Install with: brew install tmux")
        else:
            print("tmux available for session management")

        self.transcript_path = self.find_transcript_path()

        if self.transcript_path:
            self.transcript_handler = TranscriptHandler(
                self.handle_content_response,  # New: content callback
                self.handle_claude_response,   # Existing: audio callback
                self.loop,
                self
            )
            # Set expected session file (initializes line count from existing content)
            self.transcript_handler.set_session_file(self.transcript_path)
            self.observer = Observer()
            self.observer.schedule(self.transcript_handler, os.path.dirname(self.transcript_path))
            self.observer.start()

        # Start HTTP server for permission hooks
        http_runner = await start_http_server(self.permission_handler)

        from .qr_display import get_local_ip, print_startup_banner

        local_ip = get_local_ip()
        if local_ip:
            print_startup_banner(local_ip, PORT)
        else:
            print(f"WARNING: Could not detect local IP. Server running on port {PORT}")

        async with websockets.serve(self.handle_client, "0.0.0.0", PORT):
            await asyncio.Future()


def main():
    """Entry point for claude-connect command."""
    asyncio.run(VoiceServer().start())


if __name__ == "__main__":
    main()
