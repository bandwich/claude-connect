# Claude Code via iOS

Control Claude Code hands-free from your iPhone. Voice commands with TTS responses, session management, tool output viewing, file browsing, and remote permission approval — all over WebSocket to a Mac server.

## Setup

### Server (Mac)

```bash
git clone https://github.com/bandwich/hands-free.git
cd hands-free
./install.sh
```

Installs system dependencies (tmux, zbar) and the `claude-connect` CLI globally via pipx.

<details>
<summary>Manual installation</summary>

```bash
brew install tmux zbar
pipx install /path/to/hands-free
```
</details>

### iOS App

Open `ios-voice-app/ClaudeVoice/ClaudeVoice.xcodeproj` in Xcode, build to device.

## Usage

```bash
claude-connect
```

Scan the QR code from the iOS app to connect.

## Testing

```bash
# Server tests
cd voice_server/tests && ./run_tests.sh

# iOS unit tests
cd ios-voice-app/ClaudeVoice
xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests

# E2E tests
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh
```

See [tests/TESTS.md](tests/TESTS.md) for details. See [CLAUDE.md](CLAUDE.md) for architecture, protocol, and dev docs.
