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
