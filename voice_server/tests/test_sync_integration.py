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

        async def content_callback(response):
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
            missed_blocks, _ = handler.reconcile()
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

        async def content_callback(response):
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
            missed, _ = handler.reconcile()
            received_blocks.extend(missed)

        finally:
            observer.stop()
            observer.join()
            loop.close()

        # Should have both tool_use and tool_result
        types = [b.type for b in received_blocks]
        assert "tool_use" in types, f"Missing tool_use, got: {types}"
        assert "tool_result" in types, f"Missing tool_result, got: {types}"
