// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ContextStats.swift
import Foundation

struct ContextStats: Codable {
    let type: String
    let sessionId: String
    let tokensUsed: Int
    let contextLimit: Int
    let contextPercentage: Double

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case tokensUsed = "tokens_used"
        case contextLimit = "context_limit"
        case contextPercentage = "context_percentage"
    }
}
