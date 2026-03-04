# voice_server/tests/test_usage_parser.py
import pytest
from voice_server.usage_parser import parse_api_response

SAMPLE_API_RESPONSE = {
    "five_hour": {
        "utilization": 9.0,
        "resets_at": "2026-03-03T23:00:00.654360+00:00"
    },
    "seven_day": {
        "utilization": 19.0,
        "resets_at": "2026-03-06T19:00:00.654375+00:00"
    },
    "seven_day_sonnet": {
        "utilization": 0.0,
        "resets_at": "2026-03-07T21:00:00.654382+00:00"
    },
    "seven_day_oauth_apps": None,
    "seven_day_opus": None,
    "seven_day_cowork": None,
    "iguana_necktie": None,
    "extra_usage": {
        "is_enabled": True,
        "monthly_limit": 2000,
        "used_credits": 0.0,
        "utilization": None
    }
}


def test_parse_session_from_five_hour():
    result = parse_api_response(SAMPLE_API_RESPONSE)
    assert result["session"]["percentage"] == 9
    assert result["session"]["resets_at"] is not None


def test_parse_week_all_models_from_seven_day():
    result = parse_api_response(SAMPLE_API_RESPONSE)
    assert result["week_all_models"]["percentage"] == 19
    assert result["week_all_models"]["resets_at"] is not None


def test_parse_week_sonnet_only():
    result = parse_api_response(SAMPLE_API_RESPONSE)
    assert result["week_sonnet_only"]["percentage"] == 0


def test_resets_at_formatted_as_local_time():
    """resets_at should be human-readable like '4:00pm', not raw ISO."""
    result = parse_api_response(SAMPLE_API_RESPONSE)
    # Should be a short time string, not an ISO timestamp
    resets = result["session"]["resets_at"]
    assert "T" not in resets  # Not ISO format
    assert ("am" in resets or "pm" in resets)  # 12-hour format


def test_timezone_extracted():
    result = parse_api_response(SAMPLE_API_RESPONSE)
    assert result["session"]["timezone"] is not None
    assert len(result["session"]["timezone"]) > 0


def test_parse_missing_category():
    """Categories that are None in the API response get None percentage."""
    sparse = {
        "five_hour": {"utilization": 5.0, "resets_at": "2026-03-03T23:00:00+00:00"},
        "seven_day": None,
        "seven_day_sonnet": None,
    }
    result = parse_api_response(sparse)
    assert result["session"]["percentage"] == 5
    assert result["week_all_models"]["percentage"] is None
    assert result["week_sonnet_only"]["percentage"] is None


def test_parse_utilization_rounds_float():
    """Utilization floats are rounded to int percentages."""
    data = {
        "five_hour": {"utilization": 9.7, "resets_at": "2026-03-03T23:00:00+00:00"},
        "seven_day": {"utilization": 19.3, "resets_at": "2026-03-06T19:00:00+00:00"},
        "seven_day_sonnet": {"utilization": 0.0, "resets_at": "2026-03-07T21:00:00+00:00"},
    }
    result = parse_api_response(data)
    assert result["session"]["percentage"] == 10
    assert result["week_all_models"]["percentage"] == 19
