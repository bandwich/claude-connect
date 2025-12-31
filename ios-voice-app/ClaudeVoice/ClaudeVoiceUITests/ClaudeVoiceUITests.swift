//
//  ClaudeVoiceUITests.swift
//  ClaudeVoiceUITests
//
//  Created by Aaron on 12/27/25.
//

import XCTest

final class ClaudeVoiceUITests: XCTestCase {

    override func setUpWithError() throws {
        // Put setup code here. This method is called before the invocation of each test method in the class.

        // In UI tests it is usually best to stop immediately when a failure occurs.
        continueAfterFailure = false

        // In UI tests it’s important to set the initial state - such as interface orientation - required for your tests before they run. The setUp method is a good place to do this.
    }

    override func tearDownWithError() throws {
        // Put teardown code here. This method is called after the invocation of each test method in the class.
    }

    @MainActor
    func testExample() throws {
        // Disabled - not an end-to-end functionality test
        throw XCTSkip("Template test disabled")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // Disabled - not an end-to-end functionality test
        throw XCTSkip("Performance test disabled")
    }
}
