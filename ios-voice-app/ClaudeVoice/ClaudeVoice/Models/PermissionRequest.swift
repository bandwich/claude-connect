// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift
import Foundation

enum PermissionPromptType: String, Codable {
    case bash
    case write
    case edit
    case question
    case task
}

enum PermissionDecision: String, Codable {
    case allow
    case deny
}

struct ToolInput: Codable, Equatable {
    let command: String?
    let description: String?

    init(command: String? = nil, description: String? = nil) {
        self.command = command
        self.description = description
    }
}

struct PermissionContext: Codable, Equatable {
    let filePath: String?
    let oldContent: String?
    let newContent: String?

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case oldContent = "old_content"
        case newContent = "new_content"
    }
}

struct PermissionQuestion: Codable, Equatable {
    let text: String
    let options: [String]?
}

struct PermissionRequest: Codable, Identifiable, Equatable {
    let type: String
    let requestId: String
    let promptType: PermissionPromptType
    let toolName: String
    let toolInput: ToolInput?
    let context: PermissionContext?
    let question: PermissionQuestion?
    let timestamp: Double

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case promptType = "prompt_type"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case context
        case question
        case timestamp
    }
}

struct PermissionResponse: Codable {
    let type: String
    let requestId: String
    let decision: PermissionDecision
    let input: String?
    let selectedOption: Int?
    let timestamp: Double

    init(requestId: String, decision: PermissionDecision, input: String? = nil, selectedOption: Int? = nil) {
        self.type = "permission_response"
        self.requestId = requestId
        self.decision = decision
        self.input = input
        self.selectedOption = selectedOption
        self.timestamp = Date().timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case decision
        case input
        case selectedOption = "selected_option"
        case timestamp
    }
}

struct PermissionResolved: Codable {
    let type: String
    let requestId: String
    let answeredIn: String

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case answeredIn = "answered_in"
    }
}
