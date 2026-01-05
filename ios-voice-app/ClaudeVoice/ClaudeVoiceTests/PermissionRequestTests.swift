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
