# Image Viewing & Tool Output Visibility

Two high-impact features for using Claude Code from iOS without touching the laptop.

## Feature 1: Image File Viewing in Files Tab

### Problem
FileView shows "Cannot view contents" for all binary files including images. The server tries UTF-8 read, gets UnicodeDecodeError, returns "binary_file" error.

### Design

**Server (`ios_server.py` → `handle_read_file`)**:
- Define `IMAGE_EXTENSIONS = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico', '.svg'}`
- Before UTF-8 read attempt, check extension
- If image and ≤ 10MB: base64-encode raw bytes, send as `image_data` field
- If image and > 10MB: send `error: "file_too_large"` with `file_size`
- SVG: treat as text (it's XML), no special handling

**Response shape for images**:
```json
{
  "type": "file_contents",
  "path": "/path/to/image.png",
  "image_data": "<base64>",
  "image_format": "png",
  "file_size": 245000
}
```

**iOS changes**:
- `FileContentsResponse`: add optional `imageData`, `imageFormat`, `fileSize` fields
- `FileView`: if `imageData` present → decode base64 → render with `Image(uiImage:)` + pinch-to-zoom
- Kingfisher `ImageCache.default` for caching by file path key (not URL-based)
- New error state for `file_too_large`: "File too large to preview (X MB)"

### Decisions
- Extension-based detection only (no magic bytes)
- 10MB file size limit
- Kingfisher for caching
- SVG rendered as text source

---

## Feature 2: Tool Output Visibility

### Problem
When Claude uses tools (Bash, Read, Edit, Grep, etc.), iOS shows the tool NAME via `OutputState.usingTool` but never shows what it did or what the result was. Thinking blocks are also discarded. Users are flying blind.

### Design

**New content block type** (`content_models.py`):
```python
class ToolResultBlock(BaseModel):
    type: Literal["tool_result"]
    tool_use_id: str
    content: str
    is_error: bool = False
```

**Server transcript extraction** (`ios_server.py`):
- Currently only processes `role == 'assistant'` messages
- Add: also process `role == 'user'` messages containing `tool_result` blocks
- Extract `ToolResultBlock` and include in `assistant_response` broadcasts
- Blocks sent in transcript order; iOS handles pairing

**Session history** (`session_manager.py`):
- Return structured content_blocks in history (not just flat text)
- Include tool_use and tool_result blocks so old sessions show full activity
- Response shape includes `content_blocks` array alongside flat `content`

**iOS model changes** (`AssistantContent.swift`):
```swift
// Add to ContentBlock enum:
case toolResult(ToolResultBlock)

struct ToolResultBlock: Codable {
    let type: String
    let toolUseId: String
    let content: String
    let isError: Bool?
}
```

**iOS conversation model** (`SessionView.swift`):
```swift
enum ConversationItem: Identifiable {
    case textMessage(SessionHistoryMessage)
    case toolUse(ToolUseBlock, ToolResultBlock?)  // result is nil until it arrives
}
```

**New view: `ToolUseView.swift`**:
- Always expanded (not collapsed)
- Shows: tool icon + name, tool input (contextual), tool result (monospace)
- Tool input display by tool name:
  - Bash → show `command`
  - Read → show `file_path`
  - Edit → show `file_path`
  - Grep → show `pattern`
  - Write → show `file_path`
  - Other → show tool name
- Result: first ~20 lines visible, "Show more" button to expand
- Errors: red-tinted background
- Pending result: show spinner

**Thinking blocks**: Not displayed (user decision).

**SessionView changes**:
- `onAssistantResponse` callback: stop discarding tool_use/tool_result blocks
- Append tool blocks as `ConversationItem.toolUse`
- When tool_result arrives, find matching tool_use by `tool_use_id` and update
- History loading: parse richer format into `[ConversationItem]`

### Decisions
- Always expanded, not collapsed
- iOS-side pairing (server sends in order, iOS matches by tool_use_id)
- Truncate at ~20 lines with "Show more"
- No thinking block display
- Tool use + result paired visually

---

## Files to Modify

### Server
- `voice_server/content_models.py` - add ToolResultBlock
- `voice_server/ios_server.py` - extract tool_result from user messages, image handling in read_file
- `voice_server/session_manager.py` - return structured content_blocks in history

### iOS
- `AssistantContent.swift` - add toolResult case and model
- `FileView.swift` - image rendering, Kingfisher cache, pinch-to-zoom
- `FileModels.swift` - add image fields to FileContentsResponse
- `SessionView.swift` - ConversationItem enum, stop discarding tool blocks, richer history parsing
- `WebSocketManager.swift` - decode tool_result blocks
- `Session.swift` - richer history message model
- New: `ToolUseView.swift` - paired tool use/result display
- Dependency: add Kingfisher via SPM

## Risks

1. **Tool pairing with parallel calls**: Multiple tool_uses in one response, results arriving separately. Verify with real parallel tool calls.
2. **Large base64 over WebSocket**: 10MB image → 13.3MB base64. Test with large files on WiFi.
3. **Kingfisher without URLs**: Use `ImageCache.default` directly with path keys, not URL-based `KFImage`.
