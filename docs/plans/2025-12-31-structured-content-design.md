# Structured Content Design

**Date:** 2025-12-31
**Status:** Approved
**Purpose:** Add Pydantic models for assistant response content and send structured data to iOS app

## Overview

Currently, the iOS voice server extracts only text from assistant responses (lines 108-115 in `ios_server.py`), discarding other content blocks like thinking and tool_use. This design adds structured content models on both server (Python/Pydantic) and client (Swift/Codable) to capture all content block types and send them to the iOS app for future UI display.

## Requirements

- Parse all content block types from assistant responses (text, thinking, tool_use)
- Create Pydantic models for Python server
- Create equivalent Swift Codable models for iOS client
- Send structured content to iOS app immediately upon extraction (before TTS)
- Store content on iOS for future UI display (Option C: metadata tracking)
- Maintain current TTS behavior (only speak text blocks)

## Content Block Types

From analyzing transcript files, we identified three content block types:

### 1. Text Block
```json
{
  "type": "text",
  "text": "The actual message content"
}
```

### 2. Thinking Block
```json
{
  "type": "thinking",
  "thinking": "Internal reasoning process",
  "signature": "cryptographic_signature_string"
}
```

### 3. Tool Use Block
```json
{
  "type": "tool_use",
  "id": "toolu_01abc123",
  "name": "ToolName",
  "input": {
    "param1": "value1",
    "param2": "value2"
  }
}
```

## Architecture

### Data Models

#### Python (Pydantic)

Create `voice_server/content_models.py`:

```python
from pydantic import BaseModel
from typing import Any, Dict, Literal, Union

class TextBlock(BaseModel):
    type: Literal["text"]
    text: str

class ThinkingBlock(BaseModel):
    type: Literal["thinking"]
    thinking: str
    signature: str

class ToolUseBlock(BaseModel):
    type: Literal["tool_use"]
    id: str
    name: str
    input: Dict[str, Any]

# Discriminated union type
ContentBlock = Union[TextBlock, ThinkingBlock, ToolUseBlock]

class AssistantResponse(BaseModel):
    type: Literal["assistant_response"] = "assistant_response"
    content_blocks: list[ContentBlock]
    timestamp: float
```

**Key Design Decision:** Using Pydantic's discriminated union with the `type` field ensures type-safe parsing and maps cleanly to Swift enums.

#### Swift (Codable)

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/AssistantContent.swift`:

```swift
enum ContentBlock: Codable {
    case text(TextBlock)
    case thinking(ThinkingBlock)
    case toolUse(ToolUseBlock)

    // Custom encoding/decoding for discriminated union
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

    // Note: AnyCodable handles arbitrary JSON
}

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

### Server Integration

#### Refactor `TranscriptHandler`

**Current:** Lines 64-123 extract text and return a string
**New:** Parse content into structured models, send both structured data and text for TTS

```python
class TranscriptHandler(FileSystemEventHandler):
    def __init__(self, content_callback, audio_callback, loop, server):
        self.content_callback = content_callback  # New: sends AssistantResponse
        self.audio_callback = audio_callback       # Existing: sends text for TTS
        self.loop = loop
        self.server = server
        # ...

    def on_modified(self, event):
        # ... (existing logic)

        # Extract structured response
        response = self.extract_assistant_response_to_user_message(
            event.src_path,
            self.server.last_voice_input
        )

        if response:
            # 1. Send structured content immediately (Option A)
            asyncio.run_coroutine_threadsafe(
                self.content_callback(response),
                self.loop
            )

            # 2. Extract text for TTS
            text = self.extract_text_for_tts(response.content_blocks)

            # 3. Send for audio generation
            asyncio.run_coroutine_threadsafe(
                self.audio_callback(text),
                self.loop
            )
```

#### New Method: `extract_text_for_tts`

```python
def extract_text_for_tts(self, content_blocks: list[ContentBlock]) -> str:
    """Extract only text blocks for TTS (maintains current behavior)"""
    text_parts = []
    for block in content_blocks:
        if isinstance(block, TextBlock):
            text_parts.append(block.text)
    return ' '.join(text_parts).strip()
```

#### Modified Method: `extract_assistant_response_to_user_message`

```python
def extract_assistant_response_to_user_message(
    self,
    filepath: str,
    user_message: str
) -> Optional[AssistantResponse]:
    """Extract structured assistant response"""
    found_user_message = False

    with open(filepath, 'r') as f:
        for line in f:
            try:
                entry = json.loads(line.strip())
                msg = entry.get('message', {})
                role = msg.get('role') or entry.get('role')

                # ... (existing user message matching logic)

                if found_user_message and role == 'assistant':
                    content = msg.get('content', entry.get('content', ''))

                    if isinstance(content, str):
                        # String content - create single text block
                        return AssistantResponse(
                            content_blocks=[TextBlock(type="text", text=content)],
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
                                        print(f"Unknown block type: {block_type}")
                                except Exception as e:
                                    # Validation error - log and skip block
                                    print(f"Error parsing block: {e}")
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

#### New Handler: `handle_content_response`

```python
async def handle_content_response(self, response: AssistantResponse):
    """Send structured content to iOS clients"""
    print(f"Sending structured content: {len(response.content_blocks)} blocks")

    # Serialize using Pydantic
    message = response.model_dump()

    for websocket in list(self.clients):
        try:
            await websocket.send(json.dumps(message))
        except Exception as e:
            print(f"Error sending content: {e}")
```

#### Update `VoiceServer.__init__`

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

#### Update `VoiceServer.start`

```python
async def start(self):
    self.loop = asyncio.get_running_loop()
    self.transcript_path = self.find_transcript_path()

    if self.transcript_path:
        handler = TranscriptHandler(
            self.handle_content_response,  # New callback
            self.handle_claude_response,   # Existing callback (renamed for clarity)
            self.loop,
            self
        )
        # ... (rest of existing logic)
```

### iOS Integration

#### Update `WebSocketManager.swift`

Add new callback and storage:

```swift
class WebSocketManager: NSObject, ObservableObject {
    // ... existing properties ...

    var onAssistantResponse: ((AssistantResponseMessage) -> Void)?
    private var lastContentBlocks: [ContentBlock] = []  // Store for future UI

    // ... existing methods ...

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8) else { return }

            // Try to decode as AssistantResponseMessage first
            if let assistantResponse = try? JSONDecoder().decode(
                AssistantResponseMessage.self,
                from: data
            ) {
                handleAssistantResponse(assistantResponse)
            } else if let statusMessage = try? JSONDecoder().decode(
                StatusMessage.self,
                from: data
            ) {
                handleStatusMessage(statusMessage)
            } else if let audioChunk = try? JSONDecoder().decode(
                AudioChunkMessage.self,
                from: data
            ) {
                handleAudioChunk(audioChunk)
            } else {
                print("Failed to decode message")
            }

        // ... existing binary case ...
        }
    }

    private func handleAssistantResponse(_ message: AssistantResponseMessage) {
        print("Received assistant response: \(message.contentBlocks.count) blocks")

        // Store content blocks
        lastContentBlocks = message.contentBlocks

        // Notify callback (for future UI)
        onAssistantResponse?(message)
    }
}
```

## Message Flow

### Current Flow
1. User speaks → iOS sends voice input
2. Server sends to VS Code
3. Claude responds → written to transcript
4. Server detects transcript change
5. Server extracts text → generates TTS
6. Server sends status "speaking" + audio chunks
7. iOS plays audio

### New Flow
1. User speaks → iOS sends voice input
2. Server sends to VS Code
3. Claude responds → written to transcript
4. Server detects transcript change
5. **NEW: Server extracts structured content → sends `assistant_response` message**
6. **NEW: iOS receives and stores content blocks**
7. Server extracts text → generates TTS
8. Server sends status "speaking" + audio chunks
9. iOS plays audio

**Key Insight:** Content arrives before audio (Option A), making it available for future UI rendering while TTS generation happens.

## Error Handling

### Parsing Errors
- If Pydantic validation fails on a content block, log error and skip that block
- Send whatever valid blocks could be parsed
- Send empty `content_blocks` array if nothing parses (iOS handles gracefully)

### Unknown Content Types
- Future content block types will fail validation
- Log unknown types for monitoring
- Consider adding `GenericBlock` fallback in future if needed

### Backward Compatibility
- iOS app handles missing `assistant_response` messages (older server versions)
- Server handles clients that don't consume new message type
- Audio streaming continues to work independently

## Testing Strategy

### Unit Tests

**Python:**
- Test Pydantic model validation with real transcript examples
- Test each content block type parsing
- Test malformed data handling
- Test empty content arrays

**Swift:**
- Test Codable decoding with sample JSON
- Test enum discriminated union decoding
- Test missing fields, unknown types
- Test AnyCodable for tool input parsing

### Integration Tests
- Full flow: transcript modification → iOS receives structured data
- Verify content arrives before audio
- Verify audio still works with structured content
- Test with responses containing different block type combinations

### Edge Cases
- Empty content array
- Malformed blocks
- Missing required fields
- Unknown content block types
- Very large tool input objects

## Future Enhancements

This design enables future UI features without requiring server changes:

1. **Rich content display** - Show thinking blocks in gray, tool uses in code blocks
2. **Expandable blocks** - Tap to see tool use details
3. **Conversation history** - Store and display full structured responses
4. **Search** - Search across all content types, not just text
5. **Export** - Export conversation with full structure preserved

## Summary

This design adds type-safe structured content models to both server and client while maintaining current TTS behavior. Content is sent immediately upon extraction (before TTS), enabling future UI enhancements without server modifications. The discriminated union approach ensures type safety and maps cleanly between Python and Swift.
