# Streaming Content Blocks Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Refactor from batching all content blocks to streaming them incrementally as they're written to the transcript file.

**Architecture:** Replace the current "wait-and-aggregate" approach with stateful tracking of what's been sent. As the file watcher detects modifications, extract only NEW blocks that haven't been sent yet and stream them immediately. This eliminates the debounce problem where blocks written within the 0.5s window get missed.

**Tech Stack:** Python 3.9, Pydantic models, WebSocket server, file watching (watchdog)

---

## Task 1: Add Block Tracking State to TranscriptHandler

**Files:**
- Modify: `voice_server/ios_server.py:40-50` (TranscriptHandler.__init__)

**Step 1: Write failing test for incremental extraction**

```python
# Add to voice_server/tests/test_response_extraction.py

def test_extract_incremental_blocks():
    """Test extracting only new blocks since last extraction"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # User message
        f.write(json.dumps({
            "message": {"role": "user", "content": "test input"}
        }) + "\n")

        # First assistant message - thinking block
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "id": "msg_123",
                "content": [
                    {"type": "thinking", "thinking": "Let me think", "signature": "sig1"}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test input'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        # First extraction - should get thinking block
        new_blocks = handler.extract_new_blocks(temp_path, "test input")
        assert len(new_blocks) == 1
        assert isinstance(new_blocks[0], ThinkingBlock)

        # No file changes - should get nothing
        new_blocks = handler.extract_new_blocks(temp_path, "test input")
        assert len(new_blocks) == 0

        # Add text block to file
        with open(temp_path, 'a') as f:
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "id": "msg_123",
                    "content": [
                        {"type": "text", "text": "Here's my answer"}
                    ]
                }
            }) + "\n")

        # Second extraction - should only get new text block
        new_blocks = handler.extract_new_blocks(temp_path, "test input")
        assert len(new_blocks) == 1
        assert isinstance(new_blocks[0], TextBlock)
        assert new_blocks[0].text == "Here's my answer"

    finally:
        os.unlink(temp_path)
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_response_extraction.py::test_extract_incremental_blocks -v`

Expected: FAIL with "AttributeError: 'TranscriptHandler' object has no attribute 'extract_new_blocks'"

**Step 3: Add tracking state to TranscriptHandler**

In `voice_server/ios_server.py`, modify `TranscriptHandler.__init__`:

```python
def __init__(self, content_callback, audio_callback, loop, server):
    self.content_callback = content_callback  # New: sends AssistantResponse
    self.audio_callback = audio_callback       # Existing: sends text for TTS
    self.loop = loop
    self.server = server
    self.last_message = None
    self.last_modified = 0
    # NEW: Track what we've already sent
    self.sent_blocks_by_message = {}  # {message_id: num_blocks_sent}
    self.current_message_id = None
```

**Step 4: Implement extract_new_blocks method**

Add this method to `TranscriptHandler` class in `voice_server/ios_server.py`:

```python
def extract_new_blocks(self, filepath, user_message) -> list[ContentBlock]:
    """Extract only NEW blocks that haven't been sent yet

    Returns:
        List of new ContentBlock objects that haven't been sent
    """
    found_user_message = False
    collecting_response = False
    all_parsed_blocks = []
    current_msg_id = None

    print(f"[DEBUG] Looking for user message: '{user_message[:50]}...'")

    with open(filepath, 'r') as f:
        for line in f:
            try:
                entry = json.loads(line.strip())
                msg = entry.get('message', {})
                role = msg.get('role') or entry.get('role')

                # Check if this is a user message matching our voice input
                if role == 'user' and not found_user_message:
                    content = msg.get('content', entry.get('content', ''))
                    if isinstance(content, str):
                        user_text = content
                    elif isinstance(content, list):
                        text_parts = [
                            block.get('text', '')
                            for block in content
                            if isinstance(block, dict) and block.get('type') == 'text'
                        ]
                        user_text = ' '.join(text_parts)
                    else:
                        continue

                    # Check if this user message matches our voice input
                    if user_text.strip() == user_message.strip():
                        print(f"[DEBUG] Found matching user message!")
                        found_user_message = True
                        collecting_response = True
                        continue

                # Collect ALL consecutive assistant messages
                if collecting_response:
                    if role == 'assistant':
                        msg_id = msg.get('id', 'no-id')
                        current_msg_id = msg_id
                        content = msg.get('content', entry.get('content', ''))

                        if isinstance(content, str):
                            # String content - create single text block
                            result = content.strip()
                            if result:
                                all_parsed_blocks.append(TextBlock(type="text", text=result))
                        elif isinstance(content, list):
                            # Parse structured content blocks
                            for block in content:
                                if isinstance(block, dict):
                                    block_type = block.get('type')
                                    try:
                                        if block_type == 'text':
                                            all_parsed_blocks.append(TextBlock(**block))
                                        elif block_type == 'thinking':
                                            all_parsed_blocks.append(ThinkingBlock(**block))
                                        elif block_type == 'tool_use':
                                            all_parsed_blocks.append(ToolUseBlock(**block))
                                    except Exception as e:
                                        print(f"[DEBUG] Error parsing block: {e}")
                                        continue
                    elif role == 'user':
                        # Hit another user message, stop collecting
                        print(f"[DEBUG] Hit next user message, stopping collection")
                        break
            except:
                continue

    # Update tracking state
    if current_msg_id:
        self.current_message_id = current_msg_id

    # Calculate how many blocks we've already sent for this message
    already_sent = self.sent_blocks_by_message.get(self.current_message_id, 0)

    # Return only the NEW blocks
    new_blocks = all_parsed_blocks[already_sent:]

    if new_blocks:
        print(f"[DEBUG] Found {len(new_blocks)} new blocks (already sent {already_sent})")
        # Update the count
        self.sent_blocks_by_message[self.current_message_id] = already_sent + len(new_blocks)
    else:
        print(f"[DEBUG] No new blocks (total: {len(all_parsed_blocks)}, sent: {already_sent})")

    return new_blocks
```

**Step 5: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_response_extraction.py::test_extract_incremental_blocks -v`

Expected: PASS

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_response_extraction.py
git commit -m "feat: add incremental block extraction with state tracking"
```

---

## Task 2: Update on_modified to Use Streaming Extraction

**Files:**
- Modify: `voice_server/ios_server.py:51-98` (TranscriptHandler.on_modified)

**Step 1: Write test for streaming behavior**

Add to `voice_server/tests/test_response_extraction.py`:

```python
def test_streaming_sends_blocks_incrementally():
    """Test that handler sends blocks as they arrive, not batched"""
    import asyncio

    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "message": {"role": "user", "content": "test"}
        }) + "\n")
        temp_path = f.name

    try:
        # Track what was sent
        sent_responses = []

        async def mock_content_callback(response):
            sent_responses.append(response)

        mock_server = type('obj', (), {
            'last_voice_input': 'test',
            'waiting_for_response': True
        })()

        loop = asyncio.new_event_loop()
        handler = TranscriptHandler(mock_content_callback, None, loop, mock_server)

        # Simulate first file modification - thinking block added
        with open(temp_path, 'a') as f:
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "id": "msg_1",
                    "content": [{"type": "thinking", "thinking": "Thinking...", "signature": "s1"}]
                }
            }) + "\n")

        # Manually call on_modified (simulating file watcher)
        from watchdog.events import FileModifiedEvent
        event = FileModifiedEvent(temp_path)
        handler.last_modified = 0  # Reset debounce
        handler.on_modified(event)

        # Give async callbacks time to run
        loop.run_until_complete(asyncio.sleep(0.1))

        # Should have sent first response with thinking block
        assert len(sent_responses) == 1
        assert len(sent_responses[0].content_blocks) == 1
        assert isinstance(sent_responses[0].content_blocks[0], ThinkingBlock)

        # Simulate second file modification - text block added
        with open(temp_path, 'a') as f:
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "id": "msg_1",
                    "content": [{"type": "text", "text": "Answer"}]
                }
            }) + "\n")

        handler.last_modified = 0  # Reset debounce
        handler.on_modified(event)
        loop.run_until_complete(asyncio.sleep(0.1))

        # Should have sent second response with ONLY the text block
        assert len(sent_responses) == 2
        assert len(sent_responses[1].content_blocks) == 1
        assert isinstance(sent_responses[1].content_blocks[0], TextBlock)

        loop.close()
    finally:
        os.unlink(temp_path)
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_response_extraction.py::test_streaming_sends_blocks_incrementally -v`

Expected: FAIL (current implementation batches all blocks)

**Step 3: Refactor on_modified to use streaming**

In `voice_server/ios_server.py`, replace the `on_modified` method:

```python
def on_modified(self, event):
    if event.is_directory or not event.src_path.endswith('.jsonl'):
        return

    current_time = time.time()
    if current_time - self.last_modified < 0.05:  # Reduced from 0.5s to 50ms
        return
    self.last_modified = current_time

    try:
        # Extract only NEW blocks since last check
        if self.server.last_voice_input:
            print(f"[DEBUG] File modified, extracting new blocks...")
            new_blocks = self.extract_new_blocks(
                event.src_path,
                self.server.last_voice_input
            )
            print(f"[DEBUG] Extracted {len(new_blocks)} new blocks")

            if new_blocks:
                # Create response with ONLY the new blocks
                response = AssistantResponse(
                    content_blocks=new_blocks,
                    timestamp=time.time()
                )

                # 1. Send structured content immediately
                asyncio.run_coroutine_threadsafe(
                    self.content_callback(response),
                    self.loop
                )

                # 2. Extract text for TTS
                text = extract_text_for_tts(new_blocks)
                print(f"[DEBUG] Extracted text for TTS: '{text}'")

                # 3. Send for audio generation
                if text:
                    print(f"[DEBUG] Calling audio_callback with text")
                    asyncio.run_coroutine_threadsafe(
                        self.audio_callback(text),
                        self.loop
                    )
                else:
                    print(f"[DEBUG] No text in this batch - non-text blocks only")
    except Exception as e:
        print(f"Error processing transcript: {e}")
        import traceback
        traceback.print_exc()
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_response_extraction.py::test_streaming_sends_blocks_incrementally -v`

Expected: PASS

**Step 5: Run all extraction tests**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_response_extraction.py -v`

Expected: All tests PASS

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_response_extraction.py
git commit -m "refactor: stream content blocks incrementally instead of batching"
```

---

## Task 3: Add Reset Mechanism for New Voice Inputs

**Files:**
- Modify: `voice_server/ios_server.py:273-286` (handle_voice_input method)

**Step 1: Write test for state reset**

Add to `voice_server/tests/test_response_extraction.py`:

```python
def test_state_resets_on_new_voice_input():
    """Test that tracking state resets when processing a new voice input"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # First conversation
        f.write(json.dumps({
            "message": {"role": "user", "content": "first question"}
        }) + "\n")
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "id": "msg_1",
                "content": [{"type": "text", "text": "first answer"}]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'first question'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        # Extract blocks from first conversation
        blocks = handler.extract_new_blocks(temp_path, "first question")
        assert len(blocks) == 1
        assert handler.sent_blocks_by_message.get("msg_1") == 1

        # Reset for new conversation
        handler.reset_tracking_state()

        # State should be cleared
        assert handler.sent_blocks_by_message == {}
        assert handler.current_message_id is None

        # Add second conversation
        with open(temp_path, 'a') as f:
            f.write(json.dumps({
                "message": {"role": "user", "content": "second question"}
            }) + "\n")
            f.write(json.dumps({
                "message": {
                    "role": "assistant",
                    "id": "msg_2",
                    "content": [{"type": "text", "text": "second answer"}]
                }
            }) + "\n")

        # Should extract blocks from new conversation
        blocks = handler.extract_new_blocks(temp_path, "second question")
        assert len(blocks) == 1
        assert blocks[0].text == "second answer"

    finally:
        os.unlink(temp_path)
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_response_extraction.py::test_state_resets_on_new_voice_input -v`

Expected: FAIL with "AttributeError: 'TranscriptHandler' object has no attribute 'reset_tracking_state'"

**Step 3: Add reset method to TranscriptHandler**

In `voice_server/ios_server.py`, add this method to the `TranscriptHandler` class:

```python
def reset_tracking_state(self):
    """Reset tracking state for a new voice input conversation"""
    print("[DEBUG] Resetting block tracking state for new conversation")
    self.sent_blocks_by_message = {}
    self.current_message_id = None
    self.last_message = None
```

**Step 4: Call reset in handle_voice_input**

In `voice_server/ios_server.py`, modify the `handle_voice_input` method in the `VoiceServer` class:

```python
async def handle_voice_input(self, websocket, data):
    """Handle voice input from iOS"""
    text = data.get('text', '').strip()
    print(f"[{time.strftime('%H:%M:%S')}] Voice input received: '{text}'")
    if text:
        print(f"[{time.strftime('%H:%M:%S')}] Sending to VS Code...")
        await self.send_status(websocket, "processing", "Sending to Claude...")

        # Reset tracking state for new conversation
        if self.observer and self.observer.event_handlers:
            for handler in self.observer.event_handlers:
                if isinstance(handler, TranscriptHandler):
                    handler.reset_tracking_state()

        self.waiting_for_response = True
        print(f"[DEBUG] Set waiting_for_response = True")
        self.last_voice_input = text
        await self.send_to_vs_code(text)
        print(f"[{time.strftime('%H:%M:%S')}] Sent to VS Code successfully")
    else:
        print("Empty text received, ignoring")
```

**Step 5: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_response_extraction.py::test_state_resets_on_new_voice_input -v`

Expected: PASS

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_response_extraction.py
git commit -m "feat: reset block tracking state on new voice input"
```

---

## Task 4: Clean Up Old Batching Code

**Files:**
- Modify: `voice_server/ios_server.py` (remove extract_assistant_response_to_user_message)

**Step 1: Verify old method is no longer used**

Run: `cd /Users/aaron/Desktop/max && grep -n "extract_assistant_response_to_user_message" voice_server/ios_server.py`

Expected: Should only appear in the method definition (no callers)

**Step 2: Remove the old batching method**

In `voice_server/ios_server.py`, delete the entire `extract_assistant_response_to_user_message` method (lines 100-192).

**Step 3: Run all tests to ensure nothing breaks**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_response_extraction.py -v`

Expected: All tests PASS (old tests should still work)

**Step 4: Remove obsolete tests**

Remove these test functions from `voice_server/tests/test_response_extraction.py`:
- `test_extract_string_content` (line 11-36)
- `test_extract_text_block_content` (line 39-66)
- `test_extract_mixed_content_blocks` (line 69-98)
- `test_extract_ignores_unknown_block_type` (line 101-129)
- `test_extract_thinking_only_should_wait` (line 132-171)
- `test_extract_multi_part_response_same_message_id` (line 174-220)

These tested the old batching behavior. The new tests cover streaming behavior.

**Step 5: Run tests again**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_response_extraction.py -v`

Expected: All new tests PASS

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_response_extraction.py
git commit -m "refactor: remove old batching code and tests"
```

---

## Task 5: Update AssistantResponse Model for Incremental Updates

**Files:**
- Modify: `voice_server/content_models.py:26-30`
- Modify: `voice_server/ios_server.py` (update handle_content_response)

**Step 1: Write test for incremental flag**

Add to `voice_server/tests/test_content_models.py` (create this file):

```python
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from content_models import AssistantResponse, TextBlock


def test_assistant_response_incremental_flag():
    """Test that AssistantResponse can indicate incremental vs complete"""
    # Incremental response (default for streaming)
    incremental = AssistantResponse(
        content_blocks=[TextBlock(type="text", text="Hello")],
        timestamp=123.456,
        is_incremental=True
    )
    assert incremental.is_incremental is True

    # Complete response (when conversation ends)
    complete = AssistantResponse(
        content_blocks=[TextBlock(type="text", text="Goodbye")],
        timestamp=789.012,
        is_incremental=False
    )
    assert complete.is_incremental is False


def test_assistant_response_serialization_includes_flag():
    """Test that model_dump includes is_incremental"""
    response = AssistantResponse(
        content_blocks=[TextBlock(type="text", text="Hi")],
        timestamp=123.0,
        is_incremental=True
    )

    data = response.model_dump()
    assert "is_incremental" in data
    assert data["is_incremental"] is True
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_content_models.py::test_assistant_response_incremental_flag -v`

Expected: FAIL with ValidationError (field doesn't exist)

**Step 3: Add is_incremental field to AssistantResponse**

In `voice_server/content_models.py`:

```python
class AssistantResponse(BaseModel):
    type: Literal["assistant_response"] = "assistant_response"
    content_blocks: list[ContentBlock]
    timestamp: float
    is_incremental: bool = True  # True = more blocks may come, False = response complete
```

**Step 4: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/pytest voice_server/tests/test_content_models.py -v`

Expected: All tests PASS

**Step 5: Update streaming code to use incremental flag**

In `voice_server/ios_server.py`, modify the `on_modified` method where we create the response:

```python
if new_blocks:
    # Create response with ONLY the new blocks
    response = AssistantResponse(
        content_blocks=new_blocks,
        timestamp=time.time(),
        is_incremental=True  # Signal that more blocks may arrive
    )
```

**Step 6: Fix waiting_for_response bug for multi-block streaming**

**BUG**: Currently `handle_claude_response` sets `waiting_for_response = False` on first text block, causing subsequent text blocks to be ignored (no TTS generated).

In `voice_server/ios_server.py`, modify `handle_claude_response`:

```python
async def handle_claude_response(self, text):
    """Handle Claude's response - generate and stream TTS audio"""
    print(f"[{time.strftime('%H:%M:%S')}] Claude response received: '{text[:100]}...'")

    # NOTE: With streaming, this is called multiple times (once per text block)
    # Don't check/reset waiting_for_response here - let reset happen on new voice input

    for websocket in list(self.clients):
        print(f"[{time.strftime('%H:%M:%S')}] Sending 'speaking' status to client")
        await self.send_status(websocket, "speaking", "Playing response")
        print(f"[{time.strftime('%H:%M:%S')}] Streaming audio to client...")
        await self.stream_audio(websocket, text)
        print(f"[{time.strftime('%H:%M:%S')}] Audio streaming complete, sending 'idle' status")
        await self.send_status(websocket, "idle", "Ready")
```

The key change: Remove the `if not self.waiting_for_response` check and the `self.waiting_for_response = False` line. The flag is now only managed in `handle_voice_input` (reset on new input).

**Step 7: Commit**

```bash
git add voice_server/content_models.py voice_server/tests/test_content_models.py voice_server/ios_server.py
git commit -m "feat: add is_incremental flag to AssistantResponse for streaming"
```

---

## Task 6: Manual Testing and Verification

**Files:**
- Test: Manual end-to-end testing with iOS client

**Step 1: Start the iOS server**

Run: `cd /Users/aaron/Desktop/max && .venv/bin/python voice_server/ios_server.py`

Expected: Server starts and shows "Server running on ws://..."

**Step 2: Send a voice input from iOS app**

Action: Use iOS app to send a voice message like "What is Python?"

Expected output in server logs:
```
[DEBUG] File modified, extracting new blocks...
[DEBUG] Found 1 new blocks (already sent 0)
[DEBUG] Extracted text for TTS: ''
[DEBUG] No text in this batch - non-text blocks only
[DEBUG] File modified, extracting new blocks...
[DEBUG] Found 1 new blocks (already sent 1)
[DEBUG] Extracted text for TTS: 'Python is a programming language...'
[DEBUG] Calling audio_callback with text
```

**Step 3: Verify blocks arrive incrementally on iOS**

Check iOS app logs/UI:
- First message should arrive with thinking block
- Second message should arrive with text block
- Both should have `is_incremental: true`

**Step 4: Test multiple rapid voice inputs**

Action: Send 2-3 voice inputs in quick succession

Expected: Each conversation should start fresh (state resets), no cross-contamination

**Step 5: Document any issues found**

If issues found: Create GitHub issues or fix immediately

**Step 6: Manual test complete - no commit needed**

---

## Testing Strategy

**Unit Tests:**
- `test_extract_incremental_blocks` - Core incremental extraction logic
- `test_streaming_sends_blocks_incrementally` - Streaming behavior
- `test_state_resets_on_new_voice_input` - State management
- `test_assistant_response_incremental_flag` - Model serialization

**Integration Testing:**
- Manual testing with real iOS app and Claude Code
- Verify blocks arrive in correct order
- Verify debounce doesn't miss blocks anymore
- Verify state resets between conversations

**Regression Testing:**
- All existing tests should still pass
- Old behavior (aggregating all blocks) was tested, now we test streaming

---

## Success Criteria

- ✅ Blocks are sent incrementally as they're written (no waiting for completion)
- ✅ Debounce reduced from 0.5s to 0.05s (10x faster)
- ✅ No blocks are missed due to debounce timing
- ✅ State properly resets between voice inputs
- ✅ iOS client receives `is_incremental` flag to handle streaming
- ✅ All unit tests pass
- ✅ Manual testing confirms improved responsiveness

---

## Notes

**Why This Fixes the Debounce Problem:**

Before:
1. Thinking block written → file watcher triggers
2. Extracts ALL blocks → only finds thinking → returns None
3. Text block written 0.2s later → file watcher skips (debounce)
4. ❌ Text block never extracted

After:
1. Thinking block written → file watcher triggers
2. Extracts NEW blocks → finds thinking → sends immediately ✅
3. Text block written 0.05s later → file watcher triggers (shorter debounce)
4. Extracts NEW blocks → finds text → sends immediately ✅

**Performance Considerations:**
- Reduced debounce means more file reads, but extraction is fast (<10ms)
- Tracking state adds minimal memory (~100 bytes per conversation)
- iOS client must handle incremental updates (accumulate blocks)

**Future Improvements:**
- Could eliminate debounce entirely and use a processing queue
- Could use file tailing instead of full file reads each time
- Could add block deduplication based on content hash
