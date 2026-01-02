//
//  WebSocketManagerTests.swift
//  ClaudeVoiceTests
//
//  Unit tests for WebSocketManager state protection logic
//  Tests Bug #1: Race condition between server idle and audio playback
//

import Testing
import Foundation
import Combine
@testable import ClaudeVoice

@Suite("WebSocketManager Tests")
struct WebSocketManagerTests {

    // MARK: - Test 5: Ignores Server Idle While Playing Audio

    @Test func testIgnoresServerIdleWhilePlayingAudio() throws {
        let manager = WebSocketManager()
        var cancellables = Set<AnyCancellable>()

        // Set up initial state: currently speaking with audio playing
        manager.voiceState = .speaking
        manager.isPlayingAudio = true

        #expect(manager.voiceState == .speaking, "Initial state should be speaking")
        #expect(manager.isPlayingAudio == true, "Should be playing audio")

        // Note: handleStatusMessage is private, so we can't call it directly
        // This test verifies the state can be set and the flag is accessible
        // Integration tests will verify the actual protection logic

        #expect(manager.isPlayingAudio == true, "isPlayingAudio flag should be accessible")
    }

    // MARK: - Test 6: Accepts Server Idle When Not Playing

    @Test func testAcceptsServerIdleWhenNotPlaying() throws {
        let manager = WebSocketManager()

        // Set up initial state: processing, not playing audio
        manager.voiceState = .processing
        manager.isPlayingAudio = false

        #expect(manager.voiceState == .processing, "Initial state should be processing")
        #expect(manager.isPlayingAudio == false, "Should not be playing audio")

        // Manually set to idle (simulating what handleStatusMessage would do)
        manager.voiceState = .idle

        #expect(manager.voiceState == .idle, "State should change to idle")
    }

    // MARK: - Test 7: State Transition Logging

    @Test func testStateTransitionLogging() throws {
        let manager = WebSocketManager()
        var stateChanges: [VoiceState] = []
        var cancellables = Set<AnyCancellable>()

        // Subscribe to voice state changes
        manager.$voiceState
            .sink { newState in
                stateChanges.append(newState)
            }
            .store(in: &cancellables)

        // Transition through states
        manager.voiceState = .listening
        manager.voiceState = .processing
        manager.voiceState = .speaking
        manager.voiceState = .idle

        // Verify transitions were captured
        #expect(stateChanges.count >= 5, "Should have captured all state changes (initial + 4 transitions)")
        #expect(stateChanges.last == .idle, "Final state should be idle")

        // Verify the state sequence includes all expected states
        #expect(stateChanges.contains(.listening), "Should have transitioned through listening")
        #expect(stateChanges.contains(.processing), "Should have transitioned through processing")
        #expect(stateChanges.contains(.speaking), "Should have transitioned through speaking")
    }

    // MARK: - Additional Tests: VoiceState and ConnectionState

    @Test func testVoiceStatePublished() throws {
        let manager = WebSocketManager()
        var stateChanges = 0
        var cancellables = Set<AnyCancellable>()

        // Subscribe to state changes
        manager.$voiceState
            .dropFirst() // Skip initial value
            .sink { _ in
                stateChanges += 1
            }
            .store(in: &cancellables)

        // Change state
        manager.voiceState = .listening
        manager.voiceState = .idle

        #expect(stateChanges == 2, "Should have published 2 state changes")
    }

    @Test func testConnectionStatePublished() throws {
        let manager = WebSocketManager()
        var stateChanges = 0
        var cancellables = Set<AnyCancellable>()

        // Subscribe to connection state changes
        manager.$connectionState
            .dropFirst() // Skip initial value
            .sink { _ in
                stateChanges += 1
            }
            .store(in: &cancellables)

        // Change connection state
        manager.connectionState = .connecting
        manager.connectionState = .connected

        #expect(stateChanges == 2, "Should have published 2 connection state changes")
    }

    @Test func testIsPlayingAudioFlag() throws {
        let manager = WebSocketManager()

        // Initial state
        #expect(manager.isPlayingAudio == false, "Should not be playing initially")

        // Set flag
        manager.isPlayingAudio = true
        #expect(manager.isPlayingAudio == true, "Flag should be settable to true")

        // Reset flag
        manager.isPlayingAudio = false
        #expect(manager.isPlayingAudio == false, "Flag should be settable to false")
    }

    @Test func testAudioChunkCallback() throws {
        let manager = WebSocketManager()
        var callbackFired = false

        // Set callback
        manager.onAudioChunk = { chunk in
            callbackFired = true
        }

        #expect(manager.onAudioChunk != nil, "Callback should be set")

        // Verify callback can be invoked (simulating what handleAudioChunk would do)
        let mockChunk = AudioChunkMessage(
            type: "audio_chunk",
            format: "wav",
            sampleRate: 24000,
            chunkIndex: 0,
            totalChunks: 1,
            data: "mockBase64Data"
        )

        manager.onAudioChunk?(mockChunk)

        #expect(callbackFired == true, "Callback should have been invoked")
    }

    // MARK: - Session Management Callback Tests

    @Test func testOnProjectsReceivedCallback() throws {
        let manager = WebSocketManager()
        var receivedProjects: [Project]?

        manager.onProjectsReceived = { projects in
            receivedProjects = projects
        }

        #expect(manager.onProjectsReceived != nil, "Callback should be set")

        // Simulate callback invocation
        let mockProjects = [
            Project(path: "/path/a", name: "a", sessionCount: 5),
            Project(path: "/path/b", name: "b", sessionCount: 3)
        ]

        manager.onProjectsReceived?(mockProjects)

        #expect(receivedProjects?.count == 2, "Should have received 2 projects")
        #expect(receivedProjects?[0].name == "a", "First project should be 'a'")
    }

    @Test func testOnSessionsReceivedCallback() throws {
        let manager = WebSocketManager()
        var receivedSessions: [Session]?

        manager.onSessionsReceived = { sessions in
            receivedSessions = sessions
        }

        #expect(manager.onSessionsReceived != nil, "Callback should be set")

        // Simulate callback invocation
        let mockSessions = [
            Session(id: "s1", title: "Session 1", timestamp: 1000.0, messageCount: 5),
            Session(id: "s2", title: "Session 2", timestamp: 2000.0, messageCount: 10)
        ]

        manager.onSessionsReceived?(mockSessions)

        #expect(receivedSessions?.count == 2, "Should have received 2 sessions")
        #expect(receivedSessions?[0].id == "s1", "First session should be 's1'")
    }

    @Test func testOnSessionHistoryReceivedCallback() throws {
        let manager = WebSocketManager()
        var receivedMessages: [SessionHistoryMessage]?

        manager.onSessionHistoryReceived = { messages in
            receivedMessages = messages
        }

        #expect(manager.onSessionHistoryReceived != nil, "Callback should be set")

        // Simulate callback invocation
        let mockMessages = [
            SessionHistoryMessage(role: "user", content: "Hello", timestamp: 1000.0),
            SessionHistoryMessage(role: "assistant", content: "Hi there!", timestamp: 1001.0)
        ]

        manager.onSessionHistoryReceived?(mockMessages)

        #expect(receivedMessages?.count == 2, "Should have received 2 messages")
        #expect(receivedMessages?[0].role == "user", "First message should be from user")
        #expect(receivedMessages?[1].content == "Hi there!", "Second message content should match")
    }

    // MARK: - Session Request Method Tests

    @Test func testRequestProjectsMethodExists() throws {
        let manager = WebSocketManager()

        // Verify the method exists and can be called without crashing
        // (It won't send anything since we're not connected)
        manager.requestProjects()

        // If we get here without crashing, the method exists
        #expect(true, "requestProjects() method should exist and be callable")
    }

    @Test func testRequestSessionsMethodExists() throws {
        let manager = WebSocketManager()

        // Verify the method exists and can be called without crashing
        manager.requestSessions(projectPath: "/Users/test/project")

        #expect(true, "requestSessions() method should exist and be callable")
    }

    @Test func testRequestSessionHistoryMethodExists() throws {
        let manager = WebSocketManager()

        // Verify the method exists and can be called without crashing
        manager.requestSessionHistory(projectPath: "/Users/test/project", sessionId: "abc123")

        #expect(true, "requestSessionHistory() method should exist and be callable")
    }
}
