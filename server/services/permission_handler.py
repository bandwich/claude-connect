# server/permission_handler.py
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
        self.pending_messages: dict[str, dict] = {}  # request_id -> original broadcast message
        self.websocket_clients: set = set()
        self.timed_out_requests: set[str] = set()

    def register_request(self, request_id: str) -> asyncio.Event:
        """Register a new permission request and return an Event to wait on"""
        event = asyncio.Event()
        self.pending_permissions[request_id] = event
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
        self.pending_messages.pop(request_id, None)

    async def wait_for_response(
        self, request_id: str, timeout: float = 180.0
    ) -> Optional[dict]:
        """Wait for a response to a permission request"""
        if request_id not in self.pending_permissions:
            print(f"[PERM WAIT] {request_id} not in pending_permissions — returning None")
            return None

        event = self.pending_permissions[request_id]

        try:
            await asyncio.wait_for(event.wait(), timeout=timeout)
            response = self.permission_responses.get(request_id)
            print(f"[PERM WAIT] {request_id} resolved: {response.get('decision', '?') if response else 'None'}")
            return response
        except asyncio.TimeoutError:
            print(f"[PERM WAIT] {request_id} timed out after {timeout}s")
            self.mark_timed_out(request_id)
            return None
        except asyncio.CancelledError:
            print(f"[PERM WAIT] {request_id} CANCELLED — HTTP connection dropped?")
            raise

    def cleanup_request(self, request_id: str):
        """Clean up all state for a request"""
        self.pending_permissions.pop(request_id, None)
        self.permission_responses.pop(request_id, None)
        self.pending_messages.pop(request_id, None)
        self.timed_out_requests.discard(request_id)

    async def broadcast(self, message: dict):
        """Broadcast a message to all connected WebSocket clients"""
        # Store permission_request messages for re-send on reconnect
        if message.get("type") in ("permission_request", "question_prompt"):
            request_id = message.get("request_id", "")
            if request_id:
                self.pending_messages[request_id] = message

        json_message = json.dumps(message)
        for client in list(self.websocket_clients):
            try:
                await client.send(json_message)
            except Exception as e:
                print(f"Error broadcasting to client: {e}")
                self.websocket_clients.discard(client)

    async def send_pending_to_client(self, client):
        """Re-send any pending permission requests to a newly connected client"""
        for request_id, message in list(self.pending_messages.items()):
            if self.is_request_pending(request_id):
                try:
                    await client.send(json.dumps(message))
                except Exception as e:
                    print(f"Error sending pending permission to client: {e}")

    def cleanup_session(self, session_id: str):
        """Clean up all permission state for a specific session."""
        to_remove = [
            rid for rid, msg in self.pending_messages.items()
            if msg.get("session_id") == session_id
        ]
        for rid in to_remove:
            self.cleanup_request(rid)

    def clear_all(self):
        """Clear all permission state (for full server reset)."""
        self.pending_permissions.clear()
        self.permission_responses.clear()
        self.pending_messages.clear()
        self.timed_out_requests.clear()

    def generate_request_id(self) -> str:
        """Generate a unique request ID"""
        return str(uuid.uuid4())
