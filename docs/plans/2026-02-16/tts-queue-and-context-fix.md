# TTS Queue + Context Limit Fix Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix incorrect context percentage display and eliminate overlapping TTS audio playback.

**Architecture:** Two independent fixes. (1) Update context limit constant and formula in `context_tracker.py`. (2) Add a TTS worker coroutine to `VoiceServer` that serializes TTS generation/streaming, cancels in-progress audio when new text arrives, and sends `stop_audio` to clients. iOS client handles `stop_audio` by calling `audioPlayer.stop()`.

**Tech Stack:** Python asyncio, Swift/SwiftUI, WebSocket protocol

**Risky Assumptions:** The 166k context limit is empirically derived from one session — it may vary by model. We'll verify with the app after deploying.

---

### Task 1: Fix context limit and formula

**Files:**
- Modify: `voice_server/context_tracker.py:8,48-53`
- Modify: `voice_server/tests/test_context_tracker.py`

**Step 1: Update the tests to expect new values**

In `voice_server/tests/test_context_tracker.py`, update all tests:

```python
# test_calculate_context_from_empty_file: change line 19
assert result["context_limit"] == 166000

# test_calculate_context_from_transcript: change lines 48-50
# Now only input_tokens count (no output_tokens): 150 tokens
assert result["tokens_used"] == 150
assert result["context_percentage"] == 0.09  # 150/166000 * 100 = 0.09%

# test_calculate_context_includes_cache_tokens: change lines 79-81
# 10 + 5000 + 1000 = 6010 (no output_tokens)
assert result["tokens_used"] == 6010
assert result["context_percentage"] == 3.62  # 6010/166000 * 100

# test_calculate_context_ignores_entries_without_usage: change line 105
# 500 input only (no output_tokens)
assert result["tokens_used"] == 500
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: 4 failures (old values don't match new expectations)

**Step 3: Update context_tracker.py**

In `voice_server/context_tracker.py`:

Change line 8:
```python
CONTEXT_LIMIT = 166000
```

Change lines 48-53 (remove `output_tokens`):
```python
            total_tokens = (
                last_usage.get('input_tokens', 0) +
                last_usage.get('cache_creation_input_tokens', 0) +
                last_usage.get('cache_read_input_tokens', 0)
            )
```

Update the comment on line 7 to match:
```python
# Empirically determined: 163061 tokens at 98% usage (Claude Code terminal) ≈ 166k
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All pass

**Step 5: Commit**

```bash
git add voice_server/context_tracker.py voice_server/tests/test_context_tracker.py
git commit -m "fix: correct context limit to 166k and remove output_tokens from calculation"
```

---

### Task 2: Add TTS queue and worker to VoiceServer

**Files:**
- Modify: `voice_server/ios_server.py:318-336,447-478,535-548,985-1024`
- Create: `voice_server/tests/test_tts_queue.py`

**Step 1: Write tests for TTS queue behavior**

Create `voice_server/tests/test_tts_queue.py`:

```python
"""Tests for TTS queue behavior in VoiceServer."""
import pytest
import asyncio
import json
from unittest.mock import AsyncMock, MagicMock, patch

from voice_server.ios_server import VoiceServer


@pytest.fixture
def server():
    """Create a VoiceServer with mocked dependencies."""
    with patch('voice_server.ios_server.TmuxController'), \
         patch('voice_server.ios_server.set_tmux_controller'), \
         patch('voice_server.ios_server.set_voice_server'):
        s = VoiceServer()
        s.loop = asyncio.get_event_loop()
        return s


@pytest.mark.asyncio
async def test_tts_queue_drains_to_latest(server):
    """When multiple texts are queued, only the latest is spoken."""
    generated_texts = []

    async def fake_generate(text):
        generated_texts.append(text)
        return b"fake_wav_data"

    server._tts_generate = fake_generate
    server._tts_stream = AsyncMock()
    server.clients = set()

    # Start worker
    worker_task = asyncio.create_task(server._tts_worker())

    # Queue 3 messages rapidly
    await server.tts_queue.put("first message")
    await server.tts_queue.put("second message")
    await server.tts_queue.put("third message")

    # Give worker time to process
    await asyncio.sleep(0.1)

    # Cancel worker
    worker_task.cancel()
    try:
        await worker_task
    except asyncio.CancelledError:
        pass

    # Only the latest message should have been generated
    assert generated_texts == ["third message"]


@pytest.mark.asyncio
async def test_tts_cancel_stops_streaming(server):
    """Setting cancel event stops in-progress streaming."""
    chunks_sent = []

    async def slow_stream(websocket, wav_bytes, cancel_event):
        for i in range(10):
            if cancel_event.is_set():
                return False
            chunks_sent.append(i)
            await asyncio.sleep(0.01)
        return True

    server._tts_stream = slow_stream
    server.tts_cancel = asyncio.Event()

    mock_ws = AsyncMock()
    server.clients = {mock_ws}

    # Start streaming, then cancel after a short delay
    async def cancel_after_delay():
        await asyncio.sleep(0.03)
        server.tts_cancel.set()

    cancel_task = asyncio.create_task(cancel_after_delay())
    result = await slow_stream(mock_ws, b"data", server.tts_cancel)
    await cancel_task

    assert result is False
    assert len(chunks_sent) < 10


@pytest.mark.asyncio
async def test_handle_claude_response_queues_text(server):
    """handle_claude_response puts text on queue instead of calling stream_audio directly."""
    # Start with empty queue
    assert server.tts_queue.empty()

    await server.handle_claude_response("hello world")

    assert not server.tts_queue.empty()
    text = server.tts_queue.get_nowait()
    assert text == "hello world"
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_tts_queue.py -v`
Expected: Failures (tts_queue attribute doesn't exist yet)

**Step 3: Implement TTS queue in VoiceServer**

In `voice_server/ios_server.py`, add to `VoiceServer.__init__` (after line 335):

```python
        # TTS queue: serializes audio generation/streaming
        self.tts_queue = asyncio.Queue()
        self.tts_cancel = asyncio.Event()
        self.tts_active = False
        self._tts_worker_task = None
```

Replace `stream_audio` method (lines 447-477) with cancellable version:

```python
    async def stream_audio(self, websocket, wav_bytes, cancel_event):
        """Stream pre-generated WAV audio to client. Returns False if cancelled."""
        try:
            chunk_size = 8192
            total_chunks = (len(wav_bytes) + chunk_size - 1) // chunk_size
            print(f"Streaming {total_chunks} audio chunks...")

            for i in range(0, len(wav_bytes), chunk_size):
                if cancel_event.is_set():
                    print(f"[TTS] Streaming cancelled at chunk {i // chunk_size}/{total_chunks}")
                    return False

                chunk = wav_bytes[i:i+chunk_size]
                await websocket.send(json.dumps({
                    "type": "audio_chunk",
                    "format": "wav",
                    "sample_rate": 24000,
                    "chunk_index": i // chunk_size,
                    "total_chunks": total_chunks,
                    "data": base64.b64encode(chunk).decode('utf-8')
                }))
                await asyncio.sleep(0.01)

            print(f"Finished streaming {total_chunks} chunks")
            return True

        except Exception as e:
            print(f"Error streaming audio: {e}")
            import traceback
            traceback.print_exc()
            return False
```

Add the TTS worker coroutine:

```python
    async def _tts_worker(self):
        """Background worker that processes TTS requests one at a time.

        Drains the queue to keep only the latest message.
        Cancels in-progress TTS when new messages arrive.
        """
        while True:
            try:
                # Wait for a TTS request
                text = await self.tts_queue.get()

                # Drain queue — keep only the latest
                while not self.tts_queue.empty():
                    try:
                        text = self.tts_queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break

                # If there's active TTS, cancel it and wait
                was_interrupted = False
                if self.tts_active:
                    print(f"[TTS] Cancelling current TTS for new message")
                    self.tts_cancel.set()
                    # Send stop_audio to clients
                    await self._send_stop_audio()
                    # Wait for current TTS to finish cancelling
                    while self.tts_active:
                        await asyncio.sleep(0.05)
                    was_interrupted = True

                # Reset cancel event
                self.tts_cancel.clear()
                self.tts_active = True

                # Short gap after interruption
                if was_interrupted:
                    await asyncio.sleep(0.5)
                    # Check if newer message arrived during the gap
                    if not self.tts_queue.empty():
                        self.tts_active = False
                        continue

                try:
                    # Generate TTS in executor (blocking call)
                    print(f"[TTS] Generating audio for: '{text[:50]}...'")
                    loop = asyncio.get_running_loop()
                    samples = await loop.run_in_executor(
                        None, lambda: generate_tts_audio(text, voice="af_heart")
                    )

                    # Check for cancellation after generation
                    if self.tts_cancel.is_set():
                        print(f"[TTS] Cancelled after generation")
                        continue

                    wav_bytes = samples_to_wav_bytes(samples)

                    # Stream to all clients
                    for websocket in list(self.clients):
                        await self.send_status(websocket, "speaking", "Playing response")
                        completed = await self.stream_audio(websocket, wav_bytes, self.tts_cancel)
                        if completed:
                            await self.send_status(websocket, "idle", "Ready")

                finally:
                    self.tts_active = False

            except asyncio.CancelledError:
                self.tts_active = False
                raise
            except Exception as e:
                self.tts_active = False
                print(f"[TTS] Worker error: {e}")
                import traceback
                traceback.print_exc()

    async def _send_stop_audio(self):
        """Send stop_audio message to all connected clients."""
        message = json.dumps({"type": "stop_audio"})
        for websocket in list(self.clients):
            try:
                await websocket.send(message)
            except Exception:
                pass
```

Replace `handle_claude_response` (lines 535-548):

```python
    async def handle_claude_response(self, text):
        """Handle Claude's response - queue text for TTS"""
        print(f"[{time.strftime('%H:%M:%S')}] Claude response queued for TTS: '{text[:100]}...'")
        await self.tts_queue.put(text)
```

In the `start` method, start the TTS worker. Add after line 1010 (`self.observer.start()`):

```python
        # Start TTS worker
        self._tts_worker_task = asyncio.create_task(self._tts_worker())
```

Also start it even when no transcript path exists — add after the `if self.transcript_path:` block (around line 1011):

```python
        # Start TTS worker (always, even without transcript)
        self._tts_worker_task = asyncio.create_task(self._tts_worker())
```

Wait — move the TTS worker start outside the `if self.transcript_path:` block. Place it right before the HTTP server start (line 1013):

```python
        # Start TTS worker
        self._tts_worker_task = asyncio.create_task(self._tts_worker())

        # Start HTTP server for permission hooks
        http_runner = await start_http_server(self.permission_handler)
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_tts_queue.py -v`
Expected: All 3 tests pass

**Step 5: Run full server test suite**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All pass (existing tests should not break)

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_tts_queue.py
git commit -m "feat: add TTS queue with cancellation to prevent audio overlap"
```

---

### Task 3: Handle stop_audio on iOS client

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift:371-530`

**Step 1: Add stop_audio message type**

In `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift`, add after `AudioChunkMessage`:

```swift
struct StopAudioMessage: Codable {
    let type: String
}
```

**Step 2: Handle stop_audio in WebSocketManager**

In `WebSocketManager.swift`, in the `handleMessage` method's string case, add a new decode branch. Add it right before the `AudioChunkMessage` decode (before line 389):

```swift
            } else if let stopAudio = try? JSONDecoder().decode(StopAudioMessage.self, from: data),
                      stopAudio.type == "stop_audio" {
                logToFile("🛑 Decoded as StopAudio")
                DispatchQueue.main.async {
                    self.onStopAudio?()
                }
```

Add the callback property alongside the other callbacks (around line 34):

```swift
    var onStopAudio: (() -> Void)?
```

**Step 3: Wire up stop_audio in SessionView**

Find where `onAudioChunk` is wired up in `SessionView.swift` and add `onStopAudio` nearby. It should call `audioPlayer.stop()`:

```swift
webSocketManager.onStopAudio = {
    audioPlayer.stop()
}
```

**Step 4: Build to verify compilation**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: handle stop_audio message on iOS to halt playback on cancel"
```

---

### Task 4: Manual verification

**Automated tests:** None (requires live server + iOS app)

**Step 1: Reinstall server**

```bash
pipx install --force /Users/aaron/Desktop/max
```

**Step 2: Build and install iOS app on device**

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild -target ClaudeVoice -sdk iphoneos build
xcrun devicectl list devices
xcrun devicectl device install app --device "<DEVICE_ID>" \
  ios-voice-app/ClaudeVoice/build/Release-iphoneos/ClaudeVoice.app
```

**Step 3: Verify context percentage**

1. Start server with `claude-connect`
2. Open a session on iOS app
3. Have a conversation until context builds up
4. Compare the percentage shown in the session header with Claude Code's terminal context bar
5. They should be within ~2% of each other

**Step 4: Verify TTS queue behavior**

1. Ask Claude a question that produces multiple text blocks (e.g., a complex code question)
2. Verify: audio plays sequentially, no overlap
3. Verify: if a new response comes during playback, current audio stops, short gap, new audio plays
4. Verify: no "speaking" state gets stuck

**CHECKPOINT:** Both fixes must work before merging.
