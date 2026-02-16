# Inline Permission UI Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Replace the modal permission sheet with an inline conversation card that matches the terminal's layout and options, including "always allow" support.

**Architecture:** The server passes through `permission_suggestions` from Claude Code's hook payload to iOS, and forwards `updatedPermissions` back. The iOS app renders permission prompts as inline cards in the conversation scroll view instead of modal sheets. Each card shows the terminal-style layout (type label, command/content, numbered options) and collapses to a summary after the user taps an option.

**Tech Stack:** Python (aiohttp server), Swift/SwiftUI (iOS app), XCTest (E2E tests)

**Risky Assumptions:** The `updatedPermissions` field in the hook response actually causes Claude Code to save the permission rule. We verified the payload format, but haven't verified the response side end-to-end. We'll verify this in Task 3 with a live test.

---

### Task 1: Server — forward `permission_suggestions` and `updatedPermissions`

**Files:**
- Modify: `voice_server/http_server.py:52-81`
- Modify: `voice_server/ios_server.py:865-876`
- Test: `voice_server/tests/test_message_formats.py`

**Step 1: Write failing tests**

Add to `voice_server/tests/test_message_formats.py` — new test in `TestServerToiOSMessageFormats`:

```python
def test_permission_request_includes_suggestions(self):
    """Verify permission_request message includes permission_suggestions when present"""
    message = {
        "type": "permission_request",
        "request_id": "uuid-123-456",
        "prompt_type": "bash",
        "tool_name": "Bash",
        "tool_input": {"command": "npm install"},
        "context": None,
        "question": None,
        "timestamp": 1704500000.0,
        "permission_suggestions": [
            {
                "type": "addRules",
                "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                "behavior": "allow",
                "destination": "localSettings"
            }
        ]
    }
    assert "permission_suggestions" in message
    assert len(message["permission_suggestions"]) == 1
    assert message["permission_suggestions"][0]["type"] == "addRules"
```

Add to `TestiOSToServerMessageFormats`:

```python
def test_permission_response_with_updated_permissions(self):
    """Verify permission_response can include updatedPermissions"""
    message = {
        "type": "permission_response",
        "request_id": "uuid-123-456",
        "decision": "allow",
        "input": None,
        "selected_option": None,
        "updated_permissions": [
            {
                "type": "addRules",
                "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                "behavior": "allow",
                "destination": "localSettings"
            }
        ],
        "timestamp": 1704500000.0
    }
    assert message["decision"] == "allow"
    assert "updated_permissions" in message
```

Add to `TestHTTPHookResponseFormats`:

```python
def test_permission_allow_with_updated_permissions_response_format(self):
    """Verify allow response can include updatedPermissions for 'always allow'"""
    response = {
        "hookSpecificOutput": {
            "hookEventName": "PermissionRequest",
            "decision": {
                "behavior": "allow",
                "updatedPermissions": [
                    {
                        "type": "addRules",
                        "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                        "behavior": "allow",
                        "destination": "localSettings"
                    }
                ]
            }
        }
    }
    assert response["hookSpecificOutput"]["decision"]["behavior"] == "allow"
    assert "updatedPermissions" in response["hookSpecificOutput"]["decision"]
```

Add integration test in `TestHTTPServerActualResponses`:

```python
@pytest.mark.asyncio
async def test_permission_endpoint_forwards_suggestions(self, http_app, permission_handler):
    """Test /permission forwards permission_suggestions to WebSocket broadcast"""
    from aiohttp.test_utils import TestClient, TestServer
    import asyncio

    mock_client = AsyncMock()
    permission_handler.websocket_clients.add(mock_client)
    captured_ws_message = None

    async def capture_and_respond():
        nonlocal captured_ws_message
        await asyncio.sleep(0.1)
        call_args = mock_client.send.call_args[0][0]
        captured_ws_message = json.loads(call_args)
        permission_handler.resolve_request(captured_ws_message["request_id"], {"decision": "allow"})

    async with TestClient(TestServer(http_app)) as client:
        asyncio.create_task(capture_and_respond())

        await client.post("/permission?timeout=5", json={
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"},
            "permission_suggestions": [
                {
                    "type": "addRules",
                    "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                    "behavior": "allow",
                    "destination": "localSettings"
                }
            ]
        })

        # Verify WebSocket message includes permission_suggestions
        assert captured_ws_message is not None
        assert "permission_suggestions" in captured_ws_message
        assert len(captured_ws_message["permission_suggestions"]) == 1

@pytest.mark.asyncio
async def test_permission_endpoint_forwards_updated_permissions(self, http_app, permission_handler):
    """Test /permission includes updatedPermissions in hook response when iOS sends them"""
    from aiohttp.test_utils import TestClient, TestServer
    import asyncio

    mock_client = AsyncMock()
    permission_handler.websocket_clients.add(mock_client)

    updated_perms = [
        {
            "type": "addRules",
            "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
            "behavior": "allow",
            "destination": "localSettings"
        }
    ]

    async def respond_with_perms():
        await asyncio.sleep(0.1)
        call_args = mock_client.send.call_args[0][0]
        data = json.loads(call_args)
        permission_handler.resolve_request(data["request_id"], {
            "decision": "allow",
            "updated_permissions": updated_perms
        })

    async with TestClient(TestServer(http_app)) as client:
        asyncio.create_task(respond_with_perms())

        resp = await client.post("/permission?timeout=5", json={
            "tool_name": "Bash",
            "tool_input": {"command": "npm install"}
        })

        data = await resp.json()
        decision = data["hookSpecificOutput"]["decision"]
        assert decision["behavior"] == "allow"
        assert "updatedPermissions" in decision
        assert decision["updatedPermissions"] == updated_perms
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && pytest test_message_formats.py -v --no-header -q 2>&1 | tail -20`

Expected: New integration tests fail (format tests pass since they're static dicts). The `test_permission_endpoint_forwards_suggestions` and `test_permission_endpoint_forwards_updated_permissions` tests should fail because the server doesn't forward these fields yet.

**Step 3: Implement server changes**

In `voice_server/http_server.py`, update `handle_permission` to forward `permission_suggestions`:

```python
# Line 52-61: Add permission_suggestions to ios_message
ios_message = {
    "type": "permission_request",
    "request_id": request_id,
    "prompt_type": prompt_type,
    "tool_name": tool_name,
    "tool_input": payload.get("tool_input", {}),
    "context": payload.get("context"),
    "question": payload.get("question"),
    "permission_suggestions": payload.get("permission_suggestions"),
    "timestamp": payload.get("timestamp", 0),
}
```

In `voice_server/http_server.py`, update `handle_permission` response to include `updatedPermissions`:

```python
# Line 72-81: Include updatedPermissions in hook response
hook_response = {
    "hookSpecificOutput": {
        "hookEventName": "PermissionRequest",
        "decision": {
            "behavior": response.get("decision", "deny")
        }
    }
}

# Forward updatedPermissions if iOS sent them (for "always allow")
updated_perms = response.get("updated_permissions")
if updated_perms:
    hook_response["hookSpecificOutput"]["decision"]["updatedPermissions"] = updated_perms

return web.json_response(hook_response)
```

In `voice_server/ios_server.py`, update `handle_permission_response` to pass through `updated_permissions`:

```python
# Line 870-876: Include updated_permissions in resolved data
self.permission_handler.resolve_request(request_id, {
    "decision": decision,
    "input": data.get('input'),
    "selected_option": data.get('selected_option'),
    "updated_permissions": data.get('updated_permissions')
})
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && pytest test_message_formats.py -v --no-header -q 2>&1 | tail -20`

Expected: All tests PASS.

**Step 5: Commit**

```bash
git add voice_server/http_server.py voice_server/ios_server.py voice_server/tests/test_message_formats.py
git commit -m "feat: forward permission_suggestions and updatedPermissions through server"
```

---

### Task 2: iOS models — add permission suggestions and update response

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/PermissionRequestTests.swift`

**Step 1: Write failing tests**

Add to `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/PermissionRequestTests.swift`:

```swift
func test_decode_permission_request_with_suggestions() throws {
    let json = """
    {
        "type": "permission_request",
        "request_id": "test-123",
        "prompt_type": "bash",
        "tool_name": "Bash",
        "tool_input": {"command": "npm install"},
        "context": null,
        "question": null,
        "timestamp": 1704500000.0,
        "permission_suggestions": [
            {
                "type": "addRules",
                "rules": [{"toolName": "Bash", "ruleContent": "npm install:*"}],
                "behavior": "allow",
                "destination": "localSettings"
            }
        ]
    }
    """.data(using: .utf8)!

    let request = try JSONDecoder().decode(PermissionRequest.self, from: json)
    XCTAssertEqual(request.permissionSuggestions?.count, 1)
    XCTAssertEqual(request.permissionSuggestions?[0].type, "addRules")
    XCTAssertEqual(request.permissionSuggestions?[0].rules.count, 1)
    XCTAssertEqual(request.permissionSuggestions?[0].rules[0].toolName, "Bash")
    XCTAssertEqual(request.permissionSuggestions?[0].rules[0].ruleContent, "npm install:*")
    XCTAssertEqual(request.permissionSuggestions?[0].behavior, "allow")
    XCTAssertEqual(request.permissionSuggestions?[0].destination, "localSettings")
}

func test_decode_permission_request_without_suggestions() throws {
    let json = """
    {
        "type": "permission_request",
        "request_id": "test-123",
        "prompt_type": "bash",
        "tool_name": "Bash",
        "tool_input": {"command": "npm install"},
        "context": null,
        "question": null,
        "timestamp": 1704500000.0
    }
    """.data(using: .utf8)!

    let request = try JSONDecoder().decode(PermissionRequest.self, from: json)
    XCTAssertNil(request.permissionSuggestions)
}

func test_encode_permission_response_with_updated_permissions() throws {
    let suggestion = PermissionSuggestion(
        type: "addRules",
        rules: [PermissionRule(toolName: "Bash", ruleContent: "npm install:*")],
        behavior: "allow",
        destination: "localSettings"
    )
    let response = PermissionResponse(
        requestId: "test-123",
        decision: .allow,
        updatedPermissions: [suggestion]
    )

    let data = try JSONEncoder().encode(response)
    let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    XCTAssertNotNil(dict["updated_permissions"])
}

func test_encode_permission_response_without_updated_permissions() throws {
    let response = PermissionResponse(requestId: "test-123", decision: .allow)
    let data = try JSONEncoder().encode(response)
    let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    // updated_permissions should not be present when nil
    XCTAssertNil(dict["updated_permissions"])
}

func test_permission_suggestion_display_text_single_rule() {
    let suggestion = PermissionSuggestion(
        type: "addRules",
        rules: [PermissionRule(toolName: "Bash", ruleContent: "npm install:*")],
        behavior: "allow",
        destination: "localSettings"
    )
    XCTAssertEqual(suggestion.displayText, "Yes, and don't ask again for npm install commands")
}

func test_permission_suggestion_display_text_multiple_rules() {
    let suggestion = PermissionSuggestion(
        type: "addRules",
        rules: [
            PermissionRule(toolName: "Bash", ruleContent: "tmux kill-session:*"),
            PermissionRule(toolName: "Bash", ruleContent: "tmux new-session:*")
        ],
        behavior: "allow",
        destination: "localSettings"
    )
    XCTAssertEqual(suggestion.displayText, "Yes, and don't ask again for tmux kill-session, tmux new-session commands")
}

func test_permission_suggestion_display_text_read_tool() {
    let suggestion = PermissionSuggestion(
        type: "addRules",
        rules: [PermissionRule(toolName: "Read", ruleContent: "//private/tmp/**")],
        behavior: "allow",
        destination: "session"
    )
    XCTAssertEqual(suggestion.displayText, "Yes, and don't ask again for Read //private/tmp/**")
}
```

**Step 2: Run tests to verify they fail**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/PermissionRequestTests 2>&1 | tail -20`

Expected: FAIL — `PermissionSuggestion` type doesn't exist yet.

**Step 3: Implement model changes**

Add to `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift`:

```swift
struct PermissionRule: Codable, Equatable {
    let toolName: String
    let ruleContent: String
}

struct PermissionSuggestion: Codable, Equatable {
    let type: String
    let rules: [PermissionRule]
    let behavior: String
    let destination: String

    /// Human-readable display text for the option button
    var displayText: String {
        let ruleDescriptions = rules.map { rule in
            // Strip glob suffix for cleaner display
            // "npm install:*" → "npm install"
            // "//private/tmp/**" → keep as-is (path pattern)
            let content = rule.ruleContent
            if rule.toolName == "Bash" {
                let cleaned = content.hasSuffix(":*") ? String(content.dropLast(2)) : content
                return cleaned
            }
            return "\(rule.toolName) \(content)"
        }
        let joined = ruleDescriptions.joined(separator: ", ")
        return "Yes, and don't ask again for \(joined)" + (rules.first?.toolName == "Bash" ? " commands" : "")
    }
}
```

Update `PermissionRequest` to add `permissionSuggestions`:

```swift
struct PermissionRequest: Codable, Identifiable, Equatable {
    let type: String
    let requestId: String
    let promptType: PermissionPromptType
    let toolName: String
    let toolInput: ToolInput?
    let context: PermissionContext?
    let question: PermissionQuestion?
    let permissionSuggestions: [PermissionSuggestion]?
    let timestamp: Double

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case promptType = "prompt_type"
        case toolName = "tool_name"
        case toolInput = "tool_input"
        case context
        case question
        case permissionSuggestions = "permission_suggestions"
        case timestamp
    }
}
```

Update `PermissionResponse` to add `updatedPermissions`:

```swift
struct PermissionResponse: Codable {
    let type: String
    let requestId: String
    let decision: PermissionDecision
    let input: String?
    let selectedOption: Int?
    let updatedPermissions: [PermissionSuggestion]?
    let timestamp: Double

    init(requestId: String, decision: PermissionDecision, input: String? = nil, selectedOption: Int? = nil, updatedPermissions: [PermissionSuggestion]? = nil) {
        self.type = "permission_response"
        self.requestId = requestId
        self.decision = decision
        self.input = input
        self.selectedOption = selectedOption
        self.updatedPermissions = updatedPermissions
        self.timestamp = Date().timeIntervalSince1970
    }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case decision
        case input
        case selectedOption = "selected_option"
        case updatedPermissions = "updated_permissions"
        case timestamp
    }
}
```

**Step 4: Fix compilation — update old previews**

The old previews in `PermissionPromptView.swift` construct `PermissionRequest` with the memberwise init, which now requires the new `permissionSuggestions` parameter. Add `permissionSuggestions: nil` to each of the 4 `PermissionRequest(...)` calls in the `#Preview` blocks at the bottom of `PermissionPromptView.swift` (lines 207, 223, 243, 262).

**Step 5: Run tests to verify they pass**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/PermissionRequestTests 2>&1 | tail -20`

Expected: All PASS.

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/PermissionRequestTests.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionPromptView.swift
git commit -m "feat: add PermissionSuggestion model and updatedPermissions to response"
```

---

### Task 3: Inline permission card view

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionCardView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift:76-88` (add ConversationItem case)

**Step 1: Add ConversationItem case**

In `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift`, update `ConversationItem`:

```swift
enum ConversationItem: Identifiable {
    case textMessage(SessionHistoryMessage)
    case toolUse(toolId: String, tool: ToolUseBlock, result: ToolResultBlock?)
    case permissionPrompt(requestId: String, request: PermissionRequest)

    var id: String {
        switch self {
        case .textMessage(let msg):
            return "text-\(msg.timestamp)"
        case .toolUse(let toolId, _, _):
            return "tool-\(toolId)"
        case .permissionPrompt(let requestId, _):
            return "perm-\(requestId)"
        }
    }
}
```

**Step 2: Create PermissionCardView**

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionCardView.swift`:

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionCardView.swift
import SwiftUI

struct PermissionCardView: View {
    let request: PermissionRequest
    let resolved: PermissionCardResolution?
    let onResponse: (PermissionResponse) -> Void

    var body: some View {
        if let resolved = resolved {
            resolvedView(resolved)
        } else {
            pendingView
        }
    }

    // MARK: - Resolved (collapsed) state

    private func resolvedView(_ resolution: PermissionCardResolution) -> some View {
        HStack(spacing: 6) {
            Image(systemName: resolution.allowed ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(resolution.allowed ? .green : .red)
                .font(.caption)
            Text(resolution.summary)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
        .accessibilityIdentifier("permissionResolved")
    }

    // MARK: - Pending (interactive) state

    private var pendingView: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Type label (colored)
            typeLabel

            // Content block (command, file, task description, or question)
            contentBlock

            // "Do you want to proceed?" + options
            optionsBlock
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .accessibilityIdentifier("permissionCard")
    }

    // MARK: - Type label

    private var typeLabel: some View {
        Text(typeLabelText)
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundColor(typeLabelColor)
    }

    private var typeLabelText: String {
        switch request.promptType {
        case .bash: return "Bash command"
        case .edit: return "Edit file"
        case .write: return "Create file"
        case .task: return "Agent"
        case .question: return "Question"
        }
    }

    private var typeLabelColor: Color {
        switch request.promptType {
        case .bash: return .orange
        case .edit: return .blue
        case .write: return .green
        case .task: return .purple
        case .question: return .primary
        }
    }

    // MARK: - Content block

    @ViewBuilder
    private var contentBlock: some View {
        switch request.promptType {
        case .bash:
            VStack(alignment: .leading, spacing: 4) {
                if let command = request.toolInput?.command {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(command)
                            .font(.system(.caption, design: .monospaced))
                            .padding(8)
                    }
                    .background(Color(.systemGray5))
                    .cornerRadius(6)
                }
                if let desc = request.toolInput?.description {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

        case .edit, .write:
            VStack(alignment: .leading, spacing: 4) {
                if let path = request.context?.filePath {
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if let context = request.context {
                    DiffView(
                        oldContent: context.oldContent ?? "",
                        newContent: context.newContent ?? "",
                        filePath: context.filePath ?? "file"
                    )
                    .frame(maxHeight: 200)
                }
            }

        case .task:
            if let desc = request.toolInput?.description {
                Text(desc)
                    .font(.caption)
                    .padding(8)
                    .background(Color(.systemGray5))
                    .cornerRadius(6)
            }

        case .question:
            if let text = request.question?.text {
                Text(text)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
        }
    }

    // MARK: - Options block

    @ViewBuilder
    private var optionsBlock: some View {
        if request.promptType == .question {
            questionOptions
        } else {
            permissionOptions
        }
    }

    private var permissionOptions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Do you want to proceed?")
                .font(.caption)
                .foregroundColor(.secondary)

            // Option 1: Yes
            optionButton(number: 1, text: "Yes") {
                sendResponse(.allow)
            }

            // Options from permission_suggestions (always-allow variants)
            if let suggestions = request.permissionSuggestions {
                ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                    optionButton(number: index + 2, text: suggestion.displayText) {
                        sendResponse(.allow, updatedPermissions: [suggestion])
                    }
                }
            }

            // Last option: No
            let noNumber = 2 + (request.permissionSuggestions?.count ?? 0)
            optionButton(number: noNumber, text: "No") {
                sendResponse(.deny)
            }
        }
    }

    @State private var questionTextInput: String = ""
    @State private var selectedQuestionOption: Int? = nil

    @ViewBuilder
    private var questionOptions: some View {
        if let options = request.question?.options, !options.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                    optionButton(number: index + 1, text: option) {
                        sendResponse(.allow, selectedOption: index)
                    }
                }
            }
        } else {
            HStack {
                TextField("Type your answer...", text: $questionTextInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.caption)
                Button("Send") {
                    sendResponse(.allow, input: questionTextInput)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(questionTextInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    // MARK: - Option button

    private func optionButton(number: Int, text: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(number).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 20, alignment: .trailing)
                Text(text)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .multilineTextAlignment(.leading)
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color(.systemGray5))
            .cornerRadius(6)
        }
        .accessibilityIdentifier("permissionOption\(number)")
    }

    // MARK: - Send response

    private func sendResponse(_ decision: PermissionDecision, updatedPermissions: [PermissionSuggestion]? = nil, input: String? = nil, selectedOption: Int? = nil) {
        let response = PermissionResponse(
            requestId: request.requestId,
            decision: decision,
            input: input,
            selectedOption: selectedOption,
            updatedPermissions: updatedPermissions
        )
        onResponse(response)
    }
}

struct PermissionCardResolution {
    let allowed: Bool
    let summary: String
}

#Preview("Bash - Pending") {
    PermissionCardView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-1",
            promptType: .bash,
            toolName: "Bash",
            toolInput: ToolInput(command: "python3 -c \"print('hello from permission test')\"", description: "Test permission flow again"),
            context: nil,
            question: nil,
            permissionSuggestions: [
                PermissionSuggestion(
                    type: "addRules",
                    rules: [PermissionRule(toolName: "Bash", ruleContent: "python3:*")],
                    behavior: "allow",
                    destination: "localSettings"
                )
            ],
            timestamp: Date().timeIntervalSince1970
        ),
        resolved: nil,
        onResponse: { _ in }
    )
    .padding()
}

#Preview("Bash - Resolved") {
    PermissionCardView(
        request: PermissionRequest(
            type: "permission_request",
            requestId: "preview-2",
            promptType: .bash,
            toolName: "Bash",
            toolInput: ToolInput(command: "npm install"),
            context: nil,
            question: nil,
            permissionSuggestions: nil,
            timestamp: Date().timeIntervalSince1970
        ),
        resolved: PermissionCardResolution(allowed: true, summary: "Allowed: `npm install`"),
        onResponse: { _ in }
    )
    .padding()
}
```

**Step 3: Verify it builds**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED.

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionCardView.swift
git commit -m "feat: add inline PermissionCardView with terminal-matching layout"
```

---

### Task 4: Wire inline card into SessionView and remove modal sheet

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift:124-146` (replace sheet with inline)

**Step 1: Update SessionView**

Replace the `.sheet(item:)` and `.onChange(of: pendingPermission)` with inline card logic.

Add state tracking for resolved permissions at the top of `SessionView`:

```swift
@State private var permissionResolutions: [String: PermissionCardResolution] = [:]
```

In the `ForEach(items)` switch statement, add the new case:

```swift
case .permissionPrompt(let requestId, let request):
    PermissionCardView(
        request: request,
        resolved: permissionResolutions[requestId],
        onResponse: { response in
            handlePermissionResponse(response, for: request)
        }
    )
    .id(item.id)
```

Replace the `.sheet(item: $webSocketManager.pendingPermission)` block with nothing (delete it).

Replace the `.onChange(of: webSocketManager.pendingPermission)` block with:

```swift
.onChange(of: webSocketManager.pendingPermission) { _, newValue in
    if let request = newValue {
        items.append(.permissionPrompt(requestId: request.requestId, request: request))
        // Clear pendingPermission so it doesn't re-trigger
        webSocketManager.pendingPermission = nil
    }
}
```

Add the handler function:

```swift
private func handlePermissionResponse(_ response: PermissionResponse, for request: PermissionRequest) {
    let allowed = response.decision == .allow
    let summary = "\(allowed ? "Allowed" : "Denied"): \(permissionDescription(for: request))"
    permissionResolutions[request.requestId] = PermissionCardResolution(
        allowed: allowed,
        summary: summary
    )
    webSocketManager.sendPermissionResponse(response)
}
```

Also handle `permission_resolved` (terminal answer) — update the existing `.onChange(of:)` or add a new one. In `setupView()`, subscribe to resolved events:

```swift
webSocketManager.onPermissionResolved = { resolved in
    if resolved.answeredIn == "terminal" {
        permissionResolutions[resolved.requestId] = PermissionCardResolution(
            allowed: true,
            summary: "Answered in terminal"
        )
    }
}
```

**Step 2: Verify it builds**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED.

**Step 3: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "feat: wire inline permission cards into SessionView, remove modal sheet"
```

---

### Task 5: Update E2E tests for inline permission UI

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift:438-521`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EFullConversationFlowTests.swift:48-60` (update permission references)

**Step 1: Update E2E test helpers**

In `E2ETestBase.swift`, update `injectPermissionRequest` to accept `permissionSuggestions` parameter and update `waitForPermission*` helpers:

```swift
func injectPermissionRequest(
    promptType: String,
    toolName: String,
    command: String? = nil,
    description: String? = nil,
    filePath: String? = nil,
    oldContent: String? = nil,
    newContent: String? = nil,
    questionText: String? = nil,
    questionOptions: [String]? = nil,
    permissionSuggestions: [[String: Any]]? = nil
) -> String {
    // ... existing payload building ...

    if let suggestions = permissionSuggestions {
        payload["permission_suggestions"] = suggestions
    }

    // ... rest unchanged ...
}

func waitForPermissionCard(timeout: TimeInterval = 5.0) -> Bool {
    return app.otherElements["permissionCard"].waitForExistence(timeout: timeout)
}

func waitForPermissionResolved(timeout: TimeInterval = 3.0) -> Bool {
    return app.otherElements["permissionResolved"].waitForExistence(timeout: timeout)
}
```

**Step 2: Rewrite E2E permission tests**

Replace `E2EPermissionTests.swift` with tests that verify inline card behavior:

```swift
import XCTest

final class E2EPermissionTests: E2ETestBase {

    func test_bash_permission_inline_card() throws {
        navigateToTestSession()

        // Inject bash permission with a suggestion
        let _ = injectPermissionRequest(
            promptType: "bash",
            toolName: "Bash",
            command: "npm install express",
            permissionSuggestions: [
                [
                    "type": "addRules",
                    "rules": [["toolName": "Bash", "ruleContent": "npm install:*"]],
                    "behavior": "allow",
                    "destination": "localSettings"
                ]
            ]
        )

        // Card should appear inline (not as a sheet)
        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Verify type label
        XCTAssertTrue(app.staticTexts["Bash command"].exists, "Should show 'Bash command' label")

        // Verify command is shown
        XCTAssertTrue(app.staticTexts["npm install express"].waitForExistence(timeout: 2), "Should show command")

        // Verify options: Yes, always-allow, No
        XCTAssertTrue(app.buttons["permissionOption1"].exists, "Option 1 (Yes) should exist")
        XCTAssertTrue(app.buttons["permissionOption2"].exists, "Option 2 (always allow) should exist")
        XCTAssertTrue(app.buttons["permissionOption3"].exists, "Option 3 (No) should exist")

        // Tap Yes
        app.buttons["permissionOption1"].tap()

        // Card should collapse
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse after response")
    }

    func test_bash_permission_deny() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "bash",
            toolName: "Bash",
            command: "rm -rf /"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Without suggestions: only Yes (1) and No (2)
        XCTAssertTrue(app.buttons["permissionOption2"].exists, "Option 2 (No) should exist")
        app.buttons["permissionOption2"].tap()

        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse after deny")
    }

    func test_edit_permission_inline_card() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "edit",
            toolName: "Edit",
            filePath: "src/utils.ts",
            oldContent: "const foo = 1;",
            newContent: "const foo = 2;"
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Verify type label
        XCTAssertTrue(app.staticTexts["Edit file"].exists, "Should show 'Edit file' label")

        // Verify file path
        XCTAssertTrue(app.staticTexts["src/utils.ts"].waitForExistence(timeout: 2), "Should show file path")

        // Tap Yes to approve
        app.buttons["permissionOption1"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse")
    }

    func test_question_options_inline() throws {
        navigateToTestSession()

        let _ = injectPermissionRequest(
            promptType: "question",
            toolName: "AskUserQuestion",
            questionText: "Which database?",
            questionOptions: ["PostgreSQL", "SQLite"]
        )

        XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")

        // Verify question text
        XCTAssertTrue(app.staticTexts["Which database?"].waitForExistence(timeout: 2))

        // Verify options (numbered)
        XCTAssertTrue(app.buttons["permissionOption1"].exists, "Option 1 should exist")
        XCTAssertTrue(app.buttons["permissionOption2"].exists, "Option 2 should exist")

        // Tap option
        app.buttons["permissionOption2"].tap()
        XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse")
    }
}
```

**Step 3: Update E2EFullConversationFlowTests**

In `E2EFullConversationFlowTests.swift`, update the permission section (~lines 48-60) to use the new inline card:

```swift
// Replace:
//   XCTAssertTrue(waitForPermissionSheet(timeout: 5), ...)
//   XCTAssertTrue(app.navigationBars["Command"].exists, ...)
//   app.buttons["Allow"].tap()
//   XCTAssertTrue(waitForPermissionSheetDismissed(), ...)
// With:
XCTAssertTrue(waitForPermissionCard(timeout: 5), "Permission card should appear")
app.buttons["permissionOption1"].tap()  // "Yes"
XCTAssertTrue(waitForPermissionResolved(timeout: 3), "Card should collapse")
```

**Step 4: Run E2E permission tests**

Run: `cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2EPermissionTests`

Expected: All PASS.

**CHECKPOINT:** If E2E tests fail, debug the inline card rendering. Check that accessibilityIdentifiers are correct and that the card appears in the scroll view.

**Step 5: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EFullConversationFlowTests.swift
git commit -m "test: update E2E permission tests for inline card UI"
```

---

### Task 6: Delete old modal view and verify end-to-end

**Files:**
- Delete: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionPromptView.swift`

**Step 1: Delete the old view**

```bash
rm ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionPromptView.swift
```

**Step 2: Verify build succeeds (no dangling references)**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`

Expected: BUILD SUCCEEDED. If not, find and remove any remaining references to `PermissionPromptView`.

**Step 3: Run full test suites**

Run server tests: `cd voice_server/tests && ./run_tests.sh`
Run iOS unit tests: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests 2>&1 | tail -20`

Expected: All PASS.

**Step 4: Verify end-to-end with live server**

1. Reinstall the server: `pipx install --force /Users/aaron/Desktop/max`
2. Start the server: `claude-connect`
3. Connect iOS app (simulator or device)
4. Open a session and trigger a bash command that needs permission
5. Verify:
   - Permission card appears inline in the conversation (not as a modal sheet)
   - Type label shows "Bash command" in orange
   - Command appears in monospace
   - Options include "Yes", any always-allow variants, and "No"
   - Tapping "Yes" collapses the card to a summary line
   - Claude Code receives the allow response and proceeds

**CHECKPOINT:** This must work live before merging. If the card doesn't appear or responses don't flow back, debug the WebSocket message path.

**Step 5: Commit**

```bash
git rm ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionPromptView.swift
git add -A
git commit -m "feat: remove old modal PermissionPromptView, inline UI complete"
```
