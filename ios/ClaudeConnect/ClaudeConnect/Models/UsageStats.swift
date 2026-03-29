// ios-voice-app/ClaudeConnect/ClaudeConnect/Models/UsageStats.swift
import Foundation

struct UsageCategory: Codable {
    let percentage: Int?
    let resetsAt: String?
    let timezone: String?

    enum CodingKeys: String, CodingKey {
        case percentage
        case resetsAt = "resets_at"
        case timezone
    }
}

struct UsageStats: Codable {
    let type: String
    let session: UsageCategory
    let weekAllModels: UsageCategory
    let weekSonnetOnly: UsageCategory
    let cached: Bool
    let timestamp: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type
        case session
        case weekAllModels = "week_all_models"
        case weekSonnetOnly = "week_sonnet_only"
        case cached
        case timestamp
        case error
    }
}
