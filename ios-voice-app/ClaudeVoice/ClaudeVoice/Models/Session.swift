// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift
import Foundation

struct Session: Codable, Identifiable {
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
