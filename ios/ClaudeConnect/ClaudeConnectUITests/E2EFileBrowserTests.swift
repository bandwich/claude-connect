//
//  E2EFileBrowserTests.swift
//  ClaudeConnectUITests
//
//  Tier 1 E2E tests for file browser.
//

import XCTest

final class E2EFileBrowserTests: E2ETestBase {

    /// Files tab shows directory listing
    func test_files_tab_shows_listing() throws {
        navigateToProjectsList()

        let projectCell = app.cells.firstMatch
        XCTAssertTrue(projectCell.waitForExistence(timeout: 5))
        tapByCoordinate(projectCell)

        let filesTab = app.buttons["Files"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        filesTab.tap()
        sleep(2)

        // Should see file entries from mock data
        let fileEntry = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '.'")
        ).firstMatch
        XCTAssertTrue(fileEntry.waitForExistence(timeout: 5), "Should show file entries")
    }

    /// Tapping a file shows file contents
    func test_view_file_contents() throws {
        navigateToProjectsList()

        let projectCell = app.cells.firstMatch
        XCTAssertTrue(projectCell.waitForExistence(timeout: 5))
        tapByCoordinate(projectCell)

        let filesTab = app.buttons["Files"]
        XCTAssertTrue(filesTab.waitForExistence(timeout: 5))
        filesTab.tap()
        sleep(2)

        let fileButton = app.buttons.matching(
            NSPredicate(format: "label CONTAINS '.'")
        ).firstMatch

        if fileButton.waitForExistence(timeout: 5) {
            fileButton.tap()
            sleep(2)

            // Verify not stuck on Loading
            let loadingText = app.staticTexts["Loading..."]
            let startTime = Date()
            while loadingText.exists && Date().timeIntervalSince(startTime) < 10 {
                usleep(500000)
            }
            XCTAssertFalse(loadingText.exists, "File should finish loading")
        }
    }
}
