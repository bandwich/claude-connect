//
//  E2EQuestionTests.swift
//  ClaudeConnectUITests
//
//  Tier 1 E2E tests for question prompt UI.
//

import XCTest

final class E2EQuestionTests: E2ETestBase {

    /// Question prompt appears with option buttons
    func test_question_with_options() throws {
        navigateToTestSession()

        let _ = injectQuestionPrompt(
            question: "Which approach should I use?",
            options: ["Option A", "Option B", "Option C"]
        )

        let questionCard = app.otherElements["questionCard"]
        XCTAssertTrue(questionCard.waitForExistence(timeout: 5), "Question card should appear")

        let questionText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'Which approach'")
        ).firstMatch
        XCTAssertTrue(questionText.waitForExistence(timeout: 3), "Question text should appear")

        let optionA = app.buttons.matching(
            NSPredicate(format: "label CONTAINS 'Option A'")
        ).firstMatch
        XCTAssertTrue(optionA.waitForExistence(timeout: 3), "Option A should exist")
        optionA.tap()

        sleep(2)
        XCTAssertFalse(questionCard.exists, "Card should dismiss after answer")
    }

    /// Question without options shows text input
    func test_question_without_options() throws {
        navigateToTestSession()

        let _ = injectQuestionPrompt(
            question: "What should I name this variable?",
            options: []
        )

        let questionCard = app.otherElements["questionCard"]
        XCTAssertTrue(questionCard.waitForExistence(timeout: 5), "Question card should appear")

        let questionText = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS 'name this variable'")
        ).firstMatch
        XCTAssertTrue(questionText.waitForExistence(timeout: 3))
    }
}
