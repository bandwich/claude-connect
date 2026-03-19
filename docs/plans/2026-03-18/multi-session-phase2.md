# Multi-Session Support — Phase 2: iOS App

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Update the iOS app to show active sessions with green dots, switch between them without killing background sessions, and stop sessions via an ellipsis menu.

**Architecture:** Add `active_session_ids` to the sessions list response, show green dots in SessionsListView, add an ellipsis menu to SessionView's nav bar with "Stop Session", and send `view_session` when opening an active session instead of `resume_session`.

**Tech Stack:** Swift, SwiftUI, WebSocket

**Risky Assumptions:** The nav bar has enough visual space for the ellipsis menu alongside existing content. We constrain existing content width to make room.

**Prerequisite:** Phase 1 (server multi-session) must be complete and verified.

**Design doc:** `docs/plans/2026-03-18/multi-session-design.md`

---

### Task 1: WebSocket Protocol Models ✅ DONE

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

**Step 1: Update SessionsResponse to include active_session_ids**

In `Session.swift`, update:

```swift
struct SessionsResponse: Codable {
    let type: String
    let sessions: [Session]
    let activeSessionIds: [String]?

    enum CodingKeys: String, CodingKey {
        case type, sessions
        case activeSessionIds = "active_session_ids"
    }
}
```

**Step 2: No new model needed for session_stopped**

The server's `session_stopped` response has `type`, `success`, and `session_id` fields — this already matches the existing `SessionActionResponse` struct in `Session.swift`. The existing `handleMessage` code decodes it automatically.

**Step 3: Update ConnectionStatus to include active_session_ids**

In `Session.swift`, find `ConnectionStatus` and add:

```swift
struct ConnectionStatus: Codable {
    let type: String
    let connected: Bool
    let activeSessionId: String?
    let activeSessionIds: [String]?  // NEW
    let branch: String?

    enum CodingKeys: String, CodingKey {
        case type, connected, branch
        case activeSessionId = "active_session_id"
        case activeSessionIds = "active_session_ids"
    }
}
```

**Step 4: Add stopSession and viewSession to WebSocketManager**

In `WebSocketManager.swift`, add:

```swift
func stopSession(sessionId: String) {
    let message: [String: Any] = [
        "type": "stop_session",
        "session_id": sessionId
    ]
    sendJSON(message)
}

func viewSession(sessionId: String) {
    let message: [String: Any] = [
        "type": "view_session",
        "session_id": sessionId
    ]
    sendJSON(message)
}
```

**Step 5: Add activeSessionIds published property**

In `WebSocketManager.swift`, add a published property:

```swift
@Published var activeSessionIds: [String] = []
```

**Step 6: Update handleMessage to store activeSessionIds**

`session_stopped` already decodes via the existing `SessionActionResponse` handler — no changes needed there.

Update the `ConnectionStatus` handler to store `activeSessionIds`:

```swift
} else if let connectionStatus = try? JSONDecoder().decode(ConnectionStatus.self, from: data) {
    // ... existing code ...
    DispatchQueue.main.async {
        self.connected = connectionStatus.connected
        self.activeSessionId = connectionStatus.activeSessionId
        self.activeSessionIds = connectionStatus.activeSessionIds ?? []
        self.branch = connectionStatus.branch
        self.onConnectionStatusReceived?(connectionStatus)
    }
}
```

Update the `SessionsResponse` handler to store active IDs:

```swift
} else if let sessionsResponse = try? JSONDecoder().decode(SessionsResponse.self, from: data) {
    logToFile("✅ Decoded as SessionsResponse: \(sessionsResponse.sessions.count) sessions")
    DispatchQueue.main.async {
        if let activeIds = sessionsResponse.activeSessionIds {
            self.activeSessionIds = activeIds
        }
        self.onSessionsReceived?(sessionsResponse.sessions)
    }
}
```

**Step 7: Build to verify compilation**

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 8: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: add multi-session WebSocket protocol models to iOS"
```

---

### Task 2: Sessions List Green Dots ✅ DONE

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift`

**Step 1: Add green dot indicator for active sessions**

Update the session row in the `List` to show a green dot when the session is active:

```swift
List(sessions) { session in
    Button(action: {
        selectedSession = session
    }) {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title)
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text("\(session.messageCount) messages")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Text(TimeFormatter.relativeTimeString(from: session.timestamp))
                .font(.caption)
                .foregroundColor(.secondary)

            // Green dot for active sessions
            if webSocketManager.activeSessionIds.contains(session.id) {
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .padding(.leading, 4)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}
```

**Step 2: Update session tap to use viewSession for active sessions**

In the `navigationDestination` modifier, the selected session should send `view_session` if it's already active, or `resume_session` if it's not. This logic goes in `SessionView`'s `onAppear` — see Task 3. No change needed here in the list itself since it just sets `selectedSession`.

**Step 3: Build to verify**

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift
git commit -m "feat: show green dot for active sessions in sessions list"
```

---

### Task 3: SessionView Ellipsis Menu and View/Stop Logic ✅ DONE

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CustomNavigationBar.swift`

**Step 1: Add ellipsis menu to CustomNavigationBarInline**

The existing `CustomNavigationBarInline` wraps trailing content in an HStack with the breadcrumb. We need to add an outer HStack that constrains the existing content and adds an ellipsis.

However, the ellipsis is specific to SessionView, not all navigation bars. So instead of modifying CustomNavigationBar itself, add the ellipsis as part of the SessionView's nav bar setup.

In `SessionView.swift`, find the `.customNavigationBarInline(` call and wrap the existing trailing content to leave room for the ellipsis:

```swift
.customNavigationBarInline(
    title: session.title,
    breadcrumb: "/\(project.name)",
    onBack: { selectedSessionBinding = nil }
) {
    HStack(spacing: 8) {
        // Existing trailing content, constrained
        HStack(spacing: 12) {
            // Context indicator
            if let pct = contextPercentage {
                HStack(spacing: 4) {
                    Circle()
                        .fill(contextColor(pct))
                        .frame(width: 8, height: 8)
                    Text("\(Int(max(0, 100 - pct)))%")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .accessibilityIdentifier("contextIndicator")
            }

            // Branch name
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(webSocketManager.branch ?? "main")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }

        // Ellipsis menu
        if isActiveSession {
            Menu {
                Button("Stop Session", role: .destructive) {
                    stopSession()
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary)
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
        }
    }
}
```

**Step 2: Add state properties and helper methods**

Add to SessionView:

```swift
// Computed property: is this session currently active in tmux?
private var isActiveSession: Bool {
    webSocketManager.activeSessionIds.contains(session.id) || session.isNewSession
}

private func stopSession() {
    let sessionId = session.isNewSession
        ? (webSocketManager.activeSessionId ?? "")
        : session.id
    guard !sessionId.isEmpty else { return }
    webSocketManager.stopSession(sessionId: sessionId)
    // Navigate back after stopping
    selectedSessionBinding = nil
}
```

**Step 3: Update onAppear to send view_session for active sessions**

In SessionView's `onAppear`, add logic to send `view_session` when opening an already-active session:

Find the `onAppear` block. Add at the beginning:

```swift
// If this session is already active (green dot), just switch view — don't resume
if !session.isNewSession && webSocketManager.activeSessionIds.contains(session.id) {
    webSocketManager.viewSession(sessionId: session.id)
}
```

This tells the server to switch TTS/activity updates to this session without starting a new tmux process.

**Step 4: Update back button behavior**

The back button is `onBack: { selectedSessionBinding = nil }`. This already just navigates away — it doesn't call `closeSession()`. Verify that `closeSession()` is NOT called on back navigation.

Search for `closeSession` calls in SessionView. If found (e.g., in `onDisappear`), remove them. The session should stay alive when navigating away.

**Step 5: Build to verify**

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CustomNavigationBar.swift
git commit -m "feat: add ellipsis menu with stop session to session view"
```

---

### Task 4: Commit Server Fix

**Why:** `handle_view_session` was missing a `switch_watched_session` call, so switching between sessions didn't update the transcript watcher. This is already fixed but uncommitted.

**Files:**
- Modify: `voice_server/ios_server.py` (already modified, just needs commit)

**Step 1: Commit the server fix**

```bash
cd /Users/aaron/Desktop/max && git add voice_server/ios_server.py
git commit -m "fix: switch transcript watcher when viewing a different session"
```

---

### Task 5: Filter Permission/Question Prompts by Session

**Why:** With multiple active sessions, permission and question prompts from any session arrive over the same WebSocket. Without filtering, a prompt from session B appears in session A's view. The server already sends `session_id` on `permission_request` and `question_prompt` messages (added in Phase 1 Task 4), but the iOS models don't decode it and WebSocketManager doesn't filter.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

**Step 1: Add sessionId to PermissionRequest model**

In `PermissionRequest.swift`, add `sessionId` field:

```swift
struct PermissionRequest: Codable, Identifiable, Equatable {
    let type: String
    let requestId: String
    let sessionId: String?
    let promptType: PermissionPromptType
    let toolName: String
    let toolInput: ToolInput?
    let context: PermissionContext?
    let permissionSuggestions: [PermissionSuggestion]?
    let timestamp: Double

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case sessionId = "session_id"
        case promptType = "prompt_type"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case context
        case permissionSuggestions = "permission_suggestions"
        case timestamp
    }
}
```

**Step 2: Add sessionId to QuestionPrompt model**

In `PermissionRequest.swift`, add `sessionId` field:

```swift
struct QuestionPrompt: Codable, Identifiable, Equatable {
    let type: String
    let requestId: String
    let sessionId: String?
    let header: String
    let question: String
    let options: [QuestionOption]
    let multiSelect: Bool
    let questionIndex: Int
    let totalQuestions: Int

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case sessionId = "session_id"
        case header
        case question
        case options
        case multiSelect = "multi_select"
        case questionIndex = "question_index"
        case totalQuestions = "total_questions"
    }
}
```

**Step 3: Add session filtering in WebSocketManager handleMessage**

In `WebSocketManager.swift`, there are TWO `handleMessage` blocks (normal and resync). In both, add a session check before showing permission/question prompts.

For `permission_request` — after decoding, check if the prompt's sessionId matches the viewed session. If it doesn't match, ignore it (the hook will timeout after 180s and fall back to terminal prompt).

Edge case: when `activeSessionId` is nil (new session before ID adoption), allow all prompts through — there's only one session active in that state. When `sessionId` is nil/empty (old server or single-session), also allow through for backward compatibility.

```swift
} else if let permissionRequest = try? JSONDecoder().decode(PermissionRequest.self, from: data) {
    logToFile("✅ Decoded as PermissionRequest: \(permissionRequest.requestId)")
    DispatchQueue.main.async {
        // Only show if this prompt is for the viewed session
        if let promptSession = permissionRequest.sessionId,
           !promptSession.isEmpty,
           let viewedSession = self.activeSessionId,
           promptSession != viewedSession {
            logToFile("⏭️ Skipping permission for non-viewed session: \(promptSession)")
            return
        }
        self.pendingPermission = permissionRequest
        self.handleInputBarPermission(permissionRequest)
        self.onPermissionRequest?(permissionRequest)
    }
}
```

For `question_prompt` — same pattern:

```swift
} else if let questionPrompt = try? JSONDecoder().decode(QuestionPrompt.self, from: data),
          questionPrompt.type == "question_prompt" {
    logToFile("✅ Decoded as QuestionPrompt: \(questionPrompt.requestId)")
    DispatchQueue.main.async {
        // Only show if this prompt is for the viewed session
        if let promptSession = questionPrompt.sessionId,
           !promptSession.isEmpty,
           let viewedSession = self.activeSessionId,
           promptSession != viewedSession {
            logToFile("⏭️ Skipping question for non-viewed session: \(promptSession)")
            return
        }
        self.inputBarMode = .questionPrompt(questionPrompt)
    }
}
```

Apply this pattern in BOTH handleMessage blocks (search for the two locations where `PermissionRequest` and `QuestionPrompt` are decoded).

**Step 4: Build to verify**

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max && git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: filter permission and question prompts by session ID"
```

---

### Task 6: Build, Deploy, and Manual Verification

**Files:** None (verification only)

**Step 1: Build and install iOS app on device**

```bash
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice
xcodebuild -target ClaudeVoice -sdk iphoneos build
xcrun devicectl list devices
xcrun devicectl device install app --device "<DEVICE_ID>" build/Release-iphoneos/ClaudeVoice.app
```

**Step 3: Manual verification checklist**

**Automated tests:** Run server tests to confirm nothing regressed:
```bash
cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh
```

**Manual verification (REQUIRED before merge):**

1. Start `claude-connect` server
2. Connect iOS app via QR code
3. Navigate to a project's sessions list
4. Create a new session — verify it works normally
5. Navigate back to sessions list — verify green dot appears on the session
6. Create a second session — verify both have green dots
7. Navigate back, tap the first session — verify it switches without killing the second
8. Verify switching sessions shows the correct session's thinking state and messages in real-time
9. Open ellipsis menu (…) — verify "Stop Session" appears in red
10. Tap "Stop Session" — verify it navigates back and green dot disappears
11. Trigger a permission prompt in session A, switch to session B — verify the prompt does NOT appear in B
12. Trigger a permission prompt while viewing the correct session — verify it appears and approve/deny works normally
13. Try creating 5 sessions — verify the 6th is rejected with error message
14. Kill the app (swipe away) — reconnect — verify sessions are still running (green dots)
15. Stop the server (Ctrl+C) — verify all tmux sessions are cleaned up (`tmux ls`)

**CHECKPOINT:** All 15 checks must pass before merging.

**Step 4: Commit any final fixes**

```bash
git add -A
git commit -m "fix: address manual verification findings"
```

---

## Follow-up: Fix `_reset_session_state` clearing cross-session permission state ✅ DONE

**Priority:** Important

**Problem:** `_reset_session_state()` is called in `handle_new_session` and `handle_resume_session` before creating a new tmux session. It clears `permission_handler.permission_responses`, `pending_messages`, and `timed_out_requests` — which are shared across all sessions. If session B is waiting on a permission response and the user starts session C, the reset wipes session B's pending permission state.

**Fix:** `_reset_session_state()` should only clear state for the session being reset, not global permission handler state. Either:
1. Scope the permission handler cleanup to a specific session ID, or
2. Move permission state into `SessionContext` so each session manages its own, or
3. Only call the permission cleanup when stopping/killing a specific session (not on new/resume)

**Files:**
- `voice_server/ios_server.py` — `_reset_session_state()` and its callers
- `voice_server/permission_handler.py` — may need per-session scoping
- `voice_server/session_context.py` — may absorb permission state

---

## Summary

After Phase 2, the full multi-session flow works:
- Sessions list shows green dots for active sessions
- Tapping an active session switches to it (no kill)
- Tapping an inactive session resumes it (new tmux process)
- Switching sessions updates transcript watcher so thinking state and messages stream correctly
- Permission/question prompts only appear for the viewed session (non-viewed sessions fall back to terminal)
- Ellipsis menu in session view provides "Stop Session"
- Back button navigates away without stopping anything
- App reconnect preserves active sessions
- Server shutdown cleans up all tmux sessions
