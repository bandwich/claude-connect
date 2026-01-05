// ios-voice-app/ClaudeVoice/ClaudeVoiceTests/DiffViewTests.swift
import XCTest
@testable import ClaudeVoice

final class DiffViewTests: XCTestCase {

    func testParseDiffLines() {
        let oldContent = "line1\nline2\nline3"
        let newContent = "line1\nmodified\nline3\nline4"

        let lines = DiffParser.parse(old: oldContent, new: newContent)

        // line1: unchanged
        XCTAssertEqual(lines[0].type, .unchanged)
        XCTAssertEqual(lines[0].text, "line1")

        // line2 -> modified: removed then added
        XCTAssertEqual(lines[1].type, .removed)
        XCTAssertEqual(lines[1].text, "line2")

        XCTAssertEqual(lines[2].type, .added)
        XCTAssertEqual(lines[2].text, "modified")

        // line3: unchanged
        XCTAssertEqual(lines[3].type, .unchanged)
        XCTAssertEqual(lines[3].text, "line3")

        // line4: added
        XCTAssertEqual(lines[4].type, .added)
        XCTAssertEqual(lines[4].text, "line4")
    }

    func testEmptyDiff() {
        let lines = DiffParser.parse(old: "", new: "")
        XCTAssertTrue(lines.isEmpty)
    }

    func testAllAdded() {
        let lines = DiffParser.parse(old: "", new: "line1\nline2")

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.type == .added })
    }

    func testAllRemoved() {
        let lines = DiffParser.parse(old: "line1\nline2", new: "")

        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { $0.type == .removed })
    }
}
