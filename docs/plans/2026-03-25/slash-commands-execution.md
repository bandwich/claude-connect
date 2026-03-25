# Slash Commands Execution Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Make every slash command usable from the iOS app — capture terminal output, auto-dismiss overlays, show results as `command_response` cards, and filter XML noise from the transcript.

**Architecture:** New `CommandHandler` on the server intercepts `/`-prefixed input, sends it to tmux, polls the pane until output stabilizes, sends Escape to dismiss overlays, strips ANSI codes, and broadcasts a `command_response` message. `TranscriptHandler` filters out `<local-command-caveat>`, `<command-name>`, and `<local-command-stdout>` lines. iOS adds a `.commandResponse` conversation item rendered as a monospace card.

**Tech Stack:** Python (server handler + transcript filter), Swift/SwiftUI (iOS model + view)

**Risky Assumptions:** Pane capture polling reliably produces complete, readable output for all slash commands. Task 1 is a smoke test that verifies this before building everything else.

---

### Task 1: Smoke test pane capture for slash commands

**Files:**
- Create: `voice_server/tests/test_command_capture.py`

This task verifies the riskiest assumption: that we can send a slash command to tmux, poll until stable, capture the output, and get something clean and complete.

**Step 1: Write the smoke test**

Create `voice_server/tests/test_command_capture.py`:

```python
"""Smoke test: verify pane capture works for slash commands.

Requires a running Claude Code tmux session. Run manually:
    cd voice_server/tests && python -m pytest test_command_capture.py -v -s

Marked as integration so it's skipped in normal test runs.
"""
import asyncio
import re
import time

import pytest

from voice_server.infra.tmux_controller import TmuxController

ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]')


def strip_ansi(text: str) -> str:
    return ANSI_RE.sub('', text)


async def capture_stable_pane(tmux: TmuxController, session_name: str,
                               initial_delay: float = 0.3,
                               poll_interval: float = 0.2,
                               timeout: float = 3.0) -> str:
    """Poll pane until output stabilizes (2 identical captures)."""
    await asyncio.sleep(initial_delay)
    deadline = time.time() + timeout
    prev = None
    while time.time() < deadline:
        current = tmux.capture_pane(session_name, include_history=False)
        if current is not None and current == prev:
            return current
        prev = current
        await asyncio.sleep(poll_interval)
    return prev or ""


@pytest.mark.integration
class TestCommandCapture:
    """Manual integration tests — require a claude-connect tmux session."""

    @pytest.fixture
    def tmux(self):
        return TmuxController()

    @pytest.fixture
    def session_name(self, tmux):
        """Find a running claude-connect session."""
        sessions = tmux.list_sessions()
        if not sessions:
            pytest.skip("No claude-connect tmux session running")
        return sessions[0]

    @pytest.mark.asyncio
    async def test_capture_help(self, tmux, session_name):
        """Send /help to a live session and capture the overlay."""
        tmux.send_input(session_name, "/help")
        output = await capture_stable_pane(tmux, session_name)
        tmux.send_escape(session_name)

        cleaned = strip_ansi(output)
        print("--- Captured /help output ---")
        print(cleaned[:2000])
        print(f"--- Total length: {len(cleaned)} ---")

        # /help should produce some recognizable content
        assert len(cleaned) > 50, f"Captured output too short: {len(cleaned)} chars"

    @pytest.mark.asyncio
    async def test_capture_context(self, tmux, session_name):
        """Send /context (Category 1 — writes to transcript) and capture."""
        tmux.send_input(session_name, "/context")
        output = await capture_stable_pane(tmux, session_name)

        cleaned = strip_ansi(output)
        print("--- Captured /context output ---")
        print(cleaned[:2000])
        print(f"--- Total length: {len(cleaned)} ---")

        assert len(cleaned) > 20, f"Captured output too short: {len(cleaned)} chars"
```

**Step 2: Run the smoke test against a live session**

This requires a claude-connect tmux session to be running. Start the server first if needed.

Run: `cd voice_server/tests && python -m pytest test_command_capture.py -v -s -m integration`

Expected: Both tests PASS, captured output is readable text (not garbled).

**CHECKPOINT:** If the captured output is empty, garbled, or incomplete, the pane capture approach won't work. Debug or rethink before proceeding.

**Step 3: Commit**

```bash
cd /Users/aaron/Desktop/max && git add voice_server/tests/test_command_capture.py && git commit -m "test: add smoke test for slash command pane capture"
```

---

### Task 2: CommandHandler with pane capture + ANSI stripping

**Files:**
- Create: `voice_server/handlers/command_handler.py`
- Create: `voice_server/tests/test_command_handler.py`

**Step 1: Write the failing tests**

Create `voice_server/tests/test_command_handler.py`:

```python
import pytest
import json
import asyncio
from unittest.mock import Mock, AsyncMock, patch


class TestCommandHandler:

    @pytest.mark.asyncio
    async def test_execute_sends_command_to_tmux(self):
        """Should send the slash command text to tmux."""
        from voice_server.handlers.command_handler import CommandHandler

        server = Mock()
        server._active_tmux_session = "claude-connect_abc123"
        server.send_to_terminal = AsyncMock()
        server.active_session_id = "abc123"
        server.clients = set()

        # Mock capture_pane to return stable output immediately
        server.tmux = Mock()
        server.tmux.capture_pane = Mock(return_value="❯ /help\nAvailable commands:\n  /compact\n  /clear\n❯")
        server.tmux.send_escape = Mock(return_value=True)

        handler = CommandHandler(server)
        await handler.execute("/help")

        server.send_to_terminal.assert_called_once_with("/help")

    @pytest.mark.asyncio
    async def test_execute_captures_pane_and_broadcasts(self):
        """Should capture pane output and broadcast command_response."""
        from voice_server.handlers.command_handler import CommandHandler

        server = Mock()
        server._active_tmux_session = "claude-connect_abc123"
        server.send_to_terminal = AsyncMock()
        server.active_session_id = "abc123"
        server.broadcast_message = AsyncMock()

        # Return same output twice (stable)
        server.tmux = Mock()
        server.tmux.capture_pane = Mock(return_value="❯ /help\nAvailable commands:\n  /compact\n  /clear\n❯")
        server.tmux.send_escape = Mock(return_value=True)
        server.clients = set()

        handler = CommandHandler(server)
        await handler.execute("/help")

        server.broadcast_message.assert_called_once()
        msg = server.broadcast_message.call_args[0][0]
        assert msg["type"] == "command_response"
        assert msg["command"] == "/help"
        assert "session_id" in msg
        assert len(msg["output"]) > 0

    @pytest.mark.asyncio
    async def test_execute_sends_escape_after_capture(self):
        """Should send Escape to dismiss overlay after capturing."""
        from voice_server.handlers.command_handler import CommandHandler

        server = Mock()
        server._active_tmux_session = "claude-connect_abc123"
        server.send_to_terminal = AsyncMock()
        server.active_session_id = "abc123"
        server.broadcast_message = AsyncMock()
        server.clients = set()

        server.tmux = Mock()
        server.tmux.capture_pane = Mock(return_value="some output\n❯")
        server.tmux.send_escape = Mock(return_value=True)

        handler = CommandHandler(server)
        await handler.execute("/status")

        server.tmux.send_escape.assert_called_once_with("claude-connect_abc123")

    @pytest.mark.asyncio
    async def test_strips_ansi_codes(self):
        """Should strip ANSI escape codes from captured output."""
        from voice_server.handlers.command_handler import CommandHandler

        server = Mock()
        server._active_tmux_session = "claude-connect_abc123"
        server.send_to_terminal = AsyncMock()
        server.active_session_id = "abc123"
        server.broadcast_message = AsyncMock()
        server.clients = set()

        ansi_output = "❯ /context\n\x1b[32m████████\x1b[0m Context: 45%\n❯"
        server.tmux = Mock()
        server.tmux.capture_pane = Mock(return_value=ansi_output)
        server.tmux.send_escape = Mock(return_value=True)

        handler = CommandHandler(server)
        await handler.execute("/context")

        msg = server.broadcast_message.call_args[0][0]
        assert "\x1b[" not in msg["output"]
        assert "Context: 45%" in msg["output"]

    @pytest.mark.asyncio
    async def test_empty_output_fallback(self):
        """Should send 'Command executed' if pane output is empty after trimming."""
        from voice_server.handlers.command_handler import CommandHandler

        server = Mock()
        server._active_tmux_session = "claude-connect_abc123"
        server.send_to_terminal = AsyncMock()
        server.active_session_id = "abc123"
        server.broadcast_message = AsyncMock()
        server.clients = set()

        server.tmux = Mock()
        server.tmux.capture_pane = Mock(return_value="❯ /somecommand\n❯")
        server.tmux.send_escape = Mock(return_value=True)

        handler = CommandHandler(server)
        await handler.execute("/somecommand")

        msg = server.broadcast_message.call_args[0][0]
        assert msg["output"] == "Command executed"

    @pytest.mark.asyncio
    async def test_no_tmux_session_does_nothing(self):
        """Should return early if no active tmux session."""
        from voice_server.handlers.command_handler import CommandHandler

        server = Mock()
        server._active_tmux_session = None
        server.send_to_terminal = AsyncMock()
        server.broadcast_message = AsyncMock()

        handler = CommandHandler(server)
        await handler.execute("/help")

        server.send_to_terminal.assert_not_called()
        server.broadcast_message.assert_not_called()
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_command_handler.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'voice_server.handlers.command_handler'`

**Step 3: Write the implementation**

Create `voice_server/handlers/command_handler.py`:

```python
"""Command Handler - executes slash commands via tmux pane capture."""

import asyncio
import re
import time
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from voice_server.server import VoiceServer

ANSI_RE = re.compile(r'\x1b\[[0-9;]*[a-zA-Z]')


def strip_ansi(text: str) -> str:
    """Remove ANSI escape codes from text."""
    return ANSI_RE.sub('', text)


class CommandHandler:
    """Executes slash commands by sending to tmux, capturing pane output, and broadcasting."""

    INITIAL_DELAY = 0.3
    POLL_INTERVAL = 0.2
    MAX_TIMEOUT = 3.0

    def __init__(self, server: "VoiceServer"):
        self.server = server

    async def execute(self, command_text: str) -> None:
        """Send a slash command to tmux, capture output, broadcast to iOS."""
        if not self.server._active_tmux_session:
            return

        session_name = self.server._active_tmux_session

        # Send the command to tmux
        await self.server.send_to_terminal(command_text)

        # Wait for terminal to process
        await asyncio.sleep(self.INITIAL_DELAY)

        # Poll until pane output stabilizes
        output = await self._capture_stable_pane(session_name)

        # Dismiss any overlay
        self.server.tmux.send_escape(session_name)

        # Process output
        cleaned = strip_ansi(output)
        trimmed = self._trim_output(cleaned, command_text)

        if not trimmed.strip():
            trimmed = "Command executed"

        # Broadcast to iOS
        await self.server.broadcast_message({
            "type": "command_response",
            "command": command_text,
            "output": trimmed,
            "session_id": getattr(self.server, 'active_session_id', ''),
        })

    async def _capture_stable_pane(self, session_name: str) -> str:
        """Poll pane until output stabilizes (2 identical captures in a row)."""
        deadline = time.time() + self.MAX_TIMEOUT
        prev = None
        while time.time() < deadline:
            current = self.server.tmux.capture_pane(session_name, include_history=False)
            if current is not None and current == prev:
                return current
            prev = current
            await asyncio.sleep(self.POLL_INTERVAL)
        return prev or ""

    def _trim_output(self, text: str, command_text: str) -> str:
        """Remove command echo line and trailing prompt from captured output."""
        lines = text.splitlines()
        if not lines:
            return ""

        # Remove leading empty lines
        while lines and not lines[0].strip():
            lines.pop(0)

        # Remove command echo (first line containing the command text)
        if lines and command_text.lstrip('/') in lines[0]:
            lines.pop(0)
        elif lines and lines[0].strip().startswith('❯'):
            lines.pop(0)

        # Remove trailing prompt lines
        while lines and (lines[-1].strip().startswith('❯') or not lines[-1].strip()):
            lines.pop()

        return '\n'.join(lines)
```

**Step 4: Run tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_command_handler.py -v`
Expected: All 6 tests PASS

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max && git add voice_server/handlers/command_handler.py voice_server/tests/test_command_handler.py && git commit -m "feat: add CommandHandler for slash command pane capture and broadcast"
```

---

### Task 3: Wire CommandHandler into InputHandler + transcript filtering

**Files:**
- Modify: `voice_server/handlers/input_handler.py`
- Modify: `voice_server/services/transcript_watcher.py`
- Create: `voice_server/tests/test_transcript_filter.py`

**Step 1: Write the transcript filter tests**

Create `voice_server/tests/test_transcript_filter.py`:

```python
import pytest
import json
import os
import tempfile
import time
import threading

from voice_server.services.transcript_watcher import TranscriptHandler


class TestTranscriptCommandFilter:
    """Tests that slash command XML noise is filtered from transcript output."""

    def _make_handler(self):
        handler = TranscriptHandler(
            content_callback=None,
            audio_callback=None,
            loop=None,
            server=type('FakeServer', (), {'active_session_id': 'test', 'current_branch': ''})(),
            user_callback=None,
        )
        return handler

    def test_filters_local_command_caveat(self):
        """Lines with <local-command-caveat> should be skipped."""
        handler = self._make_handler()

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            entry = {
                "message": {
                    "role": "user",
                    "content": '<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>'
                }
            }
            f.write(json.dumps(entry) + '\n')
            f.flush()

            handler.expected_session_file = f.name
            blocks, user_texts, task_ids = handler.extract_new_content(f.name)

        os.unlink(f.name)
        assert user_texts == []

    def test_filters_command_name(self):
        """Lines with <command-name> should be skipped."""
        handler = self._make_handler()

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            entry = {
                "message": {
                    "role": "user",
                    "content": '<command-name>/effort</command-name>\n<command-message>effort</command-message>'
                }
            }
            f.write(json.dumps(entry) + '\n')
            f.flush()

            blocks, user_texts, task_ids = handler.extract_new_content(f.name)

        os.unlink(f.name)
        assert user_texts == []

    def test_filters_local_command_stdout(self):
        """Lines with <local-command-stdout> should be skipped."""
        handler = self._make_handler()

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            entry = {
                "message": {
                    "role": "user",
                    "content": '<local-command-stdout>Effort level: auto (currently medium)</local-command-stdout>'
                }
            }
            f.write(json.dumps(entry) + '\n')
            f.flush()

            blocks, user_texts, task_ids = handler.extract_new_content(f.name)

        os.unlink(f.name)
        assert user_texts == []

    def test_passes_normal_user_message(self):
        """Normal user messages should NOT be filtered."""
        handler = self._make_handler()

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            entry = {
                "message": {
                    "role": "user",
                    "content": "fix the bug in server.py"
                }
            }
            f.write(json.dumps(entry) + '\n')
            f.flush()

            blocks, user_texts, task_ids = handler.extract_new_content(f.name)

        os.unlink(f.name)
        assert len(user_texts) == 1
        assert user_texts[0][0] == "fix the bug in server.py"

    def test_passes_compact_summary(self):
        """/compact summary (plain text, no XML tags) should NOT be filtered."""
        handler = self._make_handler()

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            entry = {
                "message": {
                    "role": "user",
                    "content": "This session is being continued from a previous conversation..."
                }
            }
            f.write(json.dumps(entry) + '\n')
            f.flush()

            blocks, user_texts, task_ids = handler.extract_new_content(f.name)

        os.unlink(f.name)
        assert len(user_texts) == 1

    def test_filters_content_list_with_command_caveat(self):
        """Content as list with <local-command-caveat> in text block should be filtered."""
        handler = self._make_handler()

        with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
            entry = {
                "message": {
                    "role": "user",
                    "content": [
                        {"type": "text", "text": "<local-command-caveat>Caveat: ...</local-command-caveat>"}
                    ]
                }
            }
            f.write(json.dumps(entry) + '\n')
            f.flush()

            blocks, user_texts, task_ids = handler.extract_new_content(f.name)

        os.unlink(f.name)
        assert user_texts == []
```

**Step 2: Run tests to verify they fail**

Run: `cd voice_server/tests && python -m pytest test_transcript_filter.py -v`
Expected: Some tests FAIL — the caveat/command-name/stdout lines are currently passed through as user messages.

**Step 3: Add the filter to TranscriptHandler**

Modify `voice_server/services/transcript_watcher.py`. Add this helper method to the `TranscriptHandler` class (after `__init__`, around line 84):

```python
    @staticmethod
    def _is_command_noise(text: str) -> bool:
        """Check if user message text is slash command XML noise."""
        return ('<local-command-caveat>' in text or
                '<command-name>' in text or
                '<local-command-stdout>' in text)
```

Then add the filter check in `extract_new_content`. There are two places where user text is appended:

1. **String content** (around line 279-288): Before the `else` clause that appends to `user_texts`, add the filter. Change:
```python
                    elif isinstance(content, str) and content.strip():
                        stripped = content.strip()
                        if stripped.startswith('Base directory for this skill:'):
                            pass
                        elif stripped.startswith('<task-notification'):
                            match = re.search(r'<tool-use-id>([^<]+)</tool-use-id>', stripped)
                            if match:
                                task_completed_ids.append(match.group(1))
                        else:
                            user_texts.append((rewrite_user_text(stripped), line_num))
```
to:
```python
                    elif isinstance(content, str) and content.strip():
                        stripped = content.strip()
                        if stripped.startswith('Base directory for this skill:'):
                            pass
                        elif stripped.startswith('<task-notification'):
                            match = re.search(r'<tool-use-id>([^<]+)</tool-use-id>', stripped)
                            if match:
                                task_completed_ids.append(match.group(1))
                        elif self._is_command_noise(stripped):
                            pass
                        else:
                            user_texts.append((rewrite_user_text(stripped), line_num))
```

2. **List content without tool_result** (around line 264-278): In the loop that processes text blocks, add the filter before appending. Change the block at line ~278:
```python
                                        user_texts.append((rewrite_user_text(text), line_num))
```
to:
```python
                                        if not self._is_command_noise(text):
                                            user_texts.append((rewrite_user_text(text), line_num))
```

**Step 4: Run filter tests to verify they pass**

Run: `cd voice_server/tests && python -m pytest test_transcript_filter.py -v`
Expected: All 6 tests PASS

**Step 5: Wire CommandHandler into InputHandler**

Modify `voice_server/handlers/input_handler.py`. Add import at top:

```python
from voice_server.handlers.command_handler import CommandHandler
```

Add `command_handler` initialization in `__init__`:

```python
    def __init__(self, server: "VoiceServer"):
        self.server = server
        self.command_handler = CommandHandler(server)
```

Modify `handle_voice_input` (line 22-58). Add slash command detection after the `if text:` check. Replace lines 27-57 with:

```python
            # Slash commands get routed to CommandHandler
            if text.startswith('/'):
                print(f"[{time.strftime('%H:%M:%S')}] Slash command detected, routing to CommandHandler")
                for client in list(self.server.clients):
                    try:
                        await self.server.send_status(client, "processing", "Sending to Claude...")
                    except Exception:
                        pass
                await self.command_handler.execute(text)
                return

            self.server.waiting_for_response = True
            self.server.last_voice_input = text
            ctx = self.server._get_viewed_context()
            if ctx:
                ctx.waiting_for_response = True
                ctx.last_voice_input = text

            print(f"[{time.strftime('%H:%M:%S')}] Sending to terminal...")
            for client in list(self.server.clients):
                try:
                    await self.server.send_status(client, "processing", "Sending to Claude...")
                except Exception:
                    pass

            await self.server.send_to_terminal(text)
            print(f"[{time.strftime('%H:%M:%S')}] Sent to terminal successfully")

            delivered = await self.server.verify_delivery(text)
            delivery_msg = {
                "type": "delivery_status",
                "status": "confirmed" if delivered else "failed",
                "text": text
            }
            for client in list(self.server.clients):
                try:
                    await client.send(json.dumps(delivery_msg))
                except Exception:
                    pass

            if not delivered:
                print(f"[SYNC WARNING] Message delivery not confirmed: '{text[:50]}'")
```

Do the same for `handle_user_input` (line 61-100). Add slash command detection after the image handling, before the `self.server.waiting_for_response = True` line. Replace lines 85-100 with:

```python
        prompt = text
        for path in image_paths:
            prompt += f"\n[Image: {path}]"

        print(f"[{time.strftime('%H:%M:%S')}] User input: '{prompt[:100]}'")

        # Slash commands (without images) get routed to CommandHandler
        if text.startswith('/') and not image_paths:
            for client in list(self.server.clients):
                try:
                    await self.server.send_status(client, "processing", "Sending to Claude...")
                except Exception:
                    pass
            await self.command_handler.execute(text)
            return

        self.server.waiting_for_response = True
        self.server.last_voice_input = text

        for client in list(self.server.clients):
            try:
                await self.server.send_status(client, "processing", "Sending to Claude...")
            except Exception:
                pass

        await self.server.send_to_terminal(prompt)
```

**Step 6: Run full server test suite**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests PASS (no regressions)

**Step 7: Commit**

```bash
cd /Users/aaron/Desktop/max && git add voice_server/handlers/input_handler.py voice_server/handlers/command_handler.py voice_server/services/transcript_watcher.py voice_server/tests/test_transcript_filter.py && git commit -m "feat: wire CommandHandler into InputHandler and filter transcript XML noise"
```

---

### Task 4: iOS command_response message handling + ConversationItem

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift` (add `.commandResponse` case)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift` (decode `command_response`)
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/CommandResponseTests.swift`

**Step 1: Write the failing tests**

Create `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/CommandResponseTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeVoice

@Suite("CommandResponse Tests")
struct CommandResponseTests {

    @Test func decodesCommandResponse() throws {
        let json = """
        {
            "type": "command_response",
            "command": "/help",
            "output": "Available commands:\\n  /compact\\n  /clear",
            "session_id": "abc123"
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CommandResponseMessage.self, from: json)
        #expect(response.type == "command_response")
        #expect(response.command == "/help")
        #expect(response.output.contains("/compact"))
        #expect(response.sessionId == "abc123")
    }

    @Test func conversationItemCommandResponse() {
        let item = ConversationItem.commandResponse(command: "/help", output: "test output", timestamp: 1000.0)
        #expect(item.id == "cmd-/help-1000.0")
    }
}
```

**Step 2: Add CommandResponseMessage model**

Add to `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift` (near other message structs):

```swift
struct CommandResponseMessage: Codable {
    let type: String
    let command: String
    let output: String
    let sessionId: String?

    enum CodingKeys: String, CodingKey {
        case type, command, output
        case sessionId = "session_id"
    }
}
```

**Step 3: Add `.commandResponse` to ConversationItem**

Modify `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift`. Add the new case to the `ConversationItem` enum (after line 114):

```swift
    case commandResponse(command: String, output: String, timestamp: Double = Date().timeIntervalSince1970)
```

Add the `id` case in the `id` computed property (after the `.permissionPrompt` case, around line 125):

```swift
        case .commandResponse(let command, _, let timestamp):
            return "cmd-\(command)-\(timestamp)"
```

Note: The timestamp is captured at creation time (default parameter) and stays stable across accesses, ensuring SwiftUI's `Identifiable` contract is met while keeping IDs unique across multiple invocations of the same command.

**Step 4: Add command_response decoding to WebSocketManager**

Modify `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`. Add a new published callback (near other callbacks):

```swift
    var onCommandResponse: ((String, String) -> Void)?  // (command, output)
```

Add decoding in `handleMessage`, after the `commandsList` block (around line 646) and before the `permissionRequest` block:

```swift
            } else if let commandResponse = try? JSONDecoder().decode(CommandResponseMessage.self, from: data),
                      commandResponse.type == "command_response" {
                logToFile("✅ Decoded as CommandResponse: \(commandResponse.command)")
                DispatchQueue.main.async {
                    self.onCommandResponse?(commandResponse.command, commandResponse.output)
                }
```

**Step 5: Build to verify compilation**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -20`
Expected: Build may fail due to exhaustive switch — the new enum case needs handling in SessionView.

**Step 6: Add placeholder rendering in SessionView**

In `SessionView.swift`, find the `ForEach` that switches on conversation items (around line 49). Add a case for `.commandResponse`:

```swift
                                case .commandResponse(let command, let output):
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(command)
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .foregroundColor(.secondary)
                                        Text(output)
                                            .font(.system(size: 14, design: .monospaced))
                                            .foregroundColor(.primary)
                                            .textSelection(.enabled)
                                    }
                                    .padding(12)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color(.systemGray6))
                                    .cornerRadius(12)
                                    .padding(.horizontal, 12)
                                    .id(item.id)
```

Note: `groupAgentItems()` uses `if case .toolUse` pattern matching with an `else` branch that appends all other items unchanged — `.commandResponse` passes through automatically with no changes needed.

**Step 7: Wire the callback in SessionView**

In `SessionView.swift`, in the `onAppear` block where callbacks are set up (look for `webSocketManager.onAssistantResponse`), add:

```swift
                webSocketManager.onCommandResponse = { command, output in
                    items.append(.commandResponse(command: command, output: output))
                }
```

**Step 8: Skip user echo for slash commands in sendTextMessage**

In `SessionView.swift`, in `sendTextMessage()` (around line 1010), add early detection before the user message is appended to `items`. After `guard !text.isEmpty || !attachedImages.isEmpty else { return }`:

```swift
        // Slash commands: don't add user message bubble — command_response card handles display
        if text.hasPrefix("/") && attachedImages.isEmpty {
            webSocketManager.sendUserInput(text: text, images: [])
            messageText = ""
            selectedCommandPrefix = nil
            showCommandDropdown = false
            return
        }
```

**Step 9: Build and run iOS unit tests**

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

Run: `cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/CommandResponseTests 2>&1 | tail -20`
Expected: All 2 tests PASS

**Step 10: Commit**

```bash
cd /Users/aaron/Desktop/max && git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Message.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/CommandResponseTests.swift && git commit -m "feat: add command_response handling and rendering on iOS"
```

---

### Task 5: End-to-end verification and device deploy

**Files:**
- No new files

**Step 1: Reinstall server**

```bash
pipx install --force /Users/aaron/Desktop/max
```

**Step 2: Run full server test suite**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests PASS

**Step 3: Build and install on device**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild -target ClaudeVoice -sdk iphoneos build 2>&1 | tail -5
```

```bash
xcrun devicectl list devices
xcrun devicectl device install app --device "<DEVICE_ID>" ios-voice-app/ClaudeVoice/build/Release-iphoneos/ClaudeVoice.app
```

**Step 4: Manual verification**

Start the server (`claude-connect`), connect from iOS app, open a session, then verify:

1. Type `/help` → should see a monospace command output card (no user bubble), overlay auto-dismissed in terminal
2. Type `/effort` → should see command output card with effort level, NO raw XML in conversation
3. Type `/context` → should see context info card, no ANSI garbage
4. Type a normal message like "hello" → should work as before (user bubble + assistant response)
5. Say "/compact" via voice → should show command output card
6. Check terminal — no overlays stuck waiting for dismissal

**CHECKPOINT:** All 6 verification steps must pass. Debug any failures before considering this feature complete.

**Step 5: Commit any fixes needed**

```bash
cd /Users/aaron/Desktop/max && git add -A && git commit -m "fix: slash command execution adjustments from e2e testing"
```
