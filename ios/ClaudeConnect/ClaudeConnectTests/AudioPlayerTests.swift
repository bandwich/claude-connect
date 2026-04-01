import Testing
import Foundation
@testable import ClaudeConnect

@Suite("AudioPlayer Tests")
struct AudioPlayerTests {

    @Test func initialStateIsNotPlaying() {
        let player = AudioPlayer()
        #expect(player.isPlaying == false)
    }

    @Test func callbacksAreNilByDefault() {
        let player = AudioPlayer()
        #expect(player.onPlaybackFinished == nil)
        #expect(player.onPlaybackStarted == nil)
    }

    @Test func stopWhenPlayingCallsFinishedCallback() {
        let player = AudioPlayer()
        var callbackFired = false
        player.onPlaybackFinished = { callbackFired = true }

        player.isPlaying = true
        player.stop()

        #expect(player.isPlaying == false)
        #expect(callbackFired == true)
    }

    @Test func stopWhenNotPlayingSkipsCallback() {
        let player = AudioPlayer()
        var callbackFired = false
        player.onPlaybackFinished = { callbackFired = true }

        player.stop()

        #expect(player.isPlaying == false)
        #expect(callbackFired == false)
    }

    @Test func receiveChunkDoesNotCrashInTestEnvironment() {
        let player = AudioPlayer()
        let chunk = AudioChunkMessage(
            type: "audio_chunk", format: "wav", sampleRate: 24000,
            chunkIndex: 0, totalChunks: 1, data: "dGVzdA=="
        )
        player.receiveAudioChunk(chunk)
        // isRunningUITests guard returns early — no crash, no state change
        #expect(player.isPlaying == false)
    }
}
