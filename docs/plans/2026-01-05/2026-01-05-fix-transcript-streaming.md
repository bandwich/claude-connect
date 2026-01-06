# Fix Transcript Streaming for Permission-Only Flows

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Stream all assistant content to iOS app regardless of whether voice input initiated the interaction, and consolidate E2E tests into comprehensive flow-based tests.

**Architecture:** Replace voice-input-gated transcript handling with global line tracking. Consolidate fragmented E2E tests into fewer, more comprehensive flow tests.

**Tech Stack:** Python (server), Swift (iOS), pytest, XCTest

---

## Root Cause Analysis

### The Bug

In `voice_server/ios_server.py:70`:

```python
if self.server.last_voice_input:
    new_blocks = self.extract_new_blocks(...)
```

The transcript handler **only** processes content when `last_voice_input` is set.

### Why E2E Tests Didn't Catch This

1. **`simulateConversationTurn`** always calls `sendVoiceInput()` first, which sets `last_voice_input`
2. **Permission tests** only test UI flow - never verify responses arrive AFTER permission approval
3. **No comprehensive flow test** - tests are fragmented, each testing one feature in isolation

---

## Task 1: Audit Existing E2E Tests for Consolidation

**Files to analyze:**
- `E2EHappyPathTests.swift`
- `E2ESessionViewTests.swift`
- `E2EConnectionTests.swift`
- `E2EErrorHandlingTests.swift`
- `E2EProjectsListTests.swift`
- `E2ESessionsListTests.swift`
- `E2EVSCodeConnectionTests.swift`
- `E2EPermissionTests.swift`

### Step 1: Document current test coverage

| File | Tests | What It Tests |
|------|-------|---------------|
| `E2EHappyPathTests` | 1 | Voice → response, multiple turns |
| `E2ESessionViewTests` | 2 | UI elements, voice from session |
| `E2EConnectionTests` | 2 | Connection status, reconnect flow |
| `E2EErrorHandlingTests` | 1 | Malformed JSON, empty input, long response |
| `E2EProjectsListTests` | 1 | Projects load, session counts, settings |
| `E2ESessionsListTests` | 1 | Sessions list, message counts, back nav |
| `E2EVSCodeConnectionTests` | 5 | Sync indicators, active session tracking |
| `E2EPermissionTests` | 6 | All permission types (already consolidated) |

**Total: 19 tests across 8 files**

### Step 2: Identify redundancies after comprehensive flow test

After adding `E2EFullConversationFlowTests`, these become **REDUNDANT**:

| File | Reason |
|------|--------|
| `E2EHappyPathTests` | Comprehensive test covers voice → response and multiple turns |
| `E2ESessionViewTests.test_session_view_voice_input` | Covered by comprehensive test |

### Step 3: Identify consolidation opportunities

| Current Files | Consolidate Into | New Test Name |
|---------------|------------------|---------------|
| `E2EProjectsListTests` + `E2ESessionsListTests` + `E2ESessionViewTests.test_session_view_ui_elements` | `E2ENavigationFlowTests` | `test_complete_navigation_flow` |
| `E2EVSCodeConnectionTests` (5 tests) | `E2EVSCodeFlowTests` | `test_complete_vscode_sync_flow` |
| `E2EConnectionTests` (keep as-is) | - | Already tests reconnection flow |
| `E2EErrorHandlingTests` (keep as-is) | - | Already consolidated |
| `E2EPermissionTests` (keep as-is) | - | Already consolidated |

### Step 4: Proposed final structure

```
E2E Tests (Target: 6 files, ~8 comprehensive tests)
├── E2EFullConversationFlowTests.swift     # NEW: voice + permissions + responses
├── E2ENavigationFlowTests.swift           # NEW: projects → sessions → session view
├── E2EVSCodeFlowTests.swift               # CONSOLIDATED: all sync scenarios
├── E2EConnectionTests.swift               # KEEP: connect/disconnect/reconnect
├── E2EErrorHandlingTests.swift            # KEEP: resilience testing
└── E2EPermissionTests.swift               # KEEP: all permission types
```

**Files to DELETE after consolidation:**
- `E2EHappyPathTests.swift`
- `E2ESessionViewTests.swift`
- `E2EProjectsListTests.swift`
- `E2ESessionsListTests.swift`
- `E2EVSCodeConnectionTests.swift`

---

## Task 2: Write Comprehensive Conversation Flow Test

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EFullConversationFlowTests.swift`

### Step 1: Create new test file

```swift
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
```

### Step 2: Run test to verify it fails

```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2EFullConversationFlowTests
```

Expected: FAIL at Phase 2 - response after permission not received

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EFullConversationFlowTests.swift
git commit -m "test: add comprehensive conversation flow E2E test"
```

---

## Task 3: Write Consolidated Navigation Flow Test

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ENavigationFlowTests.swift`

### Step 1: Create navigation flow test (replaces 3 files)

```swift
//
//  E2ENavigationFlowTests.swift
//  ClaudeVoiceUITests
//
//  Comprehensive navigation test covering the entire app navigation flow
//  Replaces: E2EProjectsListTests, E2ESessionsListTests, E2ESessionViewTests
//

import XCTest

final class E2ENavigationFlowTests: E2ETestBase {

    /// Complete navigation flow test
    /// Tests: Projects list → Sessions list → Session view → Settings → Back navigation
    func test_complete_navigation_flow() throws {
        // ============================================================
        // PHASE 1: Projects List
        // ============================================================
        print("📍 PHASE 1: Projects list")

        // Projects should load after connection (setUp connects)
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should show project1")

        let project2 = app.staticTexts["e2e_test_project2"]
        XCTAssertTrue(project2.waitForExistence(timeout: 5), "Should show project2")

        // Session counts visible
        let count2 = app.staticTexts["2"]
        XCTAssertTrue(count2.exists, "Should show session count")

        // Settings accessible from projects list
        let settingsButton = app.buttons["gearshape.fill"]
        XCTAssertTrue(settingsButton.exists, "Settings button should exist")
        settingsButton.tap()

        let settingsTitle = app.staticTexts["Settings"]
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Should show Settings")
        app.buttons["Done"].tap()

        // ============================================================
        // PHASE 2: Sessions List
        // ============================================================
        print("📍 PHASE 2: Sessions list")

        project1.tap()

        let navTitle = app.navigationBars["e2e_test_project1"]
        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Should navigate to sessions list")

        // Sessions show titles (first user message)
        let session1Title = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1Title.waitForExistence(timeout: 5), "Should show session 1 title")

        let session2Title = app.staticTexts["How do I write a Swift function?"]
        XCTAssertTrue(session2Title.waitForExistence(timeout: 5), "Should show session 2 title")

        // Message counts visible
        let messageCount = app.staticTexts["2 messages"]
        XCTAssertTrue(messageCount.waitForExistence(timeout: 5), "Should show message count")

        // ============================================================
        // PHASE 3: Session View
        // ============================================================
        print("📍 PHASE 3: Session view")

        session1Title.tap()

        // Message history visible
        let userMessage = app.staticTexts["Hello Claude"]
        XCTAssertTrue(userMessage.waitForExistence(timeout: 5), "Should show user message")

        let assistantMessage = app.staticTexts["Hi! How can I help?"]
        XCTAssertTrue(assistantMessage.waitForExistence(timeout: 5), "Should show assistant message")

        // Voice controls visible
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5), "Should show talk button")

        // Settings accessible from session view
        settingsButton.tap()
        XCTAssertTrue(settingsTitle.waitForExistence(timeout: 5), "Should show Settings from session")
        app.buttons["Done"].tap()

        // ============================================================
        // PHASE 4: Back Navigation
        // ============================================================
        print("📍 PHASE 4: Back navigation")

        // Back to sessions list
        let backButton = app.navigationBars.buttons.element(boundBy: 0)
        backButton.tap()

        XCTAssertTrue(navTitle.waitForExistence(timeout: 5), "Should return to sessions list")

        // Back to projects list
        backButton.tap()

        let projectsTitle = app.navigationBars["Projects"]
        XCTAssertTrue(projectsTitle.waitForExistence(timeout: 5), "Should return to projects list")

        print("✅ Complete navigation flow test passed!")
    }
}
```

### Step 2: Run test

```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2ENavigationFlowTests
```

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ENavigationFlowTests.swift
git commit -m "test: add consolidated navigation flow E2E test"
```

---

## Task 4: Write Consolidated VSCode Sync Flow Test

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EVSCodeFlowTests.swift`

### Step 1: Create VSCode sync flow test (replaces 5 tests)

```swift
//
//  E2EVSCodeFlowTests.swift
//  ClaudeVoiceUITests
//
//  Comprehensive VSCode sync test covering all sync scenarios
//  Replaces: E2EVSCodeConnectionTests (5 separate tests)
//

import XCTest

final class E2EVSCodeFlowTests: E2ETestBase {

    /// Complete VSCode sync flow test
    /// Tests: Connect status → Session sync → Active indicators → New session → Switch sessions
    func test_complete_vscode_sync_flow() throws {
        // ============================================================
        // PHASE 1: VSCode Status on Connect
        // ============================================================
        print("📍 PHASE 1: VSCode connection status")

        // After connection (setUp), should be able to see projects
        let project1 = app.staticTexts["e2e_test_project1"]
        XCTAssertTrue(project1.waitForExistence(timeout: 5), "Should see test project")

        // ============================================================
        // PHASE 2: Session Sync Flow
        // ============================================================
        print("📍 PHASE 2: Session sync")

        project1.tap()

        let session1 = app.staticTexts["Hello Claude"]
        XCTAssertTrue(session1.waitForExistence(timeout: 5))
        session1.tap()

        // Should show synced indicator
        let syncedIndicator = app.images["Synced with VSCode"]
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "Should show synced indicator")

        // Talk button should be enabled when synced
        let talkButton = app.buttons["Tap to Talk"]
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5))
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled after sync")

        // ============================================================
        // PHASE 3: Active Session Indicator in List
        // ============================================================
        print("📍 PHASE 3: Active session indicator")

        // Go back to sessions list
        app.navigationBars.buttons.firstMatch.tap()

        // The session should show active indicator
        let activeIndicator = app.images["Active in VSCode"]
        XCTAssertTrue(activeIndicator.waitForExistence(timeout: 5), "Should show active indicator")

        // ============================================================
        // PHASE 4: Switch Sessions
        // ============================================================
        print("📍 PHASE 4: Switch sessions")

        // Tap second session
        let session2 = app.staticTexts["How do I write a Swift function?"]
        XCTAssertTrue(session2.waitForExistence(timeout: 5))
        session2.tap()

        // Should sync to new session
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "Should sync new session")

        // Go back - only session2 should have active indicator
        app.navigationBars.buttons.firstMatch.tap()

        let activeIndicators = app.images.matching(NSPredicate(format: "label == %@", "Active in VSCode"))
        XCTAssertEqual(activeIndicators.count, 1, "Only one session should show active indicator")

        // ============================================================
        // PHASE 5: New Session Flow
        // ============================================================
        print("📍 PHASE 5: New session")

        let newButton = app.buttons["New Session"]
        XCTAssertTrue(newButton.waitForExistence(timeout: 5))
        newButton.tap()

        // New session should sync
        XCTAssertTrue(syncedIndicator.waitForExistence(timeout: 10), "New session should show synced")

        // Talk button should be enabled
        XCTAssertTrue(talkButton.waitForExistence(timeout: 5))
        XCTAssertTrue(talkButton.isEnabled, "Talk button should be enabled for new session")

        print("✅ Complete VSCode sync flow test passed!")
    }
}
```

### Step 2: Run test

```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2EVSCodeFlowTests
```

### Step 3: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EVSCodeFlowTests.swift
git commit -m "test: add consolidated VSCode sync flow E2E test"
```

---

## Task 5: Delete Redundant Test Files

**Files to delete:**
- `E2EHappyPathTests.swift` (covered by comprehensive conversation test)
- `E2ESessionViewTests.swift` (covered by navigation + conversation tests)
- `E2EProjectsListTests.swift` (covered by navigation test)
- `E2ESessionsListTests.swift` (covered by navigation test)
- `E2EVSCodeConnectionTests.swift` (covered by VSCode flow test)

### Step 1: Verify new tests cover all functionality

Run all new consolidated tests:

```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2EFullConversationFlowTests E2ENavigationFlowTests E2EVSCodeFlowTests
```

Expected: All pass

### Step 2: Delete redundant files

```bash
cd ios-voice-app/ClaudeVoice/ClaudeVoiceUITests
rm E2EHappyPathTests.swift
rm E2ESessionViewTests.swift
rm E2EProjectsListTests.swift
rm E2ESessionsListTests.swift
rm E2EVSCodeConnectionTests.swift
```

### Step 3: Commit

```bash
git add -A ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/
git commit -m "refactor: remove redundant E2E tests replaced by flow tests"
```

---

## Task 6: Refactor TranscriptHandler to Track by Line Position

**Files:**
- Modify: `voice_server/ios_server.py`
- Modify: `voice_server/tests/test_ios_server.py`

### Step 1: Write failing unit test

Add to `voice_server/tests/test_ios_server.py`:

```python
class TestTranscriptHandlerGlobalTracking:
    """Tests for line-based tracking (not voice-input-gated)"""

    @pytest.mark.asyncio
    async def test_processes_content_without_voice_input(self, tmp_path):
        """Transcript changes should be processed even without last_voice_input"""
        from ios_server import TranscriptHandler, VoiceServer

        server = VoiceServer()
        server.last_voice_input = None  # The bug condition

        content_received = []
        async def mock_content_callback(response):
            content_received.append(response)

        async def mock_audio_callback(text):
            pass

        loop = asyncio.get_event_loop()
        handler = TranscriptHandler(
            mock_content_callback,
            mock_audio_callback,
            loop,
            server
        )

        transcript = tmp_path / "test.jsonl"
        transcript.write_text(
            '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hello"}]}}\n'
        )

        class MockEvent:
            is_directory = False
            src_path = str(transcript)

        handler.on_modified(MockEvent())
        await asyncio.sleep(0.2)

        assert len(content_received) > 0, "Should process content without voice input"
```

### Step 2: Run test to verify it fails

```bash
cd voice_server/tests && python -m pytest test_ios_server.py::TestTranscriptHandlerGlobalTracking -v
```

Expected: FAIL

### Step 3: Refactor TranscriptHandler

Replace `on_modified` and `extract_new_blocks` with line-position tracking:

```python
class TranscriptHandler(FileSystemEventHandler):
    """Monitors transcript file for new assistant messages"""

    def __init__(self, content_callback, audio_callback, loop, server):
        self.content_callback = content_callback
        self.audio_callback = audio_callback
        self.loop = loop
        self.server = server
        self.last_modified = 0
        self.processed_line_count = 0
        self.last_file_path = None

    def on_modified(self, event):
        if event.is_directory or not event.src_path.endswith('.jsonl'):
            return

        current_time = time.time()
        if current_time - self.last_modified < 0.05:
            return
        self.last_modified = current_time

        try:
            if self.last_file_path != event.src_path:
                self.processed_line_count = 0
                self.last_file_path = event.src_path

            new_blocks = self.extract_new_assistant_content(event.src_path)

            if new_blocks:
                response = AssistantResponse(
                    content_blocks=new_blocks,
                    timestamp=time.time(),
                    is_incremental=True
                )

                asyncio.run_coroutine_threadsafe(
                    self.content_callback(response),
                    self.loop
                )

                text = extract_text_for_tts(new_blocks)
                if text:
                    asyncio.run_coroutine_threadsafe(
                        self.audio_callback(text),
                        self.loop
                    )
        except Exception as e:
            print(f"Error processing transcript: {e}")
            import traceback
            traceback.print_exc()

    def extract_new_assistant_content(self, filepath) -> list[ContentBlock]:
        """Extract assistant content from lines not yet processed"""
        all_blocks = []

        with open(filepath, 'r') as f:
            lines = f.readlines()

        new_lines = lines[self.processed_line_count:]

        for line in new_lines:
            try:
                entry = json.loads(line.strip())
                msg = entry.get('message', {})
                role = msg.get('role') or entry.get('role')

                if role == 'assistant':
                    content = msg.get('content', entry.get('content', ''))

                    if isinstance(content, str) and content.strip():
                        all_blocks.append(TextBlock(type="text", text=content.strip()))
                    elif isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict):
                                block_type = block.get('type')
                                try:
                                    if block_type == 'text':
                                        all_blocks.append(TextBlock(**block))
                                    elif block_type == 'thinking':
                                        all_blocks.append(ThinkingBlock(**block))
                                    elif block_type == 'tool_use':
                                        all_blocks.append(ToolUseBlock(**block))
                                except Exception:
                                    continue
            except json.JSONDecodeError:
                continue

        self.processed_line_count = len(lines)

        if all_blocks:
            print(f"[DEBUG] Extracted {len(all_blocks)} blocks from {len(new_lines)} new lines")

        return all_blocks

    def reset_tracking_state(self):
        """Reset tracking state (called when switching sessions)"""
        self.processed_line_count = 0
        self.last_file_path = None
```

### Step 4: Run tests

```bash
cd voice_server/tests && ./run_tests.sh
```

### Step 5: Commit

```bash
git add voice_server/ios_server.py voice_server/tests/test_ios_server.py
git commit -m "fix: stream all assistant content regardless of voice input"
```

---

## Task 7: Update Remaining Server Tests

### Step 1: Find tests using old API

```bash
grep -rn "last_voice_input\|extract_new_blocks" voice_server/tests/
```

### Step 2: Update each test for new line-based tracking

### Step 3: Run all tests

```bash
cd voice_server/tests && ./run_tests.sh
```

### Step 4: Commit

```bash
git add voice_server/tests/
git commit -m "test: update server tests for line-based transcript tracking"
```

---

## Task 8: Verify All E2E Tests Pass

### Step 1: Run comprehensive conversation flow test

```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2EFullConversationFlowTests
```

Expected: PASS (fix from Task 6 enables response after permission)

### Step 2: Run all E2E tests

```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh
```

Expected: All pass

### Step 3: Commit any fixes

```bash
git add .
git commit -m "fix: ensure all E2E tests pass"
```

---

## Summary

| Task | Description | Files Changed |
|------|-------------|---------------|
| 1 | Audit E2E tests for consolidation | Documentation only |
| 2 | Write comprehensive conversation flow test | +E2EFullConversationFlowTests.swift |
| 3 | Write consolidated navigation flow test | +E2ENavigationFlowTests.swift |
| 4 | Write consolidated VSCode sync flow test | +E2EVSCodeFlowTests.swift |
| 5 | Delete redundant test files | -5 files |
| 6 | Refactor TranscriptHandler | ios_server.py, test_ios_server.py |
| 7 | Update remaining server tests | test_*.py |
| 8 | Verify all tests pass | - |

**Before:** 19 tests across 8 files
**After:** ~8 comprehensive flow tests across 6 files

**Key Principle:** Flow-based tests catch integration bugs that isolated tests miss.
