# Send Button State Reset Fix

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix bug where pressing Send while recording doesn't stop the mic, leaving the stop button visible and allowing stale text to reappear.

**Architecture:** Add a `cancelRecording()` method to `SpeechRecognizer` that stops audio and cancels the recognition task (so `onFinalTranscription` never fires). Call it from `sendTextMessage()` when recording is active, and clear `preRecordingText`.

**Tech Stack:** Swift/SwiftUI, iOS Speech framework

**Risky Assumptions:** Calling `recognitionTask?.cancel()` cleanly stops recognition without triggering the result callback with `isFinal=true`. The existing `startRecording()` method already calls `recognitionTask?.cancel()` on line 59 of SpeechRecognizer.swift, so this is a known-safe pattern.

---

### Task 1: Add `cancelRecording()` to SpeechRecognizer

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/SpeechRecognizer.swift:148` (after `stopRecording()`)

**Step 1: Add `cancelRecording()` method**

Add after the closing brace of `stopRecording()` (line 174):

```swift
    /// Cancel recording without triggering onFinalTranscription.
    /// Used when the message has already been sent and we don't want
    /// the recognizer to re-populate the text field.
    func cancelRecording() {
        print("🎤 SpeechRecognizer: cancelRecording() called")

        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        transcribedText = ""

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            print("🎤 SpeechRecognizer: Failed to deactivate audio session: \(error)")
        }

        DispatchQueue.main.async {
            self.isRecording = false
            self.onRecordingStopped?()
        }
    }
```

**Step 2: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/SpeechRecognizer.swift
git commit -m "feat: add cancelRecording() to SpeechRecognizer"
```

---

### Task 2: Call `cancelRecording()` from `sendTextMessage()`

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift:853-858` (end of `sendTextMessage()`)

**Step 1: Update `sendTextMessage()`**

Replace the clearing block at the end of `sendTextMessage()` (lines 853-857):

Before:
```swift
        // Clear input — resign focus first to prevent TextField's active editing
        // session from overriding the binding update back to the old value
        isTextFieldFocused = false
        messageText = ""
        attachedImages = []
```

After:
```swift
        // Cancel recording if active — must happen before clearing text so
        // onFinalTranscription doesn't re-populate messageText after send
        if speechRecognizer.isRecording {
            speechRecognizer.cancelRecording()
        }

        // Clear input — resign focus first to prevent TextField's active editing
        // session from overriding the binding update back to the old value
        isTextFieldFocused = false
        messageText = ""
        attachedImages = []
        preRecordingText = ""
```

**Step 2: Build to verify compilation**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```

Expected: BUILD SUCCEEDED

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "fix: stop recording and clear state when sending while mic is active"
```

---

### Task 3: Verify the fix

**Automated tests:** None — this bug involves real speech recognition hardware and timing-dependent UI state. The speech recognizer requires microphone access that can't be granted in simulator tests.

**Manual verification (REQUIRED before merge):**
1. Open app, connect to server, open a session
2. Tap mic, speak a phrase, see text appear in input field
3. Tap Send while the stop button (red) is still showing
4. **Verify:** Stop button disappears, text field clears, mic button (grey) returns to normal
5. **Verify:** The sent text does NOT reappear in the text field
6. Tap mic again, speak, stop, send normally — confirm normal flow still works

**CHECKPOINT:** Must pass manual verification.
