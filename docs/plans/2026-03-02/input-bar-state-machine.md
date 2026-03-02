# Input Bar State Machine Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Replace the scattered input bar state management (canRecord, canSend, outputState gating, inline permission cards) with a single `InputBarMode` enum that drives the entire input area, fixing the "stuck input" bug.

**Architecture:** A new `InputBarMode` enum becomes the single source of truth for what the input bar displays. WebSocketManager owns the mode and transitions it on permission_request/resolved/disconnect/reconnect events. SessionView switches on the mode to render either the normal text+mic input, a permission/question prompt, or a disconnected state. Permission prompts move from inline conversation items to the input bar area. Resolved prompts become compact summary lines in the conversation.

**Tech Stack:** Swift/SwiftUI (iOS app only — no server changes)

**Risky Assumptions:**
- Removing `canSendVoiceInput` gating from `ClaudeOutputState` won't break anything — we verify by checking that `InputBarMode.normal` only allows input when appropriate.
- Moving permission prompts out of the conversation scroll won't confuse users — the resolved summary lines preserve history.

---

### Task 1: Create InputBarMode enum with unit tests

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/InputBarMode.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/InputBarModeTests.swift`

**Step 1: Write the failing test**

Create `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/InputBarModeTests.swift`:

```swift
import Testing
@testable import ClaudeVoice

@Suite("InputBarMode Tests")
struct InputBarModeTests {

    @Test func normalModeAllowsInput() {
        let mode = InputBarMode.normal
        #expect(mode.allowsTextInput == true)
        #expect(mode.allowsMicInput == true)
        #expect(mode.showsPrompt == false)
    }

    @Test func permissionPromptBlocksInput() {
        let request = PermissionRequest(
            type: "permission_request",
            requestId: "test-1",
            promptType: .bash,
            toolName: "Bash",
            toolInput: ToolInput(command: "ls"),
            context: nil,
            question: nil,
            permissionSuggestions: nil,
            timestamp: 0
        )
        let mode = InputBarMode.permissionPrompt(request)
        #expect(mode.allowsTextInput == false)
        #expect(mode.allowsMicInput == false)
        #expect(mode.showsPrompt == true)
    }

    @Test func questionPromptBlocksInput() {
        let request = PermissionRequest(
            type: "permission_request",
            requestId: "test-2",
            promptType: .question,
            toolName: "AskUserQuestion",
            toolInput: nil,
            context: nil,
            question: PermissionQuestion(text: "Which option?", options: ["A", "B"]),
            permissionSuggestions: nil,
            timestamp: 0
        )
        let mode = InputBarMode.questionPrompt(request)
        #expect(mode.allowsTextInput == false)
        #expect(mode.allowsMicInput == false)
        #expect(mode.showsPrompt == true)
    }

    @Test func disconnectedBlocksInput() {
        let mode = InputBarMode.disconnected
        #expect(mode.allowsTextInput == false)
        #expect(mode.allowsMicInput == false)
        #expect(mode.showsPrompt == false)
    }

    @Test func syncingBlocksInput() {
        let mode = InputBarMode.syncing
        #expect(mode.allowsTextInput == false)
        #expect(mode.allowsMicInput == false)
        #expect(mode.showsPrompt == false)
    }
}
```

**Step 2: Clean build (required — new files added)**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild clean -target ClaudeVoice`

**Step 3: Run test to verify it fails**

Run: `xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/InputBarModeTests 2>&1 | tail -20`
Expected: FAIL — `InputBarMode` type not found

**Step 4: Write minimal implementation**

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/InputBarMode.swift`:

```swift
import Foundation

enum InputBarMode: Equatable {
    case normal
    case permissionPrompt(PermissionRequest)
    case questionPrompt(PermissionRequest)
    case syncing
    case disconnected

    var allowsTextInput: Bool {
        if case .normal = self { return true }
        return false
    }

    var allowsMicInput: Bool {
        if case .normal = self { return true }
        return false
    }

    var showsPrompt: Bool {
        switch self {
        case .permissionPrompt, .questionPrompt:
            return true
        default:
            return false
        }
    }
}
```

**Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/InputBarModeTests 2>&1 | tail -20`
Expected: PASS — all 5 tests green

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/InputBarMode.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/InputBarModeTests.swift
git commit -m "feat: add InputBarMode enum for input bar state machine"
```

---

### Task 2: Wire InputBarMode into WebSocketManager

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift` (add tests)

**Step 1: Write the failing tests**

Add to `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift` (or create if needed):

```swift
@Test func inputBarModeStartsNormal() {
    let manager = WebSocketManager()
    #expect(manager.inputBarMode == .normal)
}

@Test func inputBarModeTransitionsToPermissionOnRequest() {
    let manager = WebSocketManager()
    let request = PermissionRequest(
        type: "permission_request",
        requestId: "req-1",
        promptType: .bash,
        toolName: "Bash",
        toolInput: ToolInput(command: "ls"),
        context: nil,
        question: nil,
        permissionSuggestions: nil,
        timestamp: 0
    )
    manager.handleInputBarPermission(request)
    #expect(manager.inputBarMode == .permissionPrompt(request))
}

@Test func inputBarModeTransitionsToQuestionOnQuestionRequest() {
    let manager = WebSocketManager()
    let request = PermissionRequest(
        type: "permission_request",
        requestId: "req-2",
        promptType: .question,
        toolName: "AskUserQuestion",
        toolInput: nil,
        context: nil,
        question: PermissionQuestion(text: "Pick one", options: ["A"]),
        permissionSuggestions: nil,
        timestamp: 0
    )
    manager.handleInputBarPermission(request)
    #expect(manager.inputBarMode == .questionPrompt(request))
}

@Test func inputBarModeResetsToNormalOnResolution() {
    let manager = WebSocketManager()
    let request = PermissionRequest(
        type: "permission_request",
        requestId: "req-3",
        promptType: .bash,
        toolName: "Bash",
        toolInput: ToolInput(command: "ls"),
        context: nil,
        question: nil,
        permissionSuggestions: nil,
        timestamp: 0
    )
    manager.handleInputBarPermission(request)
    manager.handleInputBarResolved()
    #expect(manager.inputBarMode == .normal)
}

@Test func inputBarModeTransitionsToDisconnected() {
    let manager = WebSocketManager()
    manager.handleInputBarDisconnected()
    #expect(manager.inputBarMode == .disconnected)
}
```

**Step 2: Clean build (required if new test file added)**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild clean -target ClaudeVoice`

**Step 3: Run tests to verify they fail**

Run: `xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/WebSocketManagerTests 2>&1 | tail -30`
Expected: FAIL — `inputBarMode` and `handleInputBar*` methods not found

**Step 4: Add InputBarMode property and transition methods to WebSocketManager**

In `WebSocketManager.swift`, add the published property near the other `@Published` properties (around line 29):

```swift
@Published var inputBarMode: InputBarMode = .normal
```

Add transition methods (after `sendPermissionResponse` around line 380):

```swift
// MARK: - Input bar state transitions

func handleInputBarPermission(_ request: PermissionRequest) {
    if request.promptType == .question {
        inputBarMode = .questionPrompt(request)
    } else {
        inputBarMode = .permissionPrompt(request)
    }
}

func handleInputBarResolved() {
    inputBarMode = .normal
}

func handleInputBarDisconnected() {
    inputBarMode = .disconnected
}

func handleInputBarSyncing() {
    inputBarMode = .syncing
}

func handleInputBarSynced() {
    inputBarMode = .normal
}
```

**Step 5: Wire transitions into existing WebSocket message handlers**

In `handlePermissionRequest` (where `pendingPermission` is set), add:

```swift
self.handleInputBarPermission(permissionRequest)
```

In `handlePermissionResolved` (where `pendingPermission` is nil'd), add:

```swift
self.handleInputBarResolved()
```

In `sendPermissionResponse` (where `pendingPermission = nil` and `outputState = .idle`), add:

```swift
self.handleInputBarResolved()
```

In the connection lost handler, add:

```swift
self.handleInputBarDisconnected()
```

In the connection established handler (around line 738 where `outputState = .idle`), add:

```swift
// Don't go straight to normal — SessionView will set syncing/normal after sync
```

**Step 6: Run tests to verify they pass**

Run: `xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/WebSocketManagerTests 2>&1 | tail -30`
Expected: PASS

**Step 7: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift
git commit -m "feat: wire InputBarMode transitions into WebSocketManager"
```

---

### Task 3: Refactor SessionView input bar to switch on InputBarMode

This is the core UI change. The input bar area becomes a `switch` on `webSocketManager.inputBarMode`.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Replace the input bar conditional chain**

Currently (lines 103-208), the input bar has a three-way conditional:
1. `syncError` → error view
2. `!isSessionSynced && !session.isNewSession` → progress spinner
3. `else` → text input + buttons

Replace with a switch on `webSocketManager.inputBarMode`:

```swift
// Input bar
VStack(spacing: 0) {
    if let error = syncError {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.red)
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
        }
        .frame(height: 100)
        .frame(maxWidth: .infinity)
        .accessibilityIdentifier("syncError")
    } else {
        switch webSocketManager.inputBarMode {
        case .disconnected, .syncing:
            VStack(spacing: 8) {
                ProgressView()
            }
            .frame(height: 100)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("syncStatus")

        case .permissionPrompt(let request):
            PermissionCardView(
                request: request,
                resolved: nil,
                onResponse: { response in
                    handlePermissionResponse(response, for: request)
                }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

        case .questionPrompt(let request):
            PermissionCardView(
                request: request,
                resolved: nil,
                onResponse: { response in
                    handlePermissionResponse(response, for: request)
                }
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

        case .normal:
            normalInputBar
        }
    }
}
.background(Color(.systemBackground))
```

**Step 2: Extract normal input bar to a computed property**

Move the existing image preview + text field + buttons code into:

```swift
@ViewBuilder
private var normalInputBar: some View {
    VStack(spacing: 0) {
        // Image previews (existing code)
        if !attachedImages.isEmpty {
            // ... existing image preview scroll view ...
        }

        // Input area with text field and buttons
        HStack(alignment: .bottom, spacing: 8) {
            // Image picker button
            Button { showingPhotoPicker = true } label: {
                Image(systemName: "photo")
                    .font(.system(size: 20))
                    .foregroundColor(.secondary)
                    .frame(width: 36, height: 36)
            }
            .disabled(speechRecognizer.isRecording)
            .accessibilityIdentifier("imagePickerButton")

            // Text field
            TextField("Message Claude...", text: $messageText, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.systemGray6))
                .cornerRadius(20)
                .disabled(speechRecognizer.isRecording)
                .focused($isTextFieldFocused)
                .accessibilityIdentifier("messageTextField")

            // Mic button
            Button(action: toggleRecording) {
                Image(systemName: speechRecognizer.isRecording ? "stop.fill" : "mic.fill")
                    .font(.system(size: 20))
                    .foregroundColor(speechRecognizer.isRecording ? .red : .secondary)
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel(speechRecognizer.isRecording ? "Stop" : "Tap to Talk")
            .disabled(!speechRecognizer.isRecording && !canRecord)
            .accessibilityIdentifier("micButton")

            // Send button
            if !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachedImages.isEmpty {
                Button(action: sendTextMessage) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(canSend ? .blue : .gray)
                }
                .disabled(!canSend)
                .accessibilityLabel("Send")
                .accessibilityIdentifier("sendButton")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
```

**Step 3: Simplify canRecord and canSend**

Replace the current `canRecord` and `canSend` (which check `outputState.canSendVoiceInput`) to only check connection + auth:

```swift
private var canRecord: Bool {
    guard case .connected = webSocketManager.connectionState else { return false }
    return speechRecognizer.isAuthorized
}

private var canSend: Bool {
    guard case .connected = webSocketManager.connectionState else { return false }
    let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    return hasText || !attachedImages.isEmpty
}
```

The `inputBarMode` switch already ensures these computed properties are only evaluated when we're in `.normal` mode — so `outputState` gating is no longer needed here.

**Step 4: Update setupView to set inputBarMode for syncing**

In `setupView()`, after the existing sync logic, set syncing mode:

```swift
// In setupView(), when starting sync for non-new sessions:
if !session.isNewSession {
    webSocketManager.handleInputBarSyncing()
    // ... existing code ...
}
```

In `syncSession()`, on success callback:

```swift
if response.success {
    webSocketManager.handleInputBarSynced()
    // ...existing...
}
```

In the `onChange(of: webSocketManager.connectionState)` handler, when connection drops:

```swift
// Already handled by WebSocketManager setting .disconnected
```

**Step 5: Update permission prompt handling**

Remove the `onChange(of: webSocketManager.pendingPermission)` handler that adds inline permission cards to `items`. The `InputBarMode` transition in WebSocketManager now handles showing prompts in the input bar.

Keep the `handlePermissionResponse` method but update it to also add a resolved summary to the conversation:

```swift
private func handlePermissionResponse(_ response: PermissionResponse, for request: PermissionRequest) {
    let allowed = response.decision == .allow
    let summary = "\(allowed ? "Allowed" : "Denied"): \(permissionDescription(for: request))"

    // Add compact resolved summary to conversation
    let resolvedMessage = SessionHistoryMessage(
        role: "system",
        content: summary,
        timestamp: Date().timeIntervalSince1970
    )
    items.append(.textMessage(resolvedMessage))

    // Send response (this also resets inputBarMode to .normal via WebSocketManager)
    webSocketManager.sendPermissionResponse(response)
}
```

**Step 6: Build to verify compilation**

Run: `xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: refactor input bar to switch on InputBarMode"
```

**CHECKPOINT:** Build + install on device. Open a session. Verify:
1. Normal input bar appears (text field + mic + send)
2. Trigger a permission prompt (e.g., run a bash command) — prompt should appear in input bar area
3. Approve/deny — input bar returns to normal, resolved summary appears in conversation
4. Disconnect WiFi — input bar shows syncing/disconnected state
5. Reconnect — input bar returns to normal after sync

---

### Task 4: Remove inline permission cards from conversation

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Remove `permissionPrompt` case from ConversationItem**

In `Session.swift`, remove the case and its id:

```swift
enum ConversationItem: Identifiable {
    case textMessage(SessionHistoryMessage)
    case toolUse(toolId: String, tool: ToolUseBlock, result: ToolResultBlock?)

    var id: String {
        switch self {
        case .textMessage(let msg):
            return "text-\(msg.timestamp)"
        case .toolUse(let toolId, _, _):
            return "tool-\(toolId)"
        }
    }
}
```

**Step 2: Remove permission-related state and handlers from SessionView**

Remove from SessionView:
- `@State private var permissionResolutions: [String: PermissionCardResolution] = [:]`
- The `.permissionPrompt` case in the `ForEach` switch
- The `onChange(of: webSocketManager.pendingPermission)` handler (already done in Task 3)
- The `onPermissionResolved` handler in `setupView()` (terminal-resolved permissions are now handled by WebSocketManager's `handleInputBarResolved()`)

**Step 3: Remove the `PermissionCardResolution` struct**

In `PermissionCardView.swift`, remove `PermissionCardResolution` (line 250-253). Also remove the `resolved` parameter from `PermissionCardView` — the resolved state is no longer shown in the card (it's a conversation summary line now). Update `PermissionCardView` to only show the pending view:

```swift
struct PermissionCardView: View {
    let request: PermissionRequest
    let onResponse: (PermissionResponse) -> Void

    var body: some View {
        pendingView
    }

    // ... keep pendingView, typeLabel, contentBlock, optionsBlock, etc.
    // Remove resolvedView and the resolved parameter
}
```

**Step 4: Update PermissionCardView previews**

Remove the `resolved` parameter from preview invocations.

**Step 5: Build to verify compilation**

Run: `xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionCardView.swift
git commit -m "refactor: remove inline permission cards from conversation scroll"
```

---

### Task 5: Add safety nets (timeouts and reconnect reset)

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/InputBarModeTests.swift` (add timeout tests)

**Step 1: Add prompt timeout to SessionView**

When `inputBarMode` changes to a prompt state, start a 180-second timer. If still in prompt state when timer fires, auto-reset to normal:

```swift
// In SessionView, add:
@State private var promptTimeoutTask: Task<Void, Never>? = nil

// In body or onChange, watch inputBarMode:
.onChange(of: webSocketManager.inputBarMode) { _, newMode in
    promptTimeoutTask?.cancel()
    if newMode.showsPrompt {
        promptTimeoutTask = Task {
            try? await Task.sleep(for: .seconds(180))
            if !Task.isCancelled && webSocketManager.inputBarMode.showsPrompt {
                webSocketManager.handleInputBarResolved()
            }
        }
    }
}
```

**Step 2: Add sync timeout to SessionView**

In `syncSession()`, add a timeout that resets syncing state after 10 seconds:

```swift
// After sending the resume request:
Task {
    try? await Task.sleep(for: .seconds(10))
    if isSyncing {
        isSyncing = false
        // Retry sync
        syncSession()
    }
}
```

**Step 3: Ensure reconnect resets inputBarMode**

In WebSocketManager, in the disconnect handler (where `connected = false` is set), ensure:

```swift
inputBarMode = .disconnected
```

In the reconnect/connection established handler, do NOT set `.normal` — let SessionView's sync flow handle the transition from `.disconnected` → `.syncing` → `.normal`.

**Step 4: Build and verify**

Run: `xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: add safety net timeouts for prompt and sync states"
```

**CHECKPOINT:** Build + install on device. Verify:
1. Permission prompt that goes unanswered for 3 minutes auto-resets input bar to normal
2. Syncing state that takes >10s retries automatically
3. Disconnecting and reconnecting properly cycles through disconnected → syncing → normal

---

### Task 6: Clean up dead code and fix stale tests

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ClaudeOutputState.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeOutputStateTests.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

**Step 1: Remove permission cases from ClaudeOutputState**

`ClaudeOutputState` no longer needs `.awaitingPermission` and `.awaitingQuestion` — `InputBarMode` handles that. Remove them:

```swift
enum ClaudeOutputState: Equatable {
    case idle
    case thinking
    case usingTool(String)
    case speaking
}
```

Remove `canSendVoiceInput` and `expectsPermissionResponse` computed properties — no longer used.

Keep `statusText` for the activity status display.

**Step 2: Update ClaudeOutputState tests**

Replace `ClaudeOutputStateTests.swift` to match the simplified enum:

```swift
import Testing
@testable import ClaudeVoice

@Suite("ClaudeOutputState Tests")
struct ClaudeOutputStateTests {

    @Test func idleHasNoStatusText() {
        #expect(ClaudeOutputState.idle.statusText == nil)
    }

    @Test func thinkingShowsStatusText() {
        #expect(ClaudeOutputState.thinking.statusText == "Thinking...")
    }

    @Test func usingToolShowsToolName() {
        #expect(ClaudeOutputState.usingTool("Bash").statusText == "Using Bash...")
    }

    @Test func speakingShowsStatusText() {
        #expect(ClaudeOutputState.speaking.statusText == "Speaking...")
    }
}
```

**Step 3: Remove stale outputState references in WebSocketManager**

Search for places that set `outputState` to `.awaitingPermission` or `.awaitingQuestion` and remove those lines. The `inputBarMode` transitions added in Task 2 replace them.

Also remove `canSendVoiceInput` checks from any remaining code.

**Step 4: Run all unit tests**

Run: `xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests 2>&1 | tail -30`
Expected: ALL PASS

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ClaudeOutputState.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeOutputStateTests.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "refactor: remove permission cases from ClaudeOutputState, clean up dead code"
```

**CHECKPOINT:** Run full test suite. Build and install on device. Do a full smoke test:
1. Open session, send text message — works
2. Use mic — works
3. Trigger permission prompt — appears in input bar, approve — input bar returns to normal
4. Trigger another prompt, deny — input bar returns to normal, denied summary in conversation
5. Close and reopen session — no stuck states
6. Kill server, reconnect — input bar properly cycles through states
