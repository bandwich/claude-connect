---
status: completed
created: 2026-04-02
completed: 2026-04-23
branch: feature/adopt-tmux-sessions
---

# Adopt External Tmux Sessions + Fix Stale Tool Display

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** When the iOS app opens a session that's already running in an external tmux (e.g., started by `/dispatch`), adopt that tmux instead of creating a duplicate. Also fix the display bug where actively-running tools show "(result not available)" instead of a spinner.

**Architecture:** Phase 1 adds `find_session_by_id()` to TmuxController that scans all tmux sessions' panes for a Claude session ID. `handle_resume_session` calls this before creating a new tmux — if found, it adopts the existing session. Phase 2 makes the iOS stale-marking logic session-aware: only mark trailing tool_use blocks as stale for inactive sessions.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS)

**Risky Assumptions:**
- The Claude session ID is visible in the tmux pane output. Needs verification — check what `claude --resume <id>` or a running Claude session shows. If the ID isn't visible, we'll need an alternative detection method (e.g., checking process args via `ps`).

---

## Phase 1: Adopt External Tmux Sessions (Server)

### Task 1: Add `list_all_sessions()` to TmuxController

**Files:**
- Modify: `server/infra/tmux_controller.py:155-171` (near `list_sessions`)
- Test: `server/tests/test_tmux_controller.py`

**Step 1: Write the failing test**

In `server/tests/test_tmux_controller.py`, add a new test class after `TestListAndCleanup`:

```python
TEST_EXTERNAL_SESSION = "dispatch-test-branch"

# Add to fixture cleanup lists in ensure_no_session and controller fixtures:
# for name in [TEST_SESSION, TEST_SESSION_2, TEST_EXTERNAL_SESSION]:
```

Update the `controller` and `ensure_no_session` fixtures to also clean up `TEST_EXTERNAL_SESSION`.

Then add tests:

```python
class TestListAllSessions:
    """Tests for list_all_sessions — returns ALL tmux sessions, not just claude-connect_*"""

    def test_list_all_includes_non_prefixed(self, controller, ensure_no_session):
        """list_all_sessions should include sessions without claude-connect prefix"""
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        subprocess.run(
            ["tmux", "new-session", "-d", "-s", TEST_EXTERNAL_SESSION, "-c", "/tmp", "bash"],
            capture_output=True
        )
        time.sleep(0.5)
        all_sessions = controller.list_all_sessions()
        assert TEST_SESSION in all_sessions
        assert TEST_EXTERNAL_SESSION in all_sessions

    def test_list_all_empty(self, controller, ensure_no_session):
        """list_all_sessions returns empty list when no sessions"""
        # Other tmux sessions may exist on this machine, so just check ours aren't there
        all_sessions = controller.list_all_sessions()
        assert TEST_SESSION not in all_sessions
        assert TEST_EXTERNAL_SESSION not in all_sessions
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_tmux_controller.py::TestListAllSessions -v`
Expected: FAIL — `AttributeError: 'TmuxController' object has no attribute 'list_all_sessions'`

**Step 3: Write minimal implementation**

In `server/infra/tmux_controller.py`, add after `list_sessions()`:

```python
def list_all_sessions(self) -> list[str]:
    """List all tmux sessions (not just claude-connect ones).

    Returns:
        List of all tmux session names
    """
    result = subprocess.run(
        ["tmux", "list-sessions", "-F", "#{session_name}"],
        capture_output=True,
        text=True
    )
    if result.returncode != 0:
        return []
    return [name.strip() for name in result.stdout.strip().split("\n") if name.strip()]
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_tmux_controller.py::TestListAllSessions -v`
Expected: PASS

**Step 5: Commit**

```bash
git commit -m "feat: add list_all_sessions to TmuxController"
```

---

### Task 2: Add `find_session_by_id()` to TmuxController

Scan all tmux panes for a Claude session ID. The session ID appears in the pane when Claude is running (shown in the TUI header or `--resume` command line).

**Files:**
- Modify: `server/infra/tmux_controller.py`
- Test: `server/tests/test_tmux_controller.py`

**Step 1: Verify session ID is visible in tmux pane**

Before writing any code, verify the assumption. Start a Claude session in tmux and capture the pane to confirm the session ID appears:

```bash
# Check what a running Claude Code session shows
tmux list-sessions -F "#{session_name}"
# Pick a running session (dispatch-* or claude-connect_*) and capture:
tmux capture-pane -t <session-name> -p | head -20
```

Look for the session UUID in the output. If it's NOT visible, try checking process args instead:

```bash
# Alternative: check process args
ps aux | grep "claude.*resume"
```

Document what you find — the detection approach depends on this.

**CHECKPOINT:** If the session ID is not visible in the pane AND not in process args, stop and report back. The approach needs rethinking.

**Step 2: Write the failing test**

Add to `server/tests/test_tmux_controller.py`:

```python
class TestFindSessionById:
    """Tests for find_session_by_id — finds tmux session running a Claude session"""

    def test_finds_session_with_id_in_pane(self, controller, ensure_no_session):
        """Should find a tmux session whose pane contains the session ID"""
        target_id = "abc123-def456-test"
        # Start a session that echoes the session ID (simulates Claude showing it)
        subprocess.run([
            "tmux", "new-session", "-d", "-s", TEST_EXTERNAL_SESSION, "-c", "/tmp",
            f"echo 'Session: {target_id}' && bash"
        ], capture_output=True)
        time.sleep(0.5)
        found = controller.find_session_by_id(target_id)
        assert found == TEST_EXTERNAL_SESSION

    def test_returns_none_when_not_found(self, controller, ensure_no_session):
        """Should return None when no tmux session contains the ID"""
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        time.sleep(0.5)
        found = controller.find_session_by_id("nonexistent-id-xyz")
        assert found is None

    def test_skips_claude_connect_sessions(self, controller, ensure_no_session):
        """Should skip claude-connect_* sessions (server already tracks those)"""
        target_id = "abc123-skip-test"
        subprocess.run([
            "tmux", "new-session", "-d", "-s", f"claude-connect_{target_id}", "-c", "/tmp",
            f"echo 'Session: {target_id}' && bash"
        ], capture_output=True)
        time.sleep(0.5)
        found = controller.find_session_by_id(target_id)
        assert found is None
        # Cleanup
        subprocess.run(["tmux", "kill-session", "-t", f"claude-connect_{target_id}"], capture_output=True)
```

**Step 3: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_tmux_controller.py::TestFindSessionById -v`
Expected: FAIL — `AttributeError`

**Step 4: Write minimal implementation**

In `server/infra/tmux_controller.py`:

```python
def find_session_by_id(self, session_id: str) -> Optional[str]:
    """Find a non-claude-connect tmux session running a Claude session with this ID.

    Scans pane content of all tmux sessions (excluding claude-connect_* ones,
    which are already tracked by the server) looking for the session ID.

    Args:
        session_id: Claude Code session ID to search for

    Returns:
        Tmux session name if found, None otherwise
    """
    for name in self.list_all_sessions():
        if name.startswith(f"{SESSION_PREFIX}_"):
            continue
        pane = self.capture_pane(name, include_history=False)
        if pane and session_id in pane:
            return name
    return None
```

Add `from typing import Optional` to imports if not already present.

**Step 5: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_tmux_controller.py::TestFindSessionById -v`
Expected: PASS

**Step 6: Commit**

```bash
git commit -m "feat: add find_session_by_id to scan tmux panes for Claude sessions"
```

---

### Task 3: Update `handle_resume_session` to adopt existing tmux

**Files:**
- Modify: `server/main.py:993-1072` (`handle_resume_session`)
- Test: `server/tests/test_message_handlers.py`

**Step 1: Write the failing test**

Add to `TestResumeSession` in `server/tests/test_message_handlers.py`:

```python
@pytest.mark.asyncio
async def test_resume_adopts_existing_external_tmux(self):
    """resume_session should adopt an existing external tmux instead of creating a new one"""
    from server.main import ConnectServer

    server = ConnectServer()
    server.tmux = Mock()
    # find_session_by_id returns an existing dispatch tmux
    server.tmux.find_session_by_id = Mock(return_value="dispatch-my-feature")
    server.tmux.session_exists = Mock(return_value=True)
    server.tmux.start_session = Mock(return_value=True)
    server.poll_claude_ready = AsyncMock(return_value=True)
    server.broadcast_connection_status = AsyncMock()

    mock_ws = AsyncMock()
    sent_messages = []
    mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

    await server.handle_resume_session(mock_ws, {
        "session_id": "abc123",
        "folder_name": "test-project"
    })

    # Should NOT have created a new tmux session
    server.tmux.start_session.assert_not_called()
    # Should have adopted the dispatch session
    assert server._active_tmux_session == "dispatch-my-feature"
    assert server.active_session_id == "abc123"
    # Should have sent success
    responses = [json.loads(m) for m in sent_messages]
    resume_response = next(r for r in responses if r.get("type") == "session_resumed")
    assert resume_response["success"] is True

@pytest.mark.asyncio
async def test_resume_falls_through_when_no_external_tmux(self):
    """resume_session should create new tmux when no external session found"""
    from server.main import ConnectServer

    server = ConnectServer()
    server.tmux = Mock()
    server.tmux.find_session_by_id = Mock(return_value=None)
    server.tmux.start_session = Mock(return_value=True)
    server.poll_claude_ready = AsyncMock(return_value=True)
    server.broadcast_connection_status = AsyncMock()

    mock_ws = AsyncMock()

    await server.handle_resume_session(mock_ws, {"session_id": "xyz789"})

    # Should have created a new tmux session as before
    server.tmux.start_session.assert_called_once()
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_message_handlers.py::TestResumeSession::test_resume_adopts_existing_external_tmux -v`
Expected: FAIL — `find_session_by_id` not called in current code

**Step 3: Write minimal implementation**

In `server/main.py`, modify `handle_resume_session`. After the existing `_get_context_by_session_id` check (line ~1013) and before `_reset_session_state()` (line ~1026), add the external tmux adoption path:

```python
        # Check if this session is running in an external tmux (e.g., dispatch skill)
        external_tmux = self.tmux.find_session_by_id(session_id)
        if external_tmux:
            print(f"[INFO] Found session {session_id} in external tmux: {external_tmux}")
            self._reset_session_state()

            self._active_tmux_session = external_tmux
            self.active_session_id = session_id

            ctx = SessionContext(
                session_id=session_id,
                folder_name=folder_name,
                tmux_session_name=external_tmux,
            )
            self.active_sessions[external_tmux] = ctx
            self.viewed_session_id = session_id

            if folder_name:
                self.active_folder_name = folder_name
                self.switch_watched_session(folder_name, session_id)

            await websocket.send(json.dumps({
                "type": "session_resumed",
                "success": True,
                "session_id": session_id
            }))
            await self.broadcast_connection_status()
            return
```

Insert this block after the `existing_ctx` check (line ~1013) and before the session limit check (line ~1016).

**Step 4: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_message_handlers.py::TestResumeSession -v`
Expected: ALL PASS

**Step 5: Verify it actually works**

Start a tmux session simulating a dispatch-started Claude:
```bash
tmux new-session -d -s "dispatch-test-verify" -c /tmp "echo 'session-id: some-test-id' && bash"
```
Then check from Python:
```python
from server.infra.tmux_controller import TmuxController
ctrl = TmuxController()
result = ctrl.find_session_by_id("some-test-id")
print(f"Found: {result}")  # Should print: Found: dispatch-test-verify
```
Clean up: `tmux kill-session -t dispatch-test-verify`

**CHECKPOINT:** If find_session_by_id doesn't find the session, debug the pane content before proceeding.

**Step 6: Commit**

```bash
git commit -m "feat: adopt external tmux sessions in resume_session"
```

---

### Task 4: Route empty-session-ID hooks to the viewed session

Adopted tmux sessions won't have `CLAUDE_CONNECT_SESSION_ID` set (the dispatch skill doesn't set it). So hooks send an empty `X-Session-Id` header. Currently `is_viewed_session("")` returns `False`, which makes the hook bail — permissions fall back to the terminal instead of going to iOS.

Fix: treat empty session ID as matching the viewed session. If a hook doesn't know which session it belongs to, routing to iOS is better than silently falling back to terminal. This also helps any Claude Code session started outside the server (e.g., user types `claude` in a terminal with hooks configured).

**Files:**
- Modify: `server/infra/http_server.py:58-59`
- Test: `server/tests/test_http_server.py`

**Step 1: Update the existing test**

In `server/tests/test_http_server.py`, there's an existing `test_empty_session_id_rejected` (line ~152) that asserts `is_viewed_session("") == False`. Update it:

```python
def test_empty_session_id_routes_to_viewed(self):
    """Empty session ID (external/adopted session) routes to viewed session."""
    from server.infra.http_server import is_viewed_session
    set_server(self._make_mock_server("viewed-session-123"))
    try:
        assert is_viewed_session("") == True
    finally:
        set_server(None)
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_http_server.py -k "test_empty_session_id" -v`
Expected: FAIL — `AssertionError: assert False == True`

**Step 3: Write minimal implementation**

In `server/infra/http_server.py`, change line 58-59 from:

```python
    if not raw_session_id:
        return False
```

to:

```python
    if not raw_session_id:
        return True
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_http_server.py -v`
Expected: ALL PASS

**Step 5: Run all server tests**

Run: `cd /Users/aaron/Desktop/max/server/tests && ./run_tests.sh`
Expected: ALL PASS

**Step 6: Commit**

```bash
git commit -m "fix: route empty-session-ID hook requests to viewed session"
```

---

## Phase 2: Fix Stale Tool Display (iOS)

### Task 5: Don't mark trailing tool_use as stale for active sessions

The session history load callback marks ALL result-less tool_use blocks as stale. Change it to only mark them stale when the session is NOT active.

**Files:**
- Modify: `ios/ClaudeConnect/ClaudeConnect/Views/SessionView.swift:589-602`
- Test: `ios/ClaudeConnect/ClaudeConnectTests/ClaudeVoiceTests.swift`

**Step 1: Write the failing test**

In `ios/ClaudeConnect/ClaudeConnectTests/ClaudeVoiceTests.swift`, add a new test suite (at the end of the file, after the existing `AgentGroup` tests):

```swift
@Suite("Stale Tool Marking Tests")
struct StaleToolMarkingTests {

    @Test func trailingToolUseNotMarkedStaleWhenSessionActive() {
        // Simulate history items with a trailing tool_use (no result)
        let tool = ToolUseBlock(type: "tool_use", id: "toolu_active", name: "Bash", input: ["command": "ls"])
        var items: [ConversationItem] = [
            .textMessage(SessionHistoryMessage(role: "assistant", content: "Let me check.", timestamp: 1)),
            .toolUse(toolId: "toolu_active", tool: tool, result: nil)
        ]

        // When session IS active, trailing tool_use should keep nil result
        markStaleToolUses(&items, isSessionActive: true)

        if case .toolUse(_, _, let result) = items[1] {
            #expect(result == nil, "Active session should NOT mark trailing tool_use as stale")
        }
    }

    @Test func trailingToolUseMarkedStaleWhenSessionInactive() {
        let tool = ToolUseBlock(type: "tool_use", id: "toolu_old", name: "Bash", input: ["command": "ls"])
        var items: [ConversationItem] = [
            .textMessage(SessionHistoryMessage(role: "assistant", content: "checking", timestamp: 1)),
            .toolUse(toolId: "toolu_old", tool: tool, result: nil)
        ]

        // When session is NOT active, trailing tool_use should be marked stale
        markStaleToolUses(&items, isSessionActive: false)

        if case .toolUse(_, _, let result) = items[1] {
            #expect(result != nil, "Inactive session SHOULD mark trailing tool_use as stale")
            #expect(result?.content == "(result not available)")
        }
    }

    @Test func middleToolUseAlwaysMarkedStale() {
        // A tool_use followed by another tool_use — the first should always be stale
        let tool1 = ToolUseBlock(type: "tool_use", id: "toolu_1", name: "Read", input: [:])
        let tool2 = ToolUseBlock(type: "tool_use", id: "toolu_2", name: "Bash", input: [:])
        let result2 = ToolResultBlock(type: "tool_result", toolUseId: "toolu_2", content: "ok", isError: false)
        var items: [ConversationItem] = [
            .toolUse(toolId: "toolu_1", tool: tool1, result: nil),
            .toolUse(toolId: "toolu_2", tool: tool2, result: result2)
        ]

        // Even for active session, middle tool_use without result should be stale
        markStaleToolUses(&items, isSessionActive: true)

        if case .toolUse(_, _, let result) = items[0] {
            #expect(result != nil, "Middle tool_use without result should be marked stale")
            #expect(result?.content == "(result not available)")
        }
    }
}
```

**Step 2: Run test to verify it fails**

Run:
```bash
cd /Users/aaron/Desktop/max/ios/ClaudeConnect
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO
```
Expected: FAIL — `markStaleToolUses` doesn't exist

**Step 3: Extract `markStaleToolUses` helper and make it session-aware**

In `ios/ClaudeConnect/ClaudeConnect/Models/Session.swift` (where `groupAgentItems` lives), add:

```swift
/// Mark tool_use blocks without results as stale.
/// - For active sessions: only mark non-trailing tool_uses (middle ones that were likely missed).
/// - For inactive sessions: mark ALL tool_uses without results (nothing more will arrive).
func markStaleToolUses(_ items: inout [ConversationItem], isSessionActive: Bool) {
    for i in 0..<items.count {
        if case .toolUse(let tid, let tool, nil) = items[i] {
            // If session is active, skip the LAST result-less tool_use (it may still be running)
            if isSessionActive {
                let isLastResultless = !items[(i+1)...].contains(where: {
                    if case .toolUse(_, _, nil) = $0 { return true }
                    if case .toolUse(_, _, _) = $0 { return false }
                    return false
                })
                if isLastResultless { continue }
            }
            let staleResult = ToolResultBlock(
                type: "tool_result",
                toolUseId: tid,
                content: "(result not available)",
                isError: false
            )
            items[i] = .toolUse(toolId: tid, tool: tool, result: staleResult)
        }
    }
}
```

**Step 4: Update SessionView to use the helper**

In `SessionView.swift`, replace the stale-marking loop at line ~589-602 with:

```swift
// Mark stale tool_use blocks — skip trailing ones for active sessions
let isActive = webSocketManager.activeSessionIds.contains(session.id)
markStaleToolUses(&newItems, isSessionActive: isActive)
```

**Step 5: Run test to verify it passes**

Run:
```bash
cd /Users/aaron/Desktop/max/ios/ClaudeConnect
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO
```
Expected: ALL PASS

**Step 6: Commit**

```bash
git commit -m "fix: don't mark trailing tool_use as stale for active sessions"
```

---

Note: The live streaming stale-marking (lines ~713-724, ~837-848) has DIFFERENT semantics — it marks ALL previous result-less tool_uses when a new tool arrives, and excludes `Agent` tools. This is correct behavior for live streaming and should NOT be changed. Only the history-load path (Task 5) needs the session-aware fix.
