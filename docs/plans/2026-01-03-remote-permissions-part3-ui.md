# Remote Permission Control - Part 3: iOS UI Components

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Build the iOS UI components for displaying and responding to permission prompts.

**Architecture:** DiffView for file edit visualization, PermissionPromptView with 4 variants (bash, edit, question, task), presented as sheet from SessionView.

**Tech Stack:** SwiftUI

**Prerequisites:** Parts 1-2 complete (models and WebSocketManager handling exist)

---

## Task 6: DiffView Component

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/DiffView.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/DiffViewTests.swift`

### Step 1: Write the failing test

```swift
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
```

### Step 2: Run test to verify it fails

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/DiffViewTests 2>&1 | tail -20
```
Expected: FAIL with "cannot find type 'DiffParser' in scope"

### Step 3: Write minimal implementation

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/DiffView.swift
import SwiftUI

enum DiffLineType {
    case added
    case removed
    case unchanged
}

struct DiffLine: Identifiable {
    let id = UUID()
    let type: DiffLineType
    let text: String
    let lineNumber: Int?
}

struct DiffParser {
    /// Simple line-by-line diff algorithm
    static func parse(old: String, new: String) -> [DiffLine] {
        let oldLines = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let newLines = new.isEmpty ? [] : new.components(separatedBy: "\n")

        var result: [DiffLine] = []
        var oldIndex = 0
        var newIndex = 0

        while oldIndex < oldLines.count || newIndex < newLines.count {
            if oldIndex >= oldLines.count {
                // Only new lines left
                result.append(DiffLine(type: .added, text: newLines[newIndex], lineNumber: newIndex + 1))
                newIndex += 1
            } else if newIndex >= newLines.count {
                // Only old lines left
                result.append(DiffLine(type: .removed, text: oldLines[oldIndex], lineNumber: nil))
                oldIndex += 1
            } else if oldLines[oldIndex] == newLines[newIndex] {
                // Lines match
                result.append(DiffLine(type: .unchanged, text: oldLines[oldIndex], lineNumber: newIndex + 1))
                oldIndex += 1
                newIndex += 1
            } else {
                // Lines differ - show removal then addition
                result.append(DiffLine(type: .removed, text: oldLines[oldIndex], lineNumber: nil))
                result.append(DiffLine(type: .added, text: newLines[newIndex], lineNumber: newIndex + 1))
                oldIndex += 1
                newIndex += 1
            }
        }

        return result
    }
}

struct DiffView: View {
    let oldContent: String
    let newContent: String
    let filePath: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // File path header
            Text(filePath)
                .font(.caption)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.systemGray6))

            // Diff content
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(DiffParser.parse(old: oldContent, new: newContent)) { line in
                        DiffLineView(line: line)
                    }
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
        .background(Color(.systemBackground))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }
}

struct DiffLineView: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            // Line prefix
            Text(prefix)
                .foregroundColor(prefixColor)
                .frame(width: 16)

            // Line content
            Text(line.text)
                .foregroundColor(textColor)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(backgroundColor)
    }

    private var prefix: String {
        switch line.type {
        case .added: return "+"
        case .removed: return "-"
        case .unchanged: return " "
        }
    }

    private var prefixColor: Color {
        switch line.type {
        case .added: return .green
        case .removed: return .red
        case .unchanged: return .secondary
        }
    }

    private var textColor: Color {
        switch line.type {
        case .added: return .green
        case .removed: return .red
        case .unchanged: return .primary
        }
    }

    private var backgroundColor: Color {
        switch line.type {
        case .added: return Color.green.opacity(0.1)
        case .removed: return Color.red.opacity(0.1)
        case .unchanged: return .clear
        }
    }
}

#Preview {
    DiffView(
        oldContent: "const foo = 1;\nconst bar = 2;",
        newContent: "const foo = 2;\nconst bar = 2;\nconst baz = 3;",
        filePath: "src/utils.ts"
    )
    .padding()
}
```

### Step 4: Run test to verify it passes

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -only-testing:ClaudeVoiceTests/DiffViewTests 2>&1 | tail -20
```
Expected: PASS

### Step 5: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/DiffView.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceTests/DiffViewTests.swift
git commit -m "feat: add DiffView component for file edit visualization"
```

---

## Task 7: PermissionPromptView

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionPromptView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

### Step 1: Create PermissionPromptView

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionPromptView.swift
import SwiftUI

struct PermissionPromptView: View {
    let request: PermissionRequest
    let onResponse: (PermissionResponse) -> Void

    @State private var textInput: String = ""
    @State private var selectedOption: Int? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Header based on type
                headerView

                Divider()

                // Content based on type
                contentView

                Spacer()

                // Action buttons
                actionButtons
            }
            .padding()
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var headerView: some View {
        switch request.promptType {
        case .bash, .task:
            VStack(alignment: .leading, spacing: 8) {
                Text(request.promptType == .bash ? "Allow command?" : "Allow agent?")
                    .font(.headline)
                if let description = request.toolInput?.description {
                    Text(description)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .write, .edit:
            VStack(alignment: .leading, spacing: 8) {
                Text(request.promptType == .write ? "Create file?" : "Edit file?")
                    .font(.headline)
                if let filePath = request.context?.filePath {
                    Text(filePath)
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .question:
            VStack(alignment: .leading, spacing: 8) {
                Text(request.question?.text ?? "Question")
                    .font(.headline)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch request.promptType {
        case .bash:
            // Show command in monospace
            if let command = request.toolInput?.command {
                ScrollView(.horizontal, showsIndicators: false) {
                    Text(command)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                }
            }

        case .task:
            // Show task description
            if let description = request.toolInput?.description {
                Text(description)
                    .font(.body)
                    .padding()
                    .background(Color(.systemGray6))
                    .cornerRadius(8)
            }

        case .write, .edit:
            // Show diff view
            if let context = request.context {
                DiffView(
                    oldContent: context.oldContent ?? "",
                    newContent: context.newContent ?? "",
                    filePath: context.filePath ?? "file"
                )
                .frame(maxHeight: 300)
            }

        case .question:
            // Show text input or option picker
            if let options = request.question?.options, !options.isEmpty {
                // Multiple choice
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                        Button(action: { selectedOption = index }) {
                            HStack {
                                Image(systemName: selectedOption == index ? "circle.fill" : "circle")
                                    .foregroundColor(selectedOption == index ? .blue : .secondary)
                                Text(option)
                                    .foregroundColor(.primary)
                                Spacer()
                            }
                            .padding()
                            .background(Color(.systemGray6))
                            .cornerRadius(8)
                        }
                    }
                }
            } else {
                // Text input
                TextField("Enter your response...", text: $textInput)
                    .textFieldStyle(.roundedBorder)
                    .padding()
            }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch request.promptType {
        case .bash, .task:
            HStack(spacing: 16) {
                Button("Deny") {
                    sendResponse(.deny)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button("Allow") {
                    sendResponse(.allow)
                }
                .buttonStyle(.borderedProminent)
            }

        case .write, .edit:
            HStack(spacing: 16) {
                Button("Reject") {
                    sendResponse(.deny)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                Button("Approve") {
                    sendResponse(.allow)
                }
                .buttonStyle(.borderedProminent)
            }

        case .question:
            Button("Submit") {
                sendResponse(.allow)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitDisabled)
        }
    }

    private var navigationTitle: String {
        switch request.promptType {
        case .bash: return "Command"
        case .write: return "New File"
        case .edit: return "Edit"
        case .question: return "Question"
        case .task: return "Agent"
        }
    }

    private var isSubmitDisabled: Bool {
        if let options = request.question?.options, !options.isEmpty {
            return selectedOption == nil
        }
        return textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendResponse(_ decision: PermissionDecision) {
        let response = PermissionResponse(
            requestId: request.requestId,
            decision: decision,
            input: textInput.isEmpty ? nil : textInput,
            selectedOption: selectedOption
        )
        onResponse(response)
        dismiss()
    }
}

#Preview("Bash Command") {
    PermissionPromptView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-1",
            promptType: .bash,
            toolName: "Bash",
            toolInput: ToolInput(command: "npm install", description: "Install dependencies"),
            context: nil,
            question: nil,
            timestamp: Date().timeIntervalSince1970
        ),
        onResponse: { _ in }
    )
}

#Preview("Edit File") {
    PermissionPromptView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-2",
            promptType: .edit,
            toolName: "Edit",
            toolInput: nil,
            context: PermissionContext(
                filePath: "src/utils.ts",
                oldContent: "const foo = 1;",
                newContent: "const foo = 2;"
            ),
            question: nil,
            timestamp: Date().timeIntervalSince1970
        ),
        onResponse: { _ in }
    )
}

#Preview("Question - Options") {
    PermissionPromptView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-3",
            promptType: .question,
            toolName: "AskUserQuestion",
            toolInput: nil,
            context: nil,
            question: PermissionQuestion(
                text: "Which database should we use?",
                options: ["PostgreSQL", "SQLite", "MongoDB"]
            ),
            timestamp: Date().timeIntervalSince1970
        ),
        onResponse: { _ in }
    )
}

#Preview("Question - Text Input") {
    PermissionPromptView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-4",
            promptType: .question,
            toolName: "AskUserQuestion",
            toolInput: nil,
            context: nil,
            question: PermissionQuestion(
                text: "What should the function be named?",
                options: nil
            ),
            timestamp: Date().timeIntervalSince1970
        ),
        onResponse: { _ in }
    )
}
```

### Step 2: Integrate into SessionView

Add this sheet modifier to `SessionView.swift` after the existing `.sheet(isPresented: $showingSettings)` (around line 131):

```swift
.sheet(item: $webSocketManager.pendingPermission) { request in
    PermissionPromptView(request: request) { response in
        webSocketManager.sendPermissionResponse(response)
    }
}
```

### Step 3: Build to verify compilation

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build \
  -scheme ClaudeVoice \
  -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED

### Step 4: Commit

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionPromptView.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: add PermissionPromptView for remote permission control"
```

---

## Part 3 Complete

**Tasks Completed:** 2
**Files Created/Modified:** 4

**Next:** Continue with Part 4 (Integration & Documentation)
