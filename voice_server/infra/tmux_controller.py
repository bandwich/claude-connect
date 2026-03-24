"""Tmux-based Claude Code session control"""

import os
import subprocess
from typing import Optional


SESSION_PREFIX = "claude-connect"


def session_name_for(session_id: str) -> str:
    """Generate tmux session name from Claude session ID."""
    return f"{SESSION_PREFIX}_{session_id}"


class TmuxController:
    """Controls Claude Code sessions via tmux subprocess calls"""

    def is_available(self) -> bool:
        """Check if tmux is installed and available"""
        result = subprocess.run(
            ["tmux", "-V"],
            capture_output=True,
            text=True
        )
        return result.returncode == 0

    def session_exists(self, session_name: str) -> bool:
        """Check if a tmux session is running"""
        result = subprocess.run(
            ["tmux", "has-session", "-t", session_name],
            capture_output=True,
            text=True
        )
        return result.returncode == 0

    def kill_session(self, session_name: str) -> bool:
        """Kill a tmux session

        Returns:
            True if killed successfully
        """
        result = subprocess.run(
            ["tmux", "kill-session", "-t", session_name],
            capture_output=True,
            text=True
        )
        return result.returncode == 0

    def start_session(
        self,
        session_name: str,
        working_dir: Optional[str] = None,
        resume_id: Optional[str] = None,
        env: Optional[dict[str, str]] = None,
    ) -> bool:
        """Start a new tmux session running Claude Code

        Args:
            session_name: Tmux session name
            working_dir: Directory to start the session in
            resume_id: If set, runs 'claude --resume <id>'
            env: Extra environment variables to set in the tmux session

        Returns:
            True if session started successfully
        """
        # Ensure working directory exists (e.g., /tmp may be cleared on reboot)
        if working_dir:
            os.makedirs(working_dir, exist_ok=True)

        # Build the claude command
        if resume_id:
            cmd = f"claude --resume {resume_id}"
        else:
            cmd = "claude"

        # Prepend env var exports if provided
        if env:
            exports = " ".join(f"{k}={v}" for k, v in env.items())
            cmd = f"export {exports} && {cmd}"

        # Build tmux command
        tmux_cmd = [
            "tmux", "new-session",
            "-d",  # Detached
            "-s", session_name,
        ]

        if working_dir:
            tmux_cmd.extend(["-c", working_dir])

        tmux_cmd.append(cmd)

        result = subprocess.run(tmux_cmd, capture_output=True, text=True)
        return result.returncode == 0

    def send_input(self, session_name: str, text: str) -> bool:
        """Send text input to a tmux session

        Args:
            session_name: Tmux session name
            text: Text to send (Enter key added automatically)

        Returns:
            True if sent successfully
        """
        # Must send text and Enter as a single shell command for it to work
        # Escape single quotes in text for shell safety
        escaped_text = text.replace("'", "'\"'\"'")
        # Multi-line text triggers Claude Code's paste detection, which shows
        # "[Pasted text #1 +N lines]" and waits for Enter to confirm the paste,
        # then waits for another Enter to submit. Send two Enters for multi-line.
        has_newlines = '\n' in text
        enter_cmd = f"tmux send-keys -t {session_name} Enter"
        cmd = f"tmux send-keys -t {session_name} '{escaped_text}' && {enter_cmd}"
        if has_newlines:
            cmd += f" && sleep 0.3 && {enter_cmd}"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return result.returncode == 0

    def send_escape(self, session_name: str) -> bool:
        """Send Escape key to a tmux session to interrupt current operation.

        Returns:
            True if sent successfully
        """
        result = subprocess.run(
            ["tmux", "send-keys", "-t", session_name, "Escape"],
            capture_output=True,
            text=True
        )
        return result.returncode == 0

    def capture_pane(self, session_name: str, include_history: bool = True) -> Optional[str]:
        """Capture the current pane content

        Args:
            session_name: Tmux session name
            include_history: If True, capture scrollback buffer too

        Returns:
            Pane content as string, or None if session doesn't exist
        """
        cmd = ["tmux", "capture-pane", "-t", session_name, "-p"]
        if include_history:
            cmd.extend(["-S", "-"])  # Capture from start of scrollback
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return None
        return result.stdout

    def list_sessions(self) -> list[str]:
        """List all claude-connect tmux sessions.

        Returns:
            List of tmux session names matching the claude-connect prefix
        """
        result = subprocess.run(
            ["tmux", "list-sessions", "-F", "#{session_name}"],
            capture_output=True,
            text=True
        )
        if result.returncode != 0:
            return []
        return [
            name.strip() for name in result.stdout.strip().split("\n")
            if name.strip().startswith(f"{SESSION_PREFIX}_")
        ]

    def cleanup_all(self) -> int:
        """Kill all claude-connect tmux sessions.

        Returns:
            Number of sessions killed
        """
        sessions = self.list_sessions()
        killed = 0
        for name in sessions:
            if self.kill_session(name):
                killed += 1
        return killed
