# Real-Time Activity Status + Interrupt

## Goal
Show the user what Claude is doing in real-time (thinking, using tools, idle) with a status indicator below the last message, and let them interrupt via a stop button.

## Step 1: Verify Terminal Status Indicators
Before writing any parsing code, capture real tmux pane output in every Claude state to document the exact format.

- Start a Claude session in tmux
- Send a prompt that triggers thinking + tool use
- Capture pane output during: thinking, tool use (Read, Bash, Grep, etc.), text generation, idle/waiting
- Document both status indicators (there appear to be two: one with thinking duration/tokens, one with current action)
- Save example captures as test fixtures

**Verify:** What exactly do the two status lines look like? What characters/unicode are used? What's the exact format?

## Step 2: Server — Pane Status Parser
New file: `voice_server/pane_parser.py`

- Parse captured pane text into activity state
- States: `thinking`, `tool_active`, `idle`
- Extract detail text (e.g., "Reading 3 files...", "Searching for patterns...")
- Unit tests with real captured pane fixtures from Step 1

## Step 3: Server — Polling Loop
In `ios_server.py`:

- Add async polling loop that runs every ~1s when a session is active
- Calls `tmux capture_pane()` → `pane_parser.parse()`
- Only sends `activity_status` WebSocket message when state **changes**
- Starts on `send_input()`, stops when idle is stable for a few seconds
- Message: `{"type": "activity_status", "state": "thinking|tool_active|idle", "detail": "..."}`

## Step 4: Server — Interrupt Handler
- New WebSocket message type: `interrupt` (iOS → Server)
- On receive: call `TmuxController.send_escape()`
- Add `send_escape()` to `TmuxController` — `tmux send-keys -t claude_voice Escape`

## Step 5: iOS — WebSocket + State
In `WebSocketManager.swift`:

- Handle `activity_status` message type
- New `@Published var activityState` property (or adapt existing `outputState`)
- New `sendInterrupt()` method sends `{"type": "interrupt"}`

## Step 6: iOS — Status Indicator UI
In `SessionView.swift`:

- New view below last message in conversation scroll: spinner + status text + stop button
- Only visible when activity state is `thinking` or `tool_active`
- Stop button calls `sendInterrupt()`
- Auto-scroll to keep status visible

## Scope Boundary
- No changes to transcript parsing, hooks, or TTS flow
- No live timer (just state + detail text)
- Polling only when session is active
