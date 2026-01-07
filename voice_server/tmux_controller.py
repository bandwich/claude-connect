"""Tmux-based Claude Code session control"""

import subprocess
from typing import Optional


class TmuxController:
    """Controls Claude Code sessions via tmux subprocess calls"""

    SESSION_NAME = "claude_voice"

    def is_available(self) -> bool:
        """Check if tmux is installed and available"""
        result = subprocess.run(
            ["tmux", "-V"],
            capture_output=True,
            text=True
        )
        return result.returncode == 0

    def session_exists(self) -> bool:
        """Check if the claude_voice tmux session is running"""
        result = subprocess.run(
            ["tmux", "has-session", "-t", self.SESSION_NAME],
            capture_output=True,
            text=True
        )
        return result.returncode == 0

    def kill_session(self) -> bool:
        """Kill the active Claude session

        Returns:
            True if killed successfully
        """
        result = subprocess.run(
            ["tmux", "kill-session", "-t", self.SESSION_NAME],
            capture_output=True,
            text=True
        )
        return result.returncode == 0

    def start_session(self, working_dir: Optional[str] = None, resume_id: Optional[str] = None) -> bool:
        """Start a new tmux session running Claude Code

        Args:
            working_dir: Directory to start the session in
            resume_id: If set, runs 'claude --resume <id>'

        Returns:
            True if session started successfully
        """
        # Kill existing session first (one at a time)
        if self.session_exists():
            self.kill_session()

        # Build the claude command
        if resume_id:
            cmd = f"claude --resume {resume_id}"
        else:
            cmd = "claude"

        # Build tmux command
        tmux_cmd = [
            "tmux", "new-session",
            "-d",  # Detached
            "-s", self.SESSION_NAME,
        ]

        if working_dir:
            tmux_cmd.extend(["-c", working_dir])

        tmux_cmd.append(cmd)

        result = subprocess.run(tmux_cmd, capture_output=True, text=True)
        return result.returncode == 0

    def send_input(self, text: str) -> bool:
        """Send text input to the Claude session

        Args:
            text: Text to send (Enter key added automatically)

        Returns:
            True if sent successfully
        """
        # Send text and Enter as separate calls - combining them causes
        # tmux to misinterpret Enter as a literal string
        result1 = subprocess.run(
            ["tmux", "send-keys", "-t", self.SESSION_NAME, text],
            capture_output=True,
            text=True
        )
        if result1.returncode != 0:
            return False

        result2 = subprocess.run(
            ["tmux", "send-keys", "-t", self.SESSION_NAME, "Enter"],
            capture_output=True,
            text=True
        )
        return result2.returncode == 0
