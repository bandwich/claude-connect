# voice_server/permission_handler.py
"""Permission request handler for Claude Code hooks"""

import asyncio
import json
from typing import Optional
import uuid


class PermissionHandler:
    """Manages permission requests from Claude Code hooks"""

    def __init__(self):
        self.pending_permissions: dict[str, asyncio.Event] = {}
        self.permission_responses: dict[str, dict] = {}
        self.websocket_clients: set = set()
        self.timed_out_requests: set[str] = set()
        self.latest_request_id: Optional[str] = None

    def register_request(self, request_id: str) -> asyncio.Event:
        """Register a new permission request and return an Event to wait on"""
        event = asyncio.Event()
        self.pending_permissions[request_id] = event
        self.latest_request_id = request_id
        return event

    def resolve_request(self, request_id: str, decision: dict) -> bool:
        """Resolve a pending permission request with a decision"""
        if request_id in self.pending_permissions:
            self.permission_responses[request_id] = decision
            self.pending_permissions[request_id].set()
            return True
        return False

    def is_request_pending(self, request_id: str) -> bool:
        """Check if a request is still pending (event not set)"""
        if request_id not in self.pending_permissions:
            return False
        return not self.pending_permissions[request_id].is_set()

    def is_request_timed_out(self, request_id: str) -> bool:
        """Check if a request timed out (terminal fallback active)"""
        return request_id in self.timed_out_requests

    def mark_timed_out(self, request_id: str):
        """Mark a request as timed out (fell back to terminal)"""
        self.timed_out_requests.add(request_id)
        if request_id in self.pending_permissions:
            del self.pending_permissions[request_id]

    async def wait_for_response(
        self, request_id: str, timeout: float = 180.0
    ) -> Optional[dict]:
        """Wait for a response to a permission request"""
        if request_id not in self.pending_permissions:
            return None

        event = self.pending_permissions[request_id]

        try:
            await asyncio.wait_for(event.wait(), timeout=timeout)
            return self.permission_responses.get(request_id)
        except asyncio.TimeoutError:
            self.mark_timed_out(request_id)
            return None

    def cleanup_request(self, request_id: str):
        """Clean up all state for a request"""
        self.pending_permissions.pop(request_id, None)
        self.permission_responses.pop(request_id, None)
        self.timed_out_requests.discard(request_id)

    async def broadcast(self, message: dict):
        """Broadcast a message to all connected WebSocket clients"""
        json_message = json.dumps(message)
        for client in list(self.websocket_clients):
            try:
                await client.send(json_message)
            except Exception as e:
                print(f"Error broadcasting to client: {e}")
                self.websocket_clients.discard(client)

    def generate_request_id(self) -> str:
        """Generate a unique request ID"""
        return str(uuid.uuid4())
