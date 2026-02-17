# TTS Queue + Context Limit Fix

## Problem 1: Context percentage is incorrect

The app's context indicator shows wrong remaining percentage vs Claude Code's terminal.

**Root cause:** `CONTEXT_LIMIT = 158000` is too low. Real session data shows 163,061 tokens at 98% used (per Claude Code terminal), implying a limit of ~166,000.

**Secondary issue:** Formula includes `output_tokens` — technically wrong since output tokens represent generation, not context consumed. Effect is negligible (1-2 tokens typically) but should be corrected.

**Fix:**
- Change `CONTEXT_LIMIT` from 158000 to 166000
- Remove `output_tokens` from the token sum

**Files:** `voice_server/context_tracker.py`, `voice_server/tests/test_context_tracker.py`

## Problem 2: TTS overloading

Multiple text blocks arrive rapidly from transcript watching. Each triggers `handle_claude_response` → `stream_audio`, causing overlapping TTS generation and concurrent audio streams to the client.

**Fix:** Server-side TTS queue with cancellation.

### Architecture

```
TranscriptWatcher.on_modified()
  → extract text → put on tts_queue (replace any pending)

TTS Worker (single coroutine, runs continuously)
  → drain queue, keep only latest message
  → if currently generating/streaming: set cancel event
  → wait for current work to abort
  → optional 500ms gap after interruption
  → generate TTS (in executor, so cancel is responsive)
  → stream chunks to clients (check cancel between chunks)
```

### Server changes (`ios_server.py`)

1. Add to `VoiceServer.__init__`:
   - `self.tts_queue: asyncio.Queue` — incoming TTS requests
   - `self.tts_cancel: asyncio.Event` — signals current TTS to stop
   - `self.tts_active: bool` — whether TTS is currently generating/streaming

2. Add `tts_worker` coroutine:
   - Runs as background task, started when server starts
   - Loops: `await tts_queue.get()`, then drain any additional items (keep latest only)
   - If `tts_active`, set `tts_cancel`, wait for it to clear
   - If interrupted previous playback, sleep 500ms
   - Run `generate_tts_audio` in executor (so event loop stays responsive)
   - Check `tts_cancel` after generation — if set, discard and loop
   - Stream chunks, checking `tts_cancel` between each chunk
   - Send `stop_audio` to clients when cancelling mid-stream

3. Modify `handle_claude_response`:
   - Instead of calling `stream_audio` directly, put text on `tts_queue`
   - Remove direct `send_status` calls (worker handles them)

4. Modify `stream_audio`:
   - Accept cancel event parameter
   - Check cancel between chunk sends
   - Return early if cancelled

### Client changes (`AudioPlayer.swift`)

5. Handle `stop_audio` message:
   - `WebSocketManager` receives `{"type": "stop_audio"}`
   - Calls `audioPlayer.stop()` to immediately halt playback

### New message type

```json
{"type": "stop_audio"}
```

Server sends this to all clients when cancelling current TTS playback.

### Test updates

6. Update `test_context_tracker.py` — adjust expected percentages for new limit
7. Add tests for TTS queue behavior (queue draining, cancellation)

### Manual verification

- Start server, open session, trigger rapid Claude responses
- Verify: no overlapping audio, smooth transition with short gap
- Verify: context percentage in app header matches terminal closely
