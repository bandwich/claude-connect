# E2E Testing Design for iOS Voice Mode

**Date:** 2026-01-01
**Status:** Approved
**Author:** Claude Code (brainstorm-plan)

## Overview

Design for comprehensive end-to-end smoke tests that verify the iOS voice app and server work correctly together. Tests will use the Xcode simulator running the real iOS app connected to the real `ios_server.py`, with mocked speech recognition and Claude/VSCode interactions.

## Goals

- Verify critical user flows work end-to-end
- Test real `ios_server.py` implementation (not mocked)
- Ensure app UI states update correctly
- Validate WebSocket communication between app and server
- Catch integration issues that unit tests miss

## Non-Goals

- Replace existing unit tests (keep Python and Swift unit tests)
- Test real Claude API or VSCode integration (mocked via transcript injection)
- Test real iOS speech recognition (mocked with dummy text)
- Performance benchmarking (basic smoke tests only)

## Architecture

### Test Structure

```
ios-voice-app/ClaudeVoice/
├── ClaudeVoiceTests/           # Keep: Swift unit tests
├── ClaudeVoiceUITests/         # REPLACE: New E2E tests
│   ├── E2ETestBase.swift       # Base class for E2E tests
│   ├── E2EHappyPathTests.swift # Happy path scenarios
│   ├── E2EConnectionTests.swift # Connection & reconnection
│   └── E2EErrorHandlingTests.swift # Error scenarios
└── ClaudeVoiceE2ESupport/      # New: Test infrastructure
    ├── server_manager.py       # Launch/manage real ios_server.py
    ├── transcript_injector.py  # Inject mock assistant messages
    └── test_config.py          # Configuration (ports, paths)

voice_server/tests/             # Keep: Python unit tests (unchanged)
```

### Key Principles

1. **Real server**: Tests launch actual `ios_server.py` process (not mock `test_server.py`)
2. **Mock boundaries**: Mock speech recognition (app side) and transcript messages (server side)
3. **Process isolation**: Each test class gets fresh server instance
4. **Clean state**: Transcript files cleaned between tests
5. **Reuse patterns**: Reference existing `IntegrationTestBase` for UI interaction helpers

### Three-Layer Testing Strategy

**1. Python Unit Tests** (existing, unchanged)
- **Location:** `voice_server/tests/test_*.py`
- **Tests:** Server logic in isolation with mocked dependencies
- **Run:** `cd voice_server/tests && ./run_tests.sh`
- **Purpose:** Fast unit tests for server code

**2. Swift Unit Tests** (existing, unchanged)
- **Location:** `ClaudeVoiceTests/`
- **Tests:** iOS app logic in isolation with mocked WebSocket/audio
- **Run:** Xcode Test Navigator
- **Purpose:** Fast unit tests for app code

**3. E2E Tests** (new, replacing existing UI tests)
- **Location:** `ClaudeVoiceUITests/`
- **Tests:** Full system integration (real app + real server)
- **Run:** Xcode UI tests
- **Purpose:** Verify complete user flows work end-to-end

## Components

### 1. E2ETestBase.swift

**Responsibilities:**
- Launch real `ios_server.py` via Python helper script
- Manage server process lifecycle (start in `setUp`, kill in `tearDown`)
- Configure app to connect to real server
- Provide UI helper methods (tap buttons, wait for states, check labels)
- Inject mock assistant responses via `transcript_injector.py`

**Key Methods:**
```swift
class E2ETestBase: XCTestCase {
    var serverProcess: Process?
    var serverPID: Int?
    var transcriptPath: String?

    override func setUp() {
        // Launch server, wait for READY, configure app
    }

    override func tearDown() {
        // Kill server, clean up temp files
    }

    func connectToServer()
    func sendVoiceInput(_ text: String)
    func injectAssistantResponse(_ text: String)
    func waitForVoiceState(_ state: String, timeout: TimeInterval) -> Bool
    func waitForConnectionState(_ state: String, timeout: TimeInterval) -> Bool
}
```

**Differences from old IntegrationTestBase:**
- Spawns real server process instead of assuming mock server is running
- Uses subprocess to call Python scripts
- Waits for server "READY" signal before proceeding

### 2. server_manager.py

**Responsibilities:**
- Launch `ios_server.py` with test configuration
- Create temporary transcript file for test session
- Monitor server startup (wait for "READY" output)
- Provide clean shutdown on test completion

**CLI Interface:**
```bash
# Start server
python server_manager.py start --transcript /tmp/test_transcript.jsonl
# Output: {"pid": 12345, "port": 8765, "status": "ready"}

# Stop server
python server_manager.py stop --pid 12345
```

**Implementation Notes:**
- Uses `subprocess.Popen` to launch `ios_server.py`
- Monitors stdout for "READY" signal (with timeout)
- Returns JSON with server metadata
- Tracks PID for cleanup

### 3. transcript_injector.py

**Responsibilities:**
- Inject mock assistant messages into transcript file
- Server's file watcher detects changes naturally
- Format messages as proper JSONL entries

**CLI Interface:**
```bash
python transcript_injector.py \
  --transcript /tmp/test_transcript.jsonl \
  --message "Hello from Claude"
```

**Implementation Notes:**
- Appends properly formatted JSONL assistant message
- Validates file exists and is writable
- Returns exit code: 0 = success, 1 = error

## Data Flow

### Complete E2E Test Execution Flow

Using `test_complete_voice_conversation_flow` as example:

#### Setup Phase
1. `E2ETestBase.setUp()` runs
2. Calls `server_manager.py start` → spawns real `ios_server.py`
3. Server creates temp transcript file, starts WebSocket listener on port 8765
4. Server prints "READY" to stdout → test proceeds
5. iOS app launches with test environment variables:
   - `TEST_MODE=1`
   - `SERVER_HOST=127.0.0.1`
   - `SERVER_PORT=8765`
6. App auto-connects to server via WebSocket
7. Verify connection: check "Connected" status label exists

#### Test Execution Phase
1. Test calls `sendVoiceInput("Hello Claude")` helper
2. Helper uses app UI automation to:
   - Mock speech recognition result (inject dummy text into app)
   - Tap "Talk" button programmatically
   - App sends `{"type": "voice_input", "text": "Hello Claude"}` via WebSocket
3. Server receives message, logs it, processes normally
4. Test calls `injectAssistantResponse("Hi! How can I help?")` helper
5. Helper runs: `transcript_injector.py --message "Hi! How can I help?"`
6. Injector appends assistant message to transcript file in JSONL format
7. Server's watchdog detects file modification event
8. Server extracts assistant message from transcript
9. Server generates TTS audio using Kokoro
10. Server streams audio chunks to app via WebSocket (base64-encoded WAV)
11. App receives chunks, buffers, starts playback
12. App UI updates: Idle → Processing → Speaking → Idle
13. Test verifies state transitions using `waitForVoiceState("Speaking")`
14. Test waits for return to idle: `waitForVoiceState("Idle")`

#### Teardown Phase
1. `E2ETestBase.tearDown()` runs (even on test failure)
2. Calls `server_manager.py stop --pid <PID>`
3. Server process killed gracefully (SIGTERM, then SIGKILL if needed)
4. Cleans up temp transcript file
5. App terminates

## Error Handling & Reliability

### Server Startup Failures
- `server_manager.py` waits max 10 seconds for "READY" signal
- If timeout: raises exception with server stderr output
- Test fails fast with clear error: "Server failed to start: <reason>"
- Cleanup: Kill any orphaned server processes by PID

### Test Failures Mid-Execution
- `E2ETestBase.tearDown()` runs even on test failure (XCTest guarantee)
- Server process killed via tracked PID
- Temp transcript files deleted from `/tmp`
- Prevents orphaned processes or leftover files

### WebSocket Connection Issues
- App connection timeout: `connectToServer()` waits max 10 seconds
- If connection fails: Check server is still running, log server output
- Retry logic: Optional 1 retry with fresh connection attempt
- Clear assertion: "Failed to connect to server at 127.0.0.1:8765"

### State Verification Timeouts
- `waitForVoiceState()` uses configurable timeout (default 10s)
- On timeout: Capture current app state, server logs, transcript contents
- Print diagnostic info before failing assertion
- Example: "Expected 'Speaking' but got 'Idle' after 10s. Server logs: ..."

### Transcript Injection Failures
- `transcript_injector.py` validates file exists and is writable
- Verifies JSONL format of injected message
- Returns status codes:
  - 0 = success
  - 1 = file error
  - 2 = format error

### Process Cleanup
- Use `atexit` handlers in Python scripts to ensure cleanup
- Track all server PIDs in test base class for forced cleanup
- Clean temp directory on test suite completion
- Prevent port conflicts by waiting for socket close

## Test Suite

### E2EHappyPathTests.swift

**1. test_complete_voice_conversation_flow**
- Connect to real ios_server
- App sends dummy voice input "Hello Claude"
- Test harness injects assistant response into transcript
- Server detects response, streams audio back
- Verify app shows: Idle → Processing → Speaking → Idle states
- Verify audio playback occurs
- **Success criteria:** All state transitions occur, no errors in logs

**2. test_multiple_conversation_turns**
- Send 3 back-and-forth messages in sequence
- Verify each completes before next starts
- Verify no state corruption between turns
- **Success criteria:** All 3 turns complete successfully, clean state after each

### E2EConnectionTests.swift

**3. test_initial_connection_to_real_server**
- Start real ios_server via server_manager.py
- App connects via WebSocket
- Verify connection status shows "Connected"
- Verify initial voice state is "Idle"
- Verify talk button is enabled
- **Success criteria:** Connection established, UI shows correct initial state

**4. test_reconnection_after_disconnect**
- Connect → disconnect → reconnect
- Verify clean state reset after reconnection
- Verify server handles reconnection gracefully
- **Success criteria:** Reconnection successful, state resets properly

**5. test_connection_failure_handling**
- Start app with server not running
- Attempt connection
- Verify app shows appropriate error state
- Verify talk button is disabled
- Verify no crashes
- **Success criteria:** Graceful error handling, app remains functional

### E2EErrorHandlingTests.swift

**6. test_malformed_message_handling**
- Send invalid JSON from app via WebSocket
- Verify server doesn't crash (check process still alive)
- Verify app remains functional
- Send valid message afterward to confirm recovery
- **Success criteria:** System handles error gracefully, recovers

**7. test_server_error_during_processing**
- Inject malformed transcript entry (invalid JSONL)
- Verify server logs error but continues running
- Verify app shows error state or times out gracefully
- Verify system recovers for next valid message
- **Success criteria:** Errors logged, system doesn't crash, recovery works

**8. test_empty_voice_input**
- Send empty string or whitespace-only message
- Verify server handles gracefully (logs, ignores, or errors appropriately)
- Verify app returns to idle state
- Verify system remains functional
- **Success criteria:** No crashes, clean state return

## Implementation Notes

### Test Execution
- Each test class inherits from `E2ETestBase`
- Reference existing test patterns for UI interactions from old `IntegrationTestBase`
- Use XCTest assertions with descriptive messages
- Mark tests with `@MainActor` for UI operations
- Average test duration: 10-20 seconds (server startup + execution)
- Total suite duration: ~2-3 minutes for 8 tests

### Mock Speech Recognition

Create test-only code in iOS app:

```swift
#if DEBUG
extension SpeechRecognitionManager {
    func injectMockSpeechResult(text: String) {
        // Trigger same code path as real recognition
        self.handleRecognitionResult(text: text)
    }
}
#endif
```

Called from UI test via app accessibility:
```swift
app.buttons["__test_inject_speech"].tap()
app.textFields["__test_speech_input"].typeText("Hello Claude")
```

Or via XCTest app launch arguments and notification listening.

### Server Configuration for Tests

Modify `ios_server.py` to accept test mode (optional, or use environment variables):
- Custom transcript path via `--transcript-path` argument
- Skip VSCode automation in test mode
- Log "READY" signal on startup

### File Organization

Reference existing tests for patterns:
- Connection helpers: from `ConnectionTests.swift`
- State waiting helpers: from `StateManagementTests.swift`
- UI interaction helpers: from `VoiceInputFlowTests.swift`

### CI/CD Integration

Tests can run in CI with:
- Xcode simulator (headless on macOS runners)
- GitHub Actions: `xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 15'`
- Run Python unit tests separately: `pytest voice_server/tests`

## Migration Plan

### Phase 1: Infrastructure Setup
1. Create `ClaudeVoiceE2ESupport/` directory
2. Implement `server_manager.py`
3. Implement `transcript_injector.py`
4. Create `E2ETestBase.swift` with basic server lifecycle management

### Phase 2: Happy Path Tests
1. Implement `E2EHappyPathTests.swift`
2. Test basic connection and conversation flow
3. Validate infrastructure works end-to-end

### Phase 3: Error Handling Tests
1. Implement `E2EConnectionTests.swift`
2. Implement `E2EErrorHandlingTests.swift`
3. Test edge cases and error scenarios

### Phase 4: Cleanup
1. Archive or delete old `ClaudeVoiceUITests` (ConnectionTests, etc.)
2. Remove `voice_server/integration_tests/test_server.py` (mock server)
3. Update documentation and README

## Success Metrics

- All 8 E2E tests pass consistently
- Test suite completes in under 5 minutes
- No orphaned server processes after test runs
- Clear error messages on test failures
- Tests catch real integration bugs (validate with intentional bug injection)

## Open Questions

None - design approved.

## References

- Existing test patterns: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/`
- Server implementation: `voice_server/ios_server.py`
- Python unit tests: `voice_server/tests/`
