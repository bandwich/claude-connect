import Foundation

/// Tracks what type of output Claude is currently producing
enum ClaudeOutputState: Equatable {
    case idle
    case thinking
    case usingTool(String)              // tool name
    case speaking

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
        }
    }
}
