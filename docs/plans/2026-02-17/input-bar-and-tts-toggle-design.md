# Input Bar + TTS Toggle Design

## Feature 1: Input Bar with Keyboard Accessory

### Overview
Replace the current mic-only bottom area in SessionView with a text field + keyboard accessory toolbar containing image picker and mic buttons.

### iOS UI Layout

**Always visible (keyboard up or down):**
- `TextField` with placeholder "Message Claude..."
- Above text field: horizontal row of image preview thumbnails (only when images attached), each with X to remove

**Keyboard accessory toolbar (above keyboard):**
- Left side: Image button (SF Symbol `photo`), Mic button (SF Symbol `mic`)
- Right side: Send button (SF Symbol `arrow.up.circle.fill`), active only when text or images present

**Behavior:**
- Tapping mic: same tap-to-talk as current. Transcription auto-fills text field and auto-sends
- Tapping image button: opens `PhotosPicker` (PhotosUI, iOS 16+). Multiple selection. Selected images appear as thumbnails
- Tapping send: dispatches text + any images via WebSocket, clears input
- When recording (mic active): show VoiceIndicator animation, disable text field

**SwiftUI approach:**
- Use `ToolbarItemGroup(placement: .keyboard)` for accessory buttons
- Fallback: if keyboard toolbar doesn't show when keyboard is dismissed, use a custom bottom bar with buttons inline. The bar naturally moves up with keyboard via safe area handling.

### Image Previews
- Horizontal `ScrollView` of 60x60pt thumbnails
- Each thumbnail has a small X button (top-right corner) to remove
- Show count badge if many images

### WebSocket Protocol

**New message type: `user_input`**
```json
{
  "type": "user_input",
  "text": "describe this image",
  "images": [
    {"data": "<base64>", "filename": "photo1.jpg"},
    {"data": "<base64>", "filename": "photo2.png"}
  ],
  "timestamp": 1234567890.0
}
```

Existing `voice_input` type remains unchanged for voice-only input (backward compatible).

When no images are attached, text-only sends can use either `voice_input` or `user_input` (server handles both).

### Server-Side Image Handling

1. Server receives `user_input` with images array
2. For each image: decode base64, save to `/tmp/claude_voice_img_<uuid>.<ext>`
3. Construct prompt: user's text + appended lines `[Image: /tmp/claude_voice_img_<uuid>.jpg]`
4. Send combined text to Claude Code via tmux `send_input`
5. Claude Code reads images via its Read tool at those paths
6. Temp files cleaned up on session close or server restart

---

## Feature 2: TTS Toggle

### Overview
Add a setting to disable TTS audio. When off, server skips audio generation entirely (saves CPU), and iOS ignores any audio chunks.

### iOS Side

**SettingsView:**
- New "Audio" section with Toggle: "Text-to-Speech"
- Stored via `@AppStorage("ttsEnabled")`, default `true`

**SessionView:**
- Read `ttsEnabled` from `@AppStorage`
- When `false`: don't pass audio chunks to `AudioPlayer` (ignore `onAudioChunk` callback)

**WebSocket preference sync:**
- On connect: send `{"type": "set_preference", "tts_enabled": true/false}`
- On toggle change: send same message immediately

### Server Side

**VoiceServer:**
- Store `tts_enabled` per client (default `true`)
- Handle `set_preference` message: update flag
- In TTS worker: check `tts_enabled` before generating audio. If `false`, skip `generate_tts_audio` call entirely
- Still send `assistant_response` content blocks (conversation text still appears)
- Still send idle status after response processing

---

## Risk Assessment

**Riskiest assumption:** `ToolbarItemGroup(placement: .keyboard)` behavior when keyboard is dismissed — buttons may not be visible.

**Mitigation:** If keyboard toolbar approach doesn't work, use a custom VStack with buttons row + text field at the bottom. This always renders and moves with the keyboard naturally.

**Verify early:** Build the input bar UI skeleton first, test keyboard show/hide on device before wiring image picking or server changes.

---

## Files to Modify

### iOS
- `SessionView.swift` — Replace mic area with input bar, add image previews, wire up text + image sending
- `SettingsView.swift` — Add TTS toggle in new Audio section
- `WebSocketManager.swift` — Add `sendUserInput(text:images:)` method, add `sendPreference(ttsEnabled:)` method
- `Message.swift` — Add `UserInputMessage` struct with images array, add `SetPreferenceMessage`

### Server
- `ios_server.py` — Handle `user_input` message type (save images, construct prompt), handle `set_preference`, add `tts_enabled` flag, gate TTS generation on flag
