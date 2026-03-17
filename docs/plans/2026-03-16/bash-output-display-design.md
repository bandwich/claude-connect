# Bash Output Display Design

## Problem

The app shows "Done — tap to show output" for all collapsed Bash tool results, even when the command isn't done. Background commands show "Done" but tapping reveals "Command running in background with ID: ...". The terminal UI handles this correctly — it shows a preview of the actual result content.

## Terminal Behavior (observed)

| Scenario | Terminal renders |
|---|---|
| Normal output (`echo hello`) | `⎿  hello world` |
| Background (`sleep 30`) | `⎿  Running in the background (↓ to manage)` |
| Multi-line (5 lines) | First 3 lines + `… +2 lines (ctrl+o to expand)` |
| Error | Error text inline (red) |
| Empty output | Checkmark only |

The terminal always shows actual result content as a preview, truncated to ~3 lines.

## Design

Replace the static "Done — tap to show output" label in `collapsedResultView` with a content preview that mirrors the terminal.

### Collapsed state logic

1. **Error** (`isError == true`): Keep existing "Error — tap to show" with red styling. Already works.
2. **Background**: Content starts with `"Command running in background"` → show "Running in background" (matches terminal's "Running in the background").
3. **Empty content**: Show checkmark + "Done" (empty output = command ran and produced nothing = actually done).
4. **Normal output**: Show first 3 lines of content in monospaced font. If more lines exist, append `… +N lines` truncation indicator. Tap to expand (existing behavior).

### Expanded state

No changes — already shows full content with "Hide output" button.

### Files to change

- `ToolUseView.swift` — `collapsedResultView()` method (lines 148-191)

### Risks

- **Riskiest assumption**: That "Command running in background" is the only prefix for background commands. If Claude Code changes this text, the detection breaks.
- **Verification**: Run a background Bash command and confirm the app shows "Running in background" instead of "Done". Run a normal command and confirm it shows a content preview.
- **Verify early**: The string detection can be tested by checking a transcript — already confirmed the pattern is consistent across multiple transcripts.
