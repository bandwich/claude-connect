"""Tests for transcript_injector.py"""
import json
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))

from transcript_injector import inject_assistant_message

def test_inject_assistant_message_creates_valid_jsonl(tmp_path):
    """Test that injection creates valid JSONL entry"""
    transcript_path = tmp_path / "test.jsonl"

    inject_assistant_message(str(transcript_path), "Test message")

    assert transcript_path.exists()
    with open(transcript_path) as f:
        line = f.readline()
        entry = json.loads(line)
        assert entry["role"] == "assistant"
        assert entry["content"] == "Test message"

def test_inject_assistant_message_appends_to_existing(tmp_path):
    """Test that injection appends to existing file"""
    transcript_path = tmp_path / "test.jsonl"

    inject_assistant_message(str(transcript_path), "First")
    inject_assistant_message(str(transcript_path), "Second")

    with open(transcript_path) as f:
        lines = f.readlines()
        assert len(lines) == 2
        assert json.loads(lines[0])["content"] == "First"
        assert json.loads(lines[1])["content"] == "Second"
