# Claude Connect

Control Claude Code via iOS + macOS. Voice commands with TTS responses, session management, tool output viewing, file browsing, and remote permission approval — all over WebSocket to a Mac server.

## Prerequisites

- **macOS**
- **[Claude Code](https://claude.ai/code)**

## Install

```bash
git clone https://github.com/bandwich/claude-connect.git
cd claude-connect
./install.sh
```

This installs system dependencies (tmux, pipx) and sets up the `claude-connect` CLI via pipx.

First launch downloads the Kokoro TTS model (~1 GB), so startup will be slow the first time.

### iOS App

Build from source with Xcode:

```bash
cd ios/ClaudeConnect
xcodebuild build -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Usage

```bash
claude-connect
```

The server displays a QR code. Scan it from the iOS app to connect. Both devices must be on the same WiFi network.

## Permission Hooks

To approve Claude Code permission prompts and answer questions from the iOS app, add hooks to your Claude Code settings.

**Location:** `~/.claude/settings.json`

Replace `/path/to/claude-connect` with your actual clone path:

```json
{
  "hooks": {
    "PermissionRequest": [
      {
        "matcher": ".*",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/claude-connect/server/hooks/permission_hook.sh",
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
            "command": "/path/to/claude-connect/server/hooks/question_hook.sh",
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
            "command": "/path/to/claude-connect/server/hooks/post_tool_hook.sh"
          }
        ]
      }
    ]
  }
}
```

Without hooks, the app still works for voice/text input, session browsing, and file viewing — you just won't get remote permission prompts.

## Development

```bash
# Reinstall after changing server code
pipx install --force /path/to/claude-connect

# Run server tests
cd server/tests && ./run_tests.sh

# iOS unit tests
cd ios/ClaudeConnect
xcodebuild test -scheme ClaudeConnect \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeConnectTests

# E2E tests
cd ios/ClaudeConnect && ./run_e2e_tests.sh
```

See [tests/TESTS.md](tests/TESTS.md) for test details. See [CLAUDE.md](CLAUDE.md) for architecture and dev docs.

## License

[MIT](LICENSE)
