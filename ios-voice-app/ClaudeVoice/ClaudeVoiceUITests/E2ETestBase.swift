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

        // Set transcript path to server's watched directory
        let timestamp = Int(Date().timeIntervalSince1970)
        let transcriptDir = NSString(string: "~/.claude/projects/e2e_test_project").expandingTildeInPath
        transcriptPath = "\(transcriptDir)/transcript_\(timestamp).jsonl"

        // Create transcript directory
        try? FileManager.default.createDirectory(atPath: transcriptDir, withIntermediateDirectories: true)

        // Create empty transcript file
        try "".write(toFile: transcriptPath!, atomically: true, encoding: .utf8)

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

        // Clean up transcript file
        if let path = transcriptPath, FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
        }

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

        sleep(3)

        let doneButton = app.buttons["Done"]
        if doneButton.exists {
            doneButton.tap()
        }

        sleep(1)

        // Verify connected
        let connectedLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(connectedLabel.waitForExistence(timeout: 5), "Should show Connected status")
        XCTAssertEqual(connectedLabel.label, "Connected", "Connection status should be Connected")
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

        // Wait for server to process
        sleep(2)
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

        // Wait for server to process and send to app
        sleep(1)
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
}

// MARK: - Errors

enum E2ETestError: Error {
    case noTranscriptPath
    case injectionFailed
}
