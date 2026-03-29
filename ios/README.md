# Claude Connect iOS App

SwiftUI app for controlling Claude Code from your iPhone. Connects to the Mac server over WebSocket for voice/text input, conversation viewing, session management, file browsing, and remote permission approval.

## Requirements

- Xcode 15+
- iOS 18.0+ deployment target
- Physical iPhone recommended (speech recognition and audio work best on device)

## Building

```bash
# Simulator
cd ios/ClaudeConnect
xcodebuild build -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 16'

# Device
xcodebuild -target ClaudeConnect -sdk iphoneos build
xcrun devicectl list devices
xcrun devicectl device install app --device "<DEVICE_ID>" \
  ios/ClaudeConnect/build/Release-iphoneos/ClaudeConnect.app
```

## Testing

```bash
# Unit tests
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeConnectTests

# E2E tests (starts a test server, needs simulator)
./run_e2e_tests.sh

# Run a specific E2E suite
./run_e2e_tests.sh E2EPermissionTests
```

## Project Structure

```
ClaudeConnect/
├── ClaudeVoiceApp.swift        # @main entry point
├── Models/                     # Data types
│   ├── Message.swift           # WebSocket message types
│   ├── Session.swift           # Session model, ConversationItem enum
│   ├── AssistantContent.swift  # Content block types (text, tool_use, etc.)
│   ├── PermissionRequest.swift # Permission/question request models
│   ├── InputBarMode.swift      # Input bar state machine
│   └── ...
├── Services/
│   ├── WebSocketManager.swift  # Central state hub, message routing
│   ├── SpeechRecognizer.swift  # iOS Speech framework wrapper
│   ├── AudioPlayer.swift       # Chunked TTS playback via AVAudioEngine
│   └── QRCodeValidator.swift   # QR code URL validation
├── Views/
│   ├── SessionView.swift       # Main conversation view (~800 lines)
│   ├── ToolUseView.swift       # Tool use/result display
│   ├── PermissionCardView.swift # Permission approval cards
│   ├── ProjectsListView.swift  # Project browser
│   ├── ProjectDetailView.swift # Sessions + files tabs
│   ├── FilesView.swift         # File tree browser
│   └── ...
└── Utils/
    ├── TimeFormatter.swift     # Relative time strings
    └── SwipeBackModifier.swift # Swipe-back gesture
```

## Architecture

**WebSocketManager** is the single state hub. All views bind via `@ObservedObject` and communicate through published state changes and callbacks — no direct method calls between views.

Key patterns:
- **Sequence-based dedup**: Server attaches `seq` to every message. SessionView tracks `lastProcessedSeq` and skips duplicates. Reconnects trigger a resync to fill gaps.
- **Conversation items**: Messages are grouped into `.textMessage`, `.toolUse` (paired use + result), `.agentGroup` (merged agent executions), and `.permissionPrompt` types.
- **Multi-session**: Up to 5 concurrent sessions. Green dots for active, blue for unread. Switching sessions sends `view_session` without killing the previous one.

See [CLAUDE.md](ClaudeConnect/CLAUDE.md) for detailed architecture docs.
