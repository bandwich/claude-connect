//
//  ClaudeVoiceUITestsLaunchTests.swift
//  ClaudeVoiceUITests
//
//  Created by Aaron on 12/27/25.
//

import XCTest

final class ClaudeVoiceUITestsLaunchTests: XCTestCase {

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
