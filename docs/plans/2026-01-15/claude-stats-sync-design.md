# Claude Stats Sync Design

Sync Claude Code usage and context stats with iOS app display.

## Overview

Two stats to display:
1. **Context remaining** - Per-session, shown in SessionView header
2. **Usage stats** - Global, shown in SettingsView

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Voice Server                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌─────────────────────┐    ┌─────────────────────┐             │
│  │  ContextTracker     │    │  UsageChecker       │             │
│  ├─────────────────────┤    ├─────────────────────┤             │
│  │ • Extend existing   │    │ • On-demand only    │             │
│  │   transcript watch  │    │ • Spawn temp tmux   │             │
│  │ • Sum usage.tokens  │    │ • Run /usage        │             │
│  │ • Broadcast on      │    │ • Parse output      │             │
│  │   message updates   │    │ • Cache result      │             │
│  └──────────┬──────────┘    └──────────┬──────────┘             │
│             │                          │                         │
│             ▼                          ▼                         │
│       context_update              usage_response                 │
│       (real-time)                 (on request)                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ WebSocket
┌─────────────────────────────────────────────────────────────────┐
│                         iOS App                                  │
├─────────────────────────────────────────────────────────────────┤
│  SessionView Header: "Context: 73%" (live updates)              │
│  SettingsView: Show cached → request fresh → update display     │
└─────────────────────────────────────────────────────────────────┘
```

## Data Sources

### Context Remaining

Source: Transcript `.jsonl` files in `~/.claude/projects/<project>/<session>.jsonl`

Each message entry contains token usage from Anthropic API:
```json
{
  "message": {
    "usage": {
      "input_tokens": 1234,
      "output_tokens": 567,
      "cache_creation_input_tokens": 0,
      "cache_read_input_tokens": 890
    }
  }
}
```

Algorithm:
1. Parse active session transcript
2. Sum `input_tokens + output_tokens` from all message entries
3. Calculate: `context_percentage = (tokens_used / 200000) * 100`

### Usage Stats

Source: Claude Code `/usage` command output

```
Current session
███▌                                               7% used
Resets 1:59pm (America/Los_Angeles)

Current week (all models)
████████████                                       24% used
Resets 7:59pm (America/Los_Angeles)

Current week (Sonnet only)
                                                   0% used
```

Fetching approach:
1. Spawn temporary tmux session
2. Start Claude Code
3. Run `/usage` command
4. Capture terminal output
5. Parse with regex
6. Kill session

Caching: Server-side, in memory. Send cached immediately, then fresh when ready.

## WebSocket Protocol

### Context Update (Server → iOS)

Sent on transcript file changes:

```json
{
  "type": "context_update",
  "session_id": "6aa71978-51f2-40dc-bdf0-1672c35f0f9e",
  "tokens_used": 45234,
  "context_limit": 200000,
  "context_percentage": 22.6,
  "timestamp": 1705341234.5
}
```

### Usage Request (iOS → Server)

Sent when user opens Settings:

```json
{
  "type": "usage_request"
}
```

### Usage Response (Server → iOS)

```json
{
  "type": "usage_response",
  "cached": false,
  "session": {
    "percentage": 7,
    "resets_at": "1:59pm",
    "timezone": "America/Los_Angeles"
  },
  "week_all_models": {
    "percentage": 24,
    "resets_at": "7:59pm",
    "timezone": "America/Los_Angeles"
  },
  "week_sonnet_only": {
    "percentage": 0
  },
  "timestamp": 1705341234.5
}
```

## iOS UI

### SessionView Header

```
┌────────────────────────────────────────────┐
│  Project Name                              │
│  Session: abc123         Context: 73%  ●   │
└────────────────────────────────────────────┘
```

- Color indicator: green (>50%), yellow (20-50%), red (<20%)
- Updates in real-time

### SettingsView (ScrollView, below existing content)

```
┌────────────────────────────────────────────┐
│  Usage                      ↻ (refresh)    │
│  ┌──────────────────────────────────────┐  │
│  │ Current Session                      │  │
│  │ ███▌ 7%         Resets 1:59pm PT    │  │
│  │                                      │  │
│  │ This Week (All Models)               │  │
│  │ ████████ 24%    Resets 7:59pm PT    │  │
│  │                                      │  │
│  │ This Week (Sonnet)                   │  │
│  │ ░░░░░░░░ 0%                          │  │
│  └──────────────────────────────────────┘  │
│  Last checked: 2 min ago                   │
└────────────────────────────────────────────┘
```

## Server Implementation

### ContextTracker

Extend existing `TranscriptHandler`:

```python
def calculate_context_usage(self, transcript_path: str) -> dict:
    """Parse transcript and sum token usage."""
    total_tokens = 0

    with open(transcript_path) as f:
        for line in f:
            entry = json.loads(line)
            if 'message' in entry and 'usage' in entry['message']:
                usage = entry['message']['usage']
                total_tokens += usage.get('input_tokens', 0)
                total_tokens += usage.get('output_tokens', 0)

    context_limit = 200000
    return {
        "type": "context_update",
        "session_id": self.session_id,
        "tokens_used": total_tokens,
        "context_limit": context_limit,
        "context_percentage": round((total_tokens / context_limit) * 100, 1)
    }
```

### UsageChecker

New class:

```python
class UsageChecker:
    def __init__(self):
        self.cached_usage: dict | None = None
        self.cache_timestamp: float = 0

    async def check_usage(self) -> dict:
        """Spawn Claude Code, run /usage, parse output, return stats."""
        session_name = f"usage-check-{int(time.time())}"

        # 1. Create temp tmux session
        subprocess.run(["tmux", "new-session", "-d", "-s", session_name])

        # 2. Start Claude Code
        subprocess.run(["tmux", "send-keys", "-t", session_name, "claude", "Enter"])
        await asyncio.sleep(2)

        # 3. Send /usage command
        subprocess.run(["tmux", "send-keys", "-t", session_name, "/usage", "Enter"])
        await asyncio.sleep(1)

        # 4. Capture and parse
        result = subprocess.run(
            ["tmux", "capture-pane", "-t", session_name, "-p"],
            capture_output=True, text=True
        )
        usage_data = parse_usage_output(result.stdout)

        # 5. Cleanup
        subprocess.run(["tmux", "send-keys", "-t", session_name, "Escape", ""])
        subprocess.run(["tmux", "kill-session", "-t", session_name])

        # 6. Cache and return
        self.cached_usage = usage_data
        self.cache_timestamp = time.time()
        return usage_data
```

## Files to Modify

| File | Changes |
|------|---------|
| `voice_server/ios_server.py` | Add `context_update` broadcast on transcript changes |
| `voice_server/usage_checker.py` | New - UsageChecker class |
| `voice_server/usage_parser.py` | New - regex parsing for /usage output |
| `ios-voice-app/.../WebSocketManager.swift` | Handle `context_update`, `usage_response` |
| `ios-voice-app/.../SessionView.swift` | Add context % to header |
| `ios-voice-app/.../SettingsView.swift` | Add Usage section |
| `ios-voice-app/.../Models/` | Add UsageStats, ContextStats models |

## Risks

| Risk | Mitigation |
|------|------------|
| `/usage` output format changes | Match stable text anchors, return null on parse failure |
| Claude Code startup slow | Increase timeout, show loading state |
| ANSI codes in terminal output | Strip escape codes before parsing |

## Testing

- Unit tests for usage parser with sample outputs
- Integration test for context calculation against known transcript
- E2E test for usage request/response flow
