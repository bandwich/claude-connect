# iOS App (ClaudeConnect)

## Architecture

WebSocketManager is the single state hub. Views bind via `@ObservedObject` and set callbacks in `onAppear`. No direct method calls between views — all communication flows through published state changes and callbacks.

## WebSocketManager — Central State

**Published properties that drive the UI:**
- `connectionState` — disconnected/connecting/connected/error
- `voiceState` — idle/listening/processing/speaking (tracks user input state)
- `outputState` — idle/thinking/usingTool/speaking (tracks Claude's activity)
- `inputBarMode` — what the input bar shows (see state machine below)
- `pendingPermission` — current permission request awaiting user decision
- `activityState` — tmux pane activity from server (thinking/tool_active/waiting_permission + detail)
- `activeSessionIds` — list of all active session IDs (for green dots + filtering)
- `unreadSessionIds` — sessions with unread messages (for blue dots)
- `currentlyViewingSessionId` — which session the user is viewing (plain var, not @Published — set by SessionView onAppear/onDisappear)
- `contextStats` — token usage percentage
- `lastReceivedSeq` — last transcript line number for gap detection
- `isPlayingAudio` — true while AudioPlayer is streaming (plain var, not @Published — updated by AudioPlayer callbacks)

**Message routing**: `handleMessage()` tries decoding in priority order — `AssistantResponseMessage` first (structured content), then `StatusMessage`, then specialized types. This ensures content blocks take precedence over simple status updates.

**Callbacks**: `onAssistantResponse`, `onUserMessage`, `onPermissionRequest`, `onPermissionResolved`, `onDeliveryStatus`, `onActivityStatus`, `onTaskCompleted`, `onSessionHistoryReceived`, `onResyncReceived`, `onContextUpdate`, `onUsageUpdate`, plus project/session listing callbacks.

## Input Bar State Machine

`InputBarMode` controls the input area:

| Mode | Shows | Transitions |
|------|-------|-------------|
| `.normal` | Text field + mic + send | Default state |
| `.permissionPrompt(request)` | Approve/deny buttons + suggestions | On permission_request from server |
| `.questionPrompt(prompt)` | Option buttons or text input | On question_prompt from server |
| `.syncing` | Loading spinner | During resync |
| `.disconnected` | Reconnecting indicator | On connection loss |

Prompts auto-dismiss after 180 seconds (soft timeout). Late responses can still be injected by the server's post_tool_hook.

## Conversation Items

`ConversationItem` enum in Session.swift:
- `.textMessage` — user or assistant text
- `.toolUse` — paired tool_use + tool_result (matched by tool ID)
- `.agentGroup` — 2+ consecutive Agent tool_uses merged into status cards
- `.permissionPrompt` — resolved permission shown inline

**Agent grouping**: `groupAgentItems()` runs on history load and resync. During live streaming, new Agent tool_uses are also actively merged — appended to an existing `.agentGroup` or two consecutive Agent `.toolUse` items are combined into a group.

**Stale tool detection**: When a new tool_use arrives, any previous tool_use without a matching result is marked stale (`content: "(result not available)"`). Agent tools are excluded from stale marking. Handles app reinstalls mid-execution.

## Sequence-Based Dedup

- Server attaches `seq` (transcript line number) to every message
- SessionView tracks `lastProcessedSeq` — skips any message with seq ≤ this value
- On reconnect: `requestResync()` (no params — reads `lastReceivedSeq` internally, sends type `"resync"`) → server sends all messages after that seq
- Resync dedup happens at message level, not block level

## Multi-Session Support

- Sessions list shows green dots for active sessions (via `activeSessionIds` from server), blue dots for unread sessions (via `unreadSessionIds`)
- Tapping an active session sends `view_session` (switch view, no kill); tapping inactive sends `resume_session`
- SessionView has an ellipsis menu with "Stop Session" (sends `stop_session`)
- Back button navigates away without stopping the session
- Permission/question prompts are filtered by `session_id` — only shown if they match the viewed session (nil/empty passes through for backward compatibility)

## Session ID Adoption

New sessions don't have an ID when created — the server creates the tmux session before Claude generates a transcript file. SessionView adopts the ID from the first `assistant_response` message received. `isSessionSynced` handles this: for new sessions, checks `activeSessionIds.contains()` rather than requiring an exact match.

## Connection & Reconnection

- TCP pre-check via NWConnection before WebSocket attempt (fail fast if server unreachable)
- URLSession config: 90s request timeout (must exceed server's 30s ping interval), unlimited resource timeout
- Reconnection: exponential backoff (2^attempt, max 30s), 5 attempts background / 3 foreground
- App foreground return triggers `reconnectIfNeeded()` — checks if WebSocket is still alive

## Audio Pipeline

**TTS Playback (AudioPlayer):**
- Server streams `audio_chunk` messages with base64 WAV data
- AudioPlayer buffers chunks, waits for 3 before starting playback (smooth streaming)
- Converts 16-bit PCM to float32, schedules on AVAudioPlayerNode
- On new message (chunkIndex == 0): interrupts current playback, 500ms pause, then restarts
- `isPlayingAudio` prevents `voiceState` from resetting to idle while audio is still playing — server sends `status: idle` when done processing, but UI keeps showing "speaking" until last chunk finishes

**Speech Recognition (SpeechRecognizer):**
- Wraps SFSpeechRecognizer with partial/final transcription callbacks
- Partial results update the text field live as user speaks
- Final result triggers send, text field clears

## SessionView — The Main View

Largest component (~800+ lines). Manages:
- Conversation rendering (ScrollView of ConversationItems)
- Real-time callback chain: onAssistantResponse → seq dedup → parse blocks → append items
- Echo suppression: `lastVoiceInputText` filters server echo of locally-shown voice input
- Scroll: auto-scrolls to bottom on initial load, keyboard appear, and when new messages arrive (if user is near bottom). Scroll-to-bottom button (chevron) appears in bottom-right when user scrolls up, detected via `onScrollGeometryChange` (dist threshold 400). Tracking is delayed 1s after initial load to avoid false triggers.
- Activity indicator with interrupt button
- Permission resolution cards (`permissionResolutions` dictionary)
- Image attachments for messages

## Navigation

NavigationStack from ClaudeConnectApp.swift (not ContentView — ContentView is a standalone voice-only view):
- `ProjectsListView` → `ProjectDetailView` (tabs: Sessions / Files)
  - Sessions tab → `SessionView` (inline in ProjectDetailView)
  - Files tab → `FilesView` (lazy-loaded directories) → `FileView` (text + images with caching)
- `SettingsView` — connection settings + usage stats
- `QRScannerView` — camera-based QR code scanner for connection

## Key Conventions

- `voiceState` ≠ `outputState`: voiceState tracks user input (listening/speaking), outputState tracks Claude's work (thinking/tool). Both affect UI independently
- Context percentage is inverted for display: server sends % used, UI shows 100 - % as "remaining"
- ToolSearch tool results are never displayed (filtered)
- Tool results for Bash are collapsed by default (expandable) — collapsed state shows a content preview (first 3 lines, truncated with "… +N lines"), "Running in background" for background commands (updates to "Done" when server sends `task_completed`), "Done" for empty output, or "Error — tap to show" for errors. Preview logic lives in `BashPreview` enum (ToolUseView.swift). Task, Read, Edit, Grep, Glob, AskUserQuestion, ToolSearch results are fully hidden (show "Done" checkmark, not expandable)
- `@AppStorage` for persistent settings: ttsEnabled, serverIP, serverPort
- All delegate callbacks on main thread (URLSession delegateQueue: .main)
