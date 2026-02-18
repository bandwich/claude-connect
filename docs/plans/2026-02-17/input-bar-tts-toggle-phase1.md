# Input Bar + TTS Toggle — Phase 1 Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Replace the mic-only bottom area with a text input bar + keyboard accessory toolbar (mic + send buttons), and add a TTS on/off toggle in Settings.

**Architecture:** New message types (`user_input`, `set_preference`) added to both iOS and server. Server gains a `tts_enabled` flag that gates TTS generation. SessionView's bottom area is replaced with a TextField + keyboard toolbar. Phase 2 adds image picker support on top of this.

**Tech Stack:** Swift/SwiftUI (iOS 16+), Python/asyncio (server), WebSocket JSON protocol

**Risky Assumptions:** `ToolbarItemGroup(placement: .keyboard)` may not show buttons when keyboard is dismissed. Mitigation: the buttons (mic, send) are placed inline in the input bar itself (always visible), not inside the keyboard toolbar. The keyboard toolbar is only used as a secondary placement if needed later.

---

### Task 1: Add message models and WebSocket methods

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift`

**Step 1: Add new message structs to Message.swift**

Add after the existing `VoiceInputMessage` struct (line 13):

```swift
struct ImageAttachment: Codable {
    let data: String      // base64-encoded image
    let filename: String
}

struct UserInputMessage: Codable {
    let type: String
    let text: String
    let images: [ImageAttachment]
    let timestamp: Double

    init(text: String, images: [ImageAttachment] = []) {
        self.type = "user_input"
        self.text = text
        self.images = images
        self.timestamp = Date().timeIntervalSince1970
    }
}

struct SetPreferenceMessage: Codable {
    let type: String
    let ttsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case ttsEnabled = "tts_enabled"
    }

    init(ttsEnabled: Bool) {
        self.type = "set_preference"
        self.ttsEnabled = ttsEnabled
    }
}
```

**Step 2: Add send methods to WebSocketManager.swift**

Add after the `sendVoiceInput` method (after line 218):

```swift
func sendUserInput(text: String, images: [ImageAttachment] = []) {
    let message = UserInputMessage(text: text, images: images)

    guard let jsonData = try? JSONEncoder().encode(message),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
        print("Failed to encode user input message")
        return
    }

    let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
    webSocketTask?.send(wsMessage) { [weak self] error in
        if let error = error {
            if case .disconnected = self?.connectionState { return }
            print("Send user input error: \(error.localizedDescription)")
        }
    }
}

func sendPreference(ttsEnabled: Bool) {
    let message = SetPreferenceMessage(ttsEnabled: ttsEnabled)

    guard let jsonData = try? JSONEncoder().encode(message),
          let jsonString = String(data: jsonData, encoding: .utf8) else {
        print("Failed to encode preference message")
        return
    }

    let wsMessage = URLSessionWebSocketTask.Message.string(jsonString)
    webSocketTask?.send(wsMessage) { error in
        if let error = error {
            print("Send preference error: \(error)")
        }
    }
}
```

**Step 3: Write unit tests**

Add to `WebSocketManagerTests.swift` (uses Swift Testing framework — `@Test`, `#expect`):

```swift
@Test func testUserInputMessageEncodesCorrectly() throws {
    let message = UserInputMessage(text: "hello", images: [])
    let data = try JSONEncoder().encode(message)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    #expect(json["type"] as? String == "user_input")
    #expect(json["text"] as? String == "hello")
    #expect((json["images"] as? [Any])?.isEmpty == true)
    #expect(json["timestamp"] != nil)
}

@Test func testUserInputMessageWithImagesEncodesCorrectly() throws {
    let img = ImageAttachment(data: "abc123", filename: "photo.jpg")
    let message = UserInputMessage(text: "look at this", images: [img])
    let data = try JSONEncoder().encode(message)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    let images = json["images"] as! [[String: Any]]
    #expect(images.count == 1)
    #expect(images[0]["data"] as? String == "abc123")
    #expect(images[0]["filename"] as? String == "photo.jpg")
}

@Test func testSetPreferenceEncodesCorrectly() throws {
    let message = SetPreferenceMessage(ttsEnabled: false)
    let data = try JSONEncoder().encode(message)
    let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

    #expect(json["type"] as? String == "set_preference")
    #expect(json["tts_enabled"] as? Bool == false)
}
```

**Step 4: Run iOS unit tests**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/WebSocketManagerTests 2>&1 | tail -20`

Expected: All tests PASS

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift
git commit -m "feat: add UserInputMessage and SetPreferenceMessage models + WebSocket methods"
```

---

### Task 2: Server — handle set_preference and gate TTS

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`
- Create: `voice_server/tests/test_tts_preference.py`

**Step 1: Write failing tests for set_preference handler**

Create `voice_server/tests/test_tts_preference.py`:

```python
"""Tests for TTS preference handling."""
import pytest
import json
import asyncio
from unittest.mock import AsyncMock, Mock, patch

from voice_server.ios_server import VoiceServer


@pytest.fixture
async def server():
    """Create a VoiceServer with mocked dependencies."""
    with patch('voice_server.ios_server.TmuxController'), \
         patch('voice_server.ios_server.set_tmux_controller'), \
         patch('voice_server.ios_server.set_voice_server'):
        s = VoiceServer()
        s.loop = asyncio.get_event_loop()
        s.tts_queue = asyncio.Queue()
        s.tts_cancel = asyncio.Event()
        return s


@pytest.mark.asyncio
async def test_tts_enabled_default_true(server):
    """TTS should be enabled by default."""
    assert server.tts_enabled is True


@pytest.mark.asyncio
async def test_set_preference_disables_tts(server):
    """set_preference with tts_enabled=false should disable TTS."""
    mock_ws = AsyncMock()
    await server.handle_message(
        mock_ws,
        json.dumps({"type": "set_preference", "tts_enabled": False})
    )
    assert server.tts_enabled is False


@pytest.mark.asyncio
async def test_set_preference_enables_tts(server):
    """set_preference with tts_enabled=true should enable TTS."""
    mock_ws = AsyncMock()
    server.tts_enabled = False
    await server.handle_message(
        mock_ws,
        json.dumps({"type": "set_preference", "tts_enabled": True})
    )
    assert server.tts_enabled is True


@pytest.mark.asyncio
async def test_handle_tts_response_skips_when_disabled(server):
    """When TTS is disabled, handle_tts_response should not queue audio."""
    server.tts_enabled = False
    server.clients = {AsyncMock()}

    await server.handle_tts_response("Hello world")

    # Queue should be empty — nothing was queued
    assert server.tts_queue.empty()


@pytest.mark.asyncio
async def test_handle_tts_response_queues_when_enabled(server):
    """When TTS is enabled, handle_tts_response should queue audio."""
    server.tts_enabled = True
    server.clients = {AsyncMock()}

    await server.handle_tts_response("Hello world")

    assert not server.tts_queue.empty()
    text = server.tts_queue.get_nowait()
    assert text == "Hello world"
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_tts_preference.py -v`

Expected: FAIL — `tts_enabled` attribute doesn't exist, `handle_tts_response` doesn't check the flag, `set_preference` not handled

**Step 3: Implement server changes in ios_server.py**

Add `tts_enabled` to `__init__` (after line 338, the `active_folder_name` line):

```python
        self.tts_enabled = True  # TTS on by default, toggled via set_preference
```

Add handler method (after the `handle_voice_input` method, around line 537):

```python
    async def handle_set_preference(self, data):
        """Handle preference changes from iOS app"""
        if 'tts_enabled' in data:
            self.tts_enabled = data['tts_enabled']
            print(f"[Preference] TTS enabled: {self.tts_enabled}")
```

Modify `handle_tts_response` (the method at line 570) to check the flag. Add at the top of the method, before the existing code:

```python
        if not self.tts_enabled:
            print(f"[{time.strftime('%H:%M:%S')}] TTS disabled, skipping audio for: '{text[:50]}...'")
            # Still send idle status so client knows response is done
            for client in list(self.clients):
                try:
                    await self.send_status(client, "idle", "Ready")
                except Exception:
                    pass
            return
```

Add the routing in `handle_message` (after the `usage_request` elif, around line 1087):

```python
            elif msg_type == 'set_preference':
                await self.handle_set_preference(data)
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_tts_preference.py -v`

Expected: All 5 tests PASS

**Step 5: Run full server test suite**

Run: `cd voice_server/tests && ./run_tests.sh`

Expected: All existing tests still pass

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_tts_preference.py
git commit -m "feat: add set_preference handler and TTS gating on server"
```

---

### Task 3: SettingsView — TTS toggle

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SettingsView.swift`

**Step 1: Add TTS toggle to SettingsView**

Add `@AppStorage` property to SettingsView (after line 7, the `alertMessage` state):

```swift
@AppStorage("ttsEnabled") private var ttsEnabled = true
```

Add an "Audio" section in the body. Insert after the Connection section's closing `.padding(.horizontal)` (after line 99) and before the Usage Section comment (line 102):

```swift
                    // Audio Section
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Audio")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal)
                            .padding(.top, 24)
                            .padding(.bottom, 8)

                        VStack(spacing: 0) {
                            Toggle("Text-to-Speech", isOn: $ttsEnabled)
                                .padding()
                                .background(Color(.secondarySystemGroupedBackground))
                                .accessibilityIdentifier("ttsToggle")
                        }
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                    .onChange(of: ttsEnabled) { _, newValue in
                        if case .connected = webSocketManager.connectionState {
                            webSocketManager.sendPreference(ttsEnabled: newValue)
                        }
                    }
```

**Step 2: Send TTS preference on connect**

In SettingsView's `.onChange(of: webSocketManager.connectionState)` handler (line 217-222), add the preference sync after the usage fetch:

```swift
                    webSocketManager.sendPreference(ttsEnabled: ttsEnabled)
```

So the full handler becomes:
```swift
            .onChange(of: webSocketManager.connectionState) { _, newState in
                if case .connected = newState {
                    webSocketManager.requestUsage()
                    webSocketManager.sendPreference(ttsEnabled: ttsEnabled)
                }
            }
```

Also send on `.onAppear` (line 211-215), add after the usage request:

```swift
                    webSocketManager.sendPreference(ttsEnabled: ttsEnabled)
```

**Step 3: Build to verify compilation**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SettingsView.swift
git commit -m "feat: add TTS toggle in Settings with server preference sync"
```

---

### Task 4: SessionView — replace mic area with text input bar

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

This is the largest task. We replace the mic-only bottom area (lines 94-127) with a text input bar containing a TextField, mic button, and send button.

**Step 1: Add state variables**

Add to SessionView's `@State` properties (after line 21):

```swift
@State private var messageText = ""
@AppStorage("ttsEnabled") private var ttsEnabled = true
```

**Step 2: Add canSend computed property**

Add after the `canRecord` computed property (after line 202):

```swift
private var canSend: Bool {
    guard isSessionSynced else { return false }
    guard webSocketManager.outputState.canSendVoiceInput else { return false }
    if case .connected = webSocketManager.connectionState {
        return !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    return false
}
```

**Step 3: Replace the bottom mic area**

Replace the entire `// Bottom mic area` VStack (lines 94-127) with:

```swift
            // Input bar
            VStack(spacing: 0) {
                if let error = syncError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.red)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("syncError")
                } else if !isSessionSynced && !session.isNewSession {
                    VStack(spacing: 8) {
                        ProgressView()
                    }
                    .frame(height: 100)
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("syncStatus")
                } else {
                    // Input area with text field and buttons
                    HStack(alignment: .bottom, spacing: 8) {
                        // Text field
                        TextField("Message Claude...", text: $messageText, axis: .vertical)
                            .lineLimit(1...5)
                            .textFieldStyle(.plain)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.systemGray6))
                            .cornerRadius(20)
                            .disabled(speechRecognizer.isRecording)
                            .accessibilityIdentifier("messageTextField")

                        // Mic button
                        Button(action: toggleRecording) {
                            Image(systemName: speechRecognizer.isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 20))
                                .foregroundColor(speechRecognizer.isRecording ? .red : .secondary)
                                .frame(width: 36, height: 36)
                        }
                        .accessibilityLabel(speechRecognizer.isRecording ? "Stop" : "Tap to Talk")
                        .disabled(!speechRecognizer.isRecording && !canRecord)
                        .accessibilityIdentifier("micButton")

                        // Send button (only when there's text to send)
                        if canSend {
                            Button(action: sendTextMessage) {
                                Image(systemName: "arrow.up.circle.fill")
                                    .font(.system(size: 30))
                                    .foregroundColor(.blue)
                            }
                            .accessibilityLabel("Send")
                            .accessibilityIdentifier("sendButton")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                }
            }
            .background(Color(.systemBackground))
```

**Step 4: Add sendTextMessage function**

Add after the `toggleRecording` function (after line 495):

```swift
private func sendTextMessage() {
    let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }

    // Add to conversation items locally
    let userMessage = SessionHistoryMessage(
        role: "user",
        content: text,
        timestamp: Date().timeIntervalSince1970
    )
    items.append(.textMessage(userMessage))

    // Track for server echo dedup
    lastVoiceInputText = text
    lastVoiceInputTime = Date()

    // Send via WebSocket
    webSocketManager.sendUserInput(text: text)

    // Clear text field
    messageText = ""
}
```

**Step 5: Gate audio chunks on ttsEnabled**

In `setupView`, modify the `onAudioChunk` callback (around line 323) to check the toggle:

```swift
        webSocketManager.onAudioChunk = { [self] chunk in
            if ttsEnabled {
                audioPlayer.receiveAudioChunk(chunk)
            }
        }
```

**Step 6: Build to verify compilation**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

**Step 7: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: replace mic-only area with text input bar + mic + send buttons"
```

---

### Task 5: Server — handle user_input message type

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_message_handlers.py`

**Step 1: Write failing test for user_input handler**

Add to `voice_server/tests/test_message_handlers.py`:

```python
class TestUserInput:
    """Tests for user_input message handler"""

    @pytest.mark.asyncio
    async def test_user_input_text_only(self):
        """user_input with text only should send text to terminal."""
        from ios_server import VoiceServer

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.session_exists.return_value = True
        server.tmux.send_input = Mock(return_value=True)

        mock_ws = AsyncMock()
        await server.handle_message(
            mock_ws,
            json.dumps({"type": "user_input", "text": "hello claude", "images": [], "timestamp": 1234})
        )

        server.tmux.send_input.assert_called_once_with("hello claude")

    @pytest.mark.asyncio
    async def test_user_input_with_images_saves_files(self):
        """user_input with images should save them and include paths in prompt."""
        from ios_server import VoiceServer
        import base64

        server = VoiceServer()
        server.tmux = Mock()
        server.tmux.session_exists.return_value = True
        server.tmux.send_input = Mock(return_value=True)

        # Create a tiny valid base64 image (1x1 red pixel PNG header)
        img_data = base64.b64encode(b"\x89PNG\r\n\x1a\nfakedata").decode()

        mock_ws = AsyncMock()
        await server.handle_message(
            mock_ws,
            json.dumps({
                "type": "user_input",
                "text": "what is this",
                "images": [{"data": img_data, "filename": "photo.png"}],
                "timestamp": 1234
            })
        )

        # Verify send_input was called with text that includes an image path
        call_args = server.tmux.send_input.call_args[0][0]
        assert "what is this" in call_args
        assert "/tmp/claude_voice_img_" in call_args
        assert ".png" in call_args
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py::TestUserInput -v`

Expected: FAIL — `user_input` not handled

**Step 3: Implement user_input handler in ios_server.py**

Add handler method (after `handle_set_preference`):

```python
    async def handle_user_input(self, websocket, data):
        """Handle text + optional image input from iOS"""
        text = data.get('text', '').strip()
        images = data.get('images', [])

        if not text and not images:
            print("Empty user_input received, ignoring")
            return

        # Save images to temp files and build prompt
        image_paths = []
        for img in images:
            try:
                import uuid
                img_data = base64.b64decode(img['data'])
                ext = os.path.splitext(img.get('filename', 'image.jpg'))[1] or '.jpg'
                filename = f"claude_voice_img_{uuid.uuid4().hex[:12]}{ext}"
                filepath = os.path.join('/tmp', filename)
                with open(filepath, 'wb') as f:
                    f.write(img_data)
                image_paths.append(filepath)
                print(f"[UserInput] Saved image: {filepath} ({len(img_data)} bytes)")
            except Exception as e:
                print(f"[UserInput] Failed to save image: {e}")

        # Build prompt with image references
        prompt = text
        for path in image_paths:
            prompt += f"\n[Image: {path}]"

        print(f"[{time.strftime('%H:%M:%S')}] User input: '{prompt[:100]}'")

        self.waiting_for_response = True
        self.last_voice_input = text  # Track for echo dedup

        for client in list(self.clients):
            try:
                await self.send_status(client, "processing", "Sending to Claude...")
            except Exception:
                pass

        await self.send_to_terminal(prompt)
```

Add routing in `handle_message` (add before or after the `voice_input` routing). Add this after the `voice_input` permission rejection check (around line 1060), and in the routing block add:

```python
            elif msg_type == 'user_input':
                if self.permission_handler.pending_permissions:
                    await websocket.send(json.dumps({
                        "type": "error",
                        "message": "Cannot send input while permission pending"
                    }))
                    return
                await self.handle_user_input(websocket, data)
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py::TestUserInput -v`

Expected: All tests PASS

**Step 5: Run full server test suite**

Run: `cd voice_server/tests && ./run_tests.sh`

Expected: All tests pass

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: add user_input handler with image file saving on server"
```

---

### CHECKPOINT: Verify End-to-End

At this point, the text input bar and TTS toggle should work end-to-end:

1. **Reinstall server:** `pipx install --force /Users/aaron/Desktop/max`
2. **Start server:** `claude-connect`
3. **Build and install iOS app** on device
4. **Test text input:** Type a message in the text field, tap send — verify it appears in conversation and Claude responds
5. **Test mic:** Tap mic button — verify voice input still works as before
6. **Test TTS toggle:** Go to Settings, toggle TTS off. Send a message. Verify Claude responds with text but no audio plays. Toggle back on, verify audio resumes.

**CHECKPOINT:** If text input or TTS toggle doesn't work end-to-end, debug now before proceeding to Phase 2 (image input).
