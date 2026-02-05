# UI Header Fixes Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix broken header layouts in Projects, Sessions, and Session chat views.

**Architecture:** Direct fixes to SwiftUI toolbar placements and layout constraints. ProjectsListView uses wrong toolbar placement; CustomNavigationBar has overly restrictive width constraint.

**Tech Stack:** SwiftUI, iOS 18

**Risky Assumptions:** The maxWidth constraint removal won't break other layouts. Will verify on device.

---

### Task 1: Fix Projects Header Layout

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift:82-98`

**Problem:** Uses `.principal` placement which centers content. Need separate `.navigationBarLeading` and `.navigationBarTrailing` placements.

**Step 1: Replace the toolbar block**

Change lines 82-98 from:

```swift
.navigationBarTitleDisplayMode(.inline)
.toolbar {
    ToolbarItem(placement: .principal) {
        HStack {
            Text("Projects")
                .font(.title2)
                .fontWeight(.medium)
            Spacer()
            Button(action: { showingSettings = true }) {
                Image(systemName: "gearshape.fill")
                    .foregroundColor(.secondary)
            }
            .accessibilityIdentifier("settingsButton")
        }
        .frame(maxWidth: .infinity)
    }
}
```

To:

```swift
.navigationBarTitleDisplayMode(.inline)
.toolbar {
    ToolbarItem(placement: .navigationBarLeading) {
        Text("Projects")
            .font(.title2)
            .fontWeight(.medium)
    }
    ToolbarItem(placement: .navigationBarTrailing) {
        Button(action: { showingSettings = true }) {
            Image(systemName: "gearshape.fill")
                .foregroundColor(.secondary)
        }
        .accessibilityIdentifier("settingsButton")
    }
}
```

**Step 2: Build to verify no compile errors**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -target ClaudeVoice -sdk iphonesimulator -quiet 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift
git commit -m "fix: Projects header - title left, gear right"
```

---

### Task 2: Fix CustomNavigationBar Width Constraint

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CustomNavigationBar.swift:53`

**Problem:** `LeadingNavContent` has `.frame(maxWidth: 200)` which truncates breadcrumb and title on smaller text or causes layout issues.

**Step 1: Remove the maxWidth constraint**

Change line 53 from:

```swift
.frame(maxWidth: 200, alignment: .leading)
```

To:

```swift
.frame(alignment: .leading)
```

**Step 2: Build to verify no compile errors**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -target ClaudeVoice -sdk iphonesimulator -quiet 2>&1 | tail -5`

Expected: `** BUILD SUCCEEDED **`

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CustomNavigationBar.swift
git commit -m "fix: remove maxWidth constraint from nav bar leading content"
```

---

### Task 3: Verify All Headers on Device

**Files:** None (manual verification)

**Automated tests:** None (visual layout verification requires device)

**Manual verification (REQUIRED before merge):**

1. Build and install on device:
   ```bash
   cd ios-voice-app/ClaudeVoice && xcodebuild -target ClaudeVoice -sdk iphoneos build
   ```

2. Open Projects screen:
   - Verify "Projects" is left-aligned
   - Verify gear icon is on far right
   - Verify row list displays correctly

3. Tap a project to open Sessions screen:
   - Verify back chevron + breadcrumb "/projectname" on left (not split across lines)
   - Verify gear icon on far right
   - Verify Sessions/Files tabs display correctly

4. Tap a session to open Session chat:
   - Verify back chevron + session title on left (truncates properly if long)
   - Verify context % indicator displays on right
   - Verify branch indicator displays on right
   - Verify no overlapping text

**CHECKPOINT:** All three headers must match the target layouts in the design doc before proceeding.

**Step 1: If all verifications pass, commit any final adjustments**

If no adjustments needed, proceed to finish.

---

### Task 4: Finish

**Step 1: Run /finish-dev-branch to complete**

This will present options to create a PR or keep the branch for later.
