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

# Claude Voice Mode

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
├─ ios_server.py              # Main WebSocket server + transcript watcher
├─ session_manager.py         # Claude Code session/project management
├─ content_models.py          # Pydantic models for content blocks
├─ tts_utils.py               # Kokoro TTS integration
├─ tmux_controller.py         # Tmux session control
├─ context_tracker.py         # Token usage calculation from transcripts
├─ usage_checker.py           # On-demand /usage stats fetcher
├─ usage_parser.py            # Parser for /usage command output
├─ permission_handler.py      # Permission request/response handling
├─ http_server.py             # HTTP server for Claude Code hooks
├─ qr_display.py              # QR code generation for iOS connection
└─ tests/                     # pytest test suite

ios-voice-app/ClaudeVoice/     # iOS app (Swift/SwiftUI)
├─ Models/
│   ├─ AssistantContent.swift # Content block types (text, tool_use, etc.)
│   ├─ ConnectionState.swift  # WebSocket connection states
│   ├─ ClaudeOutputState.swift # Output state tracking
│   ├─ ContextStats.swift     # Context window usage stats
│   ├─ FileModels.swift       # File browser response models
│   ├─ Message.swift          # WebSocket message types
│   ├─ PermissionRequest.swift # Permission request/response models
│   ├─ Project.swift          # Claude Code project model
│   ├─ Session.swift          # Session model + conversation items
│   ├─ UsageStats.swift       # Weekly/session quota stats
│   └─ VoiceState.swift       # Voice interaction states
├─ Services/
│   ├─ WebSocketManager.swift # WebSocket client with reconnect
│   ├─ SpeechRecognizer.swift # iOS Speech framework
│   ├─ AudioPlayer.swift      # TTS audio playback
│   └─ QRCodeValidator.swift  # QR code URL validation
└─ Views/
    ├─ SessionView.swift      # Main voice interaction + conversation view
    ├─ ToolUseView.swift      # Tool use/result display with expand/collapse
    ├─ ProjectsListView.swift # Project browser
    ├─ ProjectDetailView.swift # Project detail with sessions + files tabs
    ├─ SessionsListView.swift # Session browser
    ├─ FilesView.swift        # File browser (directory listing)
    ├─ FileView.swift         # File viewer (text + images)
    ├─ DiffView.swift         # Diff viewer for Edit results
    ├─ PermissionPromptView.swift # Permission approval sheet
    ├─ SettingsView.swift     # Connection settings + usage stats
    ├─ QRScannerView.swift    # Camera-based QR scanner
    ├─ CustomNavigationBar.swift # Reusable nav bar component
    └─ VoiceIndicator.swift   # Recording animation indicator

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
        "command": "/path/to/max/voice_server/hooks/permission_hook.sh",
        "timeout": 185000
      }
    ],
    "PostToolUse": [
      {
        "command": "/path/to/max/voice_server/hooks/post_tool_hook.sh"
      }
    ]
  }
}
```

**Environment Variables:**
- `VOICE_SERVER_URL`: Override server URL (default: `http://localhost:8766`)

**Ports Used:**
- WebSocket: 8765 (iOS app connection)
- HTTP: 8766 (Hook requests from Claude Code)

**How It Works:**
1. Claude Code triggers PermissionRequest hook before showing a prompt
2. Hook POSTs to voice server, which forwards to iOS app via WebSocket
3. User approves/denies on iOS, response flows back to hook
4. Hook outputs decision JSON, Claude Code proceeds accordingly
5. If timeout (3 min), falls back to terminal prompt with late-response injection

## WebSocket Protocol

### iOS → Server
```
voice_input          {"type": "voice_input", "text": "...", "timestamp": ...}
list_projects        {"type": "list_projects"}
list_sessions        {"type": "list_sessions", "folder_name": "..."}
open_session         {"type": "open_session", "folder_name": "...", "session_id": "..."}
new_session          {"type": "new_session", "folder_name": "..."}
resume_session       {"type": "resume_session", "folder_name": "...", "session_id": "..."}
close_session        {"type": "close_session"}
add_project          {"type": "add_project", "name": "...", "path": "..."}
list_directory       {"type": "list_directory", "path": "..."}
read_file            {"type": "read_file", "path": "..."}
usage_request        {"type": "usage_request"}
permission_response  {"type": "permission_response", "request_id": "...", "decision": "allow|deny|modify", ...}
```

### Server → iOS
```
status               {"type": "status", "state": "idle|processing|speaking", ...}
audio_chunk          {"type": "audio_chunk", "data": "<base64 WAV>", ...}
assistant_response   {"type": "assistant_response", "content_blocks": [...], "session_id": "..."}
user_message         {"type": "user_message", "role": "user", "content": "...", "session_id": "..."}
projects_list        {"type": "projects_list", "projects": [...]}
sessions_list        {"type": "sessions_list", "sessions": [...]}
session_history      {"type": "session_history", "messages": [...]}
session_created      {"type": "session_created", "session_id": "..."}
session_resumed      {"type": "session_resumed", "session_id": "..."}
session_closed       {"type": "session_closed"}
connection_status    {"type": "connection_status", "connected": true|false}
directory_listing    {"type": "directory_listing", "path": "...", "entries": [...]}
file_contents        {"type": "file_contents", "path": "...", "contents": "..." | "image_data": "..."}
context_update       {"type": "context_update", "session_id": "...", "context_percentage": ..., "tokens_used": ...}
usage_response       {"type": "usage_response", "session": {...}, "week_all_models": {...}, ...}
permission_request   {"type": "permission_request", "request_id": "...", "prompt_type": "bash|edit|...", ...}
permission_resolved  {"type": "permission_resolved", "request_id": "..."}
```

## Key Features

- **Voice Interaction**: Speak commands, hear Claude's responses via Kokoro TTS
- **Session Browser**: Browse projects from `~/.claude/projects/`, view sessions, resume in tmux
- **Conversation View**: See assistant text, tool use/results, terminal-typed user messages, and interrupts
- **Tool Display**: Collapsible tool use blocks with input summaries and results
- **File Browser**: Browse project files with text and image viewing
- **Markdown Rendering**: Rich text in messages, stripped for TTS
- **Remote Permissions**: Approve/deny Claude Code permission prompts from iOS
- **Context Tracking**: Real-time context window usage displayed in session header
- **Usage Stats**: View session/weekly quotas in Settings (fetched via /usage command)
- **QR Connect**: Scan QR code displayed by server to connect iOS app
