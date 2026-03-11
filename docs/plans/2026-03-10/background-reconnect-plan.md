# Background Reconnect Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Silently reconnect WebSocket and resync messages when iOS app returns to foreground after being backgrounded.

**Architecture:** Add `scenePhase` observer in `ClaudeVoiceApp` that calls `WebSocketManager.reconnectIfNeeded()` on `.active` transition. The reconnect uses a separate retry policy (3 attempts, 1s fixed interval) from the existing exponential backoff. On successful reconnect, auto-resync to catch missed messages.

**Tech Stack:** SwiftUI (`@Environment(\.scenePhase)`), URLSession WebSocket

**Risky Assumptions:** `currentURL` survives iOS backgrounding (it should — only `disconnect()` clears it, and iOS background doesn't call `disconnect()`). Verified early in Task 1 tests.

---

### Task 1: Add `reconnectIfNeeded()` with unit tests (TDD)

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift`

**Step 1: Write failing tests**

Add these tests to `WebSocketManagerTests.swift`, after the existing `testDisconnectStatePersistsAfterCallbacks` test:

```swift
// MARK: - Foreground Reconnect Tests

@Test func reconnectIfNeededSkipsWhenConnected() {
    let manager = WebSocketManager()
    manager.connectionState = .connected

    manager.reconnectIfNeeded()

    #expect(manager.connectionState == .connected)
    #expect(manager.isReconnecting == false)
}

@Test func reconnectIfNeededSkipsWhenConnecting() {
    let manager = WebSocketManager()
    manager.connectionState = .connecting

    manager.reconnectIfNeeded()

    #expect(manager.connectionState == .connecting)
    #expect(manager.isReconnecting == false)
}

@Test func reconnectIfNeededSkipsWhenNoURL() {
    let manager = WebSocketManager()
    manager.connectionState = .disconnected

    manager.reconnectIfNeeded()

    // No currentURL stored, so nothing to reconnect to
    #expect(manager.isReconnecting == false)
}

@Test func reconnectIfNeededStartsWhenDisconnectedWithURL() {
    let manager = WebSocketManager()
    // Simulate a previous connection that stored the URL
    manager.connect(url: "ws://192.168.1.1:8765")
    // The connect sets currentURL internally via connectToURL
    // Now simulate iOS killing the connection (sets disconnected without clearing URL)
    manager.connectionState = .disconnected

    manager.reconnectIfNeeded()

    #expect(manager.isReconnecting == true)
    #expect(manager.connectionState == .connecting)
}

@Test func reconnectIfNeededStartsWhenErrorWithURL() {
    let manager = WebSocketManager()
    manager.connect(url: "ws://192.168.1.1:8765")
    manager.connectionState = .error("Connection lost")

    manager.reconnectIfNeeded()

    #expect(manager.isReconnecting == true)
    #expect(manager.connectionState == .connecting)
}

@Test func reconnectIfNeededSkipsAfterExplicitDisconnect() {
    let manager = WebSocketManager()
    manager.connect(url: "ws://192.168.1.1:8765")
    manager.disconnect()  // Clears currentURL

    manager.reconnectIfNeeded()

    // disconnect() cleared the URL, so nothing to reconnect to
    #expect(manager.isReconnecting == false)
    #expect(manager.connectionState == .disconnected)
}
```

**Step 2: Run tests to verify they fail**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/WebSocketManagerTests 2>&1 | tail -30
```

Expected: Compilation error — `reconnectIfNeeded()` and `isReconnecting` don't exist yet.

**Step 3: Implement `reconnectIfNeeded()` and supporting properties**

In `WebSocketManager.swift`, add the `isReconnecting` property alongside the other private vars (after line 74, near `shouldReconnect`):

```swift
var isReconnecting = false
```

Note: `internal` access (not `private`) so tests can read it.

Add the `reconnectIfNeeded()` method after the existing `disconnect()` method (after line 205):

```swift
func reconnectIfNeeded() {
    switch connectionState {
    case .connected, .connecting:
        return
    default:
        break
    }

    guard currentURL != nil else { return }

    isReconnecting = true
    shouldReconnect = true
    reconnectAttempts = 0
    connectToURL(currentURL!)
}
```

**Step 4: Run tests to verify they pass**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/WebSocketManagerTests 2>&1 | tail -30
```

Expected: All WebSocketManagerTests pass.

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift
git commit -m "feat: add reconnectIfNeeded() for foreground reconnect"
```

---

### Task 2: Modify reconnect retry behavior and auto-resync

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift`

**Step 1: Write failing tests for foreground retry policy**

Add to `WebSocketManagerTests.swift`:

```swift
@Test func foregroundReconnectUsesThreeMaxRetries() {
    let manager = WebSocketManager()
    manager.connect(url: "ws://192.168.1.1:8765")
    manager.connectionState = .disconnected

    manager.reconnectIfNeeded()

    #expect(manager.isReconnecting == true)
    // The foreground path should use 3 max retries, not the default 5
    #expect(manager.foregroundMaxRetries == 3)
}

@Test func foregroundReconnectResetsOnSuccess() {
    let manager = WebSocketManager()
    manager.isReconnecting = true

    // Simulate successful connection (what didOpenWithProtocol does)
    manager.connectionState = .connected
    // The didOpen handler should reset isReconnecting
    // We can't call the delegate directly, so test the state management
    manager.handleDidOpen()

    #expect(manager.isReconnecting == false)
}
```

**Step 2: Run tests to verify they fail**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/WebSocketManagerTests 2>&1 | tail -30
```

Expected: Compilation error — `foregroundMaxRetries` and `handleDidOpen()` don't exist.

**Step 3: Implement foreground retry behavior**

In `WebSocketManager.swift`:

1. Add property after `isReconnecting` (near line 75):

```swift
private(set) var foregroundMaxRetries = 3
```

2. Modify `attemptReconnect()` to use foreground-specific retry params when `isReconnecting`:

Replace the existing `attemptReconnect()` method with:

```swift
private func attemptReconnect() {
    let maxAttempts = isReconnecting ? foregroundMaxRetries : maxReconnectAttempts
    guard shouldReconnect, reconnectAttempts < maxAttempts else {
        if isReconnecting {
            connectionState = .error("Server unreachable")
            isReconnecting = false
        } else {
            connectionState = .disconnected
        }
        return
    }

    // Validate URLSession is still valid before attempting reconnect
    guard urlSession != nil else {
        connectionState = .error("Cannot reconnect: URLSession invalidated")
        shouldReconnect = false
        isReconnecting = false
        return
    }

    reconnectAttempts += 1
    let delay = isReconnecting ? 1.0 : min(pow(2.0, Double(reconnectAttempts)), 30.0)

    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
        guard let self = self, self.shouldReconnect else { return }

        // Double-check URLSession is still valid after delay
        guard self.urlSession != nil else {
            self.connectionState = .error("Cannot reconnect: URLSession invalidated")
            self.shouldReconnect = false
            self.isReconnecting = false
            return
        }

        guard let url = self.currentURL else {
            self.connectionState = .error("Cannot reconnect: no previous connection")
            self.isReconnecting = false
            return
        }

        self.connectToURL(url)
    }
}
```

3. Extract a `handleDidOpen()` method from the delegate and modify `didOpenWithProtocol` to call it:

Add this method in the MARK: - Session Management section area (before the delegate extension):

```swift
func handleDidOpen() {
    connectionState = .connected
    outputState = .idle
    activityState = nil
    reconnectAttempts = 0

    if isReconnecting {
        isReconnecting = false
        requestResync()
    }
}
```

4. Update `didOpenWithProtocol` to use the extracted method:

```swift
func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
    print("✅ WEBSOCKET CONNECTED")
    logToFile("🔌 connectionState: \(connectionState) → .connected (didOpen)")
    // Already on main thread due to delegateQueue: .main
    handleDidOpen()
}
```

**Step 4: Run tests to verify they pass**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/WebSocketManagerTests 2>&1 | tail -30
```

Expected: All tests pass.

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift
git commit -m "feat: foreground reconnect uses 3 retries at 1s interval with auto-resync"
```

---

### Task 3: Wire up scenePhase in ClaudeVoiceApp

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/ClaudeVoiceApp.swift`

**Step 1: Add scenePhase observer**

Replace the entire `ClaudeVoiceApp.swift` content with:

```swift
import SwiftUI

@main
struct ClaudeVoiceApp: App {
    @StateObject private var webSocketManager = WebSocketManager()
    @AppStorage("serverIP") private var serverIP = ""
    @AppStorage("serverPort") private var serverPort = 8765
    @Environment(\.scenePhase) private var scenePhase

    // For E2E tests: environment variables override saved settings
    private var effectiveServerIP: String {
        ProcessInfo.processInfo.environment["SERVER_HOST"] ?? serverIP
    }
    private var effectiveServerPort: Int {
        if let portStr = ProcessInfo.processInfo.environment["SERVER_PORT"],
           let port = Int(portStr) {
            return port
        }
        return serverPort
    }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ProjectsListView(webSocketManager: webSocketManager)
            }
            .onAppear {
                // Auto-connect if we have settings and not already connected
                // Environment variables (for E2E tests) override saved settings
                if !effectiveServerIP.isEmpty && webSocketManager.connectionState == .disconnected {
                    webSocketManager.connect(host: effectiveServerIP, port: effectiveServerPort)
                }
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    webSocketManager.reconnectIfNeeded()
                }
            }
        }
    }
}
```

**Step 2: Build to verify compilation**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED

**Step 3: Run all iOS unit tests to verify no regressions**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests 2>&1 | tail -30
```

Expected: All tests pass.

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/ClaudeVoiceApp.swift
git commit -m "feat: auto-reconnect WebSocket on app foreground via scenePhase"
```

**Step 5: Verify it actually works**

**Automated tests:** None for the scenePhase wiring (requires real app lifecycle).

**Manual verification (REQUIRED before merge):**
1. Build and install app on device
2. Connect to the voice server
3. Verify connection is established (shows "Connected" in Settings)
4. Switch to another app (e.g., Safari) for ~30 seconds
5. Switch back to ClaudeVoice
6. If connection survived: nothing should change, app works normally
7. If connection died: app should silently reconnect within ~3 seconds
8. Send a voice message to verify the connection is functional
9. Test the failure case: stop the server, background the app, come back — should show error state after ~3 seconds

**CHECKPOINT:** Must pass manual verification.
