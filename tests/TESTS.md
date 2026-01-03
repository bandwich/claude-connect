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
| Server Tests | ~67 | pytest | `voice_server/tests/` |
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
- WebSocket server initialization and message handling (`test_ios_server.py`, `test_message_handlers.py`)
- Transcript file monitoring and response extraction (`test_response_extraction.py`, `test_text_extraction.py`)
- TTS utilities and audio streaming (`test_tts_utils.py`)
- Session management (projects, sessions, history) (`test_session_manager.py`)
- Structured content parsing and models (`test_content_handler.py`, `test_content_models.py`)
- VSCode controller automation (`test_vscode_controller.py`)

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
- AudioPlayer: chunk receiving, playback state, callbacks
- WebSocketManager: connection state, JSON encoding, callbacks
- SpeechRecognizer: recording state, error handling
- Models: ConnectionState, VoiceState, Message, Project, Session
- State transitions and integration flows

---

## E2E Tests (XCUITest + Real Server)

**Location:** `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2E*.swift`

```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh
```

The E2E runner (`run_e2e_tests.sh`):
1. Starts the real `ios_server.py`
2. Creates a test transcript file
3. Runs E2E test suites
4. Cleans up server and files

**Test suites:**
- `E2EHappyPathTests` - Complete voice conversation flows
- `E2EConnectionTests` - Server connection and reconnection
- `E2EErrorHandlingTests` - Malformed messages, server errors
- `E2EProjectsListTests` - Projects list loading and display
- `E2ESessionsListTests` - Session navigation and counts
- `E2ESessionViewTests` - Message history and voice controls

**Support utilities:** `tests/e2e_support/`
- `server_manager.py` - Server lifecycle management
- `transcript_injector.py` - Mock message injection

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
