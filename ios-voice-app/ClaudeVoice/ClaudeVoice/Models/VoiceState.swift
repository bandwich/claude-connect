import Foundation

enum VoiceState: String {
    case idle
    case listening
    case processing
    case speaking

    var description: String {
        switch self {
        case .idle:
            return "Idle"
        case .listening:
            return "Listening"
        case .processing:
            return "Processing"
        case .speaking:
            return "Speaking"
        }
    }
}
