import Testing
import Foundation
@testable import ClaudeVoice

@Suite("Bash Collapsed Preview Tests")
struct BashCollapsedPreviewTests {

    @Test func backgroundCommandShowsRunningInBackground() {
        let content = "Command running in background with ID: b59gez7hy. Output is being written to: /private/tmp/claude-501/tasks/b59gez7hy.output"
        let preview = BashPreview.collapsedText(for: content)
        #expect(preview == "Running in background")
    }

    @Test func emptyOutputShowsDone() {
        let preview = BashPreview.collapsedText(for: "")
        #expect(preview == "Done")
    }

    @Test func singleLineShowsFullContent() {
        let preview = BashPreview.collapsedText(for: "hello world")
        #expect(preview == "hello world")
    }

    @Test func threeLineShowsAllLines() {
        let content = "line1\nline2\nline3"
        let preview = BashPreview.collapsedText(for: content)
        #expect(preview == "line1\nline2\nline3")
    }

    @Test func fiveLinesShowsFirstThreePlusTruncation() {
        let content = "line1\nline2\nline3\nline4\nline5"
        let preview = BashPreview.collapsedText(for: content)
        #expect(preview == "line1\nline2\nline3\n… +2 lines")
    }

    @Test func errorContentStillShowsPreview() {
        let content = "ls: /nonexistent: No such file or directory"
        let preview = BashPreview.collapsedText(for: content)
        #expect(preview == "ls: /nonexistent: No such file or directory")
    }
}
