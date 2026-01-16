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
├─ Session/Project Browser         ├─ tmux session management
├─ Permission Approval UI          ├─ HTTP server for hooks (port 8766)
└─ Usage Stats Display             └─ Transcript file watching
```

## Project Structure

```
voice_server/                  # Python server
├─ ios_server.py              # Main WebSocket server
├─ session_manager.py         # Claude Code session management
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
│   ├─ ConnectionState.swift  # WebSocket connection states
│   ├─ VoiceState.swift       # Voice interaction states
│   ├─ Message.swift          # WebSocket message types
│   ├─ Project.swift          # Claude Code project model
│   ├─ Session.swift          # Claude Code session model
│   ├─ ContextStats.swift     # Context window usage stats
│   └─ UsageStats.swift       # Weekly/session quota stats
├─ Services/
│   ├─ WebSocketManager.swift # WebSocket client with reconnect
│   ├─ SpeechRecognizer.swift # iOS Speech framework
│   ├─ AudioPlayer.swift      # TTS audio playback
│   └─ QRCodeValidator.swift  # QR code URL validation
└─ Views/
    ├─ SessionView.swift      # Main voice interaction view
    ├─ ProjectsListView.swift # Project browser
    ├─ SessionsListView.swift # Session browser
    ├─ SettingsView.swift     # Connection settings + usage stats
    └─ QRScannerView.swift    # Camera-based QR scanner

tests/e2e_support/            # E2E test utilities
└─ server_manager.py          # Server lifecycle for tests
```

## Commands

### Running

```bash
# Option 1: Direct Python
source .venv/bin/activate
python3 voice_server/ios_server.py

# Option 2: Installed command (after pip install -e .)
voice-server
```

Server displays QR code on startup for iOS app to scan.

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
xcodebuild clean -scheme ClaudeVoice

# Build for simulator
xcodebuild build -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# Build and install on device
xcodebuild -scheme ClaudeVoice -destination 'generic/platform=iOS' build && \
DEVICE=$(xcrun devicectl list devices 2>/dev/null | grep 'available (paired)' | awk '{print $3}') && \
xcrun devicectl device install app --device "$DEVICE" \
  ~/Library/Developer/Xcode/DerivedData/ClaudeVoice-*/Build/Products/Debug-iphoneos/ClaudeVoice.app
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
voice_input      {"type": "voice_input", "text": "...", "timestamp": ...}
list_projects    {"type": "list_projects"}
list_sessions    {"type": "list_sessions", "folder_name": "..."}
open_session     {"type": "open_session", "folder_name": "...", "session_id": "..."}
usage_request    {"type": "usage_request"}
permission_response  {"type": "permission_response", "request_id": "...", "decision": "allow|deny|modify", ...}
```

### Server → iOS
```
status           {"type": "status", "state": "idle|processing|speaking", ...}
audio_chunk      {"type": "audio_chunk", "data": "<base64 WAV>", ...}
projects_list    {"type": "projects_list", "projects": [...]}
sessions_list    {"type": "sessions_list", "sessions": [...]}
context_update   {"type": "context_update", "session_id": "...", "context_percentage": ..., "tokens_used": ...}
usage_response   {"type": "usage_response", "session": {...}, "week_all_models": {...}, ...}
permission_request  {"type": "permission_request", "request_id": "...", "prompt_type": "bash|edit|...", ...}
```

## Key Features

- **Voice Interaction**: Speak commands, hear Claude's responses via Kokoro TTS
- **Session Browser**: Browse projects from `~/.claude/projects/`, view sessions, resume in tmux
- **Remote Permissions**: Approve/deny Claude Code permission prompts from iOS
- **Context Tracking**: Real-time context window usage displayed in session header
- **Usage Stats**: View session/weekly quotas in Settings (fetched via /usage command)
- **QR Connect**: Scan QR code displayed by server to connect iOS app
