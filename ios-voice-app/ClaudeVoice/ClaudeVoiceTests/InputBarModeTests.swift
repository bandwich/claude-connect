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
            permissionSuggestions: nil,
            timestamp: 0
        )
        let mode = InputBarMode.permissionPrompt(request)
        #expect(mode.allowsTextInput == false)
        #expect(mode.allowsMicInput == false)
        #expect(mode.showsPrompt == true)
    }

    @Test func questionPromptBlocksInput() {
        let prompt = QuestionPrompt(
            type: "question_prompt",
            requestId: "test-2",
            sessionId: nil,
            header: "Question",
            question: "Which option?",
            options: [QuestionOption(label: "A", description: "Option A"), QuestionOption(label: "B", description: "Option B")],
            multiSelect: false,
            questionIndex: 0,
            totalQuestions: 1
        )
        let mode = InputBarMode.questionPrompt(prompt)
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
