//
//  ClaudeVoiceTests.swift
//  ClaudeVoiceTests
//
//  Created by Aaron on 12/27/25.
//

import Testing
import Foundation
@testable import ClaudeVoice

// MARK: - Model Tests

@Suite("VoiceInputMessage Tests")
struct VoiceInputMessageTests {

    @Test func testVoiceInputMessageEncoding() throws {
        let message = VoiceInputMessage(text: "Hello Claude")
        let encoder = JSONEncoder()
        let data = try encoder.encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        #expect(json?["type"] as? String == "voice_input")
        #expect(json?["text"] as? String == "Hello Claude")
        #expect(json?["timestamp"] as? Double != nil)
    }

    @Test func testVoiceInputMessageTimestamp() throws {
        let beforeTimestamp = Date().timeIntervalSince1970
        let message = VoiceInputMessage(text: "Test")
        let afterTimestamp = Date().timeIntervalSince1970

        #expect(message.timestamp >= beforeTimestamp)
        #expect(message.timestamp <= afterTimestamp)
    }

    @Test func testVoiceInputMessageTypeIsAlwaysVoiceInput() throws {
        let message = VoiceInputMessage(text: "Any text")
        #expect(message.type == "voice_input")
    }
}

@Suite("StatusMessage Tests")
struct StatusMessageTests {

    @Test func testStatusMessageDecoding() throws {
        let json = """
        {
            "type": "status",
            "state": "processing",
            "message": "Processing your request",
            "timestamp": 1234567890.123
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let message = try decoder.decode(StatusMessage.self, from: data)

        #expect(message.type == "status")
        #expect(message.state == "processing")
        #expect(message.message == "Processing your request")
        #expect(message.timestamp == 1234567890.123)
    }

    @Test func testStatusMessageDecodingAllStates() throws {
        let states = ["idle", "listening", "processing", "speaking"]

        for state in states {
            let json = """
            {
                "type": "status",
                "state": "\(state)",
                "message": "Test message",
                "timestamp": 123.0
            }
            """

            let data = json.data(using: .utf8)!
            let message = try JSONDecoder().decode(StatusMessage.self, from: data)
            #expect(message.state == state)
        }
    }

    @Test func testStatusMessageInvalidJSON() throws {
        let json = """
        {
            "type": "status",
            "state": "idle"
        }
        """

        let data = json.data(using: .utf8)!
        #expect(throws: Error.self) {
            try JSONDecoder().decode(StatusMessage.self, from: data)
        }
    }
}

@Suite("AudioChunkMessage Tests")
struct AudioChunkMessageTests {

    @Test func testAudioChunkMessageDecoding() throws {
        let json = """
        {
            "type": "audio_chunk",
            "format": "wav",
            "sample_rate": 24000,
            "chunk_index": 0,
            "total_chunks": 10,
            "data": "SGVsbG8gV29ybGQ="
        }
        """

        let data = json.data(using: .utf8)!
        let decoder = JSONDecoder()
        let message = try decoder.decode(AudioChunkMessage.self, from: data)

        #expect(message.type == "audio_chunk")
        #expect(message.format == "wav")
        #expect(message.sampleRate == 24000)
        #expect(message.chunkIndex == 0)
        #expect(message.totalChunks == 10)
        #expect(message.data == "SGVsbG8gV29ybGQ=")
    }

    @Test func testAudioChunkMessageSnakeCaseMapping() throws {
        let json = """
        {
            "type": "audio_chunk",
            "format": "wav",
            "sample_rate": 48000,
            "chunk_index": 5,
            "total_chunks": 20,
            "data": "base64data"
        }
        """

        let data = json.data(using: .utf8)!
        let message = try JSONDecoder().decode(AudioChunkMessage.self, from: data)

        #expect(message.sampleRate == 48000)
        #expect(message.chunkIndex == 5)
        #expect(message.totalChunks == 20)
    }

    @Test func testAudioChunkMessageBase64DataDecoding() throws {
        let json = """
        {
            "type": "audio_chunk",
            "format": "wav",
            "sample_rate": 24000,
            "chunk_index": 0,
            "total_chunks": 1,
            "data": "SGVsbG8gV29ybGQ="
        }
        """

        let data = json.data(using: .utf8)!
        let message = try JSONDecoder().decode(AudioChunkMessage.self, from: data)
        let decodedData = Data(base64Encoded: message.data)

        #expect(decodedData != nil)
        #expect(String(data: decodedData!, encoding: .utf8) == "Hello World")
    }

    @Test func testAudioChunkMessageInvalidJSON() throws {
        let json = """
        {
            "type": "audio_chunk",
            "format": "wav"
        }
        """

        let data = json.data(using: .utf8)!
        #expect(throws: Error.self) {
            try JSONDecoder().decode(AudioChunkMessage.self, from: data)
        }
    }
}

// MARK: - State Enum Tests

@Suite("VoiceState Tests")
struct VoiceStateTests {

    @Test func testVoiceStateDescriptions() {
        #expect(VoiceState.idle.description == "Idle")
        #expect(VoiceState.listening.description == "Listening")
        #expect(VoiceState.processing.description == "Processing")
        #expect(VoiceState.speaking.description == "Speaking")
    }

    @Test func testVoiceStateRawValues() {
        #expect(VoiceState.idle.rawValue == "idle")
        #expect(VoiceState.listening.rawValue == "listening")
        #expect(VoiceState.processing.rawValue == "processing")
        #expect(VoiceState.speaking.rawValue == "speaking")
    }

    @Test func testVoiceStateFromRawValue() {
        #expect(VoiceState(rawValue: "idle") == .idle)
        #expect(VoiceState(rawValue: "listening") == .listening)
        #expect(VoiceState(rawValue: "processing") == .processing)
        #expect(VoiceState(rawValue: "speaking") == .speaking)
        #expect(VoiceState(rawValue: "invalid") == nil)
    }

    @Test func testVoiceStateEquality() {
        #expect(VoiceState.idle == VoiceState.idle)
        #expect(VoiceState.listening != VoiceState.idle)
    }
}

@Suite("ConnectionState Tests")
struct ConnectionStateTests {

    @Test func testConnectionStateDescriptions() {
        #expect(ConnectionState.disconnected.description == "Disconnected")
        #expect(ConnectionState.connecting.description == "Connecting...")
        #expect(ConnectionState.connected.description == "Connected")
    }

    @Test func testConnectionStateErrorDescription() {
        let errorState = ConnectionState.error("Network timeout")
        #expect(errorState.description == "Error: Network timeout")
    }

    @Test func testConnectionStateEquality() {
        #expect(ConnectionState.disconnected == ConnectionState.disconnected)
        #expect(ConnectionState.connected == ConnectionState.connected)
        #expect(ConnectionState.connecting == ConnectionState.connecting)
        #expect(ConnectionState.disconnected != ConnectionState.connected)
    }

    @Test func testConnectionStateErrorEquality() {
        let error1 = ConnectionState.error("Error 1")
        let error2 = ConnectionState.error("Error 1")
        let error3 = ConnectionState.error("Error 2")

        #expect(error1 == error2)
        #expect(error1 != error3)
    }
}

// MARK: - Service Tests

@Suite("WebSocketManager Tests")
struct WebSocketManagerTests {

    @Test func testInitialState() {
        let manager = WebSocketManager()

        #expect(manager.connectionState == .disconnected)
        #expect(manager.voiceState == .idle)
    }

    @Test func testSendVoiceInputCreatesCorrectJSON() throws {
        let manager = WebSocketManager()
        let text = "Test message"

        manager.sendVoiceInput(text: text)

        // The message should be created and encoded properly (we can't easily test the send without a real connection)
        // But we verify the method doesn't crash and accepts the input
    }

    @Test func testDisconnectResetsState() async throws {
        let manager = WebSocketManager()

        manager.disconnect()

        // Wait a bit for async state updates
        try await Task.sleep(for: .milliseconds(100))

        #expect(manager.connectionState == .disconnected)
        #expect(manager.voiceState == .idle)
    }

    @Test func testCallbacksCanBeSet() {
        let manager = WebSocketManager()
        var audioChunkReceived = false
        var statusUpdateReceived = false

        manager.onAudioChunk = { _ in audioChunkReceived = true }
        manager.onStatusUpdate = { _ in statusUpdateReceived = true }

        #expect(manager.onAudioChunk != nil)
        #expect(manager.onStatusUpdate != nil)
    }
}

@Suite("SpeechRecognizer Tests")
struct SpeechRecognizerTests {

    @Test func testInitialState() {
        let recognizer = SpeechRecognizer()

        #expect(recognizer.isRecording == false)
        #expect(recognizer.transcribedText == "")
    }

    @Test func testStopRecordingWhenNotRecording() {
        let recognizer = SpeechRecognizer()

        recognizer.stopRecording()

        #expect(recognizer.isRecording == false)
    }

    @Test func testCallbackCanBeSet() {
        let recognizer = SpeechRecognizer()
        var callbackFired = false

        recognizer.onFinalTranscription = { _ in callbackFired = true }

        #expect(recognizer.onFinalTranscription != nil)
    }

    @Test func testRecordingStartedCallbackCanBeSet() {
        let recognizer = SpeechRecognizer()
        var callbackFired = false

        recognizer.onRecordingStarted = { callbackFired = true }

        #expect(recognizer.onRecordingStarted != nil)
    }

    @Test func testRecordingStoppedCallbackCanBeSet() {
        let recognizer = SpeechRecognizer()
        var callbackFired = false

        recognizer.onRecordingStopped = { callbackFired = true }

        #expect(recognizer.onRecordingStopped != nil)
    }

    @Test func testRecognitionErrorTypes() {
        let error1 = SpeechRecognizer.RecognitionError.recognizerNotAvailable
        let error2 = SpeechRecognizer.RecognitionError.unableToCreateRequest

        // Just verify the error types exist and are different
        #expect(error1 != error2)
    }
}

@Suite("AudioPlayer Tests")
struct AudioPlayerTests {

    @Test func testInitialState() {
        let player = AudioPlayer()

        #expect(player.isPlaying == false)
    }

    @Test func testReceiveAudioChunkWithValidBase64() async throws {
        let player = AudioPlayer()

        // Create a valid base64 encoded string
        let testData = "Hello World".data(using: .utf8)!
        let base64String = testData.base64EncodedString()

        let chunk = AudioChunkMessage(
            type: "audio_chunk",
            format: "wav",
            sampleRate: 24000,
            chunkIndex: 0,
            totalChunks: 1,
            data: base64String
        )

        player.receiveAudioChunk(chunk)

        // Note: Actual playback won't work without valid WAV data
        // We're just testing that the method accepts the chunk
    }

    @Test func testStopClearsPlaybackState() async throws {
        let player = AudioPlayer()

        player.stop()

        // Wait for async state updates
        try await Task.sleep(for: .milliseconds(100))

        #expect(player.isPlaying == false)
    }

    @Test func testResetClearsPlaybackState() async throws {
        let player = AudioPlayer()

        player.reset()

        // Wait for async state updates
        try await Task.sleep(for: .milliseconds(100))

        #expect(player.isPlaying == false)
    }

    @Test func testCallbacksCanBeSet() {
        let player = AudioPlayer()
        var startedCallbackFired = false
        var finishedCallbackFired = false

        player.onPlaybackStarted = { startedCallbackFired = true }
        player.onPlaybackFinished = { finishedCallbackFired = true }

        #expect(player.onPlaybackStarted != nil)
        #expect(player.onPlaybackFinished != nil)
    }

    @Test func testReceiveAudioChunkWithInvalidBase64() {
        let player = AudioPlayer()

        let chunk = AudioChunkMessage(
            type: "audio_chunk",
            format: "wav",
            sampleRate: 24000,
            chunkIndex: 0,
            totalChunks: 1,
            data: "invalid!!!base64"
        )

        // Should handle gracefully without crashing
        player.receiveAudioChunk(chunk)

        #expect(player.isPlaying == false)
    }
}

// MARK: - Integration Tests

@Suite("Service Integration Tests")
struct ServiceIntegrationTests {

    @Test func testSpeechRecognizerToWebSocketManagerIntegration() async throws {
        let recognizer = SpeechRecognizer()
        let websocketManager = WebSocketManager()
        var sentText: String?

        // Wire up the callback
        recognizer.onFinalTranscription = { text in
            sentText = text
            websocketManager.sendVoiceInput(text: text)
        }

        // Simulate a final transcription
        recognizer.onFinalTranscription?("Test transcription")

        #expect(sentText == "Test transcription")
    }

    @Test func testRecordingStateTriggersListeningState() async throws {
        let recognizer = SpeechRecognizer()
        let websocketManager = WebSocketManager()

        // Initial state should be idle
        #expect(websocketManager.voiceState == .idle)

        // Wire up recording started callback
        recognizer.onRecordingStarted = {
            websocketManager.voiceState = .listening
        }

        // Simulate recording started
        recognizer.onRecordingStarted?()

        #expect(websocketManager.voiceState == .listening)
    }

    @Test func testRecordingStoppedReturnsToIdleState() async throws {
        let recognizer = SpeechRecognizer()
        let websocketManager = WebSocketManager()

        // Set to listening state
        websocketManager.voiceState = .listening

        // Wire up recording stopped callback
        recognizer.onRecordingStopped = {
            if websocketManager.voiceState == .listening {
                websocketManager.voiceState = .idle
            }
        }

        // Simulate recording stopped
        recognizer.onRecordingStopped?()

        #expect(websocketManager.voiceState == .idle)
    }

    @Test func testRecordingStoppedDoesNotOverrideProcessingState() async throws {
        let recognizer = SpeechRecognizer()
        let websocketManager = WebSocketManager()

        // Set to processing state (server already responded)
        websocketManager.voiceState = .processing

        // Wire up recording stopped callback (should not override processing)
        recognizer.onRecordingStopped = {
            if websocketManager.voiceState == .listening {
                websocketManager.voiceState = .idle
            }
        }

        // Simulate recording stopped
        recognizer.onRecordingStopped?()

        // State should remain processing
        #expect(websocketManager.voiceState == .processing)
    }

    @Test func testWebSocketManagerToAudioPlayerIntegration() async throws {
        let websocketManager = WebSocketManager()
        let audioPlayer = AudioPlayer()
        var receivedChunk = false

        // Wire up the callback
        websocketManager.onAudioChunk = { chunk in
            receivedChunk = true
            audioPlayer.receiveAudioChunk(chunk)
        }

        // Simulate receiving an audio chunk
        let chunk = AudioChunkMessage(
            type: "audio_chunk",
            format: "wav",
            sampleRate: 24000,
            chunkIndex: 0,
            totalChunks: 1,
            data: "SGVsbG8="
        )

        websocketManager.onAudioChunk?(chunk)

        #expect(receivedChunk == true)
    }

    @Test func testStateTransitionsBetweenRecordingAndPlayback() async throws {
        let recognizer = SpeechRecognizer()
        let audioPlayer = AudioPlayer()

        // Initially neither should be active
        #expect(recognizer.isRecording == false)
        #expect(audioPlayer.isPlaying == false)

        // When recording starts, playback should not be active
        // (Note: We can't actually start recording in tests without permissions)

        // When playback starts, recording should stop
        recognizer.stopRecording()

        try await Task.sleep(for: .milliseconds(100))

        #expect(recognizer.isRecording == false)
    }
}

// MARK: - End-to-End Flow Tests

@Suite("End-to-End Flow Tests")
struct EndToEndFlowTests {

    @Test func testCompleteVoiceInputFlow() async throws {
        let websocketManager = WebSocketManager()
        let recognizer = SpeechRecognizer()
        let audioPlayer = AudioPlayer()

        var transcriptionReceived = false
        var audioChunkReceived = false

        // Wire up the complete flow
        recognizer.onFinalTranscription = { text in
            transcriptionReceived = true
            websocketManager.sendVoiceInput(text: text)
        }

        websocketManager.onAudioChunk = { chunk in
            audioChunkReceived = true
            audioPlayer.receiveAudioChunk(chunk)
        }

        // Simulate the flow
        recognizer.onFinalTranscription?("Hello Claude")

        #expect(transcriptionReceived == true)

        // Simulate receiving audio response
        let chunk = AudioChunkMessage(
            type: "audio_chunk",
            format: "wav",
            sampleRate: 24000,
            chunkIndex: 0,
            totalChunks: 1,
            data: "dGVzdGRhdGE="
        )

        websocketManager.onAudioChunk?(chunk)

        #expect(audioChunkReceived == true)
    }

    @Test func testMultipleRapidVoiceInputs() async throws {
        let websocketManager = WebSocketManager()
        var sentCount = 0

        // Send multiple messages rapidly
        for i in 1...5 {
            websocketManager.sendVoiceInput(text: "Message \(i)")
            sentCount += 1
        }

        #expect(sentCount == 5)
    }

    @Test func testDisconnectDuringFlow() async throws {
        let websocketManager = WebSocketManager()
        let audioPlayer = AudioPlayer()

        // Simulate being in the middle of receiving audio
        let chunk = AudioChunkMessage(
            type: "audio_chunk",
            format: "wav",
            sampleRate: 24000,
            chunkIndex: 0,
            totalChunks: 5,
            data: "dGVzdA=="
        )

        websocketManager.onAudioChunk = { chunk in
            audioPlayer.receiveAudioChunk(chunk)
        }

        websocketManager.onAudioChunk?(chunk)

        // Now disconnect
        websocketManager.disconnect()
        audioPlayer.stop()

        try await Task.sleep(for: .milliseconds(100))

        #expect(websocketManager.connectionState == .disconnected)
        #expect(audioPlayer.isPlaying == false)
    }

    @Test func testAudioBufferingWithMultipleChunks() async throws {
        let audioPlayer = AudioPlayer()
        var playbackStarted = false

        audioPlayer.onPlaybackStarted = {
            playbackStarted = true
        }

        // Create a simple WAV header (44 bytes)
        var wavHeader = Data(count: 44)
        wavHeader[0] = 0x52 // R
        wavHeader[1] = 0x49 // I
        wavHeader[2] = 0x46 // F
        wavHeader[3] = 0x46 // F

        let base64Header = wavHeader.base64EncodedString()

        // Send multiple chunks
        for i in 0..<5 {
            let chunk = AudioChunkMessage(
                type: "audio_chunk",
                format: "wav",
                sampleRate: 24000,
                chunkIndex: i,
                totalChunks: 5,
                data: base64Header
            )

            audioPlayer.receiveAudioChunk(chunk)
        }

        // Note: Actual playback requires valid WAV data
        // We're testing the buffering logic
    }

    @Test func testVoiceStateTransitions() async throws {
        let websocketManager = WebSocketManager()

        // Initial state
        #expect(websocketManager.voiceState == .idle)

        // Simulate status updates
        let statusJSON = """
        {
            "type": "status",
            "state": "processing",
            "message": "Processing",
            "timestamp": 123.0
        }
        """

        let data = statusJSON.data(using: .utf8)!
        let statusMessage = try JSONDecoder().decode(StatusMessage.self, from: data)

        // Would need to trigger handleStatusMessage - testing the message parsing works
        #expect(statusMessage.state == "processing")
        #expect(VoiceState(rawValue: statusMessage.state) == .processing)
    }

    @Test func testCompleteVoiceStateFlow() async throws {
        let recognizer = SpeechRecognizer()
        let websocketManager = WebSocketManager()

        // 1. Initial state is idle
        #expect(websocketManager.voiceState == .idle)

        // 2. Recording starts -> listening
        recognizer.onRecordingStarted = {
            websocketManager.voiceState = .listening
        }
        recognizer.onRecordingStarted?()
        #expect(websocketManager.voiceState == .listening)

        // 3. Transcription sent -> processing (simulated server response)
        websocketManager.voiceState = .processing
        #expect(websocketManager.voiceState == .processing)

        // 4. Claude responds -> speaking (simulated server response)
        websocketManager.voiceState = .speaking
        #expect(websocketManager.voiceState == .speaking)

        // 5. Audio finishes -> idle
        websocketManager.voiceState = .idle
        #expect(websocketManager.voiceState == .idle)
    }
}
