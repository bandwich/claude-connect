#!/usr/bin/env python3
"""
Test server for integration tests
Modified version of ios_server.py with test mode capabilities
"""

import asyncio
import websockets
import json
import sys
import os
import time
import base64
from aiohttp import web
import logging

from voice_server.tts_utils import samples_to_wav_bytes
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from integration_tests.test_config import *
from integration_tests.mock_transcript import MockTranscript, create_empty_transcript

# Setup logging
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL),
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)


class TestTranscriptHandler(FileSystemEventHandler):
    """Monitors test transcript file for new assistant messages"""

    def __init__(self, callback, loop):
        self.callback = callback
        self.loop = loop
        self.last_message = None
        self.last_modified = 0

    def on_modified(self, event):
        if event.is_directory or not event.src_path.endswith('.jsonl'):
            return

        current_time = time.time()
        if current_time - self.last_modified < 0.5:
            return
        self.last_modified = current_time

        try:
            message = self.extract_last_assistant_message(event.src_path)
            if message and message != self.last_message:
                self.last_message = message
                # Schedule coroutine on the event loop from this thread
                asyncio.run_coroutine_threadsafe(self.callback(message), self.loop)
        except Exception as e:
            logger.error(f"Error processing transcript: {e}")

    def extract_last_assistant_message(self, filepath):
        """Extract the last assistant message from transcript"""
        last_response = None

        with open(filepath, 'r') as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                    msg = entry.get('message', {})

                    if msg.get('role') == 'assistant' or entry.get('role') == 'assistant':
                        content = msg.get('content', entry.get('content', ''))

                        if isinstance(content, str):
                            last_response = content
                        elif isinstance(content, list):
                            text_parts = [
                                block.get('text', '')
                                for block in content
                                if isinstance(block, dict) and block.get('type') == 'text'
                            ]
                            last_response = ' '.join(text_parts)
                except:
                    continue

        return last_response if last_response and len(last_response.strip()) >= 3 else None


class TestVoiceServer:
    """Test WebSocket server with HTTP control interface"""

    def __init__(self):
        self.clients = set()
        self.transcript_path = TEST_TRANSCRIPT_PATH
        self.observer = None
        self.logs = []
        self.mock_transcript = None

    def log(self, message):
        """Log message and store for test retrieval"""
        self.logs.append(f"{time.time()}: {message}")
        logger.info(message)

    async def send_status(self, websocket, state, message):
        """Send status update to client"""
        msg = {
            "type": "status",
            "state": state,
            "message": message,
            "timestamp": time.time()
        }
        await websocket.send(json.dumps(msg))
        self.log(f"Sent status: {state} - {message}")

    async def stream_audio(self, websocket, text):
        """Stream audio to client (using mock audio in test mode)"""
        try:
            if MOCK_TTS and os.path.exists(TEST_AUDIO_PATH):
                # Use pre-generated test audio
                with open(TEST_AUDIO_PATH, 'rb') as f:
                    wav_bytes = f.read()
            else:
                # Generate TTS (fallback if test audio not available)
                from tts_utils import generate_tts_audio
                samples = generate_tts_audio(text, voice="af_heart")
                wav_bytes = samples_to_wav_bytes(samples)

            chunk_size = CHUNK_SIZE
            total_chunks = (len(wav_bytes) + chunk_size - 1) // chunk_size

            self.log(f"Streaming {len(wav_bytes)} bytes in {total_chunks} chunks")

            for i in range(0, len(wav_bytes), chunk_size):
                chunk = wav_bytes[i:i+chunk_size]
                chunk_msg = {
                    "type": "audio_chunk",
                    "format": "wav",
                    "sample_rate": 24000,
                    "chunk_index": i // chunk_size,
                    "total_chunks": total_chunks,
                    "data": base64.b64encode(chunk).decode('utf-8')
                }
                await websocket.send(json.dumps(chunk_msg))
                await asyncio.sleep(AUDIO_CHUNK_DELAY)

            self.log(f"Audio streaming complete: {total_chunks} chunks sent")

        except Exception as e:
            logger.error(f"Error streaming audio: {e}")
            self.log(f"ERROR: Audio streaming failed: {e}")

    async def handle_voice_input(self, websocket, data):
        """Handle voice input from iOS"""
        text = data.get('text', '').strip()
        timestamp = data.get('timestamp', time.time())

        self.log(f"Received voice_input: '{text}' (timestamp: {timestamp})")

        if text:
            await self.send_status(websocket, "processing", "Sending to Claude...")

            if MOCK_VS_CODE:
                # In test mode, add user message to mock transcript
                if self.mock_transcript:
                    self.mock_transcript.add_user_message(text)
                    self.log(f"Added user message to mock transcript")
            else:
                # Real mode: send to VS Code
                await self.send_to_vs_code(text)

    async def send_to_vs_code(self, text):
        """Send text to VS Code (not used in test mode)"""
        import subprocess
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
        self.log("Sent to VS Code via AppleScript")

    async def handle_claude_response(self, text):
        """Handle Claude's response"""
        self.log(f"Handling Claude response: '{text[:50]}...'")

        for websocket in list(self.clients):
            await self.send_status(websocket, "speaking", "Playing response")
            await self.stream_audio(websocket, text)
            await self.send_status(websocket, "idle", "Ready")

    async def handle_message(self, websocket, message):
        """Handle incoming WebSocket message"""
        try:
            data = json.loads(message)
            msg_type = data.get('type')
            self.log(f"Received message type: {msg_type}")

            if msg_type == 'voice_input':
                await self.handle_voice_input(websocket, data)
            else:
                self.log(f"Unknown message type: {msg_type}")

        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON: {e}")
            self.log(f"ERROR: Invalid JSON received")
        except Exception as e:
            logger.error(f"Error handling message: {e}")
            self.log(f"ERROR: {e}")

    async def handle_client(self, websocket, path):
        """Handle client connection"""
        client_addr = websocket.remote_address
        self.log(f"Client connected: {client_addr}")
        self.clients.add(websocket)

        try:
            await self.send_status(websocket, "idle", "Connected")
            async for message in websocket:
                await self.handle_message(websocket, message)
        except websockets.exceptions.ConnectionClosed:
            self.log(f"Client disconnected: {client_addr}")
        except Exception as e:
            logger.error(f"Error with client {client_addr}: {e}")
        finally:
            self.clients.discard(websocket)

    # HTTP Control Interface for Tests

    async def handle_inject_response(self, request):
        """Inject a mock Claude response (HTTP endpoint for tests)"""
        text = await request.text()
        self.log(f"HTTP: Injecting mock response: '{text[:50]}...'")

        if self.mock_transcript:
            self.mock_transcript.add_assistant_message(text)
            # Give file watcher time to detect
            await asyncio.sleep(0.6)

        return web.Response(text="Response injected")

    async def handle_get_logs(self, request):
        """Get server logs (HTTP endpoint for tests)"""
        return web.Response(text="\n".join(self.logs))

    async def handle_clear_logs(self, request):
        """Clear server logs (HTTP endpoint for tests)"""
        self.logs = []
        return web.Response(text="Logs cleared")

    async def handle_reset(self, request):
        """Reset server state (HTTP endpoint for tests)"""
        self.logs = []
        if self.mock_transcript:
            self.mock_transcript.clear()
        return web.Response(text="Server reset")

    async def handle_inject_status(self, request):
        """Manually send status message to all clients (HTTP endpoint for tests)"""
        try:
            data = await request.json()
            state = data.get('state', 'idle')
            message = data.get('message', '')

            self.log(f"HTTP: Injecting status: {state} - {message}")

            # Send status to all connected clients
            for websocket in list(self.clients):
                await self.send_status(websocket, state, message)

            return web.Response(text=f"Status '{state}' sent to {len(self.clients)} client(s)")
        except Exception as e:
            self.log(f"ERROR injecting status: {e}")
            return web.Response(text=f"Error: {e}", status=500)

    async def start_control_server(self):
        """Start HTTP control server for test harness"""
        app = web.Application()
        app.router.add_post('/inject_response', self.handle_inject_response)
        app.router.add_post('/inject_status', self.handle_inject_status)
        app.router.add_get('/logs', self.handle_get_logs)
        app.router.add_post('/clear_logs', self.handle_clear_logs)
        app.router.add_post('/reset', self.handle_reset)

        runner = web.AppRunner(app)
        await runner.setup()
        site = web.TCPSite(runner, TEST_HOST, CONTROL_PORT)
        await site.start()

        self.log(f"Control server started on http://{TEST_HOST}:{CONTROL_PORT}")

    async def start(self):
        """Start test server"""
        # Create test transcript file
        create_empty_transcript(self.transcript_path)
        self.mock_transcript = MockTranscript(self.transcript_path)
        self.log(f"Created test transcript: {self.transcript_path}")

        # Setup file watcher
        if os.path.exists(self.transcript_path):
            # Pass the event loop to the handler so it can schedule coroutines
            loop = asyncio.get_event_loop()
            handler = TestTranscriptHandler(self.handle_claude_response, loop)
            self.observer = Observer()
            self.observer.schedule(handler, os.path.dirname(self.transcript_path))
            self.observer.start()
            self.log("File watcher started")

        # Start control server
        await self.start_control_server()

        # Start WebSocket server
        self.log(f"Server listening on ws://{TEST_HOST}:{TEST_PORT}")
        print("READY")  # Signal to test harness
        sys.stdout.flush()

        async with websockets.serve(self.handle_client, TEST_HOST, TEST_PORT):
            await asyncio.Future()


if __name__ == "__main__":
    try:
        asyncio.run(TestVoiceServer().start())
    except KeyboardInterrupt:
        logger.info("Server stopped")
        cleanup_temp_dir()
