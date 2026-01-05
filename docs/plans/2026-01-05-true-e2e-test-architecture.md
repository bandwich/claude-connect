# True E2E Test Architecture

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Problem:** Current E2E tests bypass VSCode terminal submission entirely. Tests inject messages directly into the transcript file, so bugs like `\n` vs `\r` go undetected.

**Current flow (broken):**
```
Voice Input → Server → [VSCode - UNTESTED] → Tests inject transcript → App
```

**Desired flow (true E2E):**
```
Voice Input → Server → Real VSCode → Real Terminal → Transcript → App
```

**Key insight:** If VSCode connection breaks, ALL conversation tests should fail immediately.

---

## Architecture

### Requirements

1. **Real VSCode** running with vscode-remote-control extension
2. **Real terminal** in VSCode with something that processes commands
3. **No mock servers** - use actual components

### Test Prerequisites

Before running E2E tests:
- VSCode must be open
- vscode-remote-control extension must be active (ws://localhost:3710)
- A terminal must be open with Claude CLI or test responder script

### Test Flow Changes

**Before (bypasses VSCode):**
```swift
func simulateConversationTurn(userInput: String, assistantResponse: String) {
    sendVoiceInput(userInput)        // Send to server
    injectUserMessage(userInput)      // BYPASS: directly inject
    injectAssistantMessage(response)  // BYPASS: directly inject
}
```

**After (real E2E):**
```swift
func sendVoiceInput(_ text: String) {
    // Send to server via WebSocket
    // Server sends to real VSCode terminal
    // Terminal processes command
    // Response written to transcript
    // App detects transcript change
    // NO INJECTION
}
```

---

## Affected Tests

ALL tests using `simulateConversationTurn` or `injectUserMessage`/`injectAssistantMessage`:

| Test File | Uses Injection | Needs Update |
|-----------|----------------|--------------|
| E2EHappyPathTests | Yes | Yes |
| E2ESessionViewTests | Yes | Yes |
| E2EConnectionTests | Yes | Yes |
| E2EErrorHandlingTests | Yes | Yes |
| E2EPermissionTests | No (uses HTTP) | No |
| E2EProjectsListTests | No | No |
| E2ESessionsListTests | No | No |
| E2EVSCodeConnectionTests | No | No |

---

## Part 1: Create Test Responder Script

### Task 1: Create a simple script that responds to commands in terminal

For E2E tests, we need something in the VSCode terminal that:
1. Reads commands from stdin
2. Writes responses to the transcript file

**Files:**
- Create: `tests/e2e_support/test_responder.py`

```python
#!/usr/bin/env python3
"""
Simple responder for E2E tests.
Reads lines from stdin, writes mock responses to transcript.
Run this in VSCode terminal during E2E tests.
"""
import sys
import json
import time
import os

def main():
    transcript_path = os.environ.get("E2E_TRANSCRIPT_PATH")
    if not transcript_path:
        print("E2E_TRANSCRIPT_PATH not set", file=sys.stderr)
        sys.exit(1)

    print(f"Test responder ready. Transcript: {transcript_path}")

    for line in sys.stdin:
        text = line.strip()
        if not text:
            continue

        print(f"Received: {text}")

        # Write to transcript
        user_msg = {
            "type": "user",
            "message": {"content": text},
            "timestamp": time.time()
        }
        assistant_msg = {
            "type": "assistant",
            "message": {"content": f"Test response to: {text}"},
            "timestamp": time.time() + 0.1
        }

        with open(transcript_path, "a") as f:
            f.write(json.dumps(user_msg) + "\n")
            f.write(json.dumps(assistant_msg) + "\n")

        print(f"Wrote response to transcript")

if __name__ == "__main__":
    main()
```

---

## Part 2: Update E2E Test Runner

### Task 2: Update run_e2e_tests.sh to verify VSCode is ready

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/run_e2e_tests.sh`

Add check before running tests:
```bash
# Verify VSCode extension is running
echo "🔍 Checking VSCode remote-control extension..."
if ! nc -z localhost 3710 2>/dev/null; then
    echo "❌ VSCode remote-control extension not running on port 3710"
    echo "   Please:"
    echo "   1. Open VSCode"
    echo "   2. Install/enable vscode-remote-control extension"
    echo "   3. Open a terminal and run: E2E_TRANSCRIPT_PATH=$E2E_TRANSCRIPT_PATH python3 tests/e2e_support/test_responder.py"
    exit 1
fi
echo "✅ VSCode extension detected"
```

---

## Part 3: Remove Transcript Injection

### Task 3: Update E2ETestBase to remove injection helpers

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift`

1. Remove `simulateConversationTurn` method
2. Remove `injectUserMessage` method
3. Remove `injectAssistantMessage` method
4. Keep `sendVoiceInput` - this is the real E2E method

### Task 4: Update E2EHappyPathTests

Replace injection with real flow:
```swift
func test_voice_conversation_flow() throws {
    navigateToTestSession()
    XCTAssertTrue(waitForVoiceState("Idle", timeout: 5))

    // Real E2E: send voice, wait for response via VSCode → transcript → app
    sendVoiceInput("Hello Claude")
    XCTAssertTrue(waitForVoiceState("Speaking", timeout: 15), "Should receive response")
    XCTAssertTrue(waitForVoiceState("Idle", timeout: 15), "Should return to idle")

    sendVoiceInput("Second message")
    XCTAssertTrue(waitForVoiceState("Speaking", timeout: 15))
    XCTAssertTrue(waitForVoiceState("Idle", timeout: 15))
}
```

### Task 5: Update E2ESessionViewTests

### Task 6: Update E2EConnectionTests

### Task 7: Update E2EErrorHandlingTests

---

## Part 4: Verify Architecture

### Task 8: Test that VSCode failures cause test failures

1. Stop VSCode or kill the extension
2. Run any conversation test
3. Verify it fails (not passes with false confidence)

---

## Summary

### What Changes

| Component | Before | After |
|-----------|--------|-------|
| VSCode | Optional/bypassed | Required |
| Transcript injection | Used everywhere | Removed |
| Test prerequisites | Just server | Server + VSCode + responder |

### Test Coverage

- ✅ Voice input → Server WebSocket
- ✅ Server → VSCode terminal send
- ✅ Terminal command submission (Enter key)
- ✅ Terminal → Transcript write
- ✅ Transcript file watching
- ✅ App UI response

### Key Benefit

If ANY part of the VSCode integration breaks, conversation tests fail immediately.
