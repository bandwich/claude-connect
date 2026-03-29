import Testing
import Foundation
@testable import ClaudeConnect

@Suite("SlashCommand Tests")
struct SlashCommandTests {

    @Test func decodesFromJSON() throws {
        let json = """
        {"name": "compact", "description": "Compact conversation", "source": "builtin"}
        """.data(using: .utf8)!
        let command = try JSONDecoder().decode(SlashCommand.self, from: json)
        #expect(command.name == "compact")
        #expect(command.description == "Compact conversation")
        #expect(command.source == "builtin")
        #expect(command.id == "compact")
    }

    @Test func decodesCommandsListResponse() throws {
        let json = """
        {
            "type": "commands_list",
            "commands": [
                {"name": "compact", "description": "Compact conversation", "source": "builtin"},
                {"name": "deploy", "description": "Deploy app", "source": "skill"}
            ]
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CommandsListResponse.self, from: json)
        #expect(response.type == "commands_list")
        #expect(response.commands.count == 2)
        #expect(response.commands[0].name == "compact")
        #expect(response.commands[1].source == "skill")
    }

    @Test func filtersByPrefix() {
        let commands = [
            SlashCommand(name: "compact", description: "Compact", source: "builtin"),
            SlashCommand(name: "commit", description: "Commit", source: "skill"),
            SlashCommand(name: "clear", description: "Clear", source: "builtin"),
            SlashCommand(name: "debug", description: "Debug", source: "skill"),
        ]
        let filtered = commands.filter { $0.name.hasPrefix("com") }
        #expect(filtered.count == 2)
        #expect(filtered[0].name == "compact")
        #expect(filtered[1].name == "commit")
    }
}
