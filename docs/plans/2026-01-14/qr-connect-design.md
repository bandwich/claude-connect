# QR Code Connection Design

Simplify server-to-phone connection via QR code scanning.

## Overview

Replace manual IP entry with QR code scanning. Run `voice-server` from anywhere, scan QR with iPhone, automatically connect.

## Server Changes

### Python Entry Point

Add entry point to `pyproject.toml` so `voice-server` command is available globally after `pip install -e .`.

### Startup Flow

1. Detect local IP address (scan network interfaces)
2. Generate QR code encoding `ws://{ip}:8765`
3. Display ASCII QR code in terminal
4. Show URL as text below QR for reference
5. Start WebSocket server on port 8765
6. QR remains visible while server runs

### Terminal Output

```
Claude Voice Server

█████████████████████████████
█████████████████████████████
████ ▄▄▄▄▄ █ ▄ █ █ ▄▄▄▄▄ ████
████ █   █ █▄  ▀█▄█ █   █ ████
████ █▄▄▄█ █ █▄▀▄██ █▄▄▄█ ████
█████████████████████████████

Scan QR code with Claude Voice app

ws://192.168.1.42:8765

Waiting for connection...
```

### Dependencies

- `qrcode` Python package (ASCII QR generation)

### IP Detection

Try multiple methods for reliability:
- `socket.gethostbyname(socket.gethostname())`
- Iterate network interfaces via `netifaces` or `socket.getaddrinfo()`
- Filter out localhost, pick first non-127.x.x.x IPv4

If detection fails, print error with instructions to check network.

## iOS App Changes

### New Component: QRScannerView.swift

Camera-based QR scanner using AVFoundation.

**Behavior:**
1. Open camera with viewfinder overlay
2. Scan for QR codes containing `ws://` URLs
3. On valid scan: haptic feedback, extract URL
4. Auto-dismiss scanner
5. Pass URL to WebSocketManager, initiate connection

**Error handling:**
- Invalid QR (not ws:// URL): Brief error toast, keep scanning
- Camera permission denied: Show system prompt, fallback message
- Connection fails after scan: Return to Settings, show error status

**Permission:** Add `NSCameraUsageDescription` to Info.plist

### Settings View Redesign

**New layout:**

```
┌─────────────────────────────┐
│         Settings            │
├─────────────────────────────┤
│ Server Configuration        │
│                             │
│  ┌───────────────────────┐  │
│  │       Connect         │  │  ← Full-width button
│  └───────────────────────┘  │
│                             │
│  Connected: 192.168.1.42    │  ← Only visible when connected
│                             │
├─────────────────────────────┤
│ Connection                  │
│                             │
│  Status:          Connected │  ← Green/gray/red color
│                             │
│  ┌───────────────────────┐  │
│  │      Disconnect       │  │  ← Only when connected
│  └───────────────────────┘  │
│                             │
└─────────────────────────────┘
```

**Removed:**
- IP address text field
- Port text field
- Instructions section

**Connect button:**
- When disconnected: Opens QR scanner
- When connected: Hidden (Disconnect shown instead)

### WebSocketManager Changes

Add method to connect with full URL string (from QR):

```swift
func connect(url: String) {
    guard let wsURL = URL(string: url) else { return }
    // ... existing connection logic
}
```

Store connected URL for display in Settings.

## Data Flow

```
Terminal                          iPhone
   │                                │
   │  voice-server                  │
   │  ↓                             │
   │  Detect local IP               │
   │  ↓                             │
   │  Generate & display QR         │
   │  ↓                             │
   │  Start WebSocket server        │
   │         ←───── Scan QR ────────│
   │         ←───── Connect ────────│
   │  "Connected"                   │
   │         ←────── Use ──────────→│
```

## QR Code Content

Simple WebSocket URL: `ws://192.168.1.42:8765`

No authentication token (same local network assumption).

## Implementation Order

1. **Server: IP detection** - Verify reliable IP detection across network configs
2. **Server: QR display** - Add qrcode dependency, display on startup
3. **Server: Entry point** - Configure pyproject.toml for `voice-server` command
4. **iOS: QRScannerView** - Camera-based scanner with AVFoundation
5. **iOS: Settings redesign** - Remove manual entry, add Connect button
6. **iOS: Integration** - Wire scanner to WebSocketManager, handle connection flow
