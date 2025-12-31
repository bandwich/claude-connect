import Foundation

struct VoiceInputMessage: Codable {
    let type: String
    let text: String
    let timestamp: Double

    init(text: String) {
        self.type = "voice_input"
        self.text = text
        self.timestamp = Date().timeIntervalSince1970
    }
}

struct StatusMessage: Codable {
    let type: String
    let state: String
    let message: String
    let timestamp: Double
}

struct AudioChunkMessage: Codable {
    let type: String
    let format: String
    let sampleRate: Int
    let chunkIndex: Int
    let totalChunks: Int
    let data: String

    enum CodingKeys: String, CodingKey {
        case type, format
        case sampleRate = "sample_rate"
        case chunkIndex = "chunk_index"
        case totalChunks = "total_chunks"
        case data
    }
}
