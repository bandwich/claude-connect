# Activity Status + Interrupt Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Show real-time Claude activity (thinking, tool use, idle) below the last message with a spinner, and let the user interrupt via a stop button.

**Architecture:** Server polls tmux pane content every ~1s when a session is active, parses the terminal status indicators, and pushes state changes to iOS via a new `activity_status` WebSocket message. iOS displays a spinner + text + stop button below the last conversation item. Stop button sends `interrupt` message, server sends Escape to tmux.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS), tmux pane capture, regex parsing

**Risky Assumptions:**
1. We can reliably parse Claude Code's terminal status indicators from tmux pane capture. **Verified early in Task 1** by capturing real pane output before writing any parser code.
2. Sending `Escape` via tmux will interrupt Claude the same way pressing Escape in the terminal does. **Verified in Task 4** with a real tmux test.

---

### Task 1: Capture and Document Terminal Status Indicators

**Files:**
- Create: `voice_server/tests/fixtures/pane_captures/` (directory for fixture files)

**Step 1: Start Claude in tmux and capture pane output in different states**

Start a real Claude session in tmux, send a prompt that triggers thinking + tool use, and capture the pane at various points. Save each capture to a file.

```bash
# Start Claude in tmux
tmux new-session -d -s capture_test -c /Users/aaron/Desktop/max "claude"
sleep 3

# Capture idle state (waiting for input)
tmux capture-pane -t capture_test -p > voice_server/tests/fixtures/pane_captures/idle.txt

# Send a prompt that will trigger thinking and tool use
tmux send-keys -t capture_test "read the file voice_server/ios_server.py and tell me how many lines it has" Enter

# Capture rapidly during processing to catch different states
for i in $(seq 1 20); do
    tmux capture-pane -t capture_test -p > "voice_server/tests/fixtures/pane_captures/capture_${i}.txt"
    sleep 1
done

# Kill the session
tmux kill-session -t capture_test
```

**Step 2: Examine the captures and document the exact format of each status indicator**

Look at each capture file and identify:
- The exact Unicode characters used (e.g., `✶` for thinking)
- The format of the thinking line (duration, token count)
- The format of the tool activity line (tool names, file counts)
- The format of the idle/prompt state
- Whether there are indeed two separate status indicators and what each shows

Document findings as comments in the fixture files.

**CHECKPOINT:** Do not proceed until you have real captured output showing at least thinking, tool use, and idle states. These captures are the foundation for all parsing code.

**Step 3: Commit**

```bash
git add voice_server/tests/fixtures/pane_captures/
git commit -m "feat: capture tmux pane output fixtures for status parsing"
```

---

### Task 2: Pane Status Parser (TDD)

**Files:**
- Create: `voice_server/pane_parser.py`
- Create: `voice_server/tests/test_pane_parser.py`

**Step 1: Write failing tests using real fixture data from Task 1**

Use the actual captured pane output from Task 1 as test inputs. Write tests for each state the parser needs to detect.

```python
# voice_server/tests/test_pane_parser.py
import pytest
from voice_server.pane_parser import parse_pane_status, ActivityState

# Load fixture data captured in Task 1
# Adjust these expected values based on what Task 1 actually captured

class TestParsePaneStatus:
    def test_detects_idle_state(self):
        """Idle = prompt visible, no thinking/tool indicator"""
        # Use actual idle fixture content from Task 1
        with open("voice_server/tests/fixtures/pane_captures/idle.txt") as f:
            pane_text = f.read()
        result = parse_pane_status(pane_text)
        assert result.state == "idle"
        assert result.detail == ""

    def test_detects_thinking_state(self):
        """Thinking = thinking indicator visible in pane"""
        # Use actual thinking fixture from Task 1
        # (identify which capture_N.txt shows thinking state)
        pane_text = "..."  # Replace with real fixture content
        result = parse_pane_status(pane_text)
        assert result.state == "thinking"

    def test_detects_tool_active_state(self):
        """Tool active = tool activity indicator visible"""
        # Use actual tool use fixture from Task 1
        pane_text = "..."  # Replace with real fixture content
        result = parse_pane_status(pane_text)
        assert result.state == "tool_active"
        assert result.detail != ""  # Should have detail like "Reading 1 file..."

    def test_returns_idle_for_empty_pane(self):
        result = parse_pane_status("")
        assert result.state == "idle"

    def test_returns_idle_for_none(self):
        result = parse_pane_status(None)
        assert result.state == "idle"
```

**Step 2: Run tests to verify they fail**

```bash
cd voice_server/tests && python -m pytest test_pane_parser.py -v
```

Expected: ImportError or FAIL (module doesn't exist yet)

**Step 3: Implement the parser based on actual captured patterns**

```python
# voice_server/pane_parser.py
"""Parse tmux pane output to detect Claude Code's current activity state."""

import re
from dataclasses import dataclass


@dataclass
class ActivityState:
    state: str   # "idle", "thinking", "tool_active"
    detail: str  # e.g., "Reading 3 files...", "Searching for patterns..."


def parse_pane_status(pane_text: str | None) -> ActivityState:
    """Parse tmux pane capture to determine Claude's current state.

    Examines the last few lines of pane output for status indicators.
    Patterns are based on real captured output from Claude Code terminal.

    Returns:
        ActivityState with state and optional detail text.
    """
    if not pane_text:
        return ActivityState(state="idle", detail="")

    # Look at last ~10 non-empty lines (status is at the bottom)
    lines = [l for l in pane_text.splitlines() if l.strip()]
    tail = lines[-10:] if len(lines) > 10 else lines
    tail_text = "\n".join(tail)

    # TODO: Replace these patterns with actual patterns found in Task 1
    # These are placeholders that MUST be updated based on real captures

    # Check for thinking indicator (e.g., "✶ Billowing…")
    # Pattern TBD from Task 1 captures
    thinking_match = re.search(r'REPLACE_WITH_REAL_PATTERN', tail_text)
    if thinking_match:
        return ActivityState(state="thinking", detail="")

    # Check for tool activity indicator (e.g., "Reading 3 files…")
    # Pattern TBD from Task 1 captures
    tool_match = re.search(r'REPLACE_WITH_REAL_PATTERN', tail_text)
    if tool_match:
        detail = tool_match.group(0).strip()
        return ActivityState(state="tool_active", detail=detail)

    return ActivityState(state="idle", detail="")
```

**IMPORTANT:** The regex patterns above are placeholders. Task 1 must be completed first and the patterns updated to match real output. Do NOT guess the patterns.

**Step 4: Run tests to verify they pass**

```bash
cd voice_server/tests && python -m pytest test_pane_parser.py -v
```

Expected: All PASS

**Step 5: Commit**

```bash
git add voice_server/pane_parser.py voice_server/tests/test_pane_parser.py
git commit -m "feat: add pane status parser with TDD tests"
```

---

### Task 3: Server Polling Loop + WebSocket Message

**Files:**
- Modify: `voice_server/ios_server.py` (VoiceServer class)
- Modify: `voice_server/tests/test_message_handlers.py`

**Step 1: Write failing test for interrupt message handler**

```python
# Add to voice_server/tests/test_message_handlers.py

class TestInterruptHandler:
    @pytest.mark.asyncio
    async def test_interrupt_sends_escape_to_tmux(self):
        """interrupt message should send Escape to tmux"""
        from ios_server import VoiceServer
        server = VoiceServer()

        # Track send_escape calls
        escape_called = False
        def mock_send_escape():
            nonlocal escape_called
            escape_called = True
            return True
        server.tmux.send_escape = mock_send_escape

        mock_ws = AsyncMock()
        await server.handle_message(mock_ws, json.dumps({"type": "interrupt"}))

        assert escape_called, "send_escape was not called"
```

**Step 2: Run test to verify it fails**

```bash
cd voice_server/tests && python -m pytest test_message_handlers.py::TestInterruptHandler -v
```

**Step 3: Add `send_escape()` to TmuxController**

```python
# Add to voice_server/tmux_controller.py, in TmuxController class:

    def send_escape(self) -> bool:
        """Send Escape key to the Claude session to interrupt current operation.

        Returns:
            True if sent successfully
        """
        result = subprocess.run(
            ["tmux", "send-keys", "-t", self.SESSION_NAME, "Escape"],
            capture_output=True,
            text=True
        )
        return result.returncode == 0
```

**Step 4: Add interrupt handler and polling loop to VoiceServer**

Add to `voice_server/ios_server.py`:

In `VoiceServer.__init__`:
```python
        self._pane_poll_task = None
        self._last_activity_state = None  # Track for change detection
```

Add polling method to VoiceServer:
```python
    async def _pane_poll_loop(self):
        """Poll tmux pane for activity status, broadcast on change."""
        from voice_server.pane_parser import parse_pane_status
        try:
            while True:
                if self.tmux.session_exists():
                    pane_text = self.tmux.capture_pane(include_history=False)
                    state = parse_pane_status(pane_text)

                    # Only broadcast on state change
                    if self._last_activity_state is None or \
                       state.state != self._last_activity_state.state or \
                       state.detail != self._last_activity_state.detail:
                        self._last_activity_state = state
                        await self.broadcast_message({
                            "type": "activity_status",
                            "state": state.state,
                            "detail": state.detail
                        })

                await asyncio.sleep(1.0)
        except asyncio.CancelledError:
            pass
```

Add interrupt handler:
```python
    async def handle_interrupt(self):
        """Handle interrupt request from iOS - send Escape to tmux"""
        if self.tmux.session_exists():
            self.tmux.send_escape()
            print(f"[{time.strftime('%H:%M:%S')}] Sent interrupt (Escape) to tmux")
```

Add to `handle_message` dispatch:
```python
            elif msg_type == 'interrupt':
                await self.handle_interrupt()
```

Start polling in `start()` method, after the TTS worker:
```python
        # Start pane polling loop
        self._pane_poll_task = asyncio.create_task(self._pane_poll_loop())
```

Cancel polling in the `finally` block of `start()`:
```python
                if self._pane_poll_task:
                    self._pane_poll_task.cancel()
```

**Step 5: Run tests**

```bash
cd voice_server/tests && python -m pytest test_message_handlers.py::TestInterruptHandler -v
```

Expected: PASS

**Step 6: Verify polling works with real tmux**

```bash
# Start a tmux session
tmux new-session -d -s claude_voice "cat"
# Run a quick Python script to test the parser
python3 -c "
from voice_server.tmux_controller import TmuxController
from voice_server.pane_parser import parse_pane_status
tc = TmuxController()
text = tc.capture_pane(include_history=False)
print('Pane text:', repr(text[:200]))
state = parse_pane_status(text)
print('State:', state)
"
tmux kill-session -t claude_voice
```

**CHECKPOINT:** The parser should return a valid ActivityState from real pane content.

**Step 7: Commit**

```bash
git add voice_server/tmux_controller.py voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add pane polling loop and interrupt handler"
```

---

### Task 4: TmuxController.send_escape() Test

**Files:**
- Modify: `voice_server/tests/test_tmux_controller.py`

**Step 1: Write test for send_escape**

```python
# Add to voice_server/tests/test_tmux_controller.py

class TestSendEscape:
    """Tests for sending Escape key to tmux sessions"""

    def test_send_escape_sends_escape_key(self, controller, ensure_no_session):
        """send_escape should send Escape key to the session"""
        # Start a session
        controller.start_session()
        time.sleep(0.3)

        # send_escape should succeed when session exists
        result = controller.send_escape()
        assert result is True

    def test_send_escape_returns_false_when_no_session(self, controller, ensure_no_session):
        """send_escape should return False when session doesn't exist"""
        result = controller.send_escape()
        assert result is False
```

**Step 2: Run tests**

```bash
cd voice_server/tests && python -m pytest test_tmux_controller.py::TestSendEscape -v
```

Expected: PASS (implementation was added in Task 3)

**Step 3: Commit**

```bash
git add voice_server/tests/test_tmux_controller.py
git commit -m "test: add send_escape tests for TmuxController"
```

---

### Task 5: iOS — Activity Status Model + WebSocket Handling

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

**Step 1: Add ActivityStatusMessage model**

Add to `Message.swift`:

```swift
struct ActivityStatusMessage: Codable, Equatable {
    let type: String
    let state: String
    let detail: String
}
```

**Step 2: Add activity state property and interrupt method to WebSocketManager**

Add published property:
```swift
    @Published var activityState: ActivityStatusMessage? = nil
```

Add callback:
```swift
    var onActivityStatus: ((ActivityStatusMessage) -> Void)?
```

Add `sendInterrupt()` method:
```swift
    func sendInterrupt() {
        let message = ["type": "interrupt"]
        sendJSON(message)
    }
```

Reset `activityState` on disconnect — add to `disconnect()`:
```swift
        activityState = nil
```

Reset `activityState` on new connection — add to `urlSession(_:webSocketTask:didOpenWithProtocol:)`:
```swift
        activityState = nil
```

**Step 3: Handle `activity_status` message in `handleMessage`**

In the string message handler chain in `handleMessage`, add before the final `else` block:

```swift
            } else if let activityStatus = try? JSONDecoder().decode(ActivityStatusMessage.self, from: data),
                      activityStatus.type == "activity_status" {
                logToFile("✅ Decoded as ActivityStatus: \(activityStatus.state)")
                DispatchQueue.main.async {
                    self.activityState = activityStatus
                    self.onActivityStatus?(activityStatus)
                }
            }
```

Also add the same handler in the binary message handler section.

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: add activity status model and interrupt support to iOS"
```

---

### Task 6: iOS — Status Indicator UI

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Add ActivityStatusView below the conversation items**

Add a new view struct at the bottom of SessionView.swift:

```swift
struct ActivityStatusView: View {
    let state: String   // "thinking", "tool_active"
    let detail: String
    let onInterrupt: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .scaleEffect(0.8)

            Text(displayText)
                .font(.subheadline)
                .foregroundColor(.secondary)

            Spacer()

            Button(action: onInterrupt) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .foregroundColor(.red)
                    .padding(6)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
            }
            .accessibilityLabel("Interrupt")
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var displayText: String {
        if !detail.isEmpty {
            return detail
        }
        switch state {
        case "thinking":
            return "Thinking..."
        case "tool_active":
            return "Working..."
        default:
            return "Working..."
        }
    }
}
```

**Step 2: Add the status view to the conversation scroll area**

In `SessionView.body`, inside the `VStack(alignment: .leading, spacing: 12)` that contains the `ForEach(items)`, add after the ForEach:

```swift
                            // Activity status indicator
                            if let activity = webSocketManager.activityState,
                               activity.state != "idle" {
                                ActivityStatusView(
                                    state: activity.state,
                                    detail: activity.detail,
                                    onInterrupt: {
                                        webSocketManager.sendInterrupt()
                                    }
                                )
                                .id("activity-status")
                                .transition(.opacity)
                            }
```

**Step 3: Update the scroll-to-bottom logic to also trigger on activity state changes**

Add an `.onChange` for activity state near the existing `.onChange(of: items.count)`:

```swift
                .onChange(of: webSocketManager.activityState?.state) { _, _ in
                    if let activity = webSocketManager.activityState, activity.state != "idle" {
                        withAnimation {
                            proxy.scrollTo("activity-status", anchor: .bottom)
                        }
                    }
                }
```

**Step 4: Build and verify**

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```

**CHECKPOINT:** Build must succeed. No automated test here since the status indicator requires a live server connection to verify. Manual verification:
1. Connect iOS app to running server
2. Open a session and send a message
3. Verify spinner + status text appears below messages while Claude is working
4. Verify stop button is visible and tappable
5. Verify status disappears when Claude finishes

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: add activity status indicator with interrupt button to session view"
```

---

### Task 7: Integration Verification

**Step 1: Run all server tests**

```bash
cd voice_server/tests && ./run_tests.sh
```

All tests must pass.

**Step 2: Build iOS app**

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```

Must build clean.

**Step 3: Reinstall server and test end-to-end**

```bash
pipx install --force /Users/aaron/Desktop/max
```

Start server, connect iOS app, open a session, send a prompt, verify:
- Status indicator appears during thinking
- Status indicator shows tool activity detail
- Status indicator disappears when idle
- Stop button interrupts Claude

**CHECKPOINT:** All of the above must work before considering this complete.
