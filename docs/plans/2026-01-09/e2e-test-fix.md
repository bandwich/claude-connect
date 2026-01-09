# E2E Test Fix Plan

## Problem Summary
E2E tests fail with 60-second timeout when entering SessionView. XCTest waits for "app to idle" but app never becomes idle.

## Root Cause Analysis

### Finding: SessionView body evaluated 669 times in ~0.2 seconds
- This is a SwiftUI re-render loop
- Causes main thread to be continuously busy
- XCTest interprets this as "app not idle" and times out after 60s
- Works on real device (no XCTest idle detection)

### What we tried (DID NOT FIX):
1. **SwipeBackModifier** - Removed `DispatchQueue.main.async` from `updateUIViewController` - still fails
2. **voiceState/outputState guards** - Added guards to prevent redundant @Published updates in WebSocketManager and SessionView callbacks - still fails
3. **isRunningUITests check** - This was a red herring, audio/speech worked before UI overhaul

### Key difference from working version:
Old SessionView (commit 39385ce) used:
- `.navigationTitle(session.title)`
- `.navigationBarTitleDisplayMode(.inline)`
- `.toolbar { ... }`

New SessionView uses:
- `.customNavigationBarInline(...)`
- `.enableSwipeBack()`

**UI CANNOT CHANGE** - must fix without altering visual appearance.

## Code locations:
- SessionView: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- CustomNavigationBar: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CustomNavigationBar.swift`
- SwipeBackModifier: `ios-voice-app/ClaudeVoice/ClaudeVoice/Utils/SwipeBackModifier.swift`
- WebSocketManager: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

## Current state of code changes:
1. `SwipeBackModifier.updateUIViewController` is now empty (change kept)
2. Guards added to voiceState/outputState updates (change kept)
3. Guards added to SessionView audio/speech callbacks (change kept)

## Next investigation steps:

1. **Compare CustomNavigationBarInline implementation** - The ViewModifier creates new closures on each body evaluation. Check if `@ViewBuilder let trailingContent: () -> TrailingContent` pattern causes issues.

2. **Check for @Published property cascade** - SessionView body accesses many @Published properties:
   - speechRecognizer.isRecording
   - audioPlayer.isPlaying
   - webSocketManager.outputState
   - webSocketManager.connectionState
   - webSocketManager.voiceState
   - webSocketManager.activeSessionId
   - webSocketManager.pendingPermission

   Any of these changing triggers body re-evaluation.

3. **Check setupView() onAppear** - This sets up callbacks that modify @Published state. Could trigger immediate re-renders.

4. **Check onChange handlers** - `onChange(of: messages.count)` and `onChange(of: webSocketManager.pendingPermission)` might cascade.

5. **Test with EquatableView** - Wrap SessionView body in EquatableView to prevent unnecessary re-renders.

6. **Add debug logging** - Add `let _ = print("body evaluated")` at top of SessionView body to count evaluations during test.

## Session 6 Progress

### Fixed (test infrastructure):
- SIGPIPE in run_e2e_tests.sh (743 session files caused grep|head pipe to break)
- Tests use tapByCoordinate() for SessionView entry
- waitForSessionSyncComplete() uses HTTP verification instead of UI elements
- Removed UI element checks while in SessionView

### NOT fixed (root cause):
- SwiftUI re-render loop still happens
- XCTest still times out waiting for idle after entering SessionView
- Back navigation fails because XCTest can't interact with busy app

### Key insight:
- App works fine on real device - re-render loop only affects XCTest idle detection
- Test changes are workarounds, not fixes
- Need to find what triggers continuous re-renders in XCTest environment only

### Remaining investigation (not yet done):
1. Why does re-render happen in XCTest but not on device?
2. Is there something in the test setup that triggers state changes?
3. Check if WebSocketManager receives continuous messages during tests

## Test Commands
```bash
# Run single E2E test suite
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2ENavigationFlowTests

# Check test result
grep -E "(PASSED|FAILED)" /tmp/e2e_test.log
```

## Notes on test infrastructure:
- Test script runs `claude --print` to create session - can hang without timeout
- If stuck, check `/tmp/claude_init.log` and kill stale `claude` processes
- Session dir: `~/.claude/projects/-private-tmp-e2e-test-project/`

## Session 13 Progress

### ROOT CAUSE FOUND AND FIXED: @Environment(\.dismiss)

The render loop was caused by `@Environment(\.dismiss)` in both SessionsListView and SessionView.

**Evidence:**
- With @Environment(\.dismiss): 30,000+ body evaluations, XCTest timeout
- Without @Environment(\.dismiss): 29 body evaluations, test progresses

**Fix applied:**
1. SessionsListView: Replaced `@Environment(\.dismiss)` with `@Binding var showingBinding: Bool` passed from ProjectsListView
2. SessionView: Replaced `@Environment(\.dismiss)` with `@Binding var selectedSessionBinding: Session?` passed from SessionsListView
3. Both views now use binding assignment (`binding = false/nil`) instead of `dismiss()`

**Files changed:**
- `SessionView.swift`: Line 11 - `@Binding var selectedSessionBinding: Session?`
- `SessionsListView.swift`: Line 7 - `@Binding var showingBinding: Bool`
- `ProjectsListView.swift`: Line 132 - passes `showingBinding: $showingSessionsList`

### Current status:
- ✅ Render loop FIXED (29 lines vs 30,000+)
- ✅ Test no longer times out on idle
- ❌ Test fails on "Session should sync" - server never receives resume_session message

### Next investigation:
The sync failure appears unrelated to the render loop. Possible causes:
1. `syncSession()` guard failing (connectionState not .connected)
2. `webSocketManager.resumeSession()` not sending message
3. Session `isNewSession` check incorrectly returning true

Debug by adding print statements to:
- `SessionView.setupView()`
- `SessionView.syncSession()`
- `WebSocketManager.resumeSession()`

## TODO
- [x] Fix render loop (remove @Environment(\.dismiss))
- [ ] Debug why syncSession() doesn't send resume_session message
- [ ] Run E2E tests to verify complete fix
