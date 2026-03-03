# Fix Usage Checker Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Replace the broken tmux-based usage checker with a direct HTTP call to Anthropic's OAuth usage API.

**Architecture:** `UsageChecker` reads the OAuth token from macOS Keychain via `security` CLI, makes a GET request to `https://api.anthropic.com/api/oauth/usage`, and maps the response to the existing `session`/`week_all_models`/`week_sonnet_only` structure. No iOS or `ios_server.py` changes needed.

**Tech Stack:** Python, aiohttp (already a dependency), macOS Keychain (`security` CLI)

**Risky Assumptions:** The OAuth token from Keychain is valid and not expired. We verify this in Task 3 with a live integration test.

---

### Task 1: Rewrite usage_parser.py for API response format

The old parser parsed terminal output with ANSI codes and regex. Replace it with a simple JSON-to-JSON mapper for the new API response.

**Files:**
- Modify: `voice_server/usage_parser.py`
- Modify: `voice_server/tests/test_usage_parser.py`

**Step 1: Replace test file with new tests**

Replace the contents of `voice_server/tests/test_usage_parser.py` with:

```python
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
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: FAIL — `parse_api_response` does not exist yet.

**Step 3: Replace usage_parser.py implementation**

Replace the contents of `voice_server/usage_parser.py` with:

```python
"""Parser for Anthropic OAuth usage API response."""

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
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All `test_usage_parser.py` tests PASS.

**Step 5: Commit**

```bash
git add voice_server/usage_parser.py voice_server/tests/test_usage_parser.py
git commit -m "fix: rewrite usage_parser for direct API response format"
```

---

### Task 2: Rewrite usage_checker.py to use direct API call

Replace tmux-based checker with HTTP call to Anthropic's usage endpoint.

**Files:**
- Modify: `voice_server/usage_checker.py`
- Modify: `voice_server/tests/test_usage_handler.py`

**Step 1: Replace test file with new tests**

Replace the contents of `voice_server/tests/test_usage_handler.py` with:

```python
# voice_server/tests/test_usage_handler.py
import pytest
import json
import asyncio
import time
from unittest.mock import AsyncMock, patch, MagicMock
from voice_server.usage_checker import UsageChecker


def test_get_cached_returns_none_initially():
    checker = UsageChecker()
    assert checker.get_cached() is None


def test_get_cached_returns_data_after_check():
    checker = UsageChecker()
    checker.cached_usage = {
        "type": "usage_response",
        "session": {"percentage": 5},
    }
    checker.cache_timestamp = time.time()
    cached = checker.get_cached()
    assert cached is not None
    assert cached["cached"] is True
    assert cached["session"]["percentage"] == 5


@pytest.mark.asyncio
async def test_check_usage_calls_api():
    """check_usage fetches token and calls API endpoint."""
    checker = UsageChecker()

    mock_token_data = json.dumps({
        "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-fake-token",
            "expiresAt": int(time.time() * 1000) + 3600000,
        }
    })

    api_response = {
        "five_hour": {"utilization": 9.0, "resets_at": "2026-03-03T23:00:00+00:00"},
        "seven_day": {"utilization": 19.0, "resets_at": "2026-03-06T19:00:00+00:00"},
        "seven_day_sonnet": {"utilization": 0.0, "resets_at": "2026-03-07T21:00:00+00:00"},
    }

    mock_resp = AsyncMock()
    mock_resp.status = 200
    mock_resp.json = AsyncMock(return_value=api_response)

    mock_session = AsyncMock()
    mock_session.__aenter__ = AsyncMock(return_value=mock_session)
    mock_session.__aexit__ = AsyncMock(return_value=False)
    mock_session.get = MagicMock(return_value=mock_resp)
    mock_resp.__aenter__ = AsyncMock(return_value=mock_resp)
    mock_resp.__aexit__ = AsyncMock(return_value=False)

    with patch("voice_server.usage_checker.subprocess.run") as mock_run, \
         patch("voice_server.usage_checker.aiohttp.ClientSession", return_value=mock_session):
        mock_run.return_value = MagicMock(stdout=mock_token_data, returncode=0)
        result = await checker.check_usage()

    assert result["type"] == "usage_response"
    assert result["session"]["percentage"] == 9
    assert result["week_all_models"]["percentage"] == 19
    assert result["week_sonnet_only"]["percentage"] == 0
    assert result["cached"] is False


@pytest.mark.asyncio
async def test_check_usage_handles_expired_token():
    """check_usage returns error when token is expired."""
    checker = UsageChecker()

    mock_token_data = json.dumps({
        "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-expired",
            "expiresAt": 1000,  # expired long ago
        }
    })

    with patch("voice_server.usage_checker.subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(stdout=mock_token_data, returncode=0)
        result = await checker.check_usage()

    assert result["type"] == "usage_response"
    assert "error" in result
    assert "expired" in result["error"].lower()


@pytest.mark.asyncio
async def test_check_usage_handles_keychain_failure():
    """check_usage returns error when keychain access fails."""
    checker = UsageChecker()

    with patch("voice_server.usage_checker.subprocess.run") as mock_run:
        mock_run.return_value = MagicMock(stdout="", returncode=44)
        result = await checker.check_usage()

    assert result["type"] == "usage_response"
    assert "error" in result


@pytest.mark.asyncio
async def test_check_usage_caches_result():
    """Successful check_usage populates the cache."""
    checker = UsageChecker()

    mock_token_data = json.dumps({
        "claudeAiOauth": {
            "accessToken": "sk-ant-oat01-fake",
            "expiresAt": int(time.time() * 1000) + 3600000,
        }
    })

    api_response = {
        "five_hour": {"utilization": 5.0, "resets_at": "2026-03-03T23:00:00+00:00"},
        "seven_day": {"utilization": 10.0, "resets_at": "2026-03-06T19:00:00+00:00"},
        "seven_day_sonnet": None,
    }

    mock_resp = AsyncMock()
    mock_resp.status = 200
    mock_resp.json = AsyncMock(return_value=api_response)
    mock_resp.__aenter__ = AsyncMock(return_value=mock_resp)
    mock_resp.__aexit__ = AsyncMock(return_value=False)

    mock_session = AsyncMock()
    mock_session.__aenter__ = AsyncMock(return_value=mock_session)
    mock_session.__aexit__ = AsyncMock(return_value=False)
    mock_session.get = MagicMock(return_value=mock_resp)

    with patch("voice_server.usage_checker.subprocess.run") as mock_run, \
         patch("voice_server.usage_checker.aiohttp.ClientSession", return_value=mock_session):
        mock_run.return_value = MagicMock(stdout=mock_token_data, returncode=0)
        await checker.check_usage()

    cached = checker.get_cached()
    assert cached is not None
    assert cached["session"]["percentage"] == 5


def test_handle_usage_request_sends_cached_then_fresh():
    """ios_server.handle_usage_request sends cached first, then fresh data."""
    from ios_server import VoiceServer

    server = VoiceServer()

    server.usage_checker.cached_usage = {
        "type": "usage_response",
        "session": {"percentage": 5},
        "week_all_models": {"percentage": 20},
        "week_sonnet_only": {"percentage": 0},
    }
    server.usage_checker.cache_timestamp = 1000.0

    mock_ws = AsyncMock()
    sent_messages = []

    async def capture_send(msg):
        sent_messages.append(json.loads(msg))

    mock_ws.send = capture_send

    async def mock_check():
        return {
            "type": "usage_response",
            "session": {"percentage": 7},
            "week_all_models": {"percentage": 24},
            "week_sonnet_only": {"percentage": 0},
            "cached": False,
        }

    server.usage_checker.check_usage = mock_check

    loop = asyncio.new_event_loop()
    loop.run_until_complete(server.handle_usage_request(mock_ws))
    loop.close()

    assert len(sent_messages) == 2
    assert sent_messages[0]["cached"] is True
    assert sent_messages[1]["cached"] is False
    assert sent_messages[1]["session"]["percentage"] == 7
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: FAIL — new test imports won't match old code.

**Step 3: Replace usage_checker.py implementation**

Replace the contents of `voice_server/usage_checker.py` with:

```python
"""On-demand usage stats checker via Anthropic OAuth API."""

import asyncio
import aiohttp
import json
import subprocess
import time
from typing import Optional
from voice_server.usage_parser import parse_api_response

USAGE_API_URL = "https://api.anthropic.com/api/oauth/usage"
KEYCHAIN_SERVICE = "Claude Code-credentials"


class UsageChecker:
    """Fetches usage stats from Anthropic's OAuth usage API."""

    def __init__(self):
        self.cached_usage: Optional[dict] = None
        self.cache_timestamp: float = 0

    def get_cached(self) -> Optional[dict]:
        """Return cached usage if available."""
        if self.cached_usage:
            return {
                **self.cached_usage,
                "cached": True,
                "cache_age_seconds": time.time() - self.cache_timestamp,
            }
        return None

    def _get_oauth_token(self) -> str:
        """Read OAuth access token from macOS Keychain.

        Raises:
            RuntimeError: If keychain access fails or token is expired.
        """
        result = subprocess.run(
            ["security", "find-generic-password", "-s", KEYCHAIN_SERVICE, "-w"],
            capture_output=True,
            text=True,
        )
        if result.returncode != 0 or not result.stdout.strip():
            raise RuntimeError("Could not read Claude Code credentials from Keychain")

        data = json.loads(result.stdout)
        oauth = data.get("claudeAiOauth", {})
        token = oauth.get("accessToken")
        if not token:
            raise RuntimeError("No accessToken in Keychain credentials")

        expires_at = oauth.get("expiresAt", 0)
        if expires_at < time.time() * 1000:
            raise RuntimeError("OAuth token expired — open Claude Code to refresh")

        return token

    async def check_usage(self) -> dict:
        """Fetch usage stats from the Anthropic OAuth API.

        Returns:
            Parsed usage stats dict with type, session, week_all_models,
            week_sonnet_only, cached, and timestamp fields.
        """
        try:
            token = self._get_oauth_token()

            headers = {
                "Authorization": f"Bearer {token}",
                "anthropic-beta": "oauth-2025-04-20",
                "User-Agent": "claude-connect/1.0",
            }

            async with aiohttp.ClientSession() as session:
                async with session.get(USAGE_API_URL, headers=headers) as resp:
                    if resp.status != 200:
                        raise RuntimeError(f"Usage API returned {resp.status}")
                    api_data = await resp.json()

            usage_data = parse_api_response(api_data)
            usage_data["type"] = "usage_response"
            usage_data["cached"] = False
            usage_data["timestamp"] = time.time()

            self.cached_usage = usage_data
            self.cache_timestamp = time.time()

            return usage_data

        except Exception as e:
            print(f"usage_checker error: {e}")
            return {
                "type": "usage_response",
                "session": {"percentage": None, "resets_at": None, "timezone": None},
                "week_all_models": {"percentage": None, "resets_at": None, "timezone": None},
                "week_sonnet_only": {"percentage": None},
                "error": f"Failed to check usage: {e}",
                "cached": False,
                "timestamp": time.time(),
            }
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests PASS.

**Step 5: Commit**

```bash
git add voice_server/usage_checker.py voice_server/tests/test_usage_handler.py
git commit -m "fix: rewrite usage_checker to use direct OAuth API instead of tmux"
```

---

### Task 3: Live integration test

Verify the new implementation actually works end-to-end against the real API.

**Files:** None — this is a verification-only task.

**Step 1: Test token retrieval**

Run in the project venv:

```bash
cd /Users/aaron/Desktop/max && .venv/bin/python -c "
from voice_server.usage_checker import UsageChecker
c = UsageChecker()
token = c._get_oauth_token()
print(f'Token starts with: {token[:15]}...')
print('Token retrieval OK')
"
```

Expected: Prints token prefix and "Token retrieval OK".

**Step 2: Test full usage fetch**

```bash
cd /Users/aaron/Desktop/max && .venv/bin/python -c "
import asyncio
from voice_server.usage_checker import UsageChecker
c = UsageChecker()
result = asyncio.run(c.check_usage())
print(f'Session: {result[\"session\"][\"percentage\"]}%')
print(f'Week all: {result[\"week_all_models\"][\"percentage\"]}%')
print(f'Week sonnet: {result[\"week_sonnet_only\"][\"percentage\"]}%')
print(f'Error: {result.get(\"error\", \"none\")}')
"
```

Expected: Non-None percentages, no error.

**CHECKPOINT:** If this doesn't return real percentages, debug before proceeding. Check token, API response, field mapping.

**Step 3: Commit (no code changes — skip if nothing to fix)**

---

### Task 4: Reinstall and manual iOS verification

Verify the server works end-to-end with the iOS app.

**Step 1: Reinstall the server**

```bash
pipx install --force /Users/aaron/Desktop/max
```

**Step 2: Start the server and test from iOS**

Start `claude-connect`, open the iOS app, go to Settings, and tap to view usage stats.

Expected: Percentages display correctly (not 0% everywhere).

**CHECKPOINT:** If the iOS app still shows 0%, check server logs for errors. The `usage_checker error:` log line will show what went wrong.

**Step 3: Commit any fixes, then final commit**

```bash
git add -u
git commit -m "fix: complete usage checker migration to direct API"
```
