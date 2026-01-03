# Sync Sessions Feature Design

## Overview

Add the ability to view and manage Claude Code sessions from the iOS voice app. Users can browse projects, see session history, and switch between sessions - all controlled from the phone.

## Current State

- iOS app does STT, sends text to Python server via WebSocket
- Server pastes text into VS Code (via AppleScript) and watches transcript files
- Claude responses are extracted, converted to TTS, streamed back to app
- Single session only, hardcoded to most recent transcript file

## Feature Goals

- View list of projects
- View list of sessions within a project
- See message history for each session
- Switch between projects/sessions from the app
- Start new sessions

## Architecture

### Data Source

Claude stores sessions in readable files - no CLI scraping needed:

```
~/.claude/projects/
├── -Users-aaron-Desktop-max/           # project folder (path-encoded)
│   ├── 05ae5906-....jsonl              # session files (UUID)
│   ├── 0c919d88-....jsonl
│   └── ...
├── -Users-aaron-Desktop-code-unmute/
│   └── ...
```

Each `.jsonl` file contains:
- `sessionId` - UUID
- `timestamp` - when message was sent
- `message.role` - "user" or "assistant"
- `message.content` - the message content

### VS Code Integration

**vscode-remote-control extension** replaces AppleScript:
- Extension runs WebSocket server on `localhost:3710`
- Python server connects and sends commands as JSON
- Direct command execution, no clipboard/keystroke simulation

Commands needed:
| Action | VS Code Command |
|--------|-----------------|
| Open new terminal | `workbench.action.terminal.new` |
| Send text to terminal | `workbench.action.terminal.sendSequence` |
| Kill terminal | `workbench.action.terminal.kill` |

Project switching uses CLI: `code /path/to/project`

### App Navigation

```
Projects List → Session List → Session View
     ↓              ↓              ↓
  N projects    10 recent      message history
  (last path    sessions       + voice input
   component)   per project    + TTS playback
```

### Server API

New WebSocket message types from iOS app:

```json
// List projects
{"type": "list_projects"}

// Response
{"type": "projects", "projects": [
  {"path": "/Users/aaron/Desktop/max", "name": "max", "session_count": 47},
  {"path": "/Users/aaron/Desktop/code-unmute", "name": "unmute", "session_count": 12}
]}

// List sessions for a project
{"type": "list_sessions", "project_path": "/Users/aaron/Desktop/max"}

// Response
{"type": "sessions", "sessions": [
  {"id": "05ae5906-...", "title": "First message preview...", "timestamp": 1735812000, "message_count": 24},
  ...
]}

// Get session history
{"type": "get_session", "session_id": "05ae5906-..."}

// Response
{"type": "session_history", "messages": [
  {"role": "user", "content": "...", "timestamp": 1735812000},
  {"role": "assistant", "content": [...], "timestamp": 1735812005},
  ...
]}

// Open/switch to a session
{"type": "open_session", "project_path": "/Users/aaron/Desktop/max", "session_id": "05ae5906-..."}

// Create new session
{"type": "new_session", "project_path": "/Users/aaron/Desktop/max"}

// Create new project (mkdir + open in VS Code + start Claude)
{"type": "add_project", "name": "my-new-project"}
// 1. Creates ~/Desktop/code/my-new-project
// 2. Opens folder in VS Code (may trigger "Trust folder" popup - user dismisses manually)
// 3. Opens terminal and runs `claude` to start a session
// 4. Project now appears in ~/.claude/projects/ and can be read by app

// Close current session (Ctrl+C)
{"type": "close_session"}
```

### Configuration

```python
PROJECTS_BASE_PATH = os.path.expanduser("~/Desktop/code")
```

New projects are created here. Existing projects are discovered from `~/.claude/projects/`.

### iOS App Screens

**1. ProjectsListView**
- List of projects (displayed as last path component: "max", "unmute", etc.)
- Session count badge
- Tap → navigate to SessionsListView
- "Add Project" button → prompt for name → creates project

**2. SessionsListView**
- List of 10 most recent sessions for selected project
- Each row: title (first user message preview), timestamp, message count
- Tap → navigate to SessionView
- "New Session" button

**3. SessionView** (enhanced current ContentView)
- Message history (scrollable)
- Voice input button
- Connection status
- Back navigation to session list

### State Management

Server tracks:
- `current_project_path` - which project is active
- `current_session_id` - which session is active
- `vscode_ws` - WebSocket connection to vscode-remote-control

App tracks:
- Navigation state (which screen)
- Selected project/session
- Message history cache

## Dependencies

- **vscode-remote-control extension** - Install from VS Code marketplace
- **websocket-client** (Python) - For connecting to VS Code extension

## Implementation Order

1. Install vscode-remote-control extension, verify WebSocket connectivity
2. Add VSCodeController class to server (WebSocket client for VS Code)
3. Add SessionManager class to server (read projects/sessions from disk)
4. Add new WebSocket message handlers to server (list_projects, list_sessions, get_session, open_session, new_session, add_project, close_session)
5. Create ProjectsListView in iOS app (with Add Project)
6. Create SessionsListView in iOS app (with New Session)
7. Enhance ContentView → SessionView with message history
8. Wire up navigation and state management
9. Replace AppleScript paste with VSCodeController.sendSequence
10. Test full flow: browse projects → select session → voice input → response

## Open Questions

- Should closing a session warn if Claude is mid-response?
- How to handle session that doesn't exist anymore (deleted)?
- Cache session lists or always read fresh from disk?
