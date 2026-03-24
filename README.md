# Claude Connect

Control Claude Code hands-free from your iPhone. Voice commands with TTS responses, session management, tool output viewing, file browsing, and remote permission approval — all over WebSocket to a Mac server.

For Claude, written entirely by Claude, with oversight.

## Install

### Server (Mac)

```bash
pipx install claude-connect
claude-connect
```

The server will display a QR code. Scan it from the iOS app to connect.

If tmux is not installed, `claude-connect` will offer to install it for you.

### iOS App

Available on the App Store. *(coming soon)*

## Usage

```bash
claude-connect
```

Scan the QR code from the iOS app to connect.

## Development

```bash
# Clone and install locally
git clone https://github.com/bandwich/claude-connect.git
cd claude-connect
./install.sh

# Run server tests
cd voice_server/tests && ./run_tests.sh

# iOS unit tests
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests

# E2E tests
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh
```

See [tests/TESTS.md](tests/TESTS.md) for test details. See [CLAUDE.md](CLAUDE.md) for architecture and dev docs.
