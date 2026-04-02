//
//  E2ETestBase.swift
//  ClaudeConnectUITests
//
//  Base class for E2E tests. Supports two modes:
//  - Test server mode (tier 1): Fast, deterministic. Uses HTTP injection endpoints.
//  - Real server mode (tier 2): Smoke tests with real Claude Code sessions.
//

import XCTest
import Foundation

class E2ETestBase: XCTestCase {

    static var app: XCUIApplication!

    // MARK: - Server Configuration

    let testServerHost: String = {
        if let envHost = ProcessInfo.processInfo.environment["TEST_SERVER_HOST"] {
            return envHost
        }
        #if targetEnvironment(simulator)
        return "127.0.0.1"
        #else
        return "192.168.1.109"
        #endif
    }()

    var testServerPort: Int {
        // Config port takes precedence (smoke tests use isolated ports)
        return configPort
    }

    // MARK: - Test Config

    private static var _testConfig: [String: Any]?
    private var testConfig: [String: Any] {
        if Self._testConfig == nil {
            let configPath = "/tmp/e2e_test_config.json"
            if let data = FileManager.default.contents(atPath: configPath),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                Self._testConfig = json
                print("📋 Loaded test config: \(json)")
            } else {
                print("⚠️ Could not load test config from \(configPath)")
                Self._testConfig = [:]
            }
        }
        return Self._testConfig ?? [:]
    }

    var isTestServerMode: Bool {
        testConfig["mode"] as? String == "test_server"
    }

    var testProjectName: String {
        testConfig["project_name"] as? String ?? "e2e_test_project"
    }

    var testSessionId: String {
        testConfig["session_id"] as? String ?? "test-session-1"
    }

    var testFolderName: String {
        testConfig["folder_name"] as? String ?? "-private-tmp-e2e-test-project"
    }

    /// Port from config (smoke tests use isolated ports to avoid hook interference)
    var configPort: Int {
        if let port = testConfig["port"] as? Int {
            return port
        }
        return 8765
    }

    var app: XCUIApplication! {
        return Self.app
    }

    // MARK: - Setup & Teardown

    override class func setUp() {
        super.setUp()

        print("🚀 Launching app for \(String(describing: self))")

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

        // Read port from config file (smoke tests use isolated ports)
        var serverPort = ProcessInfo.processInfo.environment["TEST_SERVER_PORT"] ?? "8765"
        let configPath = "/tmp/e2e_test_config.json"
        if let data = FileManager.default.contents(atPath: configPath),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let port = json["port"] as? Int {
            serverPort = String(port)
        }

        print("📡 Server: \(serverHost):\(serverPort)")

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

        if isTestServerMode {
            resetServerState()
        }
        Self.app.launch()
        sleep(2)
        connectToServer()
    }

    override func tearDownWithError() throws {
        try super.tearDownWithError()
    }

    override class func tearDown() {
        print("🛑 Terminating app for \(String(describing: self))")
        app?.terminate()
        super.tearDown()
    }

    // MARK: - Server State

    func resetServerState() {
        let httpPort = testServerPort + 1
        let url = URL(string: "http://\(testServerHost):\(httpPort)/reset")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                print("✓ Server state reset")
            }
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
    }

    // MARK: - Connection

    func connectToServer() {
        // App auto-connects on launch using SERVER_HOST env var
        sleep(2)

        // Verify connected — project list shows cells when connected
        let anyProjectCell = app.cells.firstMatch
        if anyProjectCell.waitForExistence(timeout: 10) {
            print("✓ Connected")
            return
        }

        XCTFail("Auto-connect failed — check server status")
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

    // MARK: - UI Helpers

    /// Tap element using coordinates (bypasses scroll-to-visible which can hang in SwiftUI)
    func tapByCoordinate(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    func openSettings() {
        let settingsButton = app.buttons["settingsButton"]
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 5), "Settings button should exist")
        tapByCoordinate(settingsButton)

        let doneButton = app.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5), "Settings sheet should appear")
    }

    // MARK: - Navigation

    func navigateToProjectsList() {
        for _ in 0..<5 {
            let addProjectButton = app.buttons["Add Project"]
            if addProjectButton.exists {
                let doneButton = app.buttons["Done"]
                if !doneButton.exists { return }
            }

            let doneButton = app.buttons["Done"]
            if doneButton.exists {
                doneButton.tap()
                sleep(1)
                continue
            }

            // Custom nav bar uses chevron.left image button (not standard back button)
            let chevronBack = app.buttons["chevron.left"]
            if chevronBack.exists {
                tapByCoordinate(chevronBack)
                sleep(1)
                continue
            }

            // Fallback: standard navigation bar back button
            let navBackButton = app.navigationBars.buttons.element(boundBy: 0)
            if navBackButton.exists && navBackButton.isEnabled {
                navBackButton.tap()
                sleep(1)
            } else {
                break
            }
        }
    }

    func navigateToTestSession(resume: Bool = false) {
        navigateToProjectsList()

        // Find and tap test project
        let projectLabelPrefix = testProjectName + ","
        let projectButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", projectLabelPrefix)).firstMatch
        XCTAssertTrue(projectButton.waitForExistence(timeout: 5), "Test project '\(testProjectName)' should exist")
        projectButton.tap()
        sleep(1)

        if resume {
            let sessionCell = app.cells.firstMatch
            XCTAssertTrue(sessionCell.waitForExistence(timeout: 5), "Session should exist to resume")
            tapByCoordinate(sessionCell)
        } else {
            let newSessionButton = app.buttons["New Session"]
            XCTAssertTrue(newSessionButton.waitForExistence(timeout: 5), "New Session button should exist")
            // Use coordinate tap to avoid XCTest idle-wait blocking on SwiftUI re-renders
            tapByCoordinate(newSessionButton)
        }

        if isTestServerMode {
            // Wait for SessionView to load — animations disabled in test mode
            sleep(2) // Allow navigation to complete
            let loaded = waitForSessionViewLoaded(timeout: 10)
            XCTAssertTrue(loaded, "SessionView should load with input bar visible")
        } else {
            // Real server mode: wait for tmux session
            XCTAssertTrue(waitForSessionSyncComplete(timeout: 15), "Session sync should complete")
            XCTAssertTrue(verifyTmuxSessionRunning(), "Tmux session should be running")
            XCTAssertTrue(waitForClaudeReady(timeout: 15), "Claude should be ready for input")
        }
    }

    // MARK: - Test Server Injection (Tier 1)

    /// Generic POST helper for test server HTTP endpoints
    private func postToTestServer(_ endpoint: String, payload: [String: Any]) {
        let httpPort = testServerPort + 1
        let url = URL(string: "http://\(testServerHost):\(httpPort)\(endpoint)")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        let semaphore = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: request) { _, _, _ in
            semaphore.signal()
        }.resume()
        _ = semaphore.wait(timeout: .now() + 5)
        sleep(1) // Wait for WebSocket broadcast to reach iOS app
    }

    /// Inject content blocks via test server → broadcasts as assistant_response
    func injectContentBlocks(_ blocks: [[String: Any]]) {
        postToTestServer("/inject_content_blocks", payload: ["blocks": blocks])
    }

    /// Inject a simple text response
    func injectTextResponse(_ text: String) {
        injectContentBlocks([["type": "text", "text": text]])
    }

    /// Inject a tool use + result pair
    func injectToolUse(name: String, input: [String: Any], result: String) {
        let toolId = UUID().uuidString
        injectContentBlocks([
            ["type": "tool_use", "id": toolId, "name": name, "input": input],
            ["type": "tool_result", "tool_use_id": toolId, "content": result]
        ])
    }

    /// Inject a question prompt
    func injectQuestionPrompt(question: String, options: [String]) -> String {
        let requestId = UUID().uuidString
        postToTestServer("/inject_question", payload: [
            "request_id": requestId,
            "question": question,
            "options": options
        ])
        return requestId
    }

    /// Inject a directory listing
    func injectDirectoryListing(path: String, entries: [[String: Any]]) {
        postToTestServer("/inject_directory", payload: ["path": path, "entries": entries])
    }

    /// Inject file contents
    func injectFileContents(path: String, contents: String) {
        postToTestServer("/inject_file", payload: ["path": path, "contents": contents])
    }

    // MARK: - Permission Helpers

    /// Wait for SessionView to be fully loaded (input bar visible).
    /// Uses polling with short sleeps instead of XCTest waitForExistence
    /// to avoid idle-wait blocking from SwiftUI continuous updates.
    func waitForSessionViewLoaded(timeout: TimeInterval = 10) -> Bool {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            // Check for elements that only exist in SessionView
            if app.buttons["micButton"].exists || app.textFields["messageTextField"].exists {
                return true
            }
            usleep(500000) // 500ms
        }
        return false
    }

    /// Inject a permission request via the server's /permission endpoint.
    /// Works with both real server and test server (test server has /permission compatibility).
    func injectPermissionRequest(
        promptType: String,
        toolName: String,
        command: String? = nil,
        description: String? = nil,
        filePath: String? = nil,
        oldContent: String? = nil,
        newContent: String? = nil,
        permissionSuggestions: [[String: Any]]? = nil
    ) -> String {
        let requestId = UUID().uuidString

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

        if let suggestions = permissionSuggestions {
            payload["permission_suggestions"] = suggestions
        }

        let httpPort = testServerPort + 1
        let url = URL(string: "http://\(testServerHost):\(httpPort)/permission?timeout=5")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        // Fire and forget
        let task = URLSession.shared.dataTask(with: request)
        task.resume()

        sleep(1) // Wait for HTTP → WebSocket broadcast

        return requestId
    }

    /// Wait for permission card to appear.
    /// XCTest's waitForExistence blocks on SwiftUI's idle-wait inside SessionView,
    /// so we use an XCTNSPredicateExpectation which doesn't block the main thread.
    func waitForPermissionCard(timeout: TimeInterval = 10.0) -> Bool {
        let element = app.buttons["permissionOption1"]
        let predicate = NSPredicate(format: "exists == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    /// Wait for permission to be resolved (option button disappears).
    func waitForPermissionResolved(timeout: TimeInterval = 5.0) -> Bool {
        let element = app.buttons["permissionOption1"]
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }

    // MARK: - Real Server Helpers (Tier 2)

    /// Send voice input via WebSocket (for real Claude smoke tests)
    func sendVoiceInput(_ text: String) {
        let expectation = XCTestExpectation(description: "Send voice input")
        let url = URL(string: "ws://\(testServerHost):\(testServerPort)")!
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()

        task.receive { [weak task] result in
            guard let task = task else {
                XCTFail("WebSocket task was deallocated")
                expectation.fulfill()
                return
            }

            switch result {
            case .success(_):
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
                        // Wait for server to process before closing
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                            task.cancel(with: .goingAway, reason: nil)
                            expectation.fulfill()
                        }
                    }
                } else {
                    XCTFail("Failed to serialize voice input")
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

    /// Verify tmux session is running on the real server
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

    /// Capture tmux pane content
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

    /// Verify text appears in tmux pane
    func verifyInputInTmux(_ text: String, timeout: TimeInterval = 5.0) -> Bool {
        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            if let content = captureTmuxPane(), content.contains(text) {
                return true
            }
            usleep(500000)
        }
        return false
    }

    /// Wait for Claude Code to be ready for input
    func waitForClaudeReady(timeout: TimeInterval = 15.0) -> Bool {
        let startTime = Date()
        let readyIndicators = ["❯", "╭─", "│ >"]

        print("⏳ Waiting for Claude ready...")
        while Date().timeIntervalSince(startTime) < timeout {
            if let content = captureTmuxPane() {
                for indicator in readyIndicators {
                    if content.contains(indicator) {
                        let elapsed = Date().timeIntervalSince(startTime)
                        print("✓ Claude ready after \(String(format: "%.1f", elapsed))s")
                        return true
                    }
                }
            }
            usleep(500000)
        }
        print("✗ Claude not ready after \(timeout)s")
        return false
    }

    /// Wait for session sync to complete (real server mode)
    func waitForSessionSyncComplete(timeout: TimeInterval = 15.0) -> Bool {
        let startTime = Date()
        print("⏳ Waiting for session sync...")
        while Date().timeIntervalSince(startTime) < timeout {
            if verifyTmuxSessionRunning() {
                let elapsed = Date().timeIntervalSince(startTime)
                print("✓ Session sync after \(String(format: "%.1f", elapsed))s")
                return true
            }
            usleep(500000)
        }
        print("✗ Session sync timeout")
        return false
    }
}
