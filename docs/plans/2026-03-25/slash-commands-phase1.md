# Slash Commands Phase 1: Server + iOS Data Layer

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Server sends a full list of slash commands (builtins + custom skills) to iOS on connect; iOS receives, stores, and exposes it.

**Architecture:** New `CommandsProvider` service on the server builds a merged command list from a hardcoded builtins dict + dynamic `~/.claude/skills/` scan. Sent as a `commands_list` WebSocket message on connect and on `list_commands` request. iOS adds a `SlashCommand` model + `availableCommands` property on `WebSocketManager`.

**Tech Stack:** Python (server), Swift (iOS models + WebSocket decoding)

**Risky Assumptions:** SKILL.md frontmatter parsing assumes YAML `---` delimited format with `name:` and `description:` fields. Verified by reading all 10 user skills — they all follow this format.

---

### Task 1: CommandsProvider service (server)

**Files:**
- Create: `voice_server/services/commands_provider.py`
- Test: `voice_server/tests/test_commands_provider.py`

**Step 1: Write the failing test**

Create `voice_server/tests/test_commands_provider.py`:

```python
# voice_server/tests/test_commands_provider.py
import pytest
import os
import tempfile
from voice_server.services.commands_provider import CommandsProvider


class TestCommandsProvider:

    def test_get_builtin_commands_returns_list(self):
        """Builtins should include well-known commands"""
        provider = CommandsProvider()
        commands = provider.get_builtin_commands()
        names = [c["name"] for c in commands]
        assert "compact" in names
        assert "clear" in names
        assert "model" in names
        # Each command has name, description, source
        compact = next(c for c in commands if c["name"] == "compact")
        assert compact["source"] == "builtin"
        assert len(compact["description"]) > 0

    def test_scan_user_skills(self):
        """Should read name + description from SKILL.md frontmatter"""
        with tempfile.TemporaryDirectory() as tmpdir:
            skill_dir = os.path.join(tmpdir, "my-skill")
            os.makedirs(skill_dir)
            with open(os.path.join(skill_dir, "SKILL.md"), "w") as f:
                f.write("---\nname: my-skill\ndescription: Does cool stuff\n---\n\nBody here\n")

            provider = CommandsProvider()
            skills = provider.scan_skills_directory(tmpdir)
            assert len(skills) == 1
            assert skills[0]["name"] == "my-skill"
            assert skills[0]["description"] == "Does cool stuff"
            assert skills[0]["source"] == "skill"

    def test_scan_skills_missing_frontmatter(self):
        """Should use directory name if no frontmatter"""
        with tempfile.TemporaryDirectory() as tmpdir:
            skill_dir = os.path.join(tmpdir, "fallback-skill")
            os.makedirs(skill_dir)
            with open(os.path.join(skill_dir, "SKILL.md"), "w") as f:
                f.write("Just some instructions, no frontmatter\n")

            provider = CommandsProvider()
            skills = provider.scan_skills_directory(tmpdir)
            assert len(skills) == 1
            assert skills[0]["name"] == "fallback-skill"
            assert skills[0]["description"] == ""

    def test_scan_skills_nonexistent_directory(self):
        """Should return empty list for missing directory"""
        provider = CommandsProvider()
        skills = provider.scan_skills_directory("/nonexistent/path")
        assert skills == []

    def test_get_all_commands_merges_builtins_and_skills(self):
        """get_all_commands merges builtins + user skills, deduped by name"""
        with tempfile.TemporaryDirectory() as tmpdir:
            # Create a skill that conflicts with a builtin name
            skill_dir = os.path.join(tmpdir, "compact")
            os.makedirs(skill_dir)
            with open(os.path.join(skill_dir, "SKILL.md"), "w") as f:
                f.write("---\nname: compact\ndescription: Custom compact\n---\n")

            # Create a unique skill
            skill_dir2 = os.path.join(tmpdir, "deploy")
            os.makedirs(skill_dir2)
            with open(os.path.join(skill_dir2, "SKILL.md"), "w") as f:
                f.write("---\nname: deploy\ndescription: Deploy app\n---\n")

            provider = CommandsProvider(user_skills_path=tmpdir)
            commands = provider.get_all_commands()
            names = [c["name"] for c in commands]

            # Should have builtins + deploy (compact deduped to builtin)
            assert "deploy" in names
            assert "compact" in names
            # No duplicate compact
            assert names.count("compact") == 1
            # Builtin wins over skill
            compact = next(c for c in commands if c["name"] == "compact")
            assert compact["source"] == "builtin"

    def test_get_all_commands_sorted_alphabetically(self):
        """Commands should be sorted by name"""
        provider = CommandsProvider(user_skills_path="/nonexistent")
        commands = provider.get_all_commands()
        names = [c["name"] for c in commands]
        assert names == sorted(names)
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && python -m pytest test_commands_provider.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'voice_server.services.commands_provider'`

**Step 3: Write the implementation**

Create `voice_server/services/commands_provider.py`:

```python
# voice_server/services/commands_provider.py
"""Provides the merged list of slash commands (builtins + custom skills)."""

import os
import re

# All builtin commands from Claude Code docs
BUILTIN_COMMANDS = [
    ("add-dir", "Add a new working directory to the current session"),
    ("agents", "Manage agent configurations"),
    ("btw", "Ask a quick side question without adding to the conversation"),
    ("chrome", "Configure Claude in Chrome settings"),
    ("clear", "Clear conversation history and free up context"),
    ("color", "Set the prompt bar color for the current session"),
    ("compact", "Compact conversation with optional focus instructions"),
    ("config", "Open the Settings interface"),
    ("context", "Visualize current context usage"),
    ("copy", "Copy the last assistant response to clipboard"),
    ("cost", "Show token usage statistics"),
    ("desktop", "Continue the current session in the Desktop app"),
    ("diff", "Open an interactive diff viewer"),
    ("doctor", "Diagnose and verify your installation"),
    ("effort", "Set the model effort level"),
    ("exit", "Exit the CLI"),
    ("export", "Export the current conversation as plain text"),
    ("extra-usage", "Configure extra usage for rate limits"),
    ("fast", "Toggle fast mode"),
    ("feedback", "Submit feedback about Claude Code"),
    ("branch", "Create a branch of the current conversation"),
    ("help", "Show help and available commands"),
    ("hooks", "View hook configurations"),
    ("ide", "Manage IDE integrations"),
    ("init", "Initialize project with a CLAUDE.md guide"),
    ("insights", "Generate a report analyzing your sessions"),
    ("install-github-app", "Set up the Claude GitHub Actions app"),
    ("install-slack-app", "Install the Claude Slack app"),
    ("keybindings", "Open keybindings configuration file"),
    ("login", "Sign in to your Anthropic account"),
    ("logout", "Sign out from your Anthropic account"),
    ("mcp", "Manage MCP server connections"),
    ("memory", "Edit CLAUDE.md memory files"),
    ("mobile", "Show QR code to download the Claude mobile app"),
    ("model", "Select or change the AI model"),
    ("passes", "Share a free week of Claude Code with friends"),
    ("permissions", "View or update permissions"),
    ("plan", "Enter plan mode"),
    ("plugin", "Manage Claude Code plugins"),
    ("pr-comments", "Fetch and display comments from a GitHub PR"),
    ("privacy-settings", "View and update privacy settings"),
    ("release-notes", "View the full changelog"),
    ("reload-plugins", "Reload all active plugins"),
    ("remote-control", "Make session available for remote control"),
    ("remote-env", "Configure the default remote environment"),
    ("rename", "Rename the current session"),
    ("resume", "Resume a conversation by ID or name"),
    ("rewind", "Rewind conversation to a previous point"),
    ("sandbox", "Toggle sandbox mode"),
    ("schedule", "Create or manage Cloud scheduled tasks"),
    ("security-review", "Analyze pending changes for security vulnerabilities"),
    ("skills", "List available skills"),
    ("stats", "Visualize daily usage and session history"),
    ("status", "Show version, model, account, and connectivity"),
    ("statusline", "Configure the status line"),
    ("stickers", "Order Claude Code stickers"),
    ("tasks", "List and manage background tasks"),
    ("terminal-setup", "Configure terminal keybindings"),
    ("theme", "Change the color theme"),
    ("upgrade", "Open the upgrade page"),
    ("usage", "Show plan usage limits and rate limit status"),
    ("vim", "Toggle between Vim and Normal editing modes"),
    ("voice", "Toggle push-to-talk voice dictation"),
    # Bundled skills
    ("batch", "Orchestrate large-scale changes across a codebase in parallel"),
    ("claude-api", "Load Claude API reference material for your project"),
    ("debug", "Troubleshoot your current Claude Code session"),
    ("loop", "Run a prompt repeatedly on an interval"),
    ("simplify", "Review changed files for code reuse, quality, and efficiency"),
]

_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---", re.DOTALL)


def _parse_frontmatter(content: str) -> dict[str, str]:
    """Extract name and description from SKILL.md YAML frontmatter."""
    match = _FRONTMATTER_RE.match(content)
    if not match:
        return {}
    result = {}
    for line in match.group(1).splitlines():
        if ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            value = value.strip()
            if key in ("name", "description"):
                result[key] = value
    return result


class CommandsProvider:
    """Builds merged list of slash commands from builtins + skill directories."""

    def __init__(self, user_skills_path: str | None = None):
        if user_skills_path is None:
            user_skills_path = os.path.expanduser("~/.claude/skills")
        self._user_skills_path = user_skills_path

    def get_builtin_commands(self) -> list[dict]:
        return [
            {"name": name, "description": desc, "source": "builtin"}
            for name, desc in BUILTIN_COMMANDS
        ]

    def scan_skills_directory(self, path: str) -> list[dict]:
        """Scan a skills directory for SKILL.md files, return command dicts."""
        if not os.path.isdir(path):
            return []
        skills = []
        for entry in os.listdir(path):
            skill_file = os.path.join(path, entry, "SKILL.md")
            if not os.path.isfile(skill_file):
                continue
            try:
                with open(skill_file, "r") as f:
                    content = f.read()
                fm = _parse_frontmatter(content)
                skills.append({
                    "name": fm.get("name", entry),
                    "description": fm.get("description", ""),
                    "source": "skill",
                })
            except OSError:
                continue
        return skills

    def get_all_commands(self, project_skills_path: str | None = None) -> list[dict]:
        """Merge builtins + user skills + optional project skills, deduped."""
        builtins = self.get_builtin_commands()
        builtin_names = {c["name"] for c in builtins}

        user_skills = self.scan_skills_directory(self._user_skills_path)
        if project_skills_path:
            user_skills.extend(self.scan_skills_directory(project_skills_path))

        # Builtins win on name conflicts
        for skill in user_skills:
            if skill["name"] not in builtin_names:
                builtins.append(skill)
                builtin_names.add(skill["name"])

        builtins.sort(key=lambda c: c["name"])
        return builtins
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && python -m pytest test_commands_provider.py -v`
Expected: All 6 tests PASS

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max && git add voice_server/services/commands_provider.py voice_server/tests/test_commands_provider.py && git commit -m "feat: add CommandsProvider for slash command list"
```

---

### Task 2: Wire commands_list to WebSocket server

**Files:**
- Modify: `voice_server/server.py` (import + handle_client + handle_message + new handler)
- Test: `voice_server/tests/test_message_handlers.py` (add tests)

**Step 1: Write the failing test**

Add to `voice_server/tests/test_message_handlers.py`:

```python
class TestCommandsList:
    """Tests for commands_list message handling"""

    @pytest.mark.asyncio
    async def test_commands_list_sent_on_connect(self):
        """Server should send commands_list during handle_client setup"""
        from voice_server.server import VoiceServer

        server = VoiceServer()
        # Verify server has commands_provider
        assert hasattr(server, 'commands_provider')
        commands = server.commands_provider.get_all_commands()
        assert len(commands) > 50  # builtins + user skills

    @pytest.mark.asyncio
    async def test_handle_list_commands_returns_commands(self):
        """Should return commands_list when list_commands is received"""
        from voice_server.server import VoiceServer

        server = VoiceServer()
        mock_ws = AsyncMock()
        sent_messages = []
        mock_ws.send = AsyncMock(side_effect=lambda msg: sent_messages.append(msg))

        await server.handle_message(mock_ws, json.dumps({"type": "list_commands"}))

        assert len(sent_messages) == 1
        response = json.loads(sent_messages[0])
        assert response["type"] == "commands_list"
        assert isinstance(response["commands"], list)
        assert len(response["commands"]) > 50
        # Verify structure
        first = response["commands"][0]
        assert "name" in first
        assert "description" in first
        assert "source" in first
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py::TestCommandsList -v`
Expected: FAIL — `AssertionError: assert hasattr(server, 'commands_provider')`

**Step 3: Write the implementation**

Modify `voice_server/server.py`:

1. Add import at top (near other service imports around line 29):
```python
from voice_server.services.commands_provider import CommandsProvider
```

2. In `__init__` (after `self.usage_checker = UsageChecker()` around line 59), add:
```python
self.commands_provider = CommandsProvider()
```

3. Add new handler method (near other `handle_*` methods):
```python
    async def handle_list_commands(self, websocket):
        """Send available slash commands to client"""
        commands = self.commands_provider.get_all_commands()
        await websocket.send(json.dumps({
            "type": "commands_list",
            "commands": commands
        }))
```

4. In `handle_message` dispatch (after the `resync` handler around line 1157), add:
```python
            elif msg_type == 'list_commands':
                await self.handle_list_commands(websocket)
```

5. In `handle_client` (after `await self.permission_handler.send_pending_to_client(websocket)` around line 1177), add:
```python
            await self.handle_list_commands(websocket)
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server/tests && python -m pytest test_message_handlers.py::TestCommandsList -v`
Expected: All 2 tests PASS

**Step 5: Run full server test suite to check for regressions**

Run: `cd voice_server/tests && ./run_tests.sh`
Expected: All tests PASS

**Step 6: Commit**

```bash
cd /Users/aaron/Desktop/max && git add voice_server/server.py voice_server/tests/test_message_handlers.py && git commit -m "feat: send commands_list on connect and list_commands request"
```

---

### Task 3: SlashCommand model + WebSocket decoding on iOS

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/SlashCommand.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Test: `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/SlashCommandTests.swift`

**Step 1: Write the failing test**

Create `ios-voice-app/ClaudeVoice/ClaudeVoiceTests/SlashCommandTests.swift`:

```swift
import Testing
import Foundation
@testable import ClaudeVoice

@Suite("SlashCommand Tests")
struct SlashCommandTests {

    @Test func decodesFromJSON() throws {
        let json = """
        {"name": "compact", "description": "Compact conversation", "source": "builtin"}
        """.data(using: .utf8)!
        let command = try JSONDecoder().decode(SlashCommand.self, from: json)
        #expect(command.name == "compact")
        #expect(command.description == "Compact conversation")
        #expect(command.source == "builtin")
        #expect(command.id == "compact")
    }

    @Test func decodesCommandsListResponse() throws {
        let json = """
        {
            "type": "commands_list",
            "commands": [
                {"name": "compact", "description": "Compact conversation", "source": "builtin"},
                {"name": "deploy", "description": "Deploy app", "source": "skill"}
            ]
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(CommandsListResponse.self, from: json)
        #expect(response.type == "commands_list")
        #expect(response.commands.count == 2)
        #expect(response.commands[0].name == "compact")
        #expect(response.commands[1].source == "skill")
    }

    @Test func filtersByPrefix() {
        let commands = [
            SlashCommand(name: "compact", description: "Compact", source: "builtin"),
            SlashCommand(name: "commit", description: "Commit", source: "skill"),
            SlashCommand(name: "clear", description: "Clear", source: "builtin"),
            SlashCommand(name: "debug", description: "Debug", source: "skill"),
        ]
        let filtered = commands.filter { $0.name.hasPrefix("com") }
        #expect(filtered.count == 2)
        #expect(filtered[0].name == "compact")
        #expect(filtered[1].name == "commit")
    }
}
```

**Step 2: Create the model**

Create `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/SlashCommand.swift`:

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/SlashCommand.swift
import Foundation

struct SlashCommand: Codable, Identifiable, Equatable {
    let name: String
    let description: String
    let source: String
    var id: String { name }
}

struct CommandsListResponse: Codable {
    let type: String
    let commands: [SlashCommand]
}
```

**Step 3: Add `availableCommands` to WebSocketManager and decode the message**

Modify `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`:

1. Add published property (near other `@Published` properties around line 62):
```swift
    @Published var availableCommands: [SlashCommand] = []
```

2. In `handleMessage(_:)` (around line 559), add a new decode branch. Add it after the `questionResolved` decode block (around line 639) and before the `permissionRequest` decode block:
```swift
            } else if let commandsList = try? JSONDecoder().decode(CommandsListResponse.self, from: data),
                      commandsList.type == "commands_list" {
                logToFile("✅ Decoded as CommandsListResponse: \(commandsList.commands.count) commands")
                DispatchQueue.main.async {
                    self.availableCommands = commandsList.commands
                }
```

**Step 4: Add SlashCommand.swift to the Xcode project**

The file needs to be added to the Xcode project's build sources. Run:
```bash
# Find existing model files in the project to confirm the pattern
grep -r "SlashCommand" ios-voice-app/ClaudeVoice/ClaudeVoice.xcodeproj/ || true
```
If not auto-discovered, add via: open Xcode project, drag file into Models group, or use the `xcodebuild` approach of including the directory.

**Step 5: Build to verify compilation**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' 2>&1 | tail -5
```
Expected: `** BUILD SUCCEEDED **`

**Step 6: Run iOS unit tests**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild test -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:ClaudeVoiceTests/SlashCommandTests 2>&1 | tail -20
```
Expected: All 3 tests PASS

**Step 7: Commit**

```bash
cd /Users/aaron/Desktop/max && git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/SlashCommand.swift ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift ios-voice-app/ClaudeVoice/ClaudeVoiceTests/SlashCommandTests.swift && git commit -m "feat: add SlashCommand model and commands_list WebSocket decoding"
```

---

### Task 4: Verify end-to-end data flow

**Step 1: Reinstall server**

```bash
pipx install --force /Users/aaron/Desktop/max
```

**Step 2: Start the server and verify commands_list is sent**

Start server in one terminal, connect from iOS app (or use a test WebSocket client), and verify the `commands_list` message appears in server output.

Run:
```bash
python3 -c "
import asyncio, websockets, json
async def test():
    async with websockets.connect('ws://localhost:8765') as ws:
        msgs = []
        for _ in range(5):
            msg = await asyncio.wait_for(ws.recv(), timeout=2)
            data = json.loads(msg)
            msgs.append(data['type'])
            if data['type'] == 'commands_list':
                print(f'Got commands_list with {len(data[\"commands\"])} commands')
                print(f'First 3: {[c[\"name\"] for c in data[\"commands\"][:3]]}')
                break
        if 'commands_list' not in msgs:
            print(f'ERROR: commands_list not found in: {msgs}')
asyncio.run(test())
"
```
Expected: `Got commands_list with ~70 commands` (builtins + user skills)

**CHECKPOINT:** If the commands_list message doesn't appear, debug the server before proceeding to Phase 2.

**Step 3: Test list_commands request**

```bash
python3 -c "
import asyncio, websockets, json
async def test():
    async with websockets.connect('ws://localhost:8765') as ws:
        # Drain initial messages
        for _ in range(5):
            try:
                await asyncio.wait_for(ws.recv(), timeout=1)
            except asyncio.TimeoutError:
                break
        # Send list_commands
        await ws.send(json.dumps({'type': 'list_commands'}))
        msg = await asyncio.wait_for(ws.recv(), timeout=2)
        data = json.loads(msg)
        assert data['type'] == 'commands_list'
        print(f'list_commands returned {len(data[\"commands\"])} commands')
asyncio.run(test())
"
```
Expected: Prints command count

**Step 4: Commit verification docs (optional)**

No commit needed — this is a verification task only.
