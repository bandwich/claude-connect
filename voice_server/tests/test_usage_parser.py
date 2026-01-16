# voice_server/tests/test_usage_parser.py
import pytest
from voice_server.usage_parser import parse_usage_output

SAMPLE_OUTPUT = """
  Settings:  Status   Config   Usage  (←/→ or tab to cycle)


  Current session
  ███▌                                               7% used
  Resets 1:59pm (America/Los_Angeles)

  Current week (all models)
  ████████████                                       24% used
  Resets 7:59pm (America/Los_Angeles)

  Current week (Sonnet only)
                                                     0% used

  escape to cancel
"""

def test_parse_session_usage():
    """Extract session percentage and reset time."""
    result = parse_usage_output(SAMPLE_OUTPUT)

    assert result["session"]["percentage"] == 7
    assert result["session"]["resets_at"] == "1:59pm"
    assert result["session"]["timezone"] == "America/Los_Angeles"

def test_parse_week_all_models():
    """Extract weekly all-models usage."""
    result = parse_usage_output(SAMPLE_OUTPUT)

    assert result["week_all_models"]["percentage"] == 24
    assert result["week_all_models"]["resets_at"] == "7:59pm"

def test_parse_week_sonnet_only():
    """Extract weekly Sonnet-only usage."""
    result = parse_usage_output(SAMPLE_OUTPUT)

    assert result["week_sonnet_only"]["percentage"] == 0

def test_parse_empty_output():
    """Empty or invalid output returns None values."""
    result = parse_usage_output("")

    assert result["session"]["percentage"] is None
    assert result["week_all_models"]["percentage"] is None

def test_parse_with_ansi_codes():
    """ANSI escape codes are stripped before parsing."""
    output_with_ansi = "\x1b[1m7% used\x1b[0m"
    # This is a partial test - full output would have more structure
    # Just verify ANSI stripping doesn't break parsing
    result = parse_usage_output(output_with_ansi)
    assert result is not None

def test_parse_short_time_format():
    """Handle time format without minutes (e.g., '7pm' instead of '7:59pm')."""
    output = """
  Current session
  ██████                                             12% used
  Resets 7pm (America/Los_Angeles)

  Current week (all models)
  █████████████▌                                     27% used
  Resets 8pm (America/Los_Angeles)
"""
    result = parse_usage_output(output)

    assert result["session"]["percentage"] == 12
    assert result["session"]["resets_at"] == "7pm"
    assert result["session"]["timezone"] == "America/Los_Angeles"
    assert result["week_all_models"]["percentage"] == 27
    assert result["week_all_models"]["resets_at"] == "8pm"
