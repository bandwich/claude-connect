# UI Overhaul Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Replace three iOS screens (Projects, Sessions, Session) with new cleaner design matching provided mockups.

**Architecture:** Update SwiftUI views to match new visual design. Use ZStack for floating buttons overlaying lists. Simplify message bubbles and bottom input area. Keep all existing functionality/data flow unchanged. Refactor tests to match new UI structure.

**Tech Stack:** SwiftUI, iOS 17+

**Risky Assumptions:** Floating button positioning works across device sizes. Verify on simulator after Task 1 before proceeding.

---

### Task 1: ProjectsListView - Floating Button and Row Styling

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift`

**Step 1: Update row styling - remove pill background from session count**

Replace the Button content (around lines 22-40):
```swift
Button(action: {
    selectedProject = project
    showingSessionsList = true
}) {
    HStack {
        VStack(alignment: .leading) {
            Text(project.name)
                .font(.headline)
            Text(project.path)
                .font(.caption)
                .foregroundColor(.secondary)
        }

        Spacer()

        Text("\(project.sessionCount)")
            .font(.subheadline)
            .foregroundColor(.secondary)
    }
}
.buttonStyle(.plain)
```

**Step 2: Remove folder.badge.plus from toolbar, keep only settings gear**

Replace toolbar:
```swift
.toolbar {
    ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: { showingSettings = true }) {
            Image(systemName: "gearshape.fill")
        }
    }
}
```

**Step 3: Wrap List in ZStack and add floating button**

Replace the `List(projects)` block with:
```swift
ZStack(alignment: .bottomTrailing) {
    List(projects) { project in
        Button(action: {
            selectedProject = project
            showingSessionsList = true
        }) {
            HStack {
                VStack(alignment: .leading) {
                    Text(project.name)
                        .font(.headline)
                    Text(project.path)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text("\(project.sessionCount)")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    // Floating add button
    Button(action: { showingAddProject = true }) {
        Image(systemName: "folder.badge.plus")
            .font(.system(size: 20))
            .foregroundColor(.primary)
            .frame(width: 50, height: 50)
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color(.separator), lineWidth: 1)
            )
    }
    .padding(.trailing, 20)
    .padding(.bottom, 20)
    .accessibilityLabel("Add Project")
}
```

**Step 4: Build and verify**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift
git commit -m "feat: update ProjectsListView with floating button and cleaner row styling"
```

**CHECKPOINT:** User verifies on device that Projects screen matches mockup before proceeding.

---

### Task 2: SessionsListView - Floating Button, Breadcrumb, and Relative Time

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ENavigationFlowTests.swift`

**Step 1: Add relative time formatting function**

Add at the bottom of SessionsListView.swift, before the closing brace:
```swift
private func relativeTimeString(from timestamp: TimeInterval) -> String {
    let date = Date(timeIntervalSince1970: timestamp)
    let now = Date()
    let interval = now.timeIntervalSince(date)

    if interval < 60 {
        let seconds = Int(interval)
        return "\(seconds) seconds ago"
    } else if interval < 3600 {
        let minutes = Int(interval / 60)
        return "\(minutes) minutes ago"
    } else if interval < 86400 {
        let hours = Int(interval / 3600)
        return "\(hours) hours ago"
    } else if interval < 172800 {
        return "Yesterday"
    } else {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        return formatter.string(from: date)
    }
}
```

**Step 2: Update navigation title to show breadcrumb and combine toolbar**

Replace `.navigationTitle(project.name)` and the existing `.toolbar` block with:
```swift
.navigationTitle("Sessions")
.toolbar {
    ToolbarItem(placement: .principal) {
        VStack(spacing: 2) {
            Text("/\(project.name)")
                .font(.caption)
                .foregroundColor(.secondary)
            Text("Sessions")
                .font(.headline)
        }
    }
    ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: { showingSettings = true }) {
            Image(systemName: "gearshape.fill")
        }
    }
}
```

**Step 3: Update row styling with relative time, remove active indicator, add floating button**

Replace the List block with:
```swift
ZStack(alignment: .bottomTrailing) {
    List(sessions) { session in
        Button(action: {
            selectedSession = session
        }) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.headline)
                        .lineLimit(2)

                    Text("\(session.messageCount) messages")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(relativeTimeString(from: session.timestamp))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // Floating add button
    Button(action: createNewSession) {
        Image(systemName: "plus")
            .font(.system(size: 20))
            .foregroundColor(.primary)
            .frame(width: 50, height: 50)
            .background(Color(.systemBackground))
            .cornerRadius(25)
            .overlay(
                Circle()
                    .stroke(Color(.separator), lineWidth: 1)
            )
    }
    .padding(.trailing, 20)
    .padding(.bottom, 20)
    .accessibilityLabel("New Session")
}
```

**Step 4: Update E2ENavigationFlowTests.swift - fix nav bar title check**

Replace line 34:
```swift
let navTitle = app.navigationBars[testProjectName]
```
with:
```swift
let navTitle = app.navigationBars["Sessions"]
```

**Step 5: Build and run tests**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ENavigationFlowTests.swift
git commit -m "feat: update SessionsListView with floating button, breadcrumb, and relative time"
```

**CHECKPOINT:** User verifies on device that Sessions screen matches mockup before proceeding.

---

### Task 3: SessionView - Header Changes

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ENavigationFlowTests.swift`

**Step 1: Add branch placeholder state**

Add with other @State properties (around line 17):
```swift
@State private var branchName: String = "main"  // Placeholder for now
```

**Step 2: Update toolbar - remove settings gear and sync indicator, add branch**

Replace the `.toolbar` block with:
```swift
.toolbar {
    ToolbarItem(placement: .navigationBarTrailing) {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(branchName)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
```

**Step 3: Remove the settings sheet and @State**

Delete the `.sheet(isPresented: $showingSettings)` block.

Also delete the `@State private var showingSettings = false` declaration.

**Step 4: Update E2ENavigationFlowTests.swift - remove settings test from SessionView**

Replace lines 53-56:
```swift
        // Settings accessible from session view
        settingsButton.tap()
        XCTAssertTrue(app.staticTexts["Settings"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
```
with:
```swift
        // Branch indicator visible
        let branchIndicator = app.staticTexts["main"]
        XCTAssertTrue(branchIndicator.exists, "Branch indicator should be visible")
```

**Step 5: Build and verify**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ENavigationFlowTests.swift
git commit -m "feat: update SessionView header with branch placeholder, remove settings"
```

---

### Task 4: SessionView - Message Styling

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Replace MessageBubble with new styling**

Replace the entire `MessageBubble` struct:
```swift
struct MessageBubble: View {
    let message: SessionHistoryMessage

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if message.role == "user" {
                Text("‹")
                    .foregroundColor(.secondary)
                Text(message.content)
                    .foregroundColor(.primary)
                Spacer()
            } else {
                Text(message.content)
                    .padding(12)
                    .background(Color(.systemGray5))
                    .cornerRadius(12)
                Spacer()
            }
        }
        .accessibilityIdentifier("messageBubble")
    }
}
```

**Step 2: Build and verify**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: update message styling with user prefix and assistant cards"
```

---

### Task 5: SessionView - Bottom Area with Centered Mic and Error State

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift`

**Step 1: Replace bottom VStack with simplified mic area**

Replace the bottom VStack (the "Voice input area" section):
```swift
// Bottom mic area
VStack(spacing: 16) {
    if let error = syncError {
        // Error state - show error instead of mic
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 40))
                .foregroundColor(.red)
            Text(error)
                .font(.caption)
                .foregroundColor(.red)
                .multilineTextAlignment(.center)
        }
        .accessibilityIdentifier("syncError")
    } else if !isSessionSynced && !session.isNewSession {
        // Syncing state
        VStack(spacing: 8) {
            ProgressView()
        }
        .accessibilityIdentifier("syncStatus")
    } else {
        // Normal state - show mic
        Button(action: toggleRecording) {
            Image(systemName: speechRecognizer.isRecording ? "mic.fill" : "mic")
                .font(.system(size: 32))
                .foregroundColor(micColor)
        }
        .accessibilityLabel(speechRecognizer.isRecording ? "Stop" : "Tap to Talk")
        .disabled(!canRecord)
    }
}
.frame(height: 100)
.frame(maxWidth: .infinity)
.background(Color(.systemBackground))
```

**Step 2: Add micColor computed property, remove buttonColor**

Add after the existing computed properties:
```swift
private var micColor: Color {
    if !canRecord { return .gray }
    return speechRecognizer.isRecording ? .red : .primary
}
```

Delete the old `buttonColor` property if it exists.

**Step 3: Update E2ETestBase.swift - remove voiceState/outputStatus checks**

Update `waitForSessionSyncComplete` method to not rely on voiceState/outputStatus. Replace the method (lines 647-708):
```swift
/// Wait for SessionView sync to complete
/// Sync is complete when the mic button appears (syncStatus/syncError gone)
func waitForSessionSyncComplete(timeout: TimeInterval = 15.0) -> Bool {
    let startTime = Date()

    print("⏳ Waiting for session sync to complete...")

    // Wait for mic button to appear (indicates sync complete, no error)
    let talkButton = app.buttons["Tap to Talk"]
    while Date().timeIntervalSince(startTime) < timeout {
        // Check if Talk button exists and is enabled (sync succeeded)
        if talkButton.exists && talkButton.isEnabled {
            let elapsed = Date().timeIntervalSince(startTime)
            print("✓ Session sync complete after \(String(format: "%.1f", elapsed))s - mic button visible")
            return true
        }

        // Check if syncError element exists (sync failed)
        let syncErrorElement = app.otherElements["syncError"]
        if syncErrorElement.exists {
            print("⚠️ Session sync failed - syncError visible")
            return true
        }

        // Check if syncStatus exists (still syncing)
        let syncStatus = app.otherElements["syncStatus"]
        if syncStatus.exists {
            // Still syncing, continue waiting
        }

        usleep(250000) // Check every 250ms
    }

    print("✗ Session sync did not complete within \(timeout)s")

    // Debug: print what elements are visible
    print("  talkButton exists: \(talkButton.exists), enabled: \(talkButton.isEnabled)")
    let syncError = app.otherElements["syncError"]
    let syncStatus = app.otherElements["syncStatus"]
    print("  syncError exists: \(syncError.exists)")
    print("  syncStatus exists: \(syncStatus.exists)")

    return false
}
```

**Step 4: Update waitForVoiceState to use mic button state**

Replace the `waitForVoiceState` method (lines 252-263):
```swift
func waitForVoiceState(_ expectedState: String, timeout: TimeInterval = 10.0) -> Bool {
    // Voice state is now indicated by mic button appearance
    // "Idle" = mic button visible with "Tap to Talk" label
    // "Listening" = mic button visible with "Stop" label
    let startTime = Date()

    while Date().timeIntervalSince(startTime) < timeout {
        if expectedState == "Idle" {
            let talkButton = app.buttons["Tap to Talk"]
            if talkButton.exists && talkButton.isEnabled {
                return true
            }
        } else if expectedState == "Listening" {
            let stopButton = app.buttons["Stop"]
            if stopButton.exists {
                return true
            }
        }
        usleep(250000)
    }
    return false
}
```

**Step 5: Update waitForResponseCycle to use mic button**

Replace the `waitForResponseCycle` method (lines 274-347):
```swift
/// Wait for a conversation response cycle to complete
/// This waits for the mic button to become disabled then enabled again
func waitForResponseCycle(timeout: TimeInterval = 30.0) -> Bool {
    let startTime = Date()

    // First, wait for mic to become unavailable (response cycle started)
    var sawProcessing = false
    while Date().timeIntervalSince(startTime) < timeout {
        let talkButton = app.buttons["Tap to Talk"]

        // Check if mic is disabled or not present (processing)
        if !talkButton.exists || !talkButton.isEnabled {
            sawProcessing = true
            print("✓ Response cycle started (mic unavailable)")
            break
        }

        usleep(250000)
    }

    if !sawProcessing {
        print("✗ Response cycle never started within \(timeout)s")
        return false
    }

    // Now wait for cycle to complete (mic button becomes available again)
    while Date().timeIntervalSince(startTime) < timeout {
        let talkButton = app.buttons["Tap to Talk"]

        if talkButton.exists && talkButton.isEnabled {
            let elapsed = Date().timeIntervalSince(startTime)
            print("✓ Response cycle complete after \(String(format: "%.1f", elapsed))s")
            return true
        }

        usleep(250000)
    }

    print("✗ Response cycle did not complete within \(timeout)s")
    return false
}
```

**Step 6: Build and verify**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift
git commit -m "feat: simplify SessionView bottom area with centered mic and error state"
```

**CHECKPOINT:** User verifies on device that Session screen matches mockup.

---

## Final Verification

After all tasks, run the iOS unit tests:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests 2>&1 | tail -30
```

User should verify all three screens on device match the provided mockups.
