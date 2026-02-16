# Surface Missing User Messages in iOS Session View

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Show terminal-typed user messages, image attachment placeholders, and interrupts in the iOS session view — currently only voice input appears.

**Architecture:** The transcript watcher (`TranscriptHandler`) gains a `user_callback` for user text messages, parallel to the existing `content_callback` for assistant content. The server sends a `user_message` WebSocket message that iOS handles identically to voice input. Image blocks are replaced with `[Image: filename]` placeholders. The `ContentBlock` decoder gains graceful unknown-type handling as a safety net.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS)

**Risky Assumptions:** The `[Image: source: /path/file.png]` pattern is consistent across Claude Code versions. We verify this early in Task 1 with a test that parses the real format.

---

### Task 1: Server — extract user text messages from transcript lines

Add user text extraction to `TranscriptHandler.extract_new_assistant_content` and return them separately. Add image filename extraction helper.

**Files:**
- Modify: `voice_server/ios_server.py:138-217` (extract method + on_modified)
- Modify: `voice_server/ios_server.py:74` (TranscriptHandler.__init__ — add user_callback)
- Test: `voice_server/tests/test_response_extraction.py`

**Step 1: Write failing tests for user text extraction and image filename rewriting**

Add to `voice_server/tests/test_response_extraction.py`:

```python
import re


def test_extract_user_text_from_string_content():
    """User messages with string content should be returned as user_texts"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "hello from terminal"}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts = handler.extract_new_content(temp_path)
        assert len(blocks) == 0
        assert len(user_texts) == 1
        assert user_texts[0] == "hello from terminal"
    finally:
        os.unlink(temp_path)


def test_extract_user_text_from_list_with_text_blocks():
    """User messages with text blocks (non-tool_result) should be returned"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": [
                {"type": "text", "text": "[Request interrupted by user]"}
            ]}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts = handler.extract_new_content(temp_path)
        assert len(blocks) == 0
        assert len(user_texts) == 1
        assert user_texts[0] == "[Request interrupted by user]"
    finally:
        os.unlink(temp_path)


def test_extract_image_source_rewrites_to_filename():
    """[Image: source: /path/to/file.png] should become [Image: file.png]"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": [
                {"type": "text", "text": "[Image: source: /Users/aaron/Downloads/IMG_5594.PNG]"}
            ]}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts = handler.extract_new_content(temp_path)
        assert len(user_texts) == 1
        assert user_texts[0] == "[Image: IMG_5594.PNG]"
    finally:
        os.unlink(temp_path)


def test_extract_skips_image_blocks():
    """Raw image blocks (base64 data) should be silently skipped"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "abc123"}}
            ]}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts = handler.extract_new_content(temp_path)
        assert len(blocks) == 0
        assert len(user_texts) == 0
    finally:
        os.unlink(temp_path)


def test_extract_skips_skill_expansions():
    """Skill expansion user messages should not be surfaced"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "Base directory for this skill: /foo/bar"}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts = handler.extract_new_content(temp_path)
        assert len(user_texts) == 0
    finally:
        os.unlink(temp_path)


def test_extract_skips_task_notifications():
    """<task-notification> user messages should not be surfaced"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "<task-notification>something</task-notification>"}
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': None})()
        handler = TranscriptHandler(None, None, None, mock_server)
        blocks, user_texts = handler.extract_new_content(temp_path)
        assert len(user_texts) == 0
    finally:
        os.unlink(temp_path)
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_response_extraction.py::test_extract_user_text_from_string_content -v`
Expected: FAIL — `extract_new_content` does not exist yet.

**Step 3: Implement user text extraction**

In `voice_server/ios_server.py`:

1. Add `user_callback` to `TranscriptHandler.__init__` (line 74):

```python
def __init__(self, content_callback, audio_callback, loop, server, user_callback=None):
    self.content_callback = content_callback
    self.audio_callback = audio_callback
    self.user_callback = user_callback  # Sends user text messages
    self.loop = loop
    self.server = server
    self.last_modified = 0
    self.processed_line_count = 0
    self.expected_session_file = None
    self.context_tracker = ContextTracker()
    self.hidden_tool_ids = set()
```

2. Add helper function near top of file (after `extract_text_for_tts`):

```python
IMAGE_SOURCE_RE = re.compile(r'^\[Image: source: (.+)\]$')

def rewrite_image_source(text: str) -> str:
    """Rewrite [Image: source: /path/to/file.png] to [Image: file.png]"""
    m = IMAGE_SOURCE_RE.match(text.strip())
    if m:
        filename = os.path.basename(m.group(1))
        return f"[Image: {filename}]"
    return text
```

Add `import re` at the top if not already present.

3. Rename `extract_new_assistant_content` → `extract_new_content` and change return type to `tuple[list[ContentBlock], list[str]]`. The second element is user text messages.

In the method body, add a `user_texts: list[str] = []` list. After the existing `elif role == 'user':` block that handles tool_results, add handling for user text:

```python
elif role == 'user':
    content = msg.get('content', entry.get('content', ''))
    if isinstance(content, list):
        has_tool_result = any(
            isinstance(b, dict) and b.get('type') == 'tool_result'
            for b in content
        )
        if has_tool_result:
            # Existing tool_result handling (unchanged)
            for block in content:
                if isinstance(block, dict) and block.get('type') == 'tool_result':
                    if block.get('tool_use_id', '') in self.hidden_tool_ids:
                        continue
                    try:
                        raw_content = block.get('content', '')
                        if isinstance(raw_content, str):
                            content_str = raw_content
                        elif isinstance(raw_content, list):
                            content_str = '\n'.join(
                                b.get('text', '') for b in raw_content
                                if isinstance(b, dict) and b.get('type') == 'text'
                            )
                        else:
                            content_str = str(raw_content)
                        all_blocks.append(ToolResultBlock(
                            type="tool_result",
                            tool_use_id=block.get('tool_use_id', ''),
                            content=content_str,
                            is_error=block.get('is_error', False)
                        ))
                    except Exception:
                        continue
        else:
            # User text blocks (non-tool_result): interrupts, image refs, etc.
            for block in content:
                if isinstance(block, dict):
                    if block.get('type') == 'text':
                        text = block.get('text', '').strip()
                        if not text:
                            continue
                        if text.startswith('Base directory for this skill:'):
                            continue
                        if text.startswith('<task-notification'):
                            continue
                        user_texts.append(rewrite_image_source(text))
                    # Skip image blocks (base64 data) silently
    elif isinstance(content, str) and content.strip():
        stripped = content.strip()
        if stripped.startswith('Base directory for this skill:'):
            pass
        elif stripped.startswith('<task-notification'):
            pass
        else:
            user_texts.append(rewrite_image_source(stripped))
```

At the end of the method, change:
```python
return all_blocks, user_texts
```

4. Update `on_modified` (line 101-128) to use the new return type and call `user_callback`:

```python
try:
    new_blocks, user_texts = self.extract_new_content(event.src_path)

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

    # Broadcast context update after processing
    if self.server.active_session_id:
        self.broadcast_context_update(event.src_path, self.server.active_session_id)
```

**Step 4: Fix all existing tests that call `extract_new_assistant_content`**

The method was renamed. Search for all calls to `extract_new_assistant_content` in tests and update them:
- Tests that do `handler.extract_new_assistant_content(path)` → `handler.extract_new_content(path)` and unpack the tuple: `blocks, _ = handler.extract_new_content(path)` (they only care about blocks).

Run: `cd voice_server/tests && grep -rn "extract_new_assistant_content" *.py` to find all references.

**Step 5: Run all tests to verify they pass**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All PASS.

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_response_extraction.py
git commit -m "feat: extract user text messages from transcript lines"
```

---

### Task 2: Server — send user_message over WebSocket

Wire up the `user_callback` and add `handle_user_message` to `VoiceServer`.

**Files:**
- Modify: `voice_server/ios_server.py:251-270` (VoiceServer.__init__ — wire user_callback)
- Modify: `voice_server/ios_server.py` (add handle_user_message method)
- Test: `voice_server/tests/test_message_handlers.py`

**Step 1: Write failing test**

Add to `voice_server/tests/test_message_handlers.py`:

```python
@pytest.mark.asyncio
async def test_handle_user_message_sends_to_clients():
    """handle_user_message should send user_message JSON to all clients"""
    server = VoiceServer()
    server.active_session_id = "sess-123"

    sent_messages = []

    class MockWebSocket:
        async def send(self, data):
            sent_messages.append(json.loads(data))

    server.clients = {MockWebSocket()}

    await server.handle_user_message("hello from terminal")

    assert len(sent_messages) == 1
    msg = sent_messages[0]
    assert msg["type"] == "user_message"
    assert msg["role"] == "user"
    assert msg["content"] == "hello from terminal"
    assert msg["session_id"] == "sess-123"
    assert "timestamp" in msg
```

Check existing imports at the top of `test_message_handlers.py` — add `json` and `pytest` if missing.

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py::test_handle_user_message_sends_to_clients -v`
Expected: FAIL — `handle_user_message` does not exist.

**Step 3: Implement handle_user_message and wire callback**

In `voice_server/ios_server.py`, add method to `VoiceServer` class (after `handle_content_response`):

```python
async def handle_user_message(self, text: str):
    """Send user text message to iOS clients (for terminal-typed input)"""
    message = {
        "type": "user_message",
        "role": "user",
        "content": text,
        "timestamp": time.time(),
        "session_id": self.active_session_id,
    }

    for websocket in list(self.clients):
        try:
            await websocket.send(json.dumps(message))
        except Exception as e:
            print(f"Error sending user message: {e}")
```

Then update `start()` method where `TranscriptHandler` is created — find where it's instantiated and add the `user_callback` parameter. Search for `TranscriptHandler(` in the file to find the exact location.

```python
self.transcript_handler = TranscriptHandler(
    self.handle_content_response,
    self.handle_claude_response,
    self.loop,
    self,
    user_callback=self.handle_user_message,
)
```

**Step 4: Run tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All PASS.

**Step 5: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: send user_message over WebSocket to iOS clients"
```

---

### Task 3: Server — handle images in session history loading

Update `get_session_history` to skip image blocks and rewrite `[Image: source: ...]` text.

**Files:**
- Modify: `voice_server/session_manager.py:284-380`
- Test: `voice_server/tests/test_session_manager.py`

**Step 1: Write failing test**

Add to `voice_server/tests/test_session_manager.py` inside `TestSessionManager`:

```python
def test_get_session_history_rewrites_image_source(self, tmp_path):
    """[Image: source: /path/file.png] should become [Image: file.png]"""
    from session_manager import SessionManager

    project_dir = tmp_path / "-Users-test-proj"
    project_dir.mkdir()
    session_file = project_dir / "sess1.jsonl"
    session_file.write_text(
        json.dumps({
            "type": "user",
            "timestamp": "2026-01-01T00:00:00Z",
            "message": {"role": "user", "content": [
                {"type": "text", "text": "[Image: source: /Users/aaron/Downloads/IMG_5594.PNG]"}
            ]}
        }) + "\n"
    )

    manager = SessionManager(projects_dir=str(tmp_path))
    messages = manager.get_session_history("-Users-test-proj", "sess1")
    assert len(messages) == 1
    assert messages[0].content == "[Image: IMG_5594.PNG]"

def test_get_session_history_skips_image_blocks(self, tmp_path):
    """Image blocks with base64 data should be skipped entirely"""
    from session_manager import SessionManager

    project_dir = tmp_path / "-Users-test-proj"
    project_dir.mkdir()
    session_file = project_dir / "sess1.jsonl"
    session_file.write_text(
        json.dumps({
            "type": "user",
            "timestamp": "2026-01-01T00:00:00Z",
            "message": {"role": "user", "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "abc"}}
            ]}
        }) + "\n"
    )

    manager = SessionManager(projects_dir=str(tmp_path))
    messages = manager.get_session_history("-Users-test-proj", "sess1")
    assert len(messages) == 0
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_session_manager.py::TestSessionManager::test_get_session_history_rewrites_image_source -v`
Expected: FAIL — content will be the raw `[Image: source: ...]` string.

**Step 3: Implement**

In `voice_server/session_manager.py`:

1. Import the `rewrite_image_source` helper at the top:

```python
from voice_server.ios_server import rewrite_image_source
```

Actually — to avoid a circular import, extract `rewrite_image_source` and `IMAGE_SOURCE_RE` into a small utility. Better: just duplicate the regex inline since it's 3 lines. Add at the top of `session_manager.py`:

```python
import re

IMAGE_SOURCE_RE = re.compile(r'^\[Image: source: (.+)\]$')

def rewrite_image_source(text: str) -> str:
    """Rewrite [Image: source: /path/to/file.png] to [Image: file.png]"""
    m = IMAGE_SOURCE_RE.match(text.strip())
    if m:
        return f"[Image: {os.path.basename(m.group(1))}]"
    return text
```

2. In `get_session_history`, in the block handling `isinstance(content, list)` for non-tool_result messages (around line 335-360):

After filtering hidden tools (line 329-333), before building text_parts, add a filter to skip image blocks:

```python
# Skip image blocks (base64 data too large, not useful for display)
content = [
    b for b in content
    if not (isinstance(b, dict) and b.get('type') == 'image')
]
```

Then in the text_parts loop (line 337-339), apply `rewrite_image_source`:

```python
for block in content:
    if isinstance(block, dict) and block.get('type') == 'text':
        text_parts.append(rewrite_image_source(block.get('text', '').strip()))
```

Also apply to simple string content (line 362-379) — wrap the content:

```python
else:
    # Simple string content
    if not content or not content.strip():
        continue

    if role == 'user':
        stripped = content.strip()
        if stripped.startswith('Base directory for this skill:'):
            continue
        if stripped.startswith('<task-notification'):
            continue

    messages.append(SessionMessage(
        role=role,
        content=rewrite_image_source(content),
        timestamp=timestamp,
        content_blocks=None
    ))
```

**Step 4: Run tests**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All PASS.

**Step 5: Commit**

```bash
git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "feat: handle image blocks in session history loading"
```

---

### Task 4: iOS — handle user_message WebSocket type

Add `onUserMessage` callback and decode `user_message` in WebSocketManager.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift:34-47` (add callback)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift:370-466` (handleMessage)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift:310` (subscribe)

**Step 1: Add UserMessage model**

Add to `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift`:

```swift
struct UserMessage: Codable {
    let type: String
    let role: String
    let content: String
    let timestamp: Double
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case type, role, content, timestamp
        case sessionId = "session_id"
    }
}
```

**Step 2: Add callback and decode in WebSocketManager**

In `WebSocketManager.swift`, add callback after `onContextUpdate` (around line 46):

```swift
var onUserMessage: ((UserMessage) -> Void)?
```

In `handleMessage`, add a decode branch. Insert **before** the final `else` block (around line 462). Since `user_message` has a `type` field that won't match `AssistantResponseMessage` (which requires `type: "assistant_response"`), it won't conflict:

```swift
} else if let userMessage = try? JSONDecoder().decode(UserMessage.self, from: data),
          userMessage.type == "user_message" {
    logToFile("✅ Decoded as UserMessage: \(userMessage.content.prefix(50))")
    DispatchQueue.main.async {
        self.onUserMessage?(userMessage)
    }
}
```

**Step 3: Subscribe in SessionView**

In `SessionView.swift`, inside `setupView()`, after the `onAssistantResponse` subscription block (after line ~350), add:

```swift
// Subscribe to real-time user messages (terminal-typed input)
webSocketManager.onUserMessage = { [self] message in
    // Filter: only accept messages for the current session
    if session.isNewSession {
        if message.sessionId != nil { return }
    } else {
        if message.sessionId != session.id { return }
    }

    guard !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

    let userMsg = SessionHistoryMessage(
        role: "user",
        content: message.content,
        timestamp: message.timestamp
    )
    DispatchQueue.main.async {
        items.append(.textMessage(userMsg))
    }
}
```

**Step 4: Build for simulator to verify compilation**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: handle user_message WebSocket type in iOS app"
```

---

### Task 5: iOS — graceful unknown ContentBlock handling

Prevent crashes when unknown block types appear in session history.

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/AssistantContent.swift:90-135`

**Step 1: Add unknown case to ContentBlock enum**

In `AssistantContent.swift`, change the `ContentBlock` enum:

```swift
enum ContentBlock: Codable {
    case text(TextBlock)
    case thinking(ThinkingBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)
    case unknown
```

Update `init(from:)` — change the `default` case from throwing to:

```swift
default:
    self = .unknown
```

Update `encode(to:)` — add:

```swift
case .unknown:
    break
```

**Step 2: Filter out unknown blocks where ContentBlocks are consumed**

In `SessionView.swift`, the `onAssistantResponse` handler (line 318) already has a `switch` on blocks with explicit cases — add `case .unknown: break` there.

In the `onSessionHistoryReceived` handler (line 220), the block processing loop checks `block.type == "text"` and `block.type == "tool_use"` — unknown types will just be skipped by the existing `if` conditions, so no change needed there.

**Step 3: Build for simulator**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/AssistantContent.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "fix: graceful handling of unknown ContentBlock types"
```

---

### Task 6: Verify end-to-end

**Step 1: Reinstall server**

Run: `pipx install --force /Users/aaron/Desktop/max`

**Step 2: Manual verification**

1. Start server with `claude-connect`
2. Connect iOS app
3. Open a session, type a message in the Claude Code terminal → verify it appears as a user bubble on iOS
4. Paste an image in Claude Code → verify `[Image: filename.png]` appears on iOS
5. Interrupt a request (Ctrl+C / Escape) → verify `[Request interrupted by user]` appears on iOS
6. Browse session history for a session that had images → verify no crash, `[Image: filename]` shows

**CHECKPOINT:** All 4 scenarios must work before merging.
