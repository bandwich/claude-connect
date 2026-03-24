"""On-demand usage stats checker via Anthropic OAuth API."""

import asyncio
import aiohttp
import json
import subprocess
import time
from typing import Optional
from voice_server.services.usage_parser import parse_api_response

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
