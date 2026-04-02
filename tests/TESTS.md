# Voice Mode Test Reference

## Quick Start

```bash
# Server tests (Python)
cd server/tests && ./run_tests.sh

# iOS unit tests
cd ios/ClaudeConnect
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO

# E2E tests (full integration with real server)
cd ios/ClaudeConnect && ./run_e2e_tests.sh
```

## Test Suites Overview

| Suite | Count | Type | Location |
|-------|-------|------|----------|
| Server Tests | ~315 (31 files) | pytest | `server/tests/` |
| iOS Unit Tests | ~69 | XCTest | `ios/ClaudeConnect/ClaudeConnectTests/` |
| E2E Tests (Tier 1) | 17 | XCUITest + test server | `ios/ClaudeConnect/ClaudeConnectUITests/E2E*.swift` |

---

## Server Tests (pytest)

**Location:** `server/tests/`

```bash
cd server/tests
./run_tests.sh              # all tests
./run_tests.sh coverage     # with coverage
pytest -v                   # direct pytest
pytest test_main.py::TestConnectServer::test_send_status -v  # specific test
```

**What's tested:**
- WebSocket server initialization and message handling (`test_main.py`, `test_message_handlers.py`, `test_message_formats.py`)
- Transcript file monitoring and response extraction (`test_response_extraction.py`, `test_text_extraction.py`, `test_transcript_watcher.py`)
- TTS utilities, audio streaming, queue, and preferences (`test_tts_utils.py`, `test_tts_queue.py`, `test_tts_preference.py`)
- Session management (projects, sessions, history) (`test_session_manager.py`)
- Structured content parsing and models (`test_content_handler.py`, `test_content_models.py`)
- Permission handling and integration (`test_permission_handler.py`, `test_permission_integration.py`)
- HTTP hook server endpoints (`test_http_server.py`, `test_hooks.py`)
- Context tracking and broadcast (`test_context_tracker.py`, `test_context_broadcast.py`)
- Usage checking and parsing (`test_usage_handler.py`, `test_usage_parser.py`)
- Tmux controller (`test_tmux_controller.py`)
- Pane activity state parsing (`test_pane_parser.py`)
- QR code display (`test_qr_display.py`)
- State validation and sync (`test_state_validation.py`, `test_sync_integration.py`)

---

## iOS Unit Tests (XCTest)

**Location:** `ios/ClaudeConnect/ClaudeConnectTests/`

```bash
cd ios/ClaudeConnect
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO

# Specific test class
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests/AudioPlayerTests \
  -parallel-testing-enabled NO
```

**What's tested:**
- AudioPlayer: chunk receiving, playback state, callbacks (`AudioPlayerTests.swift`)
- WebSocketManager: connection state, JSON encoding, callbacks (`WebSocketManagerTests.swift`)
- Permission models: request/response encoding, suggestion display (`PermissionRequestTests.swift`)
- QR code validation: URL parsing, scheme validation (`QRCodeValidatorTests.swift`)
- ClaudeOutputState: state transitions (`ClaudeOutputStateTests.swift`)
- InputBarMode: input bar state machine (`InputBarModeTests.swift`)
- DiffView: diff parsing and display (`DiffViewTests.swift`)
- General models and integration flows (`ClaudeConnectTests.swift`)

---

## E2E Tests (Two-Tier Architecture)

**Location:** `ios/ClaudeConnect/ClaudeConnectUITests/E2E*.swift`

E2E tests use a two-tier architecture:

- **Tier 1 (test server):** Fast, deterministic tests using a mock test server with HTTP injection endpoints. No real Claude session needed. ~2 min.
- **Tier 2 (smoke):** Real Claude Code integration tests using a live server and tmux session. Coming in Phase 3.

```bash
# All E2E tests (test server + smoke)
cd ios/ClaudeConnect && ./run_e2e_tests.sh

# Tier 1 only — fast, test server (~2 min)
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast

# Tier 2 only — smoke, real Claude (~3 min)
cd ios/ClaudeConnect && ./run_e2e_tests.sh --smoke

# Specific suite
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast E2EPermissionTests
```

### How Tier 1 (Test Server) Tests Work

1. **Start test server** — `server/integration_tests/test_server.py` launches on ports 8765 (WebSocket) + 8766 (HTTP)
2. **Write config** — `/tmp/e2e_test_config.json` with `"mode": "test_server"` and mock session data
3. **iOS app connects** — App reads config, connects to test server WebSocket
4. **Tests inject content** — Swift test helpers call HTTP endpoints (`/inject_content_blocks`, `/inject_permission`, `/inject_question`, etc.) to push content into the app
5. **Tests verify UI** — XCUITest assertions check that injected content renders correctly

### Test Suites (17 tests across 7 suites)

| Suite | Tests | What it covers |
|-------|-------|----------------|
| `E2EConnectionTests` | 3 | Connect, settings status, disconnect flow |
| `E2EConversationTests` | 3 | Text responses, tool use blocks, multiple blocks |
| `E2EPermissionTests` | 4 | Bash/edit permissions, deny, suggestions |
| `E2EQuestionTests` | 2 | Question with options, question without options |
| `E2ENavigationTests` | 1 | Full navigation flow (projects → detail → settings → back) |
| `E2ESessionTests` | 2 | Open session, navigate back from session |
| `E2EFileBrowserTests` | 2 | Files tab listing, view file contents |

### Key Infrastructure

- **Test server** (`server/integration_tests/test_server.py`): WebSocket server with canned responses for `list_projects`, `open_session`, etc. HTTP injection endpoints for test control.
- **E2ETestBase** (`E2ETestBase.swift`): Base class with injection helpers (`injectTextResponse`, `injectToolUse`, `injectPermissionRequest`, `injectQuestionPrompt`, etc.) and navigation utilities.
- **Runner script** (`run_e2e_tests.sh`): Manages test server lifecycle, config file, and xcodebuild invocation.

**Support utilities:** `tests/e2e_support/`
- `server_manager.py` - Server lifecycle management

---

## Running Specific Tests

```bash
# Server - specific test
pytest server/tests/test_main.py::TestSessionManager -v

# iOS unit - specific class
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests/WebSocketManagerTests \
  -parallel-testing-enabled NO

# E2E - specific suite
cd ios/ClaudeConnect && ./run_e2e_tests.sh --fast E2EPermissionTests
```

---

## Troubleshooting

**Tests hang or timeout:**
```bash
ps aux | grep ClaudeConnect           # check for stuck processes
pkill -f ClaudeConnect                # kill lingering instances
xcrun simctl shutdown all           # reset simulator
```

**Server connection issues:**
```bash
lsof -ti :8765 | xargs kill -9      # kill existing server
tail -f /tmp/e2e_server.log         # check server logs
```

**Server tests fail:**
```bash
pipx install --force /Users/aaron/Desktop/max  # reinstall with latest code
rm -rf .pytest_cache                            # clear cache
```

---

## Analyzing Test Failures

### Log Files

| Log File | Contents |
|----------|----------|
| `/tmp/e2e_test.log` | E2E test runner output (xcodebuild) |
| `/tmp/e2e_server.log` | Python server logs during E2E tests |
| `/tmp/websocket_debug.log` | iOS WebSocket debug logs |

### Finding Failure Reasons

```bash
# Search for assertion failures in E2E test output
grep -A10 -B5 "XCTAssert\|failed\|Failed" /tmp/e2e_test.log

# Example output showing failure location and reason:
# E2EErrorHandlingTests.swift:19: XCTAssertTrue failed - Should handle valid message
```

### Xcode Test Results (xcresult)

Test results are saved to xcresult bundles. Path is printed at end of test run:

```bash
# List available test result bundles
ls -la ~/Library/Developer/Xcode/DerivedData/ClaudeConnect-*/Logs/Test/

# Extract test summary from xcresult (JSON format)
xcrun xcresulttool get --path <path-to.xcresult> --format json | python3 -m json.tool | head -100

# Example: extract from most recent result
RESULT=$(ls -t ~/Library/Developer/Xcode/DerivedData/ClaudeConnect-*/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool get --path "$RESULT" --format json 2>/dev/null | python3 -m json.tool | head -50
```

### Common E2E Failure Patterns

| Failure | Likely Cause |
|---------|--------------|
| `waitForExistence` timeout | UI element not rendered, wrong accessibility identifier, or test server message format mismatch |
| `connection status` failures | Test server not running, port conflict |
| `no close frame received` in server log | Normal - test client disconnected |
| Server tests pass from root but fail from `server/tests/` | Stale pipx install — run `pipx install --force /Users/aaron/Desktop/max` |
