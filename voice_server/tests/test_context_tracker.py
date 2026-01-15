# voice_server/tests/test_context_tracker.py
import pytest
import json
import tempfile
import os
from context_tracker import ContextTracker

def test_calculate_context_from_empty_file():
    """Empty transcript returns 0% context usage."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write("")
        f.flush()

        tracker = ContextTracker()
        result = tracker.calculate_context(f.name)

        assert result["tokens_used"] == 0
        assert result["context_percentage"] == 0.0
        assert result["context_limit"] == 200000

        os.unlink(f.name)

def test_calculate_context_from_transcript():
    """Transcript with usage data returns correct percentage."""
    lines = [
        json.dumps({
            "message": {
                "role": "user",
                "content": "Hello",
                "usage": {"input_tokens": 100, "output_tokens": 0}
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

        # 100 + 0 + 150 + 50 = 300 tokens
        assert result["tokens_used"] == 300
        assert result["context_percentage"] == 0.15  # 300/200000 * 100 = 0.15%

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
