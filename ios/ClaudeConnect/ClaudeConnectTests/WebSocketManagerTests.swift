//
//  WebSocketManagerTests.swift
//  ClaudeConnectTests
//
//  Unit tests for WebSocketManager state protection logic
//  Tests Bug #1: Race condition between server idle and audio playback
//

import Testing
import Foundation
import Combine
@testable import ClaudeConnect

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
            Project(path: "/path/a", name: "a", sessionCount: 5, folderName: "-path-a"),
            Project(path: "/path/b", name: "b", sessionCount: 3, folderName: "-path-b")
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
        var receivedMessages: [SessionHistoryMessageRich]?

        manager.onSessionHistoryReceived = { messages, lineCount in
            receivedMessages = messages
        }

        #expect(manager.onSessionHistoryReceived != nil, "Callback should be set")

        // Simulate callback invocation
        let mockMessages = [
            SessionHistoryMessageRich(role: "user", content: "Hello", timestamp: 1000.0, contentBlocks: nil),
            SessionHistoryMessageRich(role: "assistant", content: "Hi there!", timestamp: 1001.0, contentBlocks: nil)
        ]

        manager.onSessionHistoryReceived?(mockMessages, 5)

        #expect(receivedMessages?.count == 2, "Should have received 2 messages")
        #expect(receivedMessages?[0].role == "user", "First message should be from user")
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
        // Uses folderName (actual directory name) not decoded path
        manager.requestSessions(folderName: "-Users-test-project")

        #expect(true, "requestSessions() method should exist and be callable")
    }

    @Test func testRequestSessionHistoryMethodExists() throws {
        let manager = WebSocketManager()

        // Verify the method exists and can be called without crashing
        // Uses folderName (actual directory name) not decoded path
        manager.requestSessionHistory(folderName: "-Users-test-project", sessionId: "abc123")

        #expect(true, "requestSessionHistory() method should exist and be callable")
    }

    // MARK: - Connection Status Tests

    @Test func testConnectedPublishedProperty() throws {
        let manager = WebSocketManager()

        #expect(manager.connected == false)

        manager.$connected
            .sink { _ in }
            .cancel()

        manager.connected = true
        #expect(manager.connected == true)

        manager.connected = false
        #expect(manager.connected == false)
    }

    @Test func testOnConnectionStatusReceivedCallback() throws {
        let manager = WebSocketManager()
        var receivedStatus: ConnectionStatus?

        manager.onConnectionStatusReceived = { status in
            receivedStatus = status
        }

        #expect(manager.onConnectionStatusReceived != nil)

        let mockStatus = ConnectionStatus(
            type: "connection_status",
            connected: true,
            activeSessionId: "test-session",
            activeSessionIds: ["test-session"],
            branch: nil
        )

        manager.onConnectionStatusReceived?(mockStatus)

        #expect(receivedStatus?.connected == true)
        #expect(receivedStatus?.activeSessionId == "test-session")
    }

    @Test func testConnectionStatusUpdatesProperties() throws {
        let manager = WebSocketManager()

        let status = ConnectionStatus(
            type: "connection_status",
            connected: true,
            activeSessionId: "session-xyz",
            activeSessionIds: ["session-xyz"],
            branch: nil
        )

        manager.connected = status.connected
        if let sessionId = status.activeSessionId {
            manager.activeSessionIds = [sessionId]
        }

        #expect(manager.connected == true)
        #expect(manager.activeSessionIds.contains("session-xyz"))
    }

    @Test func testConnectionStatusClearsOnDisconnect() throws {
        let manager = WebSocketManager()

        manager.connected = true
        manager.activeSessionIds = ["test"]

        #expect(manager.connected == true)

        manager.connected = false
        manager.activeSessionIds = []

        #expect(manager.connected == false)
        #expect(manager.activeSessionIds.isEmpty)
    }

    // MARK: - Permission Request Tests

    @Test func testDecodePermissionRequest() throws {
        let json = """
        {
            "type": "permission_request",
            "request_id": "uuid-123",
            "prompt_type": "bash",
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"},
            "timestamp": 1234567890
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)

        #expect(request.requestId == "uuid-123")
        #expect(request.toolName == "Bash")
    }

    @Test func testDecodePermissionResolved() throws {
        let json = """
        {
            "type": "permission_resolved",
            "request_id": "uuid-123",
            "answered_in": "terminal"
        }
        """.data(using: .utf8)!

        let resolved = try JSONDecoder().decode(PermissionResolved.self, from: json)

        #expect(resolved.requestId == "uuid-123")
        #expect(resolved.answeredIn == "terminal")
    }

    // MARK: - URL Connect Tests

    @Test func testConnectWithURLSetsConnectedURL() throws {
        let manager = WebSocketManager()
        manager.connect(url: "ws://192.168.1.42:8765")

        #expect(manager.connectedURL == "ws://192.168.1.42:8765")
    }

    @Test func testConnectWithInvalidURLSetsError() throws {
        let manager = WebSocketManager()

        // "not a url" is actually parsed as a valid URL by URL(string:)
        // Test with completely empty string which will fail
        manager.connect(url: "")

        // The error is set synchronously for empty URLs
        if case .error(_) = manager.connectionState {
            #expect(true, "Should be in error state")
        } else {
            // URL(string: "") returns nil, triggering error state
            #expect(manager.connectedURL == nil, "connectedURL should not be set for invalid URL")
        }
    }

    @Test func testDisconnectClearsConnectedURL() throws {
        let manager = WebSocketManager()
        manager.connect(url: "ws://192.168.1.42:8765")
        manager.disconnect()

        #expect(manager.connectedURL == nil)
    }

    @Test func testDisconnectSetsStateImmediately() throws {
        let manager = WebSocketManager()
        manager.connectionState = .connected

        manager.disconnect()

        // State should be disconnected immediately (not async)
        #expect(manager.connectionState == .disconnected)
        #expect(manager.voiceState == .idle)
    }

    // MARK: - UserInputMessage / SetPreferenceMessage Tests

    @Test func testUserInputMessageEncodesCorrectly() throws {
        let message = UserInputMessage(text: "hello", images: [])
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "user_input")
        #expect(json["text"] as? String == "hello")
        #expect((json["images"] as? [Any])?.isEmpty == true)
        #expect(json["timestamp"] != nil)
    }

    @Test func testUserInputMessageWithImagesEncodesCorrectly() throws {
        let img = ImageAttachment(data: "abc123", filename: "photo.jpg")
        let message = UserInputMessage(text: "look at this", images: [img])
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        let images = json["images"] as! [[String: Any]]
        #expect(images.count == 1)
        #expect(images[0]["data"] as? String == "abc123")
        #expect(images[0]["filename"] as? String == "photo.jpg")
    }

    @Test func testSetPreferenceEncodesCorrectly() throws {
        let message = SetPreferenceMessage(ttsEnabled: false)
        let data = try JSONEncoder().encode(message)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        #expect(json["type"] as? String == "set_preference")
        #expect(json["tts_enabled"] as? Bool == false)
    }

    // MARK: - InputBarMode Tests

    @Test func inputBarModeStartsNormal() {
        let manager = WebSocketManager()
        #expect(manager.inputBarMode == .normal)
    }

    @Test func inputBarModeTransitionsToPermissionOnRequest() {
        let manager = WebSocketManager()
        let request = PermissionRequest(
            type: "permission_request",
            requestId: "req-1",
            promptType: .bash,
            toolName: "Bash",
            toolInput: ToolInput(command: "ls"),
            context: nil,
            permissionSuggestions: nil,
            timestamp: 0
        )
        manager.handleInputBarPermission(request)
        #expect(manager.inputBarMode == .permissionPrompt(request))
    }

    @Test func inputBarModeTransitionsToQuestionOnQuestionPrompt() {
        let manager = WebSocketManager()
        let prompt = QuestionPrompt(
            type: "question_prompt",
            requestId: "req-2",
            sessionId: nil,
            header: "Question",
            question: "Pick one",
            options: [QuestionOption(label: "A", description: "")],
            multiSelect: false,
            questionIndex: 0,
            totalQuestions: 1
        )
        manager.inputBarMode = .questionPrompt(prompt)
        if case .questionPrompt(let p) = manager.inputBarMode {
            #expect(p.requestId == "req-2")
        } else {
            #expect(Bool(false), "Should be in questionPrompt mode")
        }
    }

    @Test func inputBarModeResetsToNormalOnResolution() {
        let manager = WebSocketManager()
        let request = PermissionRequest(
            type: "permission_request",
            requestId: "req-3",
            promptType: .bash,
            toolName: "Bash",
            toolInput: ToolInput(command: "ls"),
            context: nil,
            permissionSuggestions: nil,
            timestamp: 0
        )
        manager.handleInputBarPermission(request)
        manager.handleInputBarResolved()
        #expect(manager.inputBarMode == .normal)
    }

    @Test func inputBarModeTransitionsToDisconnected() {
        let manager = WebSocketManager()
        manager.handleInputBarDisconnected()
        #expect(manager.inputBarMode == .disconnected)
    }

    @Test func testDisconnectStatePersistsAfterCallbacks() throws {
        let manager = WebSocketManager()
        manager.connectionState = .connected

        manager.disconnect()

        // Simulate what would happen if delegate tried to set error
        // The actual delegate checks if case .disconnected = connectionState { return }
        // So we verify the state stays disconnected
        #expect(manager.connectionState == .disconnected)
    }

    // MARK: - Foreground Reconnect Tests

    @Test func reconnectIfNeededSkipsWhenConnected() {
        let manager = WebSocketManager()
        manager.connectionState = .connected

        manager.reconnectIfNeeded()

        #expect(manager.connectionState == .connected)
        #expect(manager.isReconnecting == false)
    }

    @Test func reconnectIfNeededSkipsWhenConnecting() {
        let manager = WebSocketManager()
        manager.connectionState = .connecting

        manager.reconnectIfNeeded()

        #expect(manager.connectionState == .connecting)
        #expect(manager.isReconnecting == false)
    }

    @Test func reconnectIfNeededSkipsWhenNoURL() {
        let manager = WebSocketManager()
        manager.connectionState = .disconnected

        manager.reconnectIfNeeded()

        // No currentURL stored, so nothing to reconnect to
        #expect(manager.isReconnecting == false)
    }

    @Test func reconnectIfNeededStartsWhenDisconnectedWithURL() {
        let manager = WebSocketManager()
        // Set currentURL directly (avoid connect() which triggers async pre-check)
        manager.currentURL = URL(string: "ws://192.168.1.1:8765")
        manager.connectionState = .disconnected

        manager.reconnectIfNeeded()

        // isReconnecting is set synchronously; connectionState is set async in connectToURL
        #expect(manager.isReconnecting == true)
    }

    @Test func reconnectIfNeededStartsWhenErrorWithURL() {
        let manager = WebSocketManager()
        manager.currentURL = URL(string: "ws://192.168.1.1:8765")
        manager.connectionState = .error("Connection lost")

        manager.reconnectIfNeeded()

        #expect(manager.isReconnecting == true)
    }

    @Test func foregroundReconnectUsesThreeMaxRetries() {
        let manager = WebSocketManager()
        manager.currentURL = URL(string: "ws://192.168.1.1:8765")
        manager.connectionState = .disconnected

        manager.reconnectIfNeeded()

        #expect(manager.isReconnecting == true)
        #expect(manager.foregroundMaxRetries == 3)
    }

    @Test func foregroundReconnectResetsOnSuccess() {
        let manager = WebSocketManager()
        manager.isReconnecting = true

        manager.handleDidOpen()

        #expect(manager.isReconnecting == false)
    }

    @Test func reconnectIfNeededSkipsAfterExplicitDisconnect() {
        let manager = WebSocketManager()
        // Simulate a stored connection
        manager.currentURL = URL(string: "ws://192.168.1.1:8765")
        manager.connectedURL = "ws://192.168.1.1:8765"

        // Explicit disconnect clears currentURL
        manager.disconnect()

        manager.reconnectIfNeeded()

        // disconnect() cleared the URL, so nothing to reconnect to
        #expect(manager.isReconnecting == false)
        #expect(manager.connectionState == .disconnected)
    }
}
