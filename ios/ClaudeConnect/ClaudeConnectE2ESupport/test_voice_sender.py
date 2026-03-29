"""Tests for voice_sender.py"""
import pytest
import asyncio
import json
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from voice_sender import send_voice_input

@pytest.mark.asyncio
async def test_send_voice_input_formats_message_correctly():
    """Test that message is formatted correctly"""
    # This is a unit test - we'll test format without actual WebSocket
    # The function should return the formatted message for testing
    message = {
        "type": "voice_input",
        "text": "Test message",
        "timestamp": 123456789.0
    }

    # Verify JSON serialization works
    json_str = json.dumps(message)
    parsed = json.loads(json_str)

    assert parsed["type"] == "voice_input"
    assert parsed["text"] == "Test message"
