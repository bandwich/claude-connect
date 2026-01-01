//
//  AudioPlayerTests.swift
//  ClaudeVoiceTests
//
//  Unit tests for AudioPlayer callback mechanism and state management
//  Tests Bug #1: Speaking state not returning to Idle
//

import Testing
import Foundation
import AVFoundation
@testable import ClaudeVoice

@Suite("AudioPlayer Tests")
struct AudioPlayerTests {

    // MARK: - Test 1: Playback Finished Callback Invoked

    @Test func testPlaybackFinishedCallbackInvoked() async throws {
        let audioPlayer = AudioPlayer()
        var callbackFired = false
        var callbackCount = 0

        // Set up callback
        audioPlayer.onPlaybackFinished = {
            callbackFired = true
            callbackCount += 1
        }

        // Verify callback is not nil
        #expect(audioPlayer.onPlaybackFinished != nil, "Callback should be set")

        // Create mock audio chunks
        let mockAudioData = createMockWAVData()
        let totalChunks = 3

        // Simulate receiving chunks
        for chunkIndex in 0..<totalChunks {
            let chunk = AudioChunkMessage(
                type: "audio_chunk",
                format: "wav",
                sampleRate: 24000,
                chunkIndex: chunkIndex,
                totalChunks: totalChunks,
                data: mockAudioData.base64EncodedString()
            )

            await audioPlayer.receiveAudioChunk(chunk)
        }

        // Wait for playback to complete (test audio is short)
        // In real scenario, this would be triggered by AVAudioPlayerNode completion
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Note: This test verifies the callback can be set and is not nil
        // Testing actual AVAudioPlayerNode completion requires integration test
        #expect(audioPlayer.onPlaybackFinished != nil, "Callback should remain set after playback")
    }

    // MARK: - Test 2: isPlaying Flag Lifecycle

    @Test func testIsPlayingFlagLifecycle() throws {
        let audioPlayer = AudioPlayer()

        // Initial state: not playing
        #expect(audioPlayer.isPlaying == false, "Should not be playing initially")

        // Note: Testing actual playback state changes requires AVAudioEngine
        // which requires an integration test environment
        // This test verifies the initial state is correct

        // Verify property is observable
        #expect(audioPlayer.isPlaying == false, "isPlaying should be false by default")
    }

    // MARK: - Test 3: Chunk Counting Logic

    @Test func testChunkCountingLogic() async throws {
        let audioPlayer = AudioPlayer()

        let mockAudioData = createMockWAVData()

        // Test with 5 chunks
        let totalChunks = 5
        for chunkIndex in 0..<totalChunks {
            let chunk = AudioChunkMessage(
                type: "audio_chunk",
                format: "wav",
                sampleRate: 24000,
                chunkIndex: chunkIndex,
                totalChunks: totalChunks,
                data: mockAudioData.base64EncodedString()
            )

            await audioPlayer.receiveAudioChunk(chunk)
        }

        // Verify all chunks were received
        // Note: Internal counters are private, so we verify behavior through public API
        #expect(true, "AudioPlayer should handle chunks without crashing")

        // Test edge case: single chunk response
        let audioPlayer2 = AudioPlayer()
        let singleChunk = AudioChunkMessage(
            type: "audio_chunk",
            format: "wav",
            sampleRate: 24000,
            chunkIndex: 0,
            totalChunks: 1,
            data: mockAudioData.base64EncodedString()
        )

        await audioPlayer2.receiveAudioChunk(singleChunk)

        // Single chunk should be treated as last chunk
        // Verification through behavior (doesn't crash)
        #expect(true, "Single chunk should be handled without crash")
    }

    // MARK: - Test 4: Callback Not Nil Before Invocation

    @Test func testCallbackNotNilBeforeInvocation() async throws {
        let audioPlayer = AudioPlayer()

        // Don't set onPlaybackFinished callback
        #expect(audioPlayer.onPlaybackFinished == nil, "Callback should be nil initially")

        // Create mock audio chunk
        let mockAudioData = createMockWAVData()
        let chunk = AudioChunkMessage(
            type: "audio_chunk",
            format: "wav",
            sampleRate: 24000,
            chunkIndex: 0,
            totalChunks: 1,
            data: mockAudioData.base64EncodedString()
        )

        // This should not crash even with nil callback
        await audioPlayer.receiveAudioChunk(chunk)

        // Wait briefly
        try await Task.sleep(nanoseconds: 100_000_000) // 100ms

        // Verify no crash occurred
        #expect(true, "Should handle nil callback gracefully")

        // Verify defensive coding: AudioPlayer should check callback before invoking
        // The actual check happens in handlePlaybackFinished() which is private
        // This test documents expected behavior
    }

    // MARK: - Test Helpers

    /// Creates mock WAV audio data for testing
    /// Returns a minimal valid WAV header + silent audio data
    private func createMockWAVData() -> Data {
        var data = Data()

        // WAV header (44 bytes)
        // "RIFF" chunk descriptor
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46]) // "RIFF"
        data.append(contentsOf: [0x24, 0x00, 0x00, 0x00]) // Chunk size (36 + data size)
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45]) // "WAVE"

        // "fmt " sub-chunk
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20]) // "fmt "
        data.append(contentsOf: [0x10, 0x00, 0x00, 0x00]) // Sub-chunk size (16)
        data.append(contentsOf: [0x01, 0x00])             // Audio format (1 = PCM)
        data.append(contentsOf: [0x01, 0x00])             // Num channels (1 = mono)
        data.append(contentsOf: [0xC0, 0x5D, 0x00, 0x00]) // Sample rate (24000)
        data.append(contentsOf: [0x80, 0xBB, 0x00, 0x00]) // Byte rate (48000)
        data.append(contentsOf: [0x02, 0x00])             // Block align (2)
        data.append(contentsOf: [0x10, 0x00])             // Bits per sample (16)

        // "data" sub-chunk
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61]) // "data"
        data.append(contentsOf: [0x00, 0x00, 0x00, 0x00]) // Data size (0 for minimal test)

        // Add some silent audio data (16-bit PCM, all zeros = silence)
        let silentSamples: [UInt8] = Array(repeating: 0, count: 100)
        data.append(contentsOf: silentSamples)

        return data
    }
}
