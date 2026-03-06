# Agent Status UI Design

## Problem

When Claude Code runs agents (Task tool), the terminal shows a compact tree view:

```
Running 4 Explore agents...
├─ Explore message sending flow · 25 tool uses · 63.6k tokens
│  ⎿  Done
├─ Explore settings and connection UI · 9 tool uses · 34.0k tokens
│  ⎿  Done
...
```

The iOS app currently shows agents as separate message bubbles with long first-person text ("I need to understand..."), and for running agents only shows "Agent\nExplore" instead of the full description.

## Design Decisions

- **Minimal detail**: Show agent type, description, and running/done status only. No internal tool calls, no output text, no token counts.
- **Data from main transcript only**: No parsing of `agent-*.jsonl` subagent files. The main session transcript has everything we need.
- **Grouped card for 2+ agents**: One consolidated card instead of N separate bubbles.
- **Slim inline card for 1 agent**: Same style as existing ToolUseView, just with cleaner description display.
- **Done = checkmark, no output**: Agent output text is hidden. Claude's next text message summarizes findings.
- **TaskOutput hidden entirely**: Added to suppressed tools, never shown in UI.

## Transcript Data Flow

### How agents appear in the JSONL transcript

1. **Task tool_use** (assistant message): Contains the launch info
   ```json
   {
     "type": "tool_use",
     "id": "toolu_01FXq...",
     "name": "Task",
     "input": {
       "description": "Find message sending flow",
       "subagent_type": "Explore",
       "prompt": "..."
     }
   }
   ```

2. **Task tool_result** (user message): Agent finished, contains output text
   ```json
   {
     "type": "tool_result",
     "tool_use_id": "toolu_01FXq...",
     "content": [
       {"type": "text", "text": "...agent's findings..."},
       {"type": "text", "text": "agentId: a7297cf\n<usage>total_tokens: 24726\ntool_uses: 1\nduration_ms: 6969</usage>"}
     ]
   }
   ```

3. **TaskOutput tool_use** (assistant message): Claude fetches agent result
   ```json
   {
     "type": "tool_use",
     "id": "toolu_01YZX...",
     "name": "TaskOutput",
     "input": {"task_id": "bfb6bf6", "block": true}
   }
   ```

4. **TaskOutput tool_result**: Contains agent output wrapped in `<output>` tags

### ID mapping (important documentation)

- The `Task` tool_use `id` (e.g. `toolu_01FXq...`) is a standard tool_use_id. Its matching tool_result uses the same ID.
- The `TaskOutput` `task_id` (e.g. `bfb6bf6`) is a separate internal ID system.
- **There is no link between these two ID systems in the transcript.** The terminal tracks this mapping in memory at runtime.
- **We don't need the mapping** because:
  - Agent completion is tracked via the Task tool_result arriving (matched by tool_use_id)
  - TaskOutput is hidden entirely from the UI
  - Agent output text is not displayed

### Completion detection

- `Task` tool_use appears → agent is running (show spinner)
- `Task` tool_result arrives (matched by `tool_use_id`) → agent is done (show checkmark)
- `TaskOutput` + its results → completely hidden

## UI Components

### Grouped Agent Card (2+ agents in one message)

```
┌─────────────────────────────────────┐
│  ⑂ Running 3 agents...             │
│                                     │
│  ◎ Explore: Find message sending f… │
│  ✓ Explore: Check settings UI       │
│  ✓ Explore: Review session ordering │
└─────────────────────────────────────┘
```

- Header: branch icon + "Running N agents..." (or "Ran N agents" when all done)
- One line per agent: spinner/checkmark + `{subagent_type}: {description}`
- Description truncated at ~50 chars with ellipsis
- No expand/collapse, no output, no token counts
- Same background styling as ToolUseView (systemGray5 at 0.5 opacity)

### Single Agent Card (1 agent in a message)

Uses existing `ToolUseView` layout:
```
┌─────────────────────────────────┐
│  ⑂ Agent                        │
│  ┌────────────────────────────┐ │
│  │ Explore: Find message flow │ │
│  └────────────────────────────┘ │
│  ✓ Done                         │
└─────────────────────────────────┘
```

- Already handled by ToolUseView with existing Task case (line 289-291 of ToolUseView.swift)
- Input summary: `{subagent_type}: {description}` (already implemented)
- Result hidden (Task is already in `shouldHideResult`)

### Mixed messages

If an assistant message has both Task and non-Task tools (e.g. Bash + 3 Explore agents):
- Non-Task tools render as individual ToolUseView cards
- Task tools are grouped into one AgentGroupView card
- Both appear in the message in source order (agents card placed where the first Task block was)

## Implementation Changes

### Server (Python)

**`voice_server/session_manager.py`:**
- Add `TaskOutput` to `HIDDEN_TOOLS` set (currently: `TaskCreate`, `TaskUpdate`, `TaskGet`, `TaskList`, `TaskStop`)

### iOS (Swift)

**New file: `AgentGroupView.swift`**
- Takes array of `(tool: ToolUseBlock, result: ToolResultBlock?)` pairs
- Renders the grouped card UI described above
- Header shows running/done count
- Each line shows subagent_type + description + spinner/checkmark

**Modified: `SessionView.swift`**
- In the conversation item rendering, detect when multiple Task tool_use blocks appear
- Group consecutive Task blocks into a single `AgentGroupView`
- Non-Task tools before/after the group render as normal `ToolUseView`

**No changes: `ToolUseView.swift`**
- Single-agent case already works correctly with existing Task handling

### Tests

**Server tests:**
- Verify `TaskOutput` is in `HIDDEN_TOOLS`
- Verify TaskOutput tool_use blocks and their results are filtered from content sent to iOS

**iOS unit tests:**
- Test AgentGroupView renders correct agent count in header
- Test AgentGroupView shows description from each Task's input
- Test spinner vs checkmark based on whether tool_result exists
- Test that a message with 1 Task still uses ToolUseView (not AgentGroupView)
- Test mixed messages (Task + non-Task tools) group correctly
