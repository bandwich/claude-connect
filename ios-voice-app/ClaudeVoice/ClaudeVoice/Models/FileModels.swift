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
    let imageData: String?     // base64-encoded image bytes
    let imageFormat: String?   // "png", "jpg", etc.
    let fileSize: Int?         // file size in bytes

    enum CodingKeys: String, CodingKey {
        case type, path, contents, error
        case imageData = "image_data"
        case imageFormat = "image_format"
        case fileSize = "file_size"
    }
}
