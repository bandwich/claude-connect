# Claude Code Transcript Format

Each transcript is a JSONL file (one JSON object per line).

## Top-level Message Types

| Type | Description |
|------|-------------|
| `user` | User input message |
| `assistant` | Claude's response (may be streamed across multiple lines) |
| `progress` | Hook/tool progress events during execution |
| `file-history-snapshot` | File state snapshots for undo/restore |
| `system` | System events (e.g., turn duration) |

## Common Fields (all message types)

```
parentUuid    - links to parent message (conversation threading)
uuid          - unique message ID
timestamp     - ISO 8601 timestamp
sessionId     - session identifier
type          - message type (see table above)
isSidechain   - whether this is on a side branch
cwd           - working directory
version       - Claude Code version
gitBranch     - active git branch
```

## `user` Messages

Extra fields: `userType` ("external"), `permissionMode`, `todos`

`message.content` is typically a string (the user's text).

## `assistant` Messages

Extra fields: `requestId`

`message` follows the Anthropic API response format:
- `message.role`: "assistant"
- `message.model`: model ID
- `message.stop_reason`: "end_turn", "tool_use", null (streaming)
- `message.usage`: token counts (input, output, cache)

### Content Block Types

| Type | Description |
|------|-------------|
| `text` | Plain text response |
| `thinking` | Extended thinking block (has `thinking` + `signature` fields) |
| `tool_use` | Tool invocation (has `name`, `input`, `id`) |
| `tool_result` | Tool output (has `tool_use_id`, `content`) |

### Tool Names Observed

Read, Write, Edit, Glob, Grep, Bash, TaskCreate, TaskUpdate, Skill

## `progress` Messages

Extra fields: `data`, `parentToolUseID`, `toolUseID`

`data.type` is `hook_progress` — tracks hook execution during tool use.

## `file-history-snapshot` Messages

Fields: `messageId`, `snapshot` (contains `trackedFileBackups`), `isSnapshotUpdate`

Used for file versioning/undo support.

## `system` Messages

Fields: `slug`, `subtype`, `durationMs`, `isMeta`

Observed subtype: `turn_duration` — records how long a turn took.
