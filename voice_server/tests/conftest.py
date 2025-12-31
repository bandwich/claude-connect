#!/usr/bin/env python3
"""
Pytest configuration and fixtures for voice mode tests
"""

import pytest
import tempfile
import os
import json
import numpy as np


@pytest.fixture
def temp_transcript_file():
    """Create a temporary transcript file"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        yield f.name
    if os.path.exists(f.name):
        os.unlink(f.name)


@pytest.fixture
def sample_transcript_data():
    """Sample transcript data with various message types"""
    return [
        {"role": "user", "content": "Hello"},
        {"role": "assistant", "content": "Hi there! How can I help?"},
        {"role": "user", "content": "Tell me a joke"},
        {
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Why did the programmer quit?"},
                {"type": "text", "text": "Because they didn't get arrays!"}
            ]
        },
    ]


@pytest.fixture
def sample_audio_data():
    """Sample audio data as numpy array"""
    # Create 1 second of silence at 24kHz
    return np.zeros(24000, dtype=np.float32)


@pytest.fixture
def sample_websocket_message():
    """Sample WebSocket message from iOS app"""
    return {
        "type": "voice_input",
        "text": "What is the weather today?",
        "timestamp": 1234567890.123
    }


@pytest.fixture
def temp_transcript_dir():
    """Create a temporary directory for transcript files"""
    with tempfile.TemporaryDirectory() as tmpdir:
        yield tmpdir


@pytest.fixture
def populated_transcript_file(temp_transcript_file, sample_transcript_data):
    """Create a transcript file with sample data"""
    with open(temp_transcript_file, 'w') as f:
        for entry in sample_transcript_data:
            f.write(json.dumps(entry) + '\n')
    return temp_transcript_file
