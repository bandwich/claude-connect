# Agent Status UI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Replace noisy per-agent message bubbles with a compact grouped status card for multiple agents, and keep the existing slim ToolUseView for single agents. Hide TaskOutput from UI entirely.

**Architecture:** Server-side: add `TaskOutput` to `HIDDEN_TOOLS` so it's filtered from both history and real-time streams. iOS-side: add a new `ConversationItem.agentGroup` case and `AgentGroupView` SwiftUI view. SessionView groups consecutive Task tool_use blocks into a single agent group item instead of individual toolUse items.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS), Swift Testing framework (iOS tests), pytest (server tests)

**Risky Assumptions:** The grouping logic assumes all Task tool_use blocks in a batch arrive in the same assistant_response message. We'll verify this against real transcript data early in Task 2.

**Design doc:** `docs/plans/2026-03-06/agent-status-ui-design.md`

---

### Task 1: Add TaskOutput to HIDDEN_TOOLS (Server)

**Files:**
- Modify: `voice_server/session_manager.py:52`
- Test: `voice_server/tests/test_response_extraction.py`

**Step 1: Write the failing test**

Add to `voice_server/tests/test_response_extraction.py`:

```python
def test_taskoutput_tool_use_is_hidden():
    """TaskOutput tool_use blocks and their results should be filtered out"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # Assistant sends a TaskOutput call
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "toolu_01ABC", "name": "TaskOutput", "input": {"task_id": "bfb6bf6", "block": True}}
                ]
            }
        }) + "\n")
        # The tool result comes back
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": [
                    {
                        "type": "tool_result",
                        "tool_use_id": "toolu_01ABC",
                        "content": "<output>Agent found stuff</output>"
                    }
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        # Both the TaskOutput tool_use and its result should be filtered out
        assert len(blocks) == 0, f"Expected 0 blocks but got {len(blocks)}: {blocks}"
    finally:
        os.unlink(temp_path)


def test_taskoutput_hidden_alongside_visible_tools():
    """TaskOutput should be hidden but Task and other tools should still appear"""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        # Assistant sends a regular Task tool and a TaskOutput
        f.write(json.dumps({
            "message": {
                "role": "assistant",
                "content": [
                    {"type": "tool_use", "id": "toolu_01TASK", "name": "Task", "input": {"description": "Explore stuff", "subagent_type": "Explore", "prompt": "do things"}},
                    {"type": "tool_use", "id": "toolu_01OUT", "name": "TaskOutput", "input": {"task_id": "abc123", "block": True}}
                ]
            }
        }) + "\n")
        # Results for both
        f.write(json.dumps({
            "message": {
                "role": "user",
                "content": [
                    {"type": "tool_result", "tool_use_id": "toolu_01TASK", "content": "agent done"},
                    {"type": "tool_result", "tool_use_id": "toolu_01OUT", "content": "<output>result</output>"}
                ]
            }
        }) + "\n")
        temp_path = f.name

    try:
        mock_server = type('obj', (), {'last_voice_input': 'test'})()
        handler = TranscriptHandler(None, None, None, mock_server)

        blocks = handler.extract_new_assistant_content(temp_path)
        # Task tool_use + its result should appear; TaskOutput + its result should not
        tool_names = [b.name for b in blocks if isinstance(b, ToolUseBlock)]
        assert "Task" in tool_names
        assert "TaskOutput" not in tool_names
        # The Task result should be present
        result_ids = [b.tool_use_id for b in blocks if isinstance(b, ToolResultBlock)]
        assert "toolu_01TASK" in result_ids
        assert "toolu_01OUT" not in result_ids
    finally:
        os.unlink(temp_path)
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_response_extraction.py::test_taskoutput_tool_use_is_hidden test_response_extraction.py::test_taskoutput_hidden_alongside_visible_tools -v`

Expected: FAIL (TaskOutput is not yet in HIDDEN_TOOLS)

**Step 3: Add TaskOutput to HIDDEN_TOOLS**

In `voice_server/session_manager.py` line 52, change:

```python
HIDDEN_TOOLS = {'TaskCreate', 'TaskUpdate', 'TaskGet', 'TaskList', 'TaskStop'}
```

to:

```python
HIDDEN_TOOLS = {'TaskCreate', 'TaskUpdate', 'TaskGet', 'TaskList', 'TaskStop', 'TaskOutput'}
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_response_extraction.py -v`

Expected: All pass including the two new tests.

**Step 5: Run full server test suite**

Run: `cd voice_server/tests && ./run_tests.sh`

Expected: All tests pass.

**Step 6: Commit**

```bash
git add voice_server/session_manager.py voice_server/tests/test_response_extraction.py
git commit -m "feat: hide TaskOutput from iOS app UI"
```

---

### Task 2: Add agentGroup ConversationItem case (iOS Model)

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift:82-97`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift`

**Step 1: Write the failing test**

Add to `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift`:

```swift
// MARK: - Agent Group Tests

@Suite("AgentGroup ConversationItem Tests")
struct AgentGroupTests {

    @Test func testAgentGroupId() throws {
        let tool1 = ToolUseBlock(
            type: "tool_use", id: "toolu_01A", name: "Task",
            input: ["description": AnyCodable("Find stuff"), "subagent_type": AnyCodable("Explore")]
        )
        let tool2 = ToolUseBlock(
            type: "tool_use", id: "toolu_01B", name: "Task",
            input: ["description": AnyCodable("Check things"), "subagent_type": AnyCodable("Explore")]
        )
        let item = ConversationItem.agentGroup(agents: [
            AgentInfo(tool: tool1, result: nil),
            AgentInfo(tool: tool2, result: nil)
        ])
        #expect(item.id == "agent-group-toolu_01A")
    }

    @Test func testAgentInfoDescription() throws {
        let tool = ToolUseBlock(
            type: "tool_use", id: "toolu_01A", name: "Task",
            input: ["description": AnyCodable("Find message flow"), "subagent_type": AnyCodable("Explore")]
        )
        let agent = AgentInfo(tool: tool, result: nil)
        #expect(agent.displayDescription == "Explore: Find message flow")
    }

    @Test func testAgentInfoDescriptionWithoutSubagentType() throws {
        let tool = ToolUseBlock(
            type: "tool_use", id: "toolu_01A", name: "Task",
            input: ["description": AnyCodable("Do something")]
        )
        let agent = AgentInfo(tool: tool, result: nil)
        #expect(agent.displayDescription == "Agent: Do something")
    }

    @Test func testAgentInfoIsDone() throws {
        let tool = ToolUseBlock(
            type: "tool_use", id: "toolu_01A", name: "Task",
            input: ["description": AnyCodable("Find stuff"), "subagent_type": AnyCodable("Explore")]
        )
        let result = ToolResultBlock(type: "tool_result", toolUseId: "toolu_01A", content: "done", isError: false)

        let running = AgentInfo(tool: tool, result: nil)
        let done = AgentInfo(tool: tool, result: result)

        #expect(running.isDone == false)
        #expect(done.isDone == true)
    }

    @Test func testAgentInfoTruncatesLongDescription() throws {
        let longDesc = String(repeating: "a", count: 80)
        let tool = ToolUseBlock(
            type: "tool_use", id: "toolu_01A", name: "Task",
            input: ["description": AnyCodable(longDesc), "subagent_type": AnyCodable("Explore")]
        )
        let agent = AgentInfo(tool: tool, result: nil)
        #expect(agent.displayDescription.count <= 60) // "Explore: " + 50 + "..."
    }
}
```

**Step 2: Run tests to verify they fail**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/AgentGroupTests 2>&1 | tail -20
```

Expected: FAIL — `AgentInfo` and `.agentGroup` don't exist yet.

**Step 3: Implement AgentInfo and agentGroup case**

In `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift`, add `AgentInfo` struct before the `ConversationItem` enum (before line 82):

```swift
struct AgentInfo {
    let tool: ToolUseBlock
    var result: ToolResultBlock?

    var isDone: Bool {
        result != nil
    }

    var displayDescription: String {
        let subagentType: String
        if let typeValue = tool.input["subagent_type"]?.value as? String, !typeValue.isEmpty {
            subagentType = typeValue
        } else {
            subagentType = "Agent"
        }
        let desc = (tool.input["description"]?.value as? String) ?? ""
        let maxDescLen = 50
        let truncatedDesc = desc.count > maxDescLen ? String(desc.prefix(maxDescLen)) + "..." : desc
        return truncatedDesc.isEmpty ? subagentType : "\(subagentType): \(truncatedDesc)"
    }
}
```

Then add the new case to `ConversationItem` enum:

```swift
enum ConversationItem: Identifiable {
    case textMessage(SessionHistoryMessage)
    case toolUse(toolId: String, tool: ToolUseBlock, result: ToolResultBlock?)
    case agentGroup(agents: [AgentInfo])
    case permissionPrompt(requestId: String, request: PermissionRequest)

    var id: String {
        switch self {
        case .textMessage(let msg):
            return "text-\(msg.timestamp)"
        case .toolUse(let toolId, _, _):
            return "tool-\(toolId)"
        case .agentGroup(let agents):
            return "agent-group-\(agents.first?.tool.id ?? "unknown")"
        case .permissionPrompt(let requestId, _):
            return "perm-\(requestId)"
        }
    }
}
```

**Step 4: Run tests to verify they pass**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/AgentGroupTests 2>&1 | tail -20
```

Expected: All 5 tests pass.

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift
git commit -m "feat: add AgentInfo model and agentGroup ConversationItem case"
```

---

### Task 3: Create AgentGroupView (iOS View)

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/AgentGroupView.swift`

**Step 1: Create the view**

```swift
import SwiftUI

struct AgentGroupView: View {
    let agents: [AgentInfo]

    private var allDone: Bool {
        agents.allSatisfy { $0.isDone }
    }

    private var doneCount: Int {
        agents.filter { $0.isDone }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.footnote)
                    .foregroundColor(.secondary)
                Text(allDone ? "Ran \(agents.count) agents" : "Running \(agents.count) agents...")
                    .font(.footnote.bold())
                    .foregroundColor(.secondary)
            }
            .padding(.bottom, 2)

            // Agent list
            ForEach(Array(agents.enumerated()), id: \.offset) { _, agent in
                HStack(spacing: 8) {
                    if agent.isDone {
                        Image(systemName: "checkmark")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    }
                    Text(agent.displayDescription)
                        .font(.system(.footnote, design: .monospaced))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray5).opacity(0.5))
        .cornerRadius(10)
    }
}
```

**Step 2: Add the file to the Xcode project**

The project uses directory-based file discovery (no manual pbxproj edits needed for files in existing directories). Verify by building:

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/AgentGroupView.swift
git commit -m "feat: add AgentGroupView for grouped agent status display"
```

---

### Task 4: Group Task blocks in SessionView

This is the core change. SessionView currently creates individual `.toolUse` items for each Task block. We need to:
1. Detect when 2+ Task blocks appear consecutively
2. Group them into a single `.agentGroup` item
3. Keep single Task blocks as `.toolUse` (existing behavior)
4. Update results correctly when tool_results arrive

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Add a helper function for grouping**

Add this as an internal (non-private) function in `Session.swift` alongside the `ConversationItem` enum, so it's testable from `ClaudeVoiceTests`. This helper takes a flat list of ConversationItems and groups consecutive Task toolUse items into agentGroup items:

```swift
/// Groups consecutive Task tool_use items into agentGroup items.
/// Single Task items remain as toolUse. Groups of 2+ become agentGroup.
func groupAgentItems(_ items: [ConversationItem]) -> [ConversationItem] {
    var result: [ConversationItem] = []
    var pendingAgents: [AgentInfo] = []

    func flushAgents() {
        if pendingAgents.count >= 2 {
            result.append(.agentGroup(agents: pendingAgents))
        } else if let single = pendingAgents.first {
            result.append(.toolUse(toolId: single.tool.id, tool: single.tool, result: single.result))
        }
        pendingAgents = []
    }

    for item in items {
        if case .toolUse(_, let tool, let toolResult) = item, tool.name == "Task" {
            pendingAgents.append(AgentInfo(tool: tool, result: toolResult))
        } else {
            flushAgents()
            result.append(item)
        }
    }
    flushAgents()
    return result
}
```

**Step 2: Apply grouping in the three item-building locations**

There are three places in SessionView that build/modify the `items` array:

1. **History loading** (~line 450): After `self.items = newItems`, change to:
   ```swift
   self.items = groupAgentItems(newItems)
   ```

2. **Real-time assistant_response** (~line 555-586): When a `toolUse` block with name "Task" arrives, instead of immediately appending, we need to check if the previous item is an agentGroup or a Task toolUse and merge. Replace the `.toolUse(let toolBlock)` case:
   ```swift
   case .toolUse(let toolBlock):
       DispatchQueue.main.async {
           // Mark any previous non-Task tool_use without a result as stale
           for i in stride(from: items.count - 1, through: 0, by: -1) {
               if case .toolUse(let tid, let tool, nil) = items[i], tool.name != "Task" {
                   let staleResult = ToolResultBlock(
                       type: "tool_result",
                       toolUseId: tid,
                       content: "(result not available)",
                       isError: false
                   )
                   items[i] = .toolUse(toolId: tid, tool: tool, result: staleResult)
               }
           }

           if toolBlock.name == "Task" {
               // Check if last item is already an agentGroup — append to it
               if case .agentGroup(var agents) = items.last {
                   agents.append(AgentInfo(tool: toolBlock, result: nil))
                   items[items.count - 1] = .agentGroup(agents: agents)
               }
               // Check if last item is a single Task toolUse — merge into group
               else if case .toolUse(_, let prevTool, let prevResult) = items.last, prevTool.name == "Task" {
                   let prevAgent = AgentInfo(tool: prevTool, result: prevResult)
                   let newAgent = AgentInfo(tool: toolBlock, result: nil)
                   items[items.count - 1] = .agentGroup(agents: [prevAgent, newAgent])
               }
               // Otherwise just append as single toolUse
               else {
                   items.append(.toolUse(toolId: toolBlock.id, tool: toolBlock, result: nil))
               }
           } else {
               items.append(.toolUse(toolId: toolBlock.id, tool: toolBlock, result: nil))
           }
       }
   ```

3. **Real-time tool_result**: When a tool_result arrives, it needs to update agents inside agentGroup items too. Replace the `.toolResult(let resultBlock)` case:
   ```swift
   case .toolResult(let resultBlock):
       DispatchQueue.main.async {
           // First check agentGroup items
           for i in 0..<items.count {
               if case .agentGroup(var agents) = items[i] {
                   if let agentIdx = agents.firstIndex(where: { $0.tool.id == resultBlock.toolUseId }) {
                       agents[agentIdx].result = resultBlock
                       items[i] = .agentGroup(agents: agents)
                       return
                   }
               }
           }
           // Then check individual toolUse items
           if let idx = items.firstIndex(where: {
               if case .toolUse(let tid, _, _) = $0 { return tid == resultBlock.toolUseId }
               return false
           }) {
               if case .toolUse(let tid, let tool, _) = items[idx] {
                   items[idx] = .toolUse(toolId: tid, tool: tool, result: resultBlock)
               }
           }
       }
   ```

4. **Resync handler** (~line 628-707): Apply the same pattern as real-time. The toolUse and toolResult cases should match the real-time handler above. After the resync loop completes, also apply grouping to catch any ungrouped agents from the batch:
   ```swift
   // After the resync message loop, regroup any consecutive Task items
   DispatchQueue.main.async {
       items = groupAgentItems(items)
   }
   ```

**Step 3: Render agentGroup in the ForEach**

In the `ForEach(items)` switch (~line 42), add the agentGroup case:

```swift
case .agentGroup(let agents):
    AgentGroupView(agents: agents)
        .id(item.id)
```

**Step 4: Build and verify**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10
```

Expected: BUILD SUCCEEDED

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: group multiple Task tools into AgentGroupView in session"
```

---

### Task 5: Add grouping logic unit tests (iOS)

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift`

**Step 1: Write the tests**

Add to `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift`:

```swift
// MARK: - Agent Grouping Logic Tests

@Suite("Agent Grouping Tests")
struct AgentGroupingTests {

    private func makeTaskTool(id: String, description: String = "Do stuff", subagentType: String = "Explore") -> ToolUseBlock {
        ToolUseBlock(
            type: "tool_use", id: id, name: "Task",
            input: ["description": AnyCodable(description), "subagent_type": AnyCodable(subagentType)]
        )
    }

    private func makeBashTool(id: String) -> ToolUseBlock {
        ToolUseBlock(
            type: "tool_use", id: id, name: "Bash",
            input: ["command": AnyCodable("echo hello")]
        )
    }

    @Test func testSingleTaskNotGrouped() {
        let tool = makeTaskTool(id: "t1")
        let items: [ConversationItem] = [.toolUse(toolId: "t1", tool: tool, result: nil)]
        let grouped = groupAgentItems(items)
        #expect(grouped.count == 1)
        if case .toolUse = grouped[0] {} else {
            Issue.record("Expected toolUse, got \(grouped[0])")
        }
    }

    @Test func testTwoTasksGrouped() {
        let tool1 = makeTaskTool(id: "t1", description: "First")
        let tool2 = makeTaskTool(id: "t2", description: "Second")
        let items: [ConversationItem] = [
            .toolUse(toolId: "t1", tool: tool1, result: nil),
            .toolUse(toolId: "t2", tool: tool2, result: nil)
        ]
        let grouped = groupAgentItems(items)
        #expect(grouped.count == 1)
        if case .agentGroup(let agents) = grouped[0] {
            #expect(agents.count == 2)
            #expect(agents[0].displayDescription.contains("First"))
            #expect(agents[1].displayDescription.contains("Second"))
        } else {
            Issue.record("Expected agentGroup, got \(grouped[0])")
        }
    }

    @Test func testMixedToolsGroupCorrectly() {
        let bash = makeBashTool(id: "b1")
        let task1 = makeTaskTool(id: "t1")
        let task2 = makeTaskTool(id: "t2")
        let task3 = makeTaskTool(id: "t3")
        let items: [ConversationItem] = [
            .toolUse(toolId: "b1", tool: bash, result: nil),
            .toolUse(toolId: "t1", tool: task1, result: nil),
            .toolUse(toolId: "t2", tool: task2, result: nil),
            .toolUse(toolId: "t3", tool: task3, result: nil)
        ]
        let grouped = groupAgentItems(items)
        #expect(grouped.count == 2) // bash + agent group
        if case .toolUse(_, let tool, _) = grouped[0] {
            #expect(tool.name == "Bash")
        } else {
            Issue.record("Expected toolUse(Bash)")
        }
        if case .agentGroup(let agents) = grouped[1] {
            #expect(agents.count == 3)
        } else {
            Issue.record("Expected agentGroup with 3 agents")
        }
    }

    @Test func testNonConsecutiveTasksNotGrouped() {
        let task1 = makeTaskTool(id: "t1")
        let bash = makeBashTool(id: "b1")
        let task2 = makeTaskTool(id: "t2")
        let items: [ConversationItem] = [
            .toolUse(toolId: "t1", tool: task1, result: nil),
            .toolUse(toolId: "b1", tool: bash, result: nil),
            .toolUse(toolId: "t2", tool: task2, result: nil)
        ]
        let grouped = groupAgentItems(items)
        #expect(grouped.count == 3) // single task, bash, single task
        if case .toolUse(_, let tool, _) = grouped[0] {
            #expect(tool.name == "Task")
        }
        if case .toolUse(_, let tool, _) = grouped[2] {
            #expect(tool.name == "Task")
        }
    }

    @Test func testGroupPreservesResults() {
        let tool1 = makeTaskTool(id: "t1")
        let tool2 = makeTaskTool(id: "t2")
        let result1 = ToolResultBlock(type: "tool_result", toolUseId: "t1", content: "done", isError: false)
        let items: [ConversationItem] = [
            .toolUse(toolId: "t1", tool: tool1, result: result1),
            .toolUse(toolId: "t2", tool: tool2, result: nil)
        ]
        let grouped = groupAgentItems(items)
        #expect(grouped.count == 1)
        if case .agentGroup(let agents) = grouped[0] {
            #expect(agents[0].isDone == true)
            #expect(agents[1].isDone == false)
        } else {
            Issue.record("Expected agentGroup")
        }
    }
}
```

**Step 2: Verify groupAgentItems is accessible to tests**

The `groupAgentItems` function was placed in `Session.swift` as an internal function in Task 4. It should already be accessible from `ClaudeVoiceTests` via `@testable import ClaudeVoice`.

**Step 3: Run tests**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/AgentGroupingTests 2>&1 | tail -30
```

Expected: All 5 tests pass.

**Step 4: Run full iOS test suite**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests 2>&1 | tail -20
```

Expected: All tests pass (including existing tests — no regressions).

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceTests/ClaudeVoiceTests.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift
git commit -m "test: add unit tests for agent grouping logic"
```

---

### Task 6: Build, deploy, and verify end-to-end

**Files:** None (verification only)

**Step 1: Run full server tests**

```bash
cd voice_server/tests && ./run_tests.sh
```

Expected: All pass.

**Step 2: Run full iOS unit tests**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests 2>&1 | tail -20
```

Expected: All pass.

**Step 3: Reinstall server**

```bash
pipx install --force --python python3.9 /Users/aaron/Desktop/max
```

**Step 4: Build and install on device**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild -target ClaudeVoice -sdk iphoneos build
xcrun devicectl list devices
xcrun devicectl device install app --device "<DEVICE_ID>" \
  ios-voice-app/ClaudeVoice/build/Release-iphoneos/ClaudeVoice.app
```

**Step 5: Manual verification**

Start the server (`claude-connect`), connect the iOS app, and open a session. Ask Claude to do something that spawns agents (e.g. "explore this codebase").

**CHECKPOINT:** Verify the following:
1. Multiple agents appear as a single grouped card (not separate bubbles)
2. Each agent line shows type + description + spinner while running
3. Agent lines flip to checkmark when done
4. Header says "Running N agents..." then "Ran N agents" when complete
5. No TaskOutput bubbles appear
6. A single agent (if one is spawned) still shows as a normal ToolUseView card
7. Non-agent tools (Bash, Read, etc.) still render normally

If any of these fail, debug before considering the feature complete.
