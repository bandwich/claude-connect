# E2E Test Fix Plan

## Problem Summary
E2E tests fail with 60-second timeout when entering SessionView. XCTest waits for "app to idle" but app never becomes idle.

## Root Cause Analysis

### Finding: SessionView body evaluated 669 times in ~0.2 seconds
- This is a SwiftUI re-render loop
- Causes main thread to be continuously busy
- XCTest interprets this as "app not idle" and times out after 60s
- Works on real device (no XCTest idle detection)

### What we ruled out:
1. WebSocket messages - only ~3-4 status messages received, not 669
2. Audio engine blocking - engine starts successfully
3. Semaphores/sync calls - none found in codebase
4. File I/O in debug logging - removed, issue persists

### Likely causes to investigate:
1. **@StateObject initialization** - SpeechRecognizer and AudioPlayer are @StateObject in SessionView. Their @Published properties might trigger initial updates
2. **enableSwipeBack modifier** - Uses UIViewControllerRepresentable with DispatchQueue.main.async in make/updateUIViewController
3. **customNavigationBarInline modifier** - Creates new closures on each body evaluation
4. **voiceState being set to same value** - `handleStatusMessage` sets voiceState unconditionally without checking if value changed

### Code locations:
- SessionView body: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift:20`
- handleStatusMessage: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift:420`
- enableSwipeBack: `ios-voice-app/ClaudeVoice/ClaudeVoice/Utils/SwipeBackModifier.swift`
- customNavigationBarInline: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CustomNavigationBar.swift`

## Other E2E fixes already made (not yet tested):
1. `app.staticTexts["Settings"]` → `app.navigationBars["Settings"]`
2. `app.staticTexts[testProjectName]` → buttons pattern (3 places)
3. `app.staticTexts["Idle"]` → mic button check in E2EPermissionTests
4. Settings button tap changed from tapByCoordinate to regular tap()
5. Sessions list check changed from navigationBars["Sessions"] to buttons["New Session"]
6. Back navigation updated for custom nav bar

## Investigation Steps for Next Session

1. **Isolate the cause of re-render loop:**
   - Comment out enableSwipeBack modifier, test
   - Comment out customNavigationBarInline, use standard navigationTitle, test
   - Remove @StateObject declarations, test with injected dependencies

2. **Add guard for voiceState updates:**
   ```swift
   if self.voiceState != newState {
       self.voiceState = newState
   }
   ```

3. **Check if @Published property access patterns cause loops:**
   - The body accesses: speechRecognizer.isRecording, audioPlayer.isPlaying, webSocketManager.outputState, etc.
   - Any of these publishing during view setup could cause cascade

4. **Compare with pre-UI-overhaul SessionView:**
   - Old version at commit 39385ce didn't have this issue
   - Key differences: no enableSwipeBack, no customNavigationBar, standard toolbar

## Test Commands
```bash
# Run single E2E test suite
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2ENavigationFlowTests

# Check body evaluation count (add logging first)
cat /tmp/sessionview_body.log | wc -l

# Check test result
grep -E "(PASSED|FAILED)" /tmp/e2e_debug.log
```
