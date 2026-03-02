"""Integration tests for transcript sync reliability.

These tests simulate rapid transcript writes and verify
all lines are received by the handler.
"""
import pytest
import asyncio
import json
import time
import os
import threading

from watchdog.observers import Observer
from voice_server.ios_server import TranscriptHandler
from voice_server.content_models import AssistantResponse


class TestSyncReliability:
    """End-to-end sync reliability tests with real file watching"""

    def test_rapid_writes_all_received(self, tmp_path):
        """50 rapid transcript lines are all received via watchdog + reconciliation"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        received_texts = []

        async def content_callback(response, start_line=0):
            for block in response.content_blocks:
                if hasattr(block, 'text'):
                    received_texts.append(block.text)

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        observer = Observer()
        observer.schedule(handler, str(tmp_path))
        observer.start()

        try:
            time.sleep(0.5)

            # Write 50 lines rapidly (simulates Claude producing fast output)
            with open(transcript_file, "a") as f:
                for i in range(50):
                    msg = {
                        "type": "assistant",
                        "message": {
                            "role": "assistant",
                            "content": [{"type": "text", "text": f"Line {i}"}]
                        },
                        "timestamp": "2026-01-01T00:00:00Z"
                    }
                    f.write(json.dumps(msg) + "\n")
                    f.flush()

            # Wait for watchdog to process
            time.sleep(2.0)
            loop.run_until_complete(asyncio.sleep(0.1))

            # Run reconciliation to catch any lines watchdog missed
            missed_blocks, _, _ = handler.reconcile()
            if missed_blocks:
                for block in missed_blocks:
                    if hasattr(block, 'text'):
                        received_texts.append(block.text)

        finally:
            observer.stop()
            observer.join()
            loop.close()

        # Verify all 50 lines were received (via watchdog + reconciliation)
        expected = {f"Line {i}" for i in range(50)}
        actual = set(received_texts)
        missing = expected - actual
        assert not missing, f"Missing {len(missing)} lines: {sorted(missing)[:5]}..."

    def test_tool_use_and_result_both_received(self, tmp_path):
        """Tool use block followed by tool result are both received"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        received_blocks = []

        async def content_callback(response, start_line=0):
            received_blocks.extend(response.content_blocks)

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        observer = Observer()
        observer.schedule(handler, str(tmp_path))
        observer.start()

        try:
            time.sleep(0.5)

            # Write tool_use
            tool_use_msg = {
                "type": "assistant",
                "message": {
                    "role": "assistant",
                    "content": [{
                        "type": "tool_use",
                        "id": "tool_123",
                        "name": "AskUserQuestion",
                        "input": {"questions": [{"question": "Which option?"}]}
                    }]
                },
                "timestamp": "2026-01-01T00:00:00Z"
            }
            with open(transcript_file, "a") as f:
                f.write(json.dumps(tool_use_msg) + "\n")
                f.flush()

            time.sleep(0.5)

            # Write tool_result
            tool_result_msg = {
                "type": "user",
                "message": {
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": "tool_123",
                        "content": "Option A selected"
                    }]
                },
                "timestamp": "2026-01-01T00:00:01Z"
            }
            with open(transcript_file, "a") as f:
                f.write(json.dumps(tool_result_msg) + "\n")
                f.flush()

            time.sleep(1.0)
            loop.run_until_complete(asyncio.sleep(0.1))

            # Reconcile to catch any missed
            missed, _, _ = handler.reconcile()
            received_blocks.extend(missed)

        finally:
            observer.stop()
            observer.join()
            loop.close()

        # Should have both tool_use and tool_result
        types = [b.type for b in received_blocks]
        assert "tool_use" in types, f"Missing tool_use, got: {types}"
        assert "tool_result" in types, f"Missing tool_result, got: {types}"


class TestSequenceNumbers:
    """Tests for sequence number tracking on messages"""

    def test_extract_new_content_returns_line_numbers(self, tmp_path):
        """extract_new_content_with_seq returns the starting line number of new content"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        async def content_callback(response, start_line=0):
            pass

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        # Write 3 lines
        with open(transcript_file, "a") as f:
            for i in range(3):
                msg = {
                    "type": "assistant",
                    "message": {"role": "assistant", "content": [{"type": "text", "text": f"Msg {i}"}]},
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(msg) + "\n")

        blocks, user_texts, start_line = handler.extract_new_content_with_seq(str(transcript_file))
        assert start_line == 0  # Started from line 0
        assert len(blocks) == 3
        assert handler.processed_line_count == 3

        # Write 2 more
        with open(transcript_file, "a") as f:
            for i in range(2):
                msg = {
                    "type": "assistant",
                    "message": {"role": "assistant", "content": [{"type": "text", "text": f"Msg {3+i}"}]},
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(msg) + "\n")

        blocks2, _, start_line2 = handler.extract_new_content_with_seq(str(transcript_file))
        assert start_line2 == 3  # Started from line 3
        assert len(blocks2) == 2

        loop.close()


class TestUserMessageSync:
    """Tests that user messages in the transcript trigger user_callback"""

    def test_user_message_triggers_callback(self, tmp_path):
        """User message appended to transcript fires user_callback with correct text"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        received_user = []

        async def content_callback(response, start_line=0):
            pass

        async def audio_callback(text):
            pass

        async def user_callback(text, seq=0):
            received_user.append((text, seq))

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None,
            user_callback=user_callback
        )
        handler.set_session_file(str(transcript_file))

        observer = Observer()
        observer.schedule(handler, str(tmp_path))
        observer.start()

        try:
            time.sleep(0.5)

            # Write an assistant message first, then a user message
            with open(transcript_file, "a") as f:
                assistant_msg = {
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "content": [{"type": "text", "text": "Hello, how can I help?"}]
                    },
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(assistant_msg) + "\n")
                f.flush()

                time.sleep(0.3)

                user_msg = {
                    "type": "user",
                    "message": {
                        "role": "user",
                        "content": [{"type": "text", "text": "Looks good to me"}]
                    },
                    "timestamp": "2026-01-01T00:00:01Z"
                }
                f.write(json.dumps(user_msg) + "\n")
                f.flush()

            time.sleep(2.0)
            loop.run_until_complete(asyncio.sleep(0.1))

            # Reconcile to catch anything watchdog missed
            missed_blocks, missed_users, _ = handler.reconcile()
            for text in missed_users:
                received_user.append((text, 0))

        finally:
            observer.stop()
            observer.join()
            loop.close()

        assert len(received_user) >= 1, f"Expected user callback, got {received_user}"
        assert any("Looks good to me" in text for text, _ in received_user), \
            f"Expected 'Looks good to me' in {received_user}"

    def test_user_message_after_permission_resolved(self, tmp_path):
        """User messages still sync after a permission_resolved event"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        received_user = []
        received_content = []

        async def content_callback(response, start_line=0):
            for block in response.content_blocks:
                if hasattr(block, 'text'):
                    received_content.append(block.text)

        async def audio_callback(text):
            pass

        async def user_callback(text, seq=0):
            received_user.append(text)

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None,
            user_callback=user_callback
        )
        handler.set_session_file(str(transcript_file))

        observer = Observer()
        observer.schedule(handler, str(tmp_path))
        observer.start()

        try:
            time.sleep(0.5)

            # Phase 1: Normal assistant message
            with open(transcript_file, "a") as f:
                f.write(json.dumps({
                    "message": {"role": "assistant", "content": [{"type": "text", "text": "Before permission"}]},
                    "timestamp": "2026-01-01T00:00:00Z"
                }) + "\n")
                f.flush()

            time.sleep(1.0)
            loop.run_until_complete(asyncio.sleep(0.1))

            # Phase 2: Write more messages after a gap (simulates permission_resolved)
            with open(transcript_file, "a") as f:
                f.write(json.dumps({
                    "message": {"role": "assistant", "content": [{"type": "text", "text": "After permission"}]},
                    "timestamp": "2026-01-01T00:00:02Z"
                }) + "\n")
                f.flush()

                time.sleep(0.3)

                f.write(json.dumps({
                    "message": {"role": "user", "content": [{"type": "text", "text": "User after permission"}]},
                    "timestamp": "2026-01-01T00:00:03Z"
                }) + "\n")
                f.flush()

            time.sleep(2.0)
            loop.run_until_complete(asyncio.sleep(0.1))

            # Reconcile
            missed_blocks, missed_users, _ = handler.reconcile()
            for block in missed_blocks:
                if hasattr(block, 'text'):
                    received_content.append(block.text)
            received_user.extend(missed_users)

        finally:
            observer.stop()
            observer.join()
            loop.close()

        assert "Before permission" in received_content, f"Missing pre-permission content: {received_content}"
        assert "After permission" in received_content, f"Missing post-permission content: {received_content}"
        assert any("User after permission" in t for t in received_user), \
            f"Missing user message after permission: {received_user}"

    def test_reconciliation_catches_missed_user_message(self, tmp_path):
        """Reconciliation finds user messages that watchdog missed"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        async def content_callback(response, start_line=0):
            pass

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        # DON'T start a watchdog — write lines that will only be found by reconciliation
        with open(transcript_file, "a") as f:
            f.write(json.dumps({
                "message": {"role": "assistant", "content": [{"type": "text", "text": "Hello"}]},
                "timestamp": "2026-01-01T00:00:00Z"
            }) + "\n")
            f.write(json.dumps({
                "message": {"role": "user", "content": [{"type": "text", "text": "Missed user msg"}]},
                "timestamp": "2026-01-01T00:00:01Z"
            }) + "\n")

        missed_blocks, missed_users, start_line = handler.reconcile()

        loop.close()

        assert start_line == 0
        assert len(missed_blocks) >= 1, "Should have found assistant block"
        assert "Missed user msg" in missed_users, f"Should have found user message, got: {missed_users}"


class TestResyncHandler:
    """Tests for the server-side resync message handler"""

    @pytest.mark.asyncio
    async def test_resync_replays_from_sequence(self, tmp_path):
        """resync request replays all content from the given sequence number"""
        from voice_server.ios_server import VoiceServer
        from unittest.mock import AsyncMock, patch

        # Create transcript with 10 lines
        transcript_file = tmp_path / "session.jsonl"
        with open(transcript_file, "w") as f:
            for i in range(10):
                msg = {
                    "type": "assistant",
                    "message": {"role": "assistant", "content": [{"type": "text", "text": f"Msg {i}"}]},
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(msg) + "\n")

        # Patch VoiceServer.__init__ to avoid side effects (tmux, http server, etc.)
        with patch.object(VoiceServer, '__init__', lambda self: None):
            server = VoiceServer()
            server.transcript_path = str(transcript_file)

        # Mock websocket
        ws = AsyncMock()
        sent_messages = []
        async def capture_send(data):
            sent_messages.append(json.loads(data))
        ws.send = capture_send

        # Request resync from line 7 (should get lines 7, 8, 9)
        await server.handle_resync(ws, {"from_seq": 7})

        # Should have received messages with content from lines 7-9
        assert len(sent_messages) >= 1
        resync_msg = sent_messages[0]
        assert resync_msg["type"] == "resync_response"
        assert resync_msg["from_seq"] == 7
        assert len(resync_msg["messages"]) == 3  # lines 7, 8, 9
