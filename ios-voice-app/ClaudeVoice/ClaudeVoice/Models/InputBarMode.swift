import Foundation

enum InputBarMode: Equatable {
    case normal
    case permissionPrompt(PermissionRequest)
    case questionPrompt(QuestionPrompt)
    case syncing
    case disconnected

    var allowsTextInput: Bool {
        if case .normal = self { return true }
        return false
    }

    var allowsMicInput: Bool {
        if case .normal = self { return true }
        return false
    }

    var showsPrompt: Bool {
        switch self {
        case .permissionPrompt, .questionPrompt:
            return true
        default:
            return false
        }
    }
}
