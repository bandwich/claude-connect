"""Tmux-based Claude Code session control"""

import os
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

        # Ensure working directory exists (e.g., /tmp may be cleared on reboot)
        if working_dir:
            os.makedirs(working_dir, exist_ok=True)

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
        # Must send text and Enter as a single shell command for it to work
        # Escape single quotes in text for shell safety
        escaped_text = text.replace("'", "'\"'\"'")
        # Multi-line text triggers Claude Code's paste detection, which shows
        # "[Pasted text #1 +N lines]" and waits for Enter to confirm the paste,
        # then waits for another Enter to submit. Send two Enters for multi-line.
        has_newlines = '\n' in text
        enter_cmd = f"tmux send-keys -t {self.SESSION_NAME} Enter"
        cmd = f"tmux send-keys -t {self.SESSION_NAME} '{escaped_text}' && {enter_cmd}"
        if has_newlines:
            cmd += f" && sleep 0.3 && {enter_cmd}"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return result.returncode == 0

    def send_escape(self) -> bool:
        """Send Escape key to the Claude session to interrupt current operation.

        Returns:
            True if sent successfully
        """
        result = subprocess.run(
            ["tmux", "send-keys", "-t", self.SESSION_NAME, "Escape"],
            capture_output=True,
            text=True
        )
        return result.returncode == 0

    def capture_pane(self, include_history: bool = True) -> Optional[str]:
        """Capture the current pane content

        Args:
            include_history: If True, capture scrollback buffer too

        Returns:
            Pane content as string, or None if session doesn't exist
        """
        cmd = ["tmux", "capture-pane", "-t", self.SESSION_NAME, "-p"]
        if include_history:
            cmd.extend(["-S", "-"])  # Capture from start of scrollback
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return None
        return result.stdout
