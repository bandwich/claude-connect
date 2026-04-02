---
status: complete
created: 2026-04-01
branch: feature/e2e-test-rewrite
---

# E2E Idle-Wait Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix XCTest idle-wait blocking that prevents all element queries inside SessionView during E2E tests.

**Architecture:** SessionView never becomes "idle" from XCTest's perspective because `withAnimation` scroll calls and `onScrollGeometryChange` create a continuous re-render loop: items change → animated scrollTo → geometry change → isNearBottom update → chevron button toggle → layout change → geometry change. The fix: when `INTEGRATION_TEST_MODE=1`, disable scroll tracking and skip SwiftUI animations, breaking the loop. Also disable UIKit animations globally (navigation transitions) for faster test execution.

**Tech Stack:** SwiftUI, XCTest, ProcessInfo environment variables

**Risky Assumptions:** The scroll tracking + animation chain is the sole cause of the idle-wait issue. If other continuous update sources exist (e.g., URLSession delegate queue activity), this fix won't be sufficient. We verify early in Task 2.

---

### Task 1: Add test-mode idle support to SessionView and app

**Files:**
- Modify: `ios/ClaudeConnect/ClaudeConnect/Views/SessionView.swift`
- Modify: `ios/ClaudeConnect/ClaudeConnect/ClaudeVoiceApp.swift`

**Step 1: Add UIView.setAnimationsEnabled(false) in app entry point**

In `ClaudeVoiceApp.swift`, disable UIKit animations when running in test mode. This eliminates navigation transition delays and any UIKit-based animation that could prevent idle state.

In the `.onAppear` block, before the auto-connect logic, add:

```swift
// Disable UIKit animations in test mode for faster E2E tests
if ProcessInfo.processInfo.environment["INTEGRATION_TEST_MODE"] == "1" {
    UIView.setAnimationsEnabled(false)
}
```

**Step 2: Add test-mode flag to SessionView**

At the top of SessionView struct (after the `@State` properties), add:

```swift
private static let isTestMode = ProcessInfo.processInfo.environment["INTEGRATION_TEST_MODE"] == "1"
```

**Step 3: Disable scroll tracking in test mode**

Find the `.onChange(of: items.count)` block. Currently it enables scroll tracking after 1s:

```swift
DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
    scrollTrackingEnabled = true
}
```

Wrap it so test mode never enables:

```swift
if !Self.isTestMode {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
        scrollTrackingEnabled = true
    }
}
```

**Step 4: Remove withAnimation from scroll calls in test mode**

Create a helper method at the bottom of SessionView:

```swift
private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
    if Self.isTestMode || !animated {
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    } else {
        withAnimation {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}
```

Replace all `withAnimation { proxy.scrollTo("bottom-anchor", anchor: .bottom) }` calls with `scrollToBottom(proxy)`. There are 4 occurrences:

1. In `.onChange(of: items.count)` else branch (the `isNearBottom` case)
2. In `.onChange(of: webSocketManager.activityState?.state)`
3. In `.onChange(of: isTextFieldFocused)` (the keyboard case)
4. In the scroll-to-bottom chevron Button action

Also replace the non-animated `proxy.scrollTo("bottom-anchor", anchor: .bottom)` calls with `scrollToBottom(proxy, animated: false)`:

1. In `.onChange(of: items.count)` initial load branch

**Step 5: Commit**

```bash
git commit -m "fix: disable animations and scroll tracking in test mode for XCTest idle-wait"
```

---

### Task 2: Verify with E2EPermissionTests

**Files:**
- No file changes — verification only

**Step 1: Build the app for simulator**

```bash
cd ios/ClaudeConnect
xcodebuild build -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  2>&1 | tail -20
```

Expected: BUILD SUCCEEDED

**Step 2: Run E2EPermissionTests**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh E2EPermissionTests
```

Expected: All 4 tests pass (test_bash_permission_card, test_permission_deny, test_edit_permission_card, test_permission_with_suggestion)

**CHECKPOINT:** If permission tests still hang/fail, the idle-wait has a different root cause. Debug by:
1. Take a screenshot during the hang to confirm UI state
2. Check if `onScrollGeometryChange` is still firing (add a print guard)
3. Consider adding `.transaction { $0.disablesAnimations = true }` to the entire SessionView body in test mode
4. As last resort, add HTTP-based verification endpoints instead of XCTest element queries

---

### Task 3: Run all E2E test suites

**Files:**
- No file changes — verification only

**Step 1: Run the full E2E suite**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh
```

**Step 2: Check results for each suite**

Expected results:
- E2EConnectionTests (3) — PASS (worked before, should still work)
- E2ENavigationTests (1) — PASS (worked before, should still work)
- E2EConversationTests (3) — PASS (previously blocked by idle-wait)
- E2EPermissionTests (4) — PASS (verified in Task 2)
- E2EQuestionTests (2) — PASS (previously blocked by idle-wait)
- E2ESessionTests (2) — PASS (minimal SessionView queries)
- E2EFileBrowserTests (2) — PASS (queries FilesView, not SessionView)

**Step 3: Record which tests pass and which fail**

If any tests fail for reasons OTHER than idle-wait (e.g., missing accessibility identifiers, wrong element queries), note them for a follow-up fix. The goal of this plan is specifically to fix the idle-wait blocker.

**CHECKPOINT:** If previously-passing tests now fail, the animation disabling may have broken something. Investigate before proceeding.

---

### Task 4: Reduce unnecessary sleeps

**Files:**
- Modify: `ios/ClaudeConnect/ClaudeConnectUITests/E2ETestBase.swift`

Now that idle-wait is fixed, XCTest element queries resolve quickly. Reduce hardcoded sleeps that were workarounds.

**Step 1: Reduce the 8-second SessionView load sleep**

In `navigateToTestSession()`, the 8-second sleep was needed because XCTest couldn't verify SessionView loaded. Now we can use element queries instead:

```swift
if isTestServerMode {
    // Wait for SessionView to load — now works with idle-wait fix
    sleep(2) // Allow navigation animation to complete
    let loaded = waitForSessionViewLoaded(timeout: 10)
    XCTAssertTrue(loaded, "SessionView should load with input bar visible")
}
```

**Step 2: Reduce the permission injection sleep**

In `injectPermissionRequest()`, reduce the sleep from 2s to 1s:

```swift
sleep(1) // Wait for HTTP → WebSocket broadcast
```

**Step 3: Run E2EPermissionTests again to verify sleeps are sufficient**

```bash
cd ios/ClaudeConnect && ./run_e2e_tests.sh E2EPermissionTests
```

Expected: All 4 tests still pass with reduced sleeps.

**Step 4: Commit**

```bash
git commit -m "fix: reduce E2E test sleeps now that idle-wait is fixed"
```

---

### Task 5: Run server tests to verify no regressions

**Files:**
- No file changes — verification only

**Step 1: Run server tests**

```bash
cd server/tests && ./run_tests.sh
```

Expected: All tests pass (these don't touch iOS code, but verify the test server still works).

**Step 2: Run iOS unit tests**

```bash
cd ios/ClaudeConnect
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  -only-testing:ClaudeConnectTests \
  -parallel-testing-enabled NO
```

Expected: All unit tests pass.

**Step 3: Commit if any test fixes were needed**
