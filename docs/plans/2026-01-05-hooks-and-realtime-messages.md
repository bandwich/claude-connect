# Hooks Configuration & Real-time Message UI

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Configure permission hooks (only active when voice server running) and display messages in UI as they arrive.

**Architecture:** Hooks check server availability before processing. SessionView subscribes to `onAssistantResponse` callback to append messages in real-time.

**Tech Stack:** Bash, Swift/SwiftUI

---

## Task 1: Add Server Check to Permission Hook

**Files:**
- Modify: `voice_server/hooks/permission_hook.sh`

### Step 1: Add server availability check at top of script

Replace the current content with:

```bash
#!/bin/bash
# Claude Code PermissionRequest hook
# Forwards permission requests to iOS voice server
#
# Reads JSON from stdin, POSTs to server, outputs response JSON
# Exit 0 on success with decision, exit 2 to fall back to terminal

SERVER_URL="${VOICE_SERVER_URL:-http://localhost:8766}"

# check if server is running - exit immediately if not
# Use /dev/null for stdin since we haven't consumed it yet
if ! curl -s --max-time 0.5 "${SERVER_URL}/health" >/dev/null 2>&1; then
    # Server not running - fall back to terminal silently
    cat >/dev/null  # Consume stdin to avoid broken pipe
    exit 2
fi

set -e

# Read JSON payload from stdin
PAYLOAD=$(cat)

# POST to permission endpoint with 3 minute timeout
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --max-time 185 \
  "${SERVER_URL}/permission" 2>/dev/null) || {
    # Network error - fall back to terminal
    exit 2
}

# Check if response has behavior=ask (timeout occurred)
if echo "$RESPONSE" | grep -q '"behavior".*:.*"ask"'; then
    # Server timed out waiting for iOS response
    exit 2
fi

# Output the decision JSON for Claude Code
echo "$RESPONSE"
exit 0
```

### Step 2: Run test to verify hook behavior

```bash
# Test with server NOT running (should exit 2 immediately)
echo '{}' | bash voice_server/hooks/permission_hook.sh; echo "Exit code: $?"
```
Expected: Exit code: 2 (immediate, no delay)

### Step 3: Commit

```bash
git add voice_server/hooks/permission_hook.sh
git commit -m "fix: permission hook checks server availability first"
```

---

## Task 2: Add Health Endpoint to HTTP Server

**Files:**
- Modify: `voice_server/http_server.py`

### Step 1: Read current http_server.py to find where to add route

Read the file to understand the structure.

### Step 2: Add health endpoint

Add a simple `/health` GET endpoint that returns 200 OK:

```python
async def handle_health(request):
    """Health check endpoint for hooks"""
    return web.json_response({"status": "ok"})
```

And register it in `create_http_app()`:

```python
app.router.add_get('/health', handle_health)
```

### Step 3: Run server tests

```bash
cd voice_server/tests && ./run_tests.sh
```
Expected: All tests pass

### Step 4: Commit

```bash
git add voice_server/http_server.py
git commit -m "feat: add /health endpoint for hook availability check"
```

---

## Task 3: Add Server Check to Post-Tool Hook

**Files:**
- Modify: `voice_server/hooks/post_tool_hook.sh`

### Step 1: Read current post_tool_hook.sh

### Step 2: Add server check at top

Same pattern - check server before doing anything:

```bash
#!/bin/bash
# Claude Code PostToolUse hook
# Notifies server when a tool completes (to dismiss permission prompt)

SERVER_URL="${VOICE_SERVER_URL:-http://localhost:8766}"

# check if server is running - exit silently if not
if ! curl -s --max-time 0.5 "${SERVER_URL}/health" >/dev/null 2>&1; then
    cat >/dev/null  # Consume stdin
    exit 0
fi

# Read JSON payload from stdin
PAYLOAD=$(cat)

# POST to permission_resolved endpoint (fire and forget)
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --max-time 5 \
  "${SERVER_URL}/permission_resolved" >/dev/null 2>&1 || true

exit 0
```

### Step 3: Commit

```bash
git add voice_server/hooks/post_tool_hook.sh
git commit -m "fix: post-tool hook checks server availability first"
```

---

## Task 4: Configure Hooks in Claude Settings

**Files:**
- Modify: `~/.claude/settings.json` (user's global settings)

### Step 1: Check current global settings

```bash
cat ~/.claude/settings.json
```

### Step 2: Add hooks configuration

Add hooks section (merge with existing content):

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "command": "/Users/aaron/Desktop/max/voice_server/hooks/permission_hook.sh",
        "timeout": 185000
      }
    ],
    "PostToolUse": [
      {
        "command": "/Users/aaron/Desktop/max/voice_server/hooks/post_tool_hook.sh"
      }
    ]
  }
}
```

### Step 3: Verify hooks are recognized

```bash
# Start a new Claude Code session and check if hooks are loaded
# (hooks are loaded on session start)
```

### Step 4: No commit needed (user settings file)

---

## Task 5: Connect Real-time Messages to UI

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

### Step 1: Add onAssistantResponse subscription in setupView()

In `setupView()`, after the audio player setup, add:

```swift
// Subscribe to real-time assistant responses
webSocketManager.onAssistantResponse = { [weak self] response in
    guard let self = self else { return }

    // Extract text from content blocks
    var textContent = ""
    for block in response.contentBlocks {
        switch block {
        case .text(let textBlock):
            textContent += textBlock.text
        case .thinking(_):
            // Skip thinking blocks for now
            break
        case .toolUse(_):
            // Skip tool use blocks for now
            break
        }
    }

    guard !textContent.isEmpty else { return }

    // Create message and append to list
    let message = SessionHistoryMessage(
        role: "assistant",
        content: textContent,
        timestamp: response.timestamp
    )

    DispatchQueue.main.async {
        self.messages.append(message)
    }
}
```

### Step 2: Add user message when sending voice input

In `speechRecognizer.onFinalTranscription`, add user message to list:

```swift
speechRecognizer.onFinalTranscription = { text in
    currentTranscript = text

    // Add user message to list immediately
    let userMessage = SessionHistoryMessage(
        role: "user",
        content: text,
        timestamp: Date().timeIntervalSince1970
    )
    messages.append(userMessage)

    webSocketManager.sendVoiceInput(text: text)

    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
        if currentTranscript == text {
            currentTranscript = ""
        }
    }
}
```

### Step 3: Build and verify

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: Build succeeds

### Step 4: Run unit tests

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests
```
Expected: All tests pass

### Step 5: Write E2E test to verify messages appear in UI

Add to `E2ESessionViewTests.swift`:

```swift
/// Test that assistant messages appear in real-time as they arrive
func test_assistant_message_appears_in_realtime() throws {
    navigateToSession1()

    // Count initial messages
    let initialMessageCount = app.staticTexts.matching(
        NSPredicate(format: "identifier == 'messageBubble'")
    ).count

    // Inject assistant response via transcript
    injectUserMessage("Test question")
    injectAssistantResponse("Test answer from Claude")

    // Wait for message to appear in UI
    let newMessage = app.staticTexts["Test answer from Claude"]
    XCTAssertTrue(
        newMessage.waitForExistence(timeout: 5),
        "Assistant message should appear in UI within 5 seconds"
    )

    // Verify message count increased
    let finalMessageCount = app.staticTexts.matching(
        NSPredicate(format: "identifier == 'messageBubble'")
    ).count
    XCTAssertGreaterThan(finalMessageCount, initialMessageCount, "Message count should increase")
}

/// Test that user messages appear immediately when sent
func test_user_message_appears_immediately() throws {
    navigateToSession1()

    // Send voice input
    sendVoiceInput("Hello from test")

    // User message should appear immediately (not waiting for response)
    let userMessage = app.staticTexts["Hello from test"]
    XCTAssertTrue(
        userMessage.waitForExistence(timeout: 2),
        "User message should appear immediately after sending"
    )
}
```

### Step 6: Add accessibility identifier to MessageBubble

In `SessionView.swift`, update MessageBubble:

```swift
struct MessageBubble: View {
    let message: SessionHistoryMessage

    var body: some View {
        HStack {
            if message.role == "user" {
                Spacer()
            }

            Text(message.content)
                .padding(12)
                .background(message.role == "user" ? Color.blue : Color(.systemGray5))
                .foregroundColor(message.role == "user" ? .white : .primary)
                .cornerRadius(16)
                .accessibilityIdentifier("messageBubble")  // ADD THIS

            if message.role == "assistant" {
                Spacer()
            }
        }
    }
}
```

### Step 7: Run E2E test to verify it fails

```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2ESessionViewTests
```
Expected: FAIL - messages don't appear in UI

### Step 8: Debug and fix message display issue

The issue is likely in how `onAssistantResponse` captures state. Debug by:
1. Add logging to verify callback fires
2. Verify messages array updates
3. Check if view re-renders

### Step 9: Run E2E test to verify it passes

```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2ESessionViewTests
```
Expected: PASS

### Step 10: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ESessionViewTests.swift
git commit -m "feat: display messages in real-time as they arrive"
```

---

## Task 6: State Machine for Claude Output Types

**Goal:** Track Claude's current output type, show appropriate UI, validate iOS responses.

**Claude Output → UI Mapping:**
| Output Type | UI Component |
|-------------|--------------|
| Text response | Message bubble |
| Thinking block | Status indicator ("Thinking...") |
| Tool use block | Status indicator ("Using [tool]...") |
| Status update | Status label |
| Audio chunk | Audio player |
| Permission request | Permission sheet |
| AskUserQuestion | Permission sheet (with options) |

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ClaudeOutputState.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- Modify: `voice_server/ios_server.py`
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeOutputStateTests.swift`
- Create: `voice_server/tests/test_state_validation.py`

---

### Step 1: Write failing test for ClaudeOutputState (iOS)

Create `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeOutputStateTests.swift`:

```swift
import Testing
@testable import ClaudeVoice

@Suite("ClaudeOutputState Tests")
struct ClaudeOutputStateTests {

    @Test func testIdleAllowsVoiceInput() {
        let state = ClaudeOutputState.idle
        #expect(state.canSendVoiceInput == true)
        #expect(state.expectsPermissionResponse == false)
    }

    @Test func testAwaitingPermissionBlocksVoiceAllowsResponse() {
        let state = ClaudeOutputState.awaitingPermission("req-123")
        #expect(state.canSendVoiceInput == false)
        #expect(state.expectsPermissionResponse == true)
    }

    @Test func testThinkingBlocksVoiceInput() {
        let state = ClaudeOutputState.thinking
        #expect(state.canSendVoiceInput == false)
    }

    @Test func testUsingToolBlocksVoiceInput() {
        let state = ClaudeOutputState.usingTool("Bash")
        #expect(state.canSendVoiceInput == false)
    }

    @Test func testSpeakingBlocksVoiceInput() {
        let state = ClaudeOutputState.speaking
        #expect(state.canSendVoiceInput == false)
    }
}
```

### Step 2: Run test to verify it fails

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests
```
Expected: FAIL (ClaudeOutputState not found)

### Step 3: Create ClaudeOutputState model

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ClaudeOutputState.swift`:

```swift
import Foundation

/// Tracks what type of output Claude is currently producing
enum ClaudeOutputState: Equatable {
    case idle
    case thinking
    case usingTool(String)              // tool name
    case speaking
    case awaitingPermission(String)     // request_id
    case awaitingQuestion(String)       // request_id

    var canSendVoiceInput: Bool {
        switch self {
        case .idle:
            return true
        case .thinking, .usingTool, .speaking, .awaitingPermission, .awaitingQuestion:
            return false
        }
    }

    var expectsPermissionResponse: Bool {
        switch self {
        case .awaitingPermission, .awaitingQuestion:
            return true
        default:
            return false
        }
    }

    /// Status text to display (nil = no status indicator)
    var statusText: String? {
        switch self {
        case .idle:
            return nil
        case .thinking:
            return "Thinking..."
        case .usingTool(let name):
            return "Using \(name)..."
        case .speaking:
            return "Speaking..."
        case .awaitingPermission, .awaitingQuestion:
            return nil  // Permission sheet handles this
        }
    }
}
```

### Step 4: Run test to verify it passes

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/ClaudeOutputStateTests
```
Expected: PASS

### Step 5: Add outputState to WebSocketManager

In `WebSocketManager.swift`, add:

```swift
@Published var outputState: ClaudeOutputState = .idle
```

Update `handleAssistantResponse` to set state based on content blocks:

```swift
private func handleAssistantResponse(_ message: AssistantResponseMessage) {
    // ... existing logging ...

    for block in message.contentBlocks {
        switch block {
        case .thinking:
            DispatchQueue.main.async { self.outputState = .thinking }
        case .toolUse(let toolBlock):
            DispatchQueue.main.async { self.outputState = .usingTool(toolBlock.name) }
        case .text:
            break  // Text doesn't change state
        }
    }

    onAssistantResponse?(message)
}
```

Update permission handling:

```swift
// In permission_request handling:
DispatchQueue.main.async {
    self.outputState = .awaitingPermission(permissionRequest.requestId)
    self.pendingPermission = permissionRequest
    self.onPermissionRequest?(permissionRequest)
}

// In permission_resolved handling:
DispatchQueue.main.async {
    self.outputState = .idle
    // ... existing code ...
}
```

Update audio handling (in SessionView setupView):

```swift
audioPlayer.onPlaybackStarted = {
    DispatchQueue.main.async {
        webSocketManager.outputState = .speaking
        // ... existing code ...
    }
}

audioPlayer.onPlaybackFinished = {
    DispatchQueue.main.async {
        webSocketManager.outputState = .idle
        // ... existing code ...
    }
}
```

### Step 6: Update SessionView to use outputState

In `SessionView.swift`, update status display:

```swift
// Replace voiceState display with outputState
if let statusText = webSocketManager.outputState.statusText {
    Text(statusText)
        .font(.caption)
        .foregroundColor(.secondary)
        .accessibilityIdentifier("outputStatus")
}
```

Update `canRecord`:

```swift
private var canRecord: Bool {
    guard isSessionSynced else { return false }
    guard webSocketManager.outputState.canSendVoiceInput else { return false }
    if case .connected = webSocketManager.connectionState {
        return speechRecognizer.isAuthorized && !audioPlayer.isPlaying
    }
    return false
}
```

### Step 7: Build iOS and run tests

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests
```
Expected: All tests pass

### Step 8: Commit iOS changes

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ClaudeOutputState.swift
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git add ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeOutputStateTests.swift
git commit -m "feat: add ClaudeOutputState to track output types and control UI"
```

---

### Step 9: Write failing server test for validation

Create `voice_server/tests/test_state_validation.py`:

```python
"""Tests for server-side message validation"""

import pytest
import json
from unittest.mock import AsyncMock, MagicMock

import sys
import os
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))


class TestMessageValidation:

    @pytest.mark.asyncio
    async def test_rejects_permission_response_without_pending(self):
        """permission_response without pending request should error"""
        from ios_server import VoiceServer

        server = VoiceServer()
        websocket = AsyncMock()

        message = json.dumps({
            "type": "permission_response",
            "request_id": "nonexistent-123",
            "decision": "allow"
        })

        await server.handle_message(websocket, message)

        websocket.send.assert_called()
        sent = json.loads(websocket.send.call_args[0][0])
        assert sent["type"] == "error"

    @pytest.mark.asyncio
    async def test_rejects_voice_input_while_permission_pending(self):
        """voice_input while permission pending should error"""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.vscode_controller = MagicMock()
        server.vscode_controller.is_connected.return_value = False
        websocket = AsyncMock()

        # Register pending permission
        server.permission_handler.register_request("pending-123")

        message = json.dumps({
            "type": "voice_input",
            "text": "hello"
        })

        await server.handle_message(websocket, message)

        websocket.send.assert_called()
        sent = json.loads(websocket.send.call_args[0][0])
        assert sent["type"] == "error"
```

### Step 10: Run test to verify it fails

```bash
cd voice_server/tests && python -m pytest test_state_validation.py -v
```
Expected: FAIL (no validation implemented)

### Step 11: Add validation to ios_server.py

In `handle_message`, add validation before dispatching:

```python
async def handle_message(self, websocket, message):
    """Handle incoming message with state validation"""
    try:
        data = json.loads(message)
        msg_type = data.get('type')

        # Validate permission_response
        if msg_type == 'permission_response':
            request_id = data.get('request_id', '')
            if not self.permission_handler.is_request_pending(request_id) and \
               not self.permission_handler.is_request_timed_out(request_id):
                await websocket.send(json.dumps({
                    "type": "error",
                    "message": "No pending permission request"
                }))
                return

        # Reject voice_input while permission pending
        if msg_type == 'voice_input':
            if self.permission_handler.pending_permissions:
                await websocket.send(json.dumps({
                    "type": "error",
                    "message": "Cannot send voice input while permission pending"
                }))
                return

        # Dispatch to handlers (existing code)
        if msg_type == 'voice_input':
            await self.handle_voice_input(websocket, data)
        # ... rest unchanged ...
```

### Step 12: Run test to verify it passes

```bash
cd voice_server/tests && python -m pytest test_state_validation.py -v
```
Expected: PASS

### Step 13: Run all server tests

```bash
cd voice_server/tests && ./run_tests.sh
```
Expected: All tests pass

### Step 14: Commit server changes

```bash
git add voice_server/ios_server.py
git add voice_server/tests/test_state_validation.py
git commit -m "feat: validate incoming messages against permission state"
```

---

## Summary

| Task | Description |
|------|-------------|
| 1 | Permission hook checks server before processing |
| 2 | Add /health endpoint for availability check |
| 3 | Post-tool hook checks server before processing |
| 4 | Configure hooks in user's Claude settings |
| 5 | Display messages in UI as they arrive |
| 6 | State machine for Claude output types + validation |

**Files Modified:**
- `voice_server/hooks/permission_hook.sh`
- `voice_server/hooks/post_tool_hook.sh`
- `voice_server/http_server.py`
- `voice_server/ios_server.py`
- `~/.claude/settings.json`
- `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ClaudeOutputState.swift` (new)
- `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeOutputStateTests.swift` (new)
- `voice_server/tests/test_state_validation.py` (new)
