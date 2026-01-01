//
//  E2ETestBase.swift
//  ClaudeVoiceUITests
//
//  Base class for end-to-end tests with real server
//

import XCTest
import Foundation

class E2ETestBase: XCTestCase {

    static var app: XCUIApplication!
    var transcriptPath: String?

    let testServerHost = "127.0.0.1"
    let testServerPort = 8765
    let pythonHelperPath: String = {
        // Get path from environment or use default
        if let envPath = ProcessInfo.processInfo.environment["E2E_SUPPORT_PATH"] {
            return envPath
        }
        // Fallback to relative path
        let currentDir = FileManager.default.currentDirectoryPath
        return "\(currentDir)/../../tests/e2e_support"
    }()

    var app: XCUIApplication! {
        return Self.app
    }

    // MARK: - Setup & Teardown

    override class func setUp() {
        super.setUp()

        print("🚀 Launching app once for all tests in \(String(describing: self))")

        app = XCUIApplication()
        app.launchEnvironment = [
            "TEST_MODE": "1",
            "SERVER_HOST": "127.0.0.1",
            "SERVER_PORT": "8765"
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        continueAfterFailure = false

        // Get transcript path from environment (set by test runner script)
        if let envPath = ProcessInfo.processInfo.environment["TEST_TRANSCRIPT_PATH"] {
            transcriptPath = envPath
        } else {
            // Fallback: create temp transcript file
            let timestamp = Int(Date().timeIntervalSince1970)
            transcriptPath = "/tmp/claude_voice_e2e_tests/transcript_\(timestamp).jsonl"
        }

        // Note: Server should already be running (started by run_e2e_tests.sh)
        print("📡 Assuming server is already running at \(testServerHost):\(testServerPort)")

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

        // Note: Server cleanup handled by test runner script

        try super.tearDownWithError()
    }

    override class func tearDown() {
        print("🛑 Terminating app after all tests in \(String(describing: self))")
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Server Management
    // Note: Server lifecycle managed by run_e2e_tests.sh script

    // MARK: - Helper Methods

    func connectToServer() {
        // Tap settings button
        let settingsButton = app.buttons["gearshape.fill"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
        }

        // Enter server IP
        let serverIPField = app.textFields["Server IP Address"]
        if serverIPField.waitForExistence(timeout: 5) {
            serverIPField.tap()

            if let existingText = serverIPField.value as? String, !existingText.isEmpty {
                let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingText.count)
                serverIPField.typeText(deleteString)
            }

            serverIPField.typeText(testServerHost)
        }

        // Tap connect
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

        // Close settings
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
        // TODO: Implement mock speech injection
        // For now, just tap the talk button
        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk'")).firstMatch
        if talkButton.exists {
            talkButton.tap()
            sleep(1)
            // Stop recording
            let stopButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Stop'")).firstMatch
            if stopButton.exists {
                stopButton.tap()
            }
        }
    }

    func injectAssistantResponse(_ text: String) {
        guard let transcriptPath = transcriptPath else {
            XCTFail("No transcript path")
            return
        }

        // Create JSON entry
        let entry: [String: Any] = [
            "role": "assistant",
            "content": text,
            "timestamp": Date().timeIntervalSince1970
        ]

        // Write to transcript file
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: entry)
            if let jsonString = String(data: jsonData, encoding: .utf8) {
                let fileHandle = FileHandle(forWritingAtPath: transcriptPath)
                if let handle = fileHandle {
                    handle.seekToEndOfFile()
                    handle.write((jsonString + "\n").data(using: .utf8)!)
                    handle.closeFile()
                } else {
                    // File doesn't exist, create it
                    try (jsonString + "\n").write(toFile: transcriptPath, atomically: true, encoding: .utf8)
                }
            }
        } catch {
            XCTFail("Failed to inject response: \(error)")
        }

        // Wait for server to process
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
    case serverStartupFailed(reason: String)
    case noTranscriptPath
    case injectionFailed
}
