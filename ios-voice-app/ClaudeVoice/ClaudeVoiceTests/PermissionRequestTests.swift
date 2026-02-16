// ios-voice-app/ClaudeVoice/ClaudeVoiceTests/PermissionRequestTests.swift
import XCTest
@testable import ClaudeVoice

final class PermissionRequestTests: XCTestCase {

    func testDecodeBashPermission() throws {
        let json = """
        {
            "type": "permission_request",
            "request_id": "uuid-123",
            "prompt_type": "bash",
            "tool_name": "Bash",
            "tool_input": {
                "command": "npm install",
                "description": "Install dependencies"
            },
            "timestamp": 1234567890
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)

        XCTAssertEqual(request.requestId, "uuid-123")
        XCTAssertEqual(request.promptType, .bash)
        XCTAssertEqual(request.toolName, "Bash")
        XCTAssertEqual(request.toolInput?.command, "npm install")
    }

    func testDecodeEditPermission() throws {
        let json = """
        {
            "type": "permission_request",
            "request_id": "uuid-456",
            "prompt_type": "edit",
            "tool_name": "Edit",
            "tool_input": {},
            "context": {
                "file_path": "/path/to/file.ts",
                "old_content": "const foo = 1;",
                "new_content": "const foo = 2;"
            },
            "timestamp": 1234567890
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)

        XCTAssertEqual(request.promptType, .edit)
        XCTAssertEqual(request.context?.filePath, "/path/to/file.ts")
        XCTAssertEqual(request.context?.oldContent, "const foo = 1;")
        XCTAssertEqual(request.context?.newContent, "const foo = 2;")
    }

    func testDecodeQuestionPermission() throws {
        let json = """
        {
            "type": "permission_request",
            "request_id": "uuid-789",
            "prompt_type": "question",
            "tool_name": "AskUserQuestion",
            "tool_input": {},
            "question": {
                "text": "Which database?",
                "options": ["PostgreSQL", "SQLite", "MongoDB"]
            },
            "timestamp": 1234567890
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)

        XCTAssertEqual(request.promptType, .question)
        XCTAssertEqual(request.question?.text, "Which database?")
        XCTAssertEqual(request.question?.options, ["PostgreSQL", "SQLite", "MongoDB"])
    }

    func testEncodePermissionResponse() throws {
        let response = PermissionResponse(
            requestId: "uuid-123",
            decision: .allow,
            input: nil,
            selectedOption: nil
        )

        let data = try JSONEncoder().encode(response)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "permission_response")
        XCTAssertEqual(dict["request_id"] as? String, "uuid-123")
        XCTAssertEqual(dict["decision"] as? String, "allow")
    }

    func test_decode_permission_request_with_suggestions() throws {
        let json = """
        {
            "type": "permission_request",
            "request_id": "test-123",
            "prompt_type": "bash",
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"},
            "context": null,
            "question": null,
            "timestamp": 1704500000.0,
            "permission_suggestions": [
                {
                    "type": "addRules",
                    "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                    "behavior": "allow",
                    "destination": "localSettings"
                }
            ]
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)
        XCTAssertEqual(request.permissionSuggestions?.count, 1)
        XCTAssertEqual(request.permissionSuggestions?[0].type, "addRules")
        XCTAssertEqual(request.permissionSuggestions?[0].rules.count, 1)
        XCTAssertEqual(request.permissionSuggestions?[0].rules[0].toolName, "Bash")
        XCTAssertEqual(request.permissionSuggestions?[0].rules[0].ruleContent, "npm install:*")
        XCTAssertEqual(request.permissionSuggestions?[0].behavior, "allow")
        XCTAssertEqual(request.permissionSuggestions?[0].destination, "localSettings")
    }

    func test_decode_permission_request_without_suggestions() throws {
        let json = """
        {
            "type": "permission_request",
            "request_id": "test-123",
            "prompt_type": "bash",
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"},
            "context": null,
            "question": null,
            "timestamp": 1704500000.0
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)
        XCTAssertNil(request.permissionSuggestions)
    }

    func test_encode_permission_response_with_updated_permissions() throws {
        let suggestion = PermissionSuggestion(
            type: "addRules",
            rules: [PermissionRule(toolName: "Bash", ruleContent: "npm install:*")],
            behavior: "allow",
            destination: "localSettings"
        )
        let response = PermissionResponse(
            requestId: "test-123",
            decision: .allow,
            updatedPermissions: [suggestion]
        )

        let data = try JSONEncoder().encode(response)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertNotNil(dict["updated_permissions"])
    }

    func test_encode_permission_response_without_updated_permissions() throws {
        let response = PermissionResponse(requestId: "test-123", decision: .allow)
        let data = try JSONEncoder().encode(response)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        // updated_permissions should not be present when nil
        XCTAssertNil(dict["updated_permissions"])
    }

    func test_permission_suggestion_display_text_single_rule() {
        let suggestion = PermissionSuggestion(
            type: "addRules",
            rules: [PermissionRule(toolName: "Bash", ruleContent: "npm install:*")],
            behavior: "allow",
            destination: "localSettings"
        )
        XCTAssertEqual(suggestion.displayText, "Yes, and don't ask again for npm install commands")
    }

    func test_permission_suggestion_display_text_multiple_rules() {
        let suggestion = PermissionSuggestion(
            type: "addRules",
            rules: [
                PermissionRule(toolName: "Bash", ruleContent: "tmux kill-session:*"),
                PermissionRule(toolName: "Bash", ruleContent: "tmux new-session:*")
            ],
            behavior: "allow",
            destination: "localSettings"
        )
        XCTAssertEqual(suggestion.displayText, "Yes, and don't ask again for tmux kill-session, tmux new-session commands")
    }

    func test_permission_suggestion_display_text_read_tool() {
        let suggestion = PermissionSuggestion(
            type: "addRules",
            rules: [PermissionRule(toolName: "Read", ruleContent: "//private/tmp/**")],
            behavior: "allow",
            destination: "session"
        )
        XCTAssertEqual(suggestion.displayText, "Yes, and don't ask again for Read //private/tmp/**")
    }

    // MARK: - toolAlwaysAllow format (used for Edit, Write, etc.)

    func test_decode_permission_request_with_toolAlwaysAllow_suggestion() throws {
        let json = """
        {
            "type": "permission_request",
            "request_id": "test-edit-1",
            "prompt_type": "edit",
            "tool_name": "Edit",
            "tool_input": {
                "file_path": "/path/to/file.swift",
                "old_string": "let x = 1",
                "new_string": "let x = 2"
            },
            "context": null,
            "question": null,
            "timestamp": 1704500000.0,
            "permission_suggestions": [
                {
                    "type": "toolAlwaysAllow",
                    "tool": "Edit"
                }
            ]
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)
        XCTAssertEqual(request.promptType, .edit)
        XCTAssertEqual(request.toolName, "Edit")
        XCTAssertEqual(request.toolInput?.filePath, "/path/to/file.swift")
        XCTAssertEqual(request.toolInput?.oldString, "let x = 1")
        XCTAssertEqual(request.toolInput?.newString, "let x = 2")
        XCTAssertNil(request.toolInput?.command)
        XCTAssertEqual(request.permissionSuggestions?.count, 1)
        XCTAssertEqual(request.permissionSuggestions?[0].type, "toolAlwaysAllow")
        XCTAssertEqual(request.permissionSuggestions?[0].tool, "Edit")
        XCTAssertNil(request.permissionSuggestions?[0].rules)
    }

    func test_toolAlwaysAllow_display_text() {
        let suggestion = PermissionSuggestion(type: "toolAlwaysAllow", tool: "Edit")
        XCTAssertEqual(suggestion.displayText, "Yes, always allow Edit")
    }

    func test_decode_edit_permission_without_context() throws {
        // Real Claude Code payload: file info in tool_input, no context
        let json = """
        {
            "type": "permission_request",
            "request_id": "test-edit-2",
            "prompt_type": "edit",
            "tool_name": "Edit",
            "tool_input": {
                "file_path": "/src/app.ts",
                "old_string": "console.log('old')",
                "new_string": "console.log('new')",
                "replace_all": false
            },
            "context": null,
            "question": null,
            "timestamp": 0
        }
        """.data(using: .utf8)!

        let request = try JSONDecoder().decode(PermissionRequest.self, from: json)
        XCTAssertEqual(request.promptType, .edit)
        XCTAssertEqual(request.toolInput?.filePath, "/src/app.ts")
        XCTAssertEqual(request.toolInput?.oldString, "console.log('old')")
        XCTAssertEqual(request.toolInput?.newString, "console.log('new')")
        XCTAssertNil(request.context)
        XCTAssertNil(request.permissionSuggestions)
    }

    func testEncodeQuestionResponse() throws {
        let response = PermissionResponse(
            requestId: "uuid-789",
            decision: .allow,
            input: "calculateTotal",
            selectedOption: nil
        )

        let data = try JSONEncoder().encode(response)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["input"] as? String, "calculateTotal")
    }
}
