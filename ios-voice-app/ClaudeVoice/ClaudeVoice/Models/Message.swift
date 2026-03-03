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

struct ImageAttachment: Codable {
    let data: String      // base64-encoded image
    let filename: String
}

struct UserInputMessage: Codable {
    let type: String
    let text: String
    let images: [ImageAttachment]
    let timestamp: Double

    init(text: String, images: [ImageAttachment] = []) {
        self.type = "user_input"
        self.text = text
        self.images = images
        self.timestamp = Date().timeIntervalSince1970
    }
}

struct SetPreferenceMessage: Codable {
    let type: String
    let ttsEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case ttsEnabled = "tts_enabled"
    }

    init(ttsEnabled: Bool) {
        self.type = "set_preference"
        self.ttsEnabled = ttsEnabled
    }
}

struct StatusMessage: Codable {
    let type: String
    let state: String
    let message: String
    let timestamp: Double
}

struct UserMessage: Codable {
    let type: String
    let role: String
    let content: String
    let timestamp: Double
    let sessionId: String?
    let branch: String?
    let seq: Int?

    enum CodingKeys: String, CodingKey {
        case type, role, content, timestamp
        case sessionId = "session_id"
        case branch
        case seq
    }
}

struct StopAudioMessage: Codable {
    let type: String
}

struct ActivityStatusMessage: Codable, Equatable {
    let type: String
    let state: String
    let detail: String
}

struct DeliveryStatusMessage: Codable {
    let type: String
    let status: String  // "confirmed" or "failed"
    let text: String
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
