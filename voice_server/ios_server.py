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

# Add venv to path
sys.path.insert(0, '/Users/aaron/Desktop/max/.venv/lib/python3.9/site-packages')

from tts_utils import generate_tts_audio, samples_to_wav_bytes
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from content_models import TextBlock, ThinkingBlock, ToolUseBlock, ContentBlock, AssistantResponse
from session_manager import SessionManager
from vscode_controller import VSCodeController
from permission_handler import PermissionHandler
from http_server import start_http_server

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
    """Monitors transcript file for new assistant messages"""

    def __init__(self, content_callback, audio_callback, loop, server):
        self.content_callback = content_callback  # New: sends AssistantResponse
        self.audio_callback = audio_callback       # Existing: sends text for TTS
        self.loop = loop
        self.server = server
        self.last_message = None
        self.last_modified = 0
        # Track what we've already sent
        self.sent_blocks_by_message = {}  # {message_id: num_blocks_sent}
        self.current_message_id = None

    def on_modified(self, event):
        if event.is_directory or not event.src_path.endswith('.jsonl'):
            return

        current_time = time.time()
        if current_time - self.last_modified < 0.05:  # Reduced from 0.5s to 50ms
            return
        self.last_modified = current_time

        try:
            # Extract only NEW blocks since last check
            if self.server.last_voice_input:
                print(f"[DEBUG] File modified, extracting new blocks...")
                new_blocks = self.extract_new_blocks(
                    event.src_path,
                    self.server.last_voice_input
                )
                print(f"[DEBUG] Extracted {len(new_blocks)} new blocks")

                if new_blocks:
                    # Create response with ONLY the new blocks
                    response = AssistantResponse(
                        content_blocks=new_blocks,
                        timestamp=time.time(),
                        is_incremental=True  # Signal that more blocks may arrive
                    )

                    # 1. Send structured content immediately
                    asyncio.run_coroutine_threadsafe(
                        self.content_callback(response),
                        self.loop
                    )

                    # 2. Extract text for TTS
                    text = extract_text_for_tts(new_blocks)
                    print(f"[DEBUG] Extracted text for TTS: '{text}'")

                    # 3. Send for audio generation
                    if text:
                        print(f"[DEBUG] Calling audio_callback with text")
                        asyncio.run_coroutine_threadsafe(
                            self.audio_callback(text),
                            self.loop
                        )
                    else:
                        print(f"[DEBUG] No text in this batch - non-text blocks only")
        except Exception as e:
            print(f"Error processing transcript: {e}")
            import traceback
            traceback.print_exc()

    def extract_new_blocks(self, filepath, user_message) -> list[ContentBlock]:
        """Extract only NEW blocks that haven't been sent yet

        Returns:
            List of new ContentBlock objects that haven't been sent
        """
        found_user_message = False
        collecting_response = False
        all_parsed_blocks = []
        current_msg_id = None

        print(f"[DEBUG] Looking for user message: '{user_message[:50]}...'")

        with open(filepath, 'r') as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                    msg = entry.get('message', {})
                    role = msg.get('role') or entry.get('role')

                    # Check if this is a user message matching our voice input
                    if role == 'user' and not found_user_message:
                        content = msg.get('content', entry.get('content', ''))
                        if isinstance(content, str):
                            user_text = content
                        elif isinstance(content, list):
                            text_parts = [
                                block.get('text', '')
                                for block in content
                                if isinstance(block, dict) and block.get('type') == 'text'
                            ]
                            user_text = ' '.join(text_parts)
                        else:
                            continue

                        # Check if this user message matches our voice input
                        if user_text.strip() == user_message.strip():
                            print(f"[DEBUG] Found matching user message!")
                            found_user_message = True
                            collecting_response = True
                            continue

                    # Collect ALL consecutive assistant messages
                    if collecting_response:
                        if role == 'assistant':
                            msg_id = msg.get('id', 'no-id')
                            current_msg_id = msg_id
                            content = msg.get('content', entry.get('content', ''))

                            if isinstance(content, str):
                                # String content - create single text block
                                result = content.strip()
                                if result:
                                    all_parsed_blocks.append(TextBlock(type="text", text=result))
                            elif isinstance(content, list):
                                # Parse structured content blocks
                                for block in content:
                                    if isinstance(block, dict):
                                        block_type = block.get('type')
                                        try:
                                            if block_type == 'text':
                                                all_parsed_blocks.append(TextBlock(**block))
                                            elif block_type == 'thinking':
                                                all_parsed_blocks.append(ThinkingBlock(**block))
                                            elif block_type == 'tool_use':
                                                all_parsed_blocks.append(ToolUseBlock(**block))
                                        except Exception as e:
                                            print(f"[DEBUG] Error parsing block: {e}")
                                            continue
                        elif role == 'user':
                            # Hit another user message, stop collecting
                            print(f"[DEBUG] Hit next user message, stopping collection")
                            break
                except:
                    continue

        # Update tracking state
        if current_msg_id:
            self.current_message_id = current_msg_id

        # Calculate how many blocks we've already sent for this message
        already_sent = self.sent_blocks_by_message.get(self.current_message_id, 0)

        # Return only the NEW blocks
        new_blocks = all_parsed_blocks[already_sent:]

        if new_blocks:
            print(f"[DEBUG] Found {len(new_blocks)} new blocks (already sent {already_sent})")
            # Update the count
            self.sent_blocks_by_message[self.current_message_id] = already_sent + len(new_blocks)
        else:
            print(f"[DEBUG] No new blocks (total: {len(all_parsed_blocks)}, sent: {already_sent})")

        return new_blocks

    def reset_tracking_state(self):
        """Reset tracking state for a new voice input conversation"""
        print("[DEBUG] Resetting block tracking state for new conversation")
        self.sent_blocks_by_message = {}
        self.current_message_id = None
        self.last_message = None

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
        self.vscode_controller = VSCodeController()
        self.permission_handler = PermissionHandler()
        self.projects_base_path = PROJECTS_BASE_PATH
        self.active_session_id = None  # Track which session is open in VSCode

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

    async def send_status(self, websocket, state, message):
        """Send status update to client"""
        await websocket.send(json.dumps({
            "type": "status",
            "state": state,
            "message": message,
            "timestamp": time.time()
        }))

    async def send_vscode_status(self, websocket):
        """Send VSCode status to a single client"""
        response = {
            "type": "vscode_status",
            "vscode_connected": self.vscode_controller.is_connected(),
            "active_session_id": self.active_session_id
        }
        await websocket.send(json.dumps(response))

    async def broadcast_vscode_status(self):
        """Broadcast VSCode status to all connected clients"""
        for websocket in list(self.clients):
            try:
                await self.send_vscode_status(websocket)
            except Exception as e:
                print(f"Error broadcasting status: {e}")

    async def send_to_vs_code_applescript(self, text):
        """Send text to VS Code via AppleScript (fallback)"""
        subprocess.run(['pbcopy'], input=text.encode('utf-8'))
        applescript = '''
tell application "Visual Studio Code"
    activate
end tell
delay 0.3
tell application "System Events"
    keystroke "v" using {command down}
    delay 0.2
    keystroke return
end tell
'''
        subprocess.run(['osascript', '-e', applescript])

    async def send_to_vs_code(self, text):
        """Send text to VS Code terminal

        Tries VSCodeController first, falls back to AppleScript if not connected.
        """
        if self.vscode_controller.is_connected():
            success = await self.vscode_controller.send_sequence(text + "\n")
            if success:
                return
            print("VSCode send failed, falling back to AppleScript")

        # Fallback to AppleScript
        await self.send_to_vs_code_applescript(text)

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
            if self.transcript_handler:
                self.transcript_handler.reset_tracking_state()
            self.waiting_for_response = True
            self.last_voice_input = text

            print(f"[{time.strftime('%H:%M:%S')}] Sending to VS Code...")
            try:
                await self.send_status(websocket, "processing", "Sending to Claude...")
            except Exception:
                pass  # WebSocket may have closed, that's OK

            await self.send_to_vs_code(text)
            print(f"[{time.strftime('%H:%M:%S')}] Sent to VS Code successfully")
        else:
            print("Empty text received, ignoring")

    async def handle_content_response(self, response: AssistantResponse):
        """Send structured content to iOS clients"""
        print(f"[{time.strftime('%H:%M:%S')}] Sending structured content: {len(response.content_blocks)} blocks")

        # Serialize using Pydantic
        message = response.model_dump()

        for websocket in list(self.clients):
            try:
                await websocket.send(json.dumps(message))
                print(f"[{time.strftime('%H:%M:%S')}] Sent content to client")
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
        """Handle close_session request - kills the active terminal"""
        success = False

        if self.vscode_controller.is_connected():
            try:
                await self.vscode_controller.kill_terminal()
                success = True
                self.active_session_id = None  # Clear active session
            except Exception as e:
                print(f"Error closing session: {e}")

        response = {
            "type": "session_closed",
            "success": success
        }
        await websocket.send(json.dumps(response))

        # Broadcast status to all clients
        if success:
            await self.broadcast_vscode_status()

    async def handle_new_session(self, websocket, data):
        """Handle new_session request - opens terminal and starts claude

        Ensures only one terminal is active by killing existing terminal first.
        """
        project_path = data.get("project_path", "")
        success = False

        if self.vscode_controller.is_connected():
            try:
                # Kill existing terminal first to ensure only one terminal
                await self.vscode_controller.kill_terminal()
                await asyncio.sleep(0.3)

                await self.vscode_controller.new_terminal()
                await asyncio.sleep(0.5)
                success = await self.vscode_controller.send_sequence("claude\n")
                if success:
                    self.active_session_id = None  # New session has no ID yet
            except Exception as e:
                print(f"Error creating new session: {e}")

        response = {
            "type": "session_created",
            "success": success
        }
        await websocket.send(json.dumps(response))

        # Broadcast status to all clients
        if success:
            await self.broadcast_vscode_status()

    async def handle_resume_session(self, websocket, data):
        """Handle resume_session request - runs 'claude --resume <id>'

        Ensures only one terminal is active by killing existing terminal first.
        """
        session_id = data.get("session_id", "")
        success = False

        if self.vscode_controller.is_connected() and session_id:
            try:
                # Kill existing terminal first to ensure only one terminal
                await self.vscode_controller.kill_terminal()
                await asyncio.sleep(0.3)

                await self.vscode_controller.new_terminal()
                await asyncio.sleep(0.5)
                success = await self.vscode_controller.send_sequence(
                    f"claude --resume {session_id}\n"
                )
                if success:
                    self.active_session_id = session_id  # Track active session
            except Exception as e:
                print(f"Error resuming session: {e}")

        response = {
            "type": "session_resumed",
            "success": success,
            "session_id": session_id
        }
        await websocket.send(json.dumps(response))

        # Broadcast status to all clients
        if success:
            await self.broadcast_vscode_status()

    async def handle_add_project(self, websocket, data):
        """Handle add_project request - creates directory and opens in VS Code

        Gracefully closes current project by killing terminal before opening new folder.
        """
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

        safe_name = "".join(c for c in name if c.isalnum() or c in "-_.")
        project_path = os.path.join(self.projects_base_path, safe_name)

        try:
            os.makedirs(project_path, exist_ok=True)

            if self.vscode_controller.is_connected():
                # Kill existing terminal first for graceful close
                await self.vscode_controller.kill_terminal()
                await asyncio.sleep(0.3)

                await self.vscode_controller.open_folder(project_path)
                await asyncio.sleep(3.0)
                await self.vscode_controller.new_terminal()
                await asyncio.sleep(0.5)
                await self.vscode_controller.send_sequence("claude\n")
                await asyncio.sleep(2.0)
                success = await self.vscode_controller.send_sequence("\r")
            else:
                success = True

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
        elif self.permission_handler.is_request_timed_out(request_id):
            # Late response - inject into terminal
            await self.inject_terminal_response(decision, data)

    async def inject_terminal_response(self, decision, data):
        """Inject permission response into terminal after timeout"""
        if decision == "allow":
            text = data.get('input', 'y')
        else:
            text = 'n'

        await self.send_to_vs_code(text)
        print(f"Injected late response: {text}")

    async def handle_message(self, websocket, message):
        """Handle incoming message"""
        try:
            data = json.loads(message)
            msg_type = data.get('type')

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
            elif msg_type == 'permission_response':
                await self.handle_permission_response(data)
        except Exception as e:
            print(f"Error: {e}")

    async def handle_client(self, websocket, path):
        """Handle client connection"""
        self.clients.add(websocket)
        self.permission_handler.websocket_clients.add(websocket)
        print(f"Client connected. Total clients: {len(self.clients)}")
        try:
            await self.send_status(websocket, "idle", "Connected")
            await self.send_vscode_status(websocket)  # Send VSCode status on connect
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

        # Try to connect to VSCode extension
        connected = await self.vscode_controller.connect()
        if connected:
            print("✅ Connected to VSCode extension")
        else:
            print("⚠️ VSCode extension not available, using AppleScript fallback")

        self.transcript_path = self.find_transcript_path()

        if self.transcript_path:
            self.transcript_handler = TranscriptHandler(
                self.handle_content_response,  # New: content callback
                self.handle_claude_response,   # Existing: audio callback
                self.loop,
                self
            )
            self.observer = Observer()
            self.observer.schedule(self.transcript_handler, os.path.dirname(self.transcript_path))
            self.observer.start()

        # Start HTTP server for permission hooks
        http_runner = await start_http_server(self.permission_handler)

        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        local_ip = s.getsockname()[0]
        s.close()

        print(f"Server running on ws://{local_ip}:{PORT}")

        async with websockets.serve(self.handle_client, "0.0.0.0", PORT):
            await asyncio.Future()


if __name__ == "__main__":
    asyncio.run(VoiceServer().start())
