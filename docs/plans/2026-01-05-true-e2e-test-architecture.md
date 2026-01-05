# True E2E Test Architecture

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Problem:** Current E2E tests bypass VSCode terminal submission entirely. Tests inject messages directly into the transcript file, so bugs like `\n` vs `\r` go undetected.

**Current flow (broken):**
```
Voice Input → Server → [VSCode - UNTESTED] → Tests inject transcript → App
```

**Desired flow (true E2E):**
```
Voice Input → Server → Mock VSCode Server → Writes to Transcript → App
```

**Key insight:** If VSCode connection breaks, happy path tests should fail immediately.

---

## Architecture

### Mock VSCode Server

Create a mock WebSocket server that:
1. Listens on port 3710 (same as vscode-remote-control extension)
2. Receives `sendSequence` commands from ios_server
3. Parses the command text
4. If text ends with `\r` (Enter), writes a simulated response to transcript
5. This simulates what Claude CLI would do

### Test Flow Changes

**Before:**
```swift
func simulateConversationTurn(userInput: String, assistantResponse: String) {
    sendVoiceInput(userInput)        // Send to server
    injectUserMessage(userInput)      // BYPASS: directly inject
    injectAssistantMessage(response)  // BYPASS: directly inject
}
```

**After:**
```swift
func sendVoiceAndWaitForResponse(userInput: String, expectedInTranscript: Bool = true) {
    sendVoiceInput(userInput)  // Send to server
    // Server sends to Mock VSCode (port 3710)
    // Mock VSCode writes to transcript
    // App detects transcript change
    // NO INJECTION - real flow
}
```

---

## Part 1: Create Mock VSCode Server

### Task 1: Create MockVSCodeServer class

**Files:**
- Create: `tests/e2e_support/mock_vscode_server.py`

### Step 1: Implement mock server

```python
#!/usr/bin/env python3
"""Mock VSCode remote-control extension for E2E tests"""
import asyncio
import json
import websockets
from typing import Optional
import os

class MockVSCodeServer:
    """
    Simulates vscode-remote-control extension.
    When it receives sendSequence with text ending in \r,
    it writes a mock Claude response to the transcript.
    """

    def __init__(self, port: int = 3710, transcript_path: Optional[str] = None):
        self.port = port
        self.transcript_path = transcript_path
        self.server = None
        self.received_commands = []

    async def handle_connection(self, websocket):
        """Handle incoming WebSocket connection"""
        async for message in websocket:
            try:
                data = json.loads(message)
                command = data.get("command", "")
                args = data.get("args", {})

                self.received_commands.append(data)
                print(f"[MockVSCode] Received: {command}")

                if command == "workbench.action.terminal.sendSequence":
                    text = args.get("text", "")
                    await self._handle_send_sequence(text)

            except json.JSONDecodeError:
                print(f"[MockVSCode] Invalid JSON: {message}")

    async def _handle_send_sequence(self, text: str):
        """Handle terminal sendSequence command"""
        print(f"[MockVSCode] sendSequence: {repr(text)}")

        # Only process if text ends with carriage return (Enter pressed)
        if not text.endswith("\r"):
            print(f"[MockVSCode] Text does not end with \\r, not executing")
            return

        # Strip the \r and get the command
        command_text = text[:-1]

        # Write mock response to transcript
        if self.transcript_path:
            await self._write_mock_response(command_text)

    async def _write_mock_response(self, user_input: str):
        """Write mock Claude response to transcript file"""
        import time

        # User message
        user_msg = {
            "type": "user",
            "message": {"content": user_input},
            "timestamp": time.time()
        }

        # Assistant response
        assistant_msg = {
            "type": "assistant",
            "message": {"content": f"Mock response to: {user_input}"},
            "timestamp": time.time() + 0.1
        }

        with open(self.transcript_path, "a") as f:
            f.write(json.dumps(user_msg) + "\n")
            f.write(json.dumps(assistant_msg) + "\n")

        print(f"[MockVSCode] Wrote response to transcript")

    async def start(self):
        """Start the mock server"""
        self.server = await websockets.serve(
            self.handle_connection,
            "localhost",
            self.port
        )
        print(f"[MockVSCode] Server running on ws://localhost:{self.port}")

    async def stop(self):
        """Stop the mock server"""
        if self.server:
            self.server.close()
            await self.server.wait_closed()

    def get_received_commands(self):
        """Get list of all received commands (for test assertions)"""
        return self.received_commands.copy()

    def clear_received_commands(self):
        """Clear received commands list"""
        self.received_commands.clear()
```

### Step 2: Add CLI interface

Add to end of file:
```python
async def main():
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=3710)
    parser.add_argument("--transcript", required=True)
    args = parser.parse_args()

    server = MockVSCodeServer(port=args.port, transcript_path=args.transcript)
    await server.start()

    try:
        await asyncio.Future()  # Run forever
    except KeyboardInterrupt:
        await server.stop()

if __name__ == "__main__":
    asyncio.run(main())
```

### Step 3: Verify

```bash
python tests/e2e_support/mock_vscode_server.py --transcript /tmp/test.jsonl &
# In another terminal:
python -c "
import asyncio
import websockets
import json

async def test():
    async with websockets.connect('ws://localhost:3710') as ws:
        await ws.send(json.dumps({
            'command': 'workbench.action.terminal.sendSequence',
            'args': {'text': 'hello world\r'}
        }))

asyncio.run(test())
"
cat /tmp/test.jsonl  # Should show mock response
```

---

## Part 2: Update E2E Test Runner

### Task 2: Start Mock VSCode Server in run_e2e_tests.sh

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/run_e2e_tests.sh`

### Step 1: Add mock VSCode server startup

After starting ios_server.py, add:
```bash
# Start mock VSCode server
echo "📺 Starting mock VSCode server..."
python3 "$PROJECT_ROOT/tests/e2e_support/mock_vscode_server.py" \
    --port 3710 \
    --transcript "$E2E_TRANSCRIPT_PATH" &
MOCK_VSCODE_PID=$!
echo "   Mock VSCode PID: $MOCK_VSCODE_PID"
sleep 1
```

### Step 2: Add cleanup

In cleanup function:
```bash
if [ -n "$MOCK_VSCODE_PID" ]; then
    kill $MOCK_VSCODE_PID 2>/dev/null || true
fi
```

---

## Part 3: Update Happy Path Tests

### Task 3: Remove transcript injection from happy path

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EHappyPathTests.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift`

### Step 1: Add new helper method to E2ETestBase

```swift
/// Send voice input and wait for response via real flow
/// (no transcript injection - relies on mock VSCode server)
func sendVoiceAndWaitForResponse(
    _ text: String,
    timeout: TimeInterval = 15.0
) -> Bool {
    sendVoiceInput(text)

    // Wait for voice state to transition through the flow
    // Processing -> Speaking -> Idle
    let startIdle = waitForVoiceState("Idle", timeout: 5)
    guard startIdle else { return false }

    // Wait for speaking (response received from mock VSCode)
    let speaking = waitForVoiceState("Speaking", timeout: timeout)
    guard speaking else { return false }

    // Wait to return to idle
    return waitForVoiceState("Idle", timeout: timeout)
}
```

### Step 2: Update E2EHappyPathTests

Replace `simulateConversationTurn` calls with `sendVoiceAndWaitForResponse`:

```swift
func test_voice_conversation_flow() throws {
    navigateToTestSession()

    XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle")

    // Test 1: Single turn via real flow
    XCTAssertTrue(
        sendVoiceAndWaitForResponse("Hello Claude"),
        "Should complete voice conversation turn"
    )

    // Test 2: Multiple turns
    XCTAssertTrue(
        sendVoiceAndWaitForResponse("Second message"),
        "Should complete second turn"
    )

    XCTAssertTrue(
        sendVoiceAndWaitForResponse("Third message"),
        "Should complete third turn"
    )
}
```

---

## Part 4: Verify Bug Detection

### Task 4: Temporarily break VSCode send to verify tests catch it

### Step 1: Change `\r` back to `\n` temporarily

In `ios_server.py` line 298:
```python
success = await self.vscode_controller.send_sequence(text + "\n")  # Bug!
```

### Step 2: Run E2EHappyPathTests

```bash
./run_e2e_tests.sh E2EHappyPathTests
```

**Expected:** Tests should FAIL because mock VSCode only writes to transcript when command ends with `\r`.

### Step 3: Fix bug and verify tests pass

Change back to `\r` and run tests again. Should pass.

---

## Summary

### What Changes

| Component | Before | After |
|-----------|--------|-------|
| Mock VSCode | None | New server on port 3710 |
| Happy path tests | Inject transcript | Real flow via mock VSCode |
| Bug detection | Manual only | Automated |

### Test Coverage

- ✅ Voice input → Server WebSocket
- ✅ Server → VSCode terminal send (NEW)
- ✅ Terminal command execution (Enter key) (NEW)
- ✅ Transcript file watching
- ✅ App UI response

### Key Benefit

If the `\n` vs `\r` bug returns, or if VSCode connection breaks, **happy path tests fail immediately** instead of passing with false confidence.
