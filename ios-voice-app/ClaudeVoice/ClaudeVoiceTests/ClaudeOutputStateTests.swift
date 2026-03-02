import Testing
@testable import ClaudeVoice

@Suite("ClaudeOutputState Tests")
struct ClaudeOutputStateTests {

    @Test func idleHasNoStatusText() {
        #expect(ClaudeOutputState.idle.statusText == nil)
    }

    @Test func thinkingShowsStatusText() {
        #expect(ClaudeOutputState.thinking.statusText == "Thinking...")
    }

    @Test func usingToolShowsToolName() {
        #expect(ClaudeOutputState.usingTool("Bash").statusText == "Using Bash...")
    }

    @Test func speakingShowsStatusText() {
        #expect(ClaudeOutputState.speaking.statusText == "Speaking...")
    }
}
