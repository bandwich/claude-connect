import Testing
import Foundation
@testable import ClaudeVoice

@Suite("CommandResponse Tests")
struct CommandResponseTests {

    @Test func decodesCommandResponse() throws {
        let json = """
        {
            "type": "command_response",
            "command": "/help",
            "output": "Available commands:\\n  /compact\\n  /clear",
            "session_id": "abc123"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CommandResponseMessage.self, from: json)
        #expect(response.type == "command_response")
        #expect(response.command == "/help")
        #expect(response.output.contains("/compact"))
        #expect(response.sessionId == "abc123")
    }

    @Test func conversationItemCommandResponse() {
        let item = ConversationItem.commandResponse(command: "/help", output: "test output", timestamp: 1000.0)
        #expect(item.id == "cmd-/help-1000.0")
    }
}
