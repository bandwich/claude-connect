## CRITICAL RULES

**MUST FOLLOW - NO EXCEPTIONS:**

When running ANY tests (server tests, E2E tests, unit tests) or long-running commands:
- ALWAYS use `run_in_background: true` parameter
- NO text before the tool call
- NO text after the tool call
- NO timeout parameter
- NO piping through head/tail/tee or other commands
- Check results later with `tail /path/to/output_file`

WRONG:
```
"Let me run the tests."
[Bash command without run_in_background]
```

WRONG:
```
[Bash with: ./run_tests.sh 2>&1 | head -100]
```

RIGHT:
```
[Bash tool call ONLY with run_in_background: true, nothing else in response]
```

---

# Claude Connect

Hands-free voice interaction with Claude Code via iOS app + Mac server.

## Architecture

```
iPhone App                         Mac Server
├─ Speech Recognition              ├─ WebSocket Server (port 8765)
├─ WebSocket Client ──────────────►├─ Receives voice input
├─ Audio Player ◄──────────────────├─ Streams TTS audio (Kokoro)
├─ Conversation View               ├─ Transcript file watching
│  (text, tools, user msgs)        │  (assistant + user extraction)
├─ Session/Project Browser         ├─ tmux session management
├─ File Browser + Image Viewer     ├─ File serving (text + images)
├─ Permission Approval UI          ├─ HTTP server for hooks (port 8766)
└─ Usage Stats Display             └─ Session history + context tracking
```

## Project Structure

```
voice_server/                  # Python server
├─ server.py                  # Main WebSocket server (VoiceServer coordinator)
├─ tts_utils.py               # Legacy re-export (tests import from here)
├─ models/
│   ├─ content_models.py      # Pydantic models for content blocks
│   └─ session_context.py     # Per-session state container (SessionContext)
├─ services/
│   ├─ transcript_watcher.py  # TranscriptHandler (watchdog) + poll_for_session_file
│   ├─ tts_manager.py         # TTS queue, generation, audio streaming
│   ├─ session_manager.py     # Disk-based project/session inventory
│   ├─ permission_handler.py  # Permission request/response handling
│   ├─ context_tracker.py     # Token usage calculation from transcripts
│   ├─ usage_checker.py       # On-demand usage stats via OAuth API
│   └─ usage_parser.py        # Parser for OAuth API response
├─ handlers/
│   ├─ file_handler.py        # File browsing, reading, project creation
│   └─ input_handler.py       # Voice/text input, delivery verification
├─ infra/
│   ├─ tmux_controller.py     # Tmux session control (parameterized by session name)
│   ├─ http_server.py         # HTTP server for Claude Code hooks (port 8766)
│   ├─ pane_parser.py         # Tmux pane parsing for activity state detection
│   ├─ setup_check.py         # Interactive dependency checking at startup
│   └─ qr_display.py          # QR code generation for iOS connection
├─ hooks/
│   ├─ permission_hook.sh     # PermissionRequest hook → POST to HTTP server
│   ├─ question_hook.sh       # PreToolUse hook → forward AskUserQuestion to iOS
│   └─ post_tool_hook.sh      # PostToolUse hook → dismiss stale prompts
├─ integration_tests/          # E2E test server infrastructure
│   ├─ test_server.py         # Modified server for E2E tests
│   ├─ mock_transcript.py     # Test transcript fixture generation
│   ├─ test_config.py         # Test environment config (ports, paths)
│   └─ generate_test_audio.py # Pre-generate test WAV files
└─ tests/                     # pytest test suite (~315 tests)

ios-voice-app/ClaudeVoice/     # iOS app (Swift/SwiftUI)
├─ ClaudeVoiceApp.swift       # @main entry point, auto-connect on launch
├─ Models/
│   ├─ AssistantContent.swift # Content block types (text, tool_use, etc.)
│   ├─ ConnectionState.swift  # WebSocket connection states
│   ├─ ClaudeOutputState.swift # Claude activity: idle/thinking/usingTool/speaking
│   ├─ ContextStats.swift     # Context window usage stats
│   ├─ FileModels.swift       # File browser response models
│   ├─ InputBarMode.swift     # Input bar state: normal/permissionPrompt/syncing/etc.
│   ├─ Message.swift          # WebSocket message types (all send/receive structs)
│   ├─ PermissionRequest.swift # Permission/question request/response models
│   ├─ Project.swift          # Claude Code project model
│   ├─ Session.swift          # Session model, ConversationItem enum, AgentInfo
│   ├─ UsageStats.swift       # Weekly/session quota stats
│   └─ VoiceState.swift       # Voice interaction states
├─ Services/
│   ├─ WebSocketManager.swift # WebSocket client, state management, message routing
│   ├─ SpeechRecognizer.swift # iOS Speech framework wrapper
│   ├─ AudioPlayer.swift      # Chunked TTS audio playback via AVAudioEngine
│   └─ QRCodeValidator.swift  # QR code URL validation
├─ Views/
│   ├─ SessionView.swift      # Main conversation view (largest, ~50KB)
│   ├─ ToolUseView.swift      # Tool use/result display with expand/collapse
│   ├─ AgentGroupView.swift   # Agent execution status cards (running/completed)
│   ├─ PermissionCardView.swift # Permission approval + question prompt cards
│   ├─ ProjectsListView.swift # Project browser
│   ├─ ProjectDetailView.swift # Project detail with sessions + files tabs
│   ├─ FilesView.swift        # File tree browser (lazy-loaded directories)
│   ├─ FileView.swift         # File viewer (text + images with caching)
│   ├─ DiffView.swift         # Diff viewer for Edit results
│   ├─ ContentView.swift      # Root navigation view
│   ├─ SettingsView.swift     # Connection settings + usage stats
│   ├─ QRScannerView.swift    # Camera-based QR scanner
│   ├─ CustomNavigationBar.swift # Reusable nav bar component
│   └─ VoiceIndicator.swift   # Recording animation indicator
└─ Utils/
    ├─ TimeFormatter.swift    # Relative time strings ("5 minutes ago")
    └─ SwipeBackModifier.swift # iOS swipe-back gesture support

scripts/
└─ cleanup_transcripts.py     # Delete Claude transcripts with ≤2 messages

docs/                          # Design docs and implementation plans
└─ plans/                     # Date-stamped feature plans (33 directories)

tests/e2e_support/            # E2E test utilities
└─ server_manager.py          # Server lifecycle for tests
```

## Commands

### Running

```bash
# Global command (installed via pipx)
claude-connect
```

Server displays QR code on startup for iOS app to scan.

**After changing server code**, reinstall so `claude-connect` picks up changes:
```bash
pipx install --force /Users/aaron/Desktop/max
```

### Testing

See [`tests/TESTS.md`](tests/TESTS.md) for full test documentation.

```bash
# 1. Server tests (Python)
cd voice_server/tests && ./run_tests.sh

# 2. iOS unit tests
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests

# 3. iOS E2E tests (may timeout, needs simulator)
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh
```

**Run specific E2E test suite:**
```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2EPermissionTests
```

### Building iOS

```bash
# Clean build (only required after adding new files)
cd ios-voice-app/ClaudeVoice
xcodebuild clean -target ClaudeVoice

# Build for simulator
xcodebuild build -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# Build and install on device (use -target, not -scheme, for device builds)
# Step 1: Build
xcodebuild -target ClaudeVoice -sdk iphoneos build
# Step 2: List devices, read the device ID from output
xcrun devicectl list devices
# Step 3: Install using the device ID from step 2
xcrun devicectl device install app --device "<DEVICE_ID>" \
  ios-voice-app/ClaudeVoice/build/Release-iphoneos/ClaudeVoice.app
```

### Utilities

```bash
# Clean up empty/stub Claude transcripts (≤2 messages)
python3 scripts/cleanup_transcripts.py
```

### Debugging

```bash
# Kill server on port 8765
lsof -ti :8765 | xargs kill -9

# View logs
tail -f /tmp/e2e_server.log       # Server logs during E2E tests
tail -f /tmp/e2e_test.log         # E2E test runner output
tail -f /tmp/websocket_debug.log  # iOS WebSocket debug logs

# Simulator management
xcrun simctl shutdown all
xcrun simctl list
```

### Analyzing Test Failures

```bash
# Find E2E test failure reason
grep -A10 "XCTAssert\|failed\|Failed" /tmp/e2e_test.log

# List test result bundles
ls -la ~/Library/Developer/Xcode/DerivedData/ClaudeVoice-*/Logs/Test/

# Extract test summary from xcresult
xcrun xcresulttool get --path <path-to.xcresult> --format json | python3 -m json.tool | head -100
```

## Permission Hooks Configuration

To enable remote permission control from the iOS app, add hooks to your Claude Code settings.

**Location:** `~/.claude/settings.json` or project `.claude/settings.json`

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/max/voice_server/hooks/permission_hook.sh",
            "timeout": 185
          }
        ]
      }
    ],
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
    ],
    "PostToolUse": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/max/voice_server/hooks/post_tool_hook.sh"
          }
        ]
      }
    ]
  }
}
```

**Environment Variables:**
- `VOICE_SERVER_URL`: Override server URL (default: `http://localhost:8766`)
- `CLAUDE_CONNECT_SESSION_ID`: Set automatically per tmux session for permission/question routing

**Ports Used:**
- WebSocket: 8765 (iOS app connection)
- HTTP: 8766 (Hook requests from Claude Code)

**How It Works (Permissions):**
1. Claude Code triggers PermissionRequest hook before showing a prompt
2. Hook POSTs to voice server, which forwards to iOS app via WebSocket
3. User approves/denies on iOS, response flows back to hook
4. Hook outputs decision JSON, Claude Code proceeds accordingly
5. If timeout (3 min), falls back to terminal prompt with late-response injection

**How It Works (Questions):**
1. Claude Code triggers PreToolUse hook when AskUserQuestion is called
2. Hook POSTs to `/question` endpoint, which broadcasts question to iOS
3. iOS shows option buttons (or text input), user answers
4. Answer flows back through WebSocket → HTTP → hook as a deny+reason
5. Claude receives the answer and proceeds without showing terminal UI

## WebSocket Protocol

### iOS → Server
```
voice_input          {"type": "voice_input", "text": "...", "timestamp": ...}
user_input           {"type": "user_input", "text": "...", "images": [...], "timestamp": ...}
set_preference       {"type": "set_preference", "tts_enabled": true|false}
stop_audio           {"type": "stop_audio"}
resync_request       {"type": "resync_request", "last_seq": N}
list_projects        {"type": "list_projects"}
list_sessions        {"type": "list_sessions", "folder_name": "..."}
open_session         {"type": "open_session", "folder_name": "...", "session_id": "..."}
new_session          {"type": "new_session", "folder_name": "..."}
resume_session       {"type": "resume_session", "folder_name": "...", "session_id": "..."}
close_session        {"type": "close_session"}
stop_session         {"type": "stop_session", "session_id": "..."}
view_session         {"type": "view_session", "session_id": "..."}
add_project          {"type": "add_project", "name": "..."}
list_directory       {"type": "list_directory", "path": "..."}
read_file            {"type": "read_file", "path": "..."}
usage_request        {"type": "usage_request"}
permission_response  {"type": "permission_response", "request_id": "...", "decision": "allow|deny|modify", ...}
question_response    {"type": "question_response", "request_id": "...", "answer": "..." | "dismissed": true}
```

### Server → iOS
```
status               {"type": "status", "state": "idle|processing|speaking", ...}
audio_chunk          {"type": "audio_chunk", "data": "<base64 WAV>", ...}
stop_audio           {"type": "stop_audio"}
assistant_response   {"type": "assistant_response", "content_blocks": [...], "session_id": "...", "seq": N}
user_message         {"type": "user_message", "role": "user", "content": "...", "session_id": "...", "seq": N}
resync_response      {"type": "resync_response", "messages": [...]}
activity_status      {"type": "activity_status", "state": "idle|thinking|tool_active|waiting_permission", "detail": "..."}
delivery_status      {"type": "delivery_status", "status": "confirmed|failed", "text": "..."}
projects              {"type": "projects", "projects": [...]}
sessions_list        {"type": "sessions_list", "sessions": [...], "active_session_ids": [...]}
session_history      {"type": "session_history", "messages": [...]}
session_created      {"type": "session_created", "session_id": "..."}
session_resumed      {"type": "session_resumed", "session_id": "..."}
session_closed       {"type": "session_closed"}
session_stopped      {"type": "session_stopped", "session_id": "...", "success": true|false}
connection_status    {"type": "connection_status", "connected": true|false, "active_session_ids": [...]}
directory_listing    {"type": "directory_listing", "path": "...", "entries": [...]}
file_contents        {"type": "file_contents", "path": "...", "contents": "..." | "image_data": "..."}
context_update       {"type": "context_update", "session_id": "...", "context_percentage": ..., "tokens_used": ...}
usage_response       {"type": "usage_response", "session": {...}, "week_all_models": {...}, ...}
permission_request   {"type": "permission_request", "request_id": "...", "session_id": "...", "prompt_type": "bash|edit|...", ...}
permission_resolved  {"type": "permission_resolved", "request_id": "...", "session_id": "..."}
question_prompt      {"type": "question_prompt", "request_id": "...", "session_id": "...", "question": "...", "options": [...], ...}
question_resolved    {"type": "question_resolved", "request_id": "..."}
task_completed       {"type": "task_completed", "tool_use_id": "..."}
```

## Key Features

- **Voice Interaction**: Speak commands, hear Claude's responses via Kokoro TTS
- **Text + Image Input**: Type messages with photo attachments from iOS
- **Multi-Session**: Run up to 5 concurrent Claude Code sessions, switch between them, stop individual sessions
- **Session Browser**: Browse projects from `~/.claude/projects/` and `~/Desktop/code/`, view sessions (green dot = active), resume in tmux
- **Conversation View**: See assistant text, tool use/results, terminal-typed user messages, and interrupts
- **Tool Display**: Collapsible tool use blocks with input summaries and results
- **Agent Groups**: Grouped status cards for multi-agent execution (running/completed)
- **File Browser**: Browse project files with text and image viewing
- **Markdown Rendering**: Rich text in messages, stripped for TTS
- **Remote Permissions**: Approve/deny Claude Code permission prompts inline with suggestion support
- **Question Prompts**: Answer AskUserQuestion options via tappable buttons (PreToolUse hook)
- **Context Tracking**: Real-time context window usage displayed in session header
- **Usage Stats**: View session/weekly quotas in Settings (fetched via OAuth API)
- **Activity Detection**: Idle/thinking/tool_active state from tmux pane parsing
- **Delivery Tracking**: Confirm voice/text input was received by Claude Code
- **Message Sync**: Sequence numbers + resync to recover from missed WebSocket messages
- **QR Connect**: Scan QR code displayed by server to connect iOS app

## Server Design Details

### Multi-Session Architecture
`SessionContext` (`session_context.py`) bundles per-session state: session ID, folder name, tmux session name, transcript path, observer, activity state, and voice input dedup. `VoiceServer` holds `active_sessions: dict[str, SessionContext]` (keyed by tmux session name) and `viewed_session_id` (which session the iOS app is viewing). Each tmux session is named `claude-connect_<session_id>` via `session_name_for()`. Max 5 concurrent sessions (`MAX_ACTIVE_SESSIONS`). Hook scripts pass `CLAUDE_CONNECT_SESSION_ID` via `X-Session-Id` header so the server routes permissions/questions to the correct session. Server shutdown kills all `claude-connect_*` tmux sessions.

### Transcript Watching Pipeline
The core data flow for streaming Claude's output to the iOS app:
1. **watchdog** monitors the active Claude Code transcript JSONL file for changes
2. **TranscriptHandler** tracks `processed_line_count` to only extract new content
3. New lines are parsed into content blocks (text, thinking, tool_use, tool_result)
4. Blocks are broadcast to connected iOS clients via WebSocket
5. A **reconciliation loop** periodically re-checks the file to catch watchdog misses
6. Each message gets a sequence number (`seq`) for gap detection

### Activity State Detection
The pane poll loop (1s interval) iterates all active sessions, but only broadcasts activity for the viewed session. `pane_parser.py` captures the tmux pane and parses the last ~15 lines:
- Spinner chars (✢✻✽✳·✶) → `thinking`
- ⏺ + present tense verb → `tool_active` (with tool name as detail)
- "Esc to cancel · Tab to amend" → `waiting_permission`
- Otherwise → `idle`

Activity state is also re-checked immediately after sending an assistant_response (event-driven), so the iOS app gets the updated state right alongside the message content.

### Permission Flow
1. Claude Code triggers `PermissionRequest` hook → `permission_hook.sh` POSTs to HTTP server (port 8766) with `X-Session-Id` header
2. `http_server.py` generates `request_id`, resolves pending session IDs, broadcasts to iOS via WebSocket
3. iOS shows inline `PermissionCardView` with approve/deny + permission suggestions
4. User decision flows back through WebSocket → HTTP response → hook stdout → Claude Code
5. `PostToolUse` hook fires `post_tool_hook.sh` to dismiss stale prompts if the request timed out

### Question Flow
1. Claude Code triggers `PreToolUse` hook for `AskUserQuestion` → `question_hook.sh` POSTs to `/question` endpoint
2. `http_server.py` extracts questions, broadcasts `question_prompt` to iOS one at a time
3. iOS shows `QuestionCardView` with tappable option buttons (or text input for no options)
4. User answer flows back through WebSocket → HTTP response → hook stdout as deny+reason
5. Claude receives the answer and continues without showing terminal UI

### Usage Checking
`usage_checker.py` reads the OAuth token from macOS Keychain (`security` command) and calls the Anthropic OAuth API directly. `usage_parser.py` maps the API response into session/weekly quota percentages.

### TTS Pipeline
1. Assistant text extracted from transcript → markdown stripped
2. Text queued to `tts_utils.py` (Kokoro pipeline, 24kHz, voice "af_heart")
3. Audio chunked and streamed as base64 WAV via WebSocket `audio_chunk` messages
4. iOS `AudioPlayer` buffers chunks and plays via `AVAudioEngine`

## iOS Design Details

### State Architecture
- **WebSocketManager** is the central state hub (`@ObservedObject` in views)
- Published properties drive UI: `connectionState`, `outputState`, `inputBarMode`, `pendingPermission`, etc.
- Callback-based event handling for server messages (e.g., `onAssistantResponse`, `onPermissionRequest`)
- `@AppStorage` for persistent settings: `ttsEnabled`, `serverIP`, `serverPort`

### Conversation Items
`Session.swift` defines `ConversationItem` enum with cases:
- `.textMessage` — user or assistant text
- `.toolUse` — paired tool_use + tool_result blocks
- `.agentGroup` — grouped agent executions (via `groupAgentItems()`)
- `.permissionPrompt` — inline permission request card

### Input Bar State Machine
`InputBarMode` controls what the input area shows:
- `.normal` — text field + mic button
- `.permissionPrompt(request)` — approve/deny buttons
- `.questionPrompt(request)` — option selection buttons
- `.syncing` — loading state during resync
- `.disconnected` — reconnection indicator
