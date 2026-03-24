"""Parser for Anthropic OAuth usage API response."""

from __future__ import annotations

from datetime import datetime, timezone


def _format_reset_time(iso_str: str) -> tuple[str, str]:
    """Convert ISO timestamp to human-readable time and timezone.

    Returns:
        (formatted_time, timezone_name) e.g. ("4:00pm", "America/Los_Angeles")
    """
    dt = datetime.fromisoformat(iso_str)
    local_dt = dt.astimezone()
    tz_name = local_dt.strftime("%Z")

    hour = local_dt.strftime("%I").lstrip("0")
    minute = local_dt.strftime("%M")
    ampm = local_dt.strftime("%p").lower()

    if minute == "00":
        formatted = f"{hour}{ampm}"
    else:
        formatted = f"{hour}:{minute}{ampm}"

    return formatted, tz_name


def _extract_category(data: dict | None) -> dict:
    """Extract percentage and reset info from an API category."""
    if data is None:
        return {"percentage": None, "resets_at": None, "timezone": None}

    percentage = None
    if data.get("utilization") is not None:
        percentage = round(data["utilization"])

    resets_at = None
    tz = None
    if data.get("resets_at"):
        resets_at, tz = _format_reset_time(data["resets_at"])

    return {"percentage": percentage, "resets_at": resets_at, "timezone": tz}


def parse_api_response(data: dict) -> dict:
    """Parse Anthropic OAuth usage API response into app format.

    Maps: five_hour -> session, seven_day -> week_all_models,
          seven_day_sonnet -> week_sonnet_only

    Args:
        data: Raw JSON response from /api/oauth/usage

    Returns:
        Dict with session, week_all_models, week_sonnet_only stats
    """
    return {
        "session": _extract_category(data.get("five_hour")),
        "week_all_models": _extract_category(data.get("seven_day")),
        "week_sonnet_only": _extract_category(data.get("seven_day_sonnet")),
    }
