"""On-demand usage stats checker for Claude Code."""

import asyncio
import subprocess
import time
from typing import Optional
from voice_server.usage_parser import parse_usage_output

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

    def _capture_pane(self, session_name: str) -> str:
        """Capture tmux pane content."""
        result = subprocess.run(
            ["tmux", "capture-pane", "-t", session_name, "-p"],
            capture_output=True,
            text=True
        )
        return result.stdout

    async def _wait_for_content(self, session_name: str, marker: str, timeout: float = 15.0) -> bool:
        """Poll until marker appears in pane content."""
        start = time.time()
        while time.time() - start < timeout:
            content = self._capture_pane(session_name)
            if marker in content:
                return True
            await asyncio.sleep(0.3)
        return False

    async def _wait_for_ready(self, session_name: str, timeout: float = 15.0) -> bool:
        """Poll until Claude is ready for input, handling trust dialog if needed."""
        start = time.time()
        trust_handled = False

        while time.time() - start < timeout:
            content = self._capture_pane(session_name)

            # Check for trust dialog first
            if not trust_handled and "Do you trust the files" in content:
                subprocess.run(
                    ["tmux", "send-keys", "-t", session_name, "Enter"],
                    check=True,
                    capture_output=True
                )
                trust_handled = True
                await asyncio.sleep(0.3)
                continue

            # Check for ready prompt - look for the input prompt line
            # The prompt shows as "❯" at the start of an input line
            # But trust dialog also has "❯ 1. Yes" so we need to be specific
            if "Try \"" in content and "❯" in content:
                # This is the actual prompt with hint text like 'Try "how do I..."'
                return True

            await asyncio.sleep(0.3)

        return False

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

            # 2. Start Claude Code and wait for prompt
            subprocess.run(
                ["tmux", "send-keys", "-t", session_name, "claude", "Enter"],
                check=True,
                capture_output=True
            )

            # Wait for either trust dialog or ready prompt
            if not await self._wait_for_ready(session_name, timeout=15.0):
                raise RuntimeError("Claude Code did not start in time")

            # 3. Send /usage command (send text and Enter separately for reliability)
            subprocess.run(
                ["tmux", "send-keys", "-t", session_name, "/usage"],
                check=True,
                capture_output=True
            )
            await asyncio.sleep(0.5)
            subprocess.run(
                ["tmux", "send-keys", "-t", session_name, "Enter"],
                check=True,
                capture_output=True
            )
            # Wait for usage display to render (look for "% used" marker)
            if not await self._wait_for_content(session_name, "% used", timeout=10.0):
                raise RuntimeError("Usage display did not render in time")

            # 4. Capture terminal output
            raw_output = self._capture_pane(session_name)

            # 5. Parse the output
            usage_data = parse_usage_output(raw_output)
            usage_data["type"] = "usage_response"
            usage_data["cached"] = False
            usage_data["timestamp"] = time.time()

            # 6. Cache the result
            self.cached_usage = usage_data
            self.cache_timestamp = time.time()

            return usage_data

        except (subprocess.CalledProcessError, RuntimeError) as e:
            print(f"usage_checker error: {e}")
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
