# Input Bar + TTS Toggle — Phase 2: Image Input

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Add image picker support to the input bar. Users can attach photos from their library, see previews, and send them with text to Claude Code.

**Architecture:** iOS uses `PhotosPicker` (PhotosUI framework) to select images. Selected images are shown as thumbnails above the input bar. On send, images are base64-encoded and included in the existing `user_input` WebSocket message. Server-side image handling was already implemented in Phase 1 (Task 5).

**Tech Stack:** Swift/SwiftUI (PhotosUI framework), iOS 16+

**Risky Assumptions:** `PhotosPicker` thumbnail loading via `PhotosPickerItem.loadTransferable` should work smoothly. Large images may cause WebSocket message size issues — we'll compress to JPEG at 0.7 quality before sending.

**Prerequisite:** Phase 1 must be complete and verified working.

---

### Task 1: Add image state and PhotosPicker to SessionView

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Add imports and state**

Add `PhotosUI` import at the top of SessionView.swift (after `import SwiftUI`):

```swift
import PhotosUI
```

Add state variables to SessionView (after the `messageText` state added in Phase 1):

```swift
@State private var selectedPhotos: [PhotosPickerItem] = []
@State private var attachedImages: [AttachedImage] = []
@State private var showingPhotoPicker = false
```

Add a helper struct at the bottom of the file (before `MessageBubble`):

```swift
struct AttachedImage: Identifiable {
    let id = UUID()
    let uiImage: UIImage
    let filename: String
}
```

**Step 2: Update canSend to include images**

Modify the `canSend` computed property to also return true when images are attached:

```swift
private var canSend: Bool {
    guard isSessionSynced else { return false }
    guard webSocketManager.outputState.canSendVoiceInput else { return false }
    if case .connected = webSocketManager.connectionState {
        let hasText = !messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasText || !attachedImages.isEmpty
    }
    return false
}
```

**Step 3: Add image preview row above the input bar**

In the input bar area (the `else` branch after sync/error states), add the image preview row before the HStack with the text field. The structure should be:

```swift
                } else {
                    VStack(spacing: 0) {
                        // Image previews
                        if !attachedImages.isEmpty {
                            ScrollView(.horizontal, showsIndicators: false) {
                                HStack(spacing: 8) {
                                    ForEach(attachedImages) { img in
                                        ZStack(alignment: .topTrailing) {
                                            Image(uiImage: img.uiImage)
                                                .resizable()
                                                .aspectRatio(contentMode: .fill)
                                                .frame(width: 60, height: 60)
                                                .clipShape(RoundedRectangle(cornerRadius: 8))

                                            Button {
                                                attachedImages.removeAll { $0.id == img.id }
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .font(.system(size: 18))
                                                    .foregroundColor(.white)
                                                    .background(Circle().fill(Color.black.opacity(0.6)))
                                            }
                                            .offset(x: 4, y: -4)
                                        }
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                            }
                        }

                        // Input area with text field and buttons
                        HStack(alignment: .bottom, spacing: 8) {
                            // Image picker button
                            Button {
                                showingPhotoPicker = true
                            } label: {
                                Image(systemName: "photo")
                                    .font(.system(size: 20))
                                    .foregroundColor(.secondary)
                                    .frame(width: 36, height: 36)
                            }
                            .disabled(speechRecognizer.isRecording)
                            .accessibilityIdentifier("imagePickerButton")

                            // Text field
                            TextField("Message Claude...", text: $messageText, axis: .vertical)
                                .lineLimit(1...5)
                                .textFieldStyle(.plain)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color(.systemGray6))
                                .cornerRadius(20)
                                .disabled(speechRecognizer.isRecording)
                                .accessibilityIdentifier("messageTextField")

                            // Mic button
                            Button(action: toggleRecording) {
                                Image(systemName: speechRecognizer.isRecording ? "stop.fill" : "mic.fill")
                                    .font(.system(size: 20))
                                    .foregroundColor(speechRecognizer.isRecording ? .red : .secondary)
                                    .frame(width: 36, height: 36)
                            }
                            .accessibilityLabel(speechRecognizer.isRecording ? "Stop" : "Tap to Talk")
                            .disabled(!speechRecognizer.isRecording && !canRecord)
                            .accessibilityIdentifier("micButton")

                            // Send button
                            if canSend {
                                Button(action: sendTextMessage) {
                                    Image(systemName: "arrow.up.circle.fill")
                                        .font(.system(size: 30))
                                        .foregroundColor(.blue)
                                }
                                .accessibilityLabel("Send")
                                .accessibilityIdentifier("sendButton")
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
```

**Step 4: Add PhotosPicker sheet and onChange handler**

Add to the SessionView body, after `.enableSwipeBack()` (around line 159):

```swift
.photosPicker(isPresented: $showingPhotoPicker, selection: $selectedPhotos, maxSelectionCount: 5, matching: .images)
.onChange(of: selectedPhotos) { _, newItems in
    Task {
        for item in newItems {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                let filename = "photo_\(UUID().uuidString.prefix(8)).jpg"
                attachedImages.append(AttachedImage(uiImage: uiImage, filename: filename))
            }
        }
        selectedPhotos = []  // Reset picker selection
    }
}
```

**Step 5: Build to verify compilation**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: add PhotosPicker and image preview thumbnails to input bar"
```

---

### Task 2: Wire image sending through sendUserInput

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Update sendTextMessage to include images**

Replace the `sendTextMessage` function with:

```swift
private func sendTextMessage() {
    let text = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !attachedImages.isEmpty else { return }

    // Build display text for conversation (include image count)
    var displayText = text
    if !attachedImages.isEmpty {
        let imgCount = attachedImages.count
        let suffix = imgCount == 1 ? "1 image" : "\(imgCount) images"
        if displayText.isEmpty {
            displayText = "[\(suffix)]"
        } else {
            displayText += " [\(suffix)]"
        }
    }

    // Add to conversation items locally
    let userMessage = SessionHistoryMessage(
        role: "user",
        content: displayText,
        timestamp: Date().timeIntervalSince1970
    )
    items.append(.textMessage(userMessage))

    // Track for server echo dedup
    lastVoiceInputText = text
    lastVoiceInputTime = Date()

    // Encode images as base64 JPEG
    let imageAttachments = attachedImages.map { img -> ImageAttachment in
        let jpegData = img.uiImage.jpegData(compressionQuality: 0.7) ?? Data()
        return ImageAttachment(
            data: jpegData.base64EncodedString(),
            filename: img.filename
        )
    }

    // Send via WebSocket
    webSocketManager.sendUserInput(text: text, images: imageAttachments)

    // Clear input
    messageText = ""
    attachedImages = []
}
```

**Step 2: Build to verify compilation**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: wire image attachments into sendUserInput with JPEG compression"
```

---

### CHECKPOINT: Verify Image Input End-to-End

1. **Reinstall server:** `pipx install --force /Users/aaron/Desktop/max`
2. **Build and install iOS app** on device
3. **Test image picker:** Tap image button, select 1-2 photos. Verify thumbnails appear above input bar. Tap X to remove one.
4. **Test image + text send:** Type "what is in this image?" with an image attached. Tap send. Verify Claude receives the text with image path reference and responds about the image content.
5. **Test text-only send still works:** Send a text message with no images. Verify it works as before.
6. **Test voice still works:** Tap mic, speak. Verify voice input still sends correctly.

**Automated tests:** Manual verification only for this task. PhotosPicker requires real photo library access which can't be automated in XCUITest without significant infrastructure. The server-side image handling was already tested in Phase 1 Task 5.

**Manual verification (REQUIRED before merge):**
1. Select 3 images from photo picker — all 3 thumbnails appear
2. Remove middle image via X — remaining 2 images show correctly
3. Send text + 2 images — Claude responds referencing image content
4. Send text-only (no images) — works as before
5. Use voice mic — works as before (no regressions)

**CHECKPOINT:** Must pass manual verification.
