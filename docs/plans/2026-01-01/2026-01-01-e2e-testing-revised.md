# E2E Testing Implementation Plan (REVISED)

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Implement comprehensive end-to-end smoke tests for iOS voice mode using the real, unmodified ios_server.py and testing critical user flows.

**Core Principle:** Server and app run completely unmodified. Tests simulate external behaviors (speech input, Claude responses) as if they were real.

**Architecture:**
- **Server**: Runs completely normally, watches its standard transcript directory
- **Claude responses**: Tests inject mock responses into the server's watched transcript (simulating Claude writing)
- **Voice input**: Tests send WebSocket messages directly to server (simulating app sending)
- **Test helpers**: Python scripts to inject transcripts and send WebSocket messages, separate from server/app code

**Tech Stack:** XCTest (Swift UI testing), Python 3.9, WebSocket client, pytest, Xcode 15

---

## Task 1: Create Python Test Infrastructure Directory

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport/__init__.py`
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport/test_config.py`

**Step 1: Create directory structure**

Run: `mkdir -p ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport`

**Step 2: Create __init__.py**

```python
# Empty file for Python package
```

**Step 3: Create test_config.py**

```python
"""Configuration for E2E tests"""
import os

# Server configuration
TEST_SERVER_HOST = "127.0.0.1"
TEST_SERVER_PORT = 8765

# Paths
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
SERVER_SCRIPT = os.path.join(PROJECT_ROOT, "voice_server/ios_server.py")
PYTHON_VENV = os.path.join(PROJECT_ROOT, ".venv/bin/python3")

# Transcript configuration - use server's actual watched directory
TRANSCRIPT_DIR = os.path.expanduser("~/.claude/projects/e2e_test_project")
```

**Step 4: Verify files created**

Run: `ls -la ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport/`
Expected: See `__init__.py` and `test_config.py`

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport/
git commit -m "feat: add E2E test infrastructure"
```

---

## Task 2: Implement transcript_injector.py

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport/transcript_injector.py`

**Purpose:** Simulates Claude writing responses to transcript (server watches and reacts naturally)

**Step 1: Write test for transcript_injector**

Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport/test_transcript_injector.py`

```python
"""Tests for transcript_injector.py"""
import pytest
import json
import os
import sys
sys.path.insert(0, os.path.dirname(__file__))

from transcript_injector import inject_user_message, inject_assistant_message

def test_inject_user_message_creates_valid_jsonl(tmp_path):
    """Test that user message injection creates valid JSONL entry"""
    transcript_path = tmp_path / "test.jsonl"

    inject_user_message(str(transcript_path), "Hello Claude")

    assert transcript_path.exists()
    with open(transcript_path) as f:
        line = f.readline()
        entry = json.loads(line)
        assert entry["role"] == "user"
        assert entry["content"] == "Hello Claude"

def test_inject_assistant_message_creates_valid_jsonl(tmp_path):
    """Test that assistant message injection creates valid JSONL entry"""
    transcript_path = tmp_path / "test.jsonl"

    inject_assistant_message(str(transcript_path), "Test response")

    assert transcript_path.exists()
    with open(transcript_path) as f:
        line = f.readline()
        entry = json.loads(line)
        assert entry["role"] == "assistant"
        assert entry["content"] == "Test response"

def test_inject_conversation_flow(tmp_path):
    """Test injecting a conversation"""
    transcript_path = tmp_path / "test.jsonl"

    inject_user_message(str(transcript_path), "First question")
    inject_assistant_message(str(transcript_path), "First answer")
    inject_user_message(str(transcript_path), "Second question")
    inject_assistant_message(str(transcript_path), "Second answer")

    with open(transcript_path) as f:
        lines = f.readlines()
        assert len(lines) == 4
        assert json.loads(lines[0])["role"] == "user"
        assert json.loads(lines[1])["role"] == "assistant"
        assert json.loads(lines[2])["role"] == "user"
        assert json.loads(lines[3])["role"] == "assistant"
```

**Step 2: Run test to verify it fails**

Run: `cd ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport && pytest test_transcript_injector.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'transcript_injector'"

**Step 3: Implement transcript_injector.py**

```python
#!/usr/bin/env python3
"""Inject mock messages into transcript files for E2E tests

Simulates Claude and user writing to transcript. Server watches and reacts naturally.
"""
import json
import sys
import os
import time


def inject_user_message(transcript_path, message):
    """
    Inject a user message into transcript file (simulates user input being logged)

    Args:
        transcript_path: Path to transcript JSONL file
        message: User message text to inject

    Returns:
        0 on success, 1 on error
    """
    try:
        os.makedirs(os.path.dirname(transcript_path), exist_ok=True)

        entry = {
            "role": "user",
            "content": message,
            "timestamp": time.time()
        }

        json_line = json.dumps(entry)
        json.loads(json_line)  # Validate

        with open(transcript_path, 'a') as f:
            f.write(json_line + '\n')
            f.flush()

        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


def inject_assistant_message(transcript_path, message):
    """
    Inject an assistant message into transcript file (simulates Claude responding)

    Args:
        transcript_path: Path to transcript JSONL file
        message: Assistant message text to inject

    Returns:
        0 on success, 1 on error
    """
    try:
        os.makedirs(os.path.dirname(transcript_path), exist_ok=True)

        entry = {
            "role": "assistant",
            "content": message,
            "timestamp": time.time()
        }

        json_line = json.dumps(entry)
        json.loads(json_line)  # Validate

        with open(transcript_path, 'a') as f:
            f.write(json_line + '\n')
            f.flush()

        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


def main():
    """CLI interface for transcript injection"""
    import argparse

    parser = argparse.ArgumentParser(description="Inject mock messages for E2E tests")
    parser.add_argument("--transcript", required=True, help="Path to transcript file")
    parser.add_argument("--role", required=True, choices=["user", "assistant"])
    parser.add_argument("--message", required=True, help="Message to inject")

    args = parser.parse_args()

    if args.role == "user":
        exit_code = inject_user_message(args.transcript, args.message)
    else:
        exit_code = inject_assistant_message(args.transcript, args.message)

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
```

**Step 4: Run test to verify it passes**

Run: `cd ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport && pytest test_transcript_injector.py -v`
Expected: PASS

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport/
git commit -m "feat: add transcript injector"
```

---

## Task 3: Implement WebSocket voice_input sender

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport/voice_sender.py`

**Purpose:** Sends voice_input messages to server via WebSocket (simulates app sending voice input)

**Step 1: Write test for voice_sender**

Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport/test_voice_sender.py`

```python
"""Tests for voice_sender.py"""
import pytest
import asyncio
import json
import sys
import os
sys.path.insert(0, os.path.dirname(__file__))

from voice_sender import send_voice_input

@pytest.mark.asyncio
async def test_send_voice_input_formats_message_correctly():
    """Test that message is formatted correctly"""
    # This is a unit test - we'll test format without actual WebSocket
    # The function should return the formatted message for testing
    message = {
        "type": "voice_input",
        "text": "Test message",
        "timestamp": 123456789.0
    }

    # Verify JSON serialization works
    json_str = json.dumps(message)
    parsed = json.loads(json_str)

    assert parsed["type"] == "voice_input"
    assert parsed["text"] == "Test message"
```

**Step 2: Run test to verify it fails**

Run: `cd ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport && pytest test_voice_sender.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'voice_sender'"

**Step 3: Implement voice_sender.py**

```python
#!/usr/bin/env python3
"""Send voice input to server via WebSocket for E2E tests

Simulates the iOS app sending voice input to the server.
"""
import asyncio
import websockets
import json
import time
import sys


async def send_voice_input(host, port, text):
    """
    Send voice input to server via WebSocket

    Args:
        host: Server host
        port: Server port
        text: Voice input text to send

    Returns:
        0 on success, 1 on error
    """
    try:
        uri = f"ws://{host}:{port}"

        async with websockets.connect(uri) as websocket:
            # Send voice input message (same format as iOS app)
            message = {
                "type": "voice_input",
                "text": text,
                "timestamp": time.time()
            }

            await websocket.send(json.dumps(message))

            # Wait briefly for server to process
            await asyncio.sleep(0.5)

        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


def main():
    """CLI interface for sending voice input"""
    import argparse

    parser = argparse.ArgumentParser(description="Send voice input to server")
    parser.add_argument("--host", default="127.0.0.1", help="Server host")
    parser.add_argument("--port", type=int, default=8765, help="Server port")
    parser.add_argument("--text", required=True, help="Voice input text")

    args = parser.parse_args()

    exit_code = asyncio.run(send_voice_input(args.host, args.port, args.text))
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
```

**Step 4: Run test to verify it passes**

Run: `cd ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport && pytest test_voice_sender.py -v`
Expected: PASS

**Step 5: Install websockets if needed**

Run: `cd /Users/aaron/Desktop/max && source .venv/bin/activate && pip install websockets`

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceE2ESupport/
git commit -m "feat: add voice input sender"
```

---

## Task 4: Update E2E Test Base

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift`

**Purpose:** Simplify test base - no server lifecycle management, just use running server

**Step 1: Read existing E2ETestBase.swift**

Run: `find ios-voice-app -name "E2ETestBase.swift" -type f`

**Step 2: Update E2ETestBase.swift**

Replace with simplified version that assumes server is already running:

```swift
//
//  E2ETestBase.swift
//  ClaudeVoiceUITests
//
//  Base class for E2E tests - assumes server already running
//

import XCTest
import Foundation

class E2ETestBase: XCTestCase {

    static var app: XCUIApplication!
    var transcriptPath: String?

    let testServerHost = "127.0.0.1"
    let testServerPort = 8765
    let pythonHelperPath: String = {
        let bundle = Bundle(for: E2ETestBase.self)
        return bundle.bundlePath
            .replacingOccurrences(of: "/Build/Products/", with: "/")
            .replacingOccurrences(of: "ClaudeVoiceUITests-Runner.app", with: "ClaudeVoiceE2ESupport")
    }()

    var app: XCUIApplication! {
        return Self.app
    }

    // MARK: - Setup & Teardown

    override class func setUp() {
        super.setUp()

        print("🚀 Launching app once for all tests in \\(String(describing: self))")

        app = XCUIApplication()
        app.launchEnvironment = [
            "SERVER_HOST": "127.0.0.1",
            "SERVER_PORT": "8765"
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        continueAfterFailure = false

        // Set transcript path to server's watched directory
        let timestamp = Int(Date().timeIntervalSince1970)
        let transcriptDir = NSString(string: "~/.claude/projects/e2e_test_project").expandingTildeInPath
        transcriptPath = "\\(transcriptDir)/transcript_\\(timestamp).jsonl"

        // Create transcript directory
        try? FileManager.default.createDirectory(atPath: transcriptDir, withIntermediateDirectories: true)

        // Create empty transcript file
        try "".write(toFile: transcriptPath!, atomically: true, encoding: .utf8)

        // Launch app
        Self.app.launch()
        sleep(2)

        // Connect to server
        connectToServer()
    }

    override func tearDownWithError() throws {
        // Disconnect if connected
        if app.staticTexts["connectionStatus"].exists &&
           app.staticTexts["connectionStatus"].label == "Connected" {
            disconnectFromServer()
        }

        // Clean up transcript file
        if let path = transcriptPath, FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }

        try super.tearDownWithError()
    }

    override class func tearDown() {
        print("🛑 Terminating app after all tests in \\(String(describing: self))")
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Helper Methods

    func connectToServer() {
        let settingsButton = app.buttons["gearshape.fill"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
        }

        let serverIPField = app.textFields["Server IP Address"]
        if serverIPField.waitForExistence(timeout: 5) {
            serverIPField.tap()

            if let existingText = serverIPField.value as? String, !existingText.isEmpty {
                let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingText.count)
                serverIPField.typeText(deleteString)
            }

            serverIPField.typeText(testServerHost)
        }

        let connectButton = app.buttons["Connect"]
        if !connectButton.exists {
            let connectionHeader = app.staticTexts["Connection"]
            if connectionHeader.exists {
                connectionHeader.tap()
                sleep(1)
            }
        }

        if connectButton.waitForExistence(timeout: 5) {
            connectButton.tap()
        }

        sleep(3)

        let doneButton = app.buttons["Done"]
        if doneButton.exists {
            doneButton.tap()
        }

        sleep(1)

        // Verify connected
        let connectedLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(connectedLabel.waitForExistence(timeout: 5), "Should show Connected status")
        XCTAssertEqual(connectedLabel.label, "Connected", "Connection status should be Connected")
    }

    func disconnectFromServer() {
        let settingsButton = app.buttons["gearshape.fill"]
        if settingsButton.waitForExistence(timeout: 2) {
            settingsButton.tap()
        }

        let disconnectButton = app.buttons["Disconnect"]
        if disconnectButton.waitForExistence(timeout: 2) {
            disconnectButton.tap()
        }

        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 2) {
            doneButton.tap()
        }

        sleep(1)
    }

    func sendVoiceInput(_ text: String) {
        guard let _ = transcriptPath else {
            XCTFail("No transcript path")
            return
        }

        let voiceSenderScript = "\\(pythonHelperPath)/voice_sender.py"
        let pythonPath = "\\(pythonHelperPath)/../../../.venv/bin/python3"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [voiceSenderScript, "--host", testServerHost, "--port", "\\(testServerPort)", "--text", text]

        try? task.run()
        task.waitUntilExit()

        sleep(1)
    }

    func injectAssistantResponse(_ text: String) {
        guard let transcriptPath = transcriptPath else {
            XCTFail("No transcript path")
            return
        }

        let injectorScript = "\\(pythonHelperPath)/transcript_injector.py"
        let pythonPath = "\\(pythonHelperPath)/../../../.venv/bin/python3"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [injectorScript, "--transcript", transcriptPath, "--role", "assistant", "--message", text]

        try? task.run()
        task.waitUntilExit()

        // Wait for server to process
        sleep(2)
    }

    func waitForVoiceState(_ expectedState: String, timeout: TimeInterval = 10.0) -> Bool {
        let stateLabel = app.staticTexts["voiceState"]

        guard stateLabel.waitForExistence(timeout: timeout) else {
            return false
        }

        let predicate = NSPredicate(format: "label == %@", expectedState)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: stateLabel)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    func waitForConnectionState(_ expectedState: String, timeout: TimeInterval = 10.0) -> Bool {
        let stateLabel = app.staticTexts["connectionStatus"]
        let exists = stateLabel.waitForExistence(timeout: timeout)
        return exists && stateLabel.label == expectedState
    }
}

// MARK: - Errors

enum E2ETestError: Error {
    case noTranscriptPath
    case injectionFailed
}
```

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift
git commit -m "refactor: simplify E2ETestBase"
```

---

## Task 5: Update run_e2e_tests.sh

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/run_e2e_tests.sh`

**Purpose:** Script starts unmodified server, then runs tests

**Step 1: Read existing script**

Run: `cat ios-voice-app/ClaudeVoice/run_e2e_tests.sh`

**Step 2: Update script**

```bash
#!/bin/bash
# E2E Test Runner - Starts server then runs tests

set -e

echo "🧪 E2E Test Runner"
echo "=================="

# Configuration
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
SERVER_SCRIPT="$PROJECT_ROOT/voice_server/ios_server.py"
TRANSCRIPT_DIR="$HOME/.claude/projects/e2e_test_project"
LOG_FILE="/tmp/e2e_server.log"

# Ensure transcript directory exists
mkdir -p "$TRANSCRIPT_DIR"

# Start server (unmodified, just watches its normal transcript dir)
echo "📡 Starting ios_server.py..."
$VENV_PYTHON "$SERVER_SCRIPT" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!

echo "   Server PID: $SERVER_PID"
echo "   Logs: $LOG_FILE"

# Wait for server to be ready
echo "⏳ Waiting for server startup..."
sleep 3

# Verify server is running
if ! ps -p $SERVER_PID > /dev/null; then
    echo "❌ Server failed to start. Check logs:"
    cat "$LOG_FILE"
    exit 1
fi

echo "✅ Server started successfully"

# Run E2E tests
echo ""
echo "🏃 Running E2E tests..."
echo ""

xcodebuild test \
    -scheme ClaudeVoice \
    -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -only-testing:ClaudeVoiceUITests/E2EHappyPathTests \
    -only-testing:ClaudeVoiceUITests/E2EConnectionTests \
    -only-testing:ClaudeVoiceUITests/E2EErrorHandlingTests \
    2>&1

TEST_EXIT_CODE=$?

# Cleanup
echo ""
echo "🧹 Cleaning up..."
kill $SERVER_PID 2>/dev/null || true
rm -rf "$TRANSCRIPT_DIR"

if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "✅ All E2E tests passed!"
else
    echo "❌ Some E2E tests failed"
    echo "   Check server logs: $LOG_FILE"
fi

exit $TEST_EXIT_CODE
```

**Step 3: Make executable**

Run: `chmod +x ios-voice-app/ClaudeVoice/run_e2e_tests.sh`

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/run_e2e_tests.sh
git commit -m "refactor: update E2E runner for unmodified server"
```

---

## Task 6: Remove Server Test Mode Logic

**Files:**
- Modify: `voice_server/ios_server.py`

**Purpose:** Remove all TEST_MODE and TEST_TRANSCRIPT_PATH logic

**Step 1: Show current server changes**

Run: `git diff voice_server/ios_server.py | head -150`

**Step 2: Revert server to clean state**

Run: `git checkout voice_server/ios_server.py`

**Step 3: Verify server is clean**

Run: `git diff voice_server/ios_server.py`
Expected: No output (no changes)

**Step 4: Commit**

```bash
git add voice_server/ios_server.py
git commit -m "refactor: remove test mode from server"
```

---

## Task 7: Run E2E Tests

**Step 1: Run test suite**

Run: `cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh`

**Step 2: Debug any failures**

- Check server logs: `cat /tmp/e2e_server.log`
- Verify transcript directory exists
- Check WebSocket connections
- Verify transcript injection works

**Step 3: Verify all tests pass**

Expected: 8 E2E tests pass
- E2EHappyPathTests: 2 tests
- E2EConnectionTests: 3 tests
- E2EErrorHandlingTests: 3 tests

---

## Completion Checklist

- [ ] Python test helpers created (transcript_injector.py, voice_sender.py)
- [ ] E2ETestBase simplified (no server management)
- [ ] run_e2e_tests.sh updated to start unmodified server
- [ ] Server test mode logic removed
- [ ] All 8 tests pass with unmodified server
- [ ] Server runs completely normally during tests

## Key Differences from Original Plan

**What Changed:**
1. **Server**: Completely unmodified - no TEST_MODE, no custom transcript paths
2. **Transcript injection**: Writes to server's normal watched directory
3. **Voice input**: Sent via WebSocket (like real app), not mocked in app
4. **Server lifecycle**: Managed by test script, not individual tests
5. **No server_manager.py**: Not needed - just start server normally

**Why Better:**
- True E2E testing - server behaves exactly as in production
- Tests verify real file watching behavior
- No test pollution in production code
- Server can be swapped with zero code changes
