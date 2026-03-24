# voice_server/ Refactor Design

## Problem

`ios_server.py` is ~1930 lines with a ~50-method god-class (`VoiceServer`). The rest of `voice_server/` is flat with no organizational structure.

## Target Structure

```
voice_server/
├─ __init__.py
├─ __main__.py
├─ server.py                    # VoiceServer thin coordinator (~300 lines)
│
├─ handlers/                    # WebSocket message handlers (extracted from VoiceServer)
│   ├─ __init__.py
│   ├─ message_router.py        # handle_message dispatch
│   ├─ input_handler.py         # voice/text input, delivery verification
│   ├─ file_handler.py          # list_directory, read_file, add_project
│   └─ session_lifecycle.py     # new/resume/stop/view session, reset
│
├─ services/                    # Long-running services and business logic
│   ├─ __init__.py
│   ├─ transcript_watcher.py    # TranscriptHandler + reconciliation loop
│   ├─ tts_manager.py           # TTS worker + audio streaming (absorbs tts_utils.py)
│   ├─ session_manager.py       # Project/session browsing
│   ├─ context_tracker.py       # Token usage calculation
│   ├─ permission_handler.py    # Permission state management
│   ├─ usage_checker.py         # OAuth API usage stats
│   └─ usage_parser.py          # Usage response parsing
│
├─ infra/                       # External system interaction
│   ├─ __init__.py
│   ├─ tmux_controller.py       # Tmux session control
│   ├─ pane_parser.py           # Tmux pane parsing
│   ├─ http_server.py           # HTTP server for hooks
│   ├─ setup_check.py           # Startup dependency checks
│   └─ qr_display.py           # QR code display
│
├─ models/                      # Data models
│   ├─ __init__.py
│   ├─ content_models.py        # Pydantic content blocks
│   └─ session_context.py       # Per-session state container
│
├─ hooks/                       # Shell scripts (unchanged)
├─ tests/                       # (unchanged, imports updated)
└─ integration_tests/           # (unchanged, imports updated)
```

## Delegate Pattern

Each extracted module is a standalone class that receives a `VoiceServer` reference:

```python
# server.py
class VoiceServer:
    def __init__(self):
        # ... shared state ...
        self.tts = TTSManager(self)
        self.transcript = TranscriptWatcher(self)
        self.input = InputHandler(self)
        self.sessions = SessionLifecycle(self)
        self.files = FileHandler(self)
        self.router = MessageRouter(self)
```

```python
# handlers/input_handler.py
class InputHandler:
    def __init__(self, server: "VoiceServer"):
        self.server = server

    async def handle_voice_input(self, websocket, data):
        ctx = self.server._get_viewed_context()
        ...
```

Delegates access shared state via `self.server.*`. Uses `TYPE_CHECKING` guards to avoid circular imports.

## Migration Order

Each phase ends with a passing test suite.

### Phase 0: Baseline
Run tests, confirm green.

### Phase 1: Move models (leaves of dependency graph)
- `content_models.py` -> `models/content_models.py`
- `session_context.py` -> `models/session_context.py`
- Update imports in: ios_server.py, session_manager.py, ~6 test files

### Phase 2: Move infra modules (no cross-deps between them)
- `tmux_controller.py` -> `infra/tmux_controller.py`
- `pane_parser.py` -> `infra/pane_parser.py`
- `setup_check.py` -> `infra/setup_check.py`
- `qr_display.py` -> `infra/qr_display.py`
- `http_server.py` -> `infra/http_server.py`
- Update imports in: ios_server.py, http_server.py, ~3 test files

### Phase 3: Move service modules
- `usage_parser.py` -> `services/usage_parser.py`
- `usage_checker.py` -> `services/usage_checker.py`
- `context_tracker.py` -> `services/context_tracker.py`
- `permission_handler.py` -> `services/permission_handler.py`
- `session_manager.py` -> `services/session_manager.py`
- `tts_utils.py` -> held for Phase 4 (absorbed into tts_manager.py)
- Update imports in: ios_server.py, http_server.py, ~8 test files

### Phase 4: Extract from VoiceServer (one at a time, test between each)
1. `services/tts_manager.py` - Easiest. Absorbs tts_utils.py. Reads server.tts_enabled, server.connected_clients, server.cancel_event.
2. `handlers/file_handler.py` - Self-contained. Only needs server.session_manager + websocket sends.
3. `handlers/input_handler.py` - Needs server.tmux, server.tts, viewed context.
4. `services/transcript_watcher.py` - Biggest move (~500 lines). TranscriptHandler + poll_for_session_file + switch_watched_session + reconciliation_loop.
5. `handlers/session_lifecycle.py` - Touches the most shared state. Hardest extraction.
6. `handlers/message_router.py` - Last. Dispatches to all delegates above.

### Phase 5: Rename + entry point
- Rename `ios_server.py` -> `server.py`
- Update `pyproject.toml`: `claude-connect = "voice_server.server:main"`
- Update remaining test imports
- `pipx install --force`

## What Stays in server.py (~300-400 lines)
- `__init__`: shared state, delegate construction
- `handle_client`: WebSocket connection lifecycle
- `start`: server startup, background tasks
- Client tracking: `connected_clients` set management
- Broadcasting: `broadcast_message`, `send_connection_status`, `send_status`
- `_pane_poll_loop`: activity detection loop
- Lightweight project/session browsing handlers (mostly delegate to SessionManager)

## Key Risks
- **Import breakage**: Many test files import from `voice_server.ios_server`. All must be updated.
- **Circular imports**: Delegates import VoiceServer for type hints -> use `TYPE_CHECKING` guards.
- **Test mock paths**: Mocks like `patch('voice_server.ios_server.VoiceServer')` break when modules move.
- **Entry point**: `pyproject.toml` points to `voice_server.ios_server:main` -> must update to `voice_server.server:main`.
