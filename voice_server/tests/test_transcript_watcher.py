# voice_server/tests/test_transcript_watcher.py
"""
Tests for TranscriptHandler file watching - uses REAL file operations.
"""
import pytest
import asyncio
import json
import time
import os
import sys
import threading

from watchdog.observers import Observer
from voice_server.ios_server import TranscriptHandler


class TestTranscriptHandlerRealFiles:
    """Tests for TranscriptHandler using real file operations"""

    def test_file_watcher_detects_modifications(self, tmp_path):
        """File watcher triggers callback when transcript file is modified"""
        transcript_file = tmp_path / "test_session.jsonl"
        transcript_file.write_text("")

        audio_received = []

        async def content_callback(response):
            pass

        async def audio_callback(text):
            audio_received.append(text)

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

            assistant_msg = {
                "type": "assistant",
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "Hello from test"}]
                },
                "timestamp": "2026-01-01T00:00:00Z"
            }
            with open(transcript_file, "a") as f:
                f.write(json.dumps(assistant_msg) + "\n")
                f.flush()

            time.sleep(1.0)
            loop.run_until_complete(asyncio.sleep(0.1))

        finally:
            observer.stop()
            observer.join()
            loop.close()

        assert len(audio_received) > 0, "Callback was not triggered"
        assert "Hello from test" in audio_received[0]

    def test_file_watcher_with_symlinked_path(self, tmp_path):
        """File watcher works when expected_session_file uses symlinked path"""
        actual_dir = tmp_path / "actual"
        actual_dir.mkdir()
        transcript_file = actual_dir / "session.jsonl"
        transcript_file.write_text("")

        symlink_dir = tmp_path / "symlink"
        symlink_dir.symlink_to(actual_dir)
        symlinked_file = symlink_dir / "session.jsonl"

        audio_received = []

        async def content_callback(response):
            pass

        async def audio_callback(text):
            audio_received.append(text)

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(symlinked_file))

        observer = Observer()
        observer.schedule(handler, str(actual_dir))
        observer.start()

        try:
            time.sleep(0.5)

            assistant_msg = {
                "type": "assistant",
                "message": {
                    "role": "assistant",
                    "content": [{"type": "text", "text": "Symlink test"}]
                },
                "timestamp": "2026-01-01T00:00:00Z"
            }
            with open(transcript_file, "a") as f:
                f.write(json.dumps(assistant_msg) + "\n")
                f.flush()

            time.sleep(1.0)
            loop.run_until_complete(asyncio.sleep(0.1))

        finally:
            observer.stop()
            observer.join()
            loop.close()

        assert len(audio_received) > 0, "Path comparison fails with symlinks"

    def test_file_watcher_ignores_other_files(self, tmp_path):
        """File watcher only triggers for the expected session file"""
        expected_file = tmp_path / "expected.jsonl"
        other_file = tmp_path / "other.jsonl"
        expected_file.write_text("")
        other_file.write_text("")

        audio_received = []

        async def content_callback(response):
            pass

        async def audio_callback(text):
            audio_received.append(text)

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(expected_file))

        observer = Observer()
        observer.schedule(handler, str(tmp_path))
        observer.start()

        try:
            time.sleep(0.5)

            msg = {
                "type": "assistant",
                "message": {"role": "assistant", "content": "Should be ignored"},
                "timestamp": "2026-01-01T00:00:00Z"
            }
            with open(other_file, "a") as f:
                f.write(json.dumps(msg) + "\n")
                f.flush()

            time.sleep(0.5)

            msg2 = {
                "type": "assistant",
                "message": {"role": "assistant", "content": "Should be received"},
                "timestamp": "2026-01-01T00:00:00Z"
            }
            with open(expected_file, "a") as f:
                f.write(json.dumps(msg2) + "\n")
                f.flush()

            time.sleep(1.0)
            loop.run_until_complete(asyncio.sleep(0.1))

        finally:
            observer.stop()
            observer.join()
            loop.close()

        assert len(audio_received) == 1
        assert "Should be received" in audio_received[0]

    def test_path_comparison_uses_realpath(self, tmp_path):
        """Path comparison must use os.path.realpath to handle symlinks and path variations.

        On macOS, /tmp is a symlink to /private/tmp. The watchdog library reports
        event.src_path using the resolved path, but expected_session_file may use
        the unresolved path. Without realpath normalization, the comparison fails
        and file changes are ignored.
        """
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        # Get the path as the user would set it (unresolved)
        user_path = str(transcript_file)
        # Get the path as watchdog reports it (resolved)
        watchdog_path = os.path.realpath(str(transcript_file))

        audio_received = []

        async def content_callback(response):
            pass

        async def audio_callback(text):
            audio_received.append(text)

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(user_path)

        observer = Observer()
        observer.schedule(handler, str(tmp_path))
        observer.start()

        try:
            time.sleep(0.5)

            msg = {
                "type": "assistant",
                "message": {"role": "assistant", "content": "Path test"},
                "timestamp": "2026-01-01T00:00:00Z"
            }
            with open(transcript_file, "a") as f:
                f.write(json.dumps(msg) + "\n")
                f.flush()

            time.sleep(1.0)
            loop.run_until_complete(asyncio.sleep(0.1))

        finally:
            observer.stop()
            observer.join()
            loop.close()

        assert len(audio_received) > 0, \
            f"Path comparison bug: expected_session_file={user_path} but watchdog reports {watchdog_path}"


class TestTranscriptHandlerThreadSafety:
    """Tests for thread-safe access to processed_line_count and expected_session_file"""

    def test_concurrent_set_session_and_on_modified(self, tmp_path):
        """set_session_file and on_modified can run concurrently without corruption"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        content_received = []

        async def content_callback(response):
            content_received.append(response)

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

        # Write 100 lines to the file
        with open(transcript_file, "a") as f:
            for i in range(100):
                msg = {
                    "type": "assistant",
                    "message": {"role": "assistant", "content": f"Message {i}"},
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(msg) + "\n")

        # Simulate concurrent access: on_modified from watchdog thread
        # while set_session_file runs from main thread
        errors = []

        class FakeEvent:
            is_directory = False
            src_path = str(transcript_file)

        def call_on_modified():
            try:
                for _ in range(50):
                    handler.on_modified(FakeEvent())
            except Exception as e:
                errors.append(e)

        def call_set_session():
            try:
                for _ in range(50):
                    handler.set_session_file(str(transcript_file))
            except Exception as e:
                errors.append(e)

        t1 = threading.Thread(target=call_on_modified)
        t2 = threading.Thread(target=call_set_session)
        t1.start()
        t2.start()
        t1.join()
        t2.join()

        loop.close()
        assert not errors, f"Concurrent access raised: {errors}"
        # Verify handler has a lock attribute
        assert hasattr(handler, '_lock')
