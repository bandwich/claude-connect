import Foundation

struct SlashCommand: Codable, Identifiable, Equatable {
    let name: String
    let description: String
    let source: String
    var id: String { name }
}

struct CommandsListResponse: Codable {
    let type: String
    let commands: [SlashCommand]
}
