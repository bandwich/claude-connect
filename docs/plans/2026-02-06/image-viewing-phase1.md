# Image Viewing in Files Tab - Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** View image files (png, jpg, gif, webp, bmp, ico) in the iOS Files tab instead of seeing "Cannot view contents".

**Architecture:** Server detects image extensions before UTF-8 read, base64-encodes the file if ≤10MB, sends via existing `file_contents` WebSocket message with new `image_data` field. iOS decodes base64 to UIImage and renders with pinch-to-zoom. Kingfisher's ImageCache used for caching by file path.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS), Kingfisher (SPM dependency for image caching)

**Risky Assumptions:** Large base64 payloads (~13MB for 10MB image) over WebSocket may cause issues. We'll verify with a real image file early in Task 2.

---

### Task 1: Server - image detection and base64 response

**Files:**
- Modify: `voice_server/ios_server.py:627-662` (handle_read_file)
- Test: `voice_server/tests/test_message_handlers.py` (TestReadFile class)

**Step 1: Write failing tests**

Add to `voice_server/tests/test_message_handlers.py` at the end of `TestReadFile`:

```python
    @pytest.mark.asyncio
    async def test_read_file_returns_image_data_for_png(self):
        """read_file should return base64-encoded image data for PNG files"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "test.png")
            # Write minimal PNG bytes (1x1 red pixel)
            import base64
            png_bytes = base64.b64decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg=="
            )
            with open(file_path, "wb") as f:
                f.write(png_bytes)

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert response["path"] == file_path
            assert "image_data" in response
            assert response["image_format"] == "png"
            assert response["file_size"] == len(png_bytes)
            # Should NOT have contents or error fields
            assert "contents" not in response
            assert "error" not in response

    @pytest.mark.asyncio
    async def test_read_file_returns_image_data_for_jpg(self):
        """read_file should return base64-encoded image data for JPG files"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "photo.jpg")
            with open(file_path, "wb") as f:
                f.write(b'\xff\xd8\xff\xe0' + b'\x00' * 100)  # JPEG header + padding

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert "image_data" in response
            assert response["image_format"] == "jpg"

    @pytest.mark.asyncio
    async def test_read_file_rejects_oversized_image(self):
        """read_file should return error for images over 10MB"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "huge.png")
            with open(file_path, "wb") as f:
                f.write(b'\x00' * (11 * 1024 * 1024))  # 11MB

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert response["error"] == "file_too_large"
            assert response["file_size"] == 11 * 1024 * 1024

    @pytest.mark.asyncio
    async def test_read_file_svg_returns_text(self):
        """read_file should return SVG as text content (not image_data)"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "icon.svg")
            with open(file_path, "w") as f:
                f.write('<svg xmlns="http://www.w3.org/2000/svg"><circle r="10"/></svg>')

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["type"] == "file_contents"
            assert "contents" in response
            assert "image_data" not in response

    @pytest.mark.asyncio
    async def test_read_file_non_image_binary_still_returns_error(self):
        """read_file should still return binary_file error for non-image binary files"""
        from ios_server import VoiceServer

        server = VoiceServer()

        with tempfile.TemporaryDirectory() as tmpdir:
            file_path = os.path.join(tmpdir, "data.bin")
            with open(file_path, "wb") as f:
                f.write(bytes([0x00, 0x01, 0xFF, 0xFE]))

            mock_ws = AsyncMock()
            sent_messages = []
            mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

            await server.handle_read_file(mock_ws, {"path": file_path})

            response = json.loads(sent_messages[0])
            assert response["error"] == "binary_file"
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: 5 new tests FAIL (handle_read_file doesn't know about images yet)

**Step 3: Implement image detection in handle_read_file**

In `voice_server/ios_server.py`, add constant after line 32 (`PROJECTS_BASE_PATH = ...`):

```python
IMAGE_EXTENSIONS = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico'}
MAX_IMAGE_SIZE = 10 * 1024 * 1024  # 10MB
```

Replace `handle_read_file` method (lines 627-662) with:

```python
    async def handle_read_file(self, websocket, data):
        """Handle read_file request - returns file contents as text, or base64 for images"""
        path = data.get("path", "")

        if not path or not os.path.isfile(path):
            response = {
                "type": "file_contents",
                "path": path,
                "error": "not_found"
            }
            await websocket.send(json.dumps(response))
            return

        ext = os.path.splitext(path)[1].lower()

        # Image files: base64-encode (except SVG which is text)
        if ext in IMAGE_EXTENSIONS:
            file_size = os.path.getsize(path)
            if file_size > MAX_IMAGE_SIZE:
                response = {
                    "type": "file_contents",
                    "path": path,
                    "error": "file_too_large",
                    "file_size": file_size
                }
            else:
                with open(path, 'rb') as f:
                    image_bytes = f.read()
                response = {
                    "type": "file_contents",
                    "path": path,
                    "image_data": base64.b64encode(image_bytes).decode('utf-8'),
                    "image_format": ext.lstrip('.'),
                    "file_size": file_size
                }
            await websocket.send(json.dumps(response))
            return

        # Text files: read as UTF-8
        try:
            with open(path, 'r', encoding='utf-8') as f:
                contents = f.read()

            response = {
                "type": "file_contents",
                "path": path,
                "contents": contents
            }
        except UnicodeDecodeError:
            response = {
                "type": "file_contents",
                "path": path,
                "error": "binary_file"
            }
        except PermissionError:
            response = {
                "type": "file_contents",
                "path": path,
                "error": "permission_denied"
            }

        await websocket.send(json.dumps(response))
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests PASS including the 5 new ones

**Step 5: Commit**

```bash
git add voice_server/ios_server.py voice_server/tests/test_message_handlers.py
git commit -m "feat: server returns base64 image data for image files"
```

---

### Task 2: iOS - Add Kingfisher dependency via SPM

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice.xcodeproj/project.pbxproj` (via Xcode CLI)

**Step 1: Add Kingfisher package**

This must be done through xcodebuild or by editing the Package.resolved. The simplest approach:

Add Kingfisher via Swift Package Manager by editing the Xcode project. If the project doesn't already use SPM packages, this creates the dependency structure.

Use `xcodebuild -resolvePackageDependencies` after adding.

Note: If SPM is not yet configured for this project, create a `Package.swift` or use the project's package dependencies. Check the project structure first.

**Step 2: Verify build**

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: Build succeeds with Kingfisher resolved

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/
git commit -m "feat: add Kingfisher dependency for image caching"
```

---

### Task 3: iOS - Update FileContentsResponse model and FileView for images

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/FileModels.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FileView.swift`

**Step 1: Update FileContentsResponse with image fields**

In `FileModels.swift`, replace `FileContentsResponse`:

```swift
struct FileContentsResponse: Codable {
    let type: String
    let path: String
    let contents: String?
    let error: String?
    let imageData: String?     // base64-encoded image bytes
    let imageFormat: String?   // "png", "jpg", etc.
    let fileSize: Int?         // file size in bytes

    enum CodingKeys: String, CodingKey {
        case type, path, contents, error
        case imageData = "image_data"
        case imageFormat = "image_format"
        case fileSize = "file_size"
    }
}
```

**Step 2: Update FileView to render images**

Replace the entire `FileView.swift` with:

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FileView.swift
import SwiftUI
import Kingfisher

struct FileView: View {
    @ObservedObject var webSocketManager: WebSocketManager
    let filePath: String
    @Binding var selectedFilePathBinding: String?

    @State private var contents: String?
    @State private var imageData: Data?
    @State private var error: String?
    @State private var fileSize: Int?
    @State private var isLoading = true
    @State private var imageScale: CGFloat = 1.0

    var fileName: String {
        (filePath as NSString).lastPathComponent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isLoading {
                Spacer()
                ProgressView("Loading...")
                Spacer()
            } else if let error = error {
                Spacer()
                VStack(spacing: 12) {
                    Image(systemName: errorIcon)
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text(errorMessage)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else if let imageData = imageData, let uiImage = UIImage(data: imageData) {
                // Image rendering with pinch-to-zoom
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .scaleEffect(imageScale)
                            .frame(
                                width: geometry.size.width * imageScale,
                                height: (geometry.size.width * imageScale) * (uiImage.size.height / uiImage.size.width)
                            )
                            .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        imageScale = max(0.5, min(value, 5.0))
                                    }
                            )
                            .onTapGesture(count: 2) {
                                withAnimation {
                                    imageScale = imageScale > 1.0 ? 1.0 : 2.0
                                }
                            }
                    }
                }
            } else if let contents = contents {
                GeometryReader { geometry in
                    ScrollView([.horizontal, .vertical]) {
                        FileContentView(contents: contents)
                            .frame(minHeight: geometry.size.height, alignment: .top)
                    }
                }
                .clipped()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .clipped()
        .customNavigationBar(
            title: fileName,
            breadcrumb: "Files",
            onBack: { selectedFilePathBinding = nil }
        ) {
            EmptyView()
        }
        .onAppear {
            loadFile()
        }
    }

    private var errorIcon: String {
        switch error {
        case "file_too_large": return "exclamationmark.triangle"
        case "binary_file": return "doc.questionmark"
        default: return "doc.questionmark"
        }
    }

    private var errorMessage: String {
        switch error {
        case "file_too_large":
            let mb = (fileSize ?? 0) / (1024 * 1024)
            return "File too large to preview (\(mb) MB)"
        case "binary_file":
            return "Cannot view contents"
        default:
            return "Error: \(error ?? "Unknown")"
        }
    }

    private func loadFile() {
        // Check Kingfisher cache first
        let cacheKey = filePath
        ImageCache.default.retrieveImage(forKey: cacheKey) { result in
            if case .success(let cacheResult) = result, let image = cacheResult.image,
               let data = image.pngData() {
                DispatchQueue.main.async {
                    self.imageData = data
                    self.isLoading = false
                }
                return
            }

            // Not cached - request from server
            self.requestFromServer()
        }
    }

    private func requestFromServer() {
        webSocketManager.onFileContents = { response in
            guard response.path == filePath else { return }
            isLoading = false

            if let err = response.error {
                error = err
                fileSize = response.fileSize
            } else if let base64String = response.imageData,
                      let data = Data(base64Encoded: base64String) {
                imageData = data

                // Cache the image with Kingfisher
                if let uiImage = UIImage(data: data) {
                    ImageCache.default.store(uiImage, forKey: filePath)
                }
            } else {
                contents = response.contents
            }
        }
        webSocketManager.readFile(path: filePath)
    }
}

struct FileContentView: View {
    let contents: String

    var lines: [(number: Int, text: String)] {
        contents.components(separatedBy: "\n").enumerated().map { ($0.offset + 1, $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines, id: \.number) { line in
                HStack(alignment: .top, spacing: 0) {
                    Text("\(line.number)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .frame(width: 40, alignment: .trailing)
                        .padding(.trailing, 8)

                    Text(line.text.isEmpty ? " " : line.text)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.primary)
                }
                .padding(.vertical, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.trailing, 8)
    }
}

#Preview {
    NavigationStack {
        FileView(
            webSocketManager: WebSocketManager(),
            filePath: "/Users/aaron/Desktop/max/README.md",
            selectedFilePathBinding: .constant("/Users/aaron/Desktop/max/README.md")
        )
    }
}
```

**Step 3: Build and verify**

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16'
```
Expected: Build succeeds

**CHECKPOINT:** Test manually by connecting iOS app to server, navigating to Files tab, and tapping an image file (e.g., `ui/current-projects.png` which exists in this repo). The image should render instead of showing "Cannot view contents". If it doesn't work, debug the WebSocket response and base64 decoding before proceeding.

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/FileModels.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/FileView.swift
git commit -m "feat: display image files in iOS Files tab with pinch-to-zoom and caching"
```

**Automated tests:** Server-side tests cover the image response format. iOS image rendering is visual/hardware-dependent.

**Manual verification (REQUIRED before merge):**
1. Connect iOS app to server
2. Navigate to Files tab in any project
3. Tap an image file (.png or .jpg)
4. Verify image renders (not "Cannot view contents")
5. Pinch to zoom in/out
6. Double-tap to toggle zoom
7. Navigate back and re-open - should load from cache (faster)
8. Try a file >10MB - should show "File too large to preview"
