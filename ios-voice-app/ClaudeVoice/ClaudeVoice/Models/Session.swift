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

struct SessionHistoryResponse: Codable {
    let type: String
    let messages: [SessionHistoryMessage]
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

struct VSCodeStatus: Codable {
    let type: String
    let vscodeConnected: Bool
    let activeSessionId: String?

    enum CodingKeys: String, CodingKey {
        case type
        case vscodeConnected = "vscode_connected"
        case activeSessionId = "active_session_id"
    }
}
