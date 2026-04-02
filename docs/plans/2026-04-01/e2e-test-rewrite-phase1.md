---
status: completed
created: 2026-04-01
completed: 2026-04-02
branch: feature/e2e-test-rewrite
---

# E2E Test Rewrite — Phase 1: Infrastructure

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Build the infrastructure for two-tier E2E tests: a test server that can inject content into the iOS app, an updated E2ETestBase with injection helpers, and a runner script with `--fast`/`--smoke` modes. Phase 2 writes the actual test suites. Phase 3 adds real Claude smoke tests.

**Architecture:** The test server (`server/integration_tests/test_server.py`) gets updated to broadcast structured content blocks in the exact same WebSocket format as the real server. It responds to iOS app messages (list_projects, open_session, etc.) with canned data and provides HTTP endpoints for tests to inject content. E2ETestBase gets Swift helpers to call those endpoints. The runner script gets mode flags.

**Tech Stack:** Python (aiohttp + websockets), Swift (XCUITest), shell

**Risky Assumptions:** The test server's WebSocket message format must exactly match the real server's. Verify by reading the real server's broadcast code before implementing.

---

### Task 1: Update Mock Transcript and Test Server Broadcast Format

The mock transcript uses a flat `{"role": "assistant", "content": [...]}` format, but real Claude Code transcripts use `{"message": {"role": "assistant", "content": [...]}}`. The test server broadcasts raw text, not structured content blocks. Fix both.

**Files:**
- Modify: `server/integration_tests/mock_transcript.py`
- Modify: `server/integration_tests/test_server.py`

**Step 1: Read the real server's broadcast format**

Read `server/main.py` to find the exact JSON format of `assistant_response` messages that the real server sends to iOS via WebSocket. Note the exact field names, nesting, and types. This is the format the test server must produce.

**Step 2: Update mock_transcript.py to real transcript format**

Update `add_user_message` and `add_assistant_message` to use the `{"message": {"role": ..., "content": ...}}` wrapper that real transcripts use. Add new methods:

```python
def add_assistant_with_tool_use(self, tool_name: str, tool_id: str, tool_input: dict):
    """Add assistant message with a tool_use block."""
    message = {
        "message": {
            "role": "assistant",
            "content": [{"type": "tool_use", "id": tool_id, "name": tool_name, "input": tool_input}]
        },
        "timestamp": time.time()
    }
    self.messages.append(message)
    self._write()

def add_tool_result(self, tool_use_id: str, content: str, is_error: bool = False):
    """Add user message with a tool_result block."""
    message = {
        "message": {
            "role": "user",
            "content": [{"type": "tool_result", "tool_use_id": tool_use_id, "content": content, "is_error": is_error}]
        },
        "timestamp": time.time()
    }
    self.messages.append(message)
    self._write()

def add_thinking_block(self, thinking_text: str):
    """Add assistant message with a thinking block."""
    message = {
        "message": {
            "role": "assistant",
            "content": [{"type": "thinking", "thinking": thinking_text}]
        },
        "timestamp": time.time()
    }
    self.messages.append(message)
    self._write()
```

**Step 3: Update test server to broadcast structured content blocks**

The current `handle_claude_response()` sends raw text. Update it to parse transcript lines and broadcast `assistant_response` messages with `content_blocks` array matching the real server's format. The key is that the WebSocket message format matches what `WebSocketManager.swift` expects to decode.

**Step 4: Write tests for the updated mock transcript**

```bash
/Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_mock_transcript.py -v
```

Test that:
- `add_assistant_message` writes correct JSONL format
- `add_assistant_with_tool_use` produces valid tool_use blocks
- `add_tool_result` produces valid tool_result blocks
- File is valid JSONL after multiple writes

**Step 5: Commit**

```bash
git commit -m "feat: update mock transcript and test server broadcast format"
```

---

### Task 2: Add HTTP Injection Endpoints to Test Server

Add HTTP endpoints that let E2E tests inject arbitrary content into the iOS app via the test server.

**Files:**
- Modify: `server/integration_tests/test_server.py`

**Step 1: Read the real server's WebSocket message formats**

Read `server/main.py` to find the exact JSON format of: `assistant_response`, `permission_request`, `question_prompt`, `activity_status`, `directory_listing`, `file_contents`. These are the message types the test server needs to broadcast.

**Step 2: Add injection endpoints**

Add HTTP POST endpoints to the test server's control interface:

- `POST /inject_content_blocks` — accepts `{"blocks": [...]}`, broadcasts as `assistant_response` to all connected WebSocket clients
- `POST /inject_permission` — accepts permission request JSON, broadcasts as `permission_request`
- `POST /inject_question` — accepts `{"request_id": "...", "question": "...", "options": [...]}`, broadcasts as `question_prompt`
- `POST /inject_activity` — accepts `{"state": "thinking|tool_active|idle", "detail": "..."}`, broadcasts as `activity_status`
- `POST /inject_directory` — accepts `{"path": "...", "entries": [...]}`, broadcasts as `directory_listing`
- `POST /inject_file` — accepts `{"path": "...", "contents": "..."}`, broadcasts as `file_contents`

Each endpoint should:
1. Accept JSON body
2. Wrap it in the correct WebSocket message format (matching real server exactly)
3. Send to all connected WebSocket clients
4. Return 200 OK

**Step 3: Write tests for the injection endpoints**

```bash
/Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest server/tests/test_integration_server.py -v
```

Test that:
- `/inject_content_blocks` sends correct `assistant_response` WebSocket message
- `/inject_permission` sends correct `permission_request` format
- `/inject_question` sends correct `question_prompt` format
- `/reset` clears all state

Tests should connect a WebSocket client, inject via HTTP, and verify the WebSocket message received.

**Step 4: Commit**

```bash
git commit -m "feat: add HTTP injection endpoints to test server"
```

---

### Task 3: Add Session Simulation to Test Server

The iOS app sends messages like `list_projects`, `list_sessions`, `open_session`, `list_directory`, `read_file` when the user navigates. The test server needs to respond with canned data so E2E tests can navigate the app without a real server.

**Files:**
- Modify: `server/integration_tests/test_server.py`
- Modify: `server/integration_tests/test_config.py`

**Step 1: Read the real server's message handlers**

Read `server/main.py` to find how it handles `list_projects`, `list_sessions`, `open_session`, `resume_session`, `new_session`, `view_session`, `close_session`, `list_directory`, `read_file`. Note the response format for each.

**Step 2: Add mock data**

Add configurable mock data to the test server:

```python
self.mock_projects = [
    {"name": "e2e_test_project", "path": "/private/tmp/e2e_test_project", "folder_name": "-private-tmp-e2e-test-project"}
]
self.mock_sessions = [
    {"id": "test-session-1", "cwd": "/private/tmp/e2e_test_project", "timestamp": time.time(), "summary": "Test session"}
]
```

**Step 3: Handle iOS app messages**

Update `handle_message()` to respond to all message types the iOS app can send:

```python
if msg_type == 'list_projects':
    await websocket.send(json.dumps({"type": "projects", "projects": self.mock_projects}))
elif msg_type == 'list_sessions':
    await websocket.send(json.dumps({"type": "sessions_list", "sessions": self.mock_sessions, "active_session_ids": []}))
elif msg_type == 'open_session' or msg_type == 'resume_session' or msg_type == 'view_session':
    session_id = data.get('session_id', 'test-session-1')
    await websocket.send(json.dumps({"type": "session_history", "messages": []}))
    await websocket.send(json.dumps({"type": "connection_status", "connected": True, "active_session_ids": [session_id]}))
elif msg_type == 'new_session':
    new_id = f"test-session-{int(time.time())}"
    await websocket.send(json.dumps({"type": "session_created", "session_id": new_id}))
    await websocket.send(json.dumps({"type": "connection_status", "connected": True, "active_session_ids": [new_id]}))
elif msg_type == 'list_directory':
    # Respond with mock directory listing
    await websocket.send(json.dumps({"type": "directory_listing", "path": data.get('path', '/'), "entries": self.mock_directory_entries}))
elif msg_type == 'read_file':
    await websocket.send(json.dumps({"type": "file_contents", "path": data.get('path', ''), "contents": "mock file contents"}))
elif msg_type == 'set_preference':
    pass  # Acknowledge silently
elif msg_type == 'close_session':
    await websocket.send(json.dumps({"type": "session_closed"}))
```

**Step 4: Add mock directory data**

```python
self.mock_directory_entries = [
    {"name": "README.md", "type": "file"},
    {"name": "src", "type": "directory"},
    {"name": "test.txt", "type": "file"}
]
```

**Step 5: Write tests for session simulation**

Test that:
- `list_projects` returns mock projects
- `list_sessions` returns mock sessions
- `open_session` returns session_history + connection_status
- `list_directory` returns mock entries
- `read_file` returns mock contents

**Step 6: Commit**

```bash
git commit -m "feat: add session simulation to test server"
```

---

### Task 4: Update E2ETestBase

Strip dead code, update for current UI, add test server injection helpers and mode flag.

**Files:**
- Modify: `ios/ClaudeConnect/ClaudeConnectUITests/E2ETestBase.swift`

**Step 1: Read current UI accessibility identifiers**

Read SessionView.swift, ProjectsListView.swift, ProjectDetailView.swift, PermissionCardView.swift, and SettingsView.swift to find current accessibility identifiers. The old tests may reference stale identifiers.

**Step 2: Add `isTestServerMode` flag**

Read from `/tmp/e2e_test_config.json`:

```swift
var isTestServerMode: Bool {
    testConfig["mode"] == "test_server"
}
```

**Step 3: Add test server HTTP injection helpers**

```swift
// MARK: - Test Server Injection

func injectContentBlocks(_ blocks: [[String: Any]]) {
    postToTestServer("/inject_content_blocks", payload: ["blocks": blocks])
}

func injectTextResponse(_ text: String) {
    injectContentBlocks([["type": "text", "text": text]])
}

func injectToolUse(name: String, input: [String: Any], result: String) {
    let toolId = UUID().uuidString
    injectContentBlocks([
        ["type": "tool_use", "id": toolId, "name": name, "input": input],
        ["type": "tool_result", "tool_use_id": toolId, "content": result]
    ])
}

func injectQuestionPrompt(question: String, options: [String]) -> String {
    let requestId = UUID().uuidString
    postToTestServer("/inject_question", payload: [
        "request_id": requestId,
        "question": question,
        "options": options
    ])
    return requestId
}

func injectDirectoryListing(path: String, entries: [[String: Any]]) {
    postToTestServer("/inject_directory", payload: ["path": path, "entries": entries])
}

func injectFileContents(path: String, contents: String) {
    postToTestServer("/inject_file", payload: ["path": path, "contents": contents])
}

/// Generic POST helper for test server HTTP endpoints
private func postToTestServer(_ endpoint: String, payload: [String: Any]) {
    let httpPort = testServerPort + 1
    let url = URL(string: "http://\(testServerHost):\(httpPort)\(endpoint)")!
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

    let semaphore = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: request) { _, _, _ in
        semaphore.signal()
    }.resume()
    _ = semaphore.wait(timeout: .now() + 5)
    sleep(1)
}
```

**Step 4: Update `connectToServer()` for test server mode**

For test server mode, connection verification should wait for project cells from the mock data rather than checking tmux status.

**Step 5: Update `navigateToTestSession()` for test server mode**

In test server mode, skip `waitForSessionSyncComplete()` (no tmux), `verifyTmuxSessionRunning()`, and `waitForClaudeReady()`. Instead, just wait for the session view to render after the test server responds to `open_session`.

**Step 6: Clean up dead code**

Remove:
- `waitForResponseCycle()` — replaced by `waitForClaudeReady()` in tier 2
- Legacy `waitForPermissionSheet` / `waitForPermissionSheetDismissed` aliases
- `waitForVoiceState()` — not needed in either tier
- `tapTalkButton()` / `isTalkButtonEnabled()` — not needed

Keep for tier 2 smoke tests:
- `sendVoiceInput()`, `verifyTmuxSessionRunning()`, `captureTmuxPane()`, `waitForClaudeReady()`, `verifyInputInTmux()`

Keep for both tiers:
- `tapByCoordinate()`, `navigateToProjectsList()`, `openSettings()`, `disconnectFromServer()`
- `waitForPermissionCard()`, `waitForPermissionResolved()`
- `injectPermissionRequest()` — update to use `/inject_permission` endpoint in test server mode (currently it POSTs to `/permission` which is the real server's hook endpoint; the test server's `/inject_permission` from Task 2 is the equivalent)

**Step 7: Commit**

```bash
git commit -m "refactor: update E2ETestBase for two-tier test architecture"
```

---

### Task 5: Update Runner Script

Add `--fast` (test server) and `--smoke` (real Claude) modes.

**Files:**
- Modify: `ios/ClaudeConnect/run_e2e_tests.sh`

**Step 1: Add mode flag parsing**

```bash
MODE="all"
SPECIFIC_SUITE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast) MODE="fast"; shift ;;
        --smoke) MODE="smoke"; shift ;;
        *) SPECIFIC_SUITE="$1"; shift ;;
    esac
done
```

**Step 2: Define suite lists for each tier**

```bash
FAST_SUITES=(
    "E2EConnectionTests"
    "E2EConversationTests"
    "E2EPermissionTests"
    "E2EQuestionTests"
    "E2ENavigationTests"
    "E2ESessionTests"
    "E2EFileBrowserTests"
)

SMOKE_SUITES=(
    "E2ESmokeTests"
)
```

**Step 3: Add test server startup function**

```bash
start_test_server() {
    echo "📡 Starting test server..."
    cd "$PROJECT_ROOT"
    PYTHONUNBUFFERED=1 "$PYTHON" -m server.integration_tests.test_server > "$LOG_FILE" 2>&1 &
    SERVER_PID=$!
    echo "   Server PID: $SERVER_PID"
    
    # Wait for "READY" signal
    for i in $(seq 1 $SERVER_STARTUP_TIMEOUT); do
        if grep -q "READY" "$LOG_FILE" 2>/dev/null; then
            echo "✅ Test server started"
            return 0
        fi
        sleep 1
    done
    echo "❌ Test server failed to start"
    cat "$LOG_FILE"
    exit 1
}
```

**Step 4: Implement mode logic**

For `--fast`:
- Write `"mode": "test_server"` to config with mock session data
- Start test server
- Run FAST_SUITES

For `--smoke`:
- Create real Claude session (existing logic)
- Write `"mode": "real"` to config
- Start real server
- Run SMOKE_SUITES

For default (both):
- Run fast mode first
- Kill test server
- Run smoke mode

**Step 5: Fix the Python path**

Replace `$PROJECT_ROOT/.venv/bin/python3` with:

```bash
PYTHON="/Users/aaron/.local/pipx/venvs/claude-connect/bin/python"
```

**Step 6: Test the script modes**

Run `./run_e2e_tests.sh --fast` — should start test server and exit cleanly (no test suites exist yet to run, but server should start). Test `--smoke` similarly.

**CHECKPOINT:** Script starts test server in `--fast` mode and real server in `--smoke` mode without errors.

**Step 7: Commit**

```bash
git commit -m "feat: add --fast and --smoke modes to E2E runner script"
```

---

### Task 6: Verify Infrastructure End-to-End

Manually verify the full infrastructure works before writing test suites in Phase 2.

**Step 1: Start test server manually**

```bash
cd /Users/aaron/Desktop/max
/Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m server.integration_tests.test_server
```

Verify it prints "READY" and is listening on ports 8765/8766.

**Step 2: Connect a WebSocket client and test session simulation**

Use `websocat` or a simple Python script to:
1. Connect to ws://localhost:8765
2. Send `{"type": "list_projects"}`
3. Verify response has `{"type": "projects", "projects": [...]}`
4. Send `{"type": "open_session", "session_id": "test-session-1", "folder_name": "..."}`
5. Verify `session_history` and `connection_status` responses

**Step 3: Test HTTP injection**

```bash
curl -X POST http://localhost:8766/inject_content_blocks \
  -H 'Content-Type: application/json' \
  -d '{"blocks": [{"type": "text", "text": "hello from test"}]}'
```

Verify the WebSocket client receives an `assistant_response` message.

**Step 4: Run the full runner script**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast
```

This will fail (no test suites yet) but should successfully:
- Write config file
- Start test server
- Attempt xcodebuild (fails because suites don't exist yet — that's OK)

**CHECKPOINT:** Test server starts, accepts connections, responds to messages, and injection endpoints broadcast correctly. This is the foundation for Phase 2.

**Step 5: Commit (if any fixes were needed)**

```bash
git commit -m "fix: infrastructure fixes from end-to-end verification"
```
