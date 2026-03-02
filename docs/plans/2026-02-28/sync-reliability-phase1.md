# Sync Reliability Phase 1: Server-Side Fixes

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix message dropping in the transcript watcher so the iOS app reliably receives all assistant responses, tool results, and user messages.

**Architecture:** Add thread safety to `TranscriptHandler`, replace hardcoded sleeps with file-existence polling, and add a reconciliation loop that catches any lines watchdog misses. All changes are server-side only — the existing iOS app benefits immediately.

**Tech Stack:** Python, asyncio, threading, watchdog, pytest

**Risky Assumptions:** The reconciliation loop re-extracting missed lines won't cause duplicates on the iOS side (since the same content blocks get sent twice). We verify early in Task 2 with a test that simulates this exact scenario.

---

### Task 1: Add threading.Lock to TranscriptHandler

**Files:**
- Modify: `voice_server/ios_server.py:81-101` (TranscriptHandler.__init__)
- Modify: `voice_server/ios_server.py:103-166` (on_modified)
- Modify: `voice_server/ios_server.py:302-316` (set_session_file)
- Modify: `voice_server/ios_server.py:318-321` (reset_tracking_state)
- Test: `voice_server/tests/test_transcript_watcher.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_transcript_watcher.py`:

```python
import threading

class TestTranscriptHandlerThreadSafety:
    """Tests for thread-safe access to processed_line_count and expected_session_file"""

    def test_concurrent_set_session_and_on_modified(self, tmp_path):
        """set_session_file and on_modified can run concurrently without corruption"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        content_received = []

        async def content_callback(response):
            content_received.append(response)

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        # Write 100 lines to the file
        with open(transcript_file, "a") as f:
            for i in range(100):
                msg = {
                    "type": "assistant",
                    "message": {"role": "assistant", "content": f"Message {i}"},
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(msg) + "\n")

        # Simulate concurrent access: on_modified from watchdog thread
        # while set_session_file runs from main thread
        errors = []

        class FakeEvent:
            is_directory = False
            src_path = str(transcript_file)

        def call_on_modified():
            try:
                for _ in range(50):
                    handler.on_modified(FakeEvent())
            except Exception as e:
                errors.append(e)

        def call_set_session():
            try:
                for _ in range(50):
                    handler.set_session_file(str(transcript_file))
            except Exception as e:
                errors.append(e)

        t1 = threading.Thread(target=call_on_modified)
        t2 = threading.Thread(target=call_set_session)
        t1.start()
        t2.start()
        t1.join()
        t2.join()

        loop.close()
        assert not errors, f"Concurrent access raised: {errors}"
        # Verify handler has a lock attribute
        assert hasattr(handler, '_lock')
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_transcript_watcher.py::TestTranscriptHandlerThreadSafety -v`
Expected: FAIL — `AttributeError: 'TranscriptHandler' object has no attribute '_lock'`

**Step 3: Add the lock to TranscriptHandler**

In `voice_server/ios_server.py`, modify `TranscriptHandler.__init__` to add:

```python
import threading

# In __init__, after existing fields:
self._lock = threading.Lock()
```

Modify `on_modified` to acquire the lock around shared state access:

```python
def on_modified(self, event):
    if event.is_directory or not event.src_path.endswith('.jsonl'):
        return

    filename = os.path.basename(event.src_path)
    if filename.startswith('agent-'):
        return

    with self._lock:
        if self.expected_session_file:
            if os.path.realpath(event.src_path) != os.path.realpath(self.expected_session_file):
                return

        try:
            new_blocks, user_texts = self.extract_new_content(event.src_path)
        except Exception as e:
            print(f"Error processing transcript: {e}")
            import traceback
            traceback.print_exc()
            return

    # Send callbacks OUTSIDE the lock (they schedule async work)
    try:
        if new_blocks:
            response = AssistantResponse(
                content_blocks=new_blocks,
                timestamp=time.time(),
                is_incremental=True
            )

            asyncio.run_coroutine_threadsafe(
                self.content_callback(response),
                self.loop
            )

            if not self.server or self.server.active_session_id:
                text = extract_text_for_tts(new_blocks)
                if text:
                    asyncio.run_coroutine_threadsafe(
                        self.audio_callback(text),
                        self.loop
                    )
                else:
                    asyncio.run_coroutine_threadsafe(
                        self.server.send_idle_to_all_clients(),
                        self.loop
                    )

        if user_texts and self.user_callback:
            for user_text in user_texts:
                asyncio.run_coroutine_threadsafe(
                    self.user_callback(user_text),
                    self.loop
                )

        if self.server and getattr(self.server, 'active_session_id', None):
            self.broadcast_context_update(event.src_path, self.server.active_session_id)
    except Exception as e:
        print(f"Error processing transcript: {e}")
        import traceback
        traceback.print_exc()
```

Modify `set_session_file` to acquire the lock:

```python
def set_session_file(self, file_path: Optional[str]):
    with self._lock:
        self.expected_session_file = file_path
        self.hidden_tool_ids = set()
        if file_path and os.path.exists(file_path):
            with open(file_path, 'r') as f:
                self.processed_line_count = sum(1 for _ in f)
            print(f"[INFO] Watching session file: {file_path} (starting at line {self.processed_line_count})")
        else:
            self.processed_line_count = 0
            print(f"[INFO] Watching session file: {file_path} (new file)")
```

Modify `reset_tracking_state` to acquire the lock:

```python
def reset_tracking_state(self):
    with self._lock:
        self.processed_line_count = 0
        self.expected_session_file = None
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_transcript_watcher.py::TestTranscriptHandlerThreadSafety -v`
Expected: PASS

**Step 5: Run all existing transcript watcher tests**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_transcript_watcher.py -v`
Expected: All PASS (lock doesn't change behavior, just adds safety)

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_transcript_watcher.py
git commit -m "fix: add threading lock to TranscriptHandler for thread safety"
```

---

### Task 2: Replace hardcoded sleep with file-existence polling

**Files:**
- Modify: `voice_server/ios_server.py:868-896` (handle_new_session)
- Modify: `voice_server/ios_server.py:898-930` (handle_resume_session)
- Modify: `voice_server/ios_server.py:1040-1070` (handle_add_project, if it has the sleep)
- Test: `voice_server/tests/test_transcript_watcher.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_transcript_watcher.py`:

```python
class TestSessionFilePolling:
    """Tests for poll-based session file discovery"""

    @pytest.mark.asyncio
    async def test_poll_for_session_file_finds_existing(self, tmp_path):
        """poll_for_session_file returns immediately for existing file"""
        from voice_server.ios_server import poll_for_session_file

        transcript = tmp_path / "session.jsonl"
        transcript.write_text("")

        result = await poll_for_session_file(
            find_fn=lambda: str(transcript),
            timeout=2.0,
            interval=0.1
        )
        assert result == str(transcript)

    @pytest.mark.asyncio
    async def test_poll_for_session_file_waits_for_creation(self, tmp_path):
        """poll_for_session_file waits until file appears"""
        from voice_server.ios_server import poll_for_session_file

        transcript = tmp_path / "session.jsonl"
        call_count = 0

        def delayed_find():
            nonlocal call_count
            call_count += 1
            if call_count >= 3:
                transcript.write_text("")
                return str(transcript)
            return None

        result = await poll_for_session_file(
            find_fn=delayed_find,
            timeout=5.0,
            interval=0.1
        )
        assert result == str(transcript)
        assert call_count >= 3

    @pytest.mark.asyncio
    async def test_poll_for_session_file_returns_none_on_timeout(self):
        """poll_for_session_file returns None if file never appears"""
        from voice_server.ios_server import poll_for_session_file

        result = await poll_for_session_file(
            find_fn=lambda: None,
            timeout=0.5,
            interval=0.1
        )
        assert result is None
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_transcript_watcher.py::TestSessionFilePolling -v`
Expected: FAIL — `ImportError: cannot import name 'poll_for_session_file'`

**Step 3: Implement poll_for_session_file and update handlers**

Add the `poll_for_session_file` function near the top of `voice_server/ios_server.py` (after imports, before `TranscriptHandler` class):

```python
async def poll_for_session_file(find_fn, timeout=10.0, interval=0.2):
    """Poll for a session transcript file to appear.

    Args:
        find_fn: Callable that returns file path or None
        timeout: Max seconds to wait
        interval: Seconds between polls

    Returns:
        File path string, or None if timeout
    """
    elapsed = 0.0
    while elapsed < timeout:
        result = find_fn()
        if result:
            return result
        await asyncio.sleep(interval)
        elapsed += interval
    return None
```

Update `handle_new_session` — replace `await asyncio.sleep(2.0)` block:

```python
async def handle_new_session(self, websocket, data):
    """Handle new_session request - starts claude in tmux"""
    project_path = data.get("project_path", "")
    print(f"[DEBUG] handle_new_session: project_path={project_path}")
    success = self.tmux.start_session(working_dir=project_path if project_path else None)
    print(f"[DEBUG] start_session returned: {success}, session_exists: {self.tmux.session_exists()}")

    if success:
        self.active_session_id = None  # New session has no ID yet

        # Find and watch the new session's transcript
        if project_path:
            folder_name = self.session_manager.encode_path_to_folder(project_path)
            print(f"[DEBUG] Encoded folder name: {folder_name}")

            session_file = await poll_for_session_file(
                find_fn=lambda: self.session_manager.find_newest_session(folder_name),
                timeout=10.0,
                interval=0.2
            )
            if session_file:
                session_id = session_file  # find_newest_session returns session_id
                print(f"[DEBUG] Found new session: {session_id}")
                self.active_session_id = session_id
                self.switch_watched_session(folder_name, session_id)

    response = {
        "type": "session_created",
        "success": success
    }
    await websocket.send(json.dumps(response))

    if success:
        await self.broadcast_connection_status()
```

Update `handle_resume_session` — replace `await asyncio.sleep(2.0)`:

```python
async def handle_resume_session(self, websocket, data):
    """Handle resume_session request - runs 'claude --resume <id>' in tmux"""
    session_id = data.get("session_id", "")
    folder_name = data.get("folder_name", "")
    success = False

    if session_id:
        working_dir = None
        if folder_name and session_id:
            working_dir = self.session_manager.get_session_cwd(folder_name, session_id)
            print(f"[DEBUG] handle_resume_session: get_session_cwd -> {working_dir}")

        success = self.tmux.start_session(working_dir=working_dir, resume_id=session_id)
        print(f"[DEBUG] start_session(resume_id={session_id}) returned: {success}, session_exists: {self.tmux.session_exists()}")

        if success:
            self.active_session_id = session_id

            # Wait for transcript file to exist (Claude may need a moment to start writing)
            transcript_path = self.get_session_transcript_path(folder_name, session_id)
            if not transcript_path:
                transcript_path = await poll_for_session_file(
                    find_fn=lambda: self.get_session_transcript_path(folder_name, session_id),
                    timeout=10.0,
                    interval=0.2
                )

            if folder_name:
                self.switch_watched_session(folder_name, session_id)
        else:
            print(f"[ERROR] Failed to start tmux session for resume_id={session_id}")

    response = {
        "type": "session_resumed",
        "success": success,
        "session_id": session_id
    }
    await websocket.send(json.dumps(response))

    if success:
        await self.broadcast_connection_status()
```

Update `handle_add_project` — replace its `await asyncio.sleep(2.0)` similarly (replace the sleep with a brief poll, though this is less critical since add_project creates a brand new session).

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_transcript_watcher.py::TestSessionFilePolling -v`
Expected: PASS

**Step 5: Install pytest-asyncio if needed**

The tests use `@pytest.mark.asyncio`. Check if the project already has it:

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pip list | grep asyncio`

If not installed: `.venv/bin/pip install pytest-asyncio` and add to `voice_server/tests/requirements-test.txt`.

**Step 6: Run all server tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All PASS

**Step 7: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_transcript_watcher.py
git commit -m "fix: replace hardcoded sleep with file-existence polling for session startup"
```

---

### Task 3: Add reconciliation loop

**Files:**
- Modify: `voice_server/ios_server.py` (TranscriptHandler class — add `reconciliation_loop` method)
- Modify: `voice_server/ios_server.py` (VoiceServer — start/stop reconciliation loop on session open/close)
- Test: `voice_server/tests/test_transcript_watcher.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_transcript_watcher.py`:

```python
class TestReconciliationLoop:
    """Tests for the reconciliation loop that catches missed watchdog events"""

    def test_reconciliation_detects_gap(self, tmp_path):
        """reconcile() finds and returns lines that watchdog missed"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        content_received = []

        async def content_callback(response):
            content_received.append(response)

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        # Write lines WITHOUT triggering on_modified (simulating watchdog miss)
        with open(transcript_file, "a") as f:
            for i in range(5):
                msg = {
                    "type": "assistant",
                    "message": {"role": "assistant", "content": [{"type": "text", "text": f"Missed msg {i}"}]},
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(msg) + "\n")

        # processed_line_count is still 0, but file has 5 lines
        assert handler.processed_line_count == 0

        # Run reconciliation
        new_blocks, user_texts = handler.reconcile()
        assert len(new_blocks) == 5
        assert handler.processed_line_count == 5

    def test_reconciliation_no_gap(self, tmp_path):
        """reconcile() returns empty when no lines were missed"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        async def content_callback(response):
            pass

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        # No lines written — no gap
        new_blocks, user_texts = handler.reconcile()
        assert len(new_blocks) == 0
        assert len(user_texts) == 0

    def test_reconciliation_with_lock(self, tmp_path):
        """reconcile() acquires the lock to prevent races with on_modified"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        async def content_callback(response):
            pass

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        # Write a line
        with open(transcript_file, "a") as f:
            msg = {
                "type": "assistant",
                "message": {"role": "assistant", "content": "Test"},
                "timestamp": "2026-01-01T00:00:00Z"
            }
            f.write(json.dumps(msg) + "\n")

        # Hold the lock — reconcile should block
        acquired = threading.Event()
        released = threading.Event()

        def hold_lock():
            with handler._lock:
                acquired.set()
                released.wait(timeout=5.0)

        t = threading.Thread(target=hold_lock)
        t.start()
        acquired.wait()

        # reconcile should block because lock is held
        # Run in thread to avoid blocking test
        result = [None]
        def run_reconcile():
            result[0] = handler.reconcile()
        t2 = threading.Thread(target=run_reconcile)
        t2.start()

        # Give t2 a moment to start, then release
        time.sleep(0.1)
        assert t2.is_alive(), "reconcile should be blocked waiting for lock"
        released.set()

        t.join()
        t2.join()

        blocks, texts = result[0]
        assert len(blocks) == 1  # Got the line after lock was released

        loop.close()
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_transcript_watcher.py::TestReconciliationLoop -v`
Expected: FAIL — `AttributeError: 'TranscriptHandler' object has no attribute 'reconcile'`

**Step 3: Implement reconcile() method and the async reconciliation loop**

Add `reconcile()` to `TranscriptHandler`:

```python
def reconcile(self):
    """Check for lines that watchdog missed and extract their content.

    Returns:
        (content_blocks, user_texts) — same format as extract_new_content
    """
    with self._lock:
        if not self.expected_session_file or not os.path.exists(self.expected_session_file):
            return [], []
        return self.extract_new_content(self.expected_session_file)
```

Add `start_reconciliation_loop()` and `stop_reconciliation_loop()` to `VoiceServer`:

```python
async def _reconciliation_loop(self):
    """Periodically check for lines watchdog missed and send them to clients."""
    try:
        while True:
            await asyncio.sleep(3.0)
            if not self.active_session_id or not self.transcript_handler:
                continue

            new_blocks, user_texts = self.transcript_handler.reconcile()

            if new_blocks:
                print(f"[RECONCILE] Found {len(new_blocks)} missed blocks")
                response = AssistantResponse(
                    content_blocks=new_blocks,
                    timestamp=time.time(),
                    is_incremental=True
                )
                await self.handle_content_response(response)

                if not self.tts_enabled:
                    await self.send_idle_to_all_clients()

            if user_texts:
                print(f"[RECONCILE] Found {len(user_texts)} missed user messages")
                for text in user_texts:
                    await self.handle_user_message(text)

    except asyncio.CancelledError:
        pass
```

In `VoiceServer.__init__`, add:
```python
self._reconciliation_task = None
```

Start the loop when a session is opened. In `switch_watched_session`, after the existing code, add:
```python
# Start reconciliation loop if not already running
if self._reconciliation_task is None or self._reconciliation_task.done():
    self._reconciliation_task = asyncio.ensure_future(self._reconciliation_loop())
```

Stop it in `handle_close_session`, before clearing `active_session_id`:
```python
if self._reconciliation_task and not self._reconciliation_task.done():
    self._reconciliation_task.cancel()
    self._reconciliation_task = None
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_transcript_watcher.py::TestReconciliationLoop -v`
Expected: PASS

**Step 5: Run all server tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All PASS

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_transcript_watcher.py
git commit -m "feat: add reconciliation loop to catch missed transcript lines"
```

---

### Task 4: Integration test — rapid transcript writes

**Files:**
- Create: `voice_server/tests/test_sync_integration.py`

**Step 1: Write the integration test**

Create `voice_server/tests/test_sync_integration.py`:

```python
"""Integration tests for transcript sync reliability.

These tests simulate rapid transcript writes and verify
all lines are received by the handler.
"""
import pytest
import asyncio
import json
import time
import os
import threading

from watchdog.observers import Observer
from voice_server.ios_server import TranscriptHandler
from voice_server.content_models import AssistantResponse


class TestSyncReliability:
    """End-to-end sync reliability tests with real file watching"""

    def test_rapid_writes_all_received(self, tmp_path):
        """50 rapid transcript lines are all received via watchdog + reconciliation"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        received_texts = []

        async def content_callback(response):
            for block in response.content_blocks:
                if hasattr(block, 'text'):
                    received_texts.append(block.text)

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        observer = Observer()
        observer.schedule(handler, str(tmp_path))
        observer.start()

        try:
            time.sleep(0.5)

            # Write 50 lines rapidly (simulates Claude producing fast output)
            with open(transcript_file, "a") as f:
                for i in range(50):
                    msg = {
                        "type": "assistant",
                        "message": {
                            "role": "assistant",
                            "content": [{"type": "text", "text": f"Line {i}"}]
                        },
                        "timestamp": "2026-01-01T00:00:00Z"
                    }
                    f.write(json.dumps(msg) + "\n")
                    f.flush()

            # Wait for watchdog to process
            time.sleep(2.0)
            loop.run_until_complete(asyncio.sleep(0.1))

            # Run reconciliation to catch any lines watchdog missed
            missed_blocks, _ = handler.reconcile()
            if missed_blocks:
                for block in missed_blocks:
                    if hasattr(block, 'text'):
                        received_texts.append(block.text)

        finally:
            observer.stop()
            observer.join()
            loop.close()

        # Verify all 50 lines were received (via watchdog + reconciliation)
        expected = {f"Line {i}" for i in range(50)}
        actual = set(received_texts)
        missing = expected - actual
        assert not missing, f"Missing {len(missing)} lines: {sorted(missing)[:5]}..."

    def test_tool_use_and_result_both_received(self, tmp_path):
        """Tool use block followed by tool result are both received"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        received_blocks = []

        async def content_callback(response):
            received_blocks.extend(response.content_blocks)

        async def audio_callback(text):
            pass

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None
        )
        handler.set_session_file(str(transcript_file))

        observer = Observer()
        observer.schedule(handler, str(tmp_path))
        observer.start()

        try:
            time.sleep(0.5)

            # Write tool_use
            tool_use_msg = {
                "type": "assistant",
                "message": {
                    "role": "assistant",
                    "content": [{
                        "type": "tool_use",
                        "id": "tool_123",
                        "name": "AskUserQuestion",
                        "input": {"questions": [{"question": "Which option?"}]}
                    }]
                },
                "timestamp": "2026-01-01T00:00:00Z"
            }
            with open(transcript_file, "a") as f:
                f.write(json.dumps(tool_use_msg) + "\n")
                f.flush()

            time.sleep(0.5)

            # Write tool_result
            tool_result_msg = {
                "type": "user",
                "message": {
                    "role": "user",
                    "content": [{
                        "type": "tool_result",
                        "tool_use_id": "tool_123",
                        "content": "Option A selected"
                    }]
                },
                "timestamp": "2026-01-01T00:00:01Z"
            }
            with open(transcript_file, "a") as f:
                f.write(json.dumps(tool_result_msg) + "\n")
                f.flush()

            time.sleep(1.0)
            loop.run_until_complete(asyncio.sleep(0.1))

            # Reconcile to catch any missed
            missed, _ = handler.reconcile()
            received_blocks.extend(missed)

        finally:
            observer.stop()
            observer.join()
            loop.close()

        # Should have both tool_use and tool_result
        types = [b.type for b in received_blocks]
        assert "tool_use" in types, f"Missing tool_use, got: {types}"
        assert "tool_result" in types, f"Missing tool_result, got: {types}"
```

**Step 2: Run integration test**

Run: `cd voice_server/tests && ../../.venv/bin/pytest test_sync_integration.py -v`
Expected: PASS

**Step 3: Commit**

```bash
git add voice_server/tests/test_sync_integration.py
git commit -m "test: add integration tests for transcript sync reliability"
```

---

### Task 5: Verify manually with the app

**Step 1: Reinstall server**

Run: `pipx install --force /Users/aaron/Desktop/max`

**Step 2: Start the server and test**

Start `claude-connect`, open a session in the iOS app, and interact from the terminal. Verify:
- Messages typed in terminal appear in the app
- Tool use blocks show results (not stuck on "Running...")
- AskUserQuestion prompts show the question content and the answer

**CHECKPOINT:** If messages are still being dropped, debug the reconciliation loop (check server logs for `[RECONCILE]` messages). Don't proceed to Phase 2 until this works.

**Step 3: Commit any fixes found during manual testing**

If any issues are found, fix and commit before proceeding.

---

### Task 6: Run full test suite

**Step 1: Run all server tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All PASS

**Step 2: Build iOS app**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: BUILD SUCCEEDED (no iOS changes, just verifying nothing broke)

**Step 3: Commit if needed**

Only commit if fixes were needed from the test suite run.
