// ios-voice-app/ClaudeConnect/ClaudeConnect/Models/Project.swift
import Foundation

struct Project: Codable, Identifiable {
    let path: String
    let name: String
    let sessionCount: Int
    let folderName: String  // Original folder name for direct lookup

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path, name
        case sessionCount = "session_count"
        case folderName = "folder_name"
    }
}

struct ProjectsResponse: Codable {
    let type: String
    let projects: [Project]
}
