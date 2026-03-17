# Bash Output Display Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Replace the misleading "Done" label on collapsed Bash tool results with a content preview that mirrors the terminal UI.

**Architecture:** Extract a helper function that computes the collapsed preview text from the tool result content. Background commands show "Running in background", empty output shows "Done", normal output shows first 3 lines truncated. The collapsed view renders this preview instead of a static label.

**Tech Stack:** Swift/SwiftUI (iOS app only)

**Risky Assumptions:** The string `"Command running in background"` is the stable prefix for background command results. Verified across multiple transcripts and confirmed via terminal observation.

---

### Task 1: Extract collapsed preview logic and test it

The preview logic needs to be testable outside of SwiftUI. Extract it as a static function.

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ToolUseViewTests.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift`

**Step 1: Write failing tests**

In `ToolUseViewTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeVoice

@Suite("Bash Collapsed Preview Tests")
struct BashCollapsedPreviewTests {

    @Test func backgroundCommandShowsRunningInBackground() {
        let content = "Command running in background with ID: b59gez7hy. Output is being written to: /private/tmp/claude-501/tasks/b59gez7hy.output"
        let preview = BashPreview.collapsedText(for: content)
        #expect(preview == "Running in background")
    }

    @Test func emptyOutputShowsDone() {
        let preview = BashPreview.collapsedText(for: "")
        #expect(preview == "Done")
    }

    @Test func singleLineShowsFullContent() {
        let preview = BashPreview.collapsedText(for: "hello world")
        #expect(preview == "hello world")
    }

    @Test func threeLineShowsAllLines() {
        let content = "line1\nline2\nline3"
        let preview = BashPreview.collapsedText(for: content)
        #expect(preview == "line1\nline2\nline3")
    }

    @Test func fiveLinesShowsFirstThreePlusTruncation() {
        let content = "line1\nline2\nline3\nline4\nline5"
        let preview = BashPreview.collapsedText(for: content)
        #expect(preview == "line1\nline2\nline3\n… +2 lines")
    }

    @Test func errorContentStillShowsPreview() {
        let content = "ls: /nonexistent: No such file or directory"
        let preview = BashPreview.collapsedText(for: content)
        #expect(preview == "ls: /nonexistent: No such file or directory")
    }
}
```

**Step 2: Run tests to verify they fail**

Run:
```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/BashCollapsedPreviewTests
```

Expected: FAIL — `BashPreview` does not exist.

**Step 3: Implement BashPreview**

Add to the top of `ToolUseView.swift` (before the struct), or at the bottom after the struct closing brace:

```swift
enum BashPreview {
    static let maxCollapsedLines = 3

    static func collapsedText(for content: String) -> String {
        if content.hasPrefix("Command running in background") {
            return "Running in background"
        }
        if content.isEmpty {
            return "Done"
        }
        let lines = content.components(separatedBy: "\n")
        if lines.count <= maxCollapsedLines {
            return content
        }
        let preview = lines.prefix(maxCollapsedLines).joined(separator: "\n")
        let remaining = lines.count - maxCollapsedLines
        return "\(preview)\n… +\(remaining) lines"
    }
}
```

**Step 4: Run tests to verify they pass**

Run:
```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/BashCollapsedPreviewTests
```

Expected: All 6 tests PASS.

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ToolUseViewTests.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift
git commit -m "feat: add BashPreview logic for collapsed bash result text"
```

---

### Task 2: Update collapsedResultView to use BashPreview

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift:148-191`

**Step 1: Replace the collapsed (non-expanded) branch**

Replace the `else` branch in `collapsedResultView` (lines 176-190) — the part that currently shows `"Done — tap to show output"`. Change it to:

```swift
        } else {
            let isError = result.isError == true
            let previewText = BashPreview.collapsedText(for: displayContent(for: result))
            Button {
                withAnimation { isExpanded = true }
            } label: {
                if isError {
                    HStack(spacing: 4) {
                        Image(systemName: "xmark.circle")
                            .font(.footnote)
                            .foregroundColor(.red)
                        Text("Error — tap to show")
                            .font(.footnote)
                            .foregroundColor(.red)
                    }
                    .padding(.top, 2)
                } else {
                    Text(previewText)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(BashPreview.maxCollapsedLines + 1)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }
            }
        }
```

Also move `let isError = result.isError == true` from line 149 into only the expanded branch since the collapsed branch now handles it locally.

**Step 2: Build to verify compilation**

Run:
```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

Expected: BUILD SUCCEEDED.

**Step 3: Run all unit tests**

Run:
```bash
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests
```

Expected: All tests PASS.

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift
git commit -m "fix: show content preview instead of Done for collapsed bash results"
```

---

### Task 3: Manual verification

**Automated tests:** The BashPreview logic is fully tested in Task 1. The SwiftUI view wiring cannot be meaningfully unit-tested (it's a visual change).

**Manual verification (REQUIRED before merge):**

1. Build and install on device
2. Run a normal Bash command (e.g., `echo hello`) — collapsed result should show `hello` as preview text
3. Run a background Bash command (e.g., `sleep 30` with `run_in_background`) — collapsed result should show `Running in background`
4. Run a Bash command with multi-line output (e.g., `ls`) — collapsed result should show first 3 lines + `… +N lines`
5. Run a Bash command that errors (e.g., `ls /nonexistent`) — should still show `Error — tap to show`
6. Tap any collapsed result to expand — full output should appear as before
7. Tap "Hide output" — should collapse back to preview

**CHECKPOINT:** Must pass manual verification.
