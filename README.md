# Claude Voice Mode

Hands-free voice interaction with Claude Code. Speak to Claude from your iPhone, hear responses via text-to-speech.

## How It Works

1. iOS app captures speech and sends text to Mac server via WebSocket
2. Server pastes text into Claude Code running in VSCode
3. Server monitors Claude's transcript for responses
4. Responses are converted to speech (Kokoro TTS) and streamed back to iOS

## Requirements

- Mac with VSCode and Claude Code CLI installed
- iPhone (iOS 18+)
- Python 3.9+ with virtual environment
- Xcode 15+ (for building the iOS app)
- Both devices on the same network

## Installation

### Server (Mac)

```bash
# Clone the repo
git clone https://github.com/yourusername/claude-voice-mode.git
cd claude-voice-mode

# Create virtual environment
python3 -m venv .venv
source .venv/bin/activate

# Install dependencies
pip install -r requirements.txt
```

### iOS App

1. Open `ios-voice-app/ClaudeVoice/ClaudeVoice.xcodeproj` in Xcode
2. Select your iPhone as the build target
3. Build and run (Cmd+R)

## Usage

### Start the Server

```bash
source .venv/bin/activate
python3 voice_server/ios_server.py
```

The server will display your Mac's IP address.

### Connect from iOS

1. Open Claude Voice on your iPhone
2. Tap Settings (gear icon)
3. Enter your Mac's IP address (port 8765)
4. Tap Connect

### Talk to Claude

1. Ensure Claude Code is running in VSCode
2. Tap "Tap to Talk" in the app
3. Speak your request
4. Listen to Claude's response

## Project Structure

```
ios-voice-app/ClaudeVoice/    # iOS app (Swift/SwiftUI)
voice_server/                  # Python WebSocket server
tests/                         # Test documentation and E2E support
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

See [tests/TESTS.md](tests/TESTS.md) for detailed test documentation.