# Voice Server

## How It Works

VoiceServer (ios_server.py) is the central orchestrator. It owns:
- WebSocket server (port 8765) for iOS communication
- TranscriptHandler + watchdog Observer for streaming Claude's output
- TTS queue (Kokoro, serialized — one message in-flight, drains stale entries)
- Activity poller (1s interval, tmux pane parsing via pane_parser.py)
- Reconciliation loop (3s interval, catches watchdog misses)
- HTTP server (port 8766) for Claude Code hooks

## Transcript Pipeline

This is the core data flow — how Claude's output reaches iOS:

1. watchdog Observer detects modification to the active `.jsonl` transcript file
2. TranscriptHandler.on_modified() fires (in watchdog's thread, NOT the event loop)
3. Acquires lock → reads lines from `processed_line_count` onward → updates count → releases lock
4. Parses each JSON line: filters by role (assistant/user), builds Pydantic content blocks (TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock)
5. Schedules async callbacks OUTSIDE the lock via `run_coroutine_threadsafe()` — this is critical to prevent deadlock
6. VoiceServer broadcasts content blocks to all connected iOS clients + queues text for TTS

**Reconciliation**: Every 3s, compares `processed_line_count` vs actual file line count. If there's a gap (watchdog missed an event), calls `reconcile()` to extract and broadcast the missed content. This is the reliability backstop.

**Hidden tools**: TaskCreate, TaskUpdate, TaskGet, TaskList, TaskStop, TaskOutput are tracked by ID and filtered from iOS display. Agent tool results have metadata (agentId, usage tags) stripped.

**Synthetic messages**: Assistant messages with `model == "<synthetic>"` are Claude Code internal messages (e.g. "No response requested") and are filtered out before reaching iOS.

## Threading Model

- watchdog runs in its own thread — all its callbacks must bridge to asyncio via `run_coroutine_threadsafe()`
- Lock (`threading.Lock`) protects only `processed_line_count` and `expected_session_file`
- Everything else is asyncio on the main event loop
- TTS generation runs in the default executor (thread pool) since Kokoro is blocking

## Session Lifecycle

1. `_reset_session_state()` — clears active_session_id, folder_name, transcript path, stops watcher/reconciliation, clears pending permissions
2. Create or resume tmux session via TmuxController
3. For new sessions: snapshot existing session file IDs in `_pending_session_snapshot`
4. File detection is deferred — the new `.jsonl` doesn't exist yet when tmux starts
5. On first voice input: `_resolve_pending_session()` diffs current files vs snapshot to find the new one
6. For resumed sessions: set `processed_line_count` to current file length (only process NEW content)

## Key State

| Field | What it tracks | Reset |
|-------|---------------|-------|
| `active_session_id` | Which session is open in tmux | `_reset_session_state()` |
| `active_folder_name` | Project folder (encoded path) | `_reset_session_state()` |
| `transcript_path` | File being watched | `_reset_session_state()` |
| `processed_line_count` | Lines already sent to iOS | `set_session_file()` |
| `waiting_for_response` | Prevents concurrent terminal sends | Set to True on send, never explicitly cleared |
| `_pending_session_snapshot` | Session IDs before new session created | Cleared after file detected |
| `last_voice_input` | Last text sent, for echo dedup | Cleared after match |

## Permission Flow

1. Claude Code PermissionRequest hook → `permission_hook.sh` POSTs to HTTP server
2. `http_server.py` generates UUID `request_id`, registers in PermissionHandler (asyncio.Event), broadcasts to iOS
3. iOS shows PermissionCardView, user taps approve/deny
4. iOS sends `permission_response` → VoiceServer resolves the Event → HTTP handler returns decision to hook
5. If 180s timeout: returns `{"behavior": "ask"}` (falls back to terminal), marks request as timed out
6. PostToolUse hook: if request timed out AND iOS responds late, injects answer into terminal via tmux

## Question Flow

Same pattern as permissions but via `/question` endpoint. Questions are extracted one-at-a-time from AskUserQuestion tool input. iOS shows option buttons or text input. Answer returns as deny+reason so Claude receives it without showing terminal UI.

## Echo Deduplication

When iOS sends voice/text input, server saves it in `last_voice_input`. When the transcript shows a matching user message, server skips broadcasting it (the app already knows what it sent). Cleared after match.

## Activity State Detection

pane_parser.py reads tmux pane output (last ~15 lines) every 1s:
- Spinner chars (✢✻✽✳·✶) → `thinking`
- ⏺ + "-ing" verb → `tool_active` (full action phrase extracted as detail, e.g. "Searching for 1 pattern...")
- "Esc to cancel · Tab to amend" → `waiting_permission`
- Otherwise → `idle`

Only broadcasts on state change to reduce WebSocket traffic.

## Module Relationships

```
ios_server.py (VoiceServer)
├── tmux_controller.py     — subprocess wrapper for tmux commands
├── session_manager.py     — disk-based project/session inventory (~/.claude/projects/)
├── permission_handler.py  — request registration, Event-based waiting, timeout tracking
├── http_server.py         — aiohttp server for hook endpoints (/permission, /question, /permission_resolved)
├── content_models.py      — Pydantic models for content blocks
├── context_tracker.py     — token usage from transcript's last usage field
├── tts_utils.py           — Kokoro TTS pipeline (24kHz, voice "af_heart")
├── pane_parser.py         — regex-based tmux pane state detection
├── usage_checker.py       — OAuth token from Keychain → Anthropic API for quotas
├── usage_parser.py        — maps API response to session/weekly percentages
├── setup_check.py         — interactive dependency checking at startup
└── qr_display.py          — QR code generation + get_local_ip + startup banner
```

## Conventions

- Debug logging uses `[LABEL]` prefixes: `[SYNC]`, `[TTS]`, `[PERM]`, `[RECONCILE]`
- `sys.dont_write_bytecode = True` prevents __pycache__ staleness
- Path comparison uses `os.path.realpath()` (handles /tmp vs /private/tmp on macOS)
- Project path encoding is lossy: both `/` and `_` become `-`. SessionManager uses session CWD as source of truth.
- Multi-line tmux input triggers paste confirmation — controller sends two Enters with 0.3s sleep
