// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Project.swift
import Foundation

struct Project: Codable, Identifiable {
    let path: String
    let name: String
    let sessionCount: Int

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, name
        case sessionCount = "session_count"
    }
}

struct ProjectsResponse: Codable {
    let type: String
    let projects: [Project]
}
