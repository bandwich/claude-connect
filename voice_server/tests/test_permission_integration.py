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
    async def test_timeout_returns_ask_behavior(self):
        """Test timeout returns fallback behavior"""
        resp = await self.client.post("/permission?timeout=0.1", json={
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"}
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["behavior"] == "ask"

    # --- Question endpoint tests (PreToolUse hook for AskUserQuestion) ---

    @unittest_run_loop
    async def test_question_endpoint_broadcasts_and_waits(self):
        """Test /question endpoint broadcasts question_prompt and waits for response"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_answers():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            assert data["type"] == "question_prompt"
            assert data["question"] == "Which database?"
            assert data["header"] == "Scope"
            assert len(data["options"]) == 2
            assert data["options"][0]["label"] == "PostgreSQL"
            assert data["options"][0]["description"] == "Fast relational DB"
            assert data["question_index"] == 0
            assert data["total_questions"] == 1

            self.permission_handler.resolve_request(data["request_id"], {
                "answer": "PostgreSQL"
            })

        asyncio.create_task(ios_answers())

        resp = await self.client.post("/question", json={
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [{
                    "question": "Which database?",
                    "header": "Scope",
                    "options": [
                        {"label": "PostgreSQL", "description": "Fast relational DB"},
                        {"label": "SQLite", "description": "Embedded, zero config"}
                    ],
                    "multiSelect": False
                }]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["hookSpecificOutput"]["hookEventName"] == "PreToolUse"
        assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "PostgreSQL" in result["hookSpecificOutput"]["permissionDecisionReason"]

    @unittest_run_loop
    async def test_question_endpoint_dismiss(self):
        """Test /question endpoint handles dismiss"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_dismisses():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            self.permission_handler.resolve_request(data["request_id"], {
                "dismissed": True
            })

        asyncio.create_task(ios_dismisses())

        resp = await self.client.post("/question", json={
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [{
                    "question": "Which color?",
                    "header": "Color",
                    "options": [
                        {"label": "Red", "description": "Warm"},
                        {"label": "Blue", "description": "Cool"}
                    ],
                    "multiSelect": False
                }]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "dismissed" in result["hookSpecificOutput"]["permissionDecisionReason"].lower()

    @unittest_run_loop
    async def test_question_endpoint_timeout(self):
        """Test /question endpoint times out and falls back"""
        resp = await self.client.post("/question?timeout=0.1", json={
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [{
                    "question": "Pick one",
                    "header": "Test",
                    "options": [],
                    "multiSelect": False
                }]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        assert result.get("fallback") == True

    @unittest_run_loop
    async def test_question_endpoint_free_text(self):
        """Test /question endpoint with no options (free text answer)"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_types():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            assert data["options"] == []
            self.permission_handler.resolve_request(data["request_id"], {
                "answer": "calculateTotal"
            })

        asyncio.create_task(ios_types())

        resp = await self.client.post("/question", json={
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [{
                    "question": "What should the function be named?",
                    "header": "Name",
                    "multiSelect": False
                }]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        assert "calculateTotal" in result["hookSpecificOutput"]["permissionDecisionReason"]

    @unittest_run_loop
    async def test_question_endpoint_multiple_questions(self):
        """Test /question endpoint with multiple questions sends one at a time"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_answers_both():
            await asyncio.sleep(0.05)
            first_call = mock_ios.send.call_args[0][0]
            data1 = json.loads(first_call)
            assert data1["question_index"] == 0
            assert data1["total_questions"] == 2
            self.permission_handler.resolve_request(data1["request_id"], {
                "answer": "PostgreSQL"
            })
            await asyncio.sleep(0.2)
            second_call = mock_ios.send.call_args[0][0]
            data2 = json.loads(second_call)
            assert data2["question_index"] == 1
            assert data2["total_questions"] == 2
            self.permission_handler.resolve_request(data2["request_id"], {
                "answer": "Yes"
            })

        asyncio.create_task(ios_answers_both())

        resp = await self.client.post("/question", json={
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    {
                        "question": "Which database?",
                        "header": "DB",
                        "options": [{"label": "PostgreSQL", "description": ""}],
                        "multiSelect": False
                    },
                    {
                        "question": "Enable caching?",
                        "header": "Cache",
                        "options": [{"label": "Yes", "description": ""}, {"label": "No", "description": ""}],
                        "multiSelect": False
                    }
                ]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        reason = result["hookSpecificOutput"]["permissionDecisionReason"]
        assert "PostgreSQL" in reason
        assert "Yes" in reason

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
