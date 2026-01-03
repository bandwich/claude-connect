//
//  IntegrationTestBase.swift
//  ClaudeVoiceUITests
//
//  Integration test base class with server lifecycle management
//

import XCTest
import Foundation

class IntegrationTestBase: XCTestCase {

    static var app: XCUIApplication!
    static var isConnected = false

    // Read server configuration from environment variables (set by xcodebuild)
    // Falls back to defaults for simulator testing
    // For device testing, uses Mac's local IP (update this if needed)
    let testServerHost: String = {
        if let envHost = ProcessInfo.processInfo.environment["TEST_SERVER_HOST"] {
            return envHost
        }
        // Check if running on physical device vs simulator
        #if targetEnvironment(simulator)
        return "127.0.0.1"  // Simulator can use localhost
        #else
        return "192.168.1.109"  // Physical device needs Mac's IP - UPDATE THIS FOR YOUR NETWORK
        #endif
    }()

    let testServerPort: Int = {
        if let portString = ProcessInfo.processInfo.environment["TEST_SERVER_PORT"],
           let port = Int(portString) {
            return port
        }
        return 8765
    }()

    // Convenience accessor for instance methods
    var app: XCUIApplication! {
        return Self.app
    }

    // Class-level setup: Launch app ONCE per test class
    override class func setUp() {
        super.setUp()

        print("🚀 Launching app once for all tests in \(String(describing: self))")

        // Read server configuration from environment
        let serverHost: String
        if let envHost = ProcessInfo.processInfo.environment["TEST_SERVER_HOST"] {
            serverHost = envHost
        } else {
            #if targetEnvironment(simulator)
            serverHost = "127.0.0.1"
            #else
            serverHost = "192.168.1.109"  // Physical device needs Mac's IP
            #endif
        }
        let serverPort = ProcessInfo.processInfo.environment["TEST_SERVER_PORT"] ?? "8765"

        print("📡 Test server: \(serverHost):\(serverPort)")

        // Launch the iOS app with test environment variables
        app = XCUIApplication()
        app.launchEnvironment = [
            "INTEGRATION_TEST_MODE": "1",
            "TEST_SERVER_HOST": serverHost,
            "TEST_SERVER_PORT": serverPort
        ]
        app.launch()

        // Wait for app to be ready
        sleep(2)

        isConnected = false  // Reset connection state for this test class
    }

    // Class-level teardown: Terminate app ONCE after all tests
    override class func tearDown() {
        print("🛑 Terminating app after all tests in \(String(describing: self))")
        app?.terminate()
        super.tearDown()
    }

    // Per-test setup: Verify server and configure test
    override func setUpWithError() throws {
        try super.setUpWithError()

        continueAfterFailure = false

        // NOTE: Test server must be running before tests start
        // Start it manually with:
        // /Users/aaron/Desktop/max/.venv/bin/python3 /Users/aaron/.claude/voice-mode/integration_tests/test_server.py

        // Verify server is reachable
        try verifyServerRunning()
    }

    // Per-test teardown: Clean up state between tests
    override func tearDownWithError() throws {
        // Don't disconnect between tests - connection persists for all tests in class
        // App termination in class tearDown handles cleanup

        try super.tearDownWithError()
    }

    // MARK: - Server Management

    private func verifyServerRunning() throws {
        // Try to connect to the control endpoint
        let url = URL(string: "http://\(testServerHost):\(testServerPort + 1)/logs")!
        let semaphore = DispatchSemaphore(value: 0)
        var serverReachable = false

        URLSession.shared.dataTask(with: url) { _, response, _ in
            if let httpResponse = response as? HTTPURLResponse {
                serverReachable = httpResponse.statusCode == 200
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 5)

        if !serverReachable {
            throw IntegrationTestError.serverNotRunning
        }

        print("✅ Test server is running")
    }

    // MARK: - Helper Methods

    func connectToTestServer() {
        // Skip if already connected (connection persists for all tests in class)
        if Self.isConnected {
            return
        }

        // Tap settings button
        let settingsButton = app.buttons["gearshape.fill"]
        if settingsButton.waitForExistence(timeout: 5) {
            settingsButton.tap()
        }

        // Enter server IP
        let serverIPField = app.textFields["Server IP Address"]
        if serverIPField.waitForExistence(timeout: 5) {
            serverIPField.tap()

            // Clear any existing text by selecting all and deleting
            if let existingText = serverIPField.value as? String, !existingText.isEmpty {
                let deleteString = String(repeating: XCUIKeyboardKey.delete.rawValue, count: existingText.count)
                serverIPField.typeText(deleteString)
            }

            serverIPField.typeText(testServerHost)
        }

        // Try to find and tap connect button - scroll if needed
        let connectButton = app.buttons["Connect"]
        if !connectButton.exists {
            // Keyboard might be covering it, try to dismiss by tapping a label
            let connectionHeader = app.staticTexts["Connection"]
            if connectionHeader.exists {
                connectionHeader.tap()
                sleep(1)
            }
        }

        if connectButton.waitForExistence(timeout: 5) {
            connectButton.tap()
        }

        // Wait for connection (WebSocket handshake + UI update)
        sleep(8)

        // Close settings
        let doneButton = app.buttons["Done"]
        if doneButton.exists {
            doneButton.tap()
        }

        // Wait for settings to close
        sleep(1)

        // Verify connected status - this is the only assertion we care about
        let connectedLabel = app.staticTexts["connectionStatus"]
        XCTAssertTrue(connectedLabel.waitForExistence(timeout: 5), "Should show Connected status")
        XCTAssertEqual(connectedLabel.label, "Connected", "Connection status should be Connected")

        Self.isConnected = true
    }

    func waitForVoiceState(_ expectedState: String, timeout: TimeInterval = 10.0) -> Bool {
        let stateLabel = app.staticTexts["voiceState"]

        // First ensure the element exists
        guard stateLabel.waitForExistence(timeout: timeout) else {
            return false
        }

        // Then poll for the expected value with timeout
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

    func disconnectFromServer() {
        // Open settings
        let settingsButton = app.buttons["gearshape.fill"]
        if settingsButton.waitForExistence(timeout: 2) {
            settingsButton.tap()
        }

        // Tap disconnect
        let disconnectButton = app.buttons["Disconnect"]
        if disconnectButton.waitForExistence(timeout: 2) {
            disconnectButton.tap()
        }

        // Close settings
        let doneButton = app.buttons["Done"]
        if doneButton.waitForExistence(timeout: 2) {
            doneButton.tap()
        }

        // Wait for disconnection
        sleep(1)
    }

    // MARK: - Server API Helpers

    func sendMockClaudeResponse(_ text: String) {
        // Send HTTP request to test server to inject a mock response
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
        // Send HTTP request to test server to manually inject a status message
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
}

// MARK: - Errors

enum IntegrationTestError: Error {
    case serverStartupTimeout
    case serverNotRunning
    case connectionFailed
}
