// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/FileModels.swift
import Foundation

struct DirectoryEntry: Codable, Identifiable {
    let name: String
    let type: String  // "directory" or "file"

    var id: String { name }
    var isDirectory: Bool { type == "directory" }
}

struct DirectoryListingResponse: Codable {
    let type: String
    let path: String
    let entries: [DirectoryEntry]?
    let error: String?
}

struct FileContentsResponse: Codable {
    let type: String
    let path: String
    let contents: String?
    let error: String?
}
