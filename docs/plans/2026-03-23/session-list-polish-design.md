# Session List & View Polish

Four independent fixes for session/project list UX issues.

## 1. Hide Deleted Projects

**Problem:** `list_projects()` in `session_manager.py` scans `~/.claude/projects/` and decodes folder names back to paths, but never checks if the original path still exists. Deleted projects keep showing.

**Fix:** After decoding the path, add `os.path.exists(decoded_path)` check. Skip if missing.

**Files:** `voice_server/session_manager.py` (list_projects)

## 2. Fix Auto-Scroll in Session View

**Problem:** SessionView uses `onChange(of: items.count)` + `ScrollViewReader.scrollTo()` inside `GeometryReader`. Auto-scroll is completely broken — new messages appear below the viewport and the user must scroll manually.

**Root causes:**
- Tool result updates modify items in-place (no count change, no trigger)
- `GeometryReader` wrapping `ScrollView` interferes with scroll behavior
- Activity state changes don't always trigger scroll

**Fix:**
- Track a `scrollTarget` state variable (UUID or counter). Update it on: new items appended, tool results updated in-place, activity state changes, initial load.
- Single `.onChange(of: scrollTarget)` calls `proxy.scrollTo()` on the last item or activity indicator.
- Move `GeometryReader` inside scroll content or remove it (use parent frame for maxWidth).
- Track whether user has scrolled up (`isUserScrolledUp`). If scrolled up, don't auto-scroll — instead show a down-arrow icon button at the bottom edge. Tapping it scrolls to bottom and dismisses. No text, just the icon.

**Files:** `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

## 3. Sort Sessions by Last Message Timestamp

**Problem:** `list_sessions()` sorts by `os.path.getmtime()` (file modification time), not by the actual last message timestamp. The timestamp is already parsed from each session file but only used for display.

**Fix:** Sort sessions by the parsed `timestamp` field (last message time) instead of file mtime.

**Files:** `voice_server/session_manager.py` (list_sessions)

## 4. Unread Message Indicators

**Problem:** With parallel sessions, there's no way to tell which sessions have new messages without opening them.

**Fix:**

Server side (`ios_server.py`):
- Track `last_seen_seq` per session in `SessionContext` (or a dict on VoiceServer). Set it when iOS sends `view_session` or `open_session` to the current message count/seq.
- Include `has_unread: bool` in each session object in `sessions_list` responses.
- Broadcast updated `sessions_list` when a non-viewed session gets new messages (so the list refreshes live).

iOS side:
- Add `hasUnread: Bool` to `Session` model (`Session.swift`).
- Show a blue dot next to sessions with `hasUnread == true` in the session list (`ProjectDetailView.swift`).
- Viewing a session sends `view_session`, server clears unread — next `sessions_list` broadcast reflects this.

**Files:** `voice_server/ios_server.py`, `voice_server/session_context.py`, `ios-voice-app/.../Session.swift`, `ios-voice-app/.../ProjectDetailView.swift`

## Testing

### Server tests (Python)
- `list_projects()` excludes projects whose decoded path doesn't exist
- `list_sessions()` returns sessions sorted by last message timestamp, not file mtime
- `sessions_list` response includes `has_unread`, `view_session` clears unread state

### iOS (manual on device)
- Deleted project disappears from project list
- Messages auto-scroll throughout a session; scrolling up shows down-arrow button on new content; tapping it scrolls to bottom
- Sending a message in an older session moves it to top of list
- Two active sessions: messages in non-viewed session show blue dot in session list
