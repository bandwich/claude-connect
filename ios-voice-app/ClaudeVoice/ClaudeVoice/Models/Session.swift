// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift
import Foundation

struct Session: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let timestamp: Double
    let messageCount: Int

    enum CodingKeys: String, CodingKey {
        case id, title, timestamp
        case messageCount = "message_count"
    }

    var formattedDate: String {
        let date = Date(timeIntervalSince1970: timestamp)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var isNewSession: Bool {
        id.isEmpty
    }

    static func newSession() -> Session {
        Session(id: "", title: "New Session", timestamp: Date().timeIntervalSince1970, messageCount: 0)
    }
}

struct SessionsResponse: Codable {
    let type: String
    let sessions: [Session]
}

struct SessionHistoryMessage: Codable, Identifiable {
    let role: String
    let content: String
    let timestamp: Double

    var id: Double { timestamp }
}

struct SessionHistoryMessageRich: Codable, Identifiable {
    let role: String
    let content: String
    let timestamp: Double
    let contentBlocks: [ContentBlockRaw]?

    var id: Double { timestamp }

    enum CodingKeys: String, CodingKey {
        case role, content, timestamp
        case contentBlocks = "content_blocks"
    }
}

/// Raw content block from session history (looser typing than AssistantContent.ContentBlock)
struct ContentBlockRaw: Codable {
    let type: String
    let text: String?
    let id: String?
    let name: String?
    let input: [String: AnyCodable]?
    let toolUseId: String?
    let content: String?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case type, text, id, name, input, content
        case toolUseId = "tool_use_id"
        case isError = "is_error"
    }
}

enum ConversationItem: Identifiable {
    case textMessage(SessionHistoryMessage)
    case toolUse(toolId: String, tool: ToolUseBlock, result: ToolResultBlock?)
    case permissionPrompt(requestId: String, request: PermissionRequest)

    var id: String {
        switch self {
        case .textMessage(let msg):
            return "text-\(msg.timestamp)"
        case .toolUse(let toolId, _, _):
            return "tool-\(toolId)"
        case .permissionPrompt(let requestId, _):
            return "perm-\(requestId)"
        }
    }
}

struct SessionHistoryResponse: Codable {
    let type: String
    let messages: [SessionHistoryMessageRich]
}

struct SessionActionResponse: Codable {
    let type: String
    let success: Bool
    let sessionId: String?
    let path: String?
    let name: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type, success, path, name, error
        case sessionId = "session_id"
    }
}

struct ConnectionStatus: Codable {
    let type: String
    let connected: Bool
    let activeSessionId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case connected
        case activeSessionId = "active_session_id"
    }
}
