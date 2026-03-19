# Multi-Session Support — Phase 1: Server

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Refactor the server to manage multiple concurrent Claude Code sessions (up to 5), each with its own tmux session, transcript watcher, and pane poller.

**Architecture:** Replace VoiceServer's single-session state fields with a `SessionContext` dict keyed by session_id. Parameterize TmuxController to accept session names. Route permission hooks via `CLAUDE_CONNECT_SESSION_ID` env var. Add `viewed_session_id` to control which session receives input and TTS.

**Tech Stack:** Python, asyncio, tmux, watchdog, aiohttp, pytest

**Risky Assumptions:** The `CLAUDE_CONNECT_SESSION_ID` env var must flow from tmux → Claude Code → hook scripts → HTTP POST. We verify this in Task 4 with an integration test before building on it.

**Design doc:** `docs/plans/2026-03-18/multi-session-design.md`

---

### Task 1: Parameterize TmuxController

**Files:**
- Modify: `voice_server/tmux_controller.py`
- Modify: `voice_server/tests/test_tmux_controller.py`

**Step 1: Update TmuxController to accept session_name parameter**

Replace the hardcoded `SESSION_NAME` class constant. All methods take an explicit `session_name` parameter. Add `session_name_for()` helper and `cleanup_all()`.

```python
# voice_server/tmux_controller.py
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
```

**Step 2: Update tests**

```python
# voice_server/tests/test_tmux_controller.py
"""
Tests for TmuxController - uses REAL tmux, no mocking.

These tests actually create/kill tmux sessions. If they pass,
the functionality works. If they fail, something is actually broken.
"""
import pytest
import subprocess
import time
import os
import sys

from voice_server.tmux_controller import TmuxController, session_name_for, SESSION_PREFIX


TEST_SESSION = "claude-connect_test-session-1"
TEST_SESSION_2 = "claude-connect_test-session-2"


@pytest.fixture
def controller():
    """Provide a controller and ensure cleanup after test"""
    ctrl = TmuxController()
    yield ctrl
    # Cleanup: kill test sessions if they exist
    for name in [TEST_SESSION, TEST_SESSION_2]:
        subprocess.run(
            ["tmux", "kill-session", "-t", name],
            capture_output=True
        )


@pytest.fixture
def ensure_no_session():
    """Ensure no test sessions exist before test"""
    for name in [TEST_SESSION, TEST_SESSION_2]:
        subprocess.run(
            ["tmux", "kill-session", "-t", name],
            capture_output=True
        )
    yield
    for name in [TEST_SESSION, TEST_SESSION_2]:
        subprocess.run(
            ["tmux", "kill-session", "-t", name],
            capture_output=True
        )


class TestSessionNameFor:
    """Tests for session_name_for helper"""

    def test_generates_prefixed_name(self):
        assert session_name_for("abc-123") == "claude-connect_abc-123"

    def test_prefix_constant(self):
        assert SESSION_PREFIX == "claude-connect"


class TestTmuxAvailability:
    """Tests for tmux availability check"""

    def test_is_available_returns_true_when_tmux_installed(self, controller):
        assert controller.is_available() is True


class TestSessionManagement:
    """Tests for session lifecycle with parameterized names"""

    def test_session_exists_false_when_no_session(self, controller, ensure_no_session):
        assert controller.session_exists(TEST_SESSION) is False

    def test_start_and_check_session(self, controller, ensure_no_session):
        result = controller.start_session(TEST_SESSION, working_dir="/tmp")
        assert result is True
        time.sleep(0.5)
        assert controller.session_exists(TEST_SESSION) is True

    def test_start_two_sessions(self, controller, ensure_no_session):
        """Starting two sessions with different names both stay alive"""
        assert controller.start_session(TEST_SESSION, working_dir="/tmp") is True
        assert controller.start_session(TEST_SESSION_2, working_dir="/tmp") is True
        time.sleep(0.5)
        assert controller.session_exists(TEST_SESSION) is True
        assert controller.session_exists(TEST_SESSION_2) is True

    def test_kill_one_session_leaves_other(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        controller.start_session(TEST_SESSION_2, working_dir="/tmp")
        time.sleep(0.5)
        controller.kill_session(TEST_SESSION)
        time.sleep(0.3)
        assert controller.session_exists(TEST_SESSION) is False
        assert controller.session_exists(TEST_SESSION_2) is True

    def test_kill_session(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        time.sleep(0.5)
        result = controller.kill_session(TEST_SESSION)
        assert result is True
        time.sleep(0.3)
        assert controller.session_exists(TEST_SESSION) is False

    def test_start_session_with_env(self, controller, ensure_no_session):
        """Env vars are set in the tmux session"""
        controller.start_session(
            TEST_SESSION,
            working_dir="/tmp",
            env={"CLAUDE_CONNECT_SESSION_ID": "test-id-123"}
        )
        time.sleep(0.5)
        # Verify env var by capturing pane after echo
        subprocess.run(
            ["tmux", "send-keys", "-t", TEST_SESSION,
             "echo $CLAUDE_CONNECT_SESSION_ID", "Enter"],
            capture_output=True
        )
        time.sleep(0.5)
        pane = controller.capture_pane(TEST_SESSION, include_history=False)
        assert pane is not None
        assert "test-id-123" in pane


class TestListAndCleanup:
    """Tests for list_sessions and cleanup_all"""

    def test_list_sessions_empty(self, controller, ensure_no_session):
        sessions = controller.list_sessions()
        # Filter to only test sessions in case other claude-connect sessions exist
        test_sessions = [s for s in sessions if s in [TEST_SESSION, TEST_SESSION_2]]
        assert test_sessions == []

    def test_list_sessions_finds_sessions(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        controller.start_session(TEST_SESSION_2, working_dir="/tmp")
        time.sleep(0.5)
        sessions = controller.list_sessions()
        assert TEST_SESSION in sessions
        assert TEST_SESSION_2 in sessions

    def test_cleanup_all(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        controller.start_session(TEST_SESSION_2, working_dir="/tmp")
        time.sleep(0.5)
        killed = controller.cleanup_all()
        assert killed >= 2
        time.sleep(0.3)
        assert controller.session_exists(TEST_SESSION) is False
        assert controller.session_exists(TEST_SESSION_2) is False


class TestInputAndCapture:
    """Tests for send_input, send_escape, and capture_pane with session names"""

    def test_capture_pane(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        time.sleep(0.5)
        content = controller.capture_pane(TEST_SESSION, include_history=False)
        assert content is not None

    def test_capture_pane_nonexistent(self, controller, ensure_no_session):
        content = controller.capture_pane("nonexistent-session")
        assert content is None

    def test_send_input(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        time.sleep(0.5)
        result = controller.send_input(TEST_SESSION, "echo hello-from-test")
        assert result is True
        time.sleep(0.5)
        content = controller.capture_pane(TEST_SESSION, include_history=False)
        assert content is not None
        assert "hello-from-test" in content

    def test_send_escape(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        time.sleep(0.5)
        result = controller.send_escape(TEST_SESSION)
        assert result is True
```

**Step 3: Run tests to verify**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && python -m pytest test_tmux_controller.py -v`
Expected: All tests pass

**Step 4: Update all callers in ios_server.py**

Every call to `self.tmux.session_exists()`, `self.tmux.kill_session()`, `self.tmux.start_session(...)`, `self.tmux.send_input(...)`, `self.tmux.send_escape()`, `self.tmux.capture_pane(...)` needs to pass the session name.

For now, use a temporary helper property to avoid breaking everything at once:

Add to VoiceServer `__init__`:
```python
self._active_tmux_session = None  # Track current tmux session name
```

Then update each caller to pass the session name. The key callers are:
- `handle_new_session` (line ~1251): `self.tmux.start_session(...)` → pass `session_name`
- `handle_resume_session` (line ~1302): same
- `handle_close_session` (line ~1160): `self.tmux.kill_session()`
- `send_to_terminal` (line ~661): `self.tmux.send_input(text)`
- `handle_interrupt` (line ~1086): `self.tmux.send_escape()`
- `_pane_poll_loop` (line ~1065): `self.tmux.session_exists()` and `capture_pane()`
- `poll_claude_ready` (line ~1216): `self.tmux.capture_pane()`
- `send_connection_status` (line ~644): `self.tmux.session_exists()`
- `broadcast_connection_status` (line ~651): calls `send_connection_status`
- `reset_state` (line ~1231): `self.tmux.kill_session()`
- `start()` (line ~1641): `self.tmux.is_available()` (no change needed — no session_name)

Also update `http_server.py`:
- `handle_tmux_status` (line ~262): `_tmux_controller.session_exists()` — needs a session name, use server's active
- `handle_capture_pane` (line ~272): `_tmux_controller.capture_pane()` — same

For this task, use `self._active_tmux_session` as the session name for all single-session callers. This preserves current behavior while making the API correct.

**Step 5: Run full test suite**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh`
Expected: All tests pass (some may need updating for the new API)

**Step 6: Commit**

```bash
git add voice_server/tmux_controller.py voice_server/tests/test_tmux_controller.py voice_server/ios_server.py voice_server/http_server.py
git commit -m "refactor: parameterize TmuxController to accept session names"
```

---

### Task 2: Create SessionContext and Refactor VoiceServer State

**Files:**
- Create: `voice_server/session_context.py`
- Modify: `voice_server/ios_server.py`

**Step 1: Create SessionContext class**

```python
# voice_server/session_context.py
"""Per-session state container for multi-session support"""

import asyncio
from dataclasses import dataclass, field
from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from watchdog.observers import Observer


MAX_ACTIVE_SESSIONS = 5


@dataclass
class SessionContext:
    """Bundles all state for one active Claude Code session."""

    session_id: str  # Claude session ID (may be None for new sessions)
    folder_name: str  # Project folder name
    tmux_session_name: str  # e.g. "claude-connect_<session_id>"
    transcript_path: Optional[str] = None
    observer: Optional["Observer"] = None
    reconciliation_task: Optional[asyncio.Task] = None
    last_activity_state: object = None  # ActivityState from pane_parser
    current_branch: str = ""
    # For deferred new-session detection
    pending_session_snapshot: Optional[tuple] = None
    # Echo dedup
    last_voice_input: Optional[str] = None
    waiting_for_response: bool = False

    def cleanup(self):
        """Cancel async tasks and stop observer. Does NOT kill tmux."""
        if self.reconciliation_task and not self.reconciliation_task.done():
            self.reconciliation_task.cancel()
            self.reconciliation_task = None
        if self.observer:
            self.observer.unschedule_all()
            # Don't stop observer here — it may be shared or restarted
```

**Step 2: Refactor VoiceServer to use active_sessions dict**

In `voice_server/ios_server.py`, replace single-session fields with:

```python
# In __init__, replace these fields:
#   self.active_session_id = None
#   self.active_folder_name = None
#   self._pending_session_snapshot = None
#   self.current_branch = ""
#   self._active_tmux_session = None
#   self.waiting_for_response = False
#   self.last_voice_input = None
#   self._last_activity_state = None
#   self._reconciliation_task = None
# With:
from voice_server.session_context import SessionContext, MAX_ACTIVE_SESSIONS

self.active_sessions: dict[str, SessionContext] = {}  # tmux_session_name -> SessionContext
self.viewed_session_id: Optional[str] = None  # Which session the iOS app is viewing
```

Then add helper methods:

```python
def _get_viewed_context(self) -> Optional[SessionContext]:
    """Get the SessionContext for the currently viewed session."""
    if not self.viewed_session_id:
        return None
    for ctx in self.active_sessions.values():
        if ctx.session_id == self.viewed_session_id:
            return ctx
    return None

def _get_context_by_tmux_name(self, tmux_name: str) -> Optional[SessionContext]:
    """Get SessionContext by tmux session name."""
    return self.active_sessions.get(tmux_name)

def _get_context_by_session_id(self, session_id: str) -> Optional[SessionContext]:
    """Get SessionContext by Claude session ID."""
    for ctx in self.active_sessions.values():
        if ctx.session_id == session_id:
            return ctx
    return None
```

**Step 3: Update VoiceServer properties that read single-session state**

Create compatibility properties so the rest of the code keeps working during migration:

```python
@property
def active_session_id(self):
    ctx = self._get_viewed_context()
    return ctx.session_id if ctx else None

@property
def active_folder_name(self):
    ctx = self._get_viewed_context()
    return ctx.folder_name if ctx else None

@property
def transcript_path(self):
    ctx = self._get_viewed_context()
    return ctx.transcript_path if ctx else None

@property
def _active_tmux_session(self):
    ctx = self._get_viewed_context()
    return ctx.tmux_session_name if ctx else None
```

Note: These are transitional. They let existing code work while we migrate method-by-method. The setters need to be handled case-by-case in the caller sites.

**Step 4: Update `send_to_terminal` to use viewed session**

```python
async def send_to_terminal(self, text: str):
    """Send text to Claude Code terminal via tmux"""
    ctx = self._get_viewed_context()
    if not ctx:
        print("[DEBUG] send_to_terminal: no viewed session")
        return
    print(f"[DEBUG] send_to_terminal: session={ctx.tmux_session_name}")
    result = self.tmux.send_input(ctx.tmux_session_name, text)
    print(f"[DEBUG] send_input returned: {result}")

    # If we have a pending snapshot, resolve it now
    await self._resolve_pending_session(ctx)
```

**Step 5: Update `handle_interrupt` to use viewed session**

```python
async def handle_interrupt(self):
    """Handle interrupt request from iOS - send Escape to tmux"""
    ctx = self._get_viewed_context()
    if ctx and self.tmux.session_exists(ctx.tmux_session_name):
        self.tmux.send_escape(ctx.tmux_session_name)
        print(f"[{time.strftime('%H:%M:%S')}] Sent interrupt to {ctx.tmux_session_name}")
```

**Step 6: Update `send_connection_status` for multi-session**

```python
async def send_connection_status(self, websocket):
    """Send connection status to a single client"""
    active_session_ids = [
        ctx.session_id for ctx in self.active_sessions.values()
        if ctx.session_id and self.tmux.session_exists(ctx.tmux_session_name)
    ]
    ctx = self._get_viewed_context()
    response = {
        "type": "connection_status",
        "connected": ctx is not None and self.tmux.session_exists(ctx.tmux_session_name) if ctx else False,
        "active_session_id": self.viewed_session_id,
        "active_session_ids": active_session_ids,
        "branch": ctx.current_branch if ctx else ""
    }
    await websocket.send(json.dumps(response))
```

**Step 7: Run tests**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh`
Expected: Tests pass (some may need updates for the refactored state)

**Step 8: Commit**

```bash
git add voice_server/session_context.py voice_server/ios_server.py
git commit -m "refactor: extract SessionContext and add active_sessions dict"
```

---

### Task 3: Multi-Session Lifecycle Handlers

**Files:**
- Modify: `voice_server/ios_server.py`

**Step 1: Rewrite `handle_new_session` for multi-session**

Instead of `_reset_session_state()`, create a new `SessionContext` and add it to the dict.

```python
async def handle_new_session(self, websocket, data):
    """Handle new_session request - starts claude in tmux"""
    project_path = data.get("project_path", "")
    print(f"[DEBUG] handle_new_session: project_path={project_path}")

    # Check session limit
    if len(self.active_sessions) >= MAX_ACTIVE_SESSIONS:
        await websocket.send(json.dumps({
            "type": "session_created",
            "success": False,
            "error": f"Maximum {MAX_ACTIVE_SESSIONS} active sessions reached"
        }))
        return

    # Generate a temporary tmux session name (will be updated when session ID is known)
    import uuid
    temp_id = f"pending-{uuid.uuid4().hex[:8]}"
    tmux_name = session_name_for(temp_id)

    # Snapshot existing session IDs BEFORE starting Claude
    existing_ids = set()
    folder_name = None
    if project_path:
        folder_name = self.session_manager.encode_path_to_folder(project_path)
        existing_ids = self.session_manager.list_session_ids(folder_name)
        print(f"[DEBUG] Snapshot: {len(existing_ids)} existing sessions in {folder_name}")

    success = self.tmux.start_session(
        tmux_name,
        working_dir=project_path if project_path else None,
        env={"CLAUDE_CONNECT_SESSION_ID": temp_id}
    )
    print(f"[DEBUG] start_session returned: {success}")

    error = None
    if success:
        ready = await self.poll_claude_ready(tmux_name)
        if ready:
            # Create SessionContext
            ctx = SessionContext(
                session_id=None,  # Unknown until first transcript line
                folder_name=folder_name or "",
                tmux_session_name=tmux_name,
            )
            if folder_name:
                ctx.pending_session_snapshot = (folder_name, existing_ids)
            self.active_sessions[tmux_name] = ctx
            self.viewed_session_id = None  # Will be set once session ID is detected

            # Set up transcript watching for this context
            self._setup_transcript_watcher(ctx)

            print(f"[INFO] New session started: tmux={tmux_name}")
        else:
            self.tmux.kill_session(tmux_name)
            success = False
            error = "Claude failed to start"
    else:
        error = "Failed to start tmux session"

    response = {"type": "session_created", "success": success}
    if error:
        response["error"] = error
    await websocket.send(json.dumps(response))

    if success:
        await self.broadcast_connection_status()
```

**Step 2: Rewrite `handle_resume_session` for multi-session**

```python
async def handle_resume_session(self, websocket, data):
    """Handle resume_session request - runs 'claude --resume <id>' in tmux"""
    session_id = data.get("session_id", "")
    folder_name = data.get("folder_name", "")

    # Check if this session is already active
    existing_ctx = self._get_context_by_session_id(session_id)
    if existing_ctx:
        # Already running — just switch view to it
        self.viewed_session_id = session_id
        await websocket.send(json.dumps({
            "type": "session_resumed",
            "success": True,
            "session_id": session_id
        }))
        await self.broadcast_connection_status()
        return

    # Check session limit
    if len(self.active_sessions) >= MAX_ACTIVE_SESSIONS:
        await websocket.send(json.dumps({
            "type": "session_resumed",
            "success": False,
            "session_id": session_id,
            "error": f"Maximum {MAX_ACTIVE_SESSIONS} active sessions reached"
        }))
        return

    tmux_name = session_name_for(session_id)
    success = False
    error = None

    if session_id:
        working_dir = None
        if folder_name and session_id:
            working_dir = self.session_manager.get_session_cwd(folder_name, session_id)

        success = self.tmux.start_session(
            tmux_name,
            working_dir=working_dir,
            resume_id=session_id,
            env={"CLAUDE_CONNECT_SESSION_ID": session_id}
        )

        if success:
            ready = await self.poll_claude_ready(tmux_name)
            if ready:
                ctx = SessionContext(
                    session_id=session_id,
                    folder_name=folder_name,
                    tmux_session_name=tmux_name,
                )
                self.active_sessions[tmux_name] = ctx
                self.viewed_session_id = session_id

                # Set up transcript watching
                self._setup_transcript_watcher(ctx)
                if folder_name:
                    self._switch_context_to_session(ctx, folder_name, session_id)

                print(f"[INFO] Resumed session: {session_id}, tmux={tmux_name}")
            else:
                self.tmux.kill_session(tmux_name)
                success = False
                error = "Claude failed to start"
        else:
            error = "Failed to start tmux session"

    response = {
        "type": "session_resumed",
        "success": success,
        "session_id": session_id
    }
    if error:
        response["error"] = error
    await websocket.send(json.dumps(response))

    if success:
        await self.broadcast_connection_status()
```

**Step 3: Add `handle_stop_session` and `handle_view_session`**

```python
async def handle_stop_session(self, websocket, data):
    """Handle stop_session request - kills one session's tmux"""
    session_id = data.get("session_id", "")
    ctx = self._get_context_by_session_id(session_id)

    success = False
    if ctx:
        ctx.cleanup()
        success = self.tmux.kill_session(ctx.tmux_session_name)
        self.active_sessions.pop(ctx.tmux_session_name, None)
        if self.viewed_session_id == session_id:
            self.viewed_session_id = None

    await websocket.send(json.dumps({
        "type": "session_stopped",
        "success": success,
        "session_id": session_id
    }))
    await self.broadcast_connection_status()

async def handle_view_session(self, websocket, data):
    """Handle view_session request - switch which session the app is viewing"""
    session_id = data.get("session_id", "")
    ctx = self._get_context_by_session_id(session_id)
    if ctx:
        self.viewed_session_id = session_id
        print(f"[INFO] Viewing session: {session_id}")
        await self.broadcast_connection_status()
```

**Step 4: Update `handle_close_session` to use `handle_stop_session`**

Replace `handle_close_session` to delegate to the new handler:

```python
async def handle_close_session(self, websocket):
    """Handle close_session request — stop the viewed session"""
    if self.viewed_session_id:
        await self.handle_stop_session(websocket, {"session_id": self.viewed_session_id})
    else:
        await websocket.send(json.dumps({
            "type": "session_closed",
            "success": False
        }))
```

**Step 5: Wire new message types into `handle_message`**

In the message dispatch (around line 1570), add:

```python
elif msg_type == 'stop_session':
    await self.handle_stop_session(websocket, data)
elif msg_type == 'view_session':
    await self.handle_view_session(websocket, data)
```

**Step 6: Update `handle_list_sessions` to include active session IDs**

```python
async def handle_list_sessions(self, websocket, data):
    """Handle list_sessions request"""
    folder_name = data.get("folder_name", "")
    sessions = self.session_manager.list_sessions(folder_name)

    active_ids = [
        ctx.session_id for ctx in self.active_sessions.values()
        if ctx.session_id and ctx.folder_name == folder_name
    ]

    response = {
        "type": "sessions",
        "sessions": [
            {
                "id": s.id,
                "title": s.title,
                "timestamp": s.timestamp,
                "message_count": s.message_count
            }
            for s in sessions
        ],
        "active_session_ids": active_ids
    }
    await websocket.send(json.dumps(response))
```

**Step 7: Update `poll_claude_ready` to accept tmux_name**

```python
async def poll_claude_ready(self, tmux_name: str, timeout: float = 15.0, interval: float = 0.3) -> bool:
    """Poll tmux pane until Claude Code is loaded and ready."""
    from voice_server.pane_parser import is_claude_ready

    elapsed = 0.0
    while elapsed < timeout:
        pane_text = self.tmux.capture_pane(tmux_name, include_history=False)
        if is_claude_ready(pane_text):
            print(f"[INFO] Claude ready after {elapsed:.1f}s")
            return True
        await asyncio.sleep(interval)
        elapsed += interval

    print(f"[WARN] Claude not ready after {timeout}s timeout")
    return False
```

**Step 8: Add `_setup_transcript_watcher` and `_switch_context_to_session` helpers**

```python
def _setup_transcript_watcher(self, ctx: SessionContext):
    """Initialize transcript handler and file watcher for a session context."""
    # Each context uses the shared transcript_handler but with per-session file tracking
    # For now, reuse the single TranscriptHandler — multi-handler comes in Task 5
    pass

def _switch_context_to_session(self, ctx: SessionContext, folder_name: str, session_id: str):
    """Switch the transcript watcher to a specific session's file."""
    new_path = self.get_session_transcript_path(folder_name, session_id)
    if new_path:
        ctx.transcript_path = new_path
        self.switch_watched_session(folder_name, session_id)
```

**Step 9: Update `reset_state` for multi-session cleanup**

```python
def reset_state(self):
    """Reset all server state for test isolation"""
    for ctx in list(self.active_sessions.values()):
        ctx.cleanup()
        self.tmux.kill_session(ctx.tmux_session_name)
    self.active_sessions.clear()
    self.viewed_session_id = None
    self._reset_session_state()  # Keep legacy reset for transcript handler etc.
    print("[RESET] Server state cleared for test isolation")
```

**Step 10: Update server shutdown to cleanup all sessions**

In the `start()` method's `finally` block (around line 1686):

```python
finally:
    if self._tts_worker_task:
        self._tts_worker_task.cancel()
    if self._pane_poll_task:
        self._pane_poll_task.cancel()
    # Kill all active tmux sessions on shutdown
    killed = self.tmux.cleanup_all()
    if killed:
        print(f"[SHUTDOWN] Killed {killed} active session(s)")
```

**Step 11: Run tests**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh`
Expected: Tests pass

**Step 12: Commit**

```bash
git add voice_server/session_context.py voice_server/ios_server.py
git commit -m "feat: multi-session lifecycle handlers with SessionContext"
```

---

### Task 4: Hook Scripts and HTTP Permission Routing

**Files:**
- Modify: `voice_server/hooks/permission_hook.sh`
- Modify: `voice_server/hooks/question_hook.sh`
- Modify: `voice_server/hooks/post_tool_hook.sh`
- Modify: `voice_server/http_server.py`
- Modify: `voice_server/tests/test_hooks.py`

**Step 1: Update hook scripts to forward session ID**

All three hooks read `$CLAUDE_CONNECT_SESSION_ID` and include it in the POST.

```bash
# voice_server/hooks/permission_hook.sh
#!/bin/bash
# Claude Code PermissionRequest hook
# Forwards permission requests to iOS voice server
#
# Reads JSON from stdin, POSTs to server, outputs response JSON
# Exit 0 on success with decision, exit 2 to fall back to terminal

SERVER_URL="${VOICE_SERVER_URL:-http://127.0.0.1:8766}"
SESSION_ID="${CLAUDE_CONNECT_SESSION_ID:-}"

# Save stdin to a temp file to avoid shell variable expansion mangling
# JSON with special characters ($, backticks, quotes, backslashes)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
cat > "$TMPFILE"

# POST to permission endpoint with 3 minute timeout
# Use 127.0.0.1 to avoid DNS resolution delays
# If server is down, curl fails fast and we fall back to terminal
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: ${SESSION_ID}" \
  --data-binary @"$TMPFILE" \
  --connect-timeout 3 \
  --max-time 185 \
  "${SERVER_URL}/permission" 2>/dev/null) || {
    # Server not running or network error - fall back to terminal
    exit 2
}

# Check if response has behavior=ask (timeout occurred)
if echo "$RESPONSE" | grep -q '"behavior".*:.*"ask"'; then
    # Server timed out waiting for iOS response
    exit 2
fi

# Output the decision JSON for Claude Code
echo "$RESPONSE"
exit 0
```

```bash
# voice_server/hooks/question_hook.sh
#!/bin/bash
# Claude Code PreToolUse hook for AskUserQuestion
# Intercepts questions and forwards to iOS voice server for remote answering
#
# Reads JSON from stdin, POSTs to server, outputs PreToolUse decision JSON
# Exit 0 on success with decision, exit 2 to fall back to terminal
#
# NOTE: The settings.json matcher is "AskUserQuestion" so this hook
# only fires for that tool. No need to check tool_name here.

SERVER_URL="${VOICE_SERVER_URL:-http://127.0.0.1:8766}"
SESSION_ID="${CLAUDE_CONNECT_SESSION_ID:-}"

# Save stdin to a temp file to avoid shell variable expansion mangling
# JSON with special characters ($, backticks, quotes, backslashes)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
cat > "$TMPFILE"

# POST to question endpoint with 3 minute timeout
# Use 127.0.0.1 to avoid DNS resolution delays
# If server is down, curl fails fast and we fall back to terminal
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: ${SESSION_ID}" \
  --data-binary @"$TMPFILE" \
  --connect-timeout 3 \
  --max-time 185 \
  "${SERVER_URL}/question" 2>/dev/null) || {
    # Server not running or network error - fall back to terminal
    exit 2
}

# Check if response has fallback=true (timeout occurred)
if echo "$RESPONSE" | grep -q '"fallback".*:.*true'; then
    exit 2
fi

# Output the decision JSON for Claude Code
echo "$RESPONSE"
exit 0
```

```bash
# voice_server/hooks/post_tool_hook.sh
#!/bin/bash
# Claude Code PostToolUse hook
# Notifies server when a tool completes (to dismiss permission prompt)

SERVER_URL="${VOICE_SERVER_URL:-http://127.0.0.1:8766}"
SESSION_ID="${CLAUDE_CONNECT_SESSION_ID:-}"

# Read JSON payload from stdin
PAYLOAD=$(cat)

# POST to permission_resolved endpoint (fire and forget)
# Use 127.0.0.1 to avoid DNS resolution delays
curl -s -X POST \
  -H "Content-Type: application/json" \
  -H "X-Session-Id: ${SESSION_ID}" \
  -d "$PAYLOAD" \
  --connect-timeout 2 \
  --max-time 5 \
  "${SERVER_URL}/permission_resolved" >/dev/null 2>&1 || true

exit 0
```

**Step 2: Update HTTP server to read session_id from header**

In `http_server.py`, extract `X-Session-Id` header in each handler and include it in the broadcast message:

```python
# In handle_permission, after parsing payload:
session_id = request.headers.get("X-Session-Id", "")

# Add to ios_message:
ios_message = {
    "type": "permission_request",
    "request_id": request_id,
    "session_id": session_id,  # NEW: route to correct session
    # ... rest unchanged
}
```

Same for `handle_question`:
```python
session_id = request.headers.get("X-Session-Id", "")
# Include in ios_message:
ios_message = {
    # ... existing fields
    "session_id": session_id,  # NEW
}
```

And `handle_permission_resolved`:
```python
session_id = request.headers.get("X-Session-Id", "")
# Include in broadcast:
await permission_handler.broadcast({
    "type": "permission_resolved",
    "request_id": request_id,
    "session_id": session_id,  # NEW
    "answered_in": "terminal"
})
```

**Step 3: Update PermissionHandler to remove latest_request_id**

The `latest_request_id` field was used as a fallback when no request_id was available. With session-based routing, we no longer need it. Remove the field and update `handle_permission_resolved` to not fall back on it.

In `permission_handler.py`:
- Remove `self.latest_request_id` from `__init__`
- Remove `self.latest_request_id = request_id` from `register_request`

In `http_server.py` `handle_permission_resolved`:
```python
# Replace:
#   request_id = payload.get("request_id", "") or permission_handler.latest_request_id or ""
# With:
request_id = payload.get("request_id", "")
```

**Step 4: Run tests**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh`
Expected: Tests pass (update any tests that check `latest_request_id`)

**Step 5: Verify hook env var flow**

```bash
# Start a test tmux session with env var
tmux new-session -d -s claude-connect_test-env -c /tmp "export CLAUDE_CONNECT_SESSION_ID=test-verify-123 && bash"
sleep 0.5
# Verify env var is set inside
tmux send-keys -t claude-connect_test-env 'echo $CLAUDE_CONNECT_SESSION_ID' Enter
sleep 0.5
tmux capture-pane -t claude-connect_test-env -p | grep test-verify-123
# Clean up
tmux kill-session -t claude-connect_test-env
```

Expected: Output contains `test-verify-123`

**CHECKPOINT:** If the env var doesn't appear in the tmux pane, the permission routing won't work. Debug the tmux env propagation before proceeding.

**Step 6: Commit**

```bash
git add voice_server/hooks/ voice_server/http_server.py voice_server/permission_handler.py voice_server/tests/
git commit -m "feat: route permission hooks via CLAUDE_CONNECT_SESSION_ID env var"
```

---

### Task 5: Multi-Session Pane Polling and Reconciliation

**Files:**
- Modify: `voice_server/ios_server.py`

**Step 1: Update pane polling to iterate all active sessions**

```python
async def _pane_poll_loop(self):
    """Poll tmux panes for all active sessions, broadcast on change."""
    from voice_server.pane_parser import parse_pane_status
    try:
        while True:
            for tmux_name, ctx in list(self.active_sessions.items()):
                if not self.tmux.session_exists(tmux_name):
                    continue
                pane_text = self.tmux.capture_pane(tmux_name, include_history=False)
                state = parse_pane_status(pane_text)

                if ctx.last_activity_state is None or \
                   state.state != ctx.last_activity_state.state or \
                   state.detail != ctx.last_activity_state.detail:
                    ctx.last_activity_state = state
                    # Only broadcast activity for the viewed session
                    if ctx.session_id == self.viewed_session_id:
                        await self.broadcast_message({
                            "type": "activity_status",
                            "state": state.state,
                            "detail": state.detail
                        })

            await asyncio.sleep(1.0)
    except asyncio.CancelledError:
        pass
```

**Step 2: Update reconciliation to be per-session**

The reconciliation loop currently uses `self.active_session_id` and `self.transcript_handler`. For multi-session, each session context needs its own reconciliation. For now, only reconcile the viewed session (since only one transcript handler exists). The full per-session transcript handler refactor is a future enhancement.

Update `_reconciliation_loop` to check `self.viewed_session_id`:

```python
async def _reconciliation_loop(self):
    """Periodically check for lines watchdog missed and send them to clients."""
    last_watchdog_time = time.time()
    tick = 0
    while True:
        try:
            await asyncio.sleep(3.0)
            tick += 1
            if not self.viewed_session_id or not self.transcript_handler:
                continue
            # ... rest unchanged, it uses self.transcript_handler which
            # already points to the viewed session's file
```

**Step 3: Update `_resolve_pending_session` to work with SessionContext**

```python
async def _resolve_pending_session(self, ctx: SessionContext):
    """Detect new session file using saved snapshot for a specific context."""
    if not ctx.pending_session_snapshot:
        return
    folder_name, existing_ids = ctx.pending_session_snapshot
    ctx.pending_session_snapshot = None
    session_id = await poll_for_session_file(
        find_fn=lambda: self.session_manager.find_new_session(folder_name, existing_ids),
        timeout=10.0,
        interval=0.3
    )
    if session_id:
        print(f"[DEBUG] Deferred detection found new session: {session_id}")
        ctx.session_id = session_id
        self.viewed_session_id = session_id

        # Update the tmux session name mapping
        old_tmux_name = ctx.tmux_session_name
        new_tmux_name = session_name_for(session_id)
        # Re-key in active_sessions dict
        if old_tmux_name in self.active_sessions:
            self.active_sessions.pop(old_tmux_name)
        ctx.tmux_session_name = old_tmux_name  # Keep original tmux name (can't rename running session)
        self.active_sessions[old_tmux_name] = ctx

        # Update env var in tmux for hook routing
        self.tmux.send_input(old_tmux_name, "")  # no-op, just to ensure session is alive
        # Note: CLAUDE_CONNECT_SESSION_ID was set at start. For new sessions,
        # it was set to temp_id. The hooks will use whatever was set at session start.
        # This is OK — the server routes by request_id, not session_id.

        self.switch_watched_session(folder_name, session_id, from_beginning=True)

        # Broadcast so iOS knows the session ID
        await self.broadcast_connection_status()
        await self.broadcast_message({
            "type": "session_created",
            "success": True,
            "session_id": session_id
        })
    else:
        print(f"[WARN] Deferred detection timed out for new session file")
```

**Step 4: Update `handle_voice_input` to use viewed context**

```python
async def handle_voice_input(self, websocket, data):
    """Handle voice input from iOS"""
    text = data.get('text', '').strip()
    print(f"[{time.strftime('%H:%M:%S')}] Voice input received: '{text}'")
    if text:
        ctx = self._get_viewed_context()
        if ctx:
            ctx.waiting_for_response = True
            ctx.last_voice_input = text

        print(f"[{time.strftime('%H:%M:%S')}] Sending to terminal...")
        for client in list(self.clients):
            try:
                await self.send_status(client, "processing", "Sending to Claude...")
            except Exception:
                pass

        await self.send_to_terminal(text)
        # ... rest of delivery verification unchanged
```

**Step 5: Run tests**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh`
Expected: Tests pass

**Step 6: Commit**

```bash
git add voice_server/ios_server.py
git commit -m "feat: multi-session pane polling and reconciliation"
```

---

### Task 6: Integration Verification

**Files:**
- Modify: `voice_server/tests/test_tmux_controller.py` (already updated in Task 1)

**Step 1: Verify two sessions can run simultaneously**

```bash
cd /Users/aaron/Desktop/max
python3 -c "
from voice_server.tmux_controller import TmuxController, session_name_for

tmux = TmuxController()
name1 = session_name_for('session-1')
name2 = session_name_for('session-2')

# Start two sessions
assert tmux.start_session(name1, working_dir='/tmp', env={'CLAUDE_CONNECT_SESSION_ID': 'session-1'})
assert tmux.start_session(name2, working_dir='/tmp', env={'CLAUDE_CONNECT_SESSION_ID': 'session-2'})

import time; time.sleep(0.5)

# Both exist
assert tmux.session_exists(name1)
assert tmux.session_exists(name2)

# Can capture panes independently
p1 = tmux.capture_pane(name1, include_history=False)
p2 = tmux.capture_pane(name2, include_history=False)
assert p1 is not None
assert p2 is not None

# Kill one, other survives
tmux.kill_session(name1)
time.sleep(0.3)
assert not tmux.session_exists(name1)
assert tmux.session_exists(name2)

# Cleanup
tmux.cleanup_all()
print('All multi-session integration checks passed!')
"
```

Expected: "All multi-session integration checks passed!"

**CHECKPOINT:** If this fails, the tmux layer is broken and nothing above it will work.

**Step 2: Verify server starts and shuts down cleanly**

```bash
cd /Users/aaron/Desktop/max
# Quick smoke test: start server, check it responds, stop it
timeout 5 python3 -c "
import asyncio
from voice_server.ios_server import VoiceServer
async def test():
    server = VoiceServer()
    # Just verify construction works with new fields
    assert hasattr(server, 'active_sessions')
    assert server.active_sessions == {}
    assert server.viewed_session_id is None
    print('Server construction OK')
asyncio.run(test())
" || true
```

Expected: "Server construction OK"

**Step 3: Run full test suite one final time**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh`
Expected: All tests pass

**Step 4: Commit any remaining fixes**

```bash
git add -A
git commit -m "test: verify multi-session server integration"
```

---

## Summary

After Phase 1, the server can:
- Create multiple tmux sessions with unique names (`claude-connect_<id>`)
- Track them in `active_sessions` dict with per-session state
- Route input to the viewed session
- Poll activity across all sessions
- Forward `CLAUDE_CONNECT_SESSION_ID` via hook scripts for permission routing
- Clean up all sessions on shutdown
- Enforce a max of 5 concurrent sessions

Phase 2 (separate plan) covers iOS app changes: green dots on sessions list, ellipsis menu with stop button, and the protocol/UI changes for multi-session switching.
