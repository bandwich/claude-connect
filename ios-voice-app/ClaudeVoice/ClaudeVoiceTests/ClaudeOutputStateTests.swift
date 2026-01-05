import Testing
@testable import ClaudeVoice

@Suite("ClaudeOutputState Tests")
struct ClaudeOutputStateTests {

    @Test func testIdleAllowsVoiceInput() {
        let state = ClaudeOutputState.idle
        #expect(state.canSendVoiceInput == true)
        #expect(state.expectsPermissionResponse == false)
    }

    @Test func testAwaitingPermissionBlocksVoiceAllowsResponse() {
        let state = ClaudeOutputState.awaitingPermission("req-123")
        #expect(state.canSendVoiceInput == false)
        #expect(state.expectsPermissionResponse == true)
    }

    @Test func testThinkingBlocksVoiceInput() {
        let state = ClaudeOutputState.thinking
        #expect(state.canSendVoiceInput == false)
    }

    @Test func testUsingToolBlocksVoiceInput() {
        let state = ClaudeOutputState.usingTool("Bash")
        #expect(state.canSendVoiceInput == false)
    }

    @Test func testSpeakingBlocksVoiceInput() {
        let state = ClaudeOutputState.speaking
        #expect(state.canSendVoiceInput == false)
    }
}
