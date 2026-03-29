"""Command Handler - executes slash commands via transcript stdout or pane capture."""

import asyncio
import json
import re
import time
from typing import TYPE_CHECKING, Optional

from server.infra.pane_parser import parse_pane_status

if TYPE_CHECKING:
    from server.main import ConnectServer

ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]')

# Commands where Claude generates a response (shown in pane, not transcript)
_RESPONSE_COMMANDS = frozenset({'btw'})
# Commands that create a new transcript file (need special detection)
_CLEAR_COMMANDS = frozenset({'clear'})
STDOUT_RE = re.compile(r'<local-command-stdout>(.*?)</local-command-stdout>', re.DOTALL)


def strip_ansi(text: str) -> str:
    """Remove ANSI escape codes from text."""
    return ANSI_RE.sub('', text)


# Unicode bar chart characters used by Claude Code that don't render on iOS
_BAR_CHARS = str.maketrans({
    '\u26c1': '\u2588',  # ⛁ (filled) → █
    '\u26c0': '\u2593',  # ⛀ (half) → ▓
    '\u26f6': '\u2591',  # ⛶ (empty) → ░
    '\u26dd': '\u2592',  # ⛝ (reserved) → ▒
})


def replace_bar_chars(text: str) -> str:
    """Replace Claude Code bar chart Unicode with standard block characters."""
    return text.translate(_BAR_CHARS)


class CommandHandler:
    """Executes slash commands by sending to tmux, capturing output, and broadcasting.

    Prefers transcript stdout (accurate, full-width) over pane capture (affected
    by tmux pane dimensions). Falls back to pane capture for overlay commands
    like /help where transcript only contains a dismissal notice.
    """

    INITIAL_DELAY = 0.3
    POLL_INTERVAL = 0.2
    MAX_TIMEOUT = 3.0
    TRANSCRIPT_POLL_TIMEOUT = 2.0
    RESPONSE_TIMEOUT = 60.0  # Long timeout for commands that trigger Claude

    def __init__(self, server: "ConnectServer"):
        self.server = server

    @staticmethod
    def _command_name(text: str) -> str:
        """Extract command name from slash command text."""
        return text.lstrip('/').split()[0].lower() if text.startswith('/') else ''

    async def execute(self, command_text: str) -> None:
        """Send a slash command to tmux, capture output, broadcast to iOS."""
        if not self.server._active_tmux_session:
            return

        session_name = self.server._active_tmux_session
        cmd_name = self._command_name(command_text)

        if cmd_name in _CLEAR_COMMANDS:
            await self._execute_clear_command(command_text, session_name)
        elif cmd_name in _RESPONSE_COMMANDS:
            await self._execute_response_command(command_text, session_name)
        else:
            await self._execute_ui_command(command_text, session_name)

    async def _execute_clear_command(self, command_text: str, session_name: str) -> None:
        """Handle /clear — send to tmux, then detect new transcript file."""
        await self.server.send_to_terminal(command_text)

        ctx = self.server._get_viewed_context()
        if ctx:
            await self.server._handle_clear_command(ctx)
        else:
            print("[CLEAR] No viewed session context, cannot detect new file")

    async def _execute_ui_command(self, command_text: str, session_name: str) -> None:
        """Handle UI/config commands — transcript stdout or pane capture."""
        baseline = self._transcript_line_count()

        await self.server.send_to_terminal(command_text)
        await asyncio.sleep(self.INITIAL_DELAY)

        transcript_output = await self._poll_transcript_stdout(baseline)

        if transcript_output and not self._is_dismissal(transcript_output):
            output = replace_bar_chars(strip_ansi(transcript_output)).strip()
        else:
            raw = await self._capture_stable_pane(session_name)
            output = replace_bar_chars(self._trim_output(strip_ansi(raw), command_text))

        self.server.tmux.send_escape(session_name)

        if not output.strip():
            output = "Command executed"

        await self.server.broadcast_message({
            "type": "command_response",
            "command": command_text,
            "output": output,
            "session_id": getattr(self.server, 'active_session_id', ''),
        })

    async def _execute_response_command(self, command_text: str, session_name: str) -> None:
        """Handle commands that trigger Claude to respond (e.g. /btw).

        /btw shows an overlay with the response and "Press Space, Enter, or
        Escape to dismiss". Poll for that dismiss prompt as the completion signal,
        then capture the pane and send Escape.
        """
        await self.server.send_to_terminal(command_text)

        # Show thinking state while waiting for response
        await self.server.broadcast_message({
            "type": "activity_status",
            "state": "thinking",
            "detail": ""
        })

        # Poll until the response overlay appears (contains dismiss prompt)
        deadline = time.time() + self.RESPONSE_TIMEOUT
        while time.time() < deadline:
            pane = self.server.tmux.capture_pane(session_name, include_history=False) or ""
            if 'to dismiss' in pane:
                break
            await asyncio.sleep(0.5)

        # Capture and process
        raw = self.server.tmux.capture_pane(session_name, include_history=False) or ""
        cleaned = strip_ansi(raw)

        # Extract just the response content between the command echo and dismiss prompt
        lines = cleaned.splitlines()
        start = -1
        end = len(lines)
        for i, line in enumerate(lines):
            cmd_name = command_text.lstrip('/').split()[0]
            if cmd_name in line and (line.strip().startswith('/') or line.strip().startswith('❯')):
                start = i + 1
            if 'to dismiss' in line:
                end = i
                break

        if start >= 0:
            lines = lines[start:end]
        else:
            lines = lines[:end]

        # Strip leading/trailing blanks
        while lines and not lines[0].strip():
            lines.pop(0)
        while lines and not lines[-1].strip():
            lines.pop()

        output = replace_bar_chars('\n'.join(lines))

        # Dismiss the overlay
        self.server.tmux.send_escape(session_name)

        if not output.strip():
            output = "Command executed"

        await self.server.broadcast_message({
            "type": "command_response",
            "command": command_text,
            "output": output,
            "session_id": getattr(self.server, 'active_session_id', ''),
        })

        await self.server.broadcast_message({
            "type": "activity_status",
            "state": "idle",
            "detail": ""
        })

    def _transcript_line_count(self) -> int:
        """Get current transcript file line count."""
        handler = getattr(self.server, 'transcript_handler', None)
        if not handler or not handler.expected_session_file:
            return 0
        try:
            with open(handler.expected_session_file, 'r') as f:
                return sum(1 for _ in f)
        except (FileNotFoundError, OSError):
            return 0

    async def _poll_transcript_stdout(self, baseline: int) -> Optional[str]:
        """Poll transcript for <local-command-stdout> content after baseline."""
        handler = getattr(self.server, 'transcript_handler', None)
        if not handler or not handler.expected_session_file:
            return None

        filepath = handler.expected_session_file
        deadline = time.time() + self.TRANSCRIPT_POLL_TIMEOUT

        while time.time() < deadline:
            try:
                with open(filepath, 'r') as f:
                    lines = f.readlines()
                for line in lines[baseline:]:
                    try:
                        entry = json.loads(line.strip())
                        content = entry.get('message', {}).get('content', '')
                        if isinstance(content, str):
                            match = STDOUT_RE.search(content)
                            if match:
                                return match.group(1)
                    except (json.JSONDecodeError, KeyError):
                        continue
            except (FileNotFoundError, OSError):
                pass
            await asyncio.sleep(self.POLL_INTERVAL)

        return None

    @staticmethod
    def _is_dismissal(text: str) -> bool:
        """Check if transcript stdout is just a dismissal notice (not useful output)."""
        stripped = text.strip().lower()
        return 'dismissed' in stripped and len(stripped) < 50

    async def _capture_stable_pane(self, session_name: str) -> str:
        """Poll pane until output stabilizes (2 identical captures in a row)."""
        deadline = time.time() + self.MAX_TIMEOUT
        prev = None
        while time.time() < deadline:
            current = self.server.tmux.capture_pane(session_name, include_history=False)
            if current is not None and current == prev:
                return current
            prev = current
            await asyncio.sleep(self.POLL_INTERVAL)
        return prev or ""

    def _trim_output(self, text: str, command_text: str) -> str:
        """Extract command output from pane capture.

        The pane contains previous content + command echo + output + trailing prompt.
        Find the command echo line and take only what follows it.
        """
        lines = text.splitlines()
        if not lines:
            return ""

        cmd_name = command_text.lstrip('/')

        # Find the LAST line matching the command echo (in case the command
        # name appears in earlier output too)
        echo_idx = -1
        for i, line in enumerate(lines):
            stripped = line.strip()
            if cmd_name in stripped and (stripped.startswith('❯') or stripped.startswith('/')):
                echo_idx = i

        # Take everything after the echo line
        if echo_idx >= 0:
            lines = lines[echo_idx + 1:]
        else:
            # No echo found (overlay command?) — use all lines, strip leading blanks
            while lines and not lines[0].strip():
                lines.pop(0)

        # Remove trailing prompt lines and empty lines
        while lines and (lines[-1].strip().startswith('❯') or not lines[-1].strip()):
            lines.pop()

        return '\n'.join(lines)
