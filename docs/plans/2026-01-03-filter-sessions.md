# Filter Sessions Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Filter out "Warmup" sessions and sessions with 0 messages from the session list.

**Architecture:** Add filtering logic in `list_sessions()` after parsing sessions, before returning.

**Tech Stack:** Python, pytest

---

## Task 1: Filter Warmup Sessions

**Files:**
- Modify: `voice_server/session_manager.py:74-103`
- Test: `voice_server/tests/test_session_manager.py` (create)

**Step 1: Write failing test for Warmup filter**

```python
def test_list_sessions_filters_warmup_sessions(tmp_path):
    """Sessions with titles starting with 'Warmup' should be filtered out"""
    projects_dir = tmp_path / "projects"
    project_folder = projects_dir / "test-project"
    project_folder.mkdir(parents=True)

    # Create a Warmup session
    warmup_session = project_folder / "warmup123.jsonl"
    warmup_session.write_text('{"message": {"role": "user", "content": "Warmup test"}}\n')

    # Create a normal session
    normal_session = project_folder / "normal456.jsonl"
    normal_session.write_text('{"message": {"role": "user", "content": "Hello Claude"}}\n')

    manager = SessionManager(str(projects_dir))
    sessions = manager.list_sessions("test-project")

    assert len(sessions) == 1
    assert sessions[0].id == "normal456"
```

**Step 2: Run test to verify it fails**

```bash
cd /Users/aaron/Desktop/max/voice_server/tests && pytest test_session_manager.py::test_list_sessions_filters_warmup_sessions -v
```

Expected: FAIL (returns 2 sessions instead of 1)

**Step 3: Implement Warmup filter in list_sessions()**

Add filtering after the session loop, before return:

```python
# Filter out Warmup sessions and empty sessions
sessions = [s for s in sessions if not s.title.startswith("Warmup")]
```

**Step 4: Run test to verify it passes**

```bash
cd /Users/aaron/Desktop/max/voice_server/tests && pytest test_session_manager.py::test_list_sessions_filters_warmup_sessions -v
```

Expected: PASS

**Step 5: Commit**

```bash
git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "feat: filter out Warmup sessions"
```

---

## Task 2: Filter Zero-Message Sessions

**Files:**
- Modify: `voice_server/session_manager.py:74-103`
- Test: `voice_server/tests/test_session_manager.py`

**Step 1: Write failing test for zero-message filter**

```python
def test_list_sessions_filters_zero_message_sessions(tmp_path):
    """Sessions with 0 messages should be filtered out"""
    projects_dir = tmp_path / "projects"
    project_folder = projects_dir / "test-project"
    project_folder.mkdir(parents=True)

    # Create an empty session (no user/assistant messages)
    empty_session = project_folder / "empty123.jsonl"
    empty_session.write_text('{"type": "system", "content": "init"}\n')

    # Create a session with messages
    normal_session = project_folder / "normal456.jsonl"
    normal_session.write_text('{"message": {"role": "user", "content": "Hello"}}\n')

    manager = SessionManager(str(projects_dir))
    sessions = manager.list_sessions("test-project")

    assert len(sessions) == 1
    assert sessions[0].id == "normal456"
```

**Step 2: Run test to verify it fails**

```bash
cd /Users/aaron/Desktop/max/voice_server/tests && pytest test_session_manager.py::test_list_sessions_filters_zero_message_sessions -v
```

Expected: FAIL (returns 2 sessions instead of 1)

**Step 3: Extend filter to include zero-message check**

```python
# Filter out Warmup sessions and empty sessions
sessions = [s for s in sessions if not s.title.startswith("Warmup") and s.message_count > 0]
```

**Step 4: Run test to verify it passes**

```bash
cd /Users/aaron/Desktop/max/voice_server/tests && pytest test_session_manager.py -v
```

Expected: PASS (both tests)

**Step 5: Commit**

```bash
git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "feat: filter out zero-message sessions"
```

---

## Task 3: Run Full Test Suite

**Step 1: Run all session_manager tests**

```bash
cd /Users/aaron/Desktop/max/voice_server/tests && pytest test_session_manager.py -v
```

**Step 2: Run existing server tests to ensure no regressions**

```bash
cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh
```

Expected: All tests pass
