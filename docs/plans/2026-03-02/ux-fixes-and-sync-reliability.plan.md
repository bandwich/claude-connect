# UX Fixes & Sync Reliability — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix four UX issues: unreliable message delivery detection, confusing Settings connection state, disconnected mic/keyboard inputs, and unsorted project list.

**Architecture:** Server-side delivery verification polls the transcript file after sending input to tmux. iOS Settings separates connecting state from the connect action. Voice input becomes dictation that appends to the text field. Project ordering sorts by most recent session mtime.

**Tech Stack:** Python (server, watchdog, asyncio), Swift/SwiftUI (iOS), Network framework (TCP pre-check)

**Risky Assumptions:** Delivery verification assumes user messages appear in the transcript within 5 seconds. If Claude Code is slow to write (large context, API latency), we may get false "Failed to send" alerts. Task 1 (sync chain test) verifies the pipeline first.

**Design doc:** `docs/plans/2026-03-02/ux-fixes-and-sync-reliability.md`

---

### Task 1: Sync chain integration test (Problem 1B)

Verify the full pipeline: file write → watchdog → extraction → user callback. This tests whether user messages in the transcript trigger `user_callback`. If this test fails, we've found the sync bug. If it passes, the delivery verification feature has a solid foundation.

**Files:**
- Modify: `voice_server/tests/test_sync_integration.py`

**Step 1: Write verification tests for user message sync**

These test existing functionality. If any FAIL, we've found the sync bug. If all PASS, the pipeline works and we can build delivery verification on top.

Add a new test class to `test_sync_integration.py`:

```python
class TestUserMessageSync:
    """Tests that user messages in the transcript trigger user_callback"""

    def test_user_message_triggers_callback(self, tmp_path):
        """User message appended to transcript fires user_callback with correct text"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        received_user = []

        async def content_callback(response, start_line=0):
            pass

        async def audio_callback(text):
            pass

        async def user_callback(text, seq=0):
            received_user.append((text, seq))

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None,
            user_callback=user_callback
        )
        handler.set_session_file(str(transcript_file))

        observer = Observer()
        observer.schedule(handler, str(tmp_path))
        observer.start()

        try:
            time.sleep(0.5)

            # Write an assistant message first, then a user message
            with open(transcript_file, "a") as f:
                assistant_msg = {
                    "type": "assistant",
                    "message": {
                        "role": "assistant",
                        "content": [{"type": "text", "text": "Hello, how can I help?"}]
                    },
                    "timestamp": "2026-01-01T00:00:00Z"
                }
                f.write(json.dumps(assistant_msg) + "\n")
                f.flush()

                time.sleep(0.3)

                user_msg = {
                    "type": "user",
                    "message": {
                        "role": "user",
                        "content": [{"type": "text", "text": "Looks good to me"}]
                    },
                    "timestamp": "2026-01-01T00:00:01Z"
                }
                f.write(json.dumps(user_msg) + "\n")
                f.flush()

            time.sleep(2.0)
            loop.run_until_complete(asyncio.sleep(0.1))

            # Reconcile to catch anything watchdog missed
            missed_blocks, missed_users, _ = handler.reconcile()
            for text in missed_users:
                received_user.append((text, 0))

        finally:
            observer.stop()
            observer.join()
            loop.close()

        assert len(received_user) >= 1, f"Expected user callback, got {received_user}"
        assert any("Looks good to me" in text for text, _ in received_user), \
            f"Expected 'Looks good to me' in {received_user}"

    def test_user_message_after_permission_resolved(self, tmp_path):
        """User messages still sync after a permission_resolved event"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        received_user = []
        received_content = []

        async def content_callback(response, start_line=0):
            for block in response.content_blocks:
                if hasattr(block, 'text'):
                    received_content.append(block.text)

        async def audio_callback(text):
            pass

        async def user_callback(text, seq=0):
            received_user.append(text)

        loop = asyncio.new_event_loop()

        handler = TranscriptHandler(
            content_callback=content_callback,
            audio_callback=audio_callback,
            loop=loop,
            server=None,
            user_callback=user_callback
        )
        handler.set_session_file(str(transcript_file))

        observer = Observer()
        observer.schedule(handler, str(tmp_path))
        observer.start()

        try:
            time.sleep(0.5)

            # Phase 1: Normal assistant message
            with open(transcript_file, "a") as f:
                f.write(json.dumps({
                    "message": {"role": "assistant", "content": [{"type": "text", "text": "Before permission"}]},
                    "timestamp": "2026-01-01T00:00:00Z"
                }) + "\n")
                f.flush()

            time.sleep(1.0)
            loop.run_until_complete(asyncio.sleep(0.1))

            # Phase 2: Write more messages after a gap (simulates permission_resolved)
            with open(transcript_file, "a") as f:
                f.write(json.dumps({
                    "message": {"role": "assistant", "content": [{"type": "text", "text": "After permission"}]},
                    "timestamp": "2026-01-01T00:00:02Z"
                }) + "\n")
                f.flush()

                time.sleep(0.3)

                f.write(json.dumps({
                    "message": {"role": "user", "content": [{"type": "text", "text": "User after permission"}]},
                    "timestamp": "2026-01-01T00:00:03Z"
                }) + "\n")
                f.flush()

            time.sleep(2.0)
            loop.run_until_complete(asyncio.sleep(0.1))

            # Reconcile
            missed_blocks, missed_users, _ = handler.reconcile()
            for block in missed_blocks:
                if hasattr(block, 'text'):
                    received_content.append(block.text)
            received_user.extend(missed_users)

        finally:
            observer.stop()
            observer.join()
            loop.close()

        assert "Before permission" in received_content, f"Missing pre-permission content: {received_content}"
        assert "After permission" in received_content, f"Missing post-permission content: {received_content}"
        assert any("User after permission" in t for t in received_user), \
            f"Missing user message after permission: {received_user}"

    def test_reconciliation_catches_missed_user_message(self, tmp_path):
        """Reconciliation finds user messages that watchdog missed"""
        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        async def content_callback(response, start_line=0):
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

        # DON'T start a watchdog — write lines that will only be found by reconciliation
        with open(transcript_file, "a") as f:
            f.write(json.dumps({
                "message": {"role": "assistant", "content": [{"type": "text", "text": "Hello"}]},
                "timestamp": "2026-01-01T00:00:00Z"
            }) + "\n")
            f.write(json.dumps({
                "message": {"role": "user", "content": [{"type": "text", "text": "Missed user msg"}]},
                "timestamp": "2026-01-01T00:00:01Z"
            }) + "\n")

        missed_blocks, missed_users, start_line = handler.reconcile()

        loop.close()

        assert start_line == 0
        assert len(missed_blocks) >= 1, "Should have found assistant block"
        assert "Missed user msg" in missed_users, f"Should have found user message, got: {missed_users}"
```

**Step 2: Run tests**

Run: `cd voice_server/tests && python -m pytest test_sync_integration.py::TestUserMessageSync -v`
Expected: All 3 tests PASS. If any FAIL, stop — we've found the sync bug. Debug and fix before proceeding.

**Step 3: Commit**

```bash
git add voice_server/tests/test_sync_integration.py
git commit -m "test: add sync chain integration tests for user message callbacks"
```

---

### Task 2: Diagnostic logging for sync chain (Problem 1C)

Add structured logging at each step so the next sync failure gives us evidence.

**Files:**
- Modify: `voice_server/ios_server.py:126-196` (TranscriptHandler.on_modified)
- Modify: `voice_server/ios_server.py:493-521` (_reconciliation_loop)

**Step 1: Add logging to `on_modified`**

In `ios_server.py`, add logging inside `on_modified` at the start of the `with self._lock:` block (after the session file check at line 141), and after extraction:

```python
# Inside on_modified, after the session file check (line 141), before try:
line_count_before = self.processed_line_count
```

After the `extract_new_content_with_seq` call (line 144), add:

```python
line_count_after = self.processed_line_count
if new_blocks or user_texts:
    print(f"[SYNC] on_modified: lines {line_count_before}→{line_count_after}, "
          f"blocks={len(new_blocks)}, user_texts={len(user_texts)}")
elif line_count_after > line_count_before:
    print(f"[SYNC] on_modified: lines {line_count_before}→{line_count_after} (no extractable content)")
```

After the callback scheduling section (after line 188), add:

```python
if new_blocks:
    print(f"[SYNC] Scheduled content_callback (seq={start_line})")
if user_texts:
    print(f"[SYNC] Scheduled {len(user_texts)} user_callbacks")
```

**Step 2: Add logging to `_reconciliation_loop`**

In `_reconciliation_loop` (line 493), add a timestamp tracker and logging. Replace the loop body with:

```python
async def _reconciliation_loop(self):
    """Periodically check for lines watchdog missed and send them to clients."""
    last_watchdog_time = time.time()
    try:
        while True:
            await asyncio.sleep(3.0)
            if not self.active_session_id or not self.transcript_handler:
                continue

            # Check if watchdog has been silent while file changed
            if self.transcript_handler.expected_session_file:
                try:
                    file_mtime = os.path.getmtime(self.transcript_handler.expected_session_file)
                    if file_mtime > last_watchdog_time + 10:
                        print(f"[SYNC WARNING] No watchdog events for {time.time() - last_watchdog_time:.0f}s "
                              f"but file mtime is newer")
                except OSError:
                    pass

            new_blocks, user_texts, start_line = self.transcript_handler.reconcile()

            if new_blocks:
                print(f"[RECONCILE] Found {len(new_blocks)} missed blocks (seq={start_line})")
                response = AssistantResponse(
                    content_blocks=new_blocks,
                    timestamp=time.time(),
                    is_incremental=True
                )
                await self.handle_content_response(response, seq=start_line)

                if not self.tts_enabled:
                    await self.send_idle_to_all_clients()

            if user_texts:
                print(f"[RECONCILE] Found {len(user_texts)} missed user messages")
                for idx, text in enumerate(user_texts):
                    await self.handle_user_message(text, seq=start_line + idx)

            last_watchdog_time = time.time()

    except asyncio.CancelledError:
        pass
```

**Step 3: Run existing tests to verify no regressions**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests pass

**Step 4: Commit**

```bash
git add voice_server/ios_server.py
git commit -m "feat: add diagnostic logging to sync chain for debugging message loss"
```

---

### Task 3: Delivery verification — server side (Problem 1A server)

After sending input to tmux, poll the transcript for the user message to appear. Send `delivery_status` to iOS.

**Files:**
- Modify: `voice_server/ios_server.py:609-632` (handle_voice_input)
- Modify: `voice_server/ios_server.py:571-575` (near send_to_terminal)
- Test: `voice_server/tests/test_sync_integration.py`

**Step 1: Write the failing test**

Add to `test_sync_integration.py`:

```python
class TestDeliveryVerification:
    """Tests for delivery verification after sending input"""

    @pytest.mark.asyncio
    async def test_verify_delivery_finds_user_message(self, tmp_path):
        """verify_delivery returns True when user message appears in transcript"""
        from voice_server.ios_server import VoiceServer
        from unittest.mock import patch, Mock

        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        with patch.object(VoiceServer, '__init__', lambda self: None):
            server = VoiceServer()

        # Set up minimal transcript handler
        handler = TranscriptHandler(
            content_callback=lambda r, s=0: None,
            audio_callback=lambda t: None,
            loop=asyncio.get_event_loop(),
            server=server
        )
        handler.set_session_file(str(transcript_file))
        server.transcript_handler = handler

        # Simulate: user message appears after 0.5s
        async def write_after_delay():
            await asyncio.sleep(0.5)
            with open(transcript_file, "a") as f:
                f.write(json.dumps({
                    "message": {"role": "user", "content": [{"type": "text", "text": "hello world"}]},
                    "timestamp": "2026-01-01T00:00:00Z"
                }) + "\n")

        asyncio.create_task(write_after_delay())
        result = await server.verify_delivery("hello world", timeout=3)
        assert result is True

    @pytest.mark.asyncio
    async def test_verify_delivery_times_out(self, tmp_path):
        """verify_delivery returns False when message never appears"""
        from voice_server.ios_server import VoiceServer
        from unittest.mock import patch

        transcript_file = tmp_path / "session.jsonl"
        transcript_file.write_text("")

        with patch.object(VoiceServer, '__init__', lambda self: None):
            server = VoiceServer()

        handler = TranscriptHandler(
            content_callback=lambda r, s=0: None,
            audio_callback=lambda t: None,
            loop=asyncio.get_event_loop(),
            server=server
        )
        handler.set_session_file(str(transcript_file))
        server.transcript_handler = handler

        result = await server.verify_delivery("never appears", timeout=1)
        assert result is False
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_sync_integration.py::TestDeliveryVerification -v`
Expected: FAIL — `VoiceServer` has no `verify_delivery` method

**Step 3: Implement `verify_delivery` and update `handle_voice_input`**

Add to `VoiceServer` class in `ios_server.py`, after `send_to_terminal` (after line 575):

```python
async def verify_delivery(self, text: str, timeout: float = 5.0) -> bool:
    """Poll transcript file to verify a user message was written by Claude Code.

    Returns True if a user-role line containing `text` appears within timeout.
    """
    if not self.transcript_handler or not self.transcript_handler.expected_session_file:
        return False

    filepath = self.transcript_handler.expected_session_file
    start_line = self.transcript_handler.processed_line_count
    deadline = time.time() + timeout
    poll_interval = 0.5

    while time.time() < deadline:
        try:
            with open(filepath, 'r') as f:
                lines = f.readlines()

            for line in lines[start_line:]:
                try:
                    entry = json.loads(line.strip())
                    msg = entry.get('message', {})
                    role = msg.get('role') or entry.get('role')
                    if role == 'user':
                        content = msg.get('content', '')
                        if isinstance(content, str) and text in content:
                            return True
                        elif isinstance(content, list):
                            for block in content:
                                if isinstance(block, dict) and text in block.get('text', ''):
                                    return True
                except (json.JSONDecodeError, KeyError):
                    continue
        except FileNotFoundError:
            pass

        await asyncio.sleep(poll_interval)

    return False
```

Update `handle_voice_input` (line 609). After `await self.send_to_terminal(text)` (line 629), add delivery verification:

```python
            await self.send_to_terminal(text)
            print(f"[{time.strftime('%H:%M:%S')}] Sent to terminal successfully")

            # Verify delivery — check if message appears in transcript
            delivered = await self.verify_delivery(text)
            delivery_msg = {
                "type": "delivery_status",
                "status": "confirmed" if delivered else "failed",
                "text": text
            }
            for client in list(self.clients):
                try:
                    await client.send(json.dumps(delivery_msg))
                except Exception:
                    pass

            if not delivered:
                print(f"[SYNC WARNING] Message delivery not confirmed: '{text[:50]}'")
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_sync_integration.py::TestDeliveryVerification -v`
Expected: PASS

**Step 5: Run full test suite**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests pass

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_sync_integration.py
git commit -m "feat: add delivery verification polling for sent messages"
```

---

### Task 4: Delivery verification — iOS side (Problem 1A iOS) + Settings fix (Problem 2)

Handle `delivery_status` messages in the app. Also fix the Settings "Connecting..." button issue and add TCP pre-check.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift` (SessionHistoryMessage)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SettingsView.swift`

**Step 1: Add `DeliveryStatusMessage` model**

In `Message.swift`, add after the existing message structs:

```swift
struct DeliveryStatusMessage: Codable {
    let type: String
    let status: String  // "confirmed" or "failed"
    let text: String
}
```

**Step 2: Add `deliveryFailed` property to `SessionHistoryMessage`**

In `Session.swift`, find `SessionHistoryMessage` (line 36). It currently uses auto-synthesized `Codable` with `let` properties. Add a mutable `deliveryFailed` property and a `CodingKeys` enum to exclude it from decoding (otherwise Swift's auto-synthesized decoder will require it in JSON):

```swift
struct SessionHistoryMessage: Codable, Identifiable {
    let role: String
    let content: String
    let timestamp: Double
    var deliveryFailed: Bool = false

    var id: Double { timestamp }

    enum CodingKeys: String, CodingKey {
        case role, content, timestamp
        // deliveryFailed excluded — local-only state
    }
}
```

**Step 3: Handle `delivery_status` in WebSocketManager**

In `WebSocketManager.swift`, add a callback property:

```swift
var onDeliveryStatus: ((DeliveryStatusMessage) -> Void)?
```

In the message parsing section of `handleMessage()`, add a decode case for `DeliveryStatusMessage`:

```swift
if let deliveryStatus = try? decoder.decode(DeliveryStatusMessage.self, from: data),
   deliveryStatus.type == "delivery_status" {
    DispatchQueue.main.async { [weak self] in
        self?.onDeliveryStatus?(deliveryStatus)
    }
    return
}
```

**Step 4: Show "Failed to send" in SessionView**

In `SessionView.swift`, in the setup section where callbacks are configured, add:

```swift
webSocketManager.onDeliveryStatus = { [self] status in
    if status.status == "failed" {
        // Find the matching user message and mark it failed
        for i in stride(from: items.count - 1, through: 0, by: -1) {
            if case .textMessage(var msg) = items[i],
               msg.role == "user",
               msg.content.contains(status.text) {
                msg.deliveryFailed = true
                items[i] = .textMessage(msg)
                break
            }
        }
    }
}
```

In the message bubble rendering (where `MessageBubble` is used for user messages), add below the bubble:

```swift
if case .textMessage(let msg) = item, msg.role == "user", msg.deliveryFailed {
    Text("Failed to send")
        .font(.caption2)
        .foregroundColor(.red)
        .padding(.trailing, 8)
        .frame(maxWidth: .infinity, alignment: .trailing)
}
```

**Step 5: Fix Settings "Connecting..." button (Problem 2B)**

In `SettingsView.swift`, replace the connection button section (lines 38-55) with:

```swift
} else if case .connecting = webSocketManager.connectionState {
    // Non-interactive connecting state
    HStack {
        Spacer()
        ProgressView()
            .padding(.trailing, 8)
        Text("Connecting...")
            .foregroundColor(.secondary)
        Spacer()
    }
    .padding()
    .background(Color(.secondarySystemGroupedBackground))
} else {
    Button(action: { showingScanner = true }) {
        HStack {
            Spacer()
            Text("Connect")
            Spacer()
        }
    }
    .padding()
    .background(Color(.secondarySystemGroupedBackground))
    .accessibilityIdentifier("Connect")
}
```

**Step 6: Add TCP pre-check to WebSocketManager**

In `WebSocketManager.swift`, add a private method:

```swift
import Network  // Add at top of file

private func tcpCheck(host: String, port: UInt16) async -> Bool {
    await withCheckedContinuation { continuation in
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var resumed = false

        connection.stateUpdateHandler = { state in
            guard !resumed else { return }
            switch state {
            case .ready:
                resumed = true
                connection.cancel()
                continuation.resume(returning: true)
            case .failed, .cancelled:
                resumed = true
                connection.cancel()
                continuation.resume(returning: false)
            default:
                break
            }
        }

        connection.start(queue: .global())

        // Safety timeout
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
            guard !resumed else { return }
            resumed = true
            connection.cancel()
            continuation.resume(returning: false)
        }
    }
}
```

Update `connectToURL()` (line 129) to call the TCP check before creating the WebSocket. After the `connectionState = .connecting` line (153) and before creating the WebSocket task (line 165), add:

```swift
// TCP pre-check — fail fast if server is unreachable
if let host = url.host, let port = url.port {
    Task { [weak self] in
        guard let self = self else { return }
        let reachable = await self.tcpCheck(host: host, port: UInt16(port))
        if !reachable {
            await MainActor.run {
                self.connectionState = .error("Server not reachable")
                self.shouldReconnect = false
            }
            return
        }
        // TCP succeeded — proceed with WebSocket on main thread
        await MainActor.run {
            guard self.connectionState == .connecting else { return }
            let task = self.urlSession?.webSocketTask(with: url)
            self.webSocketTask = task
            task?.resume()
            self.receiveMessage()
        }
    }
    return  // Early return — WebSocket creation happens in the Task above
} else {
    // Fallback: no host/port available, connect directly
    webSocketTask = session.webSocketTask(with: url)
    webSocketTask?.resume()
    receiveMessage()
}
```

Remove the existing WebSocket creation lines (164-167) since they're now handled by the TCP check path and the fallback else branch above.

**Step 7: Build and verify**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: Build succeeds

**CHECKPOINT:** If the build fails, fix compilation errors before proceeding.

**Step 8: Commit**

```bash
git add ios-voice-app/ClaudeVoice/
git commit -m "feat: delivery status indicator, Settings connecting fix, and TCP pre-check"
```

---

### Task 5: Voice becomes dictation (Problem 3)

Voice input appends to the text field instead of sending directly. User reviews and taps send.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift:448-467` (onFinalTranscription)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift:715-732` (toggleRecording)

**Step 1: Change `onFinalTranscription` to append to text field**

Replace the `onFinalTranscription` callback (lines 448-467) with:

```swift
speechRecognizer.onFinalTranscription = { text in
    // Append transcribed text to the text field (dictation mode)
    if messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        messageText = text
    } else {
        messageText += " " + text
    }
    currentTranscript = ""
}
```

This removes:
- The `items.append(.textMessage(...))` — no longer adds to conversation immediately
- The `webSocketManager.sendVoiceInput(text:)` — no longer sends directly
- The `lastVoiceInputText` / `lastVoiceInputTime` tracking — not needed here (sendTextMessage sets these)
- The 2-second transcript clear timer — not needed since we clear immediately

**Step 2: Don't dismiss keyboard in `toggleRecording`**

In `toggleRecording` (line 715), remove the `isTextFieldFocused = false` line (line 720):

```swift
private func toggleRecording() {
    if speechRecognizer.isRecording {
        speechRecognizer.stopRecording()
    } else {
        // Stop any TTS playback so mic can take over
        if audioPlayer.isPlaying {
            audioPlayer.stop()
        }
        webSocketManager.voiceState = .idle
        do {
            try speechRecognizer.startRecording()
        } catch {
            print("Failed to start recording: \(error)")
        }
    }
}
```

**Step 3: Build and verify**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: Build succeeds

**CHECKPOINT:** If the build fails, fix compilation errors before proceeding.

**Step 4: Manual verification (REQUIRED before merge)**

1. Build and install on device
2. Open a session, type some text in the input field
3. Tap mic, speak a phrase, tap mic to stop
4. Verify: spoken text appears appended in the text field after existing text
5. Tap send — message sends normally
6. Verify: mic without prior text also works (text appears in field, send to submit)

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: voice input becomes dictation that appends to text field"
```

---

### Task 6: Sort projects by latest activity (Problem 4)

**Files:**
- Modify: `voice_server/session_manager.py:61-93` (list_projects)
- Modify: `voice_server/tests/test_session_manager.py`

**Step 1: Write the failing test**

Add these methods to the existing `TestSessionManager` class in `test_session_manager.py`:

```python
    def test_list_projects_sorted_by_latest_session_mtime(self, tmp_path):
        """Projects are returned sorted by most recent session file modification time"""
        from session_manager import SessionManager

        # Create 3 projects with sessions at different times
        old_project = tmp_path / "-Users-test-old"
        old_project.mkdir()
        (old_project / "session1.jsonl").write_text('{"type":"summary"}')
        # Force old mtime
        os.utime(old_project / "session1.jsonl", (1000, 1000))

        new_project = tmp_path / "-Users-test-new"
        new_project.mkdir()
        (new_project / "session1.jsonl").write_text('{"type":"summary"}')
        # Force newest mtime
        os.utime(new_project / "session1.jsonl", (3000, 3000))

        mid_project = tmp_path / "-Users-test-mid"
        mid_project.mkdir()
        (mid_project / "session1.jsonl").write_text('{"type":"summary"}')
        os.utime(mid_project / "session1.jsonl", (2000, 2000))

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert len(projects) == 3
        assert projects[0].name == "new"
        assert projects[1].name == "mid"
        assert projects[2].name == "old"

    def test_list_projects_empty_project_sorts_last(self, tmp_path):
        """Projects with no sessions sort to the end"""
        from session_manager import SessionManager

        empty_project = tmp_path / "-Users-test-empty"
        empty_project.mkdir()
        # No .jsonl files

        has_sessions = tmp_path / "-Users-test-active"
        has_sessions.mkdir()
        (has_sessions / "session1.jsonl").write_text('{"type":"summary"}')

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert len(projects) == 2
        assert projects[0].name == "active"
        assert projects[1].name == "empty"
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_session_manager.py::TestSessionManager::test_list_projects_sorted_by_latest_session_mtime -v`
Expected: FAIL (projects returned in arbitrary order)

**Step 3: Implement sorting**

In `session_manager.py`, add a helper method before `list_projects` and add the sort call:

```python
def _get_project_latest_mtime(self, folder_name: str) -> float:
    """Get the mtime of the most recent session file in a project."""
    project_path = os.path.join(self.projects_dir, folder_name)
    session_files = glob.glob(os.path.join(project_path, "*.jsonl"))
    if not session_files:
        return 0
    return max(os.path.getmtime(f) for f in session_files)
```

At the end of `list_projects()`, before `return projects` (line 93), add:

```python
projects.sort(key=lambda p: self._get_project_latest_mtime(p.folder_name), reverse=True)
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_session_manager.py -v`
Expected: All tests pass (including the new ones)

**Step 5: Run full test suite**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests pass

**Step 6: Commit**

```bash
git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "feat: sort projects by most recent session activity"
```

---

### Task 7: Final verification

**Step 1: Run full server test suite**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests pass

**Step 2: Build iOS app**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'`
Expected: Build succeeds

**CHECKPOINT:** All server tests pass and iOS builds. If not, fix before proceeding.

**Step 3: Manual verification checklist**

Install app on device and verify:

1. **Delivery status:** Send a message when Claude is active → no "Failed to send". Send when no session → "Failed to send" appears.
2. **Settings:** Start app with server down → "Connecting..." is NOT tappable, quickly shows error. Start with server up → connects normally.
3. **Voice dictation:** Tap mic, speak, stop → text in field. Type more, tap send → sends combined text.
4. **Project ordering:** Projects list shows most recently used project first.
