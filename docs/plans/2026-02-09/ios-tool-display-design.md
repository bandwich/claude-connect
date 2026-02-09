# iOS Tool Display & Newline Fix

## Problem

1. **Leading newlines in text bubbles**: When loading session history, assistant text blocks contain `\n\n` prefixes from Claude's raw transcript. The realtime path strips these but the history load path doesn't.

2. **Task tool shows raw data**: The Task tool displays the full agent prompt as input and `str()`'d Python list as result (e.g. `[{'type': 'text', ...}]`). Should show a compact summary like the terminal UI.

3. **Read/Grep results show full content**: File contents and grep matches are displayed in full. Only the operation summary is needed.

## Changes

### 1. Strip newlines in session history — `voice_server/session_manager.py`

**Line 339** in `get_session_history()`:

```python
# Before
text_parts.append(block.get('text', ''))

# After
text_parts.append(block.get('text', '').strip())
```

Also strip `flat_content` on line 340 for safety, since `' '.join()` of stripped parts could still have edge cases:

```python
flat_content = ' '.join(text_parts).strip()
```

### 2. Compact tool display — `ios-voice-app/.../Views/ToolUseView.swift`

#### 2a. Add `shouldHideResult` property

```swift
private var shouldHideResult: Bool {
    ["Task", "Read", "Grep", "Glob"].contains(tool.name)
}
```

#### 2b. Update `toolInputSummary` for Task

Current:
```swift
case "Task":
    return stringInput("prompt") ?? stringInput("description")
```

New — show `subagent_type: description`:
```swift
case "Task":
    let agentType = stringInput("subagent_type") ?? "Agent"
    let desc = stringInput("description") ?? ""
    return desc.isEmpty ? agentType : "\(agentType): \(desc)"
```

#### 2c. Update `toolInputSummary` for Read

Current — shows just `file_path`:
```swift
case "Read":
    return stringInput("file_path")
```

New — show file path with line range:
```swift
case "Read":
    guard let path = stringInput("file_path") else { return nil }
    let filename = (path as NSString).lastPathComponent
    if let offset = tool.input["offset"]?.value as? Int,
       let limit = tool.input["limit"]?.value as? Int {
        return "\(filename):\(offset)-\(offset + limit - 1)"
    } else if let offset = tool.input["offset"]?.value as? Int {
        return "\(filename):\(offset)+"
    }
    return filename
```

#### 2d. Hide result content for specific tools

In the `body` view, replace the result section:

```swift
// Current: always shows result
if let result = result {
    resultView(result)
} else {
    // Pending spinner
}

// New: hide result for certain tools
if shouldHideResult {
    if result != nil {
        // Show completed indicator only
        HStack(spacing: 4) {
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("Done")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(.top, 2)
    } else {
        // Pending spinner
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.7)
            Text("Running...")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
    }
} else {
    // Existing behavior for Bash, Write, Edit, etc.
    if let result = result {
        resultView(result)
    } else {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.7)
            Text("Running...")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
    }
}
```

### 3. Fix tool result content for list-type results — `voice_server/ios_server.py`

**Line 178** in `extract_new_assistant_content()` — tool_result content that is a `list` gets `str()` which produces Python repr. Extract text properly:

```python
# Before
content=block.get('content', '') if isinstance(block.get('content', ''), str) else str(block.get('content', ''))

# After
raw = block.get('content', '')
if isinstance(raw, str):
    content_str = raw
elif isinstance(raw, list):
    content_str = '\n'.join(
        b.get('text', '') for b in raw
        if isinstance(b, dict) and b.get('type') == 'text'
    )
else:
    content_str = str(raw)
```

This matches what `get_session_history` already does (lines 300-304) for the same case.

## Files Modified

| File | Change |
|------|--------|
| `voice_server/session_manager.py` | Strip text block content in history load |
| `voice_server/ios_server.py` | Fix list-type tool_result serialization |
| `ios-voice-app/.../Views/ToolUseView.swift` | Compact Task/Read/Grep display, hide results |

## Risk

- **Riskiest assumption**: The `offset`/`limit` values in Read tool input are always integers when present. If they come through as strings or doubles via `AnyCodable`, the `as? Int` cast will fail silently and fall back to showing just the filename — safe degradation.
- **Verification**: Open an existing session in the iOS app. Text bubbles should have no leading blank lines. Task tools should show `Explore: <description>`. Read tools should show `filename:range`. Grep/Read results should show "Done" instead of content.
