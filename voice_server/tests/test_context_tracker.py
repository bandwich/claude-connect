# voice_server/tests/test_context_tracker.py
import pytest
import json
import tempfile
import os
from voice_server.services.context_tracker import ContextTracker

def test_calculate_context_from_empty_file():
    """Empty transcript returns 0% context usage."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write("")
        f.flush()

        tracker = ContextTracker()
        result = tracker.calculate_context(f.name)

        assert result["tokens_used"] == 0
        assert result["context_percentage"] == 0.0
        assert result["context_limit"] == 166000

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

        # Uses last message: 150 input tokens only (no output_tokens)
        assert result["tokens_used"] == 150
        assert result["context_percentage"] == 0.09  # 150/166000 * 100 = 0.09%

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

        # 10 + 5000 + 1000 = 6010 (no output_tokens)
        assert result["tokens_used"] == 6010
        assert result["context_percentage"] == 3.62  # 6010/166000 * 100

        os.unlink(f.name)

def test_calculate_context_skips_all_zero_usage():
    """Usage entries with all zero tokens are skipped (e.g. from killed compaction)."""
    lines = [
        json.dumps({
            "message": {
                "role": "assistant",
                "content": "Real response",
                "usage": {"input_tokens": 1, "cache_creation_input_tokens": 11587, "cache_read_input_tokens": 157975, "output_tokens": 100}
            }
        }),
        json.dumps({
            "message": {
                "role": "assistant",
                "content": "",
                "usage": {"input_tokens": 0, "output_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
            }
        })
    ]

    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write("\n".join(lines))
        f.flush()

        tracker = ContextTracker()
        result = tracker.calculate_context(f.name)

        # Should use the real usage, not the all-zero one
        assert result["tokens_used"] == 1 + 11587 + 157975
        assert result["context_percentage"] > 100  # Over limit

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

        # 500 input only (no output_tokens)
        assert result["tokens_used"] == 500

        os.unlink(f.name)
