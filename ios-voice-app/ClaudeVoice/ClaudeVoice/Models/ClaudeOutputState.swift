import Foundation

/// Tracks what type of output Claude is currently producing
enum ClaudeOutputState: Equatable {
    case idle
    case thinking
    case usingTool(String)              // tool name
    case speaking
    case awaitingPermission(String)     // request_id
    case awaitingQuestion(String)       // request_id

    var canSendVoiceInput: Bool {
        switch self {
        case .idle:
            return true
        case .thinking, .usingTool, .speaking, .awaitingPermission, .awaitingQuestion:
            return false
        }
    }

    var expectsPermissionResponse: Bool {
        switch self {
        case .awaitingPermission, .awaitingQuestion:
            return true
        default:
            return false
        }
    }

    /// Status text to display (nil = no status indicator)
    var statusText: String? {
        switch self {
        case .idle:
            return nil
        case .thinking:
            return "Thinking..."
        case .usingTool(let name):
            return "Using \(name)..."
        case .speaking:
            return "Speaking..."
        case .awaitingPermission, .awaitingQuestion:
            return nil  // Permission sheet handles this
        }
    }
}
