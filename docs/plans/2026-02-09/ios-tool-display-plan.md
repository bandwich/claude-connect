# iOS Tool Display & Newline Fix — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix leading newlines in session history text bubbles, fix raw list serialization of tool results, and make Task/Read/Grep tools display compact summaries instead of full content.

**Architecture:** Three small, independent fixes across the Python server (history load + realtime extraction) and the iOS ToolUseView. No new files, no new dependencies.

**Tech Stack:** Python (Pydantic models, JSONL parsing), Swift/SwiftUI (ToolUseView)

**Risky Assumptions:** `AnyCodable` may decode JSON integers as `Int` or `Double` depending on the value — the `as? Int` cast for Read tool's offset/limit might fail for large numbers. Safe degradation: falls back to showing just the filename.

**Design doc:** `docs/plans/2026-02-09/ios-tool-display-design.md`

---

### Task 1: Fix text stripping in session history load

**Files:**
- Modify: `voice_server/session_manager.py:339-340`
- Test: `voice_server/tests/test_session_manager.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_session_manager.py`, inside the `TestSessionManager` class:

```python
def test_get_session_history_strips_text_newlines(self, tmp_path):
    """Text blocks with leading/trailing newlines should be stripped in history"""
    from session_manager import SessionManager

    project_dir = tmp_path / "-Users-test-project"
    project_dir.mkdir()

    session_file = project_dir / "sess123.jsonl"
    session_file.write_text(
        json.dumps({
            "message": {"role": "assistant", "content": [
                {"type": "text", "text": "\n\nHello, how can I help?"}
            ]},
            "timestamp": "2026-01-01T10:00:00Z"
        }) + "\n"
    )

    manager = SessionManager(projects_dir=str(tmp_path))
    messages = manager.get_session_history("-Users-test-project", "sess123")

    assert len(messages) == 1
    assert messages[0].content == "Hello, how can I help?"
    assert not messages[0].content.startswith("\n")
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && source ../../.venv/bin/activate && pytest test_session_manager.py::TestSessionManager::test_get_session_history_strips_text_newlines -v`
Expected: FAIL — content will be `"\n\nHello, how can I help?"` instead of stripped.

**Step 3: Implement the fix**

In `voice_server/session_manager.py`, change line 339:

```python
# Before
text_parts.append(block.get('text', ''))
# After
text_parts.append(block.get('text', '').strip())
```

And line 340:

```python
# Before
flat_content = ' '.join(text_parts)
# After
flat_content = ' '.join(text_parts).strip()
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && source ../../.venv/bin/activate && pytest test_session_manager.py::TestSessionManager::test_get_session_history_strips_text_newlines -v`
Expected: PASS

**Step 5: Run full test suite to check for regressions**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "fix: strip leading newlines from text blocks in session history"
```

---

### Task 2: Fix list-type tool_result serialization in realtime extraction

**Files:**
- Modify: `voice_server/ios_server.py:174-182`
- Test: `voice_server/tests/test_response_extraction.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_response_extraction.py`:

```python
def test_extract_tool_result_with_list_content():
    """tool_result with list content should join text blocks, not str() the list"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "toolu_01XYZ", "name": "Task", "input": {"prompt": "do stuff"}}
                ]
            }
        }) + "\n")
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "toolu_01XYZ",
                        "content": [
                            {"type": "text", "text": "First part of result."},
                            {"type": "text", "text": "Second part of result."}
                        ]
                    }
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        assert len(blocks) == 2
        result_block = blocks[1]
        assert isinstance(result_block, ToolResultBlock)
        # Should be joined text, not "[{'type': 'text', ..."
        assert result_block.content == "First part of result.\nSecond part of result."
        assert "[{" not in result_block.content
    finally:
        os.unlink(temp_path)
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && source ../../.venv/bin/activate && pytest test_response_extraction.py::test_extract_tool_result_with_list_content -v`
Expected: FAIL — content will be the `str()` repr of the list.

**Step 3: Implement the fix**

In `voice_server/ios_server.py`, replace line 178 (inside the `tool_result` handling block, lines 174-182):

```python
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
```

This replaces the existing lines 174-182. The full block from `try:` through the `append` call.

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && source ../../.venv/bin/activate && pytest test_response_extraction.py::test_extract_tool_result_with_list_content -v`
Expected: PASS

**Step 5: Run full test suite**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests pass.

**Step 6: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_response_extraction.py
git commit -m "fix: properly serialize list-type tool_result content"
```

---

### Task 3: Compact Task tool display in iOS ToolUseView

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift:190-191`

**Step 1: Update toolInputSummary for Task**

In `ToolUseView.swift`, replace lines 190-191:

```swift
// Before
case "Task":
    return stringInput("prompt") ?? stringInput("description")

// After
case "Task":
    let agentType = stringInput("subagent_type") ?? "Agent"
    let desc = stringInput("description") ?? ""
    return desc.isEmpty ? agentType : "\(agentType): \(desc)"
```

**Step 2: Update toolInputSummary for Read**

Replace lines 175-176:

```swift
// Before
case "Read":
    return stringInput("file_path")

// After
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

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift
git commit -m "feat: compact Task and Read tool input display"
```

---

### Task 4: Hide tool results for Task/Read/Grep/Glob

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift`

**Step 1: Add shouldHideResult computed property**

Add after the `isTaskOutput` property (after line 12):

```swift
private var shouldHideResult: Bool {
    ["Task", "Read", "Grep", "Glob"].contains(tool.name)
}
```

**Step 2: Replace the result section in body**

Replace lines 58-71 (the `// Tool result` section) with:

```swift
            // Tool result
            if shouldHideResult {
                if result != nil {
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
                    HStack(spacing: 6) {
                        ProgressView()
                            .scaleEffect(0.7)
                        Text("Running...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(8)
                }
            } else if let result = result {
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
```

**Step 3: Build to verify compilation**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ToolUseView.swift
git commit -m "feat: hide result content for Task/Read/Grep/Glob tools"
```

---

### Task 5: Verify end-to-end on device

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

**Step 3: Manual verification**

Open an existing session in the iOS app that has:
- Text messages — verify no leading blank lines in bubbles
- Task/Explore tool uses — verify shows `Explore: <description>` with "Done", not raw prompt/result
- Read tool uses — verify shows `filename:line-range` with "Done", not file contents
- Grep tool uses — verify shows search summary with "Done", not matched lines
- Bash/Write/Edit tool uses — verify these still show full results as before

**CHECKPOINT:** All five verifications must pass. If any fail, debug before merging.

**Step 4: Commit any fixes from verification, then done**

```bash
git add -A && git commit -m "fix: address verification issues" # only if needed
```
