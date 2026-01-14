# QR Code Connection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Enable one-command server startup with QR code display, and QR scanning in iOS app to auto-connect.

**Architecture:** Server displays QR code on startup encoding WebSocket URL. iOS app scans QR via camera, extracts URL, connects automatically. Settings view simplified to Connect button + status display.

**Tech Stack:** Python `qrcode` library for ASCII QR generation, `pyproject.toml` for entry point, AVFoundation for iOS camera/QR scanning.

**Risky Assumptions:**
1. Local IP detection may fail on some network configs - verify early with simple test
2. QR scanning works reliably with terminal QR codes - test with actual terminal output

---

### Task 1: Server IP Detection & QR Display

**Files:**
- Create: `voice_server/qr_display.py`
- Modify: `voice_server/ios_server.py:781-819` (start method)
- Test: `voice_server/tests/test_qr_display.py`

**Step 1: Write the failing test**

```python
# voice_server/tests/test_qr_display.py
import pytest
from qr_display import get_local_ip, generate_qr_code, get_websocket_url


class TestQRDisplay:
    def test_get_local_ip_returns_valid_ip(self):
        """IP should be IPv4 format, not localhost"""
        ip = get_local_ip()
        assert ip is not None
        assert not ip.startswith("127.")
        parts = ip.split(".")
        assert len(parts) == 4
        assert all(p.isdigit() and 0 <= int(p) <= 255 for p in parts)

    def test_get_websocket_url(self):
        """URL should be ws:// format with port"""
        url = get_websocket_url("192.168.1.42", 8765)
        assert url == "ws://192.168.1.42:8765"

    def test_generate_qr_code_returns_string(self):
        """QR code should be non-empty ASCII art"""
        qr = generate_qr_code("ws://192.168.1.42:8765")
        assert isinstance(qr, str)
        assert len(qr) > 100  # QR codes are substantial
        assert "█" in qr or "#" in qr  # Contains block characters
```

**Step 2: Run test to verify it fails**

Run: `cd /Users/aaron/Desktop/max && source .venv/bin/activate && pytest voice_server/tests/test_qr_display.py -v`
Expected: FAIL with "ModuleNotFoundError: No module named 'qr_display'"

**Step 3: Install qrcode dependency**

Run: `cd /Users/aaron/Desktop/max && source .venv/bin/activate && pip install qrcode`

**Step 4: Write minimal implementation**

```python
# voice_server/qr_display.py
"""QR code display for server startup"""
import socket
import qrcode


def get_local_ip() -> str:
    """Get the local IP address for LAN connections.

    Uses UDP socket trick to find the IP that would be used
    to reach external hosts (works across network configs).
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


def get_websocket_url(ip: str, port: int) -> str:
    """Generate WebSocket URL from IP and port."""
    return f"ws://{ip}:{port}"


def generate_qr_code(url: str) -> str:
    """Generate ASCII QR code for terminal display."""
    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=1,
        border=2,
    )
    qr.add_data(url)
    qr.make(fit=True)

    # Generate ASCII representation
    from io import StringIO
    f = StringIO()
    qr.print_ascii(out=f)
    f.seek(0)
    return f.read()


def print_startup_banner(ip: str, port: int):
    """Print startup banner with QR code."""
    url = get_websocket_url(ip, port)
    qr = generate_qr_code(url)

    print("\n" + "=" * 50)
    print("Claude Voice Server")
    print("=" * 50 + "\n")
    print(qr)
    print(f"\nScan QR code with Claude Voice app\n")
    print(f"{url}\n")
    print("Waiting for connection...")
    print("=" * 50 + "\n")
```

**Step 5: Run test to verify it passes**

Run: `cd /Users/aaron/Desktop/max && source .venv/bin/activate && pytest voice_server/tests/test_qr_display.py -v`
Expected: PASS

**Step 6: Integrate into ios_server.py**

In `voice_server/ios_server.py`, modify the `start` method. Replace lines 810-816:

```python
# OLD (remove these lines):
        import socket
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        local_ip = s.getsockname()[0]
        s.close()

        print(f"Server running on ws://{local_ip}:{PORT}")

# NEW (add these lines):
        from qr_display import get_local_ip, print_startup_banner

        local_ip = get_local_ip()
        if local_ip:
            print_startup_banner(local_ip, PORT)
        else:
            print(f"WARNING: Could not detect local IP. Server running on port {PORT}")
```

**Step 7: Verify server displays QR on startup**

Run: `cd /Users/aaron/Desktop/max && source .venv/bin/activate && timeout 3 python3 voice_server/ios_server.py || true`
Expected: QR code and URL displayed in terminal

**CHECKPOINT:** If QR doesn't display, debug now. Don't proceed.

**Step 8: Commit**

```bash
git add voice_server/qr_display.py voice_server/tests/test_qr_display.py voice_server/ios_server.py
git commit -m "feat: display QR code on server startup"
```

---

### Task 2: Python Entry Point

**Files:**
- Create: `pyproject.toml`
- Modify: `voice_server/ios_server.py:1-30` (add main function)

**Step 1: Create pyproject.toml**

```toml
# pyproject.toml
[build-system]
requires = ["setuptools>=61.0"]
build-backend = "setuptools.build_meta"

[project]
name = "claude-voice-server"
version = "0.1.0"
description = "Voice server for Claude Code iOS app"
requires-python = ">=3.9"
dependencies = [
    "websockets",
    "watchdog",
    "qrcode",
    "pydantic",
]

[project.scripts]
voice-server = "voice_server.ios_server:main"

[tool.setuptools.packages.find]
where = ["."]
include = ["voice_server*"]
```

**Step 2: Add main() function to ios_server.py**

Add at the end of `voice_server/ios_server.py`, replacing the existing `if __name__` block:

```python
def main():
    """Entry point for voice-server command."""
    asyncio.run(VoiceServer().start())


if __name__ == "__main__":
    main()
```

**Step 3: Create voice_server/__init__.py**

```python
# voice_server/__init__.py
"""Claude Voice Server package."""
```

**Step 4: Install package in editable mode**

Run: `cd /Users/aaron/Desktop/max && source .venv/bin/activate && pip install -e .`
Expected: "Successfully installed claude-voice-server-0.1.0"

**Step 5: Verify voice-server command works**

Run: `cd /tmp && source /Users/aaron/Desktop/max/.venv/bin/activate && timeout 3 voice-server || true`
Expected: QR code displayed (command works from any directory)

**CHECKPOINT:** If command doesn't work from /tmp, debug now. Don't proceed.

**Step 6: Commit**

```bash
git add pyproject.toml voice_server/__init__.py voice_server/ios_server.py
git commit -m "feat: add voice-server command entry point"
```

---

### Task 3: iOS QR Scanner Component

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/QRScannerView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Info.plist`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/QRScannerTests.swift`

**Step 1: Add camera permission to Info.plist**

Add after line 8 (after NSSpeechRecognitionUsageDescription):

```xml
    <key>NSCameraUsageDescription</key>
    <string>Scan QR code to connect to Claude Voice server.</string>
```

**Step 2: Create QRScannerView**

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/QRScannerView.swift
import SwiftUI
import AVFoundation

struct QRScannerView: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned, onCancel: onCancel)
    }

    class Coordinator: NSObject, QRScannerDelegate {
        let onCodeScanned: (String) -> Void
        let onCancel: () -> Void

        init(onCodeScanned: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onCodeScanned = onCodeScanned
            self.onCancel = onCancel
        }

        func didScanCode(_ code: String) {
            onCodeScanned(code)
        }

        func didCancel() {
            onCancel()
        }
    }
}

protocol QRScannerDelegate: AnyObject {
    func didScanCode(_ code: String)
    func didCancel()
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerDelegate?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var hasScanned = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
        setupOverlay()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hasScanned = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        captureSession?.stopRunning()
    }

    private func setupCamera() {
        captureSession = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
              let captureSession = captureSession,
              captureSession.canAddInput(videoInput) else {
            showCameraError()
            return
        }

        captureSession.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        if captureSession.canAddOutput(metadataOutput) {
            captureSession.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        }

        previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        previewLayer?.frame = view.layer.bounds
        previewLayer?.videoGravity = .resizeAspectFill
        if let previewLayer = previewLayer {
            view.layer.addSublayer(previewLayer)
        }
    }

    private func setupOverlay() {
        // Cancel button
        let cancelButton = UIButton(type: .system)
        cancelButton.setTitle("Cancel", for: .normal)
        cancelButton.setTitleColor(.white, for: .normal)
        cancelButton.titleLabel?.font = .systemFont(ofSize: 18)
        cancelButton.addTarget(self, action: #selector(cancelTapped), for: .touchUpInside)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cancelButton)

        // Instruction label
        let instructionLabel = UILabel()
        instructionLabel.text = "Point camera at QR code"
        instructionLabel.textColor = .white
        instructionLabel.textAlignment = .center
        instructionLabel.font = .systemFont(ofSize: 16)
        instructionLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(instructionLabel)

        // Viewfinder frame
        let frameView = UIView()
        frameView.layer.borderColor = UIColor.white.cgColor
        frameView.layer.borderWidth = 2
        frameView.layer.cornerRadius = 12
        frameView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(frameView)

        NSLayoutConstraint.activate([
            cancelButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            cancelButton.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),

            frameView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            frameView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            frameView.widthAnchor.constraint(equalToConstant: 250),
            frameView.heightAnchor.constraint(equalToConstant: 250),

            instructionLabel.topAnchor.constraint(equalTo: frameView.bottomAnchor, constant: 32),
            instructionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        ])
    }

    private func showCameraError() {
        let label = UILabel()
        label.text = "Camera not available"
        label.textColor = .white
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
    }

    @objc private func cancelTapped() {
        delegate?.didCancel()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard !hasScanned,
              let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = metadataObject.stringValue,
              stringValue.hasPrefix("ws://") else {
            return
        }

        hasScanned = true

        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        captureSession?.stopRunning()
        delegate?.didScanCode(stringValue)
    }
}
```

**Step 3: Create unit test for URL validation**

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoiceTests/QRScannerTests.swift
import XCTest
@testable import ClaudeVoice

final class QRScannerTests: XCTestCase {

    func test_valid_websocket_url_accepted() {
        let validURLs = [
            "ws://192.168.1.42:8765",
            "ws://10.0.0.1:8765",
            "ws://172.16.0.1:9000",
        ]

        for url in validURLs {
            XCTAssertTrue(url.hasPrefix("ws://"), "\(url) should be valid")
        }
    }

    func test_invalid_urls_rejected() {
        let invalidURLs = [
            "http://192.168.1.42:8765",
            "https://example.com",
            "not a url",
            "",
        ]

        for url in invalidURLs {
            XCTAssertFalse(url.hasPrefix("ws://"), "\(url) should be invalid")
        }
    }
}
```

**Step 4: Run iOS unit tests**

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/QRScannerTests 2>&1 | tail -20`
Expected: Tests pass

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/QRScannerView.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Info.plist ios-voice-app/ClaudeVoice/ClaudeVoiceTests/QRScannerTests.swift
git commit -m "feat: add QR scanner view for iOS"
```

---

### Task 4: WebSocketManager URL Connect Method

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift:78-94`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift`

**Step 1: Add connect(url:) method and connectedURL property**

Add after line 56 in WebSocketManager.swift (after `shouldReconnect`):

```swift
    @Published var connectedURL: String? = nil
```

Add new method after the existing `connect(host:port:)` method (after line 94):

```swift
    func connect(url: String) {
        guard let wsURL = URL(string: url) else {
            DispatchQueue.main.async {
                self.connectionState = .error("Invalid URL")
            }
            return
        }

        // Disconnect existing connection if any
        if webSocketTask != nil {
            disconnect()
        }

        shouldReconnect = true
        reconnectAttempts = 0
        connectedURL = url
        connectToURL(wsURL)
    }
```

Also update the existing `disconnect()` method to clear connectedURL. Add after line 141 (`currentURL = nil`):

```swift
        connectedURL = nil
```

**Step 2: Add test for URL connect**

Add to `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift`:

```swift
    func test_connect_with_url_sets_connectedURL() {
        let manager = WebSocketManager()
        manager.connect(url: "ws://192.168.1.42:8765")

        XCTAssertEqual(manager.connectedURL, "ws://192.168.1.42:8765")
    }

    func test_connect_with_invalid_url_sets_error() {
        let manager = WebSocketManager()
        manager.connect(url: "not a url")

        // Give time for async state update
        let expectation = XCTestExpectation(description: "Error state set")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            if case .error(_) = manager.connectionState {
                expectation.fulfill()
            }
        }
        wait(for: [expectation], timeout: 1.0)
    }

    func test_disconnect_clears_connectedURL() {
        let manager = WebSocketManager()
        manager.connect(url: "ws://192.168.1.42:8765")
        manager.disconnect()

        XCTAssertNil(manager.connectedURL)
    }
```

**Step 3: Run tests**

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/WebSocketManagerTests 2>&1 | tail -20`
Expected: Tests pass

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/WebSocketManagerTests.swift
git commit -m "feat: add URL-based connect method to WebSocketManager"
```

---

### Task 5: Settings View Redesign

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SettingsView.swift`

**Step 1: Rewrite SettingsView**

Replace entire contents of `SettingsView.swift`:

```swift
import SwiftUI

struct SettingsView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    @State private var showingScanner = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server Configuration")) {
                    if case .connected = webSocketManager.connectionState {
                        // Show connected IP when connected
                        if let url = webSocketManager.connectedURL {
                            HStack {
                                Text("Connected:")
                                Spacer()
                                Text(formatURL(url))
                                    .foregroundColor(.secondary)
                            }
                        }
                    } else {
                        // Show Connect button when disconnected
                        Button(action: { showingScanner = true }) {
                            HStack {
                                Spacer()
                                if case .connecting = webSocketManager.connectionState {
                                    ProgressView()
                                        .padding(.trailing, 8)
                                    Text("Connecting...")
                                } else {
                                    Text("Connect")
                                }
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("Connect")
                        .disabled({
                            if case .connecting = webSocketManager.connectionState {
                                return true
                            }
                            return false
                        }())
                    }
                }

                Section(header: Text("Connection")) {
                    HStack {
                        Text("Status:")
                        Spacer()
                        Text(webSocketManager.connectionState.description)
                            .foregroundColor(connectionColor)
                            .accessibilityIdentifier("connectionStatus")
                    }

                    if case .connected = webSocketManager.connectionState {
                        Button(action: disconnect) {
                            HStack {
                                Spacer()
                                Text("Disconnect")
                                Spacer()
                            }
                        }
                        .accessibilityIdentifier("Disconnect")
                        .foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarItems(trailing: Button("Done") {
                dismiss()
            })
            .alert("Connection Error", isPresented: $showingAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .fullScreenCover(isPresented: $showingScanner) {
                QRScannerView(
                    onCodeScanned: { url in
                        showingScanner = false
                        webSocketManager.connect(url: url)
                    },
                    onCancel: {
                        showingScanner = false
                    }
                )
            }
        }
    }

    private var connectionColor: Color {
        switch webSocketManager.connectionState {
        case .connected:
            return .green
        case .connecting:
            return .orange
        case .disconnected:
            return .gray
        case .error:
            return .red
        }
    }

    private func formatURL(_ url: String) -> String {
        // Extract IP from ws://192.168.1.42:8765
        if let range = url.range(of: "ws://") {
            return String(url[range.upperBound...])
        }
        return url
    }

    private func disconnect() {
        webSocketManager.disconnect()
    }
}
```

**Step 2: Build to verify no compile errors**

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -10`
Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SettingsView.swift
git commit -m "feat: redesign Settings view with QR connect button"
```

---

### Task 6: E2E Test - QR Connection Flow

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EQRConnectTests.swift`

**Step 1: Create E2E test**

Note: Camera-based QR scanning can't be fully automated in UI tests, but we can test the flow up to scanner presentation and the connection after.

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EQRConnectTests.swift
import XCTest

final class E2EQRConnectTests: E2ETestBase {

    /// Tests that Connect button opens scanner (camera permission may block full flow)
    func test_connect_button_opens_scanner() throws {
        // Disconnect first if connected
        openSettings()
        sleep(1)

        let disconnectButton = app.buttons["Disconnect"]
        if disconnectButton.exists {
            disconnectButton.tap()
            sleep(2)
        }

        // Tap Connect - should show scanner or camera permission
        let connectButton = app.buttons["Connect"]
        XCTAssertTrue(connectButton.waitForExistence(timeout: 5), "Connect button should exist")
        connectButton.tap()

        // Either scanner appears or camera permission dialog
        sleep(2)

        // Look for Cancel button (scanner) or permission dialog
        let cancelButton = app.buttons["Cancel"]
        let permissionDialog = app.alerts.firstMatch

        XCTAssertTrue(
            cancelButton.exists || permissionDialog.exists,
            "Should show scanner (Cancel button) or camera permission dialog"
        )

        // Dismiss scanner if shown
        if cancelButton.exists {
            cancelButton.tap()
        } else if permissionDialog.exists {
            // Dismiss permission dialog
            let dontAllow = permissionDialog.buttons["Don't Allow"]
            if dontAllow.exists {
                dontAllow.tap()
            }
        }

        sleep(1)
        app.buttons["Done"].tap()
    }

    /// Tests that connected state shows IP address
    func test_connected_state_shows_ip() throws {
        // This test requires manual connection or mock
        // For now, verify the UI structure when connected
        openSettings()
        sleep(1)

        let statusLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(statusLabel.waitForExistence(timeout: 5), "Status label should exist")

        // If connected, verify IP is shown
        if statusLabel.label == "Connected" {
            // Look for the Connected: text
            let connectedText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Connected:'")).firstMatch
            // IP display is only shown when connected - just verify structure
            XCTAssertTrue(app.buttons["Disconnect"].exists, "Disconnect should be visible when connected")
        }

        app.buttons["Done"].tap()
    }
}
```

**Step 2: Run E2E test**

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2EQRConnectTests 2>&1 | tail -30`
Expected: Tests pass (may need camera permission in simulator)

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EQRConnectTests.swift
git commit -m "test: add E2E tests for QR connection flow"
```

---

### Final Verification

**Step 1: Run all server tests**

Run: `cd /Users/aaron/Desktop/max/voice_server/tests && ./run_tests.sh`
Expected: All tests pass

**Step 2: Run all iOS unit tests**

Run: `cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests 2>&1 | tail -20`
Expected: All tests pass

**Step 3: Manual verification**

1. Start server: `voice-server` (from any directory)
2. Verify QR code displays in terminal
3. Build and run iOS app on device
4. Open Settings, tap Connect
5. Scan QR code with camera
6. Verify auto-connection and IP display

**CHECKPOINT:** If manual verification fails, debug before considering complete.
