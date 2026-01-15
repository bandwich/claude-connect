import pytest
import json
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

def test_handle_usage_request_returns_cached_then_fresh():
    """handle_usage_request sends cached first, then fresh data."""
    from ios_server import VoiceServer

    server = VoiceServer()

    # Pre-populate cache
    server.usage_checker.cached_usage = {
        "session": {"percentage": 5},
        "week_all_models": {"percentage": 20},
        "week_sonnet_only": {"percentage": 0}
    }
    server.usage_checker.cache_timestamp = 1000.0

    # Mock websocket
    mock_ws = AsyncMock()
    sent_messages = []

    async def capture_send(msg):
        sent_messages.append(json.loads(msg))

    mock_ws.send = capture_send

    # Mock check_usage to return fresh data
    async def mock_check():
        return {
            "type": "usage_response",
            "session": {"percentage": 7},
            "week_all_models": {"percentage": 24},
            "week_sonnet_only": {"percentage": 0},
            "cached": False
        }

    server.usage_checker.check_usage = mock_check

    # Run handler
    loop = asyncio.new_event_loop()
    loop.run_until_complete(server.handle_usage_request(mock_ws))
    loop.close()

    # Should have sent 2 messages: cached first, then fresh
    assert len(sent_messages) == 2
    assert sent_messages[0]["cached"] == True
    assert sent_messages[0]["session"]["percentage"] == 5
    assert sent_messages[1]["cached"] == False
    assert sent_messages[1]["session"]["percentage"] == 7


def test_handle_usage_request_no_cache():
    """handle_usage_request with no cache only sends fresh data."""
    from ios_server import VoiceServer

    server = VoiceServer()
    # No cached data

    mock_ws = AsyncMock()
    sent_messages = []

    async def capture_send(msg):
        sent_messages.append(json.loads(msg))

    mock_ws.send = capture_send

    async def mock_check():
        return {
            "type": "usage_response",
            "session": {"percentage": 7},
            "cached": False
        }

    server.usage_checker.check_usage = mock_check

    loop = asyncio.new_event_loop()
    loop.run_until_complete(server.handle_usage_request(mock_ws))
    loop.close()

    # Should have sent only 1 message (fresh)
    assert len(sent_messages) == 1
    assert sent_messages[0]["cached"] == False
