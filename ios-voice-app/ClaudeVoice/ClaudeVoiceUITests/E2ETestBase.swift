//
//  E2ETestBase.swift
//  ClaudeVoiceUITests
//
//  Unified base class for E2E and integration tests
//

import XCTest
import Foundation

class E2ETestBase: XCTestCase {

    static var app: XCUIApplication!
    var transcriptPath: String?

    // Environment-aware server configuration
    let testServerHost: String = {
        if let envHost = ProcessInfo.processInfo.environment["TEST_SERVER_HOST"] {
            return envHost
        }
        #if targetEnvironment(simulator)
        return "127.0.0.1"
        #else
        return "192.168.1.109"  // Physical device needs Mac's IP
        #endif
    }()

    let testServerPort: Int = {
        if let portString = ProcessInfo.processInfo.environment["TEST_SERVER_PORT"],
           let port = Int(portString) {
            return port
        }
        return 8765
    }()

    /// Test fixture paths for sync-sessions E2E tests
    let testProjectsDir = "/Users/aaron/.claude/projects"
    let testProject1Path = "/Users/aaron/.claude/projects/-e2e_test_project1"
    let testProject2Path = "/Users/aaron/.claude/projects/-e2e_test_project2"

    var app: XCUIApplication! {
        return Self.app
    }

    // MARK: - Setup & Teardown

    override class func setUp() {
        super.setUp()

        print("🚀 Launching app once for all tests in \(String(describing: self))")

        let serverHost: String
        if let envHost = ProcessInfo.processInfo.environment["TEST_SERVER_HOST"] {
            serverHost = envHost
        } else {
            #if targetEnvironment(simulator)
            serverHost = "127.0.0.1"
            #else
            serverHost = "192.168.1.109"
            #endif
        }
        let serverPort = ProcessInfo.processInfo.environment["TEST_SERVER_PORT"] ?? "8765"

        print("📡 Test server: \(serverHost):\(serverPort)")

        app = XCUIApplication()
        app.launchEnvironment = [
            "SERVER_HOST": serverHost,
            "SERVER_PORT": serverPort,
            "INTEGRATION_TEST_MODE": "1",
            "TEST_SERVER_HOST": serverHost,
            "TEST_SERVER_PORT": serverPort
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()

        continueAfterFailure = false

        transcriptPath = "/Users/aaron/.claude/projects/e2e_test_project/e2e_transcript.jsonl"
        print("📝 Using hardcoded Mac path: \(transcriptPath!)")

        let fileManager = FileManager.default
        let transcriptDir = (transcriptPath! as NSString).deletingLastPathComponent
        try? fileManager.createDirectory(atPath: transcriptDir, withIntermediateDirectories: true)
        // Seed with initial message so session isn't filtered (sessions with 0 messages are hidden)
        let seedMessage = #"{"type":"user","message":{"role":"user","content":"E2E Test Session"},"timestamp":"2026-01-01T00:00:00Z"}"# + "\n"
        try seedMessage.write(toFile: transcriptPath!, atomically: true, encoding: .utf8)

        createTestFixtures()

        Self.app.launch()
        sleep(2)  // Wait for app to fully initialize

        connectToServer()
    }

    override func tearDownWithError() throws {
        if app.staticTexts["connectionStatus"].exists &&
           app.staticTexts["connectionStatus"].label == "Connected" {
            disconnectFromServer()
        }

        if let path = transcriptPath, FileManager.default.fileExists(atPath: path) {
            try? "".write(toFile: path, atomically: true, encoding: .utf8)
        }

        cleanupTestFixtures()

        try super.tearDownWithError()
    }

    override class func tearDown() {
        print("🛑 Terminating app after all tests in \(String(describing: self))")
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Connection Methods

    func connectToServer() {
        let settingsButton = app.buttons["gearshape.fill"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
        }

        // Wait for Settings sheet to fully load (especially on first launch)
        sleep(1)

        // First, ensure Connection section is expanded (may be collapsed on first launch)
        let serverIPField = app.textFields["Server IP Address"]
        if !serverIPField.waitForExistence(timeout: 2) {
            // Section might be collapsed - try to expand it
            let connectionHeader = app.staticTexts["Connection"]
            if connectionHeader.waitForExistence(timeout: 2) {
                connectionHeader.tap()
                sleep(1)  // Wait for section to expand
            }
        }

        // Now look for server IP field with longer timeout
        if serverIPField.waitForExistence(timeout: 5) {
            serverIPField.tap()

            if let existingText = serverIPField.value as? String, !existingText.isEmpty {
                let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingText.count)
                serverIPField.typeText(deleteString)
            }

            serverIPField.typeText(testServerHost)
        }

        let connectButton = app.buttons["Connect"]
        if connectButton.waitForExistence(timeout: 5) {
            connectButton.tap()
        }

        let connectedLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(connectedLabel.waitForExistence(timeout: 10), "Should show connection status")

        let predicate = NSPredicate(format: "label == %@", "Connected")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: connectedLabel)
        let result = XCTWaiter().wait(for: [expectation], timeout: 10)
        XCTAssertEqual(result, .completed, "Connection status should become Connected")

        let doneButton = app.buttons["Done"]
        if doneButton.exists {
            doneButton.tap()
        }

        sleep(1)  // Wait for navigation to complete
    }

    /// Alias for connectToServer (compatibility with IntegrationTestBase tests)
    func connectToTestServer() {
        connectToServer()
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

    // MARK: - State Waiting

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

    /// Wait for Speaking state then Idle state - common pattern in conversation tests
    func waitForSpeakingThenIdle(speakingTimeout: TimeInterval = 10.0, idleTimeout: TimeInterval = 10.0) -> Bool {
        guard waitForVoiceState("Speaking", timeout: speakingTimeout) else {
            return false
        }
        return waitForVoiceState("Idle", timeout: idleTimeout)
    }

    // MARK: - UI Helpers

    func tapTalkButton() {
        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk' OR label CONTAINS 'Stop'")).firstMatch
        XCTAssertTrue(talkButton.exists, "Talk button should exist")
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled")
        talkButton.tap()
    }

    func isTalkButtonEnabled() -> Bool {
        let talkButton = app.buttons.matching(NSPredicate(format: "label CONTAINS 'Tap to Talk' OR label CONTAINS 'Stop'")).firstMatch
        return talkButton.exists && talkButton.isEnabled
    }

    // MARK: - Voice Input & Transcript Methods

    func sendVoiceInput(_ text: String) {
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
        sleep(1)  // Wait for server to receive WebSocket message
    }

    /// Inject assistant response to transcript file.
    /// This simulates Claude's output for testing the file watcher -> TTS -> audio streaming flow.
    /// Note: This is acceptable for E2E tests since we can't run real Claude, but we can verify
    /// the rest of the pipeline (file watching, TTS, audio streaming) works correctly.
    func injectAssistantResponse(_ text: String) {
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

            let lineData = (jsonString + "\n").data(using: .utf8)!
            let fileURL = URL(fileURLWithPath: transcriptPath)
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            try handle.write(contentsOf: lineData)
            try handle.close()
        } catch {
            XCTFail("Failed to inject response: \(error)")
        }

        // Brief delay for file system sync
        usleep(100000) // 100ms
    }

    // MARK: - Tmux Verification Methods

    /// Verify tmux session is running on the server
    func verifyTmuxSessionRunning() -> Bool {
        let httpPort = testServerPort + 1
        let url = URL(string: "http://\(testServerHost):\(httpPort)/tmux_status")!
        let semaphore = DispatchSemaphore(value: 0)
        var sessionExists = false

        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let exists = json["session_exists"] as? Bool {
                sessionExists = exists
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
        return sessionExists
    }

    /// Capture tmux pane content to verify input arrived
    func captureTmuxPane() -> String? {
        let httpPort = testServerPort + 1
        let url = URL(string: "http://\(testServerHost):\(httpPort)/capture_pane")!
        let semaphore = DispatchSemaphore(value: 0)
        var content: String?

        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data,
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let paneContent = json["content"] as? String {
                content = paneContent
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
        return content
    }

    /// Verify that text appears in tmux pane (voice input arrived)
    func verifyInputInTmux(_ text: String, timeout: TimeInterval = 5.0) -> Bool {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if let content = captureTmuxPane(), content.contains(text) {
                return true
            }
            usleep(500000) // Check every 500ms
        }
        return false
    }

    // MARK: - Permission Request Helpers

    func injectPermissionRequest(
        promptType: String,
        toolName: String,
        command: String? = nil,
        description: String? = nil,
        filePath: String? = nil,
        oldContent: String? = nil,
        newContent: String? = nil,
        questionText: String? = nil,
        questionOptions: [String]? = nil
    ) -> String {
        let requestId = UUID().uuidString

        // Build payload matching what the hook sends to HTTP server
        var payload: [String: Any] = [
            "tool_name": toolName,
            "timestamp": Date().timeIntervalSince1970
        ]

        if command != nil || description != nil {
            var toolInput: [String: Any] = [:]
            if let cmd = command { toolInput["command"] = cmd }
            if let desc = description { toolInput["description"] = desc }
            payload["tool_input"] = toolInput
        }

        if filePath != nil || oldContent != nil || newContent != nil {
            var context: [String: Any] = [:]
            if let fp = filePath { context["file_path"] = fp }
            if let old = oldContent { context["old_content"] = old }
            if let new = newContent { context["new_content"] = new }
            payload["context"] = context
        }

        if let text = questionText {
            var question: [String: Any] = ["text": text]
            if let opts = questionOptions {
                question["options"] = opts
            }
            payload["question"] = question
        }

        // POST to HTTP server (port 8766) - this triggers broadcast to iOS app
        let httpPort = testServerPort + 1
        let url = URL(string: "http://\(testServerHost):\(httpPort)/permission?timeout=5")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        if let jsonData = try? JSONSerialization.data(withJSONObject: payload) {
            request.httpBody = jsonData
        }

        // Fire and forget - don't wait for response (it would block waiting for user action)
        let task = URLSession.shared.dataTask(with: request)
        task.resume()

        sleep(2) // Wait for HTTP request to be processed and WebSocket broadcast

        return requestId
    }

    func waitForPermissionSheet(timeout: TimeInterval = 5.0) -> Bool {
        // Permission sheet has navigation title based on type
        let sheetTitles = ["Command", "Edit", "New File", "Question", "Agent"]
        for title in sheetTitles {
            if app.navigationBars[title].waitForExistence(timeout: timeout / Double(sheetTitles.count)) {
                return true
            }
        }
        return false
    }

    func waitForPermissionSheetDismissed(timeout: TimeInterval = 3.0) -> Bool {
        let sheetTitles = ["Command", "Edit", "New File", "Question", "Agent"]
        // Wait briefly, then check none exist
        sleep(1)
        for title in sheetTitles {
            if app.navigationBars[title].exists {
                return false
            }
        }
        return true
    }

    // MARK: - Server API Helpers (from IntegrationTestBase)

    func sendMockClaudeResponse(_ text: String) {
        let url = URL(string: "http://\(testServerHost):\(testServerPort + 1)/inject_response")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = text.data(using: .utf8)

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
    }

    func getServerLogs() -> String {
        let url = URL(string: "http://\(testServerHost):\(testServerPort + 1)/logs")!
        let semaphore = DispatchSemaphore(value: 0)
        var logs = ""

        URLSession.shared.dataTask(with: url) { data, _, _ in
            if let data = data, let logText = String(data: data, encoding: .utf8) {
                logs = logText
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
        return logs
    }

    func sendStatus(_ state: String, message: String = "") {
        let url = URL(string: "http://\(testServerHost):\(testServerPort + 1)/inject_status")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = ["state": state, "message": message]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)
    }

    // MARK: - Navigation Helpers

    func navigateToTestSession() {
        let projectText = app.staticTexts["e2e_test_project"]
        if projectText.waitForExistence(timeout: 5) {
            projectText.tap()
        } else {
            let firstProject = app.cells.firstMatch
            if firstProject.waitForExistence(timeout: 5) {
                firstProject.tap()
            }
        }

        sleep(1)  // Wait for sessions list to load

        let testSession = app.staticTexts["E2E Test Session"]
        if testSession.waitForExistence(timeout: 5) {
            testSession.tap()
        } else {
            let firstSession = app.cells.firstMatch
            if firstSession.waitForExistence(timeout: 5) {
                firstSession.tap()
            }
        }

        sleep(2)  // Wait for session view to load
    }

    // MARK: - Test Fixtures for Sync-Sessions

    func createTestFixtures() {
        let fileManager = FileManager.default

        try? fileManager.createDirectory(atPath: testProject1Path, withIntermediateDirectories: true)

        let session1 = """
{"type":"user","message":{"role":"user","content":"Hello Claude"},"timestamp":"2026-01-01T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi! How can I help?"}]},"timestamp":"2026-01-01T10:00:05Z"}
"""
        try? session1.write(toFile: "\(testProject1Path)/session1.jsonl", atomically: true, encoding: .utf8)

        let session2 = """
{"type":"user","message":{"role":"user","content":"How do I write a Swift function?"},"timestamp":"2026-01-02T10:00:00Z"}
{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Here's how to write a Swift function..."}]},"timestamp":"2026-01-02T10:00:05Z"}
{"type":"user","message":{"role":"user","content":"Thanks!"},"timestamp":"2026-01-02T10:00:10Z"}
"""
        try? session2.write(toFile: "\(testProject1Path)/session2.jsonl", atomically: true, encoding: .utf8)

        try? fileManager.createDirectory(atPath: testProject2Path, withIntermediateDirectories: true)

        let session3 = """
{"type":"user","message":{"role":"user","content":"What is TDD?"},"timestamp":"2026-01-01T09:00:00Z"}
"""
        try? session3.write(toFile: "\(testProject2Path)/session1.jsonl", atomically: true, encoding: .utf8)
    }

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
    case serverStartupTimeout
    case serverNotRunning
    case connectionFailed
}
