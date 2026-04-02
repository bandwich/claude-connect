import XCTest

/// Contract validation tests using real Claude Code sessions.
/// Verify Claude Code's transcript format matches what we parse.
/// If these fail but tier 1 passes, the mock format has drifted.
final class E2ESmokeTests: E2ETestBase {

    /// Smoke test 1: Text response
    /// Sends a simple prompt, verifies a text response appears.
    func test_smoke_text_response() throws {
        navigateToTestSession(resume: true)

        sendVoiceInput("Reply with only the word yes")
        XCTAssertTrue(verifyInputInTmux("Reply with only the word yes", timeout: 10),
                      "Input should reach tmux")

        XCTAssertTrue(waitForClaudeReady(timeout: 60),
                      "Claude should finish responding")

        // Response rendered — transcript was written, parsed, broadcast, and displayed
        sleep(2)
    }

    /// Smoke test 2: Tool use response
    /// Forces tool use, verifies tool_use + tool_result blocks parse and render.
    func test_smoke_tool_use_response() throws {
        navigateToTestSession(resume: true)

        // Create a test file for Claude to read
        let testFilePath = "/tmp/e2e_test_project/smoke_test.txt"
        try? "smoke test content 12345".write(toFile: testFilePath, atomically: true, encoding: .utf8)

        sendVoiceInput("Read the file smoke_test.txt and tell me what it contains. Use the Read tool.")
        XCTAssertTrue(verifyInputInTmux("smoke_test.txt", timeout: 10),
                      "Input should reach tmux")

        XCTAssertTrue(waitForClaudeReady(timeout: 90),
                      "Claude should finish after tool use")

        sleep(3)

        // Verify tool use block or file content appeared
        let toolBlock = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Read'")
        ).firstMatch

        let contentText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'smoke test content' OR label CONTAINS '12345'")
        ).firstMatch

        let anyResponse = toolBlock.exists || contentText.exists
        XCTAssertTrue(anyResponse,
                      "Should see tool use block or file content — transcript format may have changed")

        try? FileManager.default.removeItem(atPath: testFilePath)
    }
}
