//
//  E2ETestBase.swift
//  ClaudeVoiceUITests
//
//  Base class for E2E tests - assumes server already running
//

import XCTest
import Foundation

class E2ETestBase: XCTestCase {

    static var app: XCUIApplication!
    var transcriptPath: String?

    let testServerHost = "127.0.0.1"
    let testServerPort = 8765

    /// Test fixture paths for sync-sessions E2E tests
    let testProjectsDir = "/Users/aaron/.claude/projects"
    let testProject1Path = "/Users/aaron/.claude/projects/-e2e-test-project1"
    let testProject2Path = "/Users/aaron/.claude/projects/-e2e-test-project2"

    var app: XCUIApplication! {
        return Self.app
    }

    // MARK: - Setup & Teardown

    override class func setUp() {
        super.setUp()

        print("🚀 Launching app once for all tests in \(String(describing: self))")

        app = XCUIApplication()
        app.launchEnvironment = [
            "SERVER_HOST": "127.0.0.1",
            "SERVER_PORT": "8765"
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        continueAfterFailure = false

        // IMPORTANT: Use absolute Mac path, NOT tilde or HOME expansion
        // UI tests run in simulator context where ~ and HOME point to simulator's container
        // The server runs on Mac and watches /Users/aaron/.claude/projects/...
        // We must write to the same path the server watches
        transcriptPath = "/Users/aaron/.claude/projects/e2e_test_project/e2e_transcript.jsonl"
        print("📝 Using hardcoded Mac path: \(transcriptPath!)")

        // Clear the transcript file (don't create new one - server is already watching this one)
        try "".write(toFile: transcriptPath!, atomically: true, encoding: .utf8)

        // Create test fixtures for sync-sessions tests
        createTestFixtures()

        // Launch app
        Self.app.launch()
        sleep(2)

        // Connect to server
        connectToServer()
    }

    override func tearDownWithError() throws {
        // Disconnect if connected
        if app.staticTexts["connectionStatus"].exists &&
           app.staticTexts["connectionStatus"].label == "Connected" {
            disconnectFromServer()
        }

        // Clear transcript file (don't delete - server is still watching it)
        if let path = transcriptPath, FileManager.default.fileExists(atPath: path) {
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
        }

        // Clean up test fixtures for sync-sessions tests
        cleanupTestFixtures()

        try super.tearDownWithError()
    }

    override class func tearDown() {
        print("🛑 Terminating app after all tests in \(String(describing: self))")
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Helper Methods

    func connectToServer() {
        let settingsButton = app.buttons["gearshape.fill"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
        }

        let serverIPField = app.textFields["Server IP Address"]
        if serverIPField.waitForExistence(timeout: 5) {
            serverIPField.tap()

            if let existingText = serverIPField.value as? String, !existingText.isEmpty {
                let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingText.count)
                serverIPField.typeText(deleteString)
            }

            serverIPField.typeText(testServerHost)
        }

        let connectButton = app.buttons["Connect"]
        if !connectButton.exists {
            let connectionHeader = app.staticTexts["Connection"]
            if connectionHeader.exists {
                connectionHeader.tap()
                sleep(1)
            }
        }

        if connectButton.waitForExistence(timeout: 5) {
            connectButton.tap()
        }

        // Verify connected WHILE STILL IN SETTINGS (connectionStatus is only visible in SettingsView)
        let connectedLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(connectedLabel.waitForExistence(timeout: 10), "Should show Connected status")

        // Wait for connection to complete
        let predicate = NSPredicate(format: "label == %@", "Connected")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: connectedLabel)
        let result = XCTWaiter().wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Connection status should become Connected")

        // Now dismiss settings
        let doneButton = app.buttons["Done"]
        if doneButton.exists {
            doneButton.tap()
        }

        sleep(1)
    }

    func disconnectFromServer() {
        let settingsButton = app.buttons["gearshape.fill"]
        if settingsButton.waitForExistence(timeout: 2) {
            settingsButton.tap()
        }

        let disconnectButton = app.buttons["Disconnect"]
        if disconnectButton.waitForExistence(timeout: 2) {
            disconnectButton.tap()
        }

        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 2) {
            doneButton.tap()
        }

        sleep(1)
    }

    func sendVoiceInput(_ text: String) {
        // Send voice input via WebSocket (Swift implementation, iOS-compatible)
        let expectation = XCTestExpectation(description: "Send voice input")

        let url = URL(string: "ws://\(testServerHost):\(testServerPort)")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        let message: [String: Any] = [
            "type": "voice_input",
            "text": text,
            "timestamp": Date().timeIntervalSince1970
        ]

        if let jsonData = try? JSONSerialization.data(withJSONObject: message),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            task.send(.string(jsonString)) { error in
                if let error = error {
                    XCTFail("WebSocket send failed: \(error)")
                }
                task.cancel(with: .goingAway, reason: nil)
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 5.0)
        sleep(1)
    }

    func injectAssistantResponse(_ text: String) {
        // Inject assistant response into transcript file (Swift implementation, iOS-compatible)
        guard let transcriptPath = transcriptPath else {
            XCTFail("No transcript path")
            return
        }

        let entry: [String: Any] = [
            "role": "assistant",
            "content": text,
            "timestamp": Date().timeIntervalSince1970
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: entry)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                XCTFail("Failed to encode JSON")
                return
            }

            let fileHandle = FileHandle(forWritingAtPath: transcriptPath)
            if let handle = fileHandle {
                handle.seekToEndOfFile()
                handle.write((jsonString + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                // File doesn't exist, create it
                try (jsonString + "\n").write(toFile: transcriptPath, atomically: true, encoding: .utf8)
            }
        } catch {
            XCTFail("Failed to inject response: \(error)")
        }

        // Brief delay for file system sync (server will process async)
        usleep(100000) // 100ms
    }

    func injectUserMessage(_ text: String) {
        // Inject user message into transcript file (Swift implementation, iOS-compatible)
        guard let transcriptPath = transcriptPath else {
            XCTFail("No transcript path")
            return
        }

        let entry: [String: Any] = [
            "role": "user",
            "content": text,
            "timestamp": Date().timeIntervalSince1970
        ]

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: entry)
            guard let jsonString = String(data: jsonData, encoding: .utf8) else {
                XCTFail("Failed to encode JSON")
                return
            }

            let fileHandle = FileHandle(forWritingAtPath: transcriptPath)
            if let handle = fileHandle {
                handle.seekToEndOfFile()
                handle.write((jsonString + "\n").data(using: .utf8)!)
                handle.closeFile()
            } else {
                // File doesn't exist, create it
                try (jsonString + "\n").write(toFile: transcriptPath, atomically: true, encoding: .utf8)
            }
        } catch {
            XCTFail("Failed to inject user message: \(error)")
        }

        // Small delay for file system
        usleep(100000) // 100ms
    }

    func simulateConversationTurn(userInput: String, assistantResponse: String) {
        // Simulate a complete conversation turn:
        // 1. Send voice input via WebSocket (real)
        // 2. Inject user message to transcript (simulates Claude logging it)
        // 3. Inject assistant response to transcript (simulates Claude responding)

        print("📝 Simulating conversation turn: '\(userInput)' -> '\(assistantResponse)'")

        // Send voice input via WebSocket
        sendVoiceInput(userInput)

        // Wait briefly for server to process WebSocket message
        usleep(500000) // 500ms

        // Inject user message to transcript
        injectUserMessage(userInput)

        // Wait for file watcher to detect
        usleep(200000) // 200ms

        // Inject assistant response
        injectAssistantResponse(assistantResponse)

        // Don't wait here - let the test's waitForVoiceState do the waiting
        // This ensures we catch the Speaking state before it transitions back to Idle
    }

    func waitForVoiceState(_ expectedState: String, timeout: TimeInterval = 10.0) -> Bool {
        let stateLabel = app.staticTexts["voiceState"]

        guard stateLabel.waitForExistence(timeout: timeout) else {
            return false
        }

        let predicate = NSPredicate(format: "label == %@", expectedState)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: stateLabel)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    func waitForConnectionState(_ expectedState: String, timeout: TimeInterval = 10.0) -> Bool {
        let stateLabel = app.staticTexts["connectionStatus"]
        let exists = stateLabel.waitForExistence(timeout: timeout)
        return exists && stateLabel.label == expectedState
    }

    // MARK: - Test Fixtures for Sync-Sessions

    /// Create mock project directories with session files for testing
    func createTestFixtures() {
        let fileManager = FileManager.default

        // Project 1: 2 sessions
        try? fileManager.createDirectory(atPath: testProject1Path, withIntermediateDirectories: true)

        // Session 1: Hello conversation
        let session1 = """
        {"type":"user","message":{"role":"user","content":"Hello Claude"},"timestamp":"2026-01-01T10:00:00Z"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi! How can I help?"}]},"timestamp":"2026-01-01T10:00:05Z"}
        """
        try? session1.write(toFile: "\(testProject1Path)/session1.jsonl", atomically: true, encoding: .utf8)

        // Session 2: Code question
        let session2 = """
        {"type":"user","message":{"role":"user","content":"How do I write a Swift function?"},"timestamp":"2026-01-02T10:00:00Z"}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Here's how to write a Swift function..."}]},"timestamp":"2026-01-02T10:00:05Z"}
        {"type":"user","message":{"role":"user","content":"Thanks!"},"timestamp":"2026-01-02T10:00:10Z"}
        """
        try? session2.write(toFile: "\(testProject1Path)/session2.jsonl", atomically: true, encoding: .utf8)

        // Project 2: 1 session
        try? fileManager.createDirectory(atPath: testProject2Path, withIntermediateDirectories: true)

        let session3 = """
        {"type":"user","message":{"role":"user","content":"What is TDD?"},"timestamp":"2026-01-01T09:00:00Z"}
        """
        try? session3.write(toFile: "\(testProject2Path)/session1.jsonl", atomically: true, encoding: .utf8)
    }

    /// Clean up test fixtures
    func cleanupTestFixtures() {
        let fileManager = FileManager.default
        try? fileManager.removeItem(atPath: testProject1Path)
        try? fileManager.removeItem(atPath: testProject2Path)
    }
}

// MARK: - Errors

enum E2ETestError: Error {
    case noTranscriptPath
    case injectionFailed
}
