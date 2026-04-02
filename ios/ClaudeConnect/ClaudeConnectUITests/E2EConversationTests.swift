//
//  E2EConversationTests.swift
//  ClaudeConnectUITests
//
//  Tier 1 E2E tests for conversation rendering using injected content.
//

import XCTest

final class E2EConversationTests: E2ETestBase {

    /// Injected text response appears in conversation
    func test_text_response_renders() throws {
        navigateToTestSession()

        injectTextResponse("Hello, this is a test response from Claude.")

        let responseText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'test response from Claude'")
        ).firstMatch
        XCTAssertTrue(responseText.waitForExistence(timeout: 10), "Response text should appear")
    }

    /// Tool use block renders with correct structure
    func test_tool_use_renders() throws {
        navigateToTestSession()

        injectToolUse(
            name: "Read",
            input: ["file_path": "/tmp/test.txt"],
            result: "file contents here"
        )

        // Tool use should appear — look for the tool name
        let toolBlock = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Read'")
        ).firstMatch
        XCTAssertTrue(toolBlock.waitForExistence(timeout: 10), "Tool use block should appear")
    }

    /// Multiple content blocks render in sequence
    func test_multiple_blocks_render() throws {
        navigateToTestSession()

        injectContentBlocks([["type": "text", "text": "Let me check that file."]])
        sleep(1)

        let firstText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'check that file'")
        ).firstMatch
        XCTAssertTrue(firstText.waitForExistence(timeout: 10))

        let toolId = UUID().uuidString
        injectContentBlocks([
            ["type": "tool_use", "id": toolId, "name": "Bash", "input": ["command": "ls -la"]],
            ["type": "tool_result", "tool_use_id": toolId, "content": "total 8\ndrwxr-xr-x  2 user  staff  64 Apr  1 12:00 ."]
        ])
        sleep(1)

        let toolBlock = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Bash'")
        ).firstMatch
        XCTAssertTrue(toolBlock.waitForExistence(timeout: 10), "Bash tool block should appear")
    }
}
