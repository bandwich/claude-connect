# Voice Mode Test Suite Reference

## Quick Start

### Using the Test Skill (Recommended)
```bash
# Run all tests
/test-voice-mode all

# Run specific test suites
/test-voice-mode unit          # iOS unit tests only
/test-voice-mode server        # Python server tests only
/test-voice-mode integration   # Full integration tests (simulator)
/test-voice-mode integration device  # Integration tests on physical iPhone
```

### Manual Testing
```bash
# Server tests
cd /Users/aaron/Desktop/max/voice_server/tests
./run_tests.sh

# iOS unit tests
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests
```

## Test Overview

**Total: 121+ tests across 3 suites**

| Suite | Count | Type | What It Tests |
|-------|-------|------|---------------|
| **Server Unit Tests** | 33 | pytest | WebSocket server, transcript handling, TTS utilities |
| **iOS Unit Tests** | 46 | XCTest | Individual components (mocked dependencies) |
| **iOS Integration Tests** | 42 | XCUITest | Full end-to-end flows with real server |

---

## 1. Server Unit Tests (33 tests)

**Location:** `voice_server/tests/`

### Files
- `test_ios_server.py` - 33 tests for WebSocket server
- `test_tts_utils.py` - TTS utilities (if present)

### What's Tested

**TestTranscriptHandler (11 tests):**
- Handler initialization
- Assistant message extraction (string content, list/block content)
- Message wrapper handling
- Mixed role filtering
- Short message filtering (< 3 chars)
- Multiple message handling
- File event filtering (non-.jsonl, directories)
- Duplicate message detection

**TestVoiceServer (19+ tests):**
- Server initialization
- Transcript path discovery
- Status message formatting
- VS Code AppleScript integration
- Audio streaming
- Audio chunk format validation
- Base64 encoding
- Voice input processing (valid, empty, status updates)
- Claude response handling (single/multiple clients)
- JSON parsing (valid/invalid)
- Message type handling
- Client connection/disconnection
- Extract message utilities

---

## 2. iOS Unit Tests (46 tests)

**Location:** `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/`

### Files
- `ClaudeVoiceTests.swift` - Core component tests
- `AudioPlayerTests.swift` - Audio playback tests
- `WebSocketManagerTests.swift` - WebSocket connection tests

### Test Categories

**Audio Player (6 tests):**
- Initial state
- Audio chunk receiving (valid/invalid base64)
- Playback state management
- Stop/reset clearing state
- Callback configuration

**WebSocket Manager (4 tests):**
- Initial state
- Connection state management
- Voice input JSON encoding
- Disconnect state reset
- Callback configuration

**Speech Recognizer (6 tests):**
- Initial state
- Recording state transitions
- Callback configuration
- Error type handling
- Stop when not recording

**State Management (12 tests):**
- Connection state equality/descriptions/errors
- Voice state raw values/descriptions/equality/transitions
- Service integration
- End-to-end flows

**Message Handling (6 tests):**
- Status message decoding (all states, invalid JSON)
- Audio chunk message decoding (base64 data, snake_case mapping, invalid JSON)
- Voice input message encoding/timestamps

**Integration Flows (12 tests):**
- Complete voice input flow
- Complete voice state flow
- Audio buffering with multiple chunks
- Recording state triggers listening
- Recording stopped returns to idle
- Recording stopped doesn't override processing
- Speech recognizer to WebSocket integration
- WebSocket to audio player integration
- State transitions between recording/playback
- Disconnect during flow
- Multiple rapid voice inputs

---

## 3. iOS Integration Tests (42 tests)

**Location:** `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/`

**Requires:** Test server running (`voice_server/integration_tests/test_server.py`)

### Test Suites

**StateManagementTests (7 tests):**
- Full voice state lifecycle (Idle → Speaking → Idle)
- Connection state resilience (disconnect/reconnect)
- UI state synchronization with server
- Concurrent state updates
- Server restart scenarios
- Talk button disabled during playback
- **🔥 Race condition test:** Server "idle" ignored while audio playing

**AudioStreamingTests (7 tests):**
- Real WebSocket audio chunk streaming
- Base64 decoding of actual audio data
- Audio buffering behavior (3+ chunks before playback)
- Playback continuity across chunks
- Chunk ordering validation
- Incomplete chunk sequence handling
- Large audio response handling

**ConnectionTests (4 tests):**
- Initial connection flow with handshake
- Invalid IP/port handling
- Multiple connection attempts
- Server startup and discovery

**ErrorHandlingTests (8 tests):**
- Malformed JSON from server
- Corrupted audio chunks
- Missing chunk fields
- Network latency simulation
- Server disconnect during audio
- Server overload scenarios
- Unknown message types
- Status messages during connection

**VoiceInputFlowTests (5 tests):**
- Complete voice input → server → response flow
- Voice input delivery over WebSocket
- Empty voice input handling
- Long voice messages
- Status update triggers

**TranscriptMonitoringTests (4 tests):**
- Real filesystem watching
- Assistant message extraction from transcript files
- Duplicate message prevention
- Multi-role transcript parsing

**PerformanceTests (3 tests):**
- End-to-end latency measurements
- Audio streaming latency
- Multiple sequential interactions

**Other (4 tests):**
- Launch tests
- UI element debugging
- Example tests

### Critical Race Condition Test

**`StateManagementTests::testServerIdleIgnoredDuringPlayback`**

This test validates the fix for the race condition where:
1. Server sends all audio chunks
2. Server immediately sends "idle" status
3. iOS device still has buffered chunks playing

**Expected behavior:** App should IGNORE premature "idle" and stay in "Speaking" state until audio actually finishes playing (via `onPlaybackFinished` callback).

**Test implementation:**
- Triggers audio playback
- Waits for "Speaking" state
- Manually injects "idle" status while audio is playing
- Asserts app STAYS in "Speaking" (race protection working)
- Waits for legitimate transition to "Idle" after playback finishes

---

## Running Specific Tests

### Server Tests
```bash
source /Users/aaron/Desktop/max/.venv/bin/activate
cd /Users/aaron/Desktop/max/voice_server/tests

# Run all server tests
pytest -v

# Run specific file
pytest test_ios_server.py -v

# Run specific class
pytest test_ios_server.py::TestVoiceServer -v

# Run specific test
pytest test_ios_server.py::TestVoiceServer::test_send_status -v

# With coverage
./run_tests.sh coverage
```

### iOS Unit Tests
```bash
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice

# Run all unit tests
xcodebuild test \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests

# Run specific test class
xcodebuild test \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/AudioPlayerTests
```

### iOS Integration Tests
```bash
# Start test server (required!)
/Users/aaron/Desktop/max/.venv/bin/python3 \
  /Users/aaron/Desktop/max/voice_server/integration_tests/test_server.py

# In another terminal, run integration tests
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice

xcodebuild test \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceUITests

# Run specific integration test
xcodebuild test \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceUITests/StateManagementTests/testServerIdleIgnoredDuringPlayback
```

---

## Test Infrastructure

### Test Server
**Location:** `voice_server/integration_tests/test_server.py`

Features:
- Mock WebSocket server for integration tests
- HTTP control interface for test orchestration
- Mock transcript file monitoring
- Configurable audio streaming
- Status injection endpoints

**Endpoints:**
- `POST /inject_response` - Inject mock Claude response
- `POST /inject_status` - Send status message to clients
- `GET /logs` - Retrieve server logs
- `POST /clear_logs` - Clear server logs
- `POST /reset` - Reset server state

### Test Skill
**Location:** `.claude/skills/test-voice-mode/run.sh`

Unified test runner with:
- Automated test server lifecycle management
- Process monitoring and cleanup
- Crash detection
- Log aggregation
- Support for simulator and physical device testing

---

## What's Tested vs Not Tested

### ✅ Tested
- WebSocket connection management
- Audio streaming and chunking
- Voice input handling
- State management and transitions
- Race condition protection (idle during playback)
- Error handling and recovery
- Transcript file monitoring
- Multi-client broadcasting
- UI state synchronization

### ⚠️ Not Fully Tested
- Real speech recognition (mocked in tests)
- Real TTS generation (uses pre-generated audio)
- VS Code AppleScript integration (mocked)
- Network interruption recovery
- Background app behavior
- Memory pressure scenarios

---

## Dependencies

### Server Tests
```bash
pip install pytest pytest-asyncio pytest-mock
```

Or:
```bash
pip install -r voice_server/tests/requirements-test.txt
```

### iOS Tests
- Xcode 15+
- iOS 17+ Simulator or Device
- iPhone 16 simulator recommended

---

## Troubleshooting

### Integration Tests Fail to Connect
1. Verify test server is running and shows "READY"
2. Check server logs: `tail -f /tmp/test_server.log`
3. Verify host/port match (127.0.0.1:8765 for simulator)
4. For device testing, update Mac IP in test configuration

### Tests Hang or Timeout
1. Check for crashed app instances: `ps aux | grep ClaudeVoice`
2. Check crash logs: `~/Library/Logs/DiagnosticReports/ClaudeVoice*.ips`
3. Reset simulator: `xcrun simctl shutdown all`
4. Kill lingering processes: `pkill -f ClaudeVoice`

### Server Tests Fail
1. Verify virtual environment is activated
2. Check Python version (3.9+)
3. Reinstall dependencies: `pip install -r requirements-test.txt`
4. Clear pytest cache: `rm -rf .pytest_cache`
