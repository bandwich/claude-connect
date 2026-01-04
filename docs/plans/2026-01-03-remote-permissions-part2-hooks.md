# Remote Permission Control - Part 2: Hook Scripts & WebSocket

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Create the shell scripts that Claude Code hooks invoke, and update iOS WebSocketManager to handle permission messages.

**Architecture:** Bash scripts read JSON from stdin, POST to HTTP server, output response. WebSocketManager decodes new message types and exposes callbacks.

**Tech Stack:** Bash/curl, Swift/URLSession

**Prerequisites:** Part 1 complete (PermissionHandler, HTTP endpoints exist)

---

## Task 4: Hook Shell Scripts

**Files:**
- Create: `voice_server/hooks/permission_hook.sh`
- Create: `voice_server/hooks/post_tool_hook.sh`
- Test: `voice_server/tests/test_hooks.py`

### Step 1: Write the failing test

```python
# voice_server/tests/test_hooks.py
"""Tests for hook shell scripts"""

import pytest
import subprocess
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

HOOKS_DIR = os.path.join(os.path.dirname(__file__), '..', 'hooks')


class TestPermissionHook:
    """Tests for permission_hook.sh"""

    def test_hook_exists_and_executable(self):
        """Test hook script exists and is executable"""
        hook_path = os.path.join(HOOKS_DIR, 'permission_hook.sh')
        assert os.path.exists(hook_path), f"Hook not found: {hook_path}"
        assert os.access(hook_path, os.X_OK), "Hook is not executable"

    def test_hook_reads_stdin_and_posts(self):
        """Test hook reads JSON from stdin and POSTs to server"""
        hook_path = os.path.join(HOOKS_DIR, 'permission_hook.sh')

        with open(hook_path, 'r') as f:
            content = f.read()

        assert 'curl' in content, "Hook should use curl"
        assert '/permission' in content, "Hook should POST to /permission"
        assert 'stdin' in content.lower() or 'cat' in content, "Hook should read from stdin"


class TestPostToolHook:
    """Tests for post_tool_hook.sh"""

    def test_hook_exists_and_executable(self):
        """Test hook script exists and is executable"""
        hook_path = os.path.join(HOOKS_DIR, 'post_tool_hook.sh')
        assert os.path.exists(hook_path), f"Hook not found: {hook_path}"
        assert os.access(hook_path, os.X_OK), "Hook is not executable"

    def test_hook_posts_resolved(self):
        """Test hook POSTs to /permission_resolved"""
        hook_path = os.path.join(HOOKS_DIR, 'post_tool_hook.sh')

        with open(hook_path, 'r') as f:
            content = f.read()

        assert 'curl' in content, "Hook should use curl"
        assert '/permission_resolved' in content, "Hook should POST to /permission_resolved"
```

### Step 2: Run test to verify it fails

```bash
cd voice_server/tests && python -m pytest test_hooks.py -v 2>&1 | tail -20
```
Expected: FAIL with "AssertionError: Hook not found"

### Step 3: Create hooks directory and scripts

```bash
mkdir -p voice_server/hooks
```

```bash
# voice_server/hooks/permission_hook.sh
#!/bin/bash
# Claude Code PermissionRequest hook
# Forwards permission requests to iOS voice server
#
# Reads JSON from stdin, POSTs to server, outputs response JSON
# Exit 0 on success with decision, exit 2 to fall back to terminal

set -e

SERVER_URL="${VOICE_SERVER_URL:-http://localhost:8766}"

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

```bash
# voice_server/hooks/post_tool_hook.sh
#!/bin/bash
# Claude Code PostToolUse hook
# Notifies iOS voice server that a permission prompt was resolved
#
# Reads JSON from stdin, extracts request info, POSTs to server

SERVER_URL="${VOICE_SERVER_URL:-http://localhost:8766}"

# Read JSON payload from stdin
PAYLOAD=$(cat)

# POST to permission_resolved endpoint (fire and forget)
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "${SERVER_URL}/permission_resolved" >/dev/null 2>&1 || true

exit 0
```

### Step 4: Make scripts executable

```bash
chmod +x voice_server/hooks/permission_hook.sh
chmod +x voice_server/hooks/post_tool_hook.sh
```

### Step 5: Run test to verify it passes

```bash
cd voice_server/tests && python -m pytest test_hooks.py -v
```
Expected: PASS (all 4 tests)

### Step 6: Commit

```bash
git add voice_server/hooks/permission_hook.sh voice_server/hooks/post_tool_hook.sh \
        voice_server/tests/test_hooks.py
git commit -m "feat: add permission hook shell scripts"
```

---

## Task 5: WebSocket Manager Permission Handling (iOS)

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift`

### Step 1: Add test cases to existing test file

Add to `WebSocketManagerTests.swift`:

```swift
// Add to ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift

func testDecodePermissionRequest() throws {
    let json = """
    {
        "type": "permission_request",
        "request_id": "uuid-123",
        "prompt_type": "bash",
        "tool_name": "Bash",
        "tool_input": {"command": "npm install"},
        "timestamp": 1234567890
    }
    """.data(using: .utf8)!

    let request = try JSONDecoder().decode(PermissionRequest.self, from: json)

    XCTAssertEqual(request.requestId, "uuid-123")
    XCTAssertEqual(request.toolName, "Bash")
}

func testDecodePermissionResolved() throws {
    let json = """
    {
        "type": "permission_resolved",
        "request_id": "uuid-123",
        "answered_in": "terminal"
    }
    """.data(using: .utf8)!

    let resolved = try JSONDecoder().decode(PermissionResolved.self, from: json)

    XCTAssertEqual(resolved.requestId, "uuid-123")
    XCTAssertEqual(resolved.answeredIn, "terminal")
}
```

### Step 2: Run tests (should pass with Task 1 models)

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/WebSocketManagerTests 2>&1 | tail -20
```
Expected: PASS

### Step 3: Add permission callbacks and state to WebSocketManager

Add these properties around line 24 in `WebSocketManager.swift`:

```swift
// Add after existing callbacks (around line 24)
var onPermissionRequest: ((PermissionRequest) -> Void)?
var onPermissionResolved: ((PermissionResolved) -> Void)?
@Published var pendingPermission: PermissionRequest? = nil
```

### Step 4: Add message handling in handleMessage()

Add this to the `handleMessage()` method, in the decoding chain (around line 315):

```swift
} else if let permissionRequest = try? JSONDecoder().decode(PermissionRequest.self, from: data) {
    logToFile("✅ Decoded as PermissionRequest: \(permissionRequest.requestId)")
    DispatchQueue.main.async {
        self.pendingPermission = permissionRequest
        self.onPermissionRequest?(permissionRequest)
    }
} else if let permissionResolved = try? JSONDecoder().decode(PermissionResolved.self, from: data) {
    logToFile("✅ Decoded as PermissionResolved: \(permissionResolved.requestId)")
    DispatchQueue.main.async {
        if self.pendingPermission?.requestId == permissionResolved.requestId {
            self.pendingPermission = nil
        }
        self.onPermissionResolved?(permissionResolved)
    }
```

### Step 5: Add method to send permission response

Add this method to `WebSocketManager`:

```swift
func sendPermissionResponse(_ response: PermissionResponse) {
    guard let data = try? JSONEncoder().encode(response),
          let jsonString = String(data: data, encoding: .utf8) else {
        print("❌ Failed to encode permission response")
        return
    }

    let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
    webSocketTask?.send(wsMessage) { error in
        if let error = error {
            print("❌ Failed to send permission response: \(error)")
        } else {
            print("✅ Permission response sent")
            DispatchQueue.main.async {
                self.pendingPermission = nil
            }
        }
    }
}
```

### Step 6: Run full test suite

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests 2>&1 | tail -30
```
Expected: PASS

### Step 7: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift
git commit -m "feat: add permission request handling to WebSocketManager"
```

---

## Part 2 Complete

**Tasks Completed:** 2
**Files Created/Modified:** 5

**Next:** Continue with Part 3 (iOS UI Components)
