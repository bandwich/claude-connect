# Slash Commands UI for iOS App

## Overview

Bring the terminal's slash command autocomplete experience to the iOS app. When the user types `/` as the first character in the text field, a dropdown overlay appears with all available commands, filtering in real-time as they type. Selecting a command inserts it into the text field styled in blue, letting the user append arguments before sending.

## Architecture

### Data Flow

```
Server startup / iOS connect
├─ Server builds command list:
│   ├─ Hardcoded builtins (~50 commands from Claude Code docs)
│   └─ Custom skills scanned from:
│       ├─ ~/.claude/skills/*/SKILL.md (user skills)
│       └─ <project>/.claude/skills/*/SKILL.md (project skills)
├─ Merged list sent to iOS via `commands_list` WebSocket message
└─ iOS stores list in WebSocketManager
```

### Server Side

**New message type: `commands_list`**
```json
{
  "type": "commands_list",
  "commands": [
    {"name": "compact", "description": "Compact conversation with optional focus instructions", "source": "builtin"},
    {"name": "commit", "description": "Commit changes to git", "source": "skill"},
    ...
  ]
}
```

**Sent on:**
- Initial WebSocket connection
- Response to `list_commands` request from iOS

**Command sources:**
1. Hardcoded dict of builtin commands (name + description from Claude Code docs)
2. Dynamic scan of `~/.claude/skills/` — read SKILL.md frontmatter for name + description
3. Dynamic scan of active session's `.claude/skills/` if a session is active

### iOS Side

**WebSocketManager:**
- New published property: `availableCommands: [SlashCommand]`
- Populated when `commands_list` message is received

**SlashCommand model:**
```swift
struct SlashCommand: Identifiable, Codable {
    let name: String
    let description: String
    let source: String  // "builtin" or "skill"
    var id: String { name }
}
```

## UI Design

### Dropdown Overlay

- Triggers when `/` is typed as the first character in the text field
- Floating view anchored above the text field, overlaying the conversation
- Max height ~300pt, scrollable
- Each row: command name (bold) + description (secondary, one line, truncated)
- Top match highlighted in blue (selected state)
- Filters by prefix match on command name as user types after `/`
- Dismisses when:
  - User taps outside the dropdown
  - User deletes the `/`
  - Filtered list is empty
  - User taps a command (after insertion)

### Attributed Text Field

- `UIViewRepresentable` wrapping `UITextView` with `NSAttributedString`
- After selecting a command, the `/commandname` portion renders in blue
- Arguments typed after the command render in default color
- Two-way binding with the existing `messageText` state
- Supports existing interactions: send button, mic button, image attachments, focus state
- Multi-line support (1-5 lines, matching current TextField behavior)

### Interaction Flow

1. User taps text field, types `/`
2. Dropdown appears with full command list, top item highlighted blue
3. User types more characters (e.g., `/com`) — list filters to matching commands
4. User taps a command (e.g., "compact")
5. Dropdown dismisses
6. Text field shows `/compact ` with `/compact` in blue, cursor after the space
7. User optionally types arguments
8. User taps send — entire text sent as normal `user_input` message

## WebSocket Protocol

### iOS -> Server
```json
{"type": "list_commands"}
```

### Server -> iOS
```json
{
  "type": "commands_list",
  "commands": [
    {"name": "compact", "description": "Compact conversation with optional focus instructions", "source": "builtin"},
    ...
  ]
}
```

## Implementation Sequence

### Phase 1: Attributed Text Field (verify risky part first)
- Build `CommandTextField` as `UIViewRepresentable` wrapping `UITextView`
- Support two-way text binding, focus state, blue coloring for `/command` prefix
- Replace existing `TextField` in SessionView input bar
- Verify: typing, editing, coloring, multi-line, send/mic/image buttons all work

### Phase 2: Dropdown Overlay
- Build `CommandDropdownView` — filtered list with blue highlight on top match
- Wire to `CommandTextField` — show/hide based on `/` prefix detection
- Tap to insert command with blue styling

### Phase 3: Server Command List
- Add hardcoded builtin commands dict to server
- Add skill directory scanning (user + project skills)
- Add `commands_list` message type and handler
- Send on connect + on `list_commands` request

### Phase 4: Integration
- Wire `WebSocketManager` to receive and store command list
- Connect dropdown to the stored command list
- End-to-end testing

## Builtin Commands Reference

From Claude Code docs (to be hardcoded on server):

| Command | Description |
|---------|-------------|
| /add-dir | Add a new working directory to the current session |
| /agents | Manage agent configurations |
| /btw | Ask a quick side question without adding to the conversation |
| /chrome | Configure Claude in Chrome settings |
| /clear | Clear conversation history and free up context |
| /color | Set the prompt bar color for the current session |
| /compact | Compact conversation with optional focus instructions |
| /config | Open the Settings interface |
| /context | Visualize current context usage |
| /copy | Copy the last assistant response to clipboard |
| /cost | Show token usage statistics |
| /desktop | Continue the current session in the Desktop app |
| /diff | Open an interactive diff viewer |
| /doctor | Diagnose and verify your installation |
| /effort | Set the model effort level |
| /exit | Exit the CLI |
| /export | Export the current conversation as plain text |
| /extra-usage | Configure extra usage for rate limits |
| /fast | Toggle fast mode |
| /feedback | Submit feedback about Claude Code |
| /branch | Create a branch of the current conversation |
| /help | Show help and available commands |
| /hooks | View hook configurations |
| /ide | Manage IDE integrations |
| /init | Initialize project with a CLAUDE.md guide |
| /insights | Generate a report analyzing your sessions |
| /install-github-app | Set up the Claude GitHub Actions app |
| /install-slack-app | Install the Claude Slack app |
| /keybindings | Open keybindings configuration file |
| /login | Sign in to your Anthropic account |
| /logout | Sign out from your Anthropic account |
| /mcp | Manage MCP server connections |
| /memory | Edit CLAUDE.md memory files |
| /mobile | Show QR code to download the Claude mobile app |
| /model | Select or change the AI model |
| /passes | Share a free week of Claude Code with friends |
| /permissions | View or update permissions |
| /plan | Enter plan mode |
| /plugin | Manage Claude Code plugins |
| /pr-comments | Fetch and display comments from a GitHub PR |
| /privacy-settings | View and update privacy settings |
| /release-notes | View the full changelog |
| /reload-plugins | Reload all active plugins |
| /remote-control | Make session available for remote control |
| /remote-env | Configure the default remote environment |
| /rename | Rename the current session |
| /resume | Resume a conversation by ID or name |
| /review | Deprecated — use code-review plugin |
| /rewind | Rewind conversation to a previous point |
| /sandbox | Toggle sandbox mode |
| /schedule | Create or manage Cloud scheduled tasks |
| /security-review | Analyze pending changes for security vulnerabilities |
| /skills | List available skills |
| /stats | Visualize daily usage and session history |
| /status | Show version, model, account, and connectivity |
| /statusline | Configure the status line |
| /stickers | Order Claude Code stickers |
| /tasks | List and manage background tasks |
| /terminal-setup | Configure terminal keybindings |
| /theme | Change the color theme |
| /upgrade | Open the upgrade page |
| /usage | Show plan usage limits and rate limit status |
| /vim | Toggle between Vim and Normal editing modes |
| /voice | Toggle push-to-talk voice dictation |

Bundled skills: /batch, /claude-api, /debug, /loop, /simplify
