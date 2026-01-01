"""Tests for server_manager.py"""
import pytest
import json
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))

from server_manager import start_server, stop_server

def test_start_server_returns_metadata(tmp_path):
    """Test that start_server returns server metadata"""
    transcript_path = tmp_path / "test_transcript.jsonl"

    result = start_server(str(transcript_path))

    assert "pid" in result
    assert "port" in result
    assert "status" in result
    assert result["status"] == "ready"
    assert isinstance(result["pid"], int)
    assert result["port"] == 8765

    # Cleanup
    stop_server(result["pid"])

def test_stop_server_kills_process(tmp_path):
    """Test that stop_server kills the process"""
    transcript_path = tmp_path / "test_transcript.jsonl"
    result = start_server(str(transcript_path))
    pid = result["pid"]

    stop_server(pid)

    # Verify process is dead
    import psutil
    assert not psutil.pid_exists(pid)
