# VSCode Removal Design

Replace VSCode terminal integration with tmux for headless Claude Code control.

## Architecture

```
Before:
iPhone → WebSocket → Server → VSCode Extension (WS:3710) → Terminal → Claude CLI
                              ↓ (fallback)
                              AppleScript → Terminal

After:
iPhone → WebSocket → Server → tmux subprocess calls → Claude CLI
```

## Decisions

| Decision | Choice |
|----------|--------|
| Naming | Generic: `connected`, `ConnectionStatus`, "Not connected" |
| Migration | Clean replacement, no VSCode fallback |
| Session lifecycle | One tmux session at a time, kill before starting new |
| Connection status | `connected` = tmux session active with no errors |
| tmux session name | `claude_voice` (fixed name) |

## TmuxController Interface

```python
class TmuxController:
    SESSION_NAME = "claude_voice"

    def is_available(self) -> bool:
        """Check if tmux is installed"""

    def session_exists(self) -> bool:
        """Check if claude_voice session is running"""

    def start_session(self, working_dir: str = None, resume_id: str = None) -> bool:
        """Start new tmux session running claude

        - Kills existing session first (one-at-a-time)
        - working_dir: set session working directory
        - resume_id: if set, runs 'claude --resume <id>'
        """

    def send_input(self, text: str) -> bool:
        """Send text + Enter to the session"""

    def kill_session(self) -> bool:
        """Kill the active session"""
```

## Server Changes (ios_server.py)

| Current | After |
|---------|-------|
| `vscode_controller.connect()` | Remove - no persistent connection |
| `vscode_controller.is_connected()` | `tmux.session_exists()` |
| `vscode_controller.send_sequence(text)` | `tmux.send_input(text)` |
| `vscode_controller.new_terminal()` | Absorbed into `start_session()` |
| `vscode_controller.kill_terminal()` | `tmux.kill_session()` |
| `vscode_controller.open_folder()` | Absorbed into `start_session(working_dir=)` |

**Remove entirely:**
- `send_to_vs_code_applescript()` - no fallback needed
- VSCode WebSocket connection logic in `start()`

## iOS Changes

**Model (Session.swift):**
```swift
// Before
struct VSCodeStatus: Codable {
    let vscodeConnected: Bool
    let activeSessionId: String?
}

// After
struct ConnectionStatus: Codable {
    let connected: Bool
    let activeSessionId: String?
}
```

**Property renames:**
- `vscodeConnected` → `connected`
- `onVSCodeStatusReceived` → `onConnectionStatusReceived`
- Error: "VSCode not connected" → "Not connected"

**Server JSON:**
```python
# Before
{"type": "vscode_status", "vscode_connected": true, ...}

# After
{"type": "connection_status", "connected": true, ...}
```

## Files Changed

**Delete:**
- `voice_server/vscode_controller.py`
- `voice_server/tests/test_vscode_controller.py`

**Create:**
- `voice_server/tmux_controller.py`
- `voice_server/tests/test_tmux_controller.py`

**Modify - Server:**
- `voice_server/ios_server.py`
- `voice_server/tests/test_ios_server.py`
- `voice_server/tests/test_message_handlers.py`
- `voice_server/tests/test_state_validation.py`

**Modify - iOS:**
- `ClaudeVoice/Models/Session.swift`
- `ClaudeVoice/Services/WebSocketManager.swift`
- `ClaudeVoice/Views/SessionView.swift`
- `ClaudeVoiceTests/ClaudeVoiceTests.swift`
- `ClaudeVoiceTests/WebSocketManagerTests.swift`

**Modify - E2E Tests:**
- `ClaudeVoiceUITests/E2EVSCodeFlowTests.swift` → rename to `E2ESessionFlowTests.swift`

**Modify - Docs:**
- `CLAUDE.md`
- `README.md`

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| Claude Code needs TTY | tmux provides full PTY - should work. Test early. |
| Permission hooks behave differently | Hooks are Claude Code feature, not terminal. Unchanged. |
| tmux not installed | Check at startup, log clear error message |
| Timing issues | Add delay after `start_session` before sending input |

## Pre-Implementation Test

Verify Claude Code works in detached tmux before starting:

```bash
# Note: send-keys text and Enter must be separate calls
tmux new-session -d -s test "claude"
sleep 2
tmux send-keys -t test "hello" && tmux send-keys -t test Enter
tmux capture-pane -t test -p  # verify it worked
tmux kill-session -t test
```
