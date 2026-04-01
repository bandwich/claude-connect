---
status: completed
created: 2026-03-31
completed: 2026-03-31
branch: feature/health-check-cleanup
---

# Health Check Cleanup

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix dead code, stale artifacts, doc drift, and code duplication identified by health check audit.

**Architecture:** Pure cleanup — delete cruft, remove unused code, update stale docs, consolidate duplicated functions, update imports.

**Tech Stack:** Python, bash

**Risky Assumptions:** Removing `tts_utils.py` re-export layer won't break anything not caught by tests. We'll verify by running the full test suite.

---

### Task 1: Delete build artifacts and bytecode

**Files:**
- Delete: `build/` (62 stale setuptools files)
- Delete: `server/**/__pycache__/` (21 .pyc files)

**Step 1: Delete build directory**

```bash
rm -rf build/
```

**Step 2: Delete __pycache__ directories**

```bash
find server/ -type d -name __pycache__ -exec rm -rf {} +
```

**Step 3: Verify cleanup**

```bash
ls build/ 2>&1        # Should say "No such file or directory"
find server/ -name "*.pyc" | wc -l   # Should be 0
```

**Step 4: Commit**

```bash
git add -A build/ && git rm -r --cached build/ 2>/dev/null; git add -u server/
git commit -m "fix: delete stale build/ and __pycache__ artifacts"
```

---

### Task 2: Remove unused test fixtures

**Files:**
- Modify: `server/tests/conftest.py` — remove lines 39-61 (3 fixtures: `sample_audio_data`, `sample_websocket_message`, `temp_transcript_dir`)

**Step 1: Remove the unused fixtures**

Delete these three fixtures from `conftest.py`:
- `sample_audio_data()` (lines 39-43)
- `sample_websocket_message()` (lines 46-53)
- `temp_transcript_dir()` (lines 56-60)

Also remove the `import numpy as np` on line 10 — it's only used by `sample_audio_data`.

Keep `temp_transcript_file`, `sample_transcript_data`, and `populated_transcript_file` — those are used.

**Step 2: Run tests to verify nothing breaks**

```bash
cd server/tests && ./run_tests.sh
```

Expected: all ~315 tests pass.

**Step 3: Commit**

```bash
git add server/tests/conftest.py
git commit -m "fix: remove 3 unused test fixtures from conftest.py"
```

---

### Task 3: Fix CLAUDE.md doc drift

**Files:**
- Modify: `CLAUDE.md:54` — change `server.py` to `main.py`
- Modify: `CLAUDE.md:88` — change `ClaudeConnectApp.swift` to `ClaudeVoiceApp.swift`

**Step 1: Fix server entry point reference**

Line 54: change `├─ server.py                  # Main WebSocket server (ConnectServer coordinator)` to `├─ main.py                    # Main WebSocket server (ConnectServer coordinator)`

**Step 2: Fix iOS app entry point reference**

Line 88: change `├─ ClaudeConnectApp.swift       # @main entry point, auto-connect on launch` to `├─ ClaudeVoiceApp.swift         # @main entry point, auto-connect on launch`

**Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: fix stale file references in CLAUDE.md"
```

---

### Task 4: Update plans INDEX.md

Already done during plan creation — health-check-cleanup added as Active. No additional steps needed.

---

### Task 5: Consolidate rewrite_user_text duplication

**Files:**
- Keep: `server/services/session_manager.py:12-22` — canonical location (transcript_watcher already imports from session_manager, so the dependency flows this direction)
- Modify: `server/services/transcript_watcher.py:27-39` — delete local `rewrite_user_text` and `IMAGE_SOURCE_RE`, import from session_manager

**Important:** transcript_watcher already imports `HIDDEN_TOOLS` from session_manager (line 23). Adding `rewrite_user_text` to that import avoids circular imports. Going the other direction (session_manager importing from transcript_watcher) would create a circular import.

**Step 1: Update transcript_watcher.py**

Remove lines 27-39 (the `IMAGE_SOURCE_RE` regex and `rewrite_user_text` function definition).

Update the existing import on line 23 to also import `rewrite_user_text`:

```python
from server.services.session_manager import HIDDEN_TOOLS, rewrite_user_text
```

The call sites at lines ~281 and ~293 will now use the imported version.

**Step 2: Run tests**

```bash
cd server/tests && ./run_tests.sh
```

Expected: all tests pass — both modules use the same logic.

**Step 3: Commit**

```bash
git add server/services/transcript_watcher.py
git commit -m "refactor: consolidate duplicate rewrite_user_text into session_manager"
```

---

### Task 6: Remove tts_utils.py re-export layer

**Files:**
- Modify: `server/run-kokoro.py:10` — change import from `server.tts_utils` to `server.services.tts_manager`
- Modify: `server/integration_tests/generate_test_audio.py:11` — same
- Modify: `server/integration_tests/test_server.py:17` — same
- Modify: `server/tests/test_tts_utils.py:290-306` — delete `TestLegacyReExport` class (tests the re-export itself)
- Delete: `server/tts_utils.py`
- Modify: `CLAUDE.md:55` — remove `tts_utils.py` from project structure
- Modify: `server/CLAUDE.md:129` — remove `tts_utils.py` from module diagram

**Step 1: Update imports in 3 files**

`server/run-kokoro.py:10`:
```python
from server.services.tts_manager import generate_tts_audio, save_wav
```

`server/integration_tests/generate_test_audio.py:11`:
```python
from server.services.tts_manager import save_wav
```

`server/integration_tests/test_server.py:17`:
```python
from server.services.tts_manager import samples_to_wav_bytes
```

**Step 2: Remove TestLegacyReExport test class**

Delete the `TestLegacyReExport` class (lines 290-306) from `server/tests/test_tts_utils.py`.

**Step 3: Delete tts_utils.py**

```bash
rm server/tts_utils.py
```

**Step 4: Update docs**

In `CLAUDE.md`, remove line 55 (`├─ tts_utils.py               # Re-exports from services/tts_manager.py`).

In `server/CLAUDE.md`, remove line 129 (`└── tts_utils.py           — re-exports from services/tts_manager.py`), and update the previous line's `├──` to `└──` since it becomes the last item.

**Step 5: Run tests**

```bash
cd server/tests && ./run_tests.sh
```

Expected: all tests pass (minus the 3 deleted re-export tests).

**Step 6: Commit**

```bash
git add server/run-kokoro.py server/integration_tests/generate_test_audio.py server/integration_tests/test_server.py server/tests/test_tts_utils.py CLAUDE.md server/CLAUDE.md
git rm server/tts_utils.py
git commit -m "refactor: remove tts_utils.py re-export layer, import from tts_manager directly"
```

---

### Task 7: Final verification

**Step 1: Run full test suite**

```bash
cd server/tests && ./run_tests.sh
```

Expected: all tests pass.

**Step 2: Verify pipx install still works**

```bash
pipx install --force /Users/aaron/Desktop/max
```

Expected: installs cleanly, `claude-connect` command available.
