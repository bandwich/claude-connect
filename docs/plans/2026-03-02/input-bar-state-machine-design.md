# Input Bar State Machine Design

## Problem

The app's input handling has multiple independent state variables (`outputState`, `voiceState`, `isRecording`, `isSyncing`, `canRecord`, `canSend`) that can get out of sync, causing the mic and send buttons to become permanently disabled. Permission prompts appear as inline messages in the scroll view rather than replacing the input area, which doesn't match the terminal UX and creates confusion when input is silently disabled.

## Design

### Single Input Bar Mode

The bottom input area is driven by one enum:

```swift
enum InputBarMode {
    case normal                                // text field + mic + send
    case permissionPrompt(PermissionRequest)   // approve/deny/cancel
    case questionPrompt(PermissionRequest)     // options or text + cancel
    case disconnected                          // connection status
}
```

Transition rules:

- `permission_request` arrives with `prompt_type != "question"` → `.permissionPrompt(request)`
- `permission_request` arrives with `prompt_type == "question"` → `.questionPrompt(request)`
- User approves/denies/cancels a prompt → `.normal`
- `permission_resolved` from server → `.normal`
- WebSocket disconnects → `.disconnected`
- WebSocket reconnects + session synced → `.normal`

### Input Bar Content Per Mode

**`.normal`**: Current input bar — text field, mic button, send button (conditional). `ActivityStatusView` with stop button continues to appear independently when Claude is working.

**`.permissionPrompt`**: Replaces input bar with:
- Compact summary of the request (command text, file path, diff preview)
- Action buttons: numbered approve options + Deny + Cancel
- Cancel sends deny response + Escape to tmux (matches terminal Escape behavior)

**`.questionPrompt`**: Replaces input bar with:
- Question text
- If options provided: tappable option buttons + Cancel
- If no options: text field + Send + Cancel
- Cancel sends dismiss + Escape to tmux

**`.disconnected`**: Shows connection status / syncing indicator.

### Resolved Prompt History

After a prompt is resolved (approved/denied/cancelled), a compact summary line is added to the conversation scroll — e.g., "Approved: bash ls -la" or "Denied: edit file.swift". No full interactive card, just a record.

### What Gets Removed

- `canRecord` and `canSend` computed properties — replaced by `InputBarMode`. If mode is `.normal` and connected, input is enabled.
- `outputState` cases `.awaitingPermission` and `.awaitingQuestion` — `InputBarMode` handles this.
- Inline `ConversationItem.permissionPrompt` interactive cards in the scroll view — prompts only live in the input bar. Replaced by compact resolved-status lines after resolution.
- The scattered state checks that cause stuck input.

### What Stays

- `ActivityStatusView` with stop/interrupt button — already works, independent of input bar mode.
- `voiceState` for listening/speaking display indicator.
- `isRecording` on `SpeechRecognizer` for mic toggle.
- Audio playback callbacks for TTS.
- `outputState` simplified to just `.idle`, `.thinking`, `.usingTool`, `.speaking` for display purposes (no longer gates input).

### Safety Nets

- **`isSyncing` timeout**: If no server response within 10 seconds, auto-reset `isSyncing = false` and retry sync. Prevents permanent stuck state.
- **Prompt timeout**: If `InputBarMode` stays in a prompt state for 3 minutes with no resolution, auto-reset to `.normal`. Matches the server-side 180s hook timeout.
- **Reconnect reset**: On WebSocket reconnect, `InputBarMode` resets to `.disconnected` then `.normal` after sync, clearing any stale prompt state.

### Cancel Behavior (Matching Terminal Escape)

Cancelling any prompt:
1. Sends deny/dismiss response via WebSocket
2. Sends interrupt (Escape) to tmux via `sendInterrupt()`
3. Resets `InputBarMode` to `.normal`

This matches the terminal where pressing Escape during a permission prompt cancels it and returns to the input line.
