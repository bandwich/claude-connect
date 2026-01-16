# Claude Code via iOS

## Installation

### Server (Mac)

```bash
# Clone and install
git clone https://github.com/bandwich/hands-free.git
cd hands-free
./install.sh
```

This installs system dependencies (tmux, zbar) and the `claude-connect` CLI globally via pipx.

<details>
<summary>Manual installation</summary>

```bash
# Install system dependencies
brew install tmux zbar

# Option 1: Global install via pipx (recommended)
pipx install /path/to/hands-free

# Option 2: Development install
python3 -m venv .venv
source .venv/bin/activate
pip install -e .
```
</details>

### iOS App

1. Open `ios-voice-app/ClaudeVoice/ClaudeVoice.xcodeproj` in Xcode
2. Select your iPhone as the build target
3. Build and run

## Usage

```bash
claude-connect
```

Server displays a QR code on startup for the app to scan.


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

See [tests/TESTS.md](tests/TESTS.md) for test docs