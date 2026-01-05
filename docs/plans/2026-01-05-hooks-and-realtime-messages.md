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

# Quick check if server is running - exit immediately if not
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

# Quick check if server is running - exit silently if not
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

### Step 5: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: display messages in real-time as they arrive"
```

---

## Task 6: Disable Voice Input During Permission Prompt

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

### Step 1: Add permission check to canRecord

Update the `canRecord` computed property:

```swift
private var canRecord: Bool {
    guard isSessionSynced else { return false }
    guard webSocketManager.pendingPermission == nil else { return false }  // ADD THIS
    if case .connected = webSocketManager.connectionState {
        return speechRecognizer.isAuthorized
            && !audioPlayer.isPlaying
            && webSocketManager.voiceState != .processing
    }
    return false
}
```

### Step 2: Build and verify

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: Build succeeds

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "fix: disable voice input when permission prompt is pending"
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
| 6 | Disable voice input during permission prompts |

**Files Modified:**
- `voice_server/hooks/permission_hook.sh`
- `voice_server/hooks/post_tool_hook.sh`
- `voice_server/http_server.py`
- `~/.claude/settings.json`
- `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
