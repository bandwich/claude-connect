"""
Input Handler - handles voice and text input from iOS.
"""

import asyncio
import base64
import json
import os
import time
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from voice_server.server import VoiceServer


class InputHandler:
    """Handles voice input, text+image input, and delivery verification."""

    def __init__(self, server: "VoiceServer"):
        self.server = server

    async def handle_voice_input(self, websocket, data):
        """Handle voice input from iOS"""
        text = data.get('text', '').strip()
        print(f"[{time.strftime('%H:%M:%S')}] Voice input received: '{text}'")
        if text:
            self.server.waiting_for_response = True
            self.server.last_voice_input = text
            ctx = self.server._get_viewed_context()
            if ctx:
                ctx.waiting_for_response = True
                ctx.last_voice_input = text

            print(f"[{time.strftime('%H:%M:%S')}] Sending to terminal...")
            for client in list(self.server.clients):
                try:
                    await self.server.send_status(client, "processing", "Sending to Claude...")
                except Exception:
                    pass

            await self.server.send_to_terminal(text)
            print(f"[{time.strftime('%H:%M:%S')}] Sent to terminal successfully")

            delivered = await self.server.verify_delivery(text)
            delivery_msg = {
                "type": "delivery_status",
                "status": "confirmed" if delivered else "failed",
                "text": text
            }
            for client in list(self.server.clients):
                try:
                    await client.send(json.dumps(delivery_msg))
                except Exception:
                    pass

            if not delivered:
                print(f"[SYNC WARNING] Message delivery not confirmed: '{text[:50]}'")
        else:
            print("Empty text received, ignoring")

    async def handle_user_input(self, websocket, data):
        """Handle text + optional image input from iOS"""
        text = data.get('text', '').strip()
        images = data.get('images', [])

        if not text and not images:
            print("Empty user_input received, ignoring")
            return

        image_paths = []
        for img in images:
            try:
                import uuid
                img_data = base64.b64decode(img['data'])
                ext = os.path.splitext(img.get('filename', 'image.jpg'))[1] or '.jpg'
                filename = f"claude_voice_img_{uuid.uuid4().hex[:12]}{ext}"
                filepath = os.path.join('/tmp', filename)
                with open(filepath, 'wb') as f:
                    f.write(img_data)
                image_paths.append(filepath)
                print(f"[UserInput] Saved image: {filepath} ({len(img_data)} bytes)")
            except Exception as e:
                print(f"[UserInput] Failed to save image: {e}")

        prompt = text
        for path in image_paths:
            prompt += f"\n[Image: {path}]"

        print(f"[{time.strftime('%H:%M:%S')}] User input: '{prompt[:100]}'")

        self.server.waiting_for_response = True
        self.server.last_voice_input = text

        for client in list(self.server.clients):
            try:
                await self.server.send_status(client, "processing", "Sending to Claude...")
            except Exception:
                pass

        await self.server.send_to_terminal(prompt)

    async def verify_delivery(self, text: str, timeout: float = 5.0) -> bool:
        """Poll transcript file to verify a user message was written by Claude Code."""
        if not self.server.transcript_handler or not self.server.transcript_handler.expected_session_file:
            return False

        filepath = self.server.transcript_handler.expected_session_file
        start_line = self.server.transcript_handler.processed_line_count
        deadline = time.time() + timeout
        poll_interval = 0.5

        while time.time() < deadline:
            try:
                with open(filepath, 'r') as f:
                    lines = f.readlines()

                for line in lines[start_line:]:
                    try:
                        entry = json.loads(line.strip())
                        msg = entry.get('message', {})
                        role = msg.get('role') or entry.get('role')
                        if role == 'user':
                            content = msg.get('content', '')
                            if isinstance(content, str) and text in content:
                                return True
                            elif isinstance(content, list):
                                for block in content:
                                    if isinstance(block, dict) and text in block.get('text', ''):
                                        return True
                    except (json.JSONDecodeError, KeyError):
                        continue
            except FileNotFoundError:
                pass

            await asyncio.sleep(poll_interval)

        return False

    async def handle_interrupt(self):
        """Handle interrupt request from iOS - send Escape to tmux"""
        if self.server._active_tmux_session and self.server.tmux.session_exists(self.server._active_tmux_session):
            self.server.tmux.send_escape(self.server._active_tmux_session)
            print(f"[{time.strftime('%H:%M:%S')}] Sent interrupt (Escape) to {self.server._active_tmux_session}")
