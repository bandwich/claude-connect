# Activity Indicator Reliability Fix

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Make the iOS activity indicator ("Thinking...", "Searching for 1 pattern...") stay visible whenever Claude is working, instead of disappearing after the first response.

**Architecture:** Three server-side changes: (1) debounce idle transitions so brief pane-capture misses don't kill the indicator, (2) remove premature idle sends from the transcript pipeline, (3) suppress idle broadcasts from the event-driven activity check after content delivery. No iOS changes needed.

**Tech Stack:** Python (server), pytest (tests)

**Risky Assumptions:** The pane parser regex still matches Claude Code v2.1.85's spinner/tool format (fixtures are from v2.1.45). After implementing, verify by running the server with a real multi-step task.

---

### Task 1: Add idle debounce to activity state broadcasting

The core fix. Currently `_check_activity_state()` broadcasts idle immediately when the pane parser returns idle, even during brief transitions between thinking and tool use. Add a 3-second debounce: don't broadcast idle until idle has been detected continuously for 3 seconds.

**Files:**
- Modify: `voice_server/models/session_context.py:15-30`
- Modify: `voice_server/server.py:574-608` (`_check_activity_state`)
- Modify: `voice_server/server.py:78` (add `_idle_since` instance var for fallback path)
- Test: `voice_server/tests/test_activity_debounce.py` (new)

**Step 1: Write the failing tests**

Create `voice_server/tests/test_activity_debounce.py`:

```python
"""Tests for activity state idle debounce behavior."""

import time
from unittest.mock import AsyncMock, Mock, patch
import pytest

from voice_server.server import VoiceServer
from voice_server.infra.pane_parser import ActivityState
from voice_server.models.session_context import SessionContext


def make_ctx(session_id="test-session", tmux_name="claude-connect_test"):
    """Create a SessionContext for testing."""
    return SessionContext(
        session_id=session_id,
        folder_name="test-folder",
        tmux_session_name=tmux_name,
    )


@pytest.fixture
def server():
    s = VoiceServer()
    s.broadcast_message = AsyncMock()
    s.viewed_session_id = "test-session"
    return s


class TestIdleDebounce:
    """Test that idle state is debounced — not broadcast until 3s of continuous idle."""

    @pytest.mark.asyncio
    async def test_idle_not_broadcast_immediately_after_thinking(self, server):
        """When pane goes thinking -> idle, idle should NOT broadcast right away."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="thinking", detail="")
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="some idle pane"), \
             patch('voice_server.server.parse_pane_status',
                   return_value=ActivityState(state="idle", detail="")):
            await server._check_activity_state()

        # Should NOT have broadcast idle
        server.broadcast_message.assert_not_called()
        # But idle_since should be set
        assert ctx.idle_since is not None

    @pytest.mark.asyncio
    async def test_thinking_after_idle_resets_debounce(self, server):
        """When pane goes idle -> thinking, debounce resets and thinking broadcasts."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="thinking", detail="")
        ctx.idle_since = time.time() - 1.0  # Was idle for 1s
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="spinner pane"), \
             patch('voice_server.server.parse_pane_status',
                   return_value=ActivityState(state="thinking", detail="")):
            await server._check_activity_state()

        # Should broadcast thinking
        server.broadcast_message.assert_called_once()
        msg = server.broadcast_message.call_args[0][0]
        assert msg["state"] == "thinking"
        # idle_since should be reset
        assert ctx.idle_since is None

    @pytest.mark.asyncio
    async def test_idle_broadcasts_after_debounce_period(self, server):
        """After 3s of continuous idle, idle should finally broadcast."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="thinking", detail="")
        ctx.idle_since = time.time() - 4.0  # Idle for 4s (past debounce)
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="idle pane"), \
             patch('voice_server.server.parse_pane_status',
                   return_value=ActivityState(state="idle", detail="")):
            await server._check_activity_state()

        # Should broadcast idle now
        server.broadcast_message.assert_called_once()
        msg = server.broadcast_message.call_args[0][0]
        assert msg["state"] == "idle"

    @pytest.mark.asyncio
    async def test_tool_active_broadcasts_immediately(self, server):
        """Non-idle states always broadcast immediately without debounce."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="idle", detail="")
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="tool pane"), \
             patch('voice_server.server.parse_pane_status',
                   return_value=ActivityState(state="tool_active", detail="Reading 3 files...")):
            await server._check_activity_state()

        server.broadcast_message.assert_called_once()
        msg = server.broadcast_message.call_args[0][0]
        assert msg["state"] == "tool_active"
        assert msg["detail"] == "Reading 3 files..."
        assert ctx.idle_since is None

    @pytest.mark.asyncio
    async def test_idle_to_idle_no_double_broadcast(self, server):
        """If already idle (debounced and broadcast), don't broadcast again."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="idle", detail="")
        ctx.idle_since = None  # Already settled into idle
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="idle pane"), \
             patch('voice_server.server.parse_pane_status',
                   return_value=ActivityState(state="idle", detail="")):
            await server._check_activity_state()

        # Already idle, no change — should not broadcast
        server.broadcast_message.assert_not_called()


class TestSuppressIdle:
    """Test suppress_idle parameter for event-driven activity checks."""

    @pytest.mark.asyncio
    async def test_suppress_idle_skips_idle_broadcast(self, server):
        """With suppress_idle=True, idle pane state should not broadcast."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="thinking", detail="")
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="idle pane"), \
             patch('voice_server.server.parse_pane_status',
                   return_value=ActivityState(state="idle", detail="")):
            await server._check_activity_state(suppress_idle=True)

        server.broadcast_message.assert_not_called()
        # last_activity_state should NOT be updated to idle (preserve previous state)
        assert ctx.last_activity_state.state == "thinking"

    @pytest.mark.asyncio
    async def test_suppress_idle_still_broadcasts_non_idle(self, server):
        """With suppress_idle=True, non-idle states still broadcast normally."""
        ctx = make_ctx()
        ctx.last_activity_state = ActivityState(state="idle", detail="")
        server.active_sessions = {"claude-connect_test": ctx}

        with patch.object(server.tmux, 'session_exists', return_value=True), \
             patch.object(server.tmux, 'capture_pane', return_value="tool pane"), \
             patch('voice_server.server.parse_pane_status',
                   return_value=ActivityState(state="tool_active", detail="Searching...")):
            await server._check_activity_state(suppress_idle=True)

        server.broadcast_message.assert_called_once()
        msg = server.broadcast_message.call_args[0][0]
        assert msg["state"] == "tool_active"
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && python -m pytest test_activity_debounce.py -v`
Expected: FAIL — `idle_since` attribute doesn't exist, `suppress_idle` parameter doesn't exist.

**Step 3: Add `idle_since` to SessionContext**

In `voice_server/models/session_context.py`, add after `last_activity_state` (line 24):

```python
    idle_since: Optional[float] = None  # Timestamp when idle first detected (for debounce)
```

**Step 4: Add `_idle_since` instance var and rewrite `_check_activity_state`**

In `voice_server/server.py`, add after line 78 (`self._last_activity_state = None`):

```python
        self._idle_since = None  # For fallback single-session idle debounce
```

Replace `_check_activity_state` (lines 574-608) with:

```python
    async def _check_activity_state(self, suppress_idle: bool = False):
        """Check pane state for all active sessions and broadcast changes.

        Args:
            suppress_idle: If True, don't broadcast idle states (used for
                event-driven checks right after content delivery, when the
                pane is likely in a transitional state).
        """
        from voice_server.infra.pane_parser import parse_pane_status

        IDLE_DEBOUNCE_SECS = 3.0

        for tmux_name, ctx in list(self.active_sessions.items()):
            if not self.tmux.session_exists(tmux_name):
                continue
            pane_text = self.tmux.capture_pane(tmux_name, include_history=False)
            state = parse_pane_status(pane_text)

            if state.state == "idle":
                if suppress_idle:
                    continue

                # Start or continue idle debounce
                if ctx.last_activity_state and ctx.last_activity_state.state != "idle":
                    # Transition from non-idle to idle — start debounce
                    if ctx.idle_since is None:
                        ctx.idle_since = time.time()
                    # Check if debounce period has elapsed
                    if time.time() - ctx.idle_since < IDLE_DEBOUNCE_SECS:
                        continue  # Still debouncing, don't broadcast
                    # Debounce complete — broadcast idle and settle
                    ctx.last_activity_state = state
                    ctx.idle_since = None
                    if ctx.session_id == self.viewed_session_id:
                        await self.broadcast_message({
                            "type": "activity_status",
                            "state": state.state,
                            "detail": state.detail
                        })
                # else: already idle, no change to broadcast
            else:
                # Non-idle: reset debounce, broadcast if state changed
                ctx.idle_since = None
                if ctx.last_activity_state is None or \
                   state.state != ctx.last_activity_state.state or \
                   state.detail != ctx.last_activity_state.detail:
                    ctx.last_activity_state = state
                    if ctx.session_id == self.viewed_session_id:
                        await self.broadcast_message({
                            "type": "activity_status",
                            "state": state.state,
                            "detail": state.detail
                        })

        # Fallback: single active session without multi-session context
        if not self.active_sessions and self._active_tmux_session and self.tmux.session_exists(self._active_tmux_session):
            pane_text = self.tmux.capture_pane(self._active_tmux_session, include_history=False)
            state = parse_pane_status(pane_text)

            if state.state == "idle":
                if suppress_idle:
                    return

                if self._last_activity_state and self._last_activity_state.state != "idle":
                    if self._idle_since is None:
                        self._idle_since = time.time()
                    if time.time() - self._idle_since < IDLE_DEBOUNCE_SECS:
                        return
                    self._last_activity_state = state
                    self._idle_since = None
                    await self.broadcast_message({
                        "type": "activity_status",
                        "state": state.state,
                        "detail": state.detail
                    })
            else:
                self._idle_since = None
                if self._last_activity_state is None or \
                   state.state != self._last_activity_state.state or \
                   state.detail != self._last_activity_state.detail:
                    self._last_activity_state = state
                    await self.broadcast_message({
                        "type": "activity_status",
                        "state": state.state,
                        "detail": state.detail
                    })
```

**Step 5: Run tests to verify they pass**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && python -m pytest test_activity_debounce.py -v`
Expected: All 7 tests PASS.

**Step 6: Commit**

```bash
git add voice_server/models/session_context.py voice_server/server.py voice_server/tests/test_activity_debounce.py
git commit -m "fix: debounce idle activity state to prevent indicator disappearing mid-task"
```

---

### Task 2: Remove premature idle sends from transcript pipeline

The transcript pipeline calls `send_idle_to_all_clients()` whenever content has no TTS-able text (e.g., only thinking blocks). This sends a `status: idle` message that resets the iOS `outputState`, fighting the activity system. The pane poll is the single source of truth for activity state.

**Files:**
- Modify: `voice_server/services/transcript_watcher.py:142-146`
- Modify: `voice_server/server.py:253-254`
- Modify: `voice_server/tests/test_ios_server.py:109-148`

**Step 1: Remove the else branch in transcript_watcher.py**

In `voice_server/services/transcript_watcher.py`, replace lines 135-146:

```python
                if not self.server or self.server.active_session_id:
                    text = extract_text_for_tts(new_blocks)
                    if text:
                        asyncio.run_coroutine_threadsafe(
                            self.audio_callback(text),
                            self.loop
                        )
                    else:
                        asyncio.run_coroutine_threadsafe(
                            self.server.send_idle_to_all_clients(),
                            self.loop
                        )
```

with:

```python
                if not self.server or self.server.active_session_id:
                    text = extract_text_for_tts(new_blocks)
                    if text:
                        asyncio.run_coroutine_threadsafe(
                            self.audio_callback(text),
                            self.loop
                        )
```

**Step 2: Remove the idle send in reconciliation**

In `voice_server/server.py`, delete lines 253-254:

```python
                    if not self.tts_enabled:
                        await self.send_idle_to_all_clients()
```

**Step 3: Update the existing test**

In `voice_server/tests/test_ios_server.py`, replace the test `test_on_modified_sends_idle_when_no_tts_text` (lines 109-148) with:

```python
    def test_on_modified_no_idle_sent_for_thinking_only_content(self):
        """When content has only thinking blocks (no TTS text), no idle is sent.
        The pane poll is the source of truth for activity state."""
        import asyncio as asyncio_module

        content_callback = AsyncMock()
        audio_callback = AsyncMock()
        loop = Mock()
        server = Mock()
        server.clients = {Mock()}
        server.send_idle_to_all_clients = AsyncMock()
        server.broadcast_message = AsyncMock()
        server.active_session_id = "test-session"
        handler = TranscriptHandler(content_callback, audio_callback, loop, server)

        # Create file with only thinking block (no text for TTS)
        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            f.write(json.dumps({
                "role": "assistant",
                "content": [{"type": "thinking", "thinking": "Let me think about this...", "signature": "test"}]
            }) + "\n")
            filepath = f.name

        try:
            handler.expected_session_file = filepath
            event = Mock()
            event.is_directory = False
            event.src_path = filepath

            with patch.object(asyncio_module, 'run_coroutine_threadsafe') as mock_run:
                handler.on_modified(event)

                # Verify send_idle_to_all_clients was never passed to run_coroutine_threadsafe.
                # Content callback and context broadcast are scheduled, but NOT idle.
                for call in mock_run.call_args_list:
                    coro = call[0][0]
                    coro.close()  # Clean up coroutine
                # 2 calls expected: content_callback + context broadcast (no idle)
                assert mock_run.call_count == 2, \
                    f"Expected 2 calls (content + context), got {mock_run.call_count}"
        finally:
            os.unlink(filepath)
```

**Step 4: Run all server tests**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh`
Expected: All tests pass, including the updated test.

**Step 5: Commit**

```bash
git add voice_server/services/transcript_watcher.py voice_server/server.py voice_server/tests/test_ios_server.py
git commit -m "fix: remove premature idle sends from transcript pipeline"
```

---

### Task 3: Suppress idle from event-driven activity check

`handle_content_response` (line 439) calls `_check_activity_state()` right after sending content. At that moment the pane shows the just-written output, not a spinner, so the parser returns idle. With the debounce from Task 1, this won't broadcast idle immediately, but it still starts the debounce timer unnecessarily. Pass `suppress_idle=True` so event-driven checks only accelerate non-idle detection.

**Files:**
- Modify: `voice_server/server.py:439`

**Step 1: Change the call to pass suppress_idle=True**

In `voice_server/server.py`, replace line 439:

```python
        await self._check_activity_state()
```

with:

```python
        await self._check_activity_state(suppress_idle=True)
```

**Step 2: Run all tests**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh`
Expected: All tests pass (the suppress_idle tests from Task 1 already cover this).

**Step 3: Commit**

```bash
git add voice_server/server.py
git commit -m "fix: suppress idle broadcast from event-driven activity check"
```

---

### Task 4: Verify with live server

The pane parser regex was written for Claude Code v2.1.45; current version is v2.1.85. Verify the parser still detects thinking and tool_active states correctly.

**Step 1: Start the server and connect iOS app**

```bash
pipx install --force /Users/aaron/Desktop/max
claude-connect
```

**Step 2: Send a multi-step task**

From the iOS app, send a task that requires multiple tools, e.g.:
> "Read the file voice_server/server.py and count how many async functions it has, then read pane_parser.py and count how many regex patterns it defines"

**Step 3: Observe the activity indicator**

Watch for:
- "Thinking..." appears when Claude starts processing
- Tool descriptions appear (e.g., "Reading 1 file...")
- Indicator stays visible between tool calls (no disappearing)
- Indicator disappears ~3s after Claude finishes and goes idle

**Step 4: If the indicator doesn't appear during tool use**

The pane format may have changed. Capture the pane output while Claude is working:

```bash
tmux capture-pane -t claude-connect_<session_id> -p
```

Compare the output against the regex patterns in `pane_parser.py` and update them if needed.

**CHECKPOINT:** The activity indicator must stay visible throughout a multi-step task. If it doesn't, debug the pane parser before merging.
