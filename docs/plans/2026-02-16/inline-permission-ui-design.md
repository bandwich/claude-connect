# Inline Permission UI Design

## Goal

Replace the full-screen modal permission sheet with an inline conversation card that matches the terminal's permission prompt layout and options.

## Current State

- Permission prompts show as a full-height `.sheet()` modal with generic Allow/Deny buttons
- The terminal shows structured info: type label, command/content, description, and numbered options including "don't ask again" variants
- The server strips `permission_suggestions` from the Claude Code hook payload

## Design Decisions

- **Inline in conversation**: Permission card appears in the scroll view, not as a modal
- **Match terminal layout**: Type label (colored), command in monospace, description, numbered options
- **Single-tap interaction**: Tap an option to immediately send the response
- **Collapse after response**: Card shrinks to a single-line summary (e.g. "Allowed: `python3 -c ...`")
- **Full "always allow" support**: Forward `permission_suggestions` from Claude Code and send `updatedPermissions` back
- **Server as pass-through**: No option generation logic on server, just relay data

## Data Flow

```
Claude Code hook stdin → Server (http_server.py) → WebSocket → iOS app
                                                                ↓
Claude Code hook stdout ← Server ← WebSocket ← iOS permission response
```

New fields forwarded:
- To iOS: `permission_suggestions` array from hook payload
- From iOS: `updatedPermissions` in response (for "don't ask again" rules)

## Card Layout

### Pending State (bash example)

```
┌─────────────────────────────────────┐
│ Bash command                        │  ← colored type label
│                                     │
│   python3 -c "print('hello')"      │  ← monospace, dark bg
│   Test permission flow again        │  ← description (secondary)
│                                     │
│ Do you want to proceed?             │
│                                     │
│  1. Yes                             │  ← tappable
│  2. Yes, and don't ask again for    │  ← tappable (from permission_suggestions)
│     python3 commands in /project    │
│  3. No                              │  ← tappable
└─────────────────────────────────────┘
```

### Resolved State (collapsed)

```
┌─────────────────────────────────────┐
│ ✓ Allowed: `python3 -c "print(…)"` │
└─────────────────────────────────────┘
```

## Changes Required

### Phase 0: Verify payload format
- Add logging to permission hook to inspect `permission_suggestions` structure
- Trigger a bash permission prompt and capture the payload

### Phase 1: Server changes (http_server.py)
- Forward `permission_suggestions` from hook payload to iOS WebSocket message
- Accept `updatedPermissions` in iOS response, include in hook output

### Phase 2: iOS model changes (PermissionRequest.swift)
- Add `PermissionSuggestion` struct
- Add `permissionSuggestions` to `PermissionRequest`
- Add `updatedPermissions` to `PermissionResponse`

### Phase 3: New ConversationItem case (Session.swift)
- Add `.permissionPrompt` case to `ConversationItem` enum

### Phase 4: New inline view (PermissionCardView.swift)
- Terminal-matching layout for all prompt types
- Single-tap option selection
- Collapse to summary after response

### Phase 5: SessionView integration
- Remove `.sheet()` for permissions
- Append `.permissionPrompt` items to conversation
- Handle response callbacks and collapse

### Phase 6: Cleanup
- Remove `PermissionPromptView.swift` (replaced by inline card)

## Verified Payload Format

`permission_suggestions` from Claude Code (confirmed via live testing):

```json
{
  "permission_suggestions": [
    {
      "type": "addRules",
      "rules": [
        {"toolName": "Bash", "ruleContent": "tmux kill-session:*"},
        {"toolName": "Bash", "ruleContent": "tmux new-session:*"}
      ],
      "behavior": "allow",
      "destination": "localSettings"
    }
  ]
}
```

- `type`: always `"addRules"`
- `rules`: array of `{toolName, ruleContent}` — ruleContent is the human-readable pattern
- `behavior`: `"allow"`
- `destination`: `"localSettings"` (project-level) or `"session"` (session-only)

To send "always allow" back, the hook response format is:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow",
      "updatedPermissions": [<the permission_suggestions item>]
    }
  }
}
```

### Option Text Generation

Each suggestion becomes a tappable option. The display text is derived from `ruleContent`:
- `"tmux kill-session:*"` → "Yes, and don't ask again for `tmux kill-session` commands"
- Multiple rules in one suggestion → combine them

The full options list for a bash prompt:
1. "Yes" (plain allow)
2. One entry per `permission_suggestions` item (always-allow variants)
3. "No" (deny)
