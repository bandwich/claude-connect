# Fix: New Session Assistant Messages Not Appearing

## Problem

When creating a new session from the iOS app, assistant messages never appear. The app shows "Thinking..." and only permission prompts come through. The terminal shows Claude is actively working.

**Root cause:** Two bugs in `handle_new_session`:

1. **Wrong file detected.** `find_newest_session` sorts by modification time and returns the most recently modified `.jsonl`. When a new session is starting, the old session file is still the newest — Claude hasn't created the new file yet. The server latches onto the old file and watches it forever.

2. **Initial lines skipped.** Even if the correct file were found, `set_session_file` sets `processed_line_count` to the current line count, skipping any content already written. This is correct for resumed sessions (history is sent separately) but wrong for new sessions where no history load occurs.

**Evidence from logs:**
```
[INFO] Watching session file: ...e87d68c6-...jsonl (starting at line 244)
[RECONCILE] tick=90, processed=244, file_lines=244, gap=0   # never grows
[RECONCILE] tick=100, processed=244, file_lines=244, gap=0  # wrong file
```

## Fix

### Change 1: Snapshot + detect new session ID

In `handle_new_session`, before starting Claude:

```python
# Snapshot existing session IDs
existing_ids = set(self.session_manager.list_session_ids(folder_name))

# Start Claude
self.tmux.start_session(working_dir=project_path)

# Poll for a NEW session ID not in the snapshot
session_id = await poll_for_session_file(
    find_fn=lambda: self.session_manager.find_new_session(folder_name, existing_ids),
    timeout=10.0,
    interval=0.2
)
```

Add `list_session_ids(folder_name)` to `session_manager.py` — returns set of all session IDs in a folder.

Add `find_new_session(folder_name, exclude_ids)` to `session_manager.py` — returns the newest session ID that isn't in `exclude_ids`, or None.

### Change 2: Start watcher at line 0 for new sessions

Add a `from_beginning` parameter to `set_session_file`:

```python
def set_session_file(self, file_path, from_beginning=False):
    with self._lock:
        self.expected_session_file = file_path
        self.hidden_tool_ids = set()
        if from_beginning:
            self.processed_line_count = 0
        elif file_path and os.path.exists(file_path):
            self.processed_line_count = sum(1 for _ in f)
        else:
            self.processed_line_count = 0
```

Call with `from_beginning=True` in `handle_new_session`. All other callers keep the default behavior.

### Risks

**Riskiest assumption:** That `find_new_session` will reliably detect the new file within 10 seconds.

**Verification:** Create a new session from the app and confirm:
- Server log shows `(starting at line 0)` for a new UUID (not the old session's UUID)
- Reconciliation shows `file_lines` growing
- Assistant messages appear in the iOS app

**Early verification:** Can test the `find_new_session` logic in isolation with a unit test — create a folder with known files, add a new one, verify detection.

## Files to Change

1. `voice_server/session_manager.py` — add `list_session_ids()` and `find_new_session()`
2. `voice_server/ios_server.py` — update `handle_new_session()` and `set_session_file()`
3. `voice_server/tests/` — unit tests for new session_manager methods + integration test for the flow
