# Question Prompt Design

## Problem

When Claude calls AskUserQuestion with multiple-choice options, the iOS app shows only a text input field instead of option buttons. The feature was built assuming Claude Code sends a `question` field via the PermissionRequest hook, but AskUserQuestion is not a permission-gated tool — it never triggers PermissionRequest hooks.

## Solution

Intercept AskUserQuestion via a **PreToolUse hook** before Claude Code shows its terminal UI. Forward the question to the iOS app, collect the user's answer, and return it to Claude via `permissionDecision: "deny"` with the answer in `permissionDecisionReason`.

## Verified Assumptions

- **PreToolUse hooks fire for AskUserQuestion** — confirmed via test
- **Deny+reason feeds the answer to Claude** — confirmed: Claude receives the answer and proceeds without showing terminal UI
- **tool_input structure** — confirmed from transcripts:

```json
{
  "tool_input": {
    "questions": [{
      "question": "Which database?",
      "header": "Scope",
      "options": [
        {"label": "PostgreSQL", "description": "Fast relational DB"},
        {"label": "SQLite", "description": "Embedded, zero config"}
      ],
      "multiSelect": false
    }]
  }
}
```

## Architecture

### Data Flow

```
Claude Code
  │ PreToolUse fires for AskUserQuestion
  ▼
question_hook.sh (new hook script)
  │ POST /question to HTTP server
  ▼
http_server.py /question endpoint
  │ Extracts questions[0], broadcasts to iOS
  ▼
iOS WebSocket receives question_prompt message
  │ Sets inputBarMode = .questionPrompt(...)
  │ Shows option buttons (label + description)
  ▼
User taps option (or types free-text answer)
  │ iOS sends question_response via WebSocket
  ▼
Server returns answer to HTTP response
  │ Hook receives answer
  ▼
question_hook.sh outputs deny decision with answer
  │ permissionDecisionReason = "User answered: ..."
  ▼
Claude receives answer, continues without terminal UI
```

### Multiple Questions

When `questions` array has multiple items, show one question at a time. After the user answers the first, show the next. Collect all answers before returning to the hook. The hook blocks until all questions are answered.

### Timeout / Dismiss

- Hook timeout: 180s (same as permission hook)
- iOS shows dismiss/X button to interrupt Claude
- Dismiss sends a deny with reason "User dismissed the question"
- On timeout, hook exits with code 2 (falls back to terminal UI)

## Components

### New Files

- `voice_server/hooks/question_hook.sh` — PreToolUse hook for AskUserQuestion, same pattern as permission_hook.sh

### Server Changes

**http_server.py:**
- New `POST /question` endpoint — receives question data, broadcasts to iOS, waits for response
- Response format: `{"permissionDecision": "deny", "permissionDecisionReason": "User answered: ..."}`

**permission_handler.py** (or new question_handler.py):
- Reuse existing request/response pattern (generate ID, register, wait, cleanup)

### iOS Changes

**Models:**
- New `QuestionPrompt` struct: header, question text, options (label + description), multiSelect flag, requestId
- Update `InputBarMode.questionPrompt` to use `QuestionPrompt` instead of `PermissionRequest`
- New `question_response` WebSocket message type

**WebSocketManager:**
- Handle incoming `question_prompt` message → set `inputBarMode = .questionPrompt(...)`
- Handle `question_resolved` message → reset to `.normal`
- `sendQuestionResponse(requestId:, answer:)` method

**SessionView input bar:**
- Question prompt UI: header text, question text, option buttons with label (bold) + description (gray), dismiss X button
- For no options: text input field (existing behavior)
- For multiSelect: not needed initially (show one at a time)
- After answering, return to `.normal`

### Settings Change

Add PreToolUse hook to `~/.claude/settings.json`:

```json
"PreToolUse": [
  {
    "matcher": "AskUserQuestion",
    "hooks": [
      {
        "type": "command",
        "command": "/path/to/max/voice_server/hooks/question_hook.sh",
        "timeout": 185
      }
    ]
  }
]
```

### Cleanup

- Remove `"question"` field handling from `http_server.py` handle_permission (dead code)
- Remove `PermissionQuestion` struct from iOS (unused)
- Remove question-related branches from `PermissionCardView` that reference `request.question?.options`

## WebSocket Protocol

### Server → iOS
```json
{
  "type": "question_prompt",
  "request_id": "q_abc123",
  "header": "Scope",
  "question": "Which bugs do you want in this plan?",
  "options": [
    {"label": "#2, #4, #5 (known fixes)", "description": "Quick wins."},
    {"label": "All 6", "description": "Full scope."}
  ],
  "multi_select": false,
  "question_index": 0,
  "total_questions": 1
}
```

### iOS → Server
```json
{
  "type": "question_response",
  "request_id": "q_abc123",
  "answer": "#2, #4, #5 (known fixes)"
}
```

Or for dismiss:
```json
{
  "type": "question_response",
  "request_id": "q_abc123",
  "dismissed": true
}
```

### Server → iOS (after all questions answered)
```json
{
  "type": "question_resolved",
  "request_id": "q_abc123"
}
```

## Hook Output

### User answered
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "The user already answered via the iOS app.\nQ: \"Which bugs?\"\nA: \"#2, #4, #5 (known fixes)\"\nProceed with this answer. Do not ask again."
  }
}
```

### User dismissed
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "The user dismissed this question from the iOS app. Do not ask again — proceed with your best judgment or ask a different question."
  }
}
```

### Timeout (fall back to terminal)
Exit code 2 — Claude Code shows its normal terminal UI.
