//
//  DebugUITest.swift
//  ClaudeVoiceUITests
//
//  Temporary debug test to see what UI elements exist
//

import XCTest

final class DebugUITest: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        app.launch()
        sleep(2)  // Let app settle
    }

    func testPrintAllUIElements() throws {
        print("\n=== ALL BUTTONS ===")
        for button in app.buttons.allElementsBoundByIndex {
            print("Button: identifier='\(button.identifier)' label='\(button.label)'")
        }

        print("\n=== ALL STATIC TEXTS ===")
        for text in app.staticTexts.allElementsBoundByIndex {
            print("Text: identifier='\(text.identifier)' label='\(text.label)'")
        }

        print("\n=== ALL TEXT FIELDS ===")
        for field in app.textFields.allElementsBoundByIndex {
            print("TextField: identifier='\(field.identifier)' label='\(field.label)'")
        }

        // Now tap settings and see what's there
        let settingsButton = app.buttons["gearshape.fill"]
        if settingsButton.exists {
            print("\n=== TAPPING SETTINGS ===")
            settingsButton.tap()
            sleep(1)

            print("\n=== SETTINGS BUTTONS ===")
            for button in app.buttons.allElementsBoundByIndex {
                print("Button: identifier='\(button.identifier)' label='\(button.label)'")
            }

            print("\n=== SETTINGS TEXT FIELDS ===")
            for field in app.textFields.allElementsBoundByIndex {
                print("TextField: identifier='\(field.identifier)' label='\(field.label)' value='\(field.value as? String ?? "nil")'")
            }
        } else {
            print("Settings button not found!")
        }
    }
}
