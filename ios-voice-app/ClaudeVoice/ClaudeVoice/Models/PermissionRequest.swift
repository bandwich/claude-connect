// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift
import Foundation

enum PermissionPromptType: String, Codable {
    case bash
    case write
    case edit
    case task
}

enum PermissionDecision: String, Codable {
    case allow
    case deny
}

struct ToolInput: Codable, Equatable {
    let command: String?
    let description: String?
    // Edit/Write tool fields
    let filePath: String?
    let oldString: String?
    let newString: String?

    init(command: String? = nil, description: String? = nil, filePath: String? = nil, oldString: String? = nil, newString: String? = nil) {
        self.command = command
        self.description = description
        self.filePath = filePath
        self.oldString = oldString
        self.newString = newString
    }

    enum CodingKeys: String, CodingKey {
        case command, description
        case filePath = "file_path"
        case oldString = "old_string"
        case newString = "new_string"
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

struct PermissionRule: Codable, Equatable {
    let toolName: String
    let ruleContent: String
}

struct PermissionSuggestion: Codable, Equatable {
    let type: String
    // addRules format
    let rules: [PermissionRule]?
    let behavior: String?
    let destination: String?
    // toolAlwaysAllow format
    let tool: String?
    // setMode format
    let mode: String?

    init(type: String, rules: [PermissionRule]? = nil, behavior: String? = nil, destination: String? = nil, tool: String? = nil, mode: String? = nil) {
        self.type = type
        self.rules = rules
        self.behavior = behavior
        self.destination = destination
        self.tool = tool
        self.mode = mode
    }

    /// Human-readable display text for the option button
    var displayText: String {
        if type == "toolAlwaysAllow", let tool = tool {
            return "Yes, always allow \(tool)"
        }
        guard let rules = rules, !rules.isEmpty else {
            return "Yes, and always allow"
        }
        let ruleDescriptions = rules.map { rule in
            let content = rule.ruleContent
            if rule.toolName == "Bash" {
                let cleaned = content.hasSuffix(":*") ? String(content.dropLast(2)) : content
                return cleaned
            }
            return "\(rule.toolName) \(content)"
        }
        let joined = ruleDescriptions.joined(separator: ", ")
        return "Yes, and don't ask again for \(joined)" + (rules.first?.toolName == "Bash" ? " commands" : "")
    }
}

struct PermissionRequest: Codable, Identifiable, Equatable {
    let type: String
    let requestId: String
    let promptType: PermissionPromptType
    let toolName: String
    let toolInput: ToolInput?
    let context: PermissionContext?
    let permissionSuggestions: [PermissionSuggestion]?
    let timestamp: Double

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case promptType = "prompt_type"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case context
        case permissionSuggestions = "permission_suggestions"
        case timestamp
    }
}

struct PermissionResponse: Codable {
    let type: String
    let requestId: String
    let decision: PermissionDecision
    let input: String?
    let selectedOption: Int?
    let updatedPermissions: [PermissionSuggestion]?
    let timestamp: Double

    init(requestId: String, decision: PermissionDecision, input: String? = nil, selectedOption: Int? = nil, updatedPermissions: [PermissionSuggestion]? = nil) {
        self.type = "permission_response"
        self.requestId = requestId
        self.decision = decision
        self.input = input
        self.selectedOption = selectedOption
        self.updatedPermissions = updatedPermissions
        self.timestamp = Date().timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case decision
        case input
        case selectedOption = "selected_option"
        case updatedPermissions = "updated_permissions"
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

struct QuestionOption: Codable, Equatable {
    let label: String
    let description: String
}

struct QuestionPrompt: Codable, Identifiable, Equatable {
    let type: String
    let requestId: String
    let header: String
    let question: String
    let options: [QuestionOption]
    let multiSelect: Bool
    let questionIndex: Int
    let totalQuestions: Int

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case header
        case question
        case options
        case multiSelect = "multi_select"
        case questionIndex = "question_index"
        case totalQuestions = "total_questions"
    }
}

struct QuestionResolved: Codable {
    let type: String
    let requestId: String

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
    }
}
