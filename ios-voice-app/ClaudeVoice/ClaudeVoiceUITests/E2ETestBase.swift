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

    /// Test project info - created dynamically by run_e2e_tests.sh
    /// The script creates a session and writes config to /tmp/e2e_test_config.json
    private static var _testConfig: [String: String]?
    private var testConfig: [String: String] {
        if Self._testConfig == nil {
            let configPath = "/tmp/e2e_test_config.json"
            if let data = FileManager.default.contents(atPath: configPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                Self._testConfig = json
                print("📋 Loaded test config: \(json)")
            } else {
                print("⚠️ Could not load test config from \(configPath)")
                Self._testConfig = [:]
            }
        }
        return Self._testConfig ?? [:]
    }

    var testProjectName: String {
        testConfig["project_name"] ?? "project"
    }
    var testSessionId: String {
        testConfig["session_id"] ?? ""
    }
    var testFolderName: String {
        testConfig["folder_name"] ?? "-tmp-e2e-test-project"
    }

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

        // Reset server state before each test for isolation
        resetServerState()

        Self.app.launch()
        sleep(2)
        connectToServer()
    }

    /// Reset server state for test isolation
    /// Calls /reset endpoint to kill tmux sessions and clear tracking state
    func resetServerState() {
        let httpPort = testServerPort + 1
        let url = URL(string: "http://\(testServerHost):\(httpPort)/reset")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let semaphore = DispatchSemaphore(value: 0)
        var success = false

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                success = true
                print("✓ Server state reset for test isolation")
            } else {
                print("⚠️ Failed to reset server state: \(error?.localizedDescription ?? "unknown error")")
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)

        if !success {
            print("⚠️ Server reset may have failed, continuing anyway")
        }
    }

    override func tearDownWithError() throws {
        if app.staticTexts["connectionStatus"].exists &&
           app.staticTexts["connectionStatus"].label == "Connected" {
            disconnectFromServer()
        }

        // Note: We don't clean up test project directories
        // They contain REAL Claude sessions that may be useful for debugging
        // and will be reused in subsequent test runs

        try super.tearDownWithError()
    }

    override class func tearDown() {
        print("🛑 Terminating app after all tests in \(String(describing: self))")
        app?.terminate()
        super.tearDown()
    }

    // MARK: - UI Helpers

    /// Tap element using coordinates (bypasses scroll-to-visible which fails for toolbar buttons)
    func tapByCoordinate(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// Open settings by tapping the settings button
    func openSettings() {
        let settingsButton = app.buttons["settingsButton"]
        if settingsButton.waitForExistence(timeout: 5) {
            tapByCoordinate(settingsButton)
        }
    }

    // MARK: - Connection Methods

    func connectToServer() {
        // App auto-connects on launch using SERVER_HOST env var set by test runner
        // Wait for the auto-connect to complete, then verify

        // Give auto-connect time to establish
        sleep(2)

        // Check if already connected (auto-connect worked)
        // The project list shows if connected, wifi.slash icon if not
        // Look for any project cell - this indicates we're connected and have projects
        let anyProjectCell = app.cells.firstMatch
        if anyProjectCell.waitForExistence(timeout: 5) {
            print("✓ Auto-connected successfully, project list visible")
            return
        }

        // If not connected, fall back to manual connection via Settings
        print("⚠️ Auto-connect didn't work, trying manual connection...")

        openSettings()

        sleep(1)

        let serverIPField = app.textFields["Server IP Address"]
        if !serverIPField.waitForExistence(timeout: 2) {
            let connectionHeader = app.staticTexts["Connection"]
            if connectionHeader.waitForExistence(timeout: 2) {
                connectionHeader.tap()
                sleep(1)
            }
        }

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

        sleep(1)
    }

    /// Alias for connectToServer (compatibility with IntegrationTestBase tests)
    func connectToTestServer() {
        connectToServer()
    }

    func disconnectFromServer() {
        openSettings()

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
        // Voice state is now indicated by mic button appearance
        // "Idle" = mic button visible with "Tap to Talk" label
        // "Listening" = mic button visible with "Stop" label
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            if expectedState == "Idle" {
                let talkButton = app.buttons["Tap to Talk"]
                if talkButton.exists && talkButton.isEnabled {
                    return true
                }
            } else if expectedState == "Listening" {
                let stopButton = app.buttons["Stop"]
                if stopButton.exists {
                    return true
                }
            }
            usleep(250000)
        }
        return false
    }

    func waitForConnectionState(_ expectedState: String, timeout: TimeInterval = 10.0) -> Bool {
        let stateLabel = app.staticTexts["connectionStatus"]
        let exists = stateLabel.waitForExistence(timeout: timeout)
        return exists && stateLabel.label == expectedState
    }

    /// Wait for a conversation response cycle to complete
    /// This waits for the mic button to become disabled then enabled again
    func waitForResponseCycle(timeout: TimeInterval = 30.0) -> Bool {
        let startTime = Date()

        // First, wait for mic to become unavailable (response cycle started)
        var sawProcessing = false
        while Date().timeIntervalSince(startTime) < timeout {
            let talkButton = app.buttons["Tap to Talk"]

            // Check if mic is disabled or not present (processing)
            if !talkButton.exists || !talkButton.isEnabled {
                sawProcessing = true
                print("✓ Response cycle started (mic unavailable)")
                break
            }

            usleep(250000)
        }

        if !sawProcessing {
            print("✗ Response cycle never started within \(timeout)s")
            return false
        }

        // Now wait for cycle to complete (mic button becomes available again)
        while Date().timeIntervalSince(startTime) < timeout {
            let talkButton = app.buttons["Tap to Talk"]

            if talkButton.exists && talkButton.isEnabled {
                let elapsed = Date().timeIntervalSince(startTime)
                print("✓ Response cycle complete after \(String(format: "%.1f", elapsed))s")
                return true
            }

            usleep(250000)
        }

        print("✗ Response cycle did not complete within \(timeout)s")
        return false
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

    // MARK: - Voice Input

    func sendVoiceInput(_ text: String) {
        let expectation = XCTestExpectation(description: "Send voice input")
        let url = URL(string: "ws://\(testServerHost):\(testServerPort)")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        // Wait for connection to be established by receiving the server's initial status message.
        // The server sends "idle" status immediately upon connection.
        // Without this, task.send() may fail silently if called before handshake completes.
        task.receive { [weak task] result in
            guard let task = task else {
                XCTFail("WebSocket task was deallocated")
                expectation.fulfill()
                return
            }

            switch result {
            case .success(_):
                // Connection established, now send voice input
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
                } else {
                    XCTFail("Failed to serialize voice input message")
                    task.cancel(with: .goingAway, reason: nil)
                    expectation.fulfill()
                }

            case .failure(let error):
                XCTFail("WebSocket connection failed: \(error)")
                expectation.fulfill()
            }
        }

        wait(for: [expectation], timeout: 10.0)
        sleep(1)
    }

    // MARK: - Tmux Verification

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

    /// Wait for Claude Code to be ready to accept input
    /// Polls tmux pane looking for Claude's prompt indicator (❯ or the input box)
    /// Returns true when ready, false on timeout
    func waitForClaudeReady(timeout: TimeInterval = 15.0) -> Bool {
        let startTime = Date()
        // Claude Code shows these indicators when ready for input:
        // - "❯" prompt character
        // - "╭─" box drawing (input area border)
        let readyIndicators = ["❯", "╭─", "│ >"]

        print("⏳ Waiting for Claude Code to be ready...")

        while Date().timeIntervalSince(startTime) < timeout {
            if let content = captureTmuxPane() {
                for indicator in readyIndicators {
                    if content.contains(indicator) {
                        let elapsed = Date().timeIntervalSince(startTime)
                        print("✓ Claude ready after \(String(format: "%.1f", elapsed))s (found '\(indicator)')")
                        return true
                    }
                }
            }
            usleep(500000) // Check every 500ms
        }

        print("✗ Claude not ready after \(timeout)s timeout")
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

    // MARK: - Navigation Helpers

    /// Navigate back to Projects list from any screen
    func navigateToProjectsList() {
        // Try to navigate back to projects list by repeatedly tapping back buttons
        for _ in 0..<5 {
            // Check if we're already on Projects list (look for Add Project floating button)
            let addProjectButton = app.buttons["Add Project"]
            if addProjectButton.exists {
                // Also make sure no sheet is open (no Done button visible)
                let doneButton = app.buttons["Done"]
                if !doneButton.exists {
                    return
                }
            }

            // Try to dismiss any sheets first
            let doneButton = app.buttons["Done"]
            if doneButton.exists {
                doneButton.tap()
                sleep(1)
                continue
            }

            // Try back button
            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            if backButton.exists && backButton.isEnabled {
                backButton.tap()
                sleep(1)
            } else {
                break
            }
        }
    }

    /// Navigate to test project and start/resume a Claude session
    func navigateToTestSession(resume: Bool = false) {
        // First, ensure we're at the projects list
        navigateToProjectsList()

        // Find and tap test project (it's a Button with label starting with "projectName,")
        let projectLabelPrefix = testProjectName + ","
        let projectButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", projectLabelPrefix)).firstMatch
        XCTAssertTrue(projectButton.waitForExistence(timeout: 5), "Test project '\(testProjectName)' should exist")
        projectButton.tap()
        sleep(1)

        if resume {
            // Resume existing session
            let sessionCell = app.cells.firstMatch
            XCTAssertTrue(sessionCell.waitForExistence(timeout: 5), "Session should exist to resume")
            sessionCell.tap()
        } else {
            // Start new session
            let newSessionButton = app.buttons["New Session"]
            XCTAssertTrue(newSessionButton.waitForExistence(timeout: 5), "New Session button should exist")
            newSessionButton.tap()
        }

        XCTAssertTrue(waitForSessionSyncComplete(timeout: 15.0), "Session sync should complete")
        XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux session should be running")
        XCTAssertTrue(waitForClaudeReady(timeout: 15.0), "Claude should be ready for input")
    }

    /// Wait for SessionView sync to complete
    /// Sync is complete when the mic button appears (syncStatus/syncError gone)
    func waitForSessionSyncComplete(timeout: TimeInterval = 15.0) -> Bool {
        let startTime = Date()

        print("⏳ Waiting for session sync to complete...")

        // Wait for mic button to appear (indicates sync complete, no error)
        let talkButton = app.buttons["Tap to Talk"]
        while Date().timeIntervalSince(startTime) < timeout {
            // Check if Talk button exists and is enabled (sync succeeded)
            if talkButton.exists && talkButton.isEnabled {
                let elapsed = Date().timeIntervalSince(startTime)
                print("✓ Session sync complete after \(String(format: "%.1f", elapsed))s - mic button visible")
                return true
            }

            // Check if syncError element exists (sync failed)
            let syncErrorElement = app.otherElements["syncError"]
            if syncErrorElement.exists {
                print("⚠️ Session sync failed - syncError visible")
                return true
            }

            // Check if syncStatus exists (still syncing)
            let syncStatus = app.otherElements["syncStatus"]
            if syncStatus.exists {
                // Still syncing, continue waiting
            }

            usleep(250000) // Check every 250ms
        }

        print("✗ Session sync did not complete within \(timeout)s")

        // Debug: print what elements are visible
        print("  talkButton exists: \(talkButton.exists), enabled: \(talkButton.isEnabled)")
        let syncError = app.otherElements["syncError"]
        let syncStatus = app.otherElements["syncStatus"]
        print("  syncError exists: \(syncError.exists)")
        print("  syncStatus exists: \(syncStatus.exists)")

        return false
    }

}
