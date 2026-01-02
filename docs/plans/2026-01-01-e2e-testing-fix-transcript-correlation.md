# E2E Testing Fix: Transcript Correlation

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Date:** 2026-01-01
**Status:** Ready for implementation
**Previous Plan:** `2026-01-01-e2e-testing-revised.md` (partially implemented)

## Problem Statement

E2E tests compile and run but 5/8 tests fail due to transcript correlation issues.

**Root Cause:**
The server requires **both user message + assistant response** in the transcript to extract new content blocks. Tests currently:
1. ✅ Send voice input via WebSocket → server stores in `last_voice_input`
2. ❌ Only inject assistant response to transcript
3. ❌ Server can't find matching user message → fails to extract blocks

**Evidence:** `ios_server.py:65-70, 105-138` - server searches for user message in transcript before extracting assistant response.

## Current Test Results

**Passing (3/8):**
- ✅ `test_initial_connection_to_real_server`
- ✅ `test_connection_failure_handling`
- ✅ `test_server_error_during_processing`

**Failing (5/8):**
- ❌ `test_complete_voice_conversation_flow`
- ❌ `test_multiple_conversation_turns`
- ❌ `test_empty_voice_input`
- ❌ `test_malformed_message_handling`
- ❌ `test_reconnection_after_disconnect`

All failures related to voice input → transcript → audio playback flow.

## Solution

Update `E2ETestBase.swift` to inject **both** user message and assistant response into transcript, matching production behavior.

---

## Task 1: Add Helper to Inject User Messages

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift`

**Purpose:** Create reusable helper to inject user messages into transcript

**Step 1: Add `injectUserMessage()` helper**

Add this method after `injectAssistantResponse()`:

```swift
func injectUserMessage(_ text: String) {
    // Inject user message into transcript file (Swift implementation, iOS-compatible)
    guard let transcriptPath = transcriptPath else {
        XCTFail("No transcript path")
        return
    }

    let entry: [String: Any] = [
        "role": "user",
        "content": text,
        "timestamp": Date().timeIntervalSince1970
    ]

    do {
        let jsonData = try JSONSerialization.data(withJSONObject: entry)
        guard let jsonString = String(data: jsonData, encoding: .utf8) else {
            XCTFail("Failed to encode JSON")
            return
        }

        let fileHandle = FileHandle(forWritingAtPath: transcriptPath)
        if let handle = fileHandle {
            handle.seekToEndOfFile()
            handle.write((jsonString + "\n").data(using: .utf8)!)
            handle.closeFile()
        } else {
            // File doesn't exist, create it
            try (jsonString + "\n").write(toFile: transcriptPath, atomically: true, encoding: .utf8)
        }
    } catch {
        XCTFail("Failed to inject user message: \(error)")
    }

    // Small delay for file system
    usleep(100000) // 100ms
}
```

**Step 2: Verify it compiles**

Run: `xcodebuild build -scheme ClaudeVoice -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceUITests`

Expected: Build succeeds

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift
git commit -m "feat: add injectUserMessage helper"
```

---

## Task 2: Update Helper to Inject Complete Conversations

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift`

**Purpose:** Create unified helper that simulates complete conversation turn

**Step 1: Add `simulateConversationTurn()` helper**

Add this method after `injectUserMessage()`:

```swift
func simulateConversationTurn(userInput: String, assistantResponse: String) {
    // Simulate a complete conversation turn:
    // 1. Send voice input via WebSocket (real)
    // 2. Inject user message to transcript (simulates Claude logging it)
    // 3. Inject assistant response to transcript (simulates Claude responding)

    print("📝 Simulating conversation turn: '\(userInput)' -> '\(assistantResponse)'")

    // Send voice input via WebSocket
    sendVoiceInput(userInput)

    // Wait briefly for server to process WebSocket message
    usleep(500000) // 500ms

    // Inject user message to transcript
    injectUserMessage(userInput)

    // Wait for file watcher to detect
    usleep(200000) // 200ms

    // Inject assistant response
    injectAssistantResponse(assistantResponse)

    // Wait for server to process and send to app
    sleep(1)
}
```

**Step 2: Verify it compiles**

Run: `xcodebuild build -scheme ClaudeVoice -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceUITests`

Expected: Build succeeds

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift
git commit -m "feat: add simulateConversationTurn helper"
```

---

## Task 3: Update Happy Path Tests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EHappyPathTests.swift`

**Purpose:** Use new helper that injects both user + assistant messages

**Step 1: Update `test_complete_voice_conversation_flow`**

Replace:
```swift
// Send voice input (mocked)
sendVoiceInput("Hello Claude")

// Inject assistant response
injectAssistantResponse("Hi! How can I help you today?")
```

With:
```swift
// Simulate complete conversation turn
simulateConversationTurn(
    userInput: "Hello Claude",
    assistantResponse: "Hi! How can I help you today?"
)
```

**Step 2: Update `test_multiple_conversation_turns`**

Replace each pair of:
```swift
sendVoiceInput("First message")
injectAssistantResponse("Response one")
```

With:
```swift
simulateConversationTurn(userInput: "First message", assistantResponse: "Response one")
```

Do this for all three turns.

**Step 3: Verify tests compile**

Run: `xcodebuild build -scheme ClaudeVoice -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceUITests/E2EHappyPathTests`

Expected: Build succeeds

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EHappyPathTests.swift
git commit -m "fix: use simulateConversationTurn in happy path tests"
```

---

## Task 4: Update Error Handling Tests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EErrorHandlingTests.swift`

**Purpose:** Fix tests to inject both user + assistant messages

**Step 1: Update `test_malformed_message_handling`**

Replace:
```swift
// Send valid message first
injectAssistantResponse("Valid message")
```

With:
```swift
// Send valid conversation turn first
simulateConversationTurn(userInput: "Test message", assistantResponse: "Valid message")
```

And:
```swift
// Send another valid message
injectAssistantResponse("Another valid message")
```

With:
```swift
// Send another valid conversation turn
simulateConversationTurn(userInput: "Another test", assistantResponse: "Another valid message")
```

**Step 2: Update `test_server_error_during_processing`**

Replace:
```swift
injectAssistantResponse(longText)
```

With:
```swift
simulateConversationTurn(userInput: "Send long response", assistantResponse: longText)
```

And:
```swift
injectAssistantResponse("Normal message")
```

With:
```swift
simulateConversationTurn(userInput: "Send normal response", assistantResponse: "Normal message")
```

**Step 3: Update `test_empty_voice_input`**

This test sends empty voice input, which is a special case. Keep the `sendVoiceInput("")` but update the recovery:

Replace:
```swift
// Should still be functional
injectAssistantResponse("Test after empty input")
```

With:
```swift
// Should still be functional
simulateConversationTurn(userInput: "Test", assistantResponse: "Test after empty input")
```

**Step 4: Verify tests compile**

Run: `xcodebuild build -scheme ClaudeVoice -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceUITests/E2EErrorHandlingTests`

Expected: Build succeeds

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EErrorHandlingTests.swift
git commit -m "fix: use simulateConversationTurn in error handling tests"
```

---

## Task 5: Update Connection Tests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EConnectionTests.swift`

**Purpose:** Check if any connection tests need updating

**Step 1: Read connection tests**

Run: `cat ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EConnectionTests.swift`

**Step 2: Update any tests using voice input + assistant response**

Look for patterns like:
```swift
sendVoiceInput(...)
injectAssistantResponse(...)
```

Replace with:
```swift
simulateConversationTurn(userInput: ..., assistantResponse: ...)
```

**Step 3: Commit if changes made**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EConnectionTests.swift
git commit -m "fix: use simulateConversationTurn in connection tests"
```

---

## Task 6: Run E2E Tests

**Purpose:** Verify all tests pass

**Step 1: Run full test suite**

Run: `cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh`

**Step 2: Analyze results**

Expected: All 8 tests pass
- ✅ E2EHappyPathTests (2 tests)
- ✅ E2EConnectionTests (3 tests)
- ✅ E2EErrorHandlingTests (3 tests)

**Step 3: Debug any remaining failures**

If failures remain:
- Check server logs: `cat /tmp/e2e_server.log`
- Add debug logging to Swift helpers
- Verify transcript files are created correctly
- Check timing issues (add more sleep if needed)

**Step 4: Document results**

Create: `docs/testing/e2e-test-results-2026-01-01.md` with:
- Test results
- Any issues encountered
- Timing adjustments made
- Server log excerpts

---

## Completion Checklist

- [ ] `injectUserMessage()` helper added
- [ ] `simulateConversationTurn()` helper added
- [ ] Happy path tests updated
- [ ] Error handling tests updated
- [ ] Connection tests updated (if needed)
- [ ] All 8 E2E tests pass
- [ ] Test results documented

## Key Insights

**Why This Fixes the Issue:**
1. Server expects transcript to contain conversation history (user + assistant messages)
2. Server uses `last_voice_input` to find starting point in transcript
3. Server extracts blocks **after** finding the matching user message
4. Tests now match production flow: WebSocket input + complete transcript entries

**Architecture Remains Clean:**
- ✅ App doesn't know it's being tested
- ✅ Server runs unmodified
- ✅ Tests use real protocols (WebSocket + filesystem)
- ✅ Swift helpers work on iOS
- ✅ No test mode flags

**What Changed from Previous Plan:**
- Added `injectUserMessage()` helper
- Added `simulateConversationTurn()` convenience helper
- Updated all tests to inject both user + assistant messages
- Better matches production behavior where Claude writes full conversation to transcript
