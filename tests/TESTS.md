# Voice Mode Test Reference

## Quick Start

```bash
# Server tests (Python)
cd voice_server/tests && ./run_tests.sh

# iOS unit tests
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests

# E2E tests (full integration with real server)
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh
```

## Test Suites Overview

| Suite | Count | Type | Location |
|-------|-------|------|----------|
| Server Tests | ~287 (25 files) | pytest | `voice_server/tests/` |
| iOS Unit Tests | ~69 | XCTest | `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/` |
| E2E Tests | 18 | XCUITest | `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2E*.swift` |
| Integration Tests | ~34 | XCUITest | `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/*Tests.swift` |

---

## Server Tests (pytest)

**Location:** `voice_server/tests/`

```bash
cd voice_server/tests
./run_tests.sh              # all tests
./run_tests.sh coverage     # with coverage
pytest -v                   # direct pytest
pytest test_ios_server.py::TestVoiceServer::test_send_status -v  # specific test
```

**What's tested:**
- WebSocket server initialization and message handling (`test_ios_server.py`, `test_message_handlers.py`, `test_message_formats.py`)
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

**Location:** `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/`

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests

# Specific test class
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/AudioPlayerTests
```

**What's tested:**
- AudioPlayer: chunk receiving, playback state, callbacks (`AudioPlayerTests.swift`)
- WebSocketManager: connection state, JSON encoding, callbacks (`WebSocketManagerTests.swift`)
- Permission models: request/response encoding, suggestion display (`PermissionRequestTests.swift`)
- QR code validation: URL parsing, scheme validation (`QRCodeValidatorTests.swift`)
- ClaudeOutputState: state transitions (`ClaudeOutputStateTests.swift`)
- InputBarMode: input bar state machine (`InputBarModeTests.swift`)
- DiffView: diff parsing and display (`DiffViewTests.swift`)
- General models and integration flows (`ClaudeVoiceTests.swift`)

---

## E2E Tests (XCUITest + Real Server)

**Location:** `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2E*.swift`

```bash
# Run all E2E tests
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh

# Run specific E2E test suite
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2EPermissionTests
```

### How E2E Tests Work

The E2E runner (`run_e2e_tests.sh`) performs these steps:

1. **Create test session** - Runs `claude --print "Reply with only: ok"` in `/tmp/e2e_test_project` to create a real Claude session
2. **Extract session ID** - Finds the session file in `~/.claude/projects/-tmp-e2e_test_project/` and extracts the UUID
3. **Start server** - Launches `ios_server.py`
4. **Pass session info** - Exports environment variables to tests:
   - `E2E_TEST_SESSION_ID` - UUID of the created session
   - `E2E_TEST_PROJECT_NAME` - "e2e_test_project"
   - `E2E_TEST_FOLDER_NAME` - "-tmp-e2e_test_project"
5. **Run tests** - Executes specified test suites
6. **Cleanup** - Kills server and tmux session (keeps session files for debugging)

### Why Dynamic Session Creation?

Tests use a real Claude session created at test start because:
- Session files persist in `~/.claude/projects/` but working directories in `/tmp` are cleared on reboot
- Pre-created sessions can become stale or reference non-existent paths
- Dynamic creation ensures the session is always valid and resumable

**CRITICAL: If the test passes, it MUST work on a real device.**

Tests that mock core functionality (subprocess calls, file operations) can pass while the real system is broken. E2E tests must use:
- Real tmux sessions (with test-specific session names)
- Real file watching with real file modifications
- Real WebSocket connections

**Test suites:**
- `E2EConnectionTests` - Server connection and reconnection
- `E2EErrorHandlingTests` - Malformed messages, server errors
- `E2ESessionFlowTests` - Session sync and management
- `E2EFullConversationFlowTests` - Full voice → Claude → TTS flow
- `E2ENavigationFlowTests` - Project/session navigation
- `E2EPermissionTests` - Permission prompt UI

**Support utilities:** `tests/e2e_support/`
- `server_manager.py` - Server lifecycle management

---

## Integration Tests (XCUITest + Test Server)

**Location:** `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/*Tests.swift` (non-E2E)

These tests use `IntegrationTestBase` and require a running test server:

```bash
# Start server first
python3 voice_server/ios_server.py

# Run integration tests
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceUITests/StateManagementTests
```

**Test suites (~34 tests):**
- `StateManagementTests` - Voice state transitions, button enable/disable states
- `VoiceInputFlowTests` - Voice input delivery and processing flow
- `AudioStreamingTests` - Audio chunk handling and playback
- `ErrorHandlingTests` - Error states and recovery
- `TranscriptMonitoringTests` - Transcript file watching
- `PerformanceTests` - Performance benchmarks

---

## Running Specific Tests

```bash
# Server - specific test
pytest voice_server/tests/test_ios_server.py::TestSessionManager -v

# iOS unit - specific class
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/WebSocketManagerTests

# E2E - run manually (start server first)
python3 voice_server/ios_server.py  # terminal 1
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceUITests/E2EHappyPathTests  # terminal 2
```

---

## Troubleshooting

**Tests hang or timeout:**
```bash
ps aux | grep ClaudeVoice           # check for stuck processes
pkill -f ClaudeVoice                # kill lingering instances
xcrun simctl shutdown all           # reset simulator
```

**Server connection issues:**
```bash
lsof -ti :8765 | xargs kill -9      # kill existing server
tail -f /tmp/e2e_server.log         # check server logs
```

**Server tests fail:**
```bash
source .venv/bin/activate           # ensure venv active
pip install -r voice_server/tests/requirements-test.txt
rm -rf .pytest_cache                # clear cache
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
ls -la ~/Library/Developer/Xcode/DerivedData/ClaudeVoice-*/Logs/Test/

# Extract test summary from xcresult (JSON format)
xcrun xcresulttool get --path <path-to.xcresult> --format json | python3 -m json.tool | head -100

# Example: extract from most recent result
RESULT=$(ls -t ~/Library/Developer/Xcode/DerivedData/ClaudeVoice-*/Logs/Test/*.xcresult | head -1)
xcrun xcresulttool get --path "$RESULT" --format json 2>/dev/null | python3 -m json.tool | head -50
```

### Common E2E Failure Patterns

| Failure | Likely Cause |
|---------|--------------|
| `waitForVoiceState("Speaking")` timeout | TTS/audio pipeline issue, server not responding |
| `waitForExistence` timeout | UI element not rendered, navigation issue |
| `connection status` failures | Server not running, port conflict |
| `no close frame received` in server log | Normal - test client disconnected |
