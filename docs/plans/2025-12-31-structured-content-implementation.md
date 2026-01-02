# Structured Content Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Add Pydantic models for assistant response content and send structured data to iOS app

**Architecture:** Create type-safe content models (text, thinking, tool_use blocks) using Pydantic on server and Codable on iOS. Refactor server to parse and send structured content immediately (before TTS), while maintaining current audio streaming behavior. iOS stores content for future UI display.

**Tech Stack:** Python 3.9, Pydantic 2.12, Swift, iOS Codable, WebSockets

---

## Task 1: Create Pydantic Content Models

**Files:**
- Create: `voice_server/content_models.py`
- Create: `voice_server/tests/test_content_models.py`

**Step 1: Write failing tests for TextBlock model**

Create `voice_server/tests/test_content_models.py`:

```python
import pytest
from content_models import TextBlock, ThinkingBlock, ToolUseBlock, AssistantResponse


def test_text_block_valid():
    """Test TextBlock accepts valid data"""
    block = TextBlock(type="text", text="Hello world")
    assert block.type == "text"
    assert block.text == "Hello world"


def test_text_block_serialization():
    """Test TextBlock serializes to dict correctly"""
    block = TextBlock(type="text", text="Hello")
    data = block.model_dump()
    assert data == {"type": "text", "text": "Hello"}


def test_text_block_from_dict():
    """Test TextBlock parses from dict"""
    data = {"type": "text", "text": "Hello"}
    block = TextBlock(**data)
    assert block.text == "Hello"
```

**Step 2: Run tests to verify they fail**

```bash
cd /Users/aaron/Desktop/max/voice_server
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_text_block_valid -v
```

Expected: `ModuleNotFoundError: No module named 'content_models'`

**Step 3: Create minimal TextBlock implementation**

Create `voice_server/content_models.py`:

```python
from pydantic import BaseModel
from typing import Literal


class TextBlock(BaseModel):
    type: Literal["text"]
    text: str
```

**Step 4: Run tests to verify TextBlock passes**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_text_block_valid -v
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_text_block_serialization -v
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_text_block_from_dict -v
```

Expected: All 3 tests PASS

**Step 5: Write failing tests for ThinkingBlock**

Add to `voice_server/tests/test_content_models.py`:

```python
def test_thinking_block_valid():
    """Test ThinkingBlock accepts valid data"""
    block = ThinkingBlock(
        type="thinking",
        thinking="Internal reasoning",
        signature="abc123"
    )
    assert block.type == "thinking"
    assert block.thinking == "Internal reasoning"
    assert block.signature == "abc123"


def test_thinking_block_requires_signature():
    """Test ThinkingBlock requires signature field"""
    with pytest.raises(Exception):  # Pydantic ValidationError
        ThinkingBlock(type="thinking", thinking="Test")
```

**Step 6: Run tests to verify they fail**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_thinking_block_valid -v
```

Expected: `NameError: name 'ThinkingBlock' is not defined`

**Step 7: Implement ThinkingBlock**

Add to `voice_server/content_models.py`:

```python
class ThinkingBlock(BaseModel):
    type: Literal["thinking"]
    thinking: str
    signature: str
```

**Step 8: Run tests to verify ThinkingBlock passes**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_thinking_block_valid -v
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_thinking_block_requires_signature -v
```

Expected: Both tests PASS

**Step 9: Write failing tests for ToolUseBlock**

Add to `voice_server/tests/test_content_models.py`:

```python
def test_tool_use_block_valid():
    """Test ToolUseBlock accepts valid data"""
    block = ToolUseBlock(
        type="tool_use",
        id="toolu_123",
        name="TestTool",
        input={"param": "value"}
    )
    assert block.type == "tool_use"
    assert block.id == "toolu_123"
    assert block.name == "TestTool"
    assert block.input == {"param": "value"}


def test_tool_use_block_nested_input():
    """Test ToolUseBlock handles nested input objects"""
    block = ToolUseBlock(
        type="tool_use",
        id="toolu_123",
        name="TestTool",
        input={"nested": {"key": "value"}, "list": [1, 2, 3]}
    )
    assert block.input["nested"]["key"] == "value"
    assert block.input["list"] == [1, 2, 3]
```

**Step 10: Run tests to verify they fail**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_tool_use_block_valid -v
```

Expected: `NameError: name 'ToolUseBlock' is not defined`

**Step 11: Implement ToolUseBlock**

Add to `voice_server/content_models.py`:

```python
from typing import Any, Dict


class ToolUseBlock(BaseModel):
    type: Literal["tool_use"]
    id: str
    name: str
    input: Dict[str, Any]
```

**Step 12: Run tests to verify ToolUseBlock passes**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_tool_use_block_valid -v
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_tool_use_block_nested_input -v
```

Expected: Both tests PASS

**Step 13: Write failing tests for AssistantResponse**

Add to `voice_server/tests/test_content_models.py`:

```python
import time


def test_assistant_response_with_text_blocks():
    """Test AssistantResponse with text blocks"""
    blocks = [
        TextBlock(type="text", text="First"),
        TextBlock(type="text", text="Second")
    ]
    response = AssistantResponse(content_blocks=blocks, timestamp=time.time())
    assert response.type == "assistant_response"
    assert len(response.content_blocks) == 2


def test_assistant_response_with_mixed_blocks():
    """Test AssistantResponse with different block types"""
    blocks = [
        TextBlock(type="text", text="Hello"),
        ThinkingBlock(type="thinking", thinking="Hmm", signature="sig"),
        ToolUseBlock(type="tool_use", id="t1", name="Tool", input={})
    ]
    response = AssistantResponse(content_blocks=blocks, timestamp=time.time())
    assert len(response.content_blocks) == 3


def test_assistant_response_serialization():
    """Test AssistantResponse serializes correctly"""
    blocks = [TextBlock(type="text", text="Test")]
    response = AssistantResponse(content_blocks=blocks, timestamp=123.456)
    data = response.model_dump()
    assert data["type"] == "assistant_response"
    assert data["timestamp"] == 123.456
    assert len(data["content_blocks"]) == 1
    assert data["content_blocks"][0]["type"] == "text"
```

**Step 14: Run tests to verify they fail**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py::test_assistant_response_with_text_blocks -v
```

Expected: `NameError: name 'AssistantResponse' is not defined`

**Step 15: Implement AssistantResponse**

Add to `voice_server/content_models.py`:

```python
from typing import Union


ContentBlock = Union[TextBlock, ThinkingBlock, ToolUseBlock]


class AssistantResponse(BaseModel):
    type: Literal["assistant_response"] = "assistant_response"
    content_blocks: list[ContentBlock]
    timestamp: float
```

**Step 16: Run all content_models tests**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_models.py -v
```

Expected: All tests PASS

**Step 17: Commit**

```bash
cd /Users/aaron/Desktop/max
git add voice_server/content_models.py voice_server/tests/test_content_models.py
git commit -m "feat: add Pydantic models for content blocks (text, thinking, tool_use)"
```

---

## Task 2: Add Text Extraction Helper

**Files:**
- Modify: `voice_server/ios_server.py`
- Create: `voice_server/tests/test_text_extraction.py`

**Step 1: Write failing test for extract_text_for_tts**

Create `voice_server/tests/test_text_extraction.py`:

```python
import sys
import os
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from content_models import TextBlock, ThinkingBlock, ToolUseBlock
from ios_server import extract_text_for_tts


def test_extract_text_from_text_blocks():
    """Test extracting text from only text blocks"""
    blocks = [
        TextBlock(type="text", text="First"),
        TextBlock(type="text", text="Second")
    ]
    result = extract_text_for_tts(blocks)
    assert result == "First Second"


def test_extract_text_ignores_thinking():
    """Test that thinking blocks are ignored"""
    blocks = [
        TextBlock(type="text", text="Hello"),
        ThinkingBlock(type="thinking", thinking="Internal", signature="sig"),
        TextBlock(type="text", text="World")
    ]
    result = extract_text_for_tts(blocks)
    assert result == "Hello World"


def test_extract_text_ignores_tool_use():
    """Test that tool_use blocks are ignored"""
    blocks = [
        TextBlock(type="text", text="Answer"),
        ToolUseBlock(type="tool_use", id="t1", name="Tool", input={}),
        TextBlock(type="text", text="Done")
    ]
    result = extract_text_for_tts(blocks)
    assert result == "Answer Done"


def test_extract_text_empty_list():
    """Test extracting from empty list returns empty string"""
    result = extract_text_for_tts([])
    assert result == ""


def test_extract_text_no_text_blocks():
    """Test extracting when no text blocks present"""
    blocks = [
        ThinkingBlock(type="thinking", thinking="Think", signature="sig"),
        ToolUseBlock(type="tool_use", id="t1", name="Tool", input={})
    ]
    result = extract_text_for_tts(blocks)
    assert result == ""
```

**Step 2: Run tests to verify they fail**

```bash
cd /Users/aaron/Desktop/max/voice_server
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_text_extraction.py -v
```

Expected: `ImportError: cannot import name 'extract_text_for_tts'`

**Step 3: Implement extract_text_for_tts function**

Add to `voice_server/ios_server.py` (after imports, before classes):

```python
from content_models import TextBlock, ThinkingBlock, ToolUseBlock, ContentBlock


def extract_text_for_tts(content_blocks: list[ContentBlock]) -> str:
    """Extract only text blocks for TTS (maintains current behavior)"""
    text_parts = []
    for block in content_blocks:
        if isinstance(block, TextBlock):
            text_parts.append(block.text)
    return ' '.join(text_parts).strip()
```

**Step 4: Run tests to verify they pass**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_text_extraction.py -v
```

Expected: All 5 tests PASS

**Step 5: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_text_extraction.py
git commit -m "feat: add extract_text_for_tts helper function"
```

---

## Task 3: Refactor Assistant Response Extraction

**Files:**
- Modify: `voice_server/ios_server.py:64-123`
- Create: `voice_server/tests/test_response_extraction.py`

**Step 1: Write failing tests for new extraction logic**

Create `voice_server/tests/test_response_extraction.py`:

```python
import sys
import os
import json
import tempfile
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from ios_server import TranscriptHandler
from content_models import AssistantResponse, TextBlock, ThinkingBlock, ToolUseBlock


def test_extract_string_content():
    """Test extracting simple string content"""
    # Create temp transcript file
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # User message
        f.write(json.dumps({
            "message": {"role": "user", "content": "test input"}
        }) + "\n")
        # Assistant response with string content
        f.write(json.dumps({
            "message": {"role": "assistant", "content": "test response"}
        }) + "\n")
        temp_path = f.name

    try:
        handler = TranscriptHandler(None, None, None, type('obj', (), {'last_voice_input': 'test input'})())
        response = handler.extract_assistant_response_to_user_message(temp_path, "test input")

        assert response is not None
        assert isinstance(response, AssistantResponse)
        assert len(response.content_blocks) == 1
        assert isinstance(response.content_blocks[0], TextBlock)
        assert response.content_blocks[0].text == "test response"
    finally:
        os.unlink(temp_path)


def test_extract_text_block_content():
    """Test extracting content with text blocks"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "message": {"role": "user", "content": "test input"}
        }) + "\n")
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "Hello"},
                    {"type": "text", "text": "World"}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        handler = TranscriptHandler(None, None, None, type('obj', (), {'last_voice_input': 'test input'})())
        response = handler.extract_assistant_response_to_user_message(temp_path, "test input")

        assert response is not None
        assert len(response.content_blocks) == 2
        assert response.content_blocks[0].text == "Hello"
        assert response.content_blocks[1].text == "World"
    finally:
        os.unlink(temp_path)


def test_extract_mixed_content_blocks():
    """Test extracting content with text, thinking, and tool_use blocks"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "message": {"role": "user", "content": "test input"}
        }) + "\n")
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "thinking", "thinking": "Let me think", "signature": "sig123"},
                    {"type": "text", "text": "Answer"},
                    {"type": "tool_use", "id": "t1", "name": "Tool", "input": {"key": "value"}}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        handler = TranscriptHandler(None, None, None, type('obj', (), {'last_voice_input': 'test input'})())
        response = handler.extract_assistant_response_to_user_message(temp_path, "test input")

        assert response is not None
        assert len(response.content_blocks) == 3
        assert isinstance(response.content_blocks[0], ThinkingBlock)
        assert isinstance(response.content_blocks[1], TextBlock)
        assert isinstance(response.content_blocks[2], ToolUseBlock)
    finally:
        os.unlink(temp_path)


def test_extract_ignores_unknown_block_type():
    """Test that unknown block types are skipped"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "message": {"role": "user", "content": "test input"}
        }) + "\n")
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "text", "text": "Valid"},
                    {"type": "unknown_future_type", "data": "something"},
                    {"type": "text", "text": "Also valid"}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        handler = TranscriptHandler(None, None, None, type('obj', (), {'last_voice_input': 'test input'})())
        response = handler.extract_assistant_response_to_user_message(temp_path, "test input")

        assert response is not None
        assert len(response.content_blocks) == 2  # Unknown block skipped
        assert response.content_blocks[0].text == "Valid"
        assert response.content_blocks[1].text == "Also valid"
    finally:
        os.unlink(temp_path)
```

**Step 2: Run tests to verify they fail**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_response_extraction.py::test_extract_string_content -v
```

Expected: Test fails because extract_assistant_response_to_user_message still returns string, not AssistantResponse

**Step 3: Refactor extract_assistant_response_to_user_message**

Replace the method in `voice_server/ios_server.py` (lines 64-123):

```python
from typing import Optional
from content_models import AssistantResponse, TextBlock, ThinkingBlock, ToolUseBlock

# ... (in TranscriptHandler class)

def extract_assistant_response_to_user_message(self, filepath, user_message) -> Optional[AssistantResponse]:
    """Extract the first assistant message that comes after the specified user message"""
    found_user_message = False
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
                        continue
                    else:
                        print(f"[DEBUG] User message doesn't match: '{user_text[:50]}...'")

                # If we found the user message, return the next assistant message
                if found_user_message and role == 'assistant':
                    print(f"[DEBUG] Found assistant response after user message!")
                    content = msg.get('content', entry.get('content', ''))

                    if isinstance(content, str):
                        # String content - create single text block
                        result = content.strip()
                        if result:
                            return AssistantResponse(
                                content_blocks=[TextBlock(type="text", text=result)],
                                timestamp=time.time()
                            )
                    elif isinstance(content, list):
                        # Parse structured content blocks
                        parsed_blocks = []
                        for block in content:
                            if isinstance(block, dict):
                                block_type = block.get('type')
                                try:
                                    if block_type == 'text':
                                        parsed_blocks.append(TextBlock(**block))
                                    elif block_type == 'thinking':
                                        parsed_blocks.append(ThinkingBlock(**block))
                                    elif block_type == 'tool_use':
                                        parsed_blocks.append(ToolUseBlock(**block))
                                    else:
                                        # Unknown type - log and skip
                                        print(f"[DEBUG] Unknown block type: {block_type}")
                                except Exception as e:
                                    # Validation error - log and skip block
                                    print(f"[DEBUG] Error parsing block: {e}")
                                    continue

                        if parsed_blocks:
                            return AssistantResponse(
                                content_blocks=parsed_blocks,
                                timestamp=time.time()
                            )

            except:
                continue

    return None
```

**Step 4: Run tests to verify they pass**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_response_extraction.py -v
```

Expected: All 4 tests PASS

**Step 5: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_response_extraction.py
git commit -m "refactor: extract_assistant_response returns AssistantResponse model"
```

---

## Task 4: Add Content Response Handler

**Files:**
- Modify: `voice_server/ios_server.py`
- Create: `voice_server/tests/test_content_handler.py`

**Step 1: Write failing test for handle_content_response**

Create `voice_server/tests/test_content_handler.py`:

```python
import sys
import os
import json
import asyncio
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))

from ios_server import VoiceServer
from content_models import AssistantResponse, TextBlock
import pytest


@pytest.mark.asyncio
async def test_handle_content_response_sends_message():
    """Test that handle_content_response sends JSON message to clients"""
    server = VoiceServer()

    # Mock websocket
    sent_messages = []

    class MockWebSocket:
        async def send(self, message):
            sent_messages.append(message)

    mock_ws = MockWebSocket()
    server.clients.add(mock_ws)

    # Create test response
    response = AssistantResponse(
        content_blocks=[TextBlock(type="text", text="Test")],
        timestamp=123.456
    )

    # Call handler
    await server.handle_content_response(response)

    # Verify message was sent
    assert len(sent_messages) == 1
    data = json.loads(sent_messages[0])
    assert data["type"] == "assistant_response"
    assert data["timestamp"] == 123.456
    assert len(data["content_blocks"]) == 1


@pytest.mark.asyncio
async def test_handle_content_response_multiple_clients():
    """Test that content is sent to all connected clients"""
    server = VoiceServer()

    sent_messages = []

    class MockWebSocket:
        def __init__(self, id):
            self.id = id

        async def send(self, message):
            sent_messages.append((self.id, message))

    # Add multiple clients
    server.clients.add(MockWebSocket(1))
    server.clients.add(MockWebSocket(2))

    response = AssistantResponse(
        content_blocks=[TextBlock(type="text", text="Test")],
        timestamp=123.456
    )

    await server.handle_content_response(response)

    # Verify all clients received message
    assert len(sent_messages) == 2
```

**Step 2: Run tests to verify they fail**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_handler.py -v
```

Expected: `AttributeError: 'VoiceServer' object has no attribute 'handle_content_response'`

**Step 3: Implement handle_content_response method**

Add to `voice_server/ios_server.py` in the `VoiceServer` class:

```python
async def handle_content_response(self, response: AssistantResponse):
    """Send structured content to iOS clients"""
    print(f"[{time.strftime('%H:%M:%S')}] Sending structured content: {len(response.content_blocks)} blocks")

    # Serialize using Pydantic
    message = response.model_dump()

    for websocket in list(self.clients):
        try:
            await websocket.send(json.dumps(message))
            print(f"[{time.strftime('%H:%M:%S')}] Sent content to client")
        except Exception as e:
            print(f"Error sending content: {e}")
```

**Step 4: Run tests to verify they pass**

```bash
/Users/aaron/Desktop/max/.venv/bin/pytest tests/test_content_handler.py -v
```

Expected: Both tests PASS

**Step 5: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_content_handler.py
git commit -m "feat: add handle_content_response to send structured content to clients"
```

---

## Task 5: Wire Up TranscriptHandler with Dual Callbacks

**Files:**
- Modify: `voice_server/ios_server.py:29-123` (TranscriptHandler class)
- Modify: `voice_server/ios_server.py:126-136` (VoiceServer.__init__)
- Modify: `voice_server/ios_server.py:261-273` (VoiceServer.start)

**Step 1: Update TranscriptHandler.__init__ to accept two callbacks**

Modify `voice_server/ios_server.py` lines 32-37:

```python
class TranscriptHandler(FileSystemEventHandler):
    """Monitors transcript file for new assistant messages"""

    def __init__(self, content_callback, audio_callback, loop, server):
        self.content_callback = content_callback  # New: sends AssistantResponse
        self.audio_callback = audio_callback       # Existing: sends text for TTS
        self.loop = loop
        self.server = server
        self.last_message = None
        self.last_modified = 0
```

**Step 2: Update on_modified to call both callbacks**

Modify `voice_server/ios_server.py` lines 39-62:

```python
def on_modified(self, event):
    if event.is_directory or not event.src_path.endswith('.jsonl'):
        return

    current_time = time.time()
    if current_time - self.last_modified < 0.5:
        return
    self.last_modified = current_time

    try:
        # Extract the assistant response to the last voice input
        if self.server.last_voice_input:
            print(f"[DEBUG] File modified, extracting response...")
            response = self.extract_assistant_response_to_user_message(
                event.src_path,
                self.server.last_voice_input
            )
            print(f"[DEBUG] Extracted response: {response}")

            if response and response != self.last_message:
                self.last_message = response

                # 1. Send structured content immediately
                asyncio.run_coroutine_threadsafe(
                    self.content_callback(response),
                    self.loop
                )

                # 2. Extract text for TTS
                text = extract_text_for_tts(response.content_blocks)

                # 3. Send for audio generation
                if text:
                    asyncio.run_coroutine_threadsafe(
                        self.audio_callback(text),
                        self.loop
                    )
    except Exception as e:
        print(f"Error processing transcript: {e}")
        import traceback
        traceback.print_exc()
```

**Step 3: Update VoiceServer.__init__ to store content blocks**

Modify `voice_server/ios_server.py` lines 129-136:

```python
def __init__(self):
    self.clients = set()
    self.transcript_path = None
    self.observer = None
    self.loop = None
    self.waiting_for_response = False
    self.last_voice_input = None
    self.last_content_blocks = []  # New: store for future reference
```

**Step 4: Update VoiceServer.start to pass both callbacks**

Modify `voice_server/ios_server.py` lines 268-272:

```python
if self.transcript_path:
    handler = TranscriptHandler(
        self.handle_content_response,  # New: content callback
        self.handle_claude_response,   # Existing: audio callback
        self.loop,
        self
    )
    self.observer = Observer()
    self.observer.schedule(handler, os.path.dirname(self.transcript_path))
    self.observer.start()
```

**Step 5: Update handle_claude_response docstring for clarity**

Modify `voice_server/ios_server.py` line 217:

```python
async def handle_claude_response(self, text):
    """Handle Claude's response - generate and stream TTS audio"""
    print(f"[{time.strftime('%H:%M:%S')}] Generating TTS for: '{text[:100]}...'")
```

**Step 6: Manual integration test**

Start the server and verify it doesn't crash:

```bash
cd /Users/aaron/Desktop/max/voice_server
/Users/aaron/Desktop/max/.venv/bin/python ios_server.py
```

Expected: Server starts without errors, shows "Server running on ws://..."

Press Ctrl+C to stop.

**Step 7: Commit**

```bash
git add voice_server/ios_server.py
git commit -m "refactor: wire up dual callbacks for content and audio in TranscriptHandler"
```

---

## Task 6: Create Swift Content Models

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/AssistantContent.swift`

**Step 1: Create AnyCodable helper**

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/AssistantContent.swift`:

```swift
import Foundation

// MARK: - AnyCodable Helper

struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
```

**Step 2: Add Content Block structs**

Add to same file:

```swift
// MARK: - Content Block Structs

struct TextBlock: Codable {
    let type: String
    let text: String
}

struct ThinkingBlock: Codable {
    let type: String
    let thinking: String
    let signature: String
}

struct ToolUseBlock: Codable {
    let type: String
    let id: String
    let name: String
    let input: [String: AnyCodable]
}
```

**Step 3: Add ContentBlock enum with discriminated union**

Add to same file:

```swift
// MARK: - Content Block Enum

enum ContentBlock: Codable {
    case text(TextBlock)
    case thinking(ThinkingBlock)
    case toolUse(ToolUseBlock)

    enum CodingKeys: String, CodingKey {
        case type
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)

        switch type {
        case "text":
            self = .text(try TextBlock(from: decoder))
        case "thinking":
            self = .thinking(try ThinkingBlock(from: decoder))
        case "tool_use":
            self = .toolUse(try ToolUseBlock(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown content block type: \(type)"
                )
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .text(let block):
            try block.encode(to: encoder)
        case .thinking(let block):
            try block.encode(to: encoder)
        case .toolUse(let block):
            try block.encode(to: encoder)
        }
    }
}
```

**Step 4: Add AssistantResponseMessage struct**

Add to same file:

```swift
// MARK: - Assistant Response Message

struct AssistantResponseMessage: Codable {
    let type: String
    let contentBlocks: [ContentBlock]
    let timestamp: Double

    enum CodingKeys: String, CodingKey {
        case type
        case contentBlocks = "content_blocks"
        case timestamp
    }
}
```

**Step 5: Build the iOS project to verify no compile errors**

```bash
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice
xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
cd /Users/aaron/Desktop/max
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/AssistantContent.swift
git commit -m "feat: add Swift Codable models for assistant content blocks"
```

---

## Task 7: Update WebSocketManager to Handle Content Messages

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift:4-17` (add properties)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift:188-226` (handleMessage)

**Step 1: Add onAssistantResponse callback and storage**

Modify `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift` lines 4-17:

```swift
class WebSocketManager: NSObject, ObservableObject {
    @Published var connectionState: ConnectionState = .disconnected

    @Published var voiceState: VoiceState = .idle {
        didSet {
            logToFile("🔄 voiceState didSet: \(oldValue.description) -> \(voiceState.description)")
            print("🔄 voiceState didSet: \(oldValue.description) -> \(voiceState.description)")
        }
    }

    var onAudioChunk: ((AudioChunkMessage) -> Void)?
    var onStatusUpdate: ((StatusMessage) -> Void)?
    var onAssistantResponse: ((AssistantResponseMessage) -> Void)?  // NEW
    var isPlayingAudio: Bool = false
    private var lastContentBlocks: [ContentBlock] = []  // NEW: store for future UI
```

**Step 2: Add handleAssistantResponse method**

Add to `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift` after `handleAudioChunk` (around line 253):

```swift
private func handleAssistantResponse(_ message: AssistantResponseMessage) {
    print("📦 RECEIVED ASSISTANT RESPONSE: \(message.contentBlocks.count) blocks")
    logToFile("📦 ASSISTANT RESPONSE: \(message.contentBlocks.count) blocks")

    // Store content blocks
    lastContentBlocks = message.contentBlocks

    // Log block types for debugging
    for (index, block) in message.contentBlocks.enumerated() {
        switch block {
        case .text(let textBlock):
            print("  Block \(index): text - \(textBlock.text.prefix(50))...")
            logToFile("  Block \(index): text")
        case .thinking(let thinkingBlock):
            print("  Block \(index): thinking - \(thinkingBlock.thinking.prefix(50))...")
            logToFile("  Block \(index): thinking")
        case .toolUse(let toolBlock):
            print("  Block \(index): tool_use - \(toolBlock.name)")
            logToFile("  Block \(index): tool_use - \(toolBlock.name)")
        }
    }

    // Notify callback (for future UI)
    onAssistantResponse?(message)
}
```

**Step 3: Update handleMessage to decode AssistantResponseMessage**

Modify `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift` lines 188-210:

```swift
private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
    switch message {
    case .string(let text):
        print("📥 RECEIVED STRING MESSAGE: \(text.prefix(200))...")
        logToFile("📥 STRING: \(text.prefix(200))")
        guard let data = text.data(using: .utf8) else {
            print("❌ Failed to convert string to data")
            logToFile("❌ Failed to convert string to data")
            return
        }

        // Try to decode as AssistantResponseMessage FIRST (before status/audio)
        if let assistantResponse = try? JSONDecoder().decode(AssistantResponseMessage.self, from: data) {
            logToFile("✅ Decoded as AssistantResponseMessage")
            handleAssistantResponse(assistantResponse)
        } else if let statusMessage = try? JSONDecoder().decode(StatusMessage.self, from: data) {
            logToFile("✅ Decoded as StatusMessage: \(statusMessage.state)")
            handleStatusMessage(statusMessage)
        } else if let audioChunk = try? JSONDecoder().decode(AudioChunkMessage.self, from: data) {
            logToFile("✅ Decoded as AudioChunk: \(audioChunk.chunkIndex + 1)/\(audioChunk.totalChunks)")
            handleAudioChunk(audioChunk)
        } else {
            print("❌ Failed to decode message as any known type")
            print("   Raw data: \(String(data: data, encoding: .utf8) ?? "N/A")")
            logToFile("❌ Failed to decode: \(String(data: data, encoding: .utf8) ?? "N/A")")
        }

    case .data(let data):
        print("📥 RECEIVED BINARY MESSAGE: \(data.count) bytes")
        logToFile("📥 BINARY: \(data.count) bytes")
        // Try AssistantResponseMessage first for binary too
        if let assistantResponse = try? JSONDecoder().decode(AssistantResponseMessage.self, from: data) {
            handleAssistantResponse(assistantResponse)
        } else if let statusMessage = try? JSONDecoder().decode(StatusMessage.self, from: data) {
            handleStatusMessage(statusMessage)
        } else if let audioChunk = try? JSONDecoder().decode(AudioChunkMessage.self, from: data) {
            handleAudioChunk(audioChunk)
        } else {
            print("❌ Failed to decode binary message")
            logToFile("❌ Failed to decode binary message")
        }

    @unknown default:
        break
    }
}
```

**Step 4: Build iOS project to verify no errors**

```bash
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice
xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 15' build
```

Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: add WebSocketManager support for AssistantResponseMessage"
```

---

## Task 8: End-to-End Integration Test

**Files:**
- No new files, manual testing

**Step 1: Start the Python server**

```bash
cd /Users/aaron/Desktop/max/voice_server
/Users/aaron/Desktop/max/.venv/bin/python ios_server.py
```

Expected: Server starts and shows "Server running on ws://..."

**Step 2: Build and run iOS app in simulator**

```bash
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice
xcodebuild -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 15'
```

Or open in Xcode and run.

**Step 3: Connect iOS app to server**

In the iOS app, go to Settings and enter the server IP shown in the Python console.
Tap Connect.

Expected: Connection successful, status shows "Connected"

**Step 4: Test voice input flow**

1. Tap and hold the microphone button
2. Speak: "Hello, can you hear me?"
3. Release button

Expected in Python console:
```
Voice input received: 'Hello, can you hear me?'
Sending to VS Code...
File modified, extracting response...
Found assistant response after user message!
Sending structured content: X blocks
Sent content to client
Generating TTS for: '...'
Streaming audio to client...
```

Expected in iOS console/logs:
```
📦 RECEIVED ASSISTANT RESPONSE: X blocks
  Block 0: thinking
  Block 1: text - ...
🎵 RECEIVED AUDIO CHUNK: 1/N
```

**Step 5: Verify audio plays**

Expected: iOS app plays audio response from Claude

**Step 6: Check that content blocks are stored**

Add temporary debug print in iOS app's ContentView or set breakpoint in `handleAssistantResponse` to verify `lastContentBlocks` is populated.

**Step 7: Stop server**

Press Ctrl+C in the Python server terminal.

**Step 8: Final commit**

```bash
cd /Users/aaron/Desktop/max
git add -A
git commit -m "test: verify end-to-end flow with structured content"
```

---

## Summary

This implementation plan adds type-safe structured content models to both the Python server (Pydantic) and iOS client (Swift Codable). The server now:

1. Parses all content block types (text, thinking, tool_use) from Claude's responses
2. Sends structured content to iOS immediately upon extraction
3. Separately extracts text for TTS and streams audio (maintaining current behavior)

The iOS app:

1. Receives and decodes structured content messages
2. Stores content blocks for future UI display
3. Continues to play audio as before

**Key Benefits:**
- Type safety on both ends (Pydantic validation + Swift enums)
- Content available before audio (better UX for future features)
- Backward compatible (audio streaming unchanged)
- Extensible (easy to add new content block types)

**Next Steps:**
- Implement UI to display different content block types
- Add conversation history with full structured content
- Export conversations with structure preserved
