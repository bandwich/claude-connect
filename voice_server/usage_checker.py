"""On-demand usage stats checker for Claude Code."""

import asyncio
import subprocess
import time
from typing import Optional
from usage_parser import parse_usage_output

class UsageChecker:
    """Spawns Claude Code to fetch /usage stats on demand."""

    def __init__(self):
        self.cached_usage: Optional[dict] = None
        self.cache_timestamp: float = 0

    def get_cached(self) -> Optional[dict]:
        """Return cached usage if available."""
        if self.cached_usage:
            return {
                **self.cached_usage,
                "cached": True,
                "cache_age_seconds": time.time() - self.cache_timestamp
            }
        return None

    async def check_usage(self) -> dict:
        """Spawn Claude Code, run /usage, parse output, return stats.

        This creates a temporary tmux session, starts Claude Code,
        sends /usage, captures output, then cleans up.

        Returns:
            Parsed usage stats dict
        """
        session_name = f"usage-check-{int(time.time())}"

        try:
            # 1. Create temp tmux session
            subprocess.run(
                ["tmux", "new-session", "-d", "-s", session_name],
                check=True,
                capture_output=True
            )

            # 2. Start Claude Code
            subprocess.run(
                ["tmux", "send-keys", "-t", session_name, "claude", "Enter"],
                check=True,
                capture_output=True
            )
            await asyncio.sleep(3)  # Wait for Claude to initialize

            # 3. Send /usage command (send separately to allow autocomplete to render)
            subprocess.run(
                ["tmux", "send-keys", "-t", session_name, "/usage"],
                check=True,
                capture_output=True
            )
            await asyncio.sleep(1)  # Wait for autocomplete menu
            subprocess.run(
                ["tmux", "send-keys", "-t", session_name, "Enter"],
                check=True,
                capture_output=True
            )
            await asyncio.sleep(2)  # Wait for usage display to render

            # 4. Capture terminal output
            result = subprocess.run(
                ["tmux", "capture-pane", "-t", session_name, "-p"],
                capture_output=True,
                text=True
            )
            raw_output = result.stdout

            # 5. Parse the output
            usage_data = parse_usage_output(raw_output)
            usage_data["type"] = "usage_response"
            usage_data["cached"] = False
            usage_data["timestamp"] = time.time()

            # 6. Cache the result
            self.cached_usage = usage_data
            self.cache_timestamp = time.time()

            return usage_data

        except subprocess.CalledProcessError as e:
            return {
                "type": "usage_response",
                "session": {"percentage": None, "resets_at": None, "timezone": None},
                "week_all_models": {"percentage": None, "resets_at": None, "timezone": None},
                "week_sonnet_only": {"percentage": None},
                "error": f"Failed to check usage: {e}",
                "cached": False,
                "timestamp": time.time()
            }
        finally:
            # Always clean up the tmux session
            try:
                subprocess.run(
                    ["tmux", "send-keys", "-t", session_name, "Escape", ""],
                    capture_output=True
                )
                await asyncio.sleep(0.5)
                subprocess.run(
                    ["tmux", "send-keys", "-t", session_name, "/exit", "Enter"],
                    capture_output=True
                )
                await asyncio.sleep(1)
                subprocess.run(
                    ["tmux", "kill-session", "-t", session_name],
                    capture_output=True
                )
            except Exception:
                pass
