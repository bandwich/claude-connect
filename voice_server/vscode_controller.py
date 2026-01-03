"""VS Code remote control via WebSocket"""

import asyncio
import json
import websockets
from typing import Optional


class VSCodeController:
    """Controls VS Code via vscode-remote-control WebSocket extension"""

    VSCODE_WS_URL = "ws://localhost:3710"

    def __init__(self, url: Optional[str] = None):
        self.url = url or self.VSCODE_WS_URL
        self._ws: Optional[websockets.WebSocketClientProtocol] = None
        self._connected = False

    async def connect(self) -> bool:
        """Connect to VS Code extension WebSocket server"""
        try:
            self._ws = await websockets.connect(self.url)
            self._connected = True
            return True
        except Exception as e:
            print(f"Failed to connect to VS Code: {e}")
            self._connected = False
            return False

    async def disconnect(self):
        """Disconnect from VS Code"""
        if self._ws:
            await self._ws.close()
            self._ws = None
            self._connected = False

    async def _send_command(self, command: str, args: Optional[dict] = None):
        """Send a command to VS Code"""
        if not self._connected or not self._ws:
            raise ConnectionError("Not connected to VS Code")

        message = {"command": command}
        if args:
            message["args"] = args

        await self._ws.send(json.dumps(message))

    async def send_sequence(self, text: str):
        """Send text to the active terminal"""
        await self._send_command(
            "workbench.action.terminal.sendSequence",
            {"text": text}
        )

    async def new_terminal(self):
        """Open a new terminal"""
        await self._send_command("workbench.action.terminal.new")

    async def kill_terminal(self):
        """Kill the active terminal"""
        await self._send_command("workbench.action.terminal.kill")

    async def open_folder(self, folder_path: str):
        """Open a folder in VS Code (uses CLI)"""
        import subprocess
        subprocess.run(["code", folder_path])
