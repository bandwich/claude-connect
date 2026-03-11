# Background Reconnect Design

## Problem

Backgrounding the iOS app causes iOS to suspend the process, killing the WebSocket connection. When the user returns, the app is disconnected with no automatic recovery.

## Design

Silent reconnect + resync on foreground. No visible UI indicator unless reconnect fails.

### Behavior

1. **App enters foreground** — check if WebSocket is still connected
2. **If connected** — do nothing (quick background trips survive)
3. **If disconnected** — reconnect silently using stored server URL
4. **Retry policy** — 3 attempts, 1 second apart, fixed interval (not exponential)
5. **If all retries fail** — show `.error` connection state
6. **On successful reconnect** — auto-resync to catch missed messages (no UI indicator)
7. **Permission/question prompts** — left as-is; server sends resolved messages naturally

### Changes

#### `ClaudeVoiceApp.swift`

Add `@Environment(\.scenePhase)` observer. On transition to `.active`, call `webSocketManager.reconnectIfNeeded()`.

#### `WebSocketManager.swift`

New method `reconnectIfNeeded()`:
- Guard: skip if `.connected` or `.connecting`
- Use `connectedURL` to reconnect (already stored on successful connect)
- Set retry parameters: max 3 attempts, 1-second fixed delay
- Set `isReconnecting = true` flag

Modify `didOpenWithProtocol` delegate:
- If `isReconnecting` is true, call `requestResync()` and reset the flag
- Initial connects do not auto-resync (session history load handles that)

### Edge Cases

- **Quick background trips**: connection survives, no reconnect needed
- **Server down**: 3 retries fail in ~3 seconds, error state shown
- **Rapid foreground cycles**: guarded by `.connecting` state check
- **Foreground vs initial connect**: `isReconnecting` flag distinguishes them
