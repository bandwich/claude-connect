# Question Prompt Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Enable iOS app to show AskUserQuestion options as tappable buttons via a PreToolUse hook, replacing the broken PermissionRequest-based approach.

**Architecture:** A new `question_hook.sh` intercepts AskUserQuestion via PreToolUse, POSTs to a new `/question` endpoint on the HTTP server, which broadcasts the question to the iOS app via WebSocket. The iOS app shows options in the input bar. The user's answer flows back through WebSocket → HTTP response → hook stdout → Claude Code (as a `permissionDecision: "deny"` with the answer in `permissionDecisionReason`).

**Tech Stack:** Python (aiohttp), Swift/SwiftUI, bash (hook script)

**Risky Assumptions:** None — the PreToolUse deny+reason approach was verified manually before this plan was written. Claude receives the answer and proceeds without showing terminal UI.

---

### Task 1: Server — `/question` endpoint and hook script

**Files:**
- Create: `voice_server/hooks/question_hook.sh`
- Modify: `voice_server/http_server.py`
- Test: `voice_server/tests/test_permission_integration.py` (add question endpoint tests)

**Step 1: Write the failing tests**

Add to `voice_server/tests/test_permission_integration.py`:

```python
    @unittest_run_loop
    async def test_question_endpoint_broadcasts_and_waits(self):
        """Test /question endpoint broadcasts question_prompt and waits for response"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_answers():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            # Verify broadcast format
            assert data["type"] == "question_prompt"
            assert data["question"] == "Which database?"
            assert data["header"] == "Scope"
            assert len(data["options"]) == 2
            assert data["options"][0]["label"] == "PostgreSQL"
            assert data["options"][0]["description"] == "Fast relational DB"
            assert data["question_index"] == 0
            assert data["total_questions"] == 1

            self.permission_handler.resolve_request(data["request_id"], {
                "answer": "PostgreSQL"
            })

        asyncio.create_task(ios_answers())

        resp = await self.client.post("/question", json={
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [{
                    "question": "Which database?",
                    "header": "Scope",
                    "options": [
                        {"label": "PostgreSQL", "description": "Fast relational DB"},
                        {"label": "SQLite", "description": "Embedded, zero config"}
                    ],
                    "multiSelect": False
                }]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["hookSpecificOutput"]["hookEventName"] == "PreToolUse"
        assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "PostgreSQL" in result["hookSpecificOutput"]["permissionDecisionReason"]

    @unittest_run_loop
    async def test_question_endpoint_dismiss(self):
        """Test /question endpoint handles dismiss"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_dismisses():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            self.permission_handler.resolve_request(data["request_id"], {
                "dismissed": True
            })

        asyncio.create_task(ios_dismisses())

        resp = await self.client.post("/question", json={
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [{
                    "question": "Which color?",
                    "header": "Color",
                    "options": [
                        {"label": "Red", "description": "Warm"},
                        {"label": "Blue", "description": "Cool"}
                    ],
                    "multiSelect": False
                }]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        assert result["hookSpecificOutput"]["permissionDecision"] == "deny"
        assert "dismissed" in result["hookSpecificOutput"]["permissionDecisionReason"].lower()

    @unittest_run_loop
    async def test_question_endpoint_timeout(self):
        """Test /question endpoint times out and falls back"""
        resp = await self.client.post("/question?timeout=0.1", json={
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [{
                    "question": "Pick one",
                    "header": "Test",
                    "options": [],
                    "multiSelect": False
                }]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        # On timeout, return exit-2 equivalent so hook falls back to terminal
        assert result.get("fallback") == True

    @unittest_run_loop
    async def test_question_endpoint_free_text(self):
        """Test /question endpoint with no options (free text answer)"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_types():
            await asyncio.sleep(0.05)
            broadcast_call = mock_ios.send.call_args[0][0]
            data = json.loads(broadcast_call)
            assert data["options"] == []
            self.permission_handler.resolve_request(data["request_id"], {
                "answer": "calculateTotal"
            })

        asyncio.create_task(ios_types())

        resp = await self.client.post("/question", json={
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [{
                    "question": "What should the function be named?",
                    "header": "Name",
                    "multiSelect": False
                }]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        assert "calculateTotal" in result["hookSpecificOutput"]["permissionDecisionReason"]

    @unittest_run_loop
    async def test_question_endpoint_multiple_questions(self):
        """Test /question endpoint with multiple questions sends one at a time"""
        mock_ios = AsyncMock()
        self.permission_handler.websocket_clients.add(mock_ios)

        async def ios_answers_both():
            # Answer first question
            await asyncio.sleep(0.05)
            first_call = mock_ios.send.call_args[0][0]
            data1 = json.loads(first_call)
            assert data1["question_index"] == 0
            assert data1["total_questions"] == 2
            self.permission_handler.resolve_request(data1["request_id"], {
                "answer": "PostgreSQL"
            })
            # Wait for question_resolved broadcast + second question broadcast
            await asyncio.sleep(0.2)
            second_call = mock_ios.send.call_args[0][0]
            data2 = json.loads(second_call)
            assert data2["question_index"] == 1
            assert data2["total_questions"] == 2
            self.permission_handler.resolve_request(data2["request_id"], {
                "answer": "Yes"
            })

        asyncio.create_task(ios_answers_both())

        resp = await self.client.post("/question", json={
            "tool_name": "AskUserQuestion",
            "tool_input": {
                "questions": [
                    {
                        "question": "Which database?",
                        "header": "DB",
                        "options": [{"label": "PostgreSQL", "description": ""}],
                        "multiSelect": False
                    },
                    {
                        "question": "Enable caching?",
                        "header": "Cache",
                        "options": [{"label": "Yes", "description": ""}, {"label": "No", "description": ""}],
                        "multiSelect": False
                    }
                ]
            }
        })

        assert resp.status == 200
        result = await resp.json()
        reason = result["hookSpecificOutput"]["permissionDecisionReason"]
        assert "PostgreSQL" in reason
        assert "Yes" in reason
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_permission_integration.py -v -k "question_endpoint" 2>&1 | tail -20`
Expected: FAIL — `/question` endpoint doesn't exist yet

**Step 3: Implement `/question` endpoint in `http_server.py`**

Add the `handle_question` function inside `create_http_app()`, after `handle_permission_resolved`:

```python
    async def handle_question(request: web.Request) -> web.Response:
        """Handle POST /question from PreToolUse hook for AskUserQuestion.

        Receives question data, broadcasts each question to iOS one at a time,
        collects answers, returns deny decision with answers for Claude.
        """
        try:
            payload = await request.json()
        except json.JSONDecodeError:
            return web.json_response({"error": "Invalid JSON"}, status=400)

        timeout = float(request.query.get("timeout", "180"))

        tool_input = payload.get("tool_input", {})
        questions = tool_input.get("questions", [])

        if not questions:
            return web.json_response({"fallback": True})

        total = len(questions)
        answers = {}

        for idx, q in enumerate(questions):
            request_id = permission_handler.generate_request_id()
            permission_handler.register_request(request_id)

            options = q.get("options", [])

            ios_message = {
                "type": "question_prompt",
                "request_id": request_id,
                "header": q.get("header", ""),
                "question": q.get("question", ""),
                "options": options if options else [],
                "multi_select": q.get("multiSelect", False),
                "question_index": idx,
                "total_questions": total,
            }

            print(f"[QUESTION] Broadcasting question {idx+1}/{total}: {q.get('question', '')[:60]}")
            await permission_handler.broadcast(ios_message)

            try:
                response = await permission_handler.wait_for_response(request_id, timeout=timeout)
            except asyncio.CancelledError:
                print(f"[QUESTION] Connection dropped for {request_id}")
                permission_handler.cleanup_request(request_id)
                raise

            if response is None:
                print(f"[QUESTION] Timeout for question {idx+1}")
                return web.json_response({"fallback": True})

            permission_handler.cleanup_request(request_id)

            if response.get("dismissed"):
                print(f"[QUESTION] User dismissed question {idx+1}")
                # Broadcast resolved so iOS clears the prompt
                await permission_handler.broadcast({
                    "type": "question_resolved",
                    "request_id": request_id,
                })
                return web.json_response({
                    "hookSpecificOutput": {
                        "hookEventName": "PreToolUse",
                        "permissionDecision": "deny",
                        "permissionDecisionReason": "The user dismissed this question from the iOS app. Do not ask again — proceed with your best judgment or ask a different question."
                    }
                })

            answer = response.get("answer", "")
            question_text = q.get("question", "")
            answers[question_text] = answer
            print(f"[QUESTION] Got answer for question {idx+1}: {answer[:60]}")

            # Broadcast resolved so iOS clears the prompt before next question
            await permission_handler.broadcast({
                "type": "question_resolved",
                "request_id": request_id,
            })

        # Build the deny reason with all answers
        answer_lines = []
        for q_text, a_text in answers.items():
            answer_lines.append(f'Q: "{q_text}"\nA: "{a_text}"')
        answers_block = "\n\n".join(answer_lines)

        hook_response = {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": f"The user already answered via the iOS app.\n\n{answers_block}\n\nProceed with these answers. Do not ask again."
            }
        }

        print(f"[QUESTION] Returning hook response with {len(answers)} answer(s)")
        return web.json_response(hook_response)
```

Register the route — add after the `/permission_resolved` route:

```python
    app.router.add_post("/question", handle_question)
```

**Step 4: Create `voice_server/hooks/question_hook.sh`**

```bash
#!/bin/bash
# Claude Code PreToolUse hook for AskUserQuestion
# Intercepts questions and forwards to iOS voice server for remote answering
#
# Reads JSON from stdin, POSTs to server, outputs PreToolUse decision JSON
# Exit 0 on success with decision, exit 2 to fall back to terminal
#
# NOTE: The settings.json matcher is "AskUserQuestion" so this hook
# only fires for that tool. No need to check tool_name here.

SERVER_URL="${VOICE_SERVER_URL:-http://127.0.0.1:8766}"

# Save stdin to a temp file to avoid shell variable expansion mangling
# JSON with special characters ($, backticks, quotes, backslashes)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
cat > "$TMPFILE"

# POST to question endpoint with 3 minute timeout
# Use 127.0.0.1 to avoid DNS resolution delays
# If server is down, curl fails fast and we fall back to terminal
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  --data-binary @"$TMPFILE" \
  --connect-timeout 3 \
  --max-time 185 \
  "${SERVER_URL}/question" 2>/dev/null) || {
    # Server not running or network error - fall back to terminal
    exit 2
}

# Check if response has fallback=true (timeout occurred)
if echo "$RESPONSE" | grep -q '"fallback".*:.*true'; then
    exit 2
fi

# Output the decision JSON for Claude Code
echo "$RESPONSE"
exit 0
```

**Step 5: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_permission_integration.py -v -k "question_endpoint" 2>&1 | tail -30`
Expected: All 5 new tests PASS

**Step 6: Verify hook script works end-to-end**

```bash
chmod +x voice_server/hooks/question_hook.sh
```

Temporarily add the PreToolUse hook to `~/.claude/settings.json`, start a Claude session that triggers AskUserQuestion, verify the server receives the POST (check server stdout for `[QUESTION]` log lines). Then remove the temporary hook config (it will be permanently installed in Task 6).

**CHECKPOINT:** Server tests pass AND hook script receives question data when Claude calls AskUserQuestion.

**Step 7: Commit**

```bash
git add voice_server/hooks/question_hook.sh voice_server/http_server.py voice_server/tests/test_permission_integration.py
git commit -m "feat: add /question endpoint and PreToolUse hook for AskUserQuestion"
```

---

### Task 2: iOS — QuestionPrompt model and WebSocket handling

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/InputBarMode.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

**Step 1: Add QuestionPrompt model**

Add to `PermissionRequest.swift` (after `PermissionResolved` struct, before the closing of the file):

```swift
struct QuestionOption: Codable, Equatable {
    let label: String
    let description: String
}

struct QuestionPrompt: Codable, Identifiable, Equatable {
    let type: String
    let requestId: String
    let header: String
    let question: String
    let options: [QuestionOption]
    let multiSelect: Bool
    let questionIndex: Int
    let totalQuestions: Int

    var id: String { requestId }

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case header
        case question
        case options
        case multiSelect = "multi_select"
        case questionIndex = "question_index"
        case totalQuestions = "total_questions"
    }
}

struct QuestionResolved: Codable {
    let type: String
    let requestId: String

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
    }
}
```

**Step 2: Add QuestionResponse message**

Add to `Message.swift`:

```swift
struct QuestionResponseMessage: Codable {
    let type: String
    let requestId: String
    let answer: String?
    let dismissed: Bool

    enum CodingKeys: String, CodingKey {
        case type
        case requestId = "request_id"
        case answer
        case dismissed
    }

    init(requestId: String, answer: String) {
        self.type = "question_response"
        self.requestId = requestId
        self.answer = answer
        self.dismissed = false
    }

    init(requestId: String, dismissed: Bool) {
        self.type = "question_response"
        self.requestId = requestId
        self.answer = nil
        self.dismissed = dismissed
    }
}
```

**Step 3: Update InputBarMode**

In `InputBarMode.swift`, change the `questionPrompt` case to use the new model:

```swift
enum InputBarMode: Equatable {
    case normal
    case permissionPrompt(PermissionRequest)
    case questionPrompt(QuestionPrompt)
    case syncing
    case disconnected

    var allowsTextInput: Bool {
        if case .normal = self { return true }
        return false
    }

    var allowsMicInput: Bool {
        if case .normal = self { return true }
        return false
    }

    var showsPrompt: Bool {
        switch self {
        case .permissionPrompt, .questionPrompt:
            return true
        default:
            return false
        }
    }
}
```

**Step 4: Add WebSocket handling in WebSocketManager**

Find the message decoding section in `WebSocketManager.swift`. The existing code tries to decode various message types. Add decoding for `QuestionPrompt` and `QuestionResolved`.

Find the block that decodes `PermissionRequest` (around line 559) and add **before** it (since `PermissionRequest` decoding is greedy — it would match question_prompt JSON too due to optional fields):

```swift
            } else if let questionPrompt = try? JSONDecoder().decode(QuestionPrompt.self, from: data),
                      questionPrompt.type == "question_prompt" {
                logToFile("✅ Decoded as QuestionPrompt: \(questionPrompt.requestId)")
                DispatchQueue.main.async {
                    self.inputBarMode = .questionPrompt(questionPrompt)
                }
            } else if let questionResolved = try? JSONDecoder().decode(QuestionResolved.self, from: data),
                      questionResolved.type == "question_resolved" {
                logToFile("✅ Decoded as QuestionResolved: \(questionResolved.requestId)")
                DispatchQueue.main.async {
                    if case .questionPrompt(let current) = self.inputBarMode,
                       current.requestId == questionResolved.requestId {
                        self.inputBarMode = .normal
                    }
                }
```

Do the same for the second decoding block (around line 676, the `handleParsedMessage` or resync path).

Add a `sendQuestionResponse` method near `sendPermissionResponse`:

```swift
    func sendQuestionResponse(_ message: QuestionResponseMessage) {
        guard let data = try? JSONEncoder().encode(message),
              let jsonString = String(data: data, encoding: .utf8) else {
            print("❌ Failed to encode question response")
            return
        }
        sendMessage(jsonString)
        logToFile("📤 Sent question_response: \(message.requestId)")
    }
```

**Step 5: Build iOS app to verify compilation**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 6: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Models/InputBarMode.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: add QuestionPrompt model and WebSocket handling for question prompts"
```

---

### Task 3: iOS — Question prompt input bar UI

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionCardView.swift`

**Step 1: Create QuestionCardView in SessionView**

In `SessionView.swift`, find the `case .questionPrompt` in the input bar switch (around line 160). Replace the existing `PermissionCardView` usage with a new inline view:

```swift
                    case .questionPrompt(let prompt):
                        QuestionCardView(
                            prompt: prompt,
                            onAnswer: { answer in
                                webSocketManager.sendQuestionResponse(
                                    QuestionResponseMessage(requestId: prompt.requestId, answer: answer)
                                )
                                webSocketManager.inputBarMode = .normal
                            },
                            onDismiss: {
                                webSocketManager.sendQuestionResponse(
                                    QuestionResponseMessage(requestId: prompt.requestId, dismissed: true)
                                )
                                webSocketManager.inputBarMode = .normal
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
```

**Step 2: Create QuestionCardView**

Add a new `QuestionCardView` struct. This can go in `PermissionCardView.swift` (since it's related) or a new file. Add it at the bottom of `PermissionCardView.swift`:

```swift
struct QuestionCardView: View {
    let prompt: QuestionPrompt
    let onAnswer: (String) -> Void
    let onDismiss: () -> Void

    @State private var textInput: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header row with dismiss button
            HStack {
                if !prompt.header.isEmpty {
                    Text(prompt.header)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                }
                if prompt.totalQuestions > 1 {
                    Text("(\(prompt.questionIndex + 1)/\(prompt.totalQuestions))")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .accessibilityIdentifier("questionDismiss")
            }

            // Question text
            Text(prompt.question)
                .font(.subheadline)
                .fontWeight(.medium)

            // Options or text input
            if !prompt.options.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                        Button(action: { onAnswer(option.label) }) {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1).")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                                    .frame(width: 22, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(option.label)
                                        .font(.subheadline)
                                        .fontWeight(.medium)
                                        .foregroundColor(.primary)
                                        .multilineTextAlignment(.leading)
                                    if !option.description.isEmpty {
                                        Text(option.description)
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                            .multilineTextAlignment(.leading)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .padding(.horizontal, 10)
                            .background(Color(.systemGray5))
                            .cornerRadius(8)
                        }
                        .accessibilityIdentifier("questionOption\(index + 1)")
                    }
                }
            } else {
                HStack {
                    TextField("Type your answer...", text: $textInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .accessibilityIdentifier("questionTextInput")
                    Button("Send") {
                        onAnswer(textInput)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(textInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("questionSendButton")
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .accessibilityIdentifier("questionCard")
    }
}
```

**Step 3: Build iOS app**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 4: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionCardView.swift
git commit -m "feat: add QuestionCardView UI for question prompt input bar"
```

---

### Task 4: Server — Handle `question_response` from iOS

**Files:**
- Modify: `voice_server/ios_server.py`

**Step 1: Add question_response handler**

In `ios_server.py`, find the `handle_message` method (around line 1426). Add a new message type handler in the dispatch block (after `permission_response`):

```python
            elif msg_type == 'question_response':
                await self.handle_question_response(data)
```

Add the handler method near `handle_permission_response`:

```python
    async def handle_question_response(self, data):
        """Handle question response from iOS"""
        request_id = data.get('request_id', '')
        answer = data.get('answer', '')
        dismissed = data.get('dismissed', False)
        print(f"[QUESTION] Received question_response: id={request_id}, dismissed={dismissed}, answer={answer[:60] if answer else ''}")

        if self.permission_handler.is_request_pending(request_id):
            if dismissed:
                self.permission_handler.resolve_request(request_id, {"dismissed": True})
            else:
                self.permission_handler.resolve_request(request_id, {"answer": answer})
            print(f"[QUESTION] Resolved request {request_id}")
        else:
            print(f"[QUESTION] No pending request for {request_id}")
```

**Step 2: Store question_prompt messages for reconnect replay**

In `voice_server/permission_handler.py`, update the `broadcast` method to also store `question_prompt` messages (so iOS gets the pending question re-sent on reconnect):

Change the type check in `broadcast`:
```python
    async def broadcast(self, message: dict):
        """Broadcast a message to all connected WebSocket clients"""
        # Store pending request messages for re-send on reconnect
        if message.get("type") in ("permission_request", "question_prompt"):
            request_id = message.get("request_id", "")
            if request_id:
                self.pending_messages[request_id] = message
```

**Step 3: Build and verify**

Run: `cd voice_server/tests && python -m pytest test_permission_integration.py -v 2>&1 | tail -20`
Expected: All tests pass (existing + new)

**Step 4: Commit**

```bash
git add voice_server/ios_server.py voice_server/permission_handler.py
git commit -m "feat: handle question_response WebSocket messages from iOS"
```

---

### Task 5: Cleanup dead code and update settings

**Files:**
- Modify: `voice_server/http_server.py` (remove dead `question` field from `/permission`)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift` (remove `PermissionQuestion`)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionCardView.swift` (remove question branches)
- Modify: `voice_server/tests/test_permission_integration.py` (update old question tests)
- Modify: `CLAUDE.md` (document new hook)

**Step 1: Remove dead `question` field from `/permission` endpoint**

In `http_server.py`, in `handle_permission`, remove `"AskUserQuestion": "question"` from the `prompt_type_map` and remove `"question": payload.get("question"),` from `ios_message`. AskUserQuestion will no longer go through `/permission` — it goes through `/question` via PreToolUse.

**Step 2: Remove `PermissionQuestion` struct**

In `PermissionRequest.swift`, delete:
```swift
struct PermissionQuestion: Codable, Equatable {
    let text: String
    let options: [String]?
}
```

Remove the `question: PermissionQuestion?` field from `PermissionRequest` struct and its CodingKey.

Also remove `case question` from `PermissionPromptType` enum.

**Step 3: Clean up PermissionCardView**

In `PermissionCardView.swift`:
- Remove `case .question:` from `typeLabelText` and `typeLabelColor`
- Remove `case .question:` from `contentBlock`
- Remove the entire `questionOptions` computed property
- Remove the `@State private var questionTextInput` property
- Simplify `optionsBlock` to just show `permissionOptions` (remove the `if request.promptType == .question` branch)

**Step 4: Update old permission integration tests**

In `test_permission_integration.py`:
- Remove `test_question_with_text_input` and `test_question_with_option_selection` (these tested the old `/permission` endpoint with `question` field — that path no longer exists)

**Step 5: Update E2E test helpers**

In `E2ETestBase.swift`, remove `questionText` and `questionOptions` parameters from `injectPermissionRequest`.

In `E2EPermissionTests.swift`, remove `test_question_options_inline` and `test_question_text_input` tests (these tested the old PermissionRequest-based question flow). New E2E tests for the PreToolUse-based flow would use a new `injectQuestionPrompt` helper that POSTs to `/question` — but this can be added later when E2E tests are expanded.

**Step 6: Update CLAUDE.md**

Add the PreToolUse hook to the Permission Hooks Configuration section:

```json
"PreToolUse": [
  {
    "matcher": "AskUserQuestion",
    "hooks": [
      {
        "type": "command",
        "command": "/path/to/max/voice_server/hooks/question_hook.sh",
        "timeout": 185
      }
    ]
  }
]
```

**Step 7: Run all server tests**

Run: `cd voice_server/tests && ./run_tests.sh 2>&1 | tail -20`
Expected: All tests pass

**Step 8: Build iOS app**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

**Step 9: Commit**

```bash
git add voice_server/http_server.py \
        voice_server/tests/test_permission_integration.py \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Models/PermissionRequest.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoice/Views/PermissionCardView.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ETestBase.swift \
        ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EPermissionTests.swift \
        CLAUDE.md
git commit -m "refactor: remove dead PermissionRequest question code, document PreToolUse hook"
```

---

### Task 6: End-to-end verification

**Files:** None (manual verification only)

**Step 1: Install the PreToolUse hook**

Add to `~/.claude/settings.json` under `hooks`:

```json
"PreToolUse": [
  {
    "matcher": "AskUserQuestion",
    "hooks": [
      {
        "type": "command",
        "command": "/Users/aaron/Desktop/max/voice_server/hooks/question_hook.sh",
        "timeout": 185
      }
    ]
  }
]
```

**Step 2: Reinstall server**

```bash
pipx install --force /Users/aaron/Desktop/max
```

**Step 3: Start server**

```bash
claude-connect
```

**Step 4: Build and install iOS app on device**

```bash
cd ios-voice-app/ClaudeVoice
xcodebuild -target ClaudeVoice -sdk iphoneos build
xcrun devicectl list devices
xcrun devicectl device install app --device "<DEVICE_ID>" \
  ios-voice-app/ClaudeVoice/build/Release-iphoneos/ClaudeVoice.app
```

**Step 5: Test the flow**

1. Connect iOS app to server via QR code
2. Open a session
3. Send a prompt that triggers AskUserQuestion (e.g., "Ask me which approach I prefer for implementing feature X. Give me 3 options.")
4. Verify: iOS input bar shows the question with option buttons (label bold, description gray)
5. Tap an option
6. Verify: Input bar returns to normal, Claude proceeds with the selected answer

**Step 6: Test edge cases**

- Dismiss: Tap X button, verify Claude proceeds with best judgment
- Free text: Trigger a question with no options, verify text input appears
- Timeout: Disconnect iOS app while question is pending, verify Claude falls back to terminal UI

**CHECKPOINT:** Full flow works: Claude asks question → iOS shows options → user taps → Claude continues.
