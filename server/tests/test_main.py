#!/usr/bin/env python3
"""
Tests for main.py - WebSocket Server
"""

import pytest
import asyncio
import json
import tempfile
import os
import time
import base64
from unittest.mock import Mock, patch, MagicMock, AsyncMock, call
import sys
import numpy as np

from server.main import ConnectServer, TranscriptHandler


class TestTranscriptHandler:
    """Tests for TranscriptHandler class"""

    def test_transcript_handler_initialization(self):
        """Test handler initializes correctly"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(None, callback, loop, server)

        assert handler.audio_callback == callback
        assert handler.loop == loop
        assert handler.server == server
        assert handler.processed_line_count == 0
        assert handler.expected_session_file is None
        assert handler.last_modified == 0

    def test_on_modified_non_jsonl_files(self):
        """Test ignores non-.jsonl files"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(None, callback, loop, server)

        event = Mock()
        event.is_directory = False
        event.src_path = "/path/to/file.txt"

        handler.on_modified(event)

        callback.assert_not_called()

    def test_on_modified_directory_events(self):
        """Test ignores directory events"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(None, callback, loop, server)

        event = Mock()
        event.is_directory = True
        event.src_path = "/path/to/directory.jsonl"

        handler.on_modified(event)

        callback.assert_not_called()

    def test_on_modified_ignores_agent_files(self):
        """Test ignores sub-agent transcript files (agent-*.jsonl)"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(None, callback, loop, server)

        event = Mock()
        event.is_directory = False
        event.src_path = "/path/to/projects/agent-a2496e3.jsonl"

        handler.on_modified(event)

        callback.assert_not_called()

    def test_on_modified_duplicate_detection(self):
        """Test duplicate message filtering"""
        callback = AsyncMock()
        loop = Mock()
        server = Mock()
        server.last_voice_input = "User question"
        handler = TranscriptHandler(None, callback, loop, server)
        handler.last_message = "Same message"

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({"role": "user", "content": "User question"}) + "\n")
            f.write(json.dumps({"role": "assistant", "content": "Same message"}) + "\n")
            filepath = f.name

        try:
            event = Mock()
            event.is_directory = False
            event.src_path = filepath

            # First call with same message - should be filtered
            handler.on_modified(event)

            # Should not be called since last_message is already set
            callback.assert_not_called()
        finally:
            os.unlink(filepath)

    def test_on_modified_no_idle_sent_for_thinking_only_content(self):
        """When content has only thinking blocks (no TTS text), no idle is sent.
        The pane poll is the source of truth for activity state."""
        import asyncio as asyncio_module

        content_callback = AsyncMock()
        audio_callback = AsyncMock()
        loop = Mock()
        server = Mock()
        server.clients = {Mock()}
        server.send_idle_to_all_clients = AsyncMock()
        server.broadcast_message = AsyncMock()
        server.active_session_id = "test-session"
        handler = TranscriptHandler(content_callback, audio_callback, loop, server)

        # Create file with only thinking block (no text for TTS)
        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({
                "role": "assistant",
                "content": [{"type": "thinking", "thinking": "Let me think about this...", "signature": "test"}]
            }) + "\n")
            filepath = f.name

        try:
            handler.expected_session_file = filepath
            event = Mock()
            event.is_directory = False
            event.src_path = filepath

            with patch.object(asyncio_module, 'run_coroutine_threadsafe') as mock_run:
                handler.on_modified(event)

                # Close coroutines to avoid warnings
                for call in mock_run.call_args_list:
                    call[0][0].close()
                # 2 calls expected: content_callback + context broadcast (no idle)
                assert mock_run.call_count == 2, \
                    f"Expected 2 calls (content + context), got {mock_run.call_count}"
        finally:
            os.unlink(filepath)


class TestConnectServer:
    """Tests for ConnectServer class"""

    def test_server_initialization(self):
        """Test server initializes correctly"""
        server = ConnectServer()

        assert server.clients == set()
        assert server.transcript_path is None
        assert server.observer is None

    def test_find_transcript_path_no_files(self):
        """Test when no transcripts exist"""
        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            with patch('server.main.TRANSCRIPT_DIR', tmpdir):
                result = server.find_transcript_path()
                assert result is None

    def test_find_transcript_path(self):
        """Test finding most recent transcript file"""
        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            # Create test files
            file1 = os.path.join(tmpdir, "old.jsonl")
            file2 = os.path.join(tmpdir, "new.jsonl")

            with open(file1, 'w') as f:
                f.write("{}\n")
            time.sleep(0.01)
            with open(file2, 'w') as f:
                f.write("{}\n")

            with patch('server.main.TRANSCRIPT_DIR', tmpdir):
                result = server.find_transcript_path()
                assert result == file2  # Most recent

    def test_find_transcript_path_multiple_files(self):
        """Test selects most recent when multiple exist"""
        server = ConnectServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            subdir = os.path.join(tmpdir, "project")
            os.makedirs(subdir)

            file1 = os.path.join(tmpdir, "file1.jsonl")
            file2 = os.path.join(subdir, "file2.jsonl")

            with open(file1, 'w') as f:
                f.write("{}\n")
            time.sleep(0.01)
            with open(file2, 'w') as f:
                f.write("{}\n")

            with patch('server.main.TRANSCRIPT_DIR', tmpdir):
                result = server.find_transcript_path()
                assert result == file2

    @pytest.mark.asyncio
    async def test_send_status(self):
        """Test status message format"""
        server = ConnectServer()
        websocket = AsyncMock()

        await server.send_status(websocket, "idle", "Ready")

        websocket.send.assert_called_once()
        args = websocket.send.call_args[0][0]
        data = json.loads(args)

        assert data["type"] == "status"
        assert data["state"] == "idle"
        assert data["message"] == "Ready"
        assert "timestamp" in data

    @pytest.mark.asyncio
    async def test_send_to_terminal(self):
        """Test tmux send_input integration (mocked)"""
        server = ConnectServer()

        server.tmux = Mock()
        server._active_tmux_session = "claude-connect_test"
        server.tmux.send_input = Mock(return_value=True)

        await server.send_to_terminal("Test message")

        # Should call tmux send_input with session name and text
        server.tmux.send_input.assert_called_once_with("claude-connect_test", "Test message")

    @pytest.mark.asyncio
    async def test_stream_audio(self):
        """Test audio streaming with chunking"""
        server = ConnectServer()
        websocket = AsyncMock()
        cancel_event = asyncio.Event()

        wav_bytes = b'RIFF' + b'\x00' * 20000  # 20KB of fake WAV data
        result = await server.stream_audio(websocket, wav_bytes, cancel_event)

        assert result is True
        # Verify chunks were sent
        assert websocket.send.call_count > 0

    @pytest.mark.asyncio
    async def test_stream_audio_chunk_format(self):
        """Verify chunk message structure"""
        server = ConnectServer()
        websocket = AsyncMock()
        cancel_event = asyncio.Event()

        wav_bytes = b'TEST_WAV_DATA'
        await server.stream_audio(websocket, wav_bytes, cancel_event)

        # Get first chunk
        first_call = websocket.send.call_args_list[0][0][0]
        chunk_data = json.loads(first_call)

        assert chunk_data["type"] == "audio_chunk"
        assert chunk_data["format"] == "wav"
        assert chunk_data["sample_rate"] == 24000
        assert "chunk_index" in chunk_data
        assert "total_chunks" in chunk_data
        assert "data" in chunk_data

    @pytest.mark.asyncio
    async def test_stream_audio_base64_encoding(self):
        """Verify data is valid base64"""
        server = ConnectServer()
        websocket = AsyncMock()
        cancel_event = asyncio.Event()

        wav_bytes = b'TEST_DATA'
        await server.stream_audio(websocket, wav_bytes, cancel_event)

        first_call = websocket.send.call_args_list[0][0][0]
        chunk_data = json.loads(first_call)

        # Should be able to decode base64
        decoded = base64.b64decode(chunk_data["data"])
        assert isinstance(decoded, bytes)

    @pytest.mark.asyncio
    async def test_handle_voice_input(self):
        """Test voice input processing"""
        server = ConnectServer()
        websocket = AsyncMock()
        server.clients = {websocket}  # Add websocket to clients

        with patch.object(server, 'send_to_terminal', new_callable=AsyncMock) as mock_send, \
             patch.object(server, 'send_status', new_callable=AsyncMock) as mock_status:

            data = {"text": "Hello Claude"}
            await server.handle_voice_input(websocket, data)

            mock_status.assert_called_once_with(websocket, "processing", "Sending to Claude...")
            mock_send.assert_called_once_with("Hello Claude")

    @pytest.mark.asyncio
    async def test_handle_voice_input_empty_text(self):
        """Test with empty/whitespace text"""
        server = ConnectServer()
        websocket = AsyncMock()

        with patch.object(server, 'send_to_terminal', new_callable=AsyncMock) as mock_send:
            data = {"text": "   "}
            await server.handle_voice_input(websocket, data)

            mock_send.assert_not_called()

    @pytest.mark.asyncio
    async def test_handle_voice_input_status_update(self):
        """Test status messages are sent"""
        server = ConnectServer()
        websocket = AsyncMock()
        server.clients = {websocket}  # Add websocket to clients

        with patch.object(server, 'send_to_terminal', new_callable=AsyncMock), \
             patch.object(server, 'send_status', new_callable=AsyncMock) as mock_status:

            data = {"text": "Test"}
            await server.handle_voice_input(websocket, data)

            mock_status.assert_called_with(websocket, "processing", "Sending to Claude...")

    @pytest.mark.asyncio
    async def test_handle_claude_response(self):
        """Test Claude response queues text for TTS"""
        server = ConnectServer()
        server.tts_queue = asyncio.Queue()

        await server.handle_claude_response("Hello from Claude")

        # Should queue text instead of streaming directly
        assert not server.tts_queue.empty()
        text = server.tts_queue.get_nowait()
        assert text == "Hello from Claude"

    @pytest.mark.asyncio
    async def test_handle_claude_response_multiple_clients(self):
        """Test multiple responses are queued"""
        server = ConnectServer()
        server.tts_queue = asyncio.Queue()

        await server.handle_claude_response("First message")
        await server.handle_claude_response("Second message")

        # Both should be queued
        assert server.tts_queue.qsize() == 2
        assert server.tts_queue.get_nowait() == "First message"
        assert server.tts_queue.get_nowait() == "Second message"

    @pytest.mark.asyncio
    async def test_handle_message_valid_json(self):
        """Test parsing valid voice_input message"""
        server = ConnectServer()
        websocket = AsyncMock()

        with patch.object(server, 'handle_voice_input', new_callable=AsyncMock) as mock_handle:
            message = json.dumps({"type": "voice_input", "text": "Hello"})
            await server.handle_message(websocket, message)

            mock_handle.assert_called_once_with(websocket, {"type": "voice_input", "text": "Hello"})

    @pytest.mark.asyncio
    async def test_handle_message_invalid_json(self):
        """Test error handling for malformed JSON"""
        server = ConnectServer()
        websocket = AsyncMock()

        # Should not raise exception
        await server.handle_message(websocket, "invalid json {")

    @pytest.mark.asyncio
    async def test_handle_message_wrong_type(self):
        """Test ignores non-voice_input messages"""
        server = ConnectServer()
        websocket = AsyncMock()

        with patch.object(server, 'handle_voice_input', new_callable=AsyncMock) as mock_handle:
            message = json.dumps({"type": "other_type", "data": "test"})
            await server.handle_message(websocket, message)

            mock_handle.assert_not_called()

    @pytest.mark.asyncio
    async def test_handle_client_connection(self):
        """Test client connection lifecycle"""
        server = ConnectServer()
        websocket = AsyncMock()
        websocket.__aiter__.return_value = []  # No messages

        with patch.object(server, 'send_status', new_callable=AsyncMock) as mock_status:
            await server.handle_client(websocket, "/")

            # Should send initial status
            mock_status.assert_called_once_with(websocket, "idle", "Connected")

    @pytest.mark.asyncio
    async def test_handle_client_disconnection(self):
        """Test client cleanup on disconnect"""
        server = ConnectServer()
        websocket = AsyncMock()
        websocket.__aiter__.return_value = []

        await server.handle_client(websocket, "/")

        # Client should be removed from set
        assert websocket not in server.clients

    @pytest.mark.asyncio
    async def test_active_session_preserved_on_client_reconnect(self):
        """Client reconnection should preserve active_session_id so app receives current state"""
        server = ConnectServer()

        # Mock tmux controller
        server.tmux = MagicMock()
        server.tmux.session_exists.return_value = True

        # Simulate server has an active session
        server.active_session_id = "active-session-123"

        # Create mock websocket (simulates reconnecting client)
        mock_ws = AsyncMock()
        mock_ws.send = AsyncMock()
        mock_ws.__aiter__.return_value = []  # No messages, connection ends immediately

        # Connect client
        await server.handle_client(mock_ws, "/")

        # Find the connection_status message that was sent
        connection_status_sent = None
        for call in mock_ws.send.call_args_list:
            msg = json.loads(call[0][0])
            if msg.get("type") == "connection_status":
                connection_status_sent = msg
                break

        assert connection_status_sent is not None, "Should send connection_status on connect"
        assert connection_status_sent["active_session_id"] == "active-session-123", \
            "Should preserve active session across reconnects"

    @pytest.mark.asyncio
    async def test_usage_request_does_not_block_message_loop(self):
        """usage_request should not block other messages from being processed."""
        server = ConnectServer()

        # Create a slow usage handler that takes time
        usage_started = asyncio.Event()
        usage_can_finish = asyncio.Event()

        async def slow_usage_handler(websocket):
            usage_started.set()
            await usage_can_finish.wait()

        server.handle_usage_request = slow_usage_handler

        mock_ws = AsyncMock()

        usage_msg = json.dumps({"type": "usage_request"})

        # handle_message should return quickly (not block on slow usage handler)
        # If it blocks, this will timeout
        try:
            await asyncio.wait_for(
                server.handle_message(mock_ws, usage_msg),
                timeout=1.0
            )
        except asyncio.TimeoutError:
            usage_can_finish.set()  # Clean up
            pytest.fail("handle_message blocked on usage_request - should return immediately")

        # Usage handler should have started as a background task
        await asyncio.sleep(0.05)
        assert usage_started.is_set(), "Usage handler should have started"

        # Clean up background task
        usage_can_finish.set()
        await asyncio.sleep(0.05)


class TestTranscriptHandlerGlobalTracking:
    """Tests for line-based tracking (not voice-input-gated)"""

    @pytest.mark.asyncio
    async def test_processes_content_without_voice_input(self, tmp_path):
        """Transcript changes should be processed even without last_voice_input"""
        from server.main import TranscriptHandler, ConnectServer

        server = ConnectServer()
        server.last_voice_input = None  # The bug condition

        content_received = []
        async def mock_content_callback(response, start_line=0):
            content_received.append(response)

        async def mock_audio_callback(text):
            pass

        loop = asyncio.get_event_loop()
        handler = TranscriptHandler(
            mock_content_callback,
            mock_audio_callback,
            loop,
            server
        )

        transcript = tmp_path / "test.jsonl"
        transcript.write_text(
            '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}]}}\n'
        )

        class MockEvent:
            is_directory = False
            src_path = str(transcript)

        handler.on_modified(MockEvent())
        await asyncio.sleep(0.2)

        assert len(content_received) > 0, "Should process content without voice input"

    @pytest.mark.asyncio
    async def test_tracks_line_position_across_calls(self, tmp_path):
        """Handler should track processed lines and only send new content"""
        from server.main import TranscriptHandler, ConnectServer

        server = ConnectServer()
        server.last_voice_input = None

        content_received = []
        async def mock_content_callback(response, start_line=0):
            content_received.append(response)

        async def mock_audio_callback(text):
            pass

        loop = asyncio.get_event_loop()
        handler = TranscriptHandler(
            mock_content_callback,
            mock_audio_callback,
            loop,
            server
        )

        transcript = tmp_path / "test.jsonl"
        # First write
        transcript.write_text(
            '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"First message"}]}}\n'
        )

        class MockEvent:
            is_directory = False
            src_path = str(transcript)

        handler.on_modified(MockEvent())
        await asyncio.sleep(0.2)

        first_count = len(content_received)
        assert first_count > 0, "Should receive first message"

        # Append second message
        with open(transcript, 'a') as f:
            f.write('{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Second message"}]}}\n')

        handler.on_modified(MockEvent())
        await asyncio.sleep(0.2)

        # Should have received both messages but as separate calls
        assert len(content_received) > first_count, "Should receive second message"

    @pytest.mark.asyncio
    async def test_ignores_events_from_wrong_session_file(self, tmp_path):
        """Handler should only process events from expected_session_file"""
        from server.main import TranscriptHandler, ConnectServer

        server = ConnectServer()
        server.last_voice_input = None

        content_received = []
        async def mock_content_callback(response, start_line=0):
            content_received.append(response)

        async def mock_audio_callback(text):
            pass

        loop = asyncio.get_event_loop()
        handler = TranscriptHandler(
            mock_content_callback,
            mock_audio_callback,
            loop,
            server
        )

        # Set up expected session file
        transcript1 = tmp_path / "session1.jsonl"
        transcript1.write_text("")  # Empty initially
        handler.set_session_file(str(transcript1))

        # Event from different file should be ignored
        transcript2 = tmp_path / "session2.jsonl"
        transcript2.write_text(
            '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Wrong File"}]}}\n'
        )

        class MockEvent2:
            is_directory = False
            src_path = str(transcript2)

        handler.on_modified(MockEvent2())
        await asyncio.sleep(0.2)

        # Should NOT have received content from wrong file
        assert len(content_received) == 0, "Should ignore events from non-expected file"

        # Now add content to expected file and verify it IS processed
        transcript1.write_text(
            '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Correct File"}]}}\n'
        )

        class MockEvent1:
            is_directory = False
            src_path = str(transcript1)

        handler.on_modified(MockEvent1())
        await asyncio.sleep(0.2)

        # Should have received content from expected file
        assert len(content_received) == 1, "Should receive content from expected file"


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
