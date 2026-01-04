# Claude Voice Mode

Hands-free voice interaction with Claude Code via iOS app + Mac server.

## Architecture

```
iPhone App                         Mac Server
├─ Speech Recognition              ├─ WebSocket Server (port 8765)
├─ WebSocket Client ──────────────►├─ Receives voice input
├─ Audio Player ◄──────────────────├─ Streams TTS audio (Kokoro)
├─ Session/Project Browser         ├─ VSCode integration (AppleScript)
└─ Message History Display         └─ Transcript file watching
```

## Project Structure

```
ios-voice-app/ClaudeVoice/     # iOS app (Swift/SwiftUI)
├─ Models/                     # ConnectionState, VoiceState, Message, Project, Session
├─ Services/                   # WebSocketManager, SpeechRecognizer, AudioPlayer
└─ Views/                      # SessionView, ProjectsListView, SessionsListView, SettingsView

voice_server/                  # Python server
├─ ios_server.py              # Main WebSocket server
├─ session_manager.py         # Claude Code session management
├─ tts_utils.py               # Kokoro TTS integration
├─ vscode_controller.py       # AppleScript automation
└─ tests/                     # pytest test suite

tests/e2e_support/            # E2E test utilities
├─ server_manager.py          # Server lifecycle for tests
└─ transcript_injector.py     # Mock message injection
```

## Commands

### Testing

See [`tests/TESTS.md`](tests/TESTS.md) for full test documentation.

**Automatable (for auto-fix skill):**
```bash
# Server tests (Python)
cd voice_server/tests && ./run_tests.sh

# iOS unit tests
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests
```

**Requires human (not for auto-fix):**
```bash
# E2E tests - requires simulator, may timeout
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh

# Integration tests - requires manually starting server first
# See tests/TESTS.md for details
```

### Running

```bash
# Start voice server
source .venv/bin/activate
python3 voice_server/ios_server.py

# Clean iOS build (only required after adding new files)
cd ios-voice-app/ClaudeVoice
xcodebuild clean -scheme ClaudeVoice

# Build iOS app (simulator)
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# Build and install iOS app (on device)
cd ios-voice-app/ClaudeVoice
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
tail -f /tmp/e2e_server.log
tail -f /tmp/test_output.log

# Simulator management
xcrun simctl shutdown all
xcrun simctl list
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

iOS → Server: `{"type": "voice_input", "text": "...", "timestamp": ...}`
Server → iOS: `{"type": "status", "state": "idle|processing|speaking", ...}`
Server → iOS: `{"type": "audio_chunk", "data": "<base64 WAV>", ...}`
Server → iOS: `{"type": "projects_list", "projects": [...], ...}`
Server → iOS: `{"type": "sessions_list", "sessions": [...], ...}`

## Current Feature: Session Sync

The app displays Claude Code projects and sessions, allowing users to:
- Browse projects (from `~/.claude/projects/`)
- View sessions per project
- See message history for each session
- Open/resume sessions in VSCode
