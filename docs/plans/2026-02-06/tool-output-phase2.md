# Tool Output Visibility - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Show tool use inputs and results in the iOS conversation view so users can see what Claude is doing (bash commands, file reads, edits, etc.) instead of just the tool name.

**Architecture:** Server extracts `tool_result` blocks from "user" role transcript entries (Claude API convention) alongside existing `tool_use` blocks from "assistant" entries. iOS pairs them by `tool_use_id` and renders with a new `ToolUseView`. Session history also returns structured blocks. The conversation model changes from flat text to a `ConversationItem` enum.

**Tech Stack:** Python/Pydantic (server), Swift/SwiftUI (iOS)

**Risky Assumptions:** Tool_use/tool_result pairing works correctly when Claude makes parallel tool calls (multiple tool_uses in one response, results arriving separately). We verify this in Task 2 with a multi-tool transcript test.

---

### Task 1: Server - Add ToolResultBlock and extract from transcripts

**Files:**
- Modify: `voice_server/content_models.py`
- Modify: `voice_server/ios_server.py:117-162` (extract_new_assistant_content)
- Test: `voice_server/tests/test_content_models.py`
- Test: `voice_server/tests/test_response_extraction.py`

**Step 1: Write failing tests**

Add to `voice_server/tests/test_content_models.py`:

```python
from voice_server.content_models import ToolResultBlock


def test_tool_result_block_creation():
    """ToolResultBlock should be creatable with expected fields"""
    block = ToolResultBlock(
        type="tool_result",
        tool_use_id="toolu_01ABC",
        content="file1.txt\nfile2.txt",
        is_error=False
    )
    assert block.type == "tool_result"
    assert block.tool_use_id == "toolu_01ABC"
    assert block.content == "file1.txt\nfile2.txt"
    assert block.is_error is False


def test_tool_result_block_serialization():
    """ToolResultBlock should serialize to JSON with snake_case fields"""
    block = ToolResultBlock(
        type="tool_result",
        tool_use_id="toolu_01ABC",
        content="output",
        is_error=True
    )
    data = block.model_dump()
    assert data["type"] == "tool_result"
    assert data["tool_use_id"] == "toolu_01ABC"
    assert data["is_error"] is True
```

Add to `voice_server/tests/test_response_extraction.py`:

```python
from voice_server.content_models import ToolUseBlock, ToolResultBlock


def test_extract_tool_result_from_user_message():
    """Should extract tool_result blocks from user messages in transcript"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # Assistant message with tool_use
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "toolu_01ABC", "name": "Bash", "input": {"command": "ls -la"}}
                ]
            }
        }) + "\n")
        # User message with tool_result
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_01ABC", "content": "file1.txt\nfile2.txt", "is_error": False}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        assert len(blocks) == 2
        assert isinstance(blocks[0], ToolUseBlock)
        assert isinstance(blocks[1], ToolResultBlock)
        assert blocks[1].tool_use_id == "toolu_01ABC"
        assert blocks[1].content == "file1.txt\nfile2.txt"
    finally:
        os.unlink(temp_path)


def test_extract_parallel_tool_results():
    """Should extract multiple tool_results from a single user message"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # Assistant with 2 parallel tool_uses
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "toolu_01A", "name": "Grep", "input": {"pattern": "foo"}},
                    {"type": "tool_use", "id": "toolu_01B", "name": "Grep", "input": {"pattern": "bar"}}
                ]
            }
        }) + "\n")
        # User message with both results
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_01A", "content": "match1"},
                    {"type": "tool_result", "tool_use_id": "toolu_01B", "content": "match2"}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        assert len(blocks) == 4  # 2 tool_use + 2 tool_result
        assert isinstance(blocks[2], ToolResultBlock)
        assert isinstance(blocks[3], ToolResultBlock)
        assert blocks[2].tool_use_id == "toolu_01A"
        assert blocks[3].tool_use_id == "toolu_01B"
    finally:
        os.unlink(temp_path)


def test_extract_skips_non_tool_result_user_messages():
    """Should not extract regular user text messages"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": "just a regular user message"
            }
        }) + "\n")
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [{"type": "text", "text": "hello"}]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        assert len(blocks) == 1  # Only the text block
        assert isinstance(blocks[0], TextBlock)
    finally:
        os.unlink(temp_path)
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: FAIL - ToolResultBlock doesn't exist, tool_results not extracted

**Step 3: Add ToolResultBlock to content_models.py**

In `voice_server/content_models.py`, add after `ToolUseBlock`:

```python
class ToolResultBlock(BaseModel):
    type: Literal["tool_result"]
    tool_use_id: str
    content: str = ""
    is_error: bool = False
```

Update the `ContentBlock` union and `AssistantResponse` to include it:

```python
ContentBlock = Union[TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock]
```

**Step 4: Update extract_new_assistant_content to extract tool_results**

In `voice_server/ios_server.py`, update the import line 21:

```python
from voice_server.content_models import TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock, ContentBlock, AssistantResponse
```

Replace `extract_new_assistant_content` (lines 117-162) with:

```python
    def extract_new_assistant_content(self, filepath) -> list[ContentBlock]:
        """Extract assistant content and tool results from lines not yet processed"""
        all_blocks = []

        with open(filepath, 'r') as f:
            lines = f.readlines()

        # Reset if file was truncated/overwritten (fewer lines than we've processed)
        if len(lines) < self.processed_line_count:
            self.processed_line_count = 0

        new_lines = lines[self.processed_line_count:]

        for line in new_lines:
            try:
                entry = json.loads(line.strip())
                msg = entry.get('message', {})
                role = msg.get('role') or entry.get('role')

                if role == 'assistant':
                    content = msg.get('content', entry.get('content', ''))

                    if isinstance(content, str) and content.strip():
                        all_blocks.append(TextBlock(type="text", text=content.strip()))
                    elif isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict):
                                block_type = block.get('type')
                                try:
                                    if block_type == 'text':
                                        all_blocks.append(TextBlock(**block))
                                    elif block_type == 'thinking':
                                        all_blocks.append(ThinkingBlock(**block))
                                    elif block_type == 'tool_use':
                                        all_blocks.append(ToolUseBlock(**block))
                                except Exception:
                                    continue

                elif role == 'user':
                    content = msg.get('content', entry.get('content', ''))
                    if isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'tool_result':
                                try:
                                    all_blocks.append(ToolResultBlock(
                                        type="tool_result",
                                        tool_use_id=block.get('tool_use_id', ''),
                                        content=block.get('content', '') if isinstance(block.get('content', ''), str) else str(block.get('content', '')),
                                        is_error=block.get('is_error', False)
                                    ))
                                except Exception:
                                    continue

            except json.JSONDecodeError:
                continue

        self.processed_line_count = len(lines)

        if all_blocks:
            print(f"[DEBUG] Extracted {len(all_blocks)} blocks from {len(new_lines)} new lines")

        return all_blocks
```

**Step 5: Run tests to verify they pass**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add voice_server/content_models.py voice_server/ios_server.py voice_server/tests/test_content_models.py voice_server/tests/test_response_extraction.py
git commit -m "feat: extract tool_result blocks from transcripts and send to iOS"
```

---

### Task 2: Server - Structured session history

**Files:**
- Modify: `voice_server/session_manager.py:245-302` (get_session_history)
- Modify: `voice_server/ios_server.py:471-487` (handle_get_session)
- Test: `voice_server/tests/test_session_manager.py`

**Step 1: Write failing test**

Add to `voice_server/tests/test_session_manager.py`, inside `TestSessionManager`:

```python
    def test_get_session_history_includes_content_blocks(self, tmp_path):
        """get_session_history should return content_blocks for structured messages"""
        from session_manager import SessionManager

        folder = tmp_path / "-test-project"
        folder.mkdir(parents=True)

        session_file = folder / "test-session.jsonl"
        lines = [
            json.dumps({"message": {"role": "user", "content": "list files"}, "timestamp": "2026-01-01T00:00:00Z"}),
            json.dumps({"message": {"role": "assistant", "content": [
                {"type": "text", "text": "Let me check."},
                {"type": "tool_use", "id": "toolu_01A", "name": "Bash", "input": {"command": "ls"}}
            ]}, "timestamp": "2026-01-01T00:00:01Z"}),
            json.dumps({"message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_01A", "content": "file1.txt\nfile2.txt", "is_error": False}
            ]}, "timestamp": "2026-01-01T00:00:02Z"}),
            json.dumps({"message": {"role": "assistant", "content": [
                {"type": "text", "text": "Here are your files."}
            ]}, "timestamp": "2026-01-01T00:00:03Z"}),
        ]
        session_file.write_text("\n".join(lines) + "\n")

        manager = SessionManager(projects_dir=str(tmp_path))
        messages = manager.get_session_history("-test-project", "test-session")

        # Should have 4 messages: user text, assistant with blocks, tool_result, assistant text
        assert len(messages) == 4

        # First: user text
        assert messages[0].role == "user"
        assert messages[0].content == "list files"
        assert messages[0].content_blocks is None

        # Second: assistant with tool_use
        assert messages[1].role == "assistant"
        assert messages[1].content == "Let me check."
        assert messages[1].content_blocks is not None
        assert len(messages[1].content_blocks) == 2
        assert messages[1].content_blocks[0]["type"] == "text"
        assert messages[1].content_blocks[1]["type"] == "tool_use"

        # Third: tool_result
        assert messages[2].role == "tool_result"
        assert messages[2].content == "file1.txt\nfile2.txt"
        assert messages[2].content_blocks is not None
        assert messages[2].content_blocks[0]["tool_use_id"] == "toolu_01A"

        # Fourth: assistant text
        assert messages[3].role == "assistant"
        assert messages[3].content == "Here are your files."
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: FAIL - SessionMessage has no content_blocks field, tool_result messages are skipped

**Step 3: Update SessionMessage and get_session_history**

In `voice_server/session_manager.py`, update `SessionMessage`:

```python
@dataclass
class SessionMessage:
    """Represents a message in a session"""
    role: str
    content: str
    timestamp: float
    content_blocks: list = None  # Raw block dicts for structured messages
```

Replace `get_session_history` (lines 245-302):

```python
    def get_session_history(self, folder_name: str, session_id: str) -> list[SessionMessage]:
        """Get all messages from a session with structured content blocks.

        Args:
            folder_name: The actual folder name in projects_dir (not encoded path)
            session_id: The session ID (filename without .jsonl)
        """
        filepath = os.path.join(self.projects_dir, folder_name, f"{session_id}.jsonl")

        if not os.path.exists(filepath):
            return []

        messages = []

        with open(filepath, 'r') as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                    msg = entry.get('message', {})
                    role = msg.get('role') or entry.get('role')

                    if role not in ('user', 'assistant'):
                        continue

                    content = msg.get('content', entry.get('content', ''))

                    timestamp_str = entry.get('timestamp', '')
                    try:
                        from datetime import datetime
                        timestamp = datetime.fromisoformat(timestamp_str.replace('Z', '+00:00')).timestamp()
                    except Exception:
                        timestamp = 0.0

                    if isinstance(content, list):
                        # Check if this is a tool_result message
                        has_tool_result = any(
                            isinstance(b, dict) and b.get('type') == 'tool_result'
                            for b in content
                        )

                        if has_tool_result:
                            # Emit each tool_result as a separate message
                            for block in content:
                                if isinstance(block, dict) and block.get('type') == 'tool_result':
                                    messages.append(SessionMessage(
                                        role="tool_result",
                                        content=block.get('content', '') if isinstance(block.get('content', ''), str) else str(block.get('content', '')),
                                        timestamp=timestamp,
                                        content_blocks=[block]
                                    ))
                            continue

                        # Assistant message with structured blocks
                        text_parts = []
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'text':
                                text_parts.append(block.get('text', ''))
                        flat_content = ' '.join(text_parts)

                        # Check if there are non-text blocks worth keeping
                        has_tool_use = any(
                            isinstance(b, dict) and b.get('type') == 'tool_use'
                            for b in content
                        )

                        if not flat_content and not has_tool_use:
                            continue  # Skip thinking-only messages

                        # Skip skill expansions
                        if role == 'user' and flat_content.strip().startswith('Base directory for this skill:'):
                            continue

                        messages.append(SessionMessage(
                            role=role,
                            content=flat_content,
                            timestamp=timestamp,
                            content_blocks=content if has_tool_use else None
                        ))
                    else:
                        # Simple string content
                        if not content or not content.strip():
                            continue

                        # Skip skill expansions
                        if role == 'user' and content.strip().startswith('Base directory for this skill:'):
                            continue

                        messages.append(SessionMessage(
                            role=role,
                            content=content,
                            timestamp=timestamp,
                            content_blocks=None
                        ))
                except json.JSONDecodeError:
                    continue

        return messages
```

**Step 4: Update handle_get_session to include content_blocks**

In `voice_server/ios_server.py`, replace `handle_get_session` (lines 471-487):

```python
    async def handle_get_session(self, websocket, data):
        """Handle get_session request"""
        folder_name = data.get("folder_name", "")
        session_id = data.get("session_id", "")
        messages = self.session_manager.get_session_history(folder_name, session_id)
        response = {
            "type": "session_history",
            "messages": [
                {
                    "role": m.role,
                    "content": m.content,
                    "timestamp": m.timestamp,
                    **({"content_blocks": m.content_blocks} if m.content_blocks else {})
                }
                for m in messages
            ]
        }
        await websocket.send(json.dumps(response))
```

**Step 5: Run tests to verify they pass**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests PASS

**Step 6: Commit**

```bash
git add voice_server/session_manager.py voice_server/ios_server.py voice_server/tests/test_session_manager.py
git commit -m "feat: include tool_use and tool_result blocks in session history"
```

---

### Task 3: iOS - Add ToolResultBlock model and update conversation model

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/AssistantContent.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift`

**Step 1: Add ToolResultBlock to AssistantContent.swift**

After the `ToolUseBlock` struct, add:

```swift
struct ToolResultBlock: Codable {
    let type: String
    let toolUseId: String
    let content: String
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type
        case toolUseId = "tool_use_id"
        case content
        case isError = "is_error"
    }
}
```

Update the `ContentBlock` enum to include `toolResult`:

```swift
enum ContentBlock: Codable {
    case text(TextBlock)
    case thinking(ThinkingBlock)
    case toolUse(ToolUseBlock)
    case toolResult(ToolResultBlock)

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
        case "tool_result":
            self = .toolResult(try ToolResultBlock(from: decoder))
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
        case .toolResult(let block):
            try block.encode(to: encoder)
        }
    }
}
```

**Step 2: Update Session.swift with ConversationItem and richer history model**

Add to `Session.swift` after `SessionHistoryMessage`:

```swift
struct SessionHistoryMessageRich: Codable, Identifiable {
    let role: String
    let content: String
    let timestamp: Double
    let contentBlocks: [ContentBlockRaw]?

    var id: Double { timestamp }

    enum CodingKeys: String, CodingKey {
        case role, content, timestamp
        case contentBlocks = "content_blocks"
    }
}

/// Raw content block from session history (looser typing than AssistantContent.ContentBlock)
struct ContentBlockRaw: Codable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: [String: AnyCodable]?
    let toolUseId: String?
    let content: String?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }
}

enum ConversationItem: Identifiable {
    case textMessage(SessionHistoryMessage)
    case toolUse(id: String, tool: ToolUseBlock, result: ToolResultBlock?)

    var id: String {
        switch self {
        case .textMessage(let msg):
            return "text-\(msg.timestamp)"
        case .toolUse(let id, _, _):
            return "tool-\(id)"
        }
    }
}
```

Update `SessionHistoryResponse` to decode the richer format:

```swift
struct SessionHistoryResponse: Codable {
    let type: String
    let messages: [SessionHistoryMessageRich]
}
```

**Step 3: Build and verify**

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: Build succeeds (may have warnings about unused types - that's fine, they'll be used in next tasks)

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/AssistantContent.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift
git commit -m "feat: add ToolResultBlock model and ConversationItem enum for tool output display"
```

---

### Task 4: iOS - Create ToolUseView

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift`

**Step 1: Create the view**

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift
import SwiftUI

struct ToolUseView: View {
    let tool: ToolUseBlock
    let result: ToolResultBlock?
    @State private var isExpanded = false

    private let maxPreviewLines = 20

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: icon + tool name
            HStack(spacing: 6) {
                Image(systemName: toolIcon)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(tool.name)
                    .font(.caption.bold())
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 4)

            // Tool input
            if let inputSummary = toolInputSummary {
                Text(inputSummary)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundColor(.primary)
                    .lineLimit(isExpanded ? nil : 3)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.systemGray6))
                    .cornerRadius(6)
                    .padding(.bottom, 4)
            }

            // Tool result
            if let result = result {
                resultView(result)
            } else {
                // Pending result
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                    Text("Running...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(8)
            }
        }
        .padding(10)
        .background(Color(.systemGray5).opacity(0.5))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func resultView(_ result: ToolResultBlock) -> some View {
        let lines = result.content.components(separatedBy: "\n")
        let needsTruncation = lines.count > maxPreviewLines && !isExpanded
        let displayLines = needsTruncation ? Array(lines.prefix(maxPreviewLines)) : lines
        let displayText = displayLines.joined(separator: "\n")

        VStack(alignment: .leading, spacing: 4) {
            Text(displayText.isEmpty ? "(empty)" : displayText)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(result.isError == true ? .red : .primary)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(result.isError == true ? Color.red.opacity(0.1) : Color(.systemGray6))
                .cornerRadius(6)

            if needsTruncation {
                Button {
                    withAnimation { isExpanded = true }
                } label: {
                    HStack {
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.caption2)
                        Text("Show \(lines.count - maxPreviewLines) more lines")
                            .font(.caption2)
                        Spacer()
                    }
                    .foregroundColor(.accentColor)
                    .padding(.top, 2)
                }
            }
        }
    }

    private var toolIcon: String {
        switch tool.name {
        case "Bash": return "terminal"
        case "Read": return "doc.text"
        case "Edit": return "pencil"
        case "Write": return "doc.badge.plus"
        case "Grep": return "magnifyingglass"
        case "Glob": return "folder.badge.magnifyingglass"
        case "Task": return "arrow.triangle.branch"
        case "WebSearch": return "globe"
        case "WebFetch": return "globe"
        default: return "wrench"
        }
    }

    private var toolInputSummary: String? {
        // Extract the most relevant input field based on tool name
        switch tool.name {
        case "Bash":
            return stringInput("command")
        case "Read":
            return stringInput("file_path")
        case "Edit":
            if let path = stringInput("file_path") {
                return path
            }
            return nil
        case "Write":
            return stringInput("file_path")
        case "Grep":
            let pattern = stringInput("pattern") ?? ""
            let path = stringInput("path") ?? ""
            if !path.isEmpty {
                return "\(pattern) in \(path)"
            }
            return pattern.isEmpty ? nil : pattern
        case "Glob":
            return stringInput("pattern")
        case "Task":
            return stringInput("prompt") ?? stringInput("description")
        default:
            // Generic: show first string value
            for (_, value) in tool.input {
                if let str = value.value as? String, !str.isEmpty {
                    return str.count > 100 ? String(str.prefix(100)) + "..." : str
                }
            }
            return nil
        }
    }

    private func stringInput(_ key: String) -> String? {
        if let value = tool.input[key]?.value as? String, !value.isEmpty {
            return value
        }
        return nil
    }
}
```

**Step 2: Build and verify**

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: Build succeeds

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift
git commit -m "feat: add ToolUseView for displaying tool use and results"
```

---

### Task 5: iOS - Wire up SessionView to display tool blocks

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

**Step 1: Update WebSocketManager to decode richer history**

In `WebSocketManager.swift`, update the `onSessionHistoryReceived` callback type (line 39):

Change:
```swift
var onSessionHistoryReceived: (([SessionHistoryMessage]) -> Void)?
```
To:
```swift
var onSessionHistoryReceived: (([SessionHistoryMessageRich]) -> Void)?
```

And update the `handleMessage` method where `SessionHistoryResponse` is decoded (around line 401-405). The decode already works because we changed `SessionHistoryResponse` in Task 3. Just update the callback dispatch:

```swift
} else if let historyResponse = try? JSONDecoder().decode(SessionHistoryResponse.self, from: data) {
    logToFile("✅ Decoded as SessionHistoryResponse: \(historyResponse.messages.count) messages")
    DispatchQueue.main.async {
        self.onSessionHistoryReceived?(historyResponse.messages)
    }
}
```

Do the same for the binary message handler (around line 486-489).

**Step 2: Rewrite SessionView to use ConversationItem**

Replace the `messages` state and all related logic in `SessionView.swift`:

Change the state from:
```swift
@State private var messages: [SessionHistoryMessage] = []
```
To:
```swift
@State private var items: [ConversationItem] = []
```

Replace the message history ScrollView section (the `ForEach(messages)` block):

```swift
ScrollView {
    LazyVStack(alignment: .leading, spacing: 12) {
        ForEach(items) { item in
            switch item {
            case .textMessage(let message):
                MessageBubble(message: message)
            case .toolUse(_, let tool, let result):
                ToolUseView(tool: tool, result: result)
            }
        }
    }
    .padding()
}
.onChange(of: items.count) { _, _ in
    // scroll to bottom logic stays the same but uses items
}
```

Update `setupView` to handle the richer history format:

In the `onSessionHistoryReceived` callback, convert `[SessionHistoryMessageRich]` to `[ConversationItem]`:

```swift
webSocketManager.onSessionHistoryReceived = { richMessages in
    var newItems: [ConversationItem] = []
    for msg in richMessages {
        if msg.role == "tool_result" {
            // Find matching tool_use and update it
            if let blocks = msg.contentBlocks,
               let block = blocks.first,
               let toolUseId = block.toolUseId {
                let resultBlock = ToolResultBlock(
                    type: "tool_result",
                    toolUseId: toolUseId,
                    content: block.content ?? msg.content,
                    isError: block.isError
                )
                // Find and update matching tool_use item
                if let idx = newItems.firstIndex(where: {
                    if case .toolUse(let id, _, _) = $0 { return id == toolUseId }
                    return false
                }) {
                    if case .toolUse(let id, let tool, _) = newItems[idx] {
                        newItems[idx] = .toolUse(id: id, tool: tool, result: resultBlock)
                    }
                }
            }
        } else if let blocks = msg.contentBlocks {
            // Assistant message with structured blocks
            for block in blocks {
                if block.type == "text", let text = block.text, !text.isEmpty {
                    newItems.append(.textMessage(SessionHistoryMessage(
                        role: msg.role,
                        content: text,
                        timestamp: msg.timestamp
                    )))
                } else if block.type == "tool_use", let id = block.id, let name = block.name {
                    let toolBlock = ToolUseBlock(
                        type: "tool_use",
                        id: id,
                        name: name,
                        input: block.input ?? [:]
                    )
                    newItems.append(.toolUse(id: id, tool: toolBlock, result: nil))
                }
            }
        } else {
            // Simple text message
            newItems.append(.textMessage(SessionHistoryMessage(
                role: msg.role,
                content: msg.content,
                timestamp: msg.timestamp
            )))
        }
    }
    self.items = newItems
}
```

Update `onAssistantResponse` callback to append tool blocks:

```swift
webSocketManager.onAssistantResponse = { [self] response in
    // Session filtering (same as before)
    if session.isNewSession {
        if response.sessionId != nil { return }
    } else {
        if response.sessionId != session.id { return }
    }

    for block in response.contentBlocks {
        switch block {
        case .text(let textBlock):
            guard !textBlock.text.isEmpty else { continue }
            let message = SessionHistoryMessage(
                role: "assistant",
                content: textBlock.text,
                timestamp: response.timestamp
            )
            DispatchQueue.main.async {
                items.append(.textMessage(message))
            }
        case .thinking:
            break  // Not displayed per design decision
        case .toolUse(let toolBlock):
            DispatchQueue.main.async {
                items.append(.toolUse(id: toolBlock.id, tool: toolBlock, result: nil))
            }
        case .toolResult(let resultBlock):
            DispatchQueue.main.async {
                // Find matching tool_use and update with result
                if let idx = items.firstIndex(where: {
                    if case .toolUse(let id, _, _) = $0 { return id == resultBlock.toolUseId }
                    return false
                }) {
                    if case .toolUse(let id, let tool, _) = items[idx] {
                        items[idx] = .toolUse(id: id, tool: tool, result: resultBlock)
                    }
                }
            }
        }
    }
}
```

Update permission message appending and voice input message appending to use `items.append(.textMessage(...))` instead of `messages.append(...)`.

Update the `onChange(of: items.count)` scroll logic similarly to the old `onChange(of: messages.count)`.

**Step 3: Build and verify**

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: Build succeeds

**CHECKPOINT:** Connect iOS app to server. Open an existing session that has tool usage in its history. Verify you see tool blocks with inputs and results in the conversation. Then send a voice command that triggers a tool (e.g., "list the files in this directory") and verify the tool_use block appears with a spinner, followed by the result filling in.

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: display tool use and results in iOS conversation view"
```

**Automated tests:** Server-side tests cover extraction and history format. iOS tool display is visual.

**Manual verification (REQUIRED before merge):**
1. Open existing session with tool history - verify tool blocks render with icon, name, input, and result
2. Send voice command triggering Bash tool - verify spinner appears, then result fills in
3. Send command triggering parallel tools (e.g., "search for X in both server and iOS code") - verify all pairs match correctly
4. Verify long tool output (>20 lines) shows truncated with "Show more" button
5. Verify error results show in red
6. Verify text messages still render normally alongside tool blocks
