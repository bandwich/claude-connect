# Reliable Session Lifecycle

## Problem

Creating a new session from the iOS app fails silently. The server reports success, but Claude never actually starts. Messages sent by the user go nowhere. Stale state from previous sessions (watcher, permissions, active session tracking) leaks into the new session.

## Core Principle

`handle_new_session` and `handle_resume_session` are the only session lifecycle entry points. Both perform a full state reset before doing anything, and both verify Claude is actually running before reporting success to the app.

## State Reset

When creating or resuming a session, the server resets all session-related state to zero before proceeding:

- `active_session_id` → None
- `active_folder_name` → None
- `transcript_path` → None
- `_pending_session_snapshot` → None
- Transcript handler: clear watched file, reset line count
- Observer: unschedule all watches
- Permission handler: clear any pending permission/question requests
- Stop reconciliation loop if running

This is essentially the existing `reset_for_test` method but applied in production, not just tests.

## Readiness Verification (New Sessions)

After `tmux.start_session()` returns success:

1. Poll the tmux pane (using `pane_parser`) for Claude's ready indicator
2. Poll interval ~0.3s, timeout ~15s (Claude CLI can take a few seconds to boot)
3. **Success:** Claude is ready → proceed with deferred session detection setup, send `session_created` with `success: true`
4. **Failure:** Timeout → kill the tmux session, send `session_created` with `success: false` and an error message the app can display

The app should not navigate to SessionView until it gets a successful `session_created` response.

## Message Flow (New Session)

Once the server confirms Claude is ready:

1. Server saves the session ID snapshot (`_pending_session_snapshot`) for deferred transcript detection
2. App navigates to SessionView
3. User sends first message → server calls `send_to_terminal()`
4. `_resolve_pending_session()` polls for the new `.jsonl` file
5. Once found, `switch_watched_session()` starts the watcher on the new transcript

This flow is unchanged from today — the difference is we've guaranteed Claude is actually running before step 3 happens, so the message won't be lost.

## Resume Flow

Simpler — the transcript file already exists:

1. Full state reset (same as above)
2. `tmux.start_session(resume_id=...)`
3. Poll tmux pane for readiness (same as new session)
4. On success, call `switch_watched_session()` immediately (file exists)
5. Send `session_resumed` with success/failure

## Risk Assessment

**Riskiest assumption:** That we can reliably detect Claude's ready state by polling the tmux pane. The pane parser currently looks for spinners and tool indicators — we'd need to also detect the idle/ready state (Claude waiting for input).

**How to verify:** Start a new `claude` session manually in tmux, capture the pane content, and confirm pane_parser can distinguish "Claude is ready for input" from "tmux started but Claude is still loading."

**Can we verify early?** Yes — this is the first thing to build and test before touching any session lifecycle code.

## Not In Scope

- Resuming a session from the terminal while the app is open (server doesn't know about sessions started outside the app — separate feature)
- Other wishlist bugs (mic stuck, context usage, "No response requested", etc.)
- iOS-side changes beyond handling `success: false` in `session_created`
