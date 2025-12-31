#!/usr/bin/env python3
"""
Tests for ios_server.py - WebSocket Server
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

# Add voice_server directory to path
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

from ios_server import VoiceServer, TranscriptHandler


class TestTranscriptHandler:
    """Tests for TranscriptHandler class"""

    def test_transcript_handler_initialization(self):
        """Test handler initializes correctly"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        assert handler.callback == callback
        assert handler.loop == loop
        assert handler.server == server
        assert handler.last_message is None
        assert handler.last_modified == 0

    def test_extract_assistant_response_to_user_message_string_content(self):
        """Test extracting assistant response after specific user message"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        # Create test transcript file
        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({"role": "user", "content": "Hello"}) + "\n")
            f.write(json.dumps({"role": "assistant", "content": "Hi there!"}) + "\n")
            filepath = f.name

        try:
            result = handler.extract_assistant_response_to_user_message(filepath, "Hello")
            assert result == "Hi there!"
        finally:
            os.unlink(filepath)

    def test_extract_assistant_response_to_user_message_list_content(self):
        """Test extracting assistant response with list/block content"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({"role": "user", "content": "Question"}) + "\n")
            f.write(json.dumps({
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "Hello"},
                    {"type": "text", "text": "world"}
                ]
            }) + "\n")
            filepath = f.name

        try:
            result = handler.extract_assistant_response_to_user_message(filepath, "Question")
            assert result == "Hello world"
        finally:
            os.unlink(filepath)

    def test_extract_assistant_response_to_user_message_message_wrapper(self):
        """Test extracting when content is nested in 'message' key"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({
                "message": {
                    "role": "user",
                    "content": "Question"
                }
            }) + "\n")
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "content": "Nested message"
                }
            }) + "\n")
            filepath = f.name

        try:
            result = handler.extract_assistant_response_to_user_message(filepath, "Question")
            assert result == "Nested message"
        finally:
            os.unlink(filepath)

    def test_extract_assistant_response_to_user_message_mixed_roles(self):
        """Test extracts correct assistant response after specific user message"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({"role": "user", "content": "First question"}) + "\n")
            f.write(json.dumps({"role": "assistant", "content": "First response"}) + "\n")
            f.write(json.dumps({"role": "user", "content": "Second question"}) + "\n")
            f.write(json.dumps({"role": "assistant", "content": "Second response"}) + "\n")
            filepath = f.name

        try:
            result = handler.extract_assistant_response_to_user_message(filepath, "Second question")
            assert result == "Second response"
        finally:
            os.unlink(filepath)

    def test_extract_assistant_response_to_user_message_no_match(self):
        """Test when user message doesn't match"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({"role": "user", "content": "Hello"}) + "\n")
            f.write(json.dumps({"role": "assistant", "content": "Response"}) + "\n")
            filepath = f.name

        try:
            result = handler.extract_assistant_response_to_user_message(filepath, "Different question")
            assert result is None
        finally:
            os.unlink(filepath)

    def test_extract_assistant_response_to_user_message_no_assistant(self):
        """Test when no assistant response follows user message"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({"role": "user", "content": "Hello"}) + "\n")
            filepath = f.name

        try:
            result = handler.extract_assistant_response_to_user_message(filepath, "Hello")
            assert result is None
        finally:
            os.unlink(filepath)

    def test_extract_assistant_response_to_user_message_filters_thinking(self):
        """Test that thinking blocks are filtered out"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({"role": "user", "content": "Question"}) + "\n")
            f.write(json.dumps({
                "role": "assistant",
                "content": [
                    {"type": "thinking", "text": "Internal thoughts"},
                    {"type": "text", "text": "Actual response"}
                ]
            }) + "\n")
            filepath = f.name

        try:
            result = handler.extract_assistant_response_to_user_message(filepath, "Question")
            assert result == "Actual response"
        finally:
            os.unlink(filepath)

    def test_on_modified_non_jsonl_files(self):
        """Test ignores non-.jsonl files"""
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

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
        handler = TranscriptHandler(callback, loop, server)

        event = Mock()
        event.is_directory = True
        event.src_path = "/path/to/directory.jsonl"

        handler.on_modified(event)

        callback.assert_not_called()

    def test_on_modified_duplicate_detection(self):
        """Test duplicate message filtering"""
        callback = AsyncMock()
        loop = Mock()
        server = Mock()
        server.last_voice_input = "User question"
        handler = TranscriptHandler(callback, loop, server)
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


class TestVoiceServer:
    """Tests for VoiceServer class"""

    def test_voice_server_initialization(self):
        """Test server initializes correctly"""
        server = VoiceServer()

        assert server.clients == set()
        assert server.transcript_path is None
        assert server.observer is None

    def test_find_transcript_path_no_files(self):
        """Test when no transcripts exist"""
        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            with patch('ios_server.TRANSCRIPT_DIR', tmpdir):
                result = server.find_transcript_path()
                assert result is None

    def test_find_transcript_path(self):
        """Test finding most recent transcript file"""
        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            # Create test files
            file1 = os.path.join(tmpdir, "old.jsonl")
            file2 = os.path.join(tmpdir, "new.jsonl")

            with open(file1, 'w') as f:
                f.write("{}\n")
            time.sleep(0.01)
            with open(file2, 'w') as f:
                f.write("{}\n")

            with patch('ios_server.TRANSCRIPT_DIR', tmpdir):
                result = server.find_transcript_path()
                assert result == file2  # Most recent

    def test_find_transcript_path_multiple_files(self):
        """Test selects most recent when multiple exist"""
        server = VoiceServer()

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

            with patch('ios_server.TRANSCRIPT_DIR', tmpdir):
                result = server.find_transcript_path()
                assert result == file2

    @pytest.mark.asyncio
    async def test_send_status(self):
        """Test status message format"""
        server = VoiceServer()
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
    async def test_send_to_vs_code(self):
        """Test AppleScript integration (mocked)"""
        server = VoiceServer()

        with patch('ios_server.subprocess.run') as mock_run:
            await server.send_to_vs_code("Test message")

            # Should call pbcopy
            assert mock_run.call_count == 2
            pbcopy_call = mock_run.call_args_list[0]
            assert pbcopy_call[0][0] == ['pbcopy']
            assert pbcopy_call[1]['input'] == b'Test message'

            # Should call osascript
            osascript_call = mock_run.call_args_list[1]
            assert osascript_call[0][0][0] == 'osascript'

    @pytest.mark.asyncio
    async def test_stream_audio(self):
        """Test audio streaming with chunking"""
        server = VoiceServer()
        websocket = AsyncMock()

        # Mock TTS generation
        with patch('ios_server.generate_tts_audio') as mock_tts, \
             patch('ios_server.samples_to_wav_bytes') as mock_wav:

            mock_tts.return_value = np.array([0.1, 0.2, 0.3])
            mock_wav.return_value = b'RIFF' + b'\x00' * 20000  # 20KB of fake WAV data

            await server.stream_audio(websocket, "Hello")

            # Verify TTS was called
            mock_tts.assert_called_once_with("Hello", voice="af_heart")
            mock_wav.assert_called_once()

            # Verify chunks were sent
            assert websocket.send.call_count > 0

    @pytest.mark.asyncio
    async def test_stream_audio_chunk_format(self):
        """Verify chunk message structure"""
        server = VoiceServer()
        websocket = AsyncMock()

        with patch('ios_server.generate_tts_audio') as mock_tts, \
             patch('ios_server.samples_to_wav_bytes') as mock_wav:

            mock_tts.return_value = np.array([0.1, 0.2, 0.3])
            mock_wav.return_value = b'TEST_WAV_DATA'

            await server.stream_audio(websocket, "Hello")

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
        server = VoiceServer()
        websocket = AsyncMock()

        with patch('ios_server.generate_tts_audio') as mock_tts, \
             patch('ios_server.samples_to_wav_bytes') as mock_wav:

            mock_tts.return_value = np.array([0.1, 0.2, 0.3])
            mock_wav.return_value = b'TEST_DATA'

            await server.stream_audio(websocket, "Hello")

            first_call = websocket.send.call_args_list[0][0][0]
            chunk_data = json.loads(first_call)

            # Should be able to decode base64
            decoded = base64.b64decode(chunk_data["data"])
            assert isinstance(decoded, bytes)

    @pytest.mark.asyncio
    async def test_handle_voice_input(self):
        """Test voice input processing"""
        server = VoiceServer()
        websocket = AsyncMock()

        with patch.object(server, 'send_to_vs_code', new_callable=AsyncMock) as mock_send, \
             patch.object(server, 'send_status', new_callable=AsyncMock) as mock_status:

            data = {"text": "Hello Claude"}
            await server.handle_voice_input(websocket, data)

            mock_status.assert_called_once_with(websocket, "processing", "Sending to Claude...")
            mock_send.assert_called_once_with("Hello Claude")

    @pytest.mark.asyncio
    async def test_handle_voice_input_empty_text(self):
        """Test with empty/whitespace text"""
        server = VoiceServer()
        websocket = AsyncMock()

        with patch.object(server, 'send_to_vs_code', new_callable=AsyncMock) as mock_send:
            data = {"text": "   "}
            await server.handle_voice_input(websocket, data)

            mock_send.assert_not_called()

    @pytest.mark.asyncio
    async def test_handle_voice_input_status_update(self):
        """Test status messages are sent"""
        server = VoiceServer()
        websocket = AsyncMock()

        with patch.object(server, 'send_to_vs_code', new_callable=AsyncMock), \
             patch.object(server, 'send_status', new_callable=AsyncMock) as mock_status:

            data = {"text": "Test"}
            await server.handle_voice_input(websocket, data)

            mock_status.assert_called_with(websocket, "processing", "Sending to Claude...")

    @pytest.mark.asyncio
    async def test_handle_claude_response(self):
        """Test Claude response handling"""
        server = VoiceServer()
        client1 = AsyncMock()
        client2 = AsyncMock()
        server.clients = {client1, client2}
        server.waiting_for_response = True  # Simulate waiting for response

        with patch.object(server, 'stream_audio', new_callable=AsyncMock) as mock_stream, \
             patch.object(server, 'send_status', new_callable=AsyncMock) as mock_status:

            await server.handle_claude_response("Hello from Claude")

            # Should stream to all clients
            assert mock_stream.call_count == 2
            assert mock_status.call_count == 4  # 2 clients × 2 status updates (speaking, idle)

    @pytest.mark.asyncio
    async def test_handle_claude_response_multiple_clients(self):
        """Test broadcasting to multiple websockets"""
        server = VoiceServer()
        client1 = AsyncMock()
        client2 = AsyncMock()
        server.clients = {client1, client2}
        server.waiting_for_response = True  # Simulate waiting for response

        with patch.object(server, 'stream_audio', new_callable=AsyncMock) as mock_stream, \
             patch.object(server, 'send_status', new_callable=AsyncMock):

            await server.handle_claude_response("Test message")

            # Verify both clients received stream
            calls = [call[0][0] for call in mock_stream.call_args_list]
            assert client1 in calls
            assert client2 in calls

    @pytest.mark.asyncio
    async def test_handle_message_valid_json(self):
        """Test parsing valid voice_input message"""
        server = VoiceServer()
        websocket = AsyncMock()

        with patch.object(server, 'handle_voice_input', new_callable=AsyncMock) as mock_handle:
            message = json.dumps({"type": "voice_input", "text": "Hello"})
            await server.handle_message(websocket, message)

            mock_handle.assert_called_once_with(websocket, {"type": "voice_input", "text": "Hello"})

    @pytest.mark.asyncio
    async def test_handle_message_invalid_json(self):
        """Test error handling for malformed JSON"""
        server = VoiceServer()
        websocket = AsyncMock()

        # Should not raise exception
        await server.handle_message(websocket, "invalid json {")

    @pytest.mark.asyncio
    async def test_handle_message_wrong_type(self):
        """Test ignores non-voice_input messages"""
        server = VoiceServer()
        websocket = AsyncMock()

        with patch.object(server, 'handle_voice_input', new_callable=AsyncMock) as mock_handle:
            message = json.dumps({"type": "other_type", "data": "test"})
            await server.handle_message(websocket, message)

            mock_handle.assert_not_called()

    @pytest.mark.asyncio
    async def test_handle_client_connection(self):
        """Test client connection lifecycle"""
        server = VoiceServer()
        websocket = AsyncMock()
        websocket.__aiter__.return_value = []  # No messages

        with patch.object(server, 'send_status', new_callable=AsyncMock) as mock_status:
            await server.handle_client(websocket, "/")

            # Should send initial status
            mock_status.assert_called_once_with(websocket, "idle", "Connected")

    @pytest.mark.asyncio
    async def test_handle_client_disconnection(self):
        """Test client cleanup on disconnect"""
        server = VoiceServer()
        websocket = AsyncMock()
        websocket.__aiter__.return_value = []

        await server.handle_client(websocket, "/")

        # Client should be removed from set
        assert websocket not in server.clients


    # MARK: - NEW TESTS FOR BUG #2: iOS server couldn't find latest assistant message

    def test_extract_message_exact_match(self):
        """
        Test 13: Verify baseline transcript parsing works
        Tests Bug #2: Exact string match requirement
        """
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        # Create transcript with exact match
        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({"role": "user", "content": "Hello world"}) + "\n")
            f.write(json.dumps({"role": "assistant", "content": "Hi there!"}) + "\n")
            filepath = f.name

        try:
            result = handler.extract_assistant_response_to_user_message(filepath, "Hello world")
            assert result == "Hi there!", "Should extract assistant message with exact match"
        finally:
            os.unlink(filepath)

    def test_extract_message_whitespace_differences(self):
        """
        Test 14: Document the exact match limitation ⚠️ EXPECTED FAILURE
        Tests Bug #2: Whitespace differences cause extraction to fail
        """
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        # Create transcript with double space (simulating what Claude Code might write)
        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({"role": "user", "content": "Hello  world"}) + "\n")  # Double space
            f.write(json.dumps({"role": "assistant", "content": "Response text"}) + "\n")
            filepath = f.name

        try:
            # Try to extract with single space (what was sent to server)
            result = handler.extract_assistant_response_to_user_message(filepath, "Hello world")

            # Known limitation: exact match required, whitespace differences cause failure
            assert result is None, "KNOWN BUG: Whitespace differences prevent message extraction"

            # This test documents the bug - it's expected to pass (finding None)
            # In production, this causes the "couldn't find latest assistant message" bug
        finally:
            os.unlink(filepath)

    def test_extract_message_no_assistant_response(self):
        """
        Test 15: Verify graceful handling of incomplete transcript
        Tests Bug #2: Transcript with user message but no assistant response yet
        """
        callback = Mock()
        loop = Mock()
        server = Mock()
        handler = TranscriptHandler(callback, loop, server)

        # Create transcript with only user message (no assistant response yet)
        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({"role": "user", "content": "Hello"}) + "\n")
            # No assistant response
            filepath = f.name

        try:
            result = handler.extract_assistant_response_to_user_message(filepath, "Hello")
            assert result is None, "Should return None when no assistant response found"
            # Should not crash - defensive coding check
        finally:
            os.unlink(filepath)


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
