# Multi-Session Support Design

Support multiple concurrent Claude Code sessions started from the iOS app, with the ability to switch between them without killing background sessions.

## Core Model

Each active session is a self-contained unit with its own tmux session, transcript watcher, pane poller, context tracker, and permission/question request queue. The server holds a dict of these: `active_sessions: dict[str, SessionContext]`. Hard cap of `MAX_ACTIVE_SESSIONS = 5`, defined as a single constant.

### Session Lifecycle

- **Start/resume** from iOS creates the tmux session and `SessionContext`, starts watching
- **Back button** navigates away — everything keeps running
- **Stop** (ellipsis menu in session view nav bar) kills the tmux session and removes the `SessionContext`
- **Server shutdown** kills all tmux sessions as cleanup
- **WebSocket disconnect** leaves sessions running; on reconnect, app syncs which sessions are still active

### Tmux Naming

Each session gets its own tmux session named `claude-connect_<session_id>`. No more hardcoded single session name.

## Server Architecture

### New `SessionContext` Class

Bundles all per-session state currently scattered across `VoiceServer` fields:

- `session_id`, `folder_name`, `transcript_path`
- `TranscriptHandler` instance
- `watchdog.Observer` instance
- Reconciliation loop `asyncio.Task`
- Activity state (from pane polling)
- Context tracking data
- Pending permission/question requests keyed by `request_id`

### `VoiceServer` Changes

- `active_sessions: dict[str, SessionContext]` replaces `active_session_id`, `active_folder_name`, `transcript_path`, and other single-session fields
- `viewed_session_id: Optional[str]` tracks which session the iOS app is currently looking at (TTS only plays for the viewed session)
- `_reset_session_state()` becomes `_stop_session(session_id)` — tears down one session's resources
- New/resume adds a `SessionContext` to the dict (checks `MAX_ACTIVE_SESSIONS` first)
- Pane polling loop iterates all active sessions

### `TmuxController` Changes

- Remove hardcoded `SESSION_NAME` constant
- All methods take a `session_name` parameter
- Helper: `session_name_for(session_id) -> str` returns `claude-connect_<session_id>`
- New `cleanup_all()` method for server shutdown that kills all `claude-connect_*` sessions

### `PermissionHandler` Changes

- `pending_requests: dict[request_id, session_id]` replaces `latest_request_id`
- Route responses by `request_id` lookup — no need to know which session is "active"

### Permission Routing

Each Claude Code process gets a `CLAUDE_CONNECT_SESSION_ID` environment variable set when the tmux session is created. Hook scripts (`permission_hook.sh`, `question_hook.sh`, `post_tool_hook.sh`) read this env var and include it in their HTTP POST to the server. The server uses it to route the request to the correct `SessionContext`.

## iOS App Changes

### Sessions List (`SessionsListView`)

- Green dot on the right side of any session with a running tmux process
- Server includes `active_session_ids: [str]` in the `sessions_list` response
- Tapping an active session switches to it (no kill); tapping an inactive session resumes it (starts new tmux process)

### Session View (`SessionView`)

- Ellipsis menu (`…`) button in the nav bar, right-aligned outside the existing content
- Existing nav bar content (back, breadcrumb, context indicator, branch) is width-constrained to leave space for the ellipsis
- Ellipsis dropdown contains "Stop Session" as a destructive-styled menu item
- Back button navigates away without stopping the session
- When viewing, server sets `viewed_session_id` — TTS and activity updates flow for this session only

### Nav Bar Layout

The `CustomNavigationBarInline` top HStack becomes:

```
HStack {
    [existing HStack content]  // constrained to leave space
    Menu {
        Button("Stop Session", role: .destructive) { ... }
    } label: {
        Image(systemName: "ellipsis")
    }
}
```

### WebSocket Protocol Changes

New messages:

| Direction | Type | Payload |
|-----------|------|---------|
| iOS → Server | `stop_session` | `{"type": "stop_session", "session_id": "..."}` |
| Server → iOS | `session_stopped` | `{"type": "session_stopped", "session_id": "..."}` |
| iOS → Server | `view_session` | `{"type": "view_session", "session_id": "..."}` — tells server which session to send TTS for |

Modified messages:

| Type | Change |
|------|--------|
| `sessions_list` | Add `active_session_ids: [str]` field |
| `open_session` / `resume_session` | No longer kills other sessions |
| Permission/question HTTP POSTs | Include `session_id` field from env var |

Existing per-session messages (`assistant_response`, `activity_status`, `permission_request`, etc.) already carry `session_id` — the app filters by viewed session.

### On Reconnect

App sends `list_sessions`, receives which sessions have green dots. No special resync beyond what already exists.

## Risk Assessment

### Riskiest Assumption

Permission hook routing. Today one Claude Code process talks to one HTTP handler. With multiple processes sending permission requests concurrently, the `CLAUDE_CONNECT_SESSION_ID` env var must flow correctly through: tmux env → Claude Code process → hook script → HTTP POST → server routing.

### Early Verification

Get two tmux sessions running with distinct env vars, trigger a permission request from each, confirm the HTTP server receives the correct session ID on both. Testable before any iOS changes.

### Secondary Risk

Resource usage with 5 concurrent sessions (5 watchdog observers, 5 polling loops, 5 reconciliation loops). Likely fine but worth monitoring.

### Not Risky

iOS changes are mostly additive — green dot, ellipsis menu, filtering by session ID. The sessions list and session view already exist.
