# Session Lifecycle Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Make new session creation reliable by resetting stale state and verifying Claude is actually running before reporting success.

**Architecture:** Extract a `_reset_session_state()` method from `reset_state()` (test-only) and call it at the top of `handle_new_session` and `handle_resume_session`. Add a `poll_claude_ready()` helper that polls the tmux pane for Claude's `❯` prompt before reporting success. On failure, kill tmux and send `success: false` with an error message.

**Tech Stack:** Python (server), Swift (iOS error display)

**Risky Assumptions:** Claude's ready state is reliably detectable via the `❯` prompt character in the tmux pane. Will be verified in Task 1 before any other changes.

---

### Task 1: Add `is_claude_ready()` to pane_parser

**Files:**
- Modify: `voice_server/pane_parser.py`
- Modify: `voice_server/tests/test_pane_parser.py`
- Create fixture: `voice_server/tests/fixtures/pane_captures/startup_loading.txt`

**Step 1: Create a startup/loading fixture**

Capture what the tmux pane looks like while Claude is still loading (before the `❯` prompt appears). Create `voice_server/tests/fixtures/pane_captures/startup_loading.txt`:

```
$ claude
```

This represents the moment after tmux starts `claude` but before Claude has finished initializing.

**Step 2: Write the failing tests**

Add to `voice_server/tests/test_pane_parser.py`:

```python
from voice_server.pane_parser import is_claude_ready


class TestIsClaudeReady:
    def test_ready_when_idle_prompt_visible(self):
        pane_text = load_fixture("idle.txt")
        assert is_claude_ready(pane_text) is True

    def test_not_ready_when_loading(self):
        pane_text = load_fixture("startup_loading.txt")
        assert is_claude_ready(pane_text) is False

    def test_not_ready_for_empty_pane(self):
        assert is_claude_ready("") is False

    def test_not_ready_for_none(self):
        assert is_claude_ready(None) is False

    def test_ready_when_thinking(self):
        """Claude is ready (running) even when actively thinking."""
        pane_text = load_fixture("thinking.txt")
        assert is_claude_ready(pane_text) is True

    def test_ready_when_permission_prompt(self):
        """Claude is ready when showing a permission prompt."""
        pane_text = load_fixture("permission_prompt.txt")
        assert is_claude_ready(pane_text) is True
```

**Step 3: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_pane_parser.py::TestIsClaudeReady -v`
Expected: FAIL with `ImportError` (function doesn't exist yet)

**Step 4: Implement `is_claude_ready()`**

Add to `voice_server/pane_parser.py`:

```python
# Claude Code's input prompt character — indicates CLI is loaded and ready
READY_PROMPT_RE = re.compile(r'❯')

# Claude Code banner pattern — indicates CLI has started
BANNER_RE = re.compile(r'Claude Code')


def is_claude_ready(pane_text: Optional[str]) -> bool:
    """Check if Claude Code is loaded and ready for input.

    Looks for the ❯ prompt or the Claude Code banner, which indicate
    the CLI has finished initializing. Also returns True if Claude is
    already actively working (thinking, tool use, permission prompt).
    """
    if not pane_text:
        return False

    # If we can detect any Claude activity, it's ready
    state = parse_pane_status(pane_text)
    if state.state != "idle":
        return True

    # Check for ready prompt or banner
    return bool(READY_PROMPT_RE.search(pane_text)) or bool(BANNER_RE.search(pane_text))
```

**Step 5: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_pane_parser.py::TestIsClaudeReady -v`
Expected: PASS

**Step 6: Verify against real tmux**

Start a real Claude session in tmux manually, then test:

```bash
tmux new-session -d -s test_ready "claude"
sleep 5
tmux capture-pane -t test_ready -p | python3 -c "
import sys; sys.path.insert(0, '.')
from voice_server.pane_parser import is_claude_ready
print('Ready:', is_claude_ready(sys.stdin.read()))
"
tmux kill-session -t test_ready
```

Expected: `Ready: True`

**CHECKPOINT:** If `is_claude_ready` can't reliably detect the ready state from a real tmux pane, stop and investigate before proceeding.

**Step 7: Commit**

```bash
git add voice_server/pane_parser.py voice_server/tests/test_pane_parser.py voice_server/tests/fixtures/pane_captures/startup_loading.txt
git commit -m "feat: add is_claude_ready() to pane_parser for startup detection"
```

---

### Task 2: Extract `_reset_session_state()` method

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_ios_server.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_message_handlers.py` (new test class):

```python
class TestResetSessionState:
    """Tests for _reset_session_state"""

    def test_reset_session_state_clears_all_state(self):
        """_reset_session_state should clear all session-related state."""
        from ios_server import VoiceServer

        server = VoiceServer()
        # Set up dirty state
        server.active_session_id = "old-session"
        server.active_folder_name = "old-folder"
        server.transcript_path = "/some/path.jsonl"
        server._pending_session_snapshot = ("folder", {"id1"})
        server.current_branch = "main"

        server._reset_session_state()

        assert server.active_session_id is None
        assert server.active_folder_name is None
        assert server.transcript_path is None
        assert server._pending_session_snapshot is None
        assert server.current_branch == ""

    def test_reset_session_state_clears_permissions(self):
        """_reset_session_state should clear pending permissions."""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.permission_handler.latest_request_id = "stale-req"
        server.permission_handler.pending_messages["req1"] = {"type": "permission_request"}

        server._reset_session_state()

        assert server.permission_handler.latest_request_id is None
        assert len(server.permission_handler.pending_messages) == 0
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py::TestResetSessionState -v`
Expected: FAIL with `AttributeError` (method doesn't exist)

**Step 3: Extract `_reset_session_state()` from `reset_state()`**

In `voice_server/ios_server.py`, add the new method and refactor `reset_state()` to use it:

```python
def _reset_session_state(self):
    """Reset all session-related state.

    Called at the start of handle_new_session and handle_resume_session
    to ensure clean state before starting a new session lifecycle.
    """
    # Stop reconciliation loop
    if self._reconciliation_task and not self._reconciliation_task.done():
        self._reconciliation_task.cancel()
        self._reconciliation_task = None

    # Reset session tracking
    self.active_session_id = None
    self.active_folder_name = None
    self._pending_session_snapshot = None
    self.current_branch = ""
    self.transcript_path = None

    # Reset transcript handler
    if self.transcript_handler:
        self.transcript_handler.reset_tracking_state()
        self.transcript_handler.expected_session_file = None

    # Unschedule file watcher
    if self.observer:
        self.observer.unschedule_all()

    # Clear pending permissions/questions
    self.permission_handler.pending_permissions.clear()
    self.permission_handler.permission_responses.clear()
    self.permission_handler.pending_messages.clear()
    self.permission_handler.timed_out_requests.clear()
    self.permission_handler.latest_request_id = None

def reset_state(self):
    """Reset all server state for test isolation."""
    self.tmux.kill_session()
    self._reset_session_state()
    print("[RESET] Server state cleared for test isolation")
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py::TestResetSessionState -v`
Expected: PASS

**Step 5: Run all server tests to verify no regressions**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests pass

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "refactor: extract _reset_session_state() for session lifecycle reset"
```

---

### Task 3: Add `poll_claude_ready()` async helper

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_ios_server.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_message_handlers.py`:

```python
class TestPollClaudeReady:
    """Tests for poll_claude_ready"""

    @pytest.mark.asyncio
    async def test_poll_claude_ready_success(self):
        """poll_claude_ready returns True when Claude becomes ready."""
        from ios_server import VoiceServer

        server = VoiceServer()
        call_count = 0
        def mock_capture(include_history=True):
            nonlocal call_count
            call_count += 1
            if call_count >= 3:
                return "❯ Try something\n"
            return "$ claude\n"

        server.tmux = Mock()
        server.tmux.capture_pane = mock_capture
        result = await server.poll_claude_ready(timeout=5.0, interval=0.1)
        assert result is True

    @pytest.mark.asyncio
    async def test_poll_claude_ready_timeout(self):
        """poll_claude_ready returns False on timeout."""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.capture_pane = Mock(return_value="$ claude\n")
        result = await server.poll_claude_ready(timeout=0.5, interval=0.1)
        assert result is False
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py::TestPollClaudeReady -v`
Expected: FAIL with `AttributeError`

**Step 3: Implement `poll_claude_ready()`**

Add to `VoiceServer` class in `voice_server/ios_server.py`:

```python
async def poll_claude_ready(self, timeout: float = 15.0, interval: float = 0.3) -> bool:
    """Poll tmux pane until Claude Code is loaded and ready.

    Returns True if Claude becomes ready within timeout, False otherwise.
    """
    from voice_server.pane_parser import is_claude_ready

    elapsed = 0.0
    while elapsed < timeout:
        pane_text = self.tmux.capture_pane(include_history=False)
        if is_claude_ready(pane_text):
            print(f"[INFO] Claude ready after {elapsed:.1f}s")
            return True
        await asyncio.sleep(interval)
        elapsed += interval

    print(f"[WARN] Claude not ready after {timeout}s timeout")
    return False
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py::TestPollClaudeReady -v`
Expected: PASS

**Step 5: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add poll_claude_ready() to verify Claude CLI startup"
```

---

### Task 4: Wire reset + readiness into `handle_new_session`

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`

**IMPORTANT:** Existing tests in `TestNewSession` and `TestActiveSessionTracking` (`test_new_session_clears_active_session_id`) don't mock `poll_claude_ready`. After modifying `handle_new_session`, these tests will fail. Update them to add `server.poll_claude_ready = AsyncMock(return_value=True)` so they pass with the new readiness check.

**Step 1: Write the new tests**

Add to `voice_server/tests/test_message_handlers.py`:

```python
class TestNewSessionLifecycle:
    """Tests for new_session state reset and readiness"""

    @pytest.mark.asyncio
    async def test_new_session_resets_state_before_starting(self):
        """handle_new_session must reset all state before starting."""
        from ios_server import VoiceServer

        server = VoiceServer()
        # Set up stale state
        server.active_session_id = "stale-session"
        server.transcript_path = "/old/path.jsonl"
        server.permission_handler.latest_request_id = "stale-request"

        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=True)
        server.broadcast_connection_status = AsyncMock()

        mock_ws = AsyncMock()
        await server.handle_new_session(mock_ws, {"project_path": "/tmp/test"})

        # Verify stale state was cleared
        assert server.permission_handler.latest_request_id is None
        assert server.transcript_path is None

        # Verify success was sent
        sent = json.loads(mock_ws.send.call_args_list[0][0][0])
        assert sent["success"] is True

    @pytest.mark.asyncio
    async def test_new_session_fails_when_claude_not_ready(self):
        """handle_new_session sends failure when Claude doesn't become ready."""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.tmux.kill_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=False)

        mock_ws = AsyncMock()
        await server.handle_new_session(mock_ws, {"project_path": "/tmp/test"})

        # Verify failure was sent
        sent = json.loads(mock_ws.send.call_args_list[0][0][0])
        assert sent["success"] is False
        assert "error" in sent

        # Verify tmux was killed
        server.tmux.kill_session.assert_called()
```

**Step 2: Update existing tests**

In `TestNewSession`, add `server.poll_claude_ready = AsyncMock(return_value=True)` after the `server.tmux` mock setup in each test. Same for `test_new_session_clears_active_session_id` in `TestActiveSessionTracking`.

**Step 3: Rewrite `handle_new_session`**

Replace the existing `handle_new_session` in `voice_server/ios_server.py`:

```python
async def handle_new_session(self, websocket, data):
    """Handle new_session request - starts claude in tmux"""
    project_path = data.get("project_path", "")
    print(f"[DEBUG] handle_new_session: project_path={project_path}")

    # Full state reset before anything else
    self._reset_session_state()

    # Snapshot existing session IDs BEFORE starting Claude
    existing_ids = set()
    folder_name = None
    if project_path:
        folder_name = self.session_manager.encode_path_to_folder(project_path)
        existing_ids = self.session_manager.list_session_ids(folder_name)
        print(f"[DEBUG] Snapshot: {len(existing_ids)} existing sessions in {folder_name}")

    success = self.tmux.start_session(working_dir=project_path if project_path else None)
    print(f"[DEBUG] start_session returned: {success}, session_exists: {self.tmux.session_exists()}")

    error = None
    if success:
        # Verify Claude actually started and is ready for input
        ready = await self.poll_claude_ready()
        if ready:
            self.active_session_id = None  # New session has no ID yet

            # Save snapshot for deferred detection on first voice input
            if folder_name:
                self._pending_session_snapshot = (folder_name, existing_ids)
                self.active_folder_name = folder_name
                print(f"[INFO] Session snapshot saved, will detect new file on first voice input")
        else:
            # Claude didn't start — clean up
            self.tmux.kill_session()
            success = False
            error = "Claude failed to start"
            print(f"[ERROR] Claude not ready after timeout, killed tmux session")

    response = {
        "type": "session_created",
        "success": success
    }
    if error:
        response["error"] = error
    await websocket.send(json.dumps(response))

    if success:
        await self.broadcast_connection_status()
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py -k "new_session" -v`
Expected: PASS (both new and updated existing tests)

**Step 5: Run all server tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests pass

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "fix: reset state and verify readiness in handle_new_session"
```

---

### Task 5: Wire reset + readiness into `handle_resume_session`

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`

**IMPORTANT:** Existing tests in `TestResumeSession` and `TestActiveSessionTracking` (`test_resume_session_sets_active_session_id`) don't mock `poll_claude_ready`. Update them to add `server.poll_claude_ready = AsyncMock(return_value=True)` so they pass with the new readiness check.

**Step 1: Write the new tests**

Add to `voice_server/tests/test_message_handlers.py`:

```python
class TestResumeSessionLifecycle:
    """Tests for resume_session state reset and readiness"""

    @pytest.mark.asyncio
    async def test_resume_session_resets_state_before_starting(self):
        """handle_resume_session must reset all state before starting."""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.active_session_id = "stale-session"
        server.permission_handler.latest_request_id = "stale-request"

        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=True)
        server.broadcast_connection_status = AsyncMock()
        server.session_manager.get_session_cwd = Mock(return_value="/tmp/test")
        server.switch_watched_session = Mock(return_value=True)

        mock_ws = AsyncMock()
        await server.handle_resume_session(mock_ws, {
            "session_id": "new-session-id",
            "folder_name": "test-folder"
        })

        assert server.permission_handler.latest_request_id is None

        sent = json.loads(mock_ws.send.call_args_list[0][0][0])
        assert sent["success"] is True

    @pytest.mark.asyncio
    async def test_resume_session_fails_when_claude_not_ready(self):
        """handle_resume_session sends failure when Claude doesn't become ready."""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.start_session = Mock(return_value=True)
        server.tmux.kill_session = Mock(return_value=True)
        server.poll_claude_ready = AsyncMock(return_value=False)
        server.session_manager.get_session_cwd = Mock(return_value="/tmp/test")

        mock_ws = AsyncMock()
        await server.handle_resume_session(mock_ws, {
            "session_id": "test-id",
            "folder_name": "test-folder"
        })

        sent = json.loads(mock_ws.send.call_args_list[0][0][0])
        assert sent["success"] is False
        assert "error" in sent
```

**Step 2: Update existing tests**

In `TestResumeSession`, add `server.poll_claude_ready = AsyncMock(return_value=True)` after the `server.tmux` mock setup in each test. Same for `test_resume_session_sets_active_session_id` in `TestActiveSessionTracking`.

**Step 3: Rewrite `handle_resume_session`**

Replace the existing `handle_resume_session` in `voice_server/ios_server.py`:

```python
async def handle_resume_session(self, websocket, data):
    """Handle resume_session request - runs 'claude --resume <id>' in tmux"""
    session_id = data.get("session_id", "")
    folder_name = data.get("folder_name", "")

    # Full state reset before anything else
    self._reset_session_state()

    success = False
    error = None

    if session_id:
        # Get the actual cwd from the session file
        working_dir = None
        if folder_name and session_id:
            working_dir = self.session_manager.get_session_cwd(folder_name, session_id)
            print(f"[DEBUG] handle_resume_session: get_session_cwd -> {working_dir}")

        success = self.tmux.start_session(working_dir=working_dir, resume_id=session_id)
        print(f"[DEBUG] start_session(resume_id={session_id}) returned: {success}")

        if success:
            # Verify Claude actually started
            ready = await self.poll_claude_ready()
            if ready:
                self.active_session_id = session_id
                if folder_name:
                    self.switch_watched_session(folder_name, session_id)
            else:
                self.tmux.kill_session()
                success = False
                error = "Claude failed to start"
                print(f"[ERROR] Claude not ready after timeout, killed tmux session")
        else:
            error = "Failed to start tmux session"
            print(f"[ERROR] Failed to start tmux session for resume_id={session_id}")

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

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py -k "resume_session" -v`
Expected: PASS (both new and updated existing tests)

**Step 5: Run all server tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests pass

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "fix: reset state and verify readiness in handle_resume_session"
```

---

### Task 6: iOS error display + manual verification

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectDetailView.swift`

**Step 1: Add error alert to SessionsListView**

In `SessionsListView.swift`, add a `@State` for the error and an alert:

```swift
@State private var sessionError: String?

// In createNewSession(), update the callback:
webSocketManager.onSessionActionResult = { response in
    isCreating = false
    if response.success {
        selectedSession = Session.newSession()
    } else {
        sessionError = response.error ?? "Failed to create session"
    }
}

// Add .alert modifier to the view:
.alert("Session Error", isPresented: Binding(
    get: { sessionError != nil },
    set: { if !$0 { sessionError = nil } }
)) {
    Button("OK") { sessionError = nil }
} message: {
    Text(sessionError ?? "")
}
```

**Step 2: Add same error alert to ProjectDetailView**

Same pattern in `ProjectDetailView.swift`.

**Step 3: Build for simulator**

Run:
```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: BUILD SUCCEEDED

**Step 4: Run all server tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests pass

**Step 5: Manual verification**

1. Reinstall server: `pipx install --force /Users/aaron/Desktop/max --python python3.9`
2. Start server: `claude-connect`
3. Build and install app on device
4. Open app, connect to server
5. Navigate to a project, tap plus button
6. Verify: session is created successfully and you can send a message
7. Verify: sending a message shows "Thinking" state

**CHECKPOINT:** New session creation must work end-to-end. If it doesn't, debug before proceeding.

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectDetailView.swift
git commit -m "fix: show error alert when session creation fails"
```
