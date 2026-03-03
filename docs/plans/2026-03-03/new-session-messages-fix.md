# New Session Messages Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix the bug where creating a new session from the iOS app shows no assistant messages — only permission prompts appear.

**Architecture:** Two bugs: (1) `handle_new_session` uses `find_newest_session` which returns an OLD session file before the new one is created, so the watcher monitors the wrong file forever. (2) `set_session_file` skips all existing lines, which is correct for resumed sessions (history sent separately) but wrong for new sessions. Fix by snapshotting existing session IDs before starting Claude, polling for a genuinely new ID, and adding a `from_beginning` flag to start the watcher at line 0 for new sessions.

**Tech Stack:** Python, pytest

**Risky Assumptions:** Claude Code creates the new `.jsonl` file within 10 seconds of `claude` starting. We'll verify this with the existing poll timeout and add logging if it fails.

---

### Task 1: Add `list_session_ids` and `find_new_session` to SessionManager

**Files:**
- Modify: `voice_server/session_manager.py:141-165` (add methods after `find_newest_session`)
- Test: `voice_server/tests/test_session_manager.py`

**Step 1: Write the failing tests**

Add to `voice_server/tests/test_session_manager.py`:

```python
def test_list_session_ids_returns_all_ids(self, tmp_path):
    """list_session_ids returns set of all session IDs in a folder"""
    from session_manager import SessionManager

    project_dir = tmp_path / "-Users-test-project"
    project_dir.mkdir()
    (project_dir / "abc123.jsonl").write_text('{"message": {"role": "user", "content": "hi"}}\n')
    (project_dir / "def456.jsonl").write_text('{"message": {"role": "user", "content": "hi"}}\n')
    (project_dir / "agent-xyz.jsonl").write_text('{"message": {"role": "user", "content": "hi"}}\n')

    manager = SessionManager(projects_dir=str(tmp_path))
    ids = manager.list_session_ids("-Users-test-project")

    assert ids == {"abc123", "def456"}  # agent- files excluded

def test_list_session_ids_empty_folder(self, tmp_path):
    """list_session_ids returns empty set for nonexistent folder"""
    from session_manager import SessionManager
    manager = SessionManager(projects_dir=str(tmp_path))
    ids = manager.list_session_ids("nonexistent")
    assert ids == set()

def test_find_new_session_detects_new_file(self, tmp_path):
    """find_new_session returns a session ID not in the exclude set"""
    from session_manager import SessionManager

    project_dir = tmp_path / "-Users-test-project"
    project_dir.mkdir()
    (project_dir / "old-session.jsonl").write_text('{"message": {"role": "user", "content": "hi"}}\n')

    manager = SessionManager(projects_dir=str(tmp_path))
    existing = manager.list_session_ids("-Users-test-project")
    assert existing == {"old-session"}

    # Simulate Claude creating a new session file
    (project_dir / "new-session.jsonl").write_text('{"message": {"role": "user", "content": "hello"}}\n')

    result = manager.find_new_session("-Users-test-project", existing)
    assert result == "new-session"

def test_find_new_session_returns_none_when_no_new(self, tmp_path):
    """find_new_session returns None when all sessions are in exclude set"""
    from session_manager import SessionManager

    project_dir = tmp_path / "-Users-test-project"
    project_dir.mkdir()
    (project_dir / "old-session.jsonl").write_text('{"message": {"role": "user", "content": "hi"}}\n')

    manager = SessionManager(projects_dir=str(tmp_path))
    existing = manager.list_session_ids("-Users-test-project")

    result = manager.find_new_session("-Users-test-project", existing)
    assert result is None
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && source ../../.venv/bin/activate && pytest test_session_manager.py -v -k "list_session_ids or find_new_session"`

Expected: FAIL — `AttributeError: 'SessionManager' object has no attribute 'list_session_ids'`

**Step 3: Write minimal implementation**

Add to `voice_server/session_manager.py` after `find_newest_session` (after line 165):

```python
def list_session_ids(self, folder_name: str) -> set[str]:
    """Return set of all session IDs (excluding agent files) in a folder.

    Args:
        folder_name: The folder name in projects_dir

    Returns:
        Set of session ID strings
    """
    folder_path = os.path.join(self.projects_dir, folder_name)
    if not os.path.exists(folder_path):
        return set()

    session_files = glob.glob(os.path.join(folder_path, "*.jsonl"))
    session_files = [f for f in session_files if not os.path.basename(f).startswith("agent-")]
    return {os.path.splitext(os.path.basename(f))[0] for f in session_files}

def find_new_session(self, folder_name: str, exclude_ids: set[str]) -> Optional[str]:
    """Find a session ID that is not in the exclude set.

    Used to detect a newly created session after snapshotting existing IDs.

    Args:
        folder_name: The folder name in projects_dir
        exclude_ids: Session IDs to exclude (the snapshot taken before creation)

    Returns:
        Session ID of the new session, or None if no new session found
    """
    current_ids = self.list_session_ids(folder_name)
    new_ids = current_ids - exclude_ids
    if not new_ids:
        return None
    # If multiple new IDs (unlikely), return the newest by mtime
    if len(new_ids) == 1:
        return new_ids.pop()
    folder_path = os.path.join(self.projects_dir, folder_name)
    newest = max(new_ids, key=lambda sid: os.path.getmtime(os.path.join(folder_path, f"{sid}.jsonl")))
    return newest
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && source ../../.venv/bin/activate && pytest test_session_manager.py -v -k "list_session_ids or find_new_session"`

Expected: All 4 new tests PASS

**Step 5: Commit**

```bash
git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "feat: add list_session_ids and find_new_session to SessionManager"
```

---

### Task 2: Add `from_beginning` parameter to `set_session_file`

**Files:**
- Modify: `voice_server/ios_server.py:354-369` (update `set_session_file`)
- Test: `voice_server/tests/test_transcript_watcher.py`

**Step 1: Write the failing test**

Check what's already in the transcript watcher tests, then add:

```python
def test_set_session_file_from_beginning_starts_at_zero(self, tmp_path):
    """set_session_file with from_beginning=True should set processed_line_count to 0"""
    # Create a file with existing content
    session_file = tmp_path / "session.jsonl"
    session_file.write_text('{"line": 1}\n{"line": 2}\n{"line": 3}\n')

    handler = make_transcript_handler()  # Use existing test helper
    handler.set_session_file(str(session_file), from_beginning=True)

    assert handler.processed_line_count == 0

def test_set_session_file_default_skips_existing(self, tmp_path):
    """set_session_file without from_beginning should skip existing lines"""
    session_file = tmp_path / "session.jsonl"
    session_file.write_text('{"line": 1}\n{"line": 2}\n{"line": 3}\n')

    handler = make_transcript_handler()
    handler.set_session_file(str(session_file))

    assert handler.processed_line_count == 3
```

Note: Look at the existing test file to see how `TranscriptHandler` is instantiated in tests. Adapt the helper function name accordingly.

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && source ../../.venv/bin/activate && pytest test_transcript_watcher.py -v -k "set_session_file"`

Expected: FAIL — `TypeError: set_session_file() got an unexpected keyword argument 'from_beginning'`

**Step 3: Write minimal implementation**

Edit `voice_server/ios_server.py` — update `set_session_file`:

```python
def set_session_file(self, file_path: Optional[str], from_beginning: bool = False):
    """Set the expected session file and initialize line count.

    When switching sessions, we initialize the line count to the current
    number of lines in the file, so only NEW content triggers callbacks.
    For new sessions, use from_beginning=True to process all content.
    """
    with self._lock:
        self.expected_session_file = file_path
        self.hidden_tool_ids = set()  # Reset on session switch
        if from_beginning:
            self.processed_line_count = 0
            print(f"[INFO] Watching session file: {file_path} (from beginning)")
        elif file_path and os.path.exists(file_path):
            with open(file_path, 'r') as f:
                self.processed_line_count = sum(1 for _ in f)
            print(f"[INFO] Watching session file: {file_path} (starting at line {self.processed_line_count})")
        else:
            self.processed_line_count = 0
            print(f"[INFO] Watching session file: {file_path} (new file)")
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && source ../../.venv/bin/activate && pytest test_transcript_watcher.py -v -k "set_session_file"`

Expected: PASS

**Step 5: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_transcript_watcher.py
git commit -m "feat: add from_beginning parameter to set_session_file"
```

---

### Task 3: Add `from_beginning` parameter to `switch_watched_session`

**Files:**
- Modify: `voice_server/ios_server.py:457-502` (update `switch_watched_session`)

**Step 1: Update `switch_watched_session` to pass through `from_beginning`**

```python
def switch_watched_session(self, folder_name: str, session_id: str, from_beginning: bool = False) -> bool:
```

And on line 482, change:

```python
self.transcript_handler.set_session_file(new_path)
```

to:

```python
self.transcript_handler.set_session_file(new_path, from_beginning=from_beginning)
```

**Step 2: Run all tests to verify nothing breaks**

Run: `cd voice_server/tests && source ../../.venv/bin/activate && pytest -v`

Expected: All existing tests still PASS (default `from_beginning=False` preserves old behavior)

**Step 3: Commit**

```bash
git add voice_server/ios_server.py
git commit -m "feat: pass from_beginning through switch_watched_session"
```

---

### Task 4: Update `handle_new_session` to use snapshot detection

**Files:**
- Modify: `voice_server/ios_server.py:1110-1133` (update `handle_new_session`)

**Step 1: Update `handle_new_session`**

Replace the entire method body (lines 1110-1142) with:

```python
async def handle_new_session(self, websocket, data):
    """Handle new_session request - starts claude in tmux"""
    project_path = data.get("project_path", "")
    print(f"[DEBUG] handle_new_session: project_path={project_path}")

    # Snapshot existing session IDs BEFORE starting Claude (avoids race condition)
    existing_ids = set()
    folder_name = None
    if project_path:
        folder_name = self.session_manager.encode_path_to_folder(project_path)
        existing_ids = self.session_manager.list_session_ids(folder_name)
        print(f"[DEBUG] Snapshot: {len(existing_ids)} existing sessions in {folder_name}")

    success = self.tmux.start_session(working_dir=project_path if project_path else None)
    print(f"[DEBUG] start_session returned: {success}, session_exists: {self.tmux.session_exists()}")

    if success:
        self.active_session_id = None  # New session has no ID yet

        # Poll for a NEW session ID not in the snapshot
        if folder_name:
            session_id = await poll_for_session_file(
                find_fn=lambda: self.session_manager.find_new_session(folder_name, existing_ids),
                timeout=10.0,
                interval=0.2
            )
            if session_id:
                print(f"[DEBUG] Found new session: {session_id}")
                self.active_session_id = session_id
                self.switch_watched_session(folder_name, session_id, from_beginning=True)
            else:
                print(f"[WARN] Timed out waiting for new session file")

    response = {
        "type": "session_created",
        "success": success
    }
    await websocket.send(json.dumps(response))

    if success:
        await self.broadcast_connection_status()
```

Key changes:
1. Snapshot `existing_ids` **before** `start_session` (eliminates race condition)
2. Use `find_new_session(folder_name, existing_ids)` instead of `find_newest_session(folder_name)`
3. Pass `from_beginning=True` to `switch_watched_session`

**Step 2: Run all tests**

Run: `cd voice_server/tests && source ../../.venv/bin/activate && pytest -v`

Expected: All tests PASS

**Step 3: Commit**

```bash
git add voice_server/ios_server.py
git commit -m "fix: detect new session file by snapshot diff instead of mtime"
```

---

### Task 5: Manual verification

**Step 1: Reinstall server**

```bash
pipx install --force /Users/aaron/Desktop/max
```

**Step 2: Start server and create a new session from the iOS app**

CHECKPOINT: Verify all of the following in server logs:

1. `[DEBUG] Existing session IDs: <N>` — shows the snapshot was taken
2. `[DEBUG] Found new session: <new-uuid>` — a UUID different from any existing session
3. `[INFO] Watching session file: .../<new-uuid>.jsonl (from beginning)` — starts at line 0, NOT line 244+
4. `[RECONCILE] ... file_lines=<growing number>` — file_lines increases as Claude works
5. Assistant messages appear in the iOS app

If step 3 shows `(starting at line <non-zero>)` instead of `(from beginning)`, the `from_beginning` flag isn't being passed correctly — check Task 3.

If step 2 shows the same UUID as an existing session, the snapshot detection isn't working — check Task 1.
