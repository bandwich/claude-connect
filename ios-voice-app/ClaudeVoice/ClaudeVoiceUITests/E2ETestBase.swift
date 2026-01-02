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
    let pythonHelperPath: String = {
        let bundle = Bundle(for: E2ETestBase.self)
        return bundle.bundlePath
            .replacingOccurrences(of: "/Build/Products/", with: "/")
            .replacingOccurrences(of: "ClaudeVoiceUITests-Runner.app", with: "ClaudeVoiceE2ESupport")
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
        guard let _ = transcriptPath else {
            XCTFail("No transcript path")
            return
        }

        let voiceSenderScript = "\(pythonHelperPath)/voice_sender.py"
        let pythonPath = "\(pythonHelperPath)/../../../.venv/bin/python3"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [voiceSenderScript, "--host", testServerHost, "--port", "\(testServerPort)", "--text", text]

        try? task.run()
        task.waitUntilExit()

        sleep(1)
    }

    func injectAssistantResponse(_ text: String) {
        guard let transcriptPath = transcriptPath else {
            XCTFail("No transcript path")
            return
        }

        let injectorScript = "\(pythonHelperPath)/transcript_injector.py"
        let pythonPath = "\(pythonHelperPath)/../../../.venv/bin/python3"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [injectorScript, "--transcript", transcriptPath, "--role", "assistant", "--message", text]

        try? task.run()
        task.waitUntilExit()

        // Wait for server to process
        sleep(2)
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
