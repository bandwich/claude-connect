# Claude Voice Mode

claude code via iOS

## Installation

### Server (Mac)

```bash
# Clone repo
git clone https://github.com/yourusername/claude-voice-mode.git
cd claude-voice-mode

# Create venv
python3 -m venv .venv
source .venv/bin/activate

# Install deps
pip install -r requirements.txt
```

### iOS App

1. Open `ios-voice-app/ClaudeVoice/ClaudeVoice.xcodeproj` in Xcode
2. Select your iPhone as the build target
3. Build and run

## Usage

### Start server

```bash
source .venv/bin/activate
python3 voice_server/ios_server.py
```

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