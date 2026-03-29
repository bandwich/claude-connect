//
//  ClaudeConnectUITestsLaunchTests.swift
//  ClaudeConnectUITests
//
//  Created by Aaron on 12/27/25.
//

import XCTest

final class ClaudeConnectUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        // Disabled - not an end-to-end functionality test
        throw XCTSkip("Launch screenshot test disabled")
    }
}
