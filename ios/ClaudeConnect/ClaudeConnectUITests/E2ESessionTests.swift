//
//  E2ESessionTests.swift
//  ClaudeConnectUITests
//
//  Tier 1 E2E tests for session management.
//

import XCTest

final class E2ESessionTests: E2ETestBase {

    /// Open a session and verify it loads
    func test_open_session() throws {
        navigateToTestSession()
        // navigateToTestSession already verifies the session loaded
    }

    /// Navigate back from session to sessions list
    func test_navigate_back_from_session() throws {
        navigateToProjectsList()
        let projectCell = app.cells.firstMatch
        XCTAssertTrue(projectCell.waitForExistence(timeout: 5))
        tapByCoordinate(projectCell)

        let sessionCell = app.cells.firstMatch
        XCTAssertTrue(sessionCell.waitForExistence(timeout: 5))
        tapByCoordinate(sessionCell)
        sleep(2)

        // Custom nav bar uses chevron.left image button
        let chevronBack = app.buttons["chevron.left"]
        if chevronBack.exists {
            tapByCoordinate(chevronBack)
        } else {
            tapByCoordinate(app.buttons.element(boundBy: 0))
        }
        sleep(2)

        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
    }
}
