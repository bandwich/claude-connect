# Claude Voice iOS App

iOS - hands-free voice interaction with Claude Code via VSCode

## Files Created

### Models
- `ConnectionState.swift` - WebSocket connection states
- `VoiceState.swift` - Voice interaction states
- `Message.swift` - WebSocket message types

### Services
- `SpeechRecognizer.swift` - iOS Speech framework integration
- `WebSocketManager.swift` - WebSocket client with auto-reconnect
- `AudioPlayer.swift` - Plays streamed TTS audio from server

### Views
- `ContentView.swift` - Main app UI
- `VoiceIndicator.swift` - Animated visual feedback
- `SettingsView.swift` - Server connection settings

### App Entry
- `ClaudeVoiceApp.swift` - SwiftUI app entry point
- `Info.plist` - Permissions and app configuration

## WebSocket Communication Protocol


The app communicates with the server using JSON messages over WebSocket.

### iOS → Server (Voice Input)
```json
{
  "type": "voice_input",
  "text": "user's spoken text",
  "timestamp": 1234567890.123
}
```

### Server → iOS (Status Updates)
```json
{
  "type": "status",
  "state": "idle|processing|speaking",
  "message": "descriptive message",
  "timestamp": 1234567890.123
}
```

### Server → iOS (Audio Chunks)
```json
{
  "type": "audio_chunk",
  "format": "wav",
  "sample_rate": 24000,
  "chunk_index": 0,
  "total_chunks": 10,
  "data": "<base64 encoded WAV bytes>"
}
```

## Project Configuration

- **Xcode Project:** `/Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice/ClaudeVoice.xcodeproj`
- **Deployment Target:** iOS 18.0
- **Info.plist:** Custom plist with microphone and speech recognition permissions
- **Bundle ID:** bandwich.ClaudeVoice
- **Signing:** Automatic (Team: M9Y92YBFB5)

## How to Build and Run

### Testing on Simulator (Limited)
- Speech recognition works in simulator
- WebSocket connection works in simulator
- **Audio playback quality may vary on simulator**

### Testing on Physical iPhone (Recommended)
1. Connect iPhone via USB
2. Select iPhone as build target in Xcode
3. Click Run (⌘R)
4. Grant permissions when prompted

## Using the App

### Before First Use

1. **Start the server on your Mac:**
   ```bash
   cd /Users/aaron/Desktop/max
   source .venv/bin/activate
   python3 ~/.claude/voice-mode/ios_server.py
   ```

2. **Note the server IP:** The server prints its local IP when starting

### First Launch

1. Open the app on your iPhone
2. Tap the Settings gear icon (top right)
3. Enter the server IP address
4. Port should be `8765` (default)
5. Tap "Connect"
6. Wait for "Connected" status

### Making a Request

1. Make sure you're connected (green status indicator)
2. Tap "Tap to Talk" button
3. Speak your question or command
4. Stop talking and wait (automatic silence detection)
5. App sends text to server → Claude processes → Audio plays back

## Architecture Overview

```
iPhone App                      Mac (Server)
│                               │
├─ Speech Recognition           ├─ WebSocket Server (port 8765)
├─ WebSocket Client ───────────►├─ Receives voice_input
├─ Audio Player    ◄────────────├─ Streams TTS audio chunks
│                               │
│                               ├─ Sends to VS Code (AppleScript)
│                               ├─ Claude Code responds
│                               └─ Kokoro TTS generates audio
```

## Troubleshooting

### Can't Connect to Server
- Ensure both devices on same WiFi network
- Check server IP is correct
- Verify server is running (`python3 ~/.claude/voice-mode/ios_server.py`)
- Check firewall settings on Mac

### No Audio Playback
- Check iPhone volume
- Try disconnecting/reconnecting
- Restart the server
- Check server logs for errors

### Speech Recognition Not Working
- Grant microphone permission in Settings
- Grant speech recognition permission
- Check microphone works in other apps

### Build Errors in Xcode
- Clean build folder: Product → Clean Build Folder
- Restart Xcode
- Check deployment target is iOS 15.0+
- Ensure all files are added to target

## File Locations

**iOS App:**
- Xcode Project: `/Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice/ClaudeVoice.xcodeproj`
- Source Files: `/Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice/ClaudeVoice/`

**Server-Side (Mac):**
- WebSocket Server: `~/.claude/voice-mode/ios_server.py`
- TTS Utilities: `~/.claude/voice-mode/tts_utils.py`
- Kokoro TTS Hook: `~/.claude/voice-mode/run-kokoro.py`

## Server Details

The WebSocket server (`ios_server.py`) handles:
- Listens on `0.0.0.0:8765` for iOS connections
- Receives voice input from iOS app
- Sends text to VS Code via AppleScript (clipboard + paste)
- Monitors transcript file for Claude responses using watchdog
- Generates TTS audio using Kokoro (voice: "af_heart")
- Streams audio chunks to iOS as base64-encoded WAV

Audio Format: WAV, 24kHz, mono, 16-bit PCM

## Quick Start

1. **Start the server:**
   ```bash
   cd /Users/aaron/Desktop/max
   source .venv/bin/activate
   python3 ~/.claude/voice-mode/ios_server.py
   ```
   Note the IP address shown in the output.

2. **Build and run the app:**
   - Open `ClaudeVoice.xcodeproj` in Xcode
   - Select your iPhone as target
   - Press Cmd+R to build and run

3. **Connect:**
   - Tap Settings (gear icon)
   - Enter server IP address
   - Tap Connect

4. **Talk:**
   - Tap "Tap to Talk" button
   - Speak your request
   - Wait for automatic silence detection
   - Listen to Claude's response

## Requirements

- Xcode 14.0+
- iOS 18.0+ (current deployment target)
- Physical iPhone required for full functionality
- Mac and iPhone on same WiFi network
- Python environment with dependencies: websockets, kokoro, soundfile, numpy, watchdog

## Features

- Hands-free voice interaction with Claude Code
- Automatic silence detection
- Real-time speech transcription
- Streamed TTS audio playback
- Visual feedback for all states
- Auto-reconnect on connection loss
- Simple settings interface
