"""Tests for transcript_injector.py"""
import pytest
import json
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))

from transcript_injector import inject_user_message, inject_assistant_message

def test_inject_user_message_creates_valid_jsonl(tmp_path):
    """Test that user message injection creates valid JSONL entry"""
    transcript_path = tmp_path / "test.jsonl"

    inject_user_message(str(transcript_path), "Hello Claude")

    assert transcript_path.exists()
    with open(transcript_path) as f:
        line = f.readline()
        entry = json.loads(line)
        assert entry["role"] == "user"
        assert entry["content"] == "Hello Claude"

def test_inject_assistant_message_creates_valid_jsonl(tmp_path):
    """Test that assistant message injection creates valid JSONL entry"""
    transcript_path = tmp_path / "test.jsonl"

    inject_assistant_message(str(transcript_path), "Test response")

    assert transcript_path.exists()
    with open(transcript_path) as f:
        line = f.readline()
        entry = json.loads(line)
        assert entry["role"] == "assistant"
        assert entry["content"] == "Test response"

def test_inject_conversation_flow(tmp_path):
    """Test injecting a conversation"""
    transcript_path = tmp_path / "test.jsonl"

    inject_user_message(str(transcript_path), "First question")
    inject_assistant_message(str(transcript_path), "First answer")
    inject_user_message(str(transcript_path), "Second question")
    inject_assistant_message(str(transcript_path), "Second answer")

    with open(transcript_path) as f:
        lines = f.readlines()
        assert len(lines) == 4
        assert json.loads(lines[0])["role"] == "user"
        assert json.loads(lines[1])["role"] == "assistant"
        assert json.loads(lines[2])["role"] == "user"
        assert json.loads(lines[3])["role"] == "assistant"
