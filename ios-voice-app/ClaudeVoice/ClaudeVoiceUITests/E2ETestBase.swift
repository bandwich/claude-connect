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
    var serverPID: Int?
    var transcriptPath: String?

    let testServerHost = "127.0.0.1"
    let testServerPort = 8765
    let pythonHelperPath: String = {
        let bundle = Bundle(for: E2ETestBase.self)
        // Updated path for tests/e2e_support location
        return bundle.bundlePath
            .replacingOccurrences(of: "/Build/Products/", with: "/")
            .replacingOccurrences(of: "ClaudeVoiceUITests-Runner.app", with: "tests/e2e_support")
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

        // Create temp transcript file
        let timestamp = Int(Date().timeIntervalSince1970)
        transcriptPath = "/tmp/claude_voice_e2e_tests/transcript_\(timestamp).jsonl"

        // Start real server
        print("📡 Starting real ios_server.py...")
        try startServer()

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

        // Stop server
        if let pid = serverPID {
            stopServer(pid: pid)
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

    // MARK: - Server Management

    private func startServer() throws {
        guard let transcriptPath = transcriptPath else {
            throw E2ETestError.noTranscriptPath
        }

        let serverManagerScript = "\(pythonHelperPath)/server_manager.py"
        let pythonPath = "\(pythonHelperPath)/../../.venv/bin/python3"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [serverManagerScript, "start", "--transcript", transcriptPath]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        try task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            throw E2ETestError.serverStartupFailed(reason: "No output")
        }

        // Parse JSON output
        guard let jsonData = output.data(using: .utf8),
              let result = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
              let pid = result["pid"] as? Int else {
            throw E2ETestError.serverStartupFailed(reason: "Invalid JSON: \(output)")
        }

        serverPID = pid
        print("✅ Server started with PID: \(pid)")
    }

    private func stopServer(pid: Int) {
        let serverManagerScript = "\(pythonHelperPath)/server_manager.py"
        let pythonPath = "\(pythonHelperPath)/../../.venv/bin/python3"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [serverManagerScript, "stop", "--pid", "\(pid)"]

        try? task.run()
        task.waitUntilExit()

        print("🛑 Server stopped (PID: \(pid))")
    }

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

        let injectorScript = "\(pythonHelperPath)/transcript_injector.py"
        let pythonPath = "\(pythonHelperPath)/../../.venv/bin/python3"

        let task = Process()
        task.executableURL = URL(fileURLWithPath: pythonPath)
        task.arguments = [injectorScript, "--transcript", transcriptPath, "--message", text]

        try? task.run()
        task.waitUntilExit()

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
