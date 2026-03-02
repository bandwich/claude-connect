import Testing
@testable import ClaudeVoice

@Suite("InputBarMode Tests")
struct InputBarModeTests {

    @Test func normalModeAllowsInput() {
        let mode = InputBarMode.normal
        #expect(mode.allowsTextInput == true)
        #expect(mode.allowsMicInput == true)
        #expect(mode.showsPrompt == false)
    }

    @Test func permissionPromptBlocksInput() {
        let request = PermissionRequest(
            type: "permission_request",
            requestId: "test-1",
            promptType: .bash,
            toolName: "Bash",
            toolInput: ToolInput(command: "ls"),
            context: nil,
            question: nil,
            permissionSuggestions: nil,
            timestamp: 0
        )
        let mode = InputBarMode.permissionPrompt(request)
        #expect(mode.allowsTextInput == false)
        #expect(mode.allowsMicInput == false)
        #expect(mode.showsPrompt == true)
    }

    @Test func questionPromptBlocksInput() {
        let request = PermissionRequest(
            type: "permission_request",
            requestId: "test-2",
            promptType: .question,
            toolName: "AskUserQuestion",
            toolInput: nil,
            context: nil,
            question: PermissionQuestion(text: "Which option?", options: ["A", "B"]),
            permissionSuggestions: nil,
            timestamp: 0
        )
        let mode = InputBarMode.questionPrompt(request)
        #expect(mode.allowsTextInput == false)
        #expect(mode.allowsMicInput == false)
        #expect(mode.showsPrompt == true)
    }

    @Test func disconnectedBlocksInput() {
        let mode = InputBarMode.disconnected
        #expect(mode.allowsTextInput == false)
        #expect(mode.allowsMicInput == false)
        #expect(mode.showsPrompt == false)
    }

    @Test func syncingBlocksInput() {
        let mode = InputBarMode.syncing
        #expect(mode.allowsTextInput == false)
        #expect(mode.allowsMicInput == false)
        #expect(mode.showsPrompt == false)
    }
}
