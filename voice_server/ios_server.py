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

# Add venv to path
sys.path.insert(0, '/Users/aaron/Desktop/max/.venv/lib/python3.9/site-packages')

from tts_utils import generate_tts_audio, samples_to_wav_bytes
from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler

# Configuration
PORT = 8765
TRANSCRIPT_DIR = os.path.expanduser("~/.claude/projects/")


class TranscriptHandler(FileSystemEventHandler):
    """Monitors transcript file for new assistant messages"""

    def __init__(self, callback, loop, server):
        self.callback = callback
        self.loop = loop
        self.server = server
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
            # Extract the assistant response to the last voice input
            if self.server.last_voice_input:
                print(f"[DEBUG] File modified, extracting response...")
                message = self.extract_assistant_response_to_user_message(
                    event.src_path,
                    self.server.last_voice_input
                )
                print(f"[DEBUG] Extracted message: {message[:50] if message else 'None'}...")
                if message and message != self.last_message:
                    self.last_message = message
                    # Schedule coroutine on the event loop from this thread
                    asyncio.run_coroutine_threadsafe(self.callback(message), self.loop)
        except Exception as e:
            print(f"Error processing transcript: {e}")

    def extract_assistant_response_to_user_message(self, filepath, user_message):
        """Extract the first assistant message that comes after the specified user message"""
        found_user_message = False
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
                            continue
                        else:
                            print(f"[DEBUG] User message doesn't match: '{user_text[:50]}...'")

                    # If we found the user message, return the next assistant message
                    if found_user_message and role == 'assistant':
                        print(f"[DEBUG] Found assistant response after user message!")
                        content = msg.get('content', entry.get('content', ''))

                        if isinstance(content, str):
                            result = content.strip()
                            if result:
                                return result
                        elif isinstance(content, list):
                            # Extract text from text blocks only (skip thinking, tool_use, etc.)
                            text_parts = []
                            for block in content:
                                if isinstance(block, dict) and block.get('type') == 'text':
                                    text_content = block.get('text', '')
                                    if text_content:
                                        text_parts.append(text_content)

                            if text_parts:
                                return ' '.join(text_parts).strip()

                except:
                    continue

        return None


class VoiceServer:
    """WebSocket server for iOS voice mode"""

    def __init__(self):
        self.clients = set()
        self.transcript_path = None
        self.observer = None
        self.loop = None
        self.waiting_for_response = False  # Track if we're waiting for a response to voice input
        self.last_voice_input = None  # Track the last voice input text

    def find_transcript_path(self):
        """Find the most recent transcript file"""
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

    async def send_to_vs_code(self, text):
        """Send text to VS Code via AppleScript"""
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
            print(f"[{time.strftime('%H:%M:%S')}] Sending to VS Code...")
            await self.send_status(websocket, "processing", "Sending to Claude...")
            self.waiting_for_response = True  # Mark that we're waiting for Claude's response
            self.last_voice_input = text  # Store the voice input text
            await self.send_to_vs_code(text)
            print(f"[{time.strftime('%H:%M:%S')}] Sent to VS Code successfully")
        else:
            print("Empty text received, ignoring")

    async def handle_claude_response(self, text):
        """Handle Claude's response"""
        print(f"[{time.strftime('%H:%M:%S')}] Claude response received: '{text[:100]}...'")

        # Only process if we're waiting for a response to voice input
        if not self.waiting_for_response:
            print(f"[{time.strftime('%H:%M:%S')}] Ignoring response (not from voice input)")
            return

        # Mark that we've processed the response
        self.waiting_for_response = False

        for websocket in list(self.clients):
            print(f"[{time.strftime('%H:%M:%S')}] Sending 'speaking' status to client")
            await self.send_status(websocket, "speaking", "Playing response")
            print(f"[{time.strftime('%H:%M:%S')}] Streaming audio to client...")
            await self.stream_audio(websocket, text)
            print(f"[{time.strftime('%H:%M:%S')}] Audio streaming complete, sending 'idle' status")
            await self.send_status(websocket, "idle", "Ready")

    async def handle_message(self, websocket, message):
        """Handle incoming message"""
        try:
            data = json.loads(message)
            if data.get('type') == 'voice_input':
                await self.handle_voice_input(websocket, data)
        except Exception as e:
            print(f"Error: {e}")

    async def handle_client(self, websocket, path):
        """Handle client connection"""
        self.clients.add(websocket)
        print(f"Client connected. Total clients: {len(self.clients)}")
        try:
            await self.send_status(websocket, "idle", "Connected")
            async for message in websocket:
                print(f"Received message: {message[:100]}...")
                await self.handle_message(websocket, message)
        except Exception as e:
            print(f"Client error: {e}")
        finally:
            self.clients.discard(websocket)
            print(f"Client disconnected. Total clients: {len(self.clients)}")

    async def start(self):
        """Start server"""
        # Get the running event loop
        self.loop = asyncio.get_running_loop()

        self.transcript_path = self.find_transcript_path()

        if self.transcript_path:
            handler = TranscriptHandler(self.handle_claude_response, self.loop, self)
            self.observer = Observer()
            self.observer.schedule(handler, os.path.dirname(self.transcript_path))
            self.observer.start()

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
