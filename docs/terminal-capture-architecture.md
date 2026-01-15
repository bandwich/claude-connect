# Terminal Capture Architecture

## Overview

This document outlines how to programmatically capture and parse Claude Code's terminal output to build native iOS UIs for all interactive states.

## Current Architecture

The voice server uses **transcript file watching**, not terminal stream capture:

```
Claude Code (tmux) → writes → .jsonl transcript → watched by → voice_server → WebSocket → iOS
```

The transcript only logs what Claude explicitly outputs as conversation content. All interactive terminal UI (permission prompts, selection menus, "Type something else") are rendered by Claude Code's TUI but **never written to the transcript**.

## Claude Code Interactive States

### 1. Permission Requests

**Hook:** `PermissionRequest` ✓

```
Claude wants to run: npm install
Allow? [Y]es / [N]o / [A]lways / [D]on't ask again
```

**Hook payload:**
```json
{
  "session_id": "abc123",
  "transcript_path": "/Users/.../.claude/projects/.../transcript.jsonl",
  "cwd": "/Users/...",
  "permission_mode": "default",
  "hook_event_name": "PermissionRequest",
  "tool_name": "Bash",
  "tool_input": {
    "command": "npm install"
  }
}
```

**Gap:** The rendered question text isn't in the payload.

### 2. AskUserQuestion Tool

**Hook:** `PermissionRequest` (partial)

```
┌─ Question ─────────────────────────────────────┐
│ Which database should we use?                  │
│                                                │
│ > 1. PostgreSQL (Recommended)                  │
│   2. MySQL                                     │
│   3. SQLite                                    │
│   4. Type something else                       │
└────────────────────────────────────────────────┘
```

**Hook payload includes:** `tool_name: "AskUserQuestion"`, `tool_input: {questions: [...]}`

**Gap:** The rendered menu/selection state isn't exposed.

### 3. Interrupt/Escape Menu

**Hook:** None

```
╭─ Interrupted ────────────────────────────────╮
│ What would you like to do?                   │
│                                              │
│ > 1. Continue where I left off               │
│   2. Start a new task                        │
│   3. Exit                                    │
╰──────────────────────────────────────────────╯
```

### 4. Plan Mode Approval

**Hook:** None

```
╭─ Plan Ready ─────────────────────────────────╮
│ Review the plan above. Ready to proceed?     │
│                                              │
│ [Y]es, proceed / [N]o, revise / [C]ancel     │
╰──────────────────────────────────────────────╯
```

### 5. Cost/Token Warnings

**Hook:** None

```
⚠️  This conversation has used $X.XX
Continue? [Y]es / [N]o
```

### 6. Multi-Select

When Claude presents checkboxes for selecting multiple items.

### 7. Free Text Input

When "Type something else" is selected, or Claude asks an open-ended question.

### 8. Confirmation Prompts

Simple Y/N for various actions.

## Coverage Summary

| Interactive State | Hook Coverage | Terminal Parse Needed |
|-------------------|---------------|----------------------|
| Permission (Bash/Edit/Write) | ✓ Full | Optional (for question text) |
| AskUserQuestion | ✓ Partial | Yes (selection state, rendered options) |
| Interrupt menu | ✗ None | Yes |
| Plan approval | ✗ None | Yes |
| Cost warnings | ✗ None | Yes |
| Free text input | ✗ None | Yes |

## Terminal Capture Approaches

### Approach 1: tmux Control Mode (Event-Driven)

```bash
tmux -C attach-session -t claude-voice
```

Opens a streaming connection where tmux pushes `%output` notifications:

```
%output %0 \033[1;32mClaude>\033[0m Hello\015\012
```

**Pros:**
- Event-driven, no polling
- Built-in flow control (`pause-after`)
- Low latency

**Cons:**
- Complex protocol
- Need to decode octal escapes (`\015` → CR, `\012` → LF, `\033` → ESC)

### Approach 2: pipe-pane (Recommended)

```bash
tmux pipe-pane -t claude-voice -o "python3 terminal_parser.py"
```

Pipes all pane output to a process.

**Pros:**
- Simple to set up
- Can pipe to any process

**Cons:**
- Only captures new output (no initial state)
- Need to combine with `capture-pane` for current screen state

### Approach 3: Polling capture-pane

```python
while True:
    output = subprocess.run(
        ["tmux", "capture-pane", "-t", "claude-voice", "-p", "-e"],
        capture_output=True
    ).stdout
    if output != last_output:
        diff = compute_diff(last_output, output)
        send_to_ios(diff)
        last_output = output
    await asyncio.sleep(0.1)  # 100ms polling
```

**Pros:**
- Trivial to implement
- Always have complete screen state
- `-e` flag preserves ANSI escapes

**Cons:**
- 100ms latency floor
- Diffing needed

**Performance:** `capture-pane` is very cheap (~5-10ms). At 10 Hz polling: ~50-100ms CPU/second.

## Pattern Detection

```python
import re

PATTERNS = {
    # Box with title: ╭─ Title ─╮ or ┌─ Title ─┐
    'box_title': re.compile(r'[╭┌]─\s*(.+?)\s*─[╮┐]'),

    # Menu option: > 1. Text or   2. Text
    'menu_option': re.compile(r'^(\s*)(>?)\s*(\d+)\.\s*(.+)$', re.MULTILINE),

    # Y/N prompt: [Y]es / [N]o or (Y)es (N)o
    'yn_prompt': re.compile(r'\[([YN])\][a-z]+\s*/\s*\[([YN])\][a-z]+', re.IGNORECASE),

    # Permission: Allow? or Allow Bash:
    'permission': re.compile(r'(Allow|Deny|Approve)\??\s*(Bash|Edit|Write)?:?'),

    # Type something else
    'text_input_option': re.compile(r'Type something else|Enter custom|Other'),

    # Thinking/processing indicators
    'thinking': re.compile(r'(Thinking|Processing|Working)\.{0,3}'),
}


def parse_terminal_state(screen_content: str) -> dict:
    """Parse terminal content into semantic state."""

    # Detect box with title
    box_match = PATTERNS['box_title'].search(screen_content)

    # Detect menu options
    options = []
    selected_idx = None
    for match in PATTERNS['menu_option'].finditer(screen_content):
        indent, marker, num, text = match.groups()
        is_selected = marker == '>'
        options.append({
            'index': int(num),
            'text': text.strip(),
            'selected': is_selected
        })
        if is_selected:
            selected_idx = int(num) - 1

    if options:
        allows_text = any(
            PATTERNS['text_input_option'].search(o['text'])
            for o in options
        )
        return {
            'type': 'menu',
            'title': box_match.group(1) if box_match else None,
            'options': options,
            'selected_index': selected_idx,
            'allows_text_input': allows_text
        }

    # Detect Y/N prompt
    yn_match = PATTERNS['yn_prompt'].search(screen_content)
    if yn_match:
        return {
            'type': 'confirmation',
            'prompt': extract_prompt_text(screen_content),
            'options': ['Yes', 'No']
        }

    # Detect permission prompt
    perm_match = PATTERNS['permission'].search(screen_content)
    if perm_match:
        return {
            'type': 'permission',
            'tool': perm_match.group(2),
            'action': perm_match.group(1)
        }

    return {'type': 'idle'}
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                     Terminal State Parser                        │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  tmux pipe-pane ──► Python parser ──► State Machine             │
│                          │                                       │
│                          ▼                                       │
│                    ┌─────────────────┐                          │
│                    │ Pattern Matchers │                          │
│                    ├─────────────────┤                          │
│                    │ • Box detection  │  ╭─ ... ─╮              │
│                    │ • Menu detection │  > 1. Option            │
│                    │ • Y/N prompts    │  [Y]es / [N]o           │
│                    │ • Selection state│  > cursor position      │
│                    │ • Input mode     │  waiting for text       │
│                    └────────┬────────┘                          │
│                             │                                    │
│                             ▼                                    │
│                    ┌─────────────────────────────────────┐      │
│                    │        Semantic Events              │      │
│                    ├─────────────────────────────────────┤      │
│                    │ {                                   │      │
│                    │   "type": "menu",                   │      │
│                    │   "title": "Question",              │      │
│                    │   "options": [...],                 │      │
│                    │   "selected": 0,                    │      │
│                    │   "allows_text_input": true         │      │
│                    │ }                                   │      │
│                    └─────────────────────────────────────┘      │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼ WebSocket
                         iOS App
```

## Semantic Events (WebSocket Protocol)

### Menu State

```json
{
  "type": "terminal_ui",
  "component": "menu",
  "title": "Question",
  "options": [
    {"index": 1, "text": "PostgreSQL (Recommended)", "selected": true},
    {"index": 2, "text": "MySQL", "selected": false},
    {"index": 3, "text": "SQLite", "selected": false},
    {"index": 4, "text": "Type something else", "selected": false}
  ],
  "selected_index": 0,
  "allows_text_input": true
}
```

### Confirmation State

```json
{
  "type": "terminal_ui",
  "component": "confirmation",
  "prompt": "Continue with this plan?",
  "options": ["Yes", "No", "Cancel"]
}
```

### Permission State

```json
{
  "type": "terminal_ui",
  "component": "permission",
  "tool": "Bash",
  "command": "npm install",
  "options": ["Yes", "No", "Always", "Don't ask again"]
}
```

### Thinking State

```json
{
  "type": "terminal_ui",
  "component": "thinking",
  "message": "Processing..."
}
```

### Idle State

```json
{
  "type": "terminal_ui",
  "component": "idle"
}
```

## iOS UI Mapping

| Terminal State | iOS UI Component |
|----------------|------------------|
| `menu` | `List` with selection, tap to choose |
| `confirmation` | `Alert` with buttons |
| `permission` | Permission sheet (existing) |
| `text_input` | `TextField` for custom input |
| `thinking` | Loading indicator |
| `idle` | Ready state |

## Hybrid Approach: Hooks + Terminal Parsing

Combine both data sources for complete coverage:

```python
class ClaudeStateManager:
    def __init__(self):
        self.current_state = {'type': 'idle'}

    def on_hook_event(self, hook_data: dict):
        """From PermissionRequest hook - structured data."""
        if hook_data.get('tool_name') == 'AskUserQuestion':
            self.current_state = {
                'type': 'menu',
                'questions': hook_data['tool_input']['questions'],
                'source': 'hook'
            }
        else:
            self.current_state = {
                'type': 'permission',
                'tool': hook_data['tool_name'],
                'input': hook_data['tool_input'],
                'source': 'hook'
            }
        self.broadcast()

    def on_terminal_update(self, screen: str):
        """From terminal parser - visual state."""
        parsed = parse_terminal_state(screen)

        # Only update if not already handled by hook
        if self.current_state.get('source') != 'hook':
            self.current_state = parsed
            self.broadcast()

    def on_state_resolved(self):
        """Called when user responds to prompt."""
        self.current_state = {'type': 'idle'}
        self.broadcast()
```

## Implementation Steps

1. **Add terminal capture** via `pipe-pane` or polling `capture-pane`
2. **Implement pattern matchers** for each UI component type
3. **Build state machine** to track current interactive state
4. **Extend WebSocket protocol** with `terminal_ui` message type
5. **Build iOS views** for each component type
6. **Wire up responses** - send user selections back via tmux `send-keys`

## Risks

- **Fragile parsing:** Claude Code's TUI isn't a stable API. UI changes could break pattern matching.
- **Race conditions:** Hook events and terminal updates may arrive out of order.
- **Incomplete detection:** Some edge cases may not match patterns.

## References

- [tmux Control Mode](https://github.com/tmux/tmux/wiki/Control-Mode)
- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks)
- [pyte - Python terminal emulator](https://github.com/selectel/pyte)
