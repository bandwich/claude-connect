# Remote Permission Control Design

Full remote control of Claude Code permission prompts from iOS app.

## Problem

Claude Code shows interactive prompts in the VSCode terminal (permission requests, questions, edit approvals). Currently requires physical access to the Mac to respond. Goal: answer all prompts from the iOS app for hands-free operation.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Claude Code                               │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ PermissionRequest Hook                                       ││
│  │  - Intercepts all permission dialogs                        ││
│  │  - Sends HTTP POST to server with prompt details            ││
│  │  - Blocks up to 3 min waiting for response                  ││
│  │  - Returns allow/deny/input OR falls back to terminal       ││
│  └──────────────────────┬──────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ PostToolUse Hook                                             ││
│  │  - Fires when tool completes (prompt was answered)          ││
│  │  - Notifies server to dismiss prompt in iOS                 ││
│  └──────────────────────┬──────────────────────────────────────┘│
└─────────────────────────┼───────────────────────────────────────┘
                          │ HTTP
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                     Python Server                                │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ POST /permission                                             ││
│  │  - Receives hook payload                                     ││
│  │  - Forwards to iOS via WebSocket                            ││
│  │  - Blocks waiting for iOS response (asyncio.Event)          ││
│  │  - Returns decision JSON to hook                            ││
│  └─────────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ POST /permission_resolved                                    ││
│  │  - Receives PostToolUse notification                        ││
│  │  - Sends permission_resolved to iOS                         ││
│  └─────────────────────────────────────────────────────────────┘│
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ Fallback injection                                           ││
│  │  - If timeout hit, terminal shows prompt                    ││
│  │  - If iOS responds after timeout, inject via AppleScript    ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
                          ▲
                          │ WebSocket
                          ▼
┌─────────────────────────────────────────────────────────────────┐
│                       iOS App                                    │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │ PermissionPromptView                                         ││
│  │  - Displays pending prompt as sheet                         ││
│  │  - Different UI per prompt type                             ││
│  │  - Sends response via WebSocket                             ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

## Hook Configuration

In `.claude/settings.json` or project settings:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "command": "/path/to/permission_hook.sh",
        "timeout": 185000
      }
    ],
    "PostToolUse": [
      {
        "command": "/path/to/post_tool_hook.sh"
      }
    ]
  }
}
```

## Prompt Types

| Type | tool_name | iOS UI |
|------|-----------|--------|
| Bash command | `Bash` | Command text + Allow/Deny |
| File write | `Write` | File path + unified diff + Approve/Reject |
| File edit | `Edit` | File path + unified diff + Approve/Reject |
| User question | `AskUserQuestion` | Question + text field or list picker |
| Task spawn | `Task` | Agent description + Allow/Deny |

## WebSocket Protocol

### Server → iOS: Permission Request

```json
{
  "type": "permission_request",
  "request_id": "uuid-123",
  "prompt_type": "bash|write|edit|question|task",
  "tool_name": "Bash",
  "tool_input": {
    "command": "npm install",
    "description": "Install dependencies"
  },
  "context": {
    "file_path": "/path/to/file.ts",
    "old_content": "...",
    "new_content": "..."
  },
  "question": {
    "text": "Which database?",
    "options": ["PostgreSQL", "SQLite", "MongoDB"]
  },
  "timestamp": 1234567890
}
```

### iOS → Server: Permission Response

```json
{
  "type": "permission_response",
  "request_id": "uuid-123",
  "decision": "allow|deny",
  "input": "user text input if question type",
  "selected_option": 0,
  "timestamp": 1234567890
}
```

### Server → iOS: Permission Resolved

Sent when prompt answered in terminal (detected via PostToolUse hook):

```json
{
  "type": "permission_resolved",
  "request_id": "uuid-123",
  "answered_in": "terminal"
}
```

## Timeout Behavior

- Hook blocks for up to 3 minutes waiting for iOS response
- On timeout: hook returns with "ask" behavior, terminal shows prompt
- iOS app keeps prompt displayed
- If user responds in app after timeout, server injects response into terminal via AppleScript
- Prompt dismisses when `permission_resolved` received (answered from either app or terminal)

## Server Implementation

```python
# Pending permission requests awaiting iOS response
pending_permissions: dict[str, asyncio.Event] = {}
permission_responses: dict[str, dict] = {}

@app.post("/permission")
async def handle_permission(request):
    request_id = str(uuid.uuid4())

    # Send to iOS via WebSocket
    await send_to_ios({
        "type": "permission_request",
        "request_id": request_id,
        ...
    })

    # Wait for response
    event = asyncio.Event()
    pending_permissions[request_id] = event

    try:
        await asyncio.wait_for(event.wait(), timeout=180)
        return permission_responses[request_id]
    except asyncio.TimeoutError:
        # Fall back to terminal, but keep request active
        return {"behavior": "ask"}

async def handle_permission_response(request_id, decision):
    if request_id in pending_permissions:
        # Normal flow - hook still waiting
        permission_responses[request_id] = decision
        pending_permissions[request_id].set()
    else:
        # Late response - inject into terminal
        inject_terminal_response(decision)
```

## iOS UI Components

### PermissionPromptView

Presented as sheet when `permission_request` arrives.

**Bash/Task (Allow/Deny):**
```
┌─────────────────────────────────┐
│  Allow command?                 │
│                                 │
│  npm install                    │
│                                 │
│  ┌───────────┐ ┌───────────┐   │
│  │   Deny    │ │   Allow   │   │
│  └───────────┘ └───────────┘   │
└─────────────────────────────────┘
```

**Write/Edit (Diff view):**
```
┌─────────────────────────────────┐
│  Edit: src/utils.ts             │
│  ─────────────────────────────  │
│  - const foo = 1;               │  (red)
│  + const foo = 2;               │  (green)
│    const bar = 3;               │  (gray)
│                                 │
│  ┌───────────┐ ┌───────────┐   │
│  │  Reject   │ │  Approve  │   │
│  └───────────┘ └───────────┘   │
└─────────────────────────────────┘
```

**AskUserQuestion (text input):**
```
┌─────────────────────────────────┐
│  What should the function name  │
│  be?                            │
│                                 │
│  ┌─────────────────────────┐   │
│  │ calculateTotal          │   │
│  └─────────────────────────┘   │
│           ┌───────────┐         │
│           │   Submit  │         │
│           └───────────┘         │
└─────────────────────────────────┘
```

**AskUserQuestion (multiple choice):**
```
┌─────────────────────────────────┐
│  Which database should we use?  │
│                                 │
│  ○ PostgreSQL                   │
│  ○ SQLite                       │
│  ○ MongoDB                      │
│                                 │
│           ┌───────────┐         │
│           │   Submit  │         │
│           └───────────┘         │
└─────────────────────────────────┘
```

## Components to Build

### Hook Scripts (bash)

1. `permission_hook.sh` — PermissionRequest handler
   - Reads JSON from stdin
   - POSTs to `http://localhost:8765/permission`
   - Outputs response JSON
   - Exit 0 on success, exit 2 to fall back

2. `post_tool_hook.sh` — PostToolUse handler
   - POSTs to `http://localhost:8765/permission_resolved`
   - Exit 0

### Server Additions (ios_server.py)

1. `POST /permission` endpoint
2. `POST /permission_resolved` endpoint
3. WebSocket handler for `permission_response`
4. Late response injection via AppleScript

### iOS Additions

1. `PermissionRequest` model
2. `PermissionPromptView` — sheet with 4 variants
3. `DiffView` — unified diff renderer (red/green lines)
4. WebSocket handling for new message types

## Out of Scope (MVP)

- Push notifications for prompts
- Prompt history/queue (one active prompt at a time)
- Fancy diff syntax highlighting
- Multiple simultaneous prompts
