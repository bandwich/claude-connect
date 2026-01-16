# voice_server/tests/test_context_tracker.py
import pytest
import json
import tempfile
import os
from voice_server.context_tracker import ContextTracker

def test_calculate_context_from_empty_file():
    """Empty transcript returns 0% context usage."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write("")
        f.flush()

        tracker = ContextTracker()
        result = tracker.calculate_context(f.name)

        assert result["tokens_used"] == 0
        assert result["context_percentage"] == 0.0
        assert result["context_limit"] == 158000

        os.unlink(f.name)

def test_calculate_context_from_transcript():
    """Transcript with usage data uses last assistant message's tokens."""
    lines = [
        json.dumps({
            "message": {
                "role": "user",
                "content": "Hello"
            }
        }),
        json.dumps({
            "message": {
                "role": "assistant",
                "content": "Hi there!",
                "usage": {"input_tokens": 150, "output_tokens": 50}
            }
        })
    ]

    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write("\n".join(lines))
        f.flush()

        tracker = ContextTracker()
        result = tracker.calculate_context(f.name)

        # Uses last message: 150 + 50 = 200 tokens
        assert result["tokens_used"] == 200
        assert result["context_percentage"] == 0.13  # 200/158000 * 100 = 0.13%

        os.unlink(f.name)


def test_calculate_context_includes_cache_tokens():
    """Cache tokens are included in context calculation."""
    lines = [
        json.dumps({
            "message": {
                "role": "assistant",
                "content": "Response",
                "usage": {
                    "input_tokens": 10,
                    "output_tokens": 20,
                    "cache_creation_input_tokens": 5000,
                    "cache_read_input_tokens": 1000
                }
            }
        })
    ]

    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write("\n".join(lines))
        f.flush()

        tracker = ContextTracker()
        result = tracker.calculate_context(f.name)

        # 10 + 20 + 5000 + 1000 = 6030 tokens
        assert result["tokens_used"] == 6030
        assert result["context_percentage"] == 3.82  # 6030/158000 * 100

        os.unlink(f.name)

def test_calculate_context_ignores_entries_without_usage():
    """Entries without usage field are skipped."""
    lines = [
        json.dumps({"message": {"role": "user", "content": "No usage field"}}),
        json.dumps({
            "message": {
                "role": "assistant",
                "content": "With usage",
                "usage": {"input_tokens": 500, "output_tokens": 500}
            }
        })
    ]

    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write("\n".join(lines))
        f.flush()

        tracker = ContextTracker()
        result = tracker.calculate_context(f.name)

        assert result["tokens_used"] == 1000

        os.unlink(f.name)
