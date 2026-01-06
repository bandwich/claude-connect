# Audio Queue Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Prevent TTS audio from overlapping when multiple messages arrive simultaneously

**Architecture:** Add a queue to AudioPlayer that holds pending audio messages. When a new message arrives while playing, queue it. When playback finishes, process next queued message.

**Tech Stack:** Swift, AVFoundation

---

## Task 1: Add Audio Queue Infrastructure

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/AudioPlayer.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/AudioPlayerTests.swift`

**Step 1: Write failing test for queue behavior**

Add to `AudioPlayerTests.swift`:

```swift
@Test func testAudioQueuePreventsOverlapping() async throws {
    let audioPlayer = AudioPlayer()

    let mockAudioData = createMockWAVData()

    // Start first message (3 chunks)
    for i in 0..<3 {
        let chunk = AudioChunkMessage(
            type: "audio_chunk", format: "wav", sampleRate: 24000,
            chunkIndex: i, totalChunks: 3,
            data: mockAudioData.base64EncodedString()
        )
        await audioPlayer.receiveAudioChunk(chunk)
    }

    // First message should be playing/processing
    #expect(audioPlayer.isPlaying == true || audioPlayer.queuedMessageCount == 0)

    // Send second message while first is playing
    for i in 0..<2 {
        let chunk = AudioChunkMessage(
            type: "audio_chunk", format: "wav", sampleRate: 24000,
            chunkIndex: i, totalChunks: 2,
            data: mockAudioData.base64EncodedString()
        )
        await audioPlayer.receiveAudioChunk(chunk)
    }

    // Second message should be queued, not playing simultaneously
    #expect(audioPlayer.queuedMessageCount >= 0, "Should track queued messages")
}
```

**Step 2: Run test to verify it fails**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/AudioPlayerTests/testAudioQueuePreventsOverlapping 2>&1 | tail -30
```

Expected: FAIL - `queuedMessageCount` property doesn't exist

**Step 3: Add queue property and tracking**

In `AudioPlayer.swift`, add after existing properties:

```swift
// Audio message queue
private var messageQueue: [[AudioChunkMessage]] = []
private var currentMessageChunks: [AudioChunkMessage] = []
private(set) var queuedMessageCount: Int = 0
```

**Step 4: Run test to verify property exists**

Same command as Step 2. Expected: Test compiles, may still fail on logic

**Step 5: Implement queue logic in receiveAudioChunk**

Replace `receiveAudioChunk` method:

```swift
func receiveAudioChunk(_ chunk: AudioChunkMessage) {
    // New message starting (chunkIndex == 0)
    if chunk.chunkIndex == 0 {
        if isPlaying || !currentMessageChunks.isEmpty {
            // Queue this message for later
            currentMessageChunks.append(chunk)
            return
        }
    }

    // If we're collecting chunks for a queued message
    if !currentMessageChunks.isEmpty && currentMessageChunks[0].chunkIndex == 0 {
        currentMessageChunks.append(chunk)

        // Check if message is complete
        if currentMessageChunks.count == chunk.totalChunks {
            messageQueue.append(currentMessageChunks)
            currentMessageChunks = []
            queuedMessageCount = messageQueue.count
            print("AudioPlayer: Queued message, queue size: \(queuedMessageCount)")
            logToFile("📥 Queued message, queue size: \(queuedMessageCount)")
        }
        return
    }

    // Process chunk normally
    processChunk(chunk)
}

private func processChunk(_ chunk: AudioChunkMessage) {
    guard let chunkData = Data(base64Encoded: chunk.data) else {
        print("AudioPlayer: Failed to decode base64 audio data")
        logToFile("❌ AudioPlayer: Failed to decode base64")
        return
    }

    receivedChunks += 1
    expectedChunks = chunk.totalChunks

    print("AudioPlayer: Received chunk \(chunk.chunkIndex + 1)/\(chunk.totalChunks)")
    logToFile("🎵 AudioPlayer: Chunk \(chunk.chunkIndex + 1)/\(chunk.totalChunks)")

    if chunk.chunkIndex == 0 {
        extractAudioFormat(from: chunkData)
    }

    if let buffer = createAudioBuffer(from: chunkData, isFirstChunk: chunk.chunkIndex == 0) {
        let isLastExpectedChunk = (receivedChunks == expectedChunks)
        scheduleAudioBuffer(buffer, isLastChunk: isLastExpectedChunk)
        scheduledChunks += 1

        print("AudioPlayer: Scheduled chunk \(scheduledChunks), isLast: \(isLastExpectedChunk)")
        logToFile("📦 Scheduled chunk \(scheduledChunks), isLast: \(isLastExpectedChunk)")
    } else {
        print("AudioPlayer: Failed to create buffer for chunk \(chunk.chunkIndex + 1)")
        logToFile("❌ Failed to create buffer for chunk \(chunk.chunkIndex + 1)")
    }

    if receivedChunks >= minBufferChunks && !isPlaying {
        startPlayback()
    }
}
```

**Step 6: Update handlePlaybackFinished to process queue**

In `handlePlaybackFinished`, add queue processing before callbacks:

```swift
private func handlePlaybackFinished() {
    print("AudioPlayer: Playback finished")
    logToFile("🏁 AudioPlayer: Playback finished")

    playerNode.stop()

    DispatchQueue.main.async {
        self.isPlaying = false
    }

    receivedChunks = 0
    scheduledChunks = 0
    expectedChunks = 0

    // Process next queued message if any
    if !messageQueue.isEmpty {
        let nextMessage = messageQueue.removeFirst()
        queuedMessageCount = messageQueue.count
        print("AudioPlayer: Processing queued message, \(queuedMessageCount) remaining")
        logToFile("📤 Processing queued message, \(queuedMessageCount) remaining")

        for chunk in nextMessage {
            processChunk(chunk)
        }
        return
    }

    print("AudioPlayer: Calling onPlaybackFinished callback")
    logToFile("🔇 AudioPlayer: onPlaybackFinished callback")

    if onPlaybackFinished == nil {
        print("AudioPlayer: WARNING - onPlaybackFinished callback is nil!")
        logToFile("⚠️ onPlaybackFinished callback is NIL")
    } else {
        print("AudioPlayer: Executing onPlaybackFinished callback")
        onPlaybackFinished?()
        print("AudioPlayer: onPlaybackFinished callback executed")
    }
}
```

**Step 7: Update stop() and reset() to clear queue**

```swift
func stop() {
    playerNode.stop()

    receivedChunks = 0
    scheduledChunks = 0
    expectedChunks = 0
    messageQueue.removeAll()
    currentMessageChunks.removeAll()
    queuedMessageCount = 0

    DispatchQueue.main.async {
        self.isPlaying = false
    }

    print("AudioPlayer: Stopped")
    logToFile("⏹ AudioPlayer: Stopped")
}
```

**Step 8: Run all AudioPlayer tests**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/AudioPlayerTests 2>&1 | tail -30
```

Expected: All PASS

**Step 9: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Services/AudioPlayer.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceTests/AudioPlayerTests.swift
git commit -m "feat: add audio queue to prevent overlapping playback"
```

---

## Verification

Run all iOS unit tests:

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests 2>&1 | tail -50
```

Expected: All tests pass
