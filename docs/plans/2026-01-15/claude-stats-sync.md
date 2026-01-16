# Claude Stats Sync Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Sync Claude Code usage and context stats with iOS app display.

**Architecture:** Server-side services calculate context from transcript files (real-time) and fetch usage via spawning Claude Code with /usage command (on-demand). iOS displays context % in SessionView header and usage stats in SettingsView.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS), WebSocket protocol

**Risky Assumptions:**
1. `/usage` terminal output format is stable and parseable - verify by capturing actual output first
2. Transcript files always contain `usage` field with token counts - verify with sample transcript

---

## Verification Strategy

Each task includes automated verification that Claude executes:

| Task | Test File | Command |
|------|-----------|---------|
| Task 1 | `tests/test_context_tracker.py` | `pytest tests/test_context_tracker.py` |
| Task 2 | `tests/test_context_broadcast.py` + iOS build | `pytest tests/test_context_broadcast.py` + `xcodebuild build` |
| Task 3 | `E2ESessionFlowTests.swift` | `./run_e2e_tests.sh E2ESessionFlowTests` |
| Task 4 | `tests/test_usage_parser.py` | `pytest tests/test_usage_parser.py` |
| Task 5 | `tests/test_usage_handler.py` | `pytest tests/test_usage_handler.py` |
| Task 6 | `E2EConnectionTests.swift` | `./run_e2e_tests.sh E2EConnectionTests` |

---

## Task 1: Context Calculation Service (Server)

**Files:**
- Create: `voice_server/context_tracker.py`
- Test: `voice_server/tests/test_context_tracker.py`

**Step 1: Write the failing test**

```python
# voice_server/tests/test_context_tracker.py
import pytest
import json
import tempfile
import os
from context_tracker import ContextTracker

def test_calculate_context_from_empty_file():
    """Empty transcript returns 0% context usage."""
    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write("")
        f.flush()

        tracker = ContextTracker()
        result = tracker.calculate_context(f.name)

        assert result["tokens_used"] == 0
        assert result["context_percentage"] == 0.0
        assert result["context_limit"] == 200000

        os.unlink(f.name)

def test_calculate_context_from_transcript():
    """Transcript with usage data returns correct percentage."""
    lines = [
        json.dumps({
            "message": {
                "role": "user",
                "content": "Hello",
                "usage": {"input_tokens": 100, "output_tokens": 0}
            }
        }),
        json.dumps({
            "message": {
                "role": "assistant",
                "content": "Hi there!",
                "usage": {"input_tokens": 150, "output_tokens": 50}
            }
        })
    ]

    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write("\n".join(lines))
        f.flush()

        tracker = ContextTracker()
        result = tracker.calculate_context(f.name)

        # 100 + 0 + 150 + 50 = 300 tokens
        assert result["tokens_used"] == 300
        assert result["context_percentage"] == 0.15  # 300/200000 * 100 = 0.15%

        os.unlink(f.name)

def test_calculate_context_ignores_entries_without_usage():
    """Entries without usage field are skipped."""
    lines = [
        json.dumps({"message": {"role": "user", "content": "No usage field"}}),
        json.dumps({
            "message": {
                "role": "assistant",
                "content": "With usage",
                "usage": {"input_tokens": 500, "output_tokens": 500}
            }
        })
    ]

    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        f.write("\n".join(lines))
        f.flush()

        tracker = ContextTracker()
        result = tracker.calculate_context(f.name)

        assert result["tokens_used"] == 1000

        os.unlink(f.name)
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server && python -m pytest tests/test_context_tracker.py -v`
Expected: FAIL with "No module named 'context_tracker'"

**Step 3: Write minimal implementation**

```python
# voice_server/context_tracker.py
"""Context tracking service for Claude Code sessions."""

import json
from typing import Optional

CONTEXT_LIMIT = 200000

class ContextTracker:
    """Calculates context usage from transcript files."""

    def calculate_context(self, transcript_path: str) -> dict:
        """Parse transcript and sum token usage.

        Args:
            transcript_path: Path to session .jsonl transcript file

        Returns:
            Dict with tokens_used, context_limit, context_percentage
        """
        total_tokens = 0

        try:
            with open(transcript_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                        message = entry.get('message', {})
                        usage = message.get('usage', {})
                        total_tokens += usage.get('input_tokens', 0)
                        total_tokens += usage.get('output_tokens', 0)
                    except json.JSONDecodeError:
                        continue
        except FileNotFoundError:
            pass

        percentage = round((total_tokens / CONTEXT_LIMIT) * 100, 2)

        return {
            "tokens_used": total_tokens,
            "context_limit": CONTEXT_LIMIT,
            "context_percentage": percentage
        }
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server && python -m pytest tests/test_context_tracker.py -v`
Expected: PASS (3 tests)

**Step 5: Commit**

```bash
git add voice_server/context_tracker.py voice_server/tests/test_context_tracker.py
git commit -m "feat: add context tracker service for token usage calculation"
```

---

## Task 2: Context Broadcast via WebSocket (Server + iOS)

**Files:**
- Modify: `voice_server/ios_server.py:42-161` (TranscriptHandler)
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ContextStats.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`

**Step 1: Add context_update to server TranscriptHandler**

In `voice_server/ios_server.py`, add import at top:
```python
from context_tracker import ContextTracker
```

Modify `TranscriptHandler.__init__` to add context tracker:
```python
def __init__(self, content_callback, audio_callback, loop, server):
    self.content_callback = content_callback
    self.audio_callback = audio_callback
    self.loop = loop
    self.server = server
    self.last_modified = 0
    self.processed_line_count = 0
    self.expected_session_file = None
    self.context_tracker = ContextTracker()  # NEW
```

Add method to TranscriptHandler after `extract_new_assistant_content`:
```python
def broadcast_context_update(self, filepath: str, session_id: str):
    """Calculate and broadcast context usage for the session."""
    context_data = self.context_tracker.calculate_context(filepath)
    context_data["type"] = "context_update"
    context_data["session_id"] = session_id

    asyncio.run_coroutine_threadsafe(
        self.server.broadcast_message(context_data),
        self.loop
    )
```

Modify `on_modified` to broadcast context after processing (add at end of try block, after line ~108):
```python
# Broadcast context update
if self.server.active_session_id:
    self.broadcast_context_update(event.src_path, self.server.active_session_id)
```

**Step 2: Add broadcast_message helper to VoiceServer**

Add to `VoiceServer` class after `send_idle_to_all_clients`:
```python
async def broadcast_message(self, message: dict):
    """Broadcast a JSON message to all connected clients."""
    message_json = json.dumps(message)
    for websocket in list(self.clients):
        try:
            await websocket.send(message_json)
        except Exception:
            pass
```

**Step 3: Create iOS ContextStats model**

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ContextStats.swift
import Foundation

struct ContextStats: Codable {
    let type: String
    let sessionId: String
    let tokensUsed: Int
    let contextLimit: Int
    let contextPercentage: Double

    enum CodingKeys: String, CodingKey {
        case type
        case sessionId = "session_id"
        case tokensUsed = "tokens_used"
        case contextLimit = "context_limit"
        case contextPercentage = "context_percentage"
    }
}
```

**Step 4: Add context handling to WebSocketManager**

Add published property after `pendingPermission` (~line 50):
```swift
@Published var contextStats: ContextStats? = nil
```

Add callback after `onFileContents`:
```swift
var onContextUpdate: ((ContextStats) -> Void)?
```

Add decoding in `handleMessage` string case, after `fileContents` else-if (~line 435):
```swift
} else if let contextStats = try? JSONDecoder().decode(ContextStats.self, from: data),
          contextStats.type == "context_update" {
    logToFile("Decoded as ContextStats: \(contextStats.contextPercentage)%")
    DispatchQueue.main.async {
        self.contextStats = contextStats
        self.onContextUpdate?(contextStats)
    }
}
```

**Step 5: Write server integration test for context broadcast**

Create `voice_server/tests/test_context_broadcast.py`:
```python
import pytest
import json
import asyncio
import tempfile
import os
from unittest.mock import AsyncMock, MagicMock, patch

# Test that TranscriptHandler broadcasts context_update on file change
def test_context_update_broadcast():
    """TranscriptHandler broadcasts context_update when transcript changes."""
    from ios_server import TranscriptHandler
    from context_tracker import ContextTracker

    # Create mock server with broadcast_message method
    mock_server = MagicMock()
    mock_server.active_session_id = "test-session-123"
    mock_server.broadcast_message = AsyncMock()

    loop = asyncio.new_event_loop()

    handler = TranscriptHandler(
        content_callback=AsyncMock(),
        audio_callback=AsyncMock(),
        loop=loop,
        server=mock_server
    )

    # Create temp transcript with usage data
    transcript_data = [
        {"message": {"role": "assistant", "content": "Hi", "usage": {"input_tokens": 100, "output_tokens": 50}}}
    ]

    with tempfile.NamedTemporaryFile(mode='w', suffix='.jsonl', delete=False) as f:
        for entry in transcript_data:
            f.write(json.dumps(entry) + "\n")
        f.flush()
        transcript_path = f.name

    try:
        handler.set_session_file(transcript_path)

        # Simulate file modification event
        mock_event = MagicMock()
        mock_event.is_directory = False
        mock_event.src_path = transcript_path

        # Call on_modified
        handler.on_modified(mock_event)

        # Give async tasks time to complete
        loop.run_until_complete(asyncio.sleep(0.1))

        # Verify broadcast_message was called with context_update
        calls = mock_server.broadcast_message.call_args_list
        context_calls = [c for c in calls if c[0][0].get("type") == "context_update"]

        assert len(context_calls) >= 1, "Should broadcast context_update"
        context_msg = context_calls[0][0][0]
        assert context_msg["tokens_used"] == 150
        assert context_msg["session_id"] == "test-session-123"

    finally:
        os.unlink(transcript_path)
        loop.close()
```

**Step 6: Run integration test**

Run: `cd voice_server && python -m pytest tests/test_context_broadcast.py -v`
Expected: PASS

CHECKPOINT: If test fails, verify TranscriptHandler imports ContextTracker and calls broadcast_context_update.

**Step 7: Build iOS to verify model compiles**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -quiet
```
Expected: BUILD SUCCEEDED

**Step 8: Commit**

```bash
git add voice_server/ios_server.py \
  voice_server/tests/test_context_broadcast.py \
  ios-voice-app/ClaudeVoice/ClaudeVoice/Models/ContextStats.swift \
  ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift
git commit -m "feat: broadcast context updates via WebSocket"
```

---

## Task 3: Context Display in SessionView Header

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

**Step 1: Add context state variable**

Add after `branchName` state:
```swift
@State private var contextPercentage: Double? = nil
```

**Step 2: Update the header trailing content**

Replace the HStack in `.customNavigationBarInline` trailing closure:
```swift
} {
    HStack(spacing: 12) {
        // Context indicator
        if let pct = contextPercentage {
            HStack(spacing: 4) {
                Circle()
                    .fill(contextColor(pct))
                    .frame(width: 8, height: 8)
                Text("\(Int(100 - pct))%")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .accessibilityIdentifier("contextIndicator")
        }

        // Branch name
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(branchName)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}
```

**Step 3: Add contextColor helper**

Add after `permissionDescription`:
```swift
private func contextColor(_ percentage: Double) -> Color {
    let remaining = 100 - percentage
    if remaining > 50 {
        return .green
    } else if remaining > 20 {
        return .yellow
    } else {
        return .red
    }
}
```

**Step 4: Subscribe to context updates in setupView**

Add at end of `setupView()`:
```swift
// Subscribe to context updates
webSocketManager.onContextUpdate = { stats in
    // Only update if this is for our session
    if stats.sessionId == session.id || (session.isNewSession && webSocketManager.activeSessionId == nil) {
        self.contextPercentage = stats.contextPercentage
    }
}
```

**Step 5: Build iOS app to verify code compiles**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -quiet
```
Expected: BUILD SUCCEEDED

**Step 6: Add E2E verification to existing test**

Modify `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ESessionFlowTests.swift`.

Add after line 32 (`XCTAssertTrue(waitForSessionSyncComplete(timeout: 20), "Session sync should complete")`):
```swift
        // Verify context indicator appears in session header
        let contextIndicator = app.staticTexts["contextIndicator"]
        XCTAssertTrue(contextIndicator.waitForExistence(timeout: 5), "Context indicator should appear in session header")
```

**Step 7: Run E2E test to verify context display**

Run:
```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2ESessionFlowTests
```
Expected: Tests pass, context indicator found

CHECKPOINT: If E2E test fails, check that contextIndicator accessibilityIdentifier is set correctly.

**Step 8: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift \
  ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2ESessionFlowTests.swift
git commit -m "feat: display context remaining in session header"
```

---

## Task 4: Usage Parser (Server)

**Files:**
- Create: `voice_server/usage_parser.py`
- Test: `voice_server/tests/test_usage_parser.py`

**Step 1: Write the failing test**

```python
# voice_server/tests/test_usage_parser.py
import pytest
from usage_parser import parse_usage_output

SAMPLE_OUTPUT = """
  Settings:  Status   Config   Usage  (←/→ or tab to cycle)


  Current session
  ███▌                                               7% used
  Resets 1:59pm (America/Los_Angeles)

  Current week (all models)
  ████████████                                       24% used
  Resets 7:59pm (America/Los_Angeles)

  Current week (Sonnet only)
                                                     0% used

  escape to cancel
"""

def test_parse_session_usage():
    """Extract session percentage and reset time."""
    result = parse_usage_output(SAMPLE_OUTPUT)

    assert result["session"]["percentage"] == 7
    assert result["session"]["resets_at"] == "1:59pm"
    assert result["session"]["timezone"] == "America/Los_Angeles"

def test_parse_week_all_models():
    """Extract weekly all-models usage."""
    result = parse_usage_output(SAMPLE_OUTPUT)

    assert result["week_all_models"]["percentage"] == 24
    assert result["week_all_models"]["resets_at"] == "7:59pm"

def test_parse_week_sonnet_only():
    """Extract weekly Sonnet-only usage."""
    result = parse_usage_output(SAMPLE_OUTPUT)

    assert result["week_sonnet_only"]["percentage"] == 0

def test_parse_empty_output():
    """Empty or invalid output returns None values."""
    result = parse_usage_output("")

    assert result["session"]["percentage"] is None
    assert result["week_all_models"]["percentage"] is None

def test_parse_with_ansi_codes():
    """ANSI escape codes are stripped before parsing."""
    output_with_ansi = "\x1b[1m7% used\x1b[0m"
    # This is a partial test - full output would have more structure
    # Just verify ANSI stripping doesn't break parsing
    result = parse_usage_output(output_with_ansi)
    assert result is not None
```

**Step 2: Run test to verify it fails**

Run: `cd voice_server && python -m pytest tests/test_usage_parser.py -v`
Expected: FAIL with "No module named 'usage_parser'"

**Step 3: Write minimal implementation**

```python
# voice_server/usage_parser.py
"""Parser for Claude Code /usage command output."""

import re
from typing import Optional

# ANSI escape code pattern
ANSI_ESCAPE = re.compile(r'\x1b\[[0-9;]*m')

def strip_ansi(text: str) -> str:
    """Remove ANSI escape codes from text."""
    return ANSI_ESCAPE.sub('', text)

def parse_usage_output(output: str) -> dict:
    """Parse /usage command output into structured data.

    Args:
        output: Raw terminal output from /usage command

    Returns:
        Dict with session, week_all_models, week_sonnet_only stats
    """
    clean = strip_ansi(output)

    result = {
        "session": {"percentage": None, "resets_at": None, "timezone": None},
        "week_all_models": {"percentage": None, "resets_at": None, "timezone": None},
        "week_sonnet_only": {"percentage": None}
    }

    # Split into sections by looking for headers
    sections = re.split(r'\n\s*\n', clean)

    current_section = None

    for section in sections:
        section_lower = section.lower()

        if 'current session' in section_lower:
            current_section = 'session'
        elif 'current week (all models)' in section_lower:
            current_section = 'week_all_models'
        elif 'current week (sonnet' in section_lower:
            current_section = 'week_sonnet_only'
        else:
            current_section = None

        if current_section:
            # Extract percentage: look for "X% used"
            pct_match = re.search(r'(\d+)%\s*used', section)
            if pct_match:
                result[current_section]["percentage"] = int(pct_match.group(1))

            # Extract reset time: "Resets X:XXam/pm (Timezone)"
            reset_match = re.search(r'Resets\s+(\d+:\d+[ap]m)\s*\(([^)]+)\)', section)
            if reset_match and current_section != 'week_sonnet_only':
                result[current_section]["resets_at"] = reset_match.group(1)
                result[current_section]["timezone"] = reset_match.group(2)

    return result
```

**Step 4: Run test to verify it passes**

Run: `cd voice_server && python -m pytest tests/test_usage_parser.py -v`
Expected: PASS (5 tests)

**Step 5: Commit**

```bash
git add voice_server/usage_parser.py voice_server/tests/test_usage_parser.py
git commit -m "feat: add parser for /usage command output"
```

---

## Task 5: Usage Checker Service (Server)

**Files:**
- Create: `voice_server/usage_checker.py`
- Modify: `voice_server/ios_server.py` (add handler)
- Test: Manual verification (tmux spawning is hard to unit test)

**Step 1: Create UsageChecker class**

```python
# voice_server/usage_checker.py
"""On-demand usage stats checker for Claude Code."""

import asyncio
import subprocess
import time
from typing import Optional
from usage_parser import parse_usage_output

class UsageChecker:
    """Spawns Claude Code to fetch /usage stats on demand."""

    def __init__(self):
        self.cached_usage: Optional[dict] = None
        self.cache_timestamp: float = 0

    def get_cached(self) -> Optional[dict]:
        """Return cached usage if available."""
        if self.cached_usage:
            return {
                **self.cached_usage,
                "cached": True,
                "cache_age_seconds": time.time() - self.cache_timestamp
            }
        return None

    async def check_usage(self) -> dict:
        """Spawn Claude Code, run /usage, parse output, return stats.

        This creates a temporary tmux session, starts Claude Code,
        sends /usage, captures output, then cleans up.

        Returns:
            Parsed usage stats dict
        """
        session_name = f"usage-check-{int(time.time())}"

        try:
            # 1. Create temp tmux session
            subprocess.run(
                ["tmux", "new-session", "-d", "-s", session_name],
                check=True,
                capture_output=True
            )

            # 2. Start Claude Code
            subprocess.run(
                ["tmux", "send-keys", "-t", session_name, "claude", "Enter"],
                check=True,
                capture_output=True
            )
            await asyncio.sleep(3)  # Wait for Claude to initialize

            # 3. Send /usage command
            subprocess.run(
                ["tmux", "send-keys", "-t", session_name, "/usage", "Enter"],
                check=True,
                capture_output=True
            )
            await asyncio.sleep(1)  # Wait for display to render

            # 4. Capture terminal output
            result = subprocess.run(
                ["tmux", "capture-pane", "-t", session_name, "-p"],
                capture_output=True,
                text=True
            )
            raw_output = result.stdout

            # 5. Parse the output
            usage_data = parse_usage_output(raw_output)
            usage_data["type"] = "usage_response"
            usage_data["cached"] = False
            usage_data["timestamp"] = time.time()

            # 6. Cache the result
            self.cached_usage = usage_data
            self.cache_timestamp = time.time()

            return usage_data

        except subprocess.CalledProcessError as e:
            return {
                "type": "usage_response",
                "error": f"Failed to check usage: {e}",
                "cached": False,
                "timestamp": time.time()
            }
        finally:
            # Always clean up the tmux session
            try:
                subprocess.run(
                    ["tmux", "send-keys", "-t", session_name, "Escape", ""],
                    capture_output=True
                )
                await asyncio.sleep(0.5)
                subprocess.run(
                    ["tmux", "send-keys", "-t", session_name, "/exit", "Enter"],
                    capture_output=True
                )
                await asyncio.sleep(1)
                subprocess.run(
                    ["tmux", "kill-session", "-t", session_name],
                    capture_output=True
                )
            except Exception:
                pass
```

**Step 2: Add usage_request handler to ios_server.py**

Add import at top:
```python
from usage_checker import UsageChecker
```

Add to `VoiceServer.__init__` after `self.permission_handler`:
```python
self.usage_checker = UsageChecker()
```

Add handler method to VoiceServer:
```python
async def handle_usage_request(self, websocket):
    """Handle usage_request - send cached immediately, then fetch fresh."""
    # Send cached immediately if available
    cached = self.usage_checker.get_cached()
    if cached:
        await websocket.send(json.dumps(cached))

    # Fetch fresh in background
    fresh = await self.usage_checker.check_usage()
    await websocket.send(json.dumps(fresh))
```

Add to `handle_message` switch (~line 750):
```python
elif msg_type == 'usage_request':
    await self.handle_usage_request(websocket)
```

**Step 3: Write integration test for usage handler**

Create `voice_server/tests/test_usage_handler.py`:
```python
import pytest
import json
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

def test_handle_usage_request_returns_cached_then_fresh():
    """handle_usage_request sends cached first, then fresh data."""
    from ios_server import VoiceServer

    server = VoiceServer()

    # Pre-populate cache
    server.usage_checker.cached_usage = {
        "session": {"percentage": 5},
        "week_all_models": {"percentage": 20},
        "week_sonnet_only": {"percentage": 0}
    }
    server.usage_checker.cache_timestamp = 1000.0

    # Mock websocket
    mock_ws = AsyncMock()
    sent_messages = []

    async def capture_send(msg):
        sent_messages.append(json.loads(msg))

    mock_ws.send = capture_send

    # Mock check_usage to return fresh data
    async def mock_check():
        return {
            "type": "usage_response",
            "session": {"percentage": 7},
            "week_all_models": {"percentage": 24},
            "week_sonnet_only": {"percentage": 0},
            "cached": False
        }

    server.usage_checker.check_usage = mock_check

    # Run handler
    loop = asyncio.new_event_loop()
    loop.run_until_complete(server.handle_usage_request(mock_ws))
    loop.close()

    # Should have sent 2 messages: cached first, then fresh
    assert len(sent_messages) == 2
    assert sent_messages[0]["cached"] == True
    assert sent_messages[0]["session"]["percentage"] == 5
    assert sent_messages[1]["cached"] == False
    assert sent_messages[1]["session"]["percentage"] == 7


def test_handle_usage_request_no_cache():
    """handle_usage_request with no cache only sends fresh data."""
    from ios_server import VoiceServer

    server = VoiceServer()
    # No cached data

    mock_ws = AsyncMock()
    sent_messages = []

    async def capture_send(msg):
        sent_messages.append(json.loads(msg))

    mock_ws.send = capture_send

    async def mock_check():
        return {
            "type": "usage_response",
            "session": {"percentage": 7},
            "cached": False
        }

    server.usage_checker.check_usage = mock_check

    loop = asyncio.new_event_loop()
    loop.run_until_complete(server.handle_usage_request(mock_ws))
    loop.close()

    # Should have sent only 1 message (fresh)
    assert len(sent_messages) == 1
    assert sent_messages[0]["cached"] == False
```

**Step 4: Run integration test**

Run: `cd voice_server && python -m pytest tests/test_usage_handler.py -v`
Expected: PASS (2 tests)

CHECKPOINT: If tests fail, verify handle_usage_request is correctly wired in ios_server.py.

**Step 5: Commit**

```bash
git add voice_server/usage_checker.py voice_server/ios_server.py voice_server/tests/test_usage_handler.py
git commit -m "feat: add on-demand usage checker with caching"
```

---

## Task 6: Usage Display in SettingsView (iOS)

**Files:**
- Create: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/UsageStats.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift`
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SettingsView.swift`

**Step 1: Create UsageStats model**

```swift
// ios-voice-app/ClaudeVoice/ClaudeVoice/Models/UsageStats.swift
import Foundation

struct UsageCategory: Codable {
    let percentage: Int?
    let resetsAt: String?
    let timezone: String?

    enum CodingKeys: String, CodingKey {
        case percentage
        case resetsAt = "resets_at"
        case timezone
    }
}

struct UsageStats: Codable {
    let type: String
    let session: UsageCategory
    let weekAllModels: UsageCategory
    let weekSonnetOnly: UsageCategory
    let cached: Bool
    let timestamp: Double?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case type
        case session
        case weekAllModels = "week_all_models"
        case weekSonnetOnly = "week_sonnet_only"
        case cached
        case timestamp
        case error
    }
}
```

**Step 2: Add usage handling to WebSocketManager**

Add published property after `contextStats`:
```swift
@Published var usageStats: UsageStats? = nil
@Published var isLoadingUsage: Bool = false
```

Add callback after `onContextUpdate`:
```swift
var onUsageUpdate: ((UsageStats) -> Void)?
```

Add request method after `readFile`:
```swift
func requestUsage() {
    isLoadingUsage = true
    let message = ["type": "usage_request"]
    sendJSON(message)
}
```

Add decoding in `handleMessage` string case, after `contextStats` else-if:
```swift
} else if let usageStats = try? JSONDecoder().decode(UsageStats.self, from: data),
          usageStats.type == "usage_response" {
    logToFile("Decoded as UsageStats: session=\(usageStats.session.percentage ?? -1)%")
    DispatchQueue.main.async {
        self.usageStats = usageStats
        self.isLoadingUsage = false
        self.onUsageUpdate?(usageStats)
    }
}
```

**Step 3: Add Usage section to SettingsView**

Replace the entire SettingsView body with:
```swift
var body: some View {
    NavigationView {
        ScrollView {
            VStack(spacing: 0) {
                // Server Configuration Section
                VStack(alignment: .leading, spacing: 0) {
                    Text("Server Configuration")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal)
                        .padding(.top, 16)
                        .padding(.bottom, 8)

                    VStack(spacing: 0) {
                        if case .connected = webSocketManager.connectionState {
                            if let url = webSocketManager.connectedURL {
                                HStack {
                                    Text("Connected:")
                                    Spacer()
                                    Text(formatURL(url))
                                        .foregroundColor(.secondary)
                                }
                                .padding()
                                .background(Color(.secondarySystemGroupedBackground))
                            }
                        } else {
                            Button(action: { showingScanner = true }) {
                                HStack {
                                    Spacer()
                                    if case .connecting = webSocketManager.connectionState {
                                        ProgressView()
                                            .padding(.trailing, 8)
                                        Text("Connecting...")
                                    } else {
                                        Text("Connect")
                                    }
                                    Spacer()
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))
                            .accessibilityIdentifier("Connect")
                        }
                    }
                    .cornerRadius(10)
                    .padding(.horizontal)
                }

                // Connection Section
                VStack(alignment: .leading, spacing: 0) {
                    Text("Connection")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                        .padding(.horizontal)
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                    VStack(spacing: 0) {
                        HStack {
                            Text("Status:")
                            Spacer()
                            Text(webSocketManager.connectionState.description)
                                .foregroundColor(connectionColor)
                                .accessibilityIdentifier("connectionStatus")
                        }
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground))

                        if case .connected = webSocketManager.connectionState {
                            Divider()
                                .padding(.leading)

                            Button(action: disconnect) {
                                HStack {
                                    Spacer()
                                    Text("Disconnect")
                                    Spacer()
                                }
                            }
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground))
                            .accessibilityIdentifier("Disconnect")
                            .foregroundColor(.red)
                        }
                    }
                    .cornerRadius(10)
                    .padding(.horizontal)
                }

                // Usage Section (only when connected)
                if case .connected = webSocketManager.connectionState {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            Text("Usage")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                                .textCase(.uppercase)

                            Spacer()

                            if webSocketManager.isLoadingUsage {
                                ProgressView()
                                    .scaleEffect(0.7)
                            } else {
                                Button(action: { webSocketManager.requestUsage() }) {
                                    Image(systemName: "arrow.clockwise")
                                        .font(.footnote)
                                }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.top, 24)
                        .padding(.bottom, 8)

                        VStack(spacing: 0) {
                            if let usage = webSocketManager.usageStats {
                                UsageRow(
                                    title: "Current Session",
                                    percentage: usage.session.percentage,
                                    resetsAt: usage.session.resetsAt,
                                    timezone: usage.session.timezone
                                )

                                Divider().padding(.leading)

                                UsageRow(
                                    title: "This Week (All Models)",
                                    percentage: usage.weekAllModels.percentage,
                                    resetsAt: usage.weekAllModels.resetsAt,
                                    timezone: usage.weekAllModels.timezone
                                )

                                Divider().padding(.leading)

                                UsageRow(
                                    title: "This Week (Sonnet)",
                                    percentage: usage.weekSonnetOnly.percentage,
                                    resetsAt: nil,
                                    timezone: nil
                                )

                                if usage.cached {
                                    Divider().padding(.leading)

                                    HStack {
                                        Text("Last updated")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                        if let ts = usage.timestamp {
                                            Text(formatTimestamp(ts))
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    .padding()
                                    .background(Color(.secondarySystemGroupedBackground))
                                }
                            } else {
                                HStack {
                                    Spacer()
                                    if webSocketManager.isLoadingUsage {
                                        ProgressView()
                                    } else {
                                        Text("Tap refresh to load usage")
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding()
                                .background(Color(.secondarySystemGroupedBackground))
                            }
                        }
                        .cornerRadius(10)
                        .padding(.horizontal)
                    }
                    .accessibilityIdentifier("usageSection")
                }

                Spacer(minLength: 32)
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Settings")
        .navigationBarItems(trailing: Button("Done") {
            dismiss()
        })
        .alert("Connection Error", isPresented: $showingAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(alertMessage)
        }
        .fullScreenCover(isPresented: $showingScanner) {
            QRScannerView(
                onCodeScanned: { url in
                    showingScanner = false
                    webSocketManager.connect(url: url)
                },
                onCancel: {
                    showingScanner = false
                }
            )
        }
        .onAppear {
            // Auto-fetch usage when settings opens (if connected)
            if case .connected = webSocketManager.connectionState {
                webSocketManager.requestUsage()
            }
        }
    }
}
```

**Step 4: Add helper views and functions**

Add after `SettingsView`:
```swift
struct UsageRow: View {
    let title: String
    let percentage: Int?
    let resetsAt: String?
    let timezone: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)

            HStack {
                // Progress bar
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color(.systemGray5))
                            .frame(height: 8)
                            .cornerRadius(4)

                        Rectangle()
                            .fill(progressColor)
                            .frame(width: geometry.size.width * progressFraction, height: 8)
                            .cornerRadius(4)
                    }
                }
                .frame(height: 8)

                Text("\(percentage ?? 0)%")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
            }

            if let resets = resetsAt {
                Text("Resets \(resets)\(timezone != nil ? " (\(formatTimezone(timezone!)))" : "")")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
    }

    private var progressFraction: CGFloat {
        CGFloat(percentage ?? 0) / 100.0
    }

    private var progressColor: Color {
        guard let pct = percentage else { return .gray }
        if pct < 50 { return .green }
        if pct < 80 { return .yellow }
        return .red
    }

    private func formatTimezone(_ tz: String) -> String {
        // Shorten "America/Los_Angeles" to "PT"
        switch tz {
        case "America/Los_Angeles": return "PT"
        case "America/New_York": return "ET"
        case "America/Chicago": return "CT"
        case "America/Denver": return "MT"
        default: return tz
        }
    }
}
```

Add to SettingsView:
```swift
private func formatTimestamp(_ timestamp: Double) -> String {
    let date = Date(timeIntervalSince1970: timestamp)
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}
```

**Step 5: Build iOS app to verify code compiles**

Run:
```bash
cd ios-voice-app/ClaudeVoice && xcodebuild build -scheme ClaudeVoice -destination 'platform=iOS Simulator,name=iPhone 16' -quiet
```
Expected: BUILD SUCCEEDED

**Step 6: Add E2E verification to existing test**

Modify `ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EConnectionTests.swift`.

Add after line 41 (`XCTAssertEqual(statusLabel.label, "Connected", "Should be connected")`):
```swift
        // Verify usage section appears when connected
        let usageSection = app.otherElements["usageSection"]
        XCTAssertTrue(usageSection.waitForExistence(timeout: 10), "Usage section should appear in settings when connected")
```

**Step 7: Run E2E test to verify usage display**

Run:
```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2EConnectionTests
```
Expected: Tests pass, usage section found

CHECKPOINT: If E2E test fails, check that usageSection accessibilityIdentifier is set and usage_request/response flow works.

**Step 8: Commit**

```bash
git add ios-voice-app/ClaudeVoice/ClaudeVoice/Models/UsageStats.swift \
  ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift \
  ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SettingsView.swift \
  ios-voice-app/ClaudeVoice/ClaudeVoiceUITests/E2EConnectionTests.swift
git commit -m "feat: display usage stats in settings view"
```

---

## Final Verification

After all tasks complete, run the full test suite:

**Step 1: Run all server tests**
```bash
cd voice_server && python -m pytest tests/ -v
```
Expected: All tests pass (test_context_tracker, test_context_broadcast, test_usage_parser, test_usage_handler)

**Step 2: Run E2E tests for both features**
```bash
cd ios-voice-app/ClaudeVoice && ./run_e2e_tests.sh E2ESessionFlowTests E2EConnectionTests
```
Expected: All tests pass, including context indicator and usage section assertions

CHECKPOINT: If any tests fail, debug before considering the feature complete.

---

**Plan complete and saved to `docs/plans/2026-01-15/claude-stats-sync.md`.**

When ready to implement, run /execute-plan which will:
- Create feature branch
- Commit design and plan docs to the branch
- Execute tasks in batches with checkpoints
- Run /finish-dev-branch when complete
