# voice_server/tests/test_permission_integration.py
"""Integration tests for permission flow"""

import pytest
import asyncio
import json
from unittest.mock import AsyncMock
import sys
import os

from voice_server.permission_handler import PermissionHandler
from voice_server.http_server import create_http_app
from aiohttp.test_utils import AioHTTPTestCase, unittest_run_loop


class TestPermissionIntegration(AioHTTPTestCase):
    """End-to-end integration tests"""

    async def get_application(self):
        self.permission_handler = PermissionHandler()
        return create_http_app(self.permission_handler)

    @unittest_run_loop
    async def test_full_permission_flow_allow(self):
        """Test complete flow: hook -> server -> iOS -> response"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_responds():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            request_id = data["request_id"]

            self.permission_handler.resolve_request(request_id, {
                "decision": "allow"
            })

        asyncio.create_task(ios_responds())

        resp = await self.client.post("/permission", json={
            "tool_name": "Bash",
            "tool_input": {"command": "npm test"}
        })

        assert resp.status == 200
        result = await resp.json()
        # Verify Claude Code hook format
        assert "hookSpecificOutput" in result
        assert result["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
        assert result["hookSpecificOutput"]["decision"]["behavior"] == "allow"

    @unittest_run_loop
    async def test_full_permission_flow_deny(self):
        """Test complete flow with deny response"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_denies():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            self.permission_handler.resolve_request(data["request_id"], {
                "decision": "deny"
            })

        asyncio.create_task(ios_denies())

        resp = await self.client.post("/permission", json={
            "tool_name": "Bash",
            "tool_input": {"command": "rm -rf /"}
        })

        assert resp.status == 200
        result = await resp.json()
        # Verify Claude Code hook format
        assert "hookSpecificOutput" in result
        assert result["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
        assert result["hookSpecificOutput"]["decision"]["behavior"] == "deny"

    @unittest_run_loop
    async def test_question_with_text_input(self):
        """Test AskUserQuestion flow with text input"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_answers():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            self.permission_handler.resolve_request(data["request_id"], {
                "decision": "allow",
                "input": "calculateTotal"
            })

        asyncio.create_task(ios_answers())

        resp = await self.client.post("/permission", json={
            "tool_name": "AskUserQuestion",
            "question": {"text": "What should the function be named?"}
        })

        assert resp.status == 200
        result = await resp.json()
        # Verify Claude Code hook format (input is handled internally, not in hook output)
        assert "hookSpecificOutput" in result
        assert result["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
        assert result["hookSpecificOutput"]["decision"]["behavior"] == "allow"

    @unittest_run_loop
    async def test_question_with_option_selection(self):
        """Test AskUserQuestion flow with option selection"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_selects():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            self.permission_handler.resolve_request(data["request_id"], {
                "decision": "allow",
                "selected_option": 1
            })

        asyncio.create_task(ios_selects())

        resp = await self.client.post("/permission", json={
            "tool_name": "AskUserQuestion",
            "question": {
                "text": "Which database?",
                "options": ["PostgreSQL", "SQLite", "MongoDB"]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        # Verify Claude Code hook format (selected_option is handled internally, not in hook output)
        assert "hookSpecificOutput" in result
        assert result["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
        assert result["hookSpecificOutput"]["decision"]["behavior"] == "allow"

    @unittest_run_loop
    async def test_timeout_returns_ask_behavior(self):
        """Test timeout returns fallback behavior"""
        resp = await self.client.post("/permission?timeout=0.1", json={
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"}
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["behavior"] == "ask"

    @unittest_run_loop
    async def test_edit_permission_with_context(self):
        """Test Edit permission includes context in broadcast"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_approves():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)

            # Verify context was included
            assert data["prompt_type"] == "edit"
            assert data["context"]["file_path"] == "/src/file.ts"

            self.permission_handler.resolve_request(data["request_id"], {
                "decision": "allow"
            })

        asyncio.create_task(ios_approves())

        resp = await self.client.post("/permission", json={
            "tool_name": "Edit",
            "context": {
                "file_path": "/src/file.ts",
                "old_content": "const x = 1;",
                "new_content": "const x = 2;"
            }
        })

        assert resp.status == 200
        result = await resp.json()
        # Verify Claude Code hook format
        assert "hookSpecificOutput" in result
        assert result["hookSpecificOutput"]["hookEventName"] == "PermissionRequest"
        assert result["hookSpecificOutput"]["decision"]["behavior"] == "allow"
