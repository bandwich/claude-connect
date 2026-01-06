//
//  E2EFullConversationFlowTests.swift
//  ClaudeVoiceUITests
//
//  Comprehensive E2E test simulating a realistic multi-turn conversation
//  with all message types: voice input, text responses, permissions, questions
//

import XCTest

final class E2EFullConversationFlowTests: E2ETestBase {

    /// Comprehensive test simulating a realistic development conversation
    /// Tests the FULL flow in sequence:
    /// 1. Voice input → text response (with TTS)
    /// 2. Voice input → permission request → approve → continued response
    /// 3. Voice input → question prompt → answer → continued response
    /// 4. Voice input → multiple permissions in sequence
    ///
    /// This single test catches integration issues that isolated tests miss.
    func test_complete_conversation_flow_with_all_message_types() throws {
        navigateToTestSession()

        // Verify starting state
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Should start in Idle")

        // ============================================================
        // PHASE 1: Basic voice input → text response
        // ============================================================
        print("📍 PHASE 1: Basic conversation turn")

        simulateConversationTurn(
            userInput: "Hello Claude, I need help with my project",
            assistantResponse: "Hi! I'd be happy to help. What would you like to work on?"
        )

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Phase 1: Should speak response")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 15), "Phase 1: Should return to Idle")

        sleep(1)

        // ============================================================
        // PHASE 2: Voice input → Bash permission → approve → response
        // ============================================================
        print("📍 PHASE 2: Permission flow (Bash)")

        sendVoiceInput("Please install the dependencies")
        injectUserMessage("Please install the dependencies")

        sleep(1)

        let _ = injectPermissionRequest(
            promptType: "bash",
            toolName: "Bash",
            command: "npm install"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Phase 2: Permission sheet should appear")
        XCTAssertTrue(app.navigationBars["Command"].exists, "Phase 2: Should show Command title")

        app.buttons["Allow"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Phase 2: Sheet should dismiss")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 5), "Phase 2: Should return to Idle after approval")

        // Claude continues with response AFTER permission
        sleep(1)
        injectAssistantResponse("Done! I've installed all the dependencies. The project is ready.")

        // KEY TEST: Response should be received after permission
        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Phase 2: Should speak response AFTER permission")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 15), "Phase 2: Should return to Idle")

        sleep(1)

        // ============================================================
        // PHASE 3: Voice input → Edit permission → approve → response
        // ============================================================
        print("📍 PHASE 3: Edit permission flow")

        sendVoiceInput("Add a new utility function")
        injectUserMessage("Add a new utility function")

        sleep(1)

        let _ = injectPermissionRequest(
            promptType: "edit",
            toolName: "Edit",
            filePath: "src/utils.ts",
            oldContent: "export function existing() {}",
            newContent: "export function existing() {}\n\nexport function newHelper() {\n  return 'helper';\n}"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Phase 3: Edit sheet should appear")
        XCTAssertTrue(app.navigationBars["Edit"].exists, "Phase 3: Should show Edit title")

        app.buttons["Approve"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Phase 3: Sheet should dismiss")

        sleep(1)
        injectAssistantResponse("I've added the newHelper function to utils.ts.")

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Phase 3: Should speak after edit approval")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 15), "Phase 3: Should return to Idle")

        sleep(1)

        // ============================================================
        // PHASE 4: Voice input → Question prompt → answer → response
        // ============================================================
        print("📍 PHASE 4: Question flow")

        sendVoiceInput("Set up the database")
        injectUserMessage("Set up the database")

        sleep(1)

        let _ = injectPermissionRequest(
            promptType: "question",
            toolName: "AskUserQuestion",
            questionText: "Which database would you prefer?",
            questionOptions: ["PostgreSQL", "SQLite", "MongoDB"]
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Phase 4: Question sheet should appear")
        XCTAssertTrue(app.navigationBars["Question"].exists, "Phase 4: Should show Question title")

        let sqliteOption = app.staticTexts["SQLite"]
        XCTAssertTrue(sqliteOption.waitForExistence(timeout: 2), "Phase 4: Should show SQLite option")
        sqliteOption.tap()

        app.buttons["Submit"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Phase 4: Sheet should dismiss")

        sleep(1)
        injectAssistantResponse("Great choice! I'll set up SQLite for the database.")

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Phase 4: Should speak after question answered")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 15), "Phase 4: Should return to Idle")

        sleep(1)

        // ============================================================
        // PHASE 5: Multiple permissions in sequence (no voice between)
        // ============================================================
        print("📍 PHASE 5: Sequential permissions")

        sendVoiceInput("Create the schema and seed the database")
        injectUserMessage("Create the schema and seed the database")

        sleep(1)

        // First permission: create schema
        let _ = injectPermissionRequest(
            promptType: "write",
            toolName: "Write",
            filePath: "db/schema.sql",
            oldContent: "",
            newContent: "CREATE TABLE users (id INTEGER PRIMARY KEY);"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Phase 5a: Write sheet should appear")
        app.buttons["Approve"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Phase 5a: Sheet should dismiss")

        sleep(1)

        // Second permission: run seed command (no voice input between!)
        let _ = injectPermissionRequest(
            promptType: "bash",
            toolName: "Bash",
            command: "sqlite3 app.db < db/schema.sql"
        )

        XCTAssertTrue(waitForPermissionSheet(timeout: 5), "Phase 5b: Bash sheet should appear")
        app.buttons["Allow"].tap()
        XCTAssertTrue(waitForPermissionSheetDismissed(), "Phase 5b: Sheet should dismiss")

        sleep(1)

        // Final response after both permissions
        injectAssistantResponse("Database schema created and seeded successfully!")

        XCTAssertTrue(waitForVoiceState("Speaking", timeout: 10), "Phase 5: Should speak final response")
        XCTAssertTrue(waitForVoiceState("Idle", timeout: 15), "Phase 5: Should end in Idle")

        // ============================================================
        // PHASE 6: Verify message history contains all interactions
        // ============================================================
        print("📍 PHASE 6: Verify message history")

        let messageList = app.scrollViews.firstMatch
        if messageList.exists {
            messageList.swipeUp()
        }

        let hasPermissionIndicator = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS '⏳' OR label CONTAINS '✓'")
        ).count > 0
        XCTAssertTrue(hasPermissionIndicator, "Phase 6: Should show permission indicators in history")

        print("✅ Complete conversation flow test passed!")
    }
}
