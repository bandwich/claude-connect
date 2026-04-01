import Testing
import Foundation
@testable import ClaudeConnect

@Suite("SessionClearedMessage Tests")
struct SessionClearedTests {

    @Test func decodesValidMessage() throws {
        let json = """
        {
            "type": "session_cleared",
            "session_id": "abc-123"
        }
        """.data(using: .utf8)!

        let message = try JSONDecoder().decode(SessionClearedMessage.self, from: json)
        #expect(message.type == "session_cleared")
        #expect(message.sessionId == "abc-123")
    }

    @Test func failsWithoutSessionId() {
        let json = """
        {
            "type": "session_cleared"
        }
        """.data(using: .utf8)!

        #expect(throws: Error.self) {
            try JSONDecoder().decode(SessionClearedMessage.self, from: json)
        }
    }

    @Test func callbackFiresWithSessionId() {
        let manager = WebSocketManager()
        var receivedId: String?

        manager.onSessionCleared = { sessionId in
            receivedId = sessionId
        }

        manager.onSessionCleared?("new-session-456")

        #expect(receivedId == "new-session-456")
    }
}
