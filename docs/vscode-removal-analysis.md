# VSCode Removal Analysis

## Current Architecture

```
iPhone → WebSocket → Server → VSCode Terminal → Claude Code CLI
                                    ↑
                          (text injection via AppleScript
                           or VSCode WebSocket extension)
```

## What VSCode Actually Does

VSCode serves as **a terminal host** where Claude Code CLI runs. The server:
1. Injects voice-transcribed text into VSCode's terminal
2. Watches transcript files Claude writes to disk
3. Streams responses back to iPhone

That's it. VSCode is essentially acting as a **glorified terminal**.

## Can VSCode Be Removed? Yes.

Here are the replacement options:

---

### Option 1: Use Terminal.app or iTerm2

Replace VSCode with native macOS Terminal:
```applescript
tell application "Terminal"
    activate
    do script "claude --resume session_id"
end tell
```

AppleScript can target any terminal emulator the same way it currently targets VSCode.

**Pros:**
- Minimal changes to existing code
- Still have visible terminal for debugging

**Cons:**
- Still depends on AppleScript (fragile)
- Still requires GUI/display

---

### Option 2: Headless via tmux/screen (most elegant)

Run Claude Code in a detached tmux session:
```bash
# Start session
tmux new-session -d -s claude_voice "claude --resume $SESSION_ID"

# Send voice input
tmux send-keys -t claude_voice "user's voice input" Enter

# Kill session
tmux kill-session -t claude_voice
```

**Pros:**
- No GUI needed at all
- Works over SSH
- Survives disconnections
- Multiple sessions trivially
- No AppleScript fragility
- Can run as headless daemon

**Cons:**
- Requires tmux installed (`brew install tmux`)
- Slightly different mental model

---

### Option 3: Direct Subprocess (most control)

Run Claude Code as a subprocess with direct stdin/stdout:
```python
import subprocess
import asyncio

class ClaudeSubprocess:
    def __init__(self):
        self.proc = None

    async def start_session(self, session_id: str = None):
        cmd = ["claude"]
        if session_id:
            cmd.extend(["--resume", session_id])

        self.proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE
        )

    async def send_input(self, text: str):
        if self.proc and self.proc.stdin:
            self.proc.stdin.write(f"{text}\n".encode())
            await self.proc.stdin.drain()

    async def stop(self):
        if self.proc:
            self.proc.terminate()
            await self.proc.wait()
```

**Pros:**
- Complete programmatic control
- No AppleScript fragility
- No external dependencies
- Could run as a daemon
- Cleanest architecture

**Cons:**
- Need to handle stdout/stderr properly
- Claude Code may expect a TTY (might need `pty` module)
- Permission prompts might behave differently without TTY

---

### Option 4: PTY-based Subprocess (if TTY needed)

If Claude Code requires a TTY for proper operation:
```python
import pty
import os
import select

class ClaudePTY:
    def __init__(self):
        self.master_fd = None
        self.pid = None

    def start_session(self, session_id: str = None):
        cmd = ["claude"]
        if session_id:
            cmd.extend(["--resume", session_id])

        self.pid, self.master_fd = pty.fork()
        if self.pid == 0:
            # Child process
            os.execvp("claude", cmd)

    def send_input(self, text: str):
        os.write(self.master_fd, f"{text}\n".encode())

    def read_output(self, timeout=0.1):
        if select.select([self.master_fd], [], [], timeout)[0]:
            return os.read(self.master_fd, 4096).decode()
        return None
```

**Pros:**
- Full TTY emulation
- Claude Code behaves exactly as in terminal
- Complete control

**Cons:**
- More complex code
- Need to parse ANSI escape codes from output

---

## What Remains Unchanged

These parts work regardless of how Claude Code is launched:

| Component | Why It's Unaffected |
|-----------|---------------------|
| **Transcript watching** | Claude writes to `~/.claude/projects/*/session.jsonl` regardless of terminal |
| **Permission hooks** | Hook system is a Claude Code feature, not VSCode |
| **TTS/Audio streaming** | Completely independent of terminal |
| **iOS app** | No changes needed - same WebSocket protocol |
| **Session management** | Sessions are stored in filesystem, not VSCode |

---

## Recommendation

**tmux approach** would be the cleanest balance of simplicity and robustness:

1. No AppleScript fragility
2. No GUI dependency
3. Easy session management (`tmux list-sessions`, `tmux kill-session`)
4. Can run truly headless (server-only, no display needed)
5. Battle-tested, widely available
6. Easy debugging (can attach to session: `tmux attach -t claude_voice`)

The VSCode controller (`vscode_controller.py`) could be replaced with a `tmux_controller.py` of ~50-100 lines.

---

## Implementation Sketch: tmux_controller.py

```python
import subprocess
import asyncio
from typing import Optional

class TmuxController:
    """Controls Claude Code sessions via tmux."""

    SESSION_PREFIX = "claude_voice_"

    def __init__(self):
        self.active_session: Optional[str] = None

    def _tmux(self, *args) -> subprocess.CompletedProcess:
        """Run a tmux command."""
        return subprocess.run(
            ["tmux"] + list(args),
            capture_output=True,
            text=True
        )

    def session_exists(self, session_name: str) -> bool:
        """Check if a tmux session exists."""
        result = self._tmux("has-session", "-t", session_name)
        return result.returncode == 0

    def new_session(self, claude_session_id: Optional[str] = None) -> str:
        """Start a new Claude Code session in tmux."""
        session_name = f"{self.SESSION_PREFIX}{claude_session_id or 'new'}"

        # Kill existing session if present
        if self.session_exists(session_name):
            self._tmux("kill-session", "-t", session_name)

        # Build claude command
        cmd = "claude"
        if claude_session_id:
            cmd = f"claude --resume {claude_session_id}"

        # Create detached session running claude
        self._tmux(
            "new-session",
            "-d",           # Detached
            "-s", session_name,
            cmd
        )

        self.active_session = session_name
        return session_name

    def send_input(self, text: str, session_name: Optional[str] = None):
        """Send text input to the Claude session."""
        target = session_name or self.active_session
        if not target:
            raise RuntimeError("No active session")

        # Send keys to the tmux session
        self._tmux("send-keys", "-t", target, text, "Enter")

    def send_approval(self, approved: bool, session_name: Optional[str] = None):
        """Send y/n for permission prompts."""
        self.send_input("y" if approved else "n", session_name)

    def kill_session(self, session_name: Optional[str] = None):
        """Kill a Claude session."""
        target = session_name or self.active_session
        if target and self.session_exists(target):
            self._tmux("kill-session", "-t", target)
        if target == self.active_session:
            self.active_session = None

    def list_sessions(self) -> list[str]:
        """List all claude_voice tmux sessions."""
        result = self._tmux("list-sessions", "-F", "#{session_name}")
        if result.returncode != 0:
            return []
        return [
            s for s in result.stdout.strip().split("\n")
            if s.startswith(self.SESSION_PREFIX)
        ]

    def attach_session(self, session_name: str):
        """Attach to a session (for debugging)."""
        subprocess.run(["tmux", "attach", "-t", session_name])
```

---

## Migration Path

1. Create `tmux_controller.py` alongside `vscode_controller.py`
2. Add config option to choose controller: `"terminal": "tmux" | "vscode"`
3. Test tmux controller independently
4. Gradually migrate, keeping VSCode as fallback
5. Once stable, remove VSCode dependency entirely

---

## Questions to Investigate

1. **Does Claude Code require a TTY?** - Test running `claude` in tmux detached mode
2. **Permission hook behavior** - Verify hooks work the same in tmux
3. **Session ID extraction** - Currently read from transcript files, should still work
4. **Startup timing** - May need to wait for Claude to initialize before sending input
