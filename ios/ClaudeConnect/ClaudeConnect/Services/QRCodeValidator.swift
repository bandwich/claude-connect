import Foundation

enum QRValidationError: Error, Equatable {
    case emptyCode
    case invalidScheme(String)
    case invalidURL
}

struct QRCodeValidator {
    func validate(_ code: String) -> Result<URL, QRValidationError> {
        guard !code.isEmpty else {
            return .failure(.emptyCode)
        }

        guard code.hasPrefix("ws://") || code.hasPrefix("wss://") else {
            let scheme = code.components(separatedBy: "://").first ?? "unknown"
            return .failure(.invalidScheme(scheme))
        }

        guard let url = URL(string: code) else {
            return .failure(.invalidURL)
        }

        return .success(url)
    }
}
