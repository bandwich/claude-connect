# Session List & View Polish — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Fix four session/project list UX issues: hide deleted projects, fix auto-scroll, sort by last message time, show unread indicators.

**Architecture:** Four independent fixes touching different files. Server fixes are in `session_manager.py` and `ios_server.py`. iOS fixes are in `SessionView.swift`, `Session.swift`, and `ProjectDetailView.swift`. No shared dependencies between fixes.

**Tech Stack:** Python (server), Swift/SwiftUI (iOS)

**Risky Assumptions:** The auto-scroll fix (#2) relies on SwiftUI's `ScrollViewReader.scrollTo()` working reliably once `GeometryReader` is removed from wrapping the `ScrollView`. If it still doesn't work, we may need `UIScrollView` bridging or the iOS 17+ `scrollPosition` API. Verify early by testing just the GeometryReader removal + scrollTarget approach before adding the "scroll up" detection.

---

### Task 1: Hide deleted projects

**Files:**
- Modify: `voice_server/session_manager.py:64-97` (list_projects)
- Test: `voice_server/tests/test_session_manager.py`

**Step 1: Write the failing test**

In `voice_server/tests/test_session_manager.py`, add to `TestSessionManager`:

```python
def test_list_projects_excludes_deleted_paths(self, tmp_path):
    """Should not return projects whose decoded path no longer exists on disk"""
    from session_manager import SessionManager

    # Create a project folder whose decoded path does NOT exist
    project_dir = tmp_path / "-Users-test-deleted_project"
    project_dir.mkdir()
    # Write a session with a cwd that doesn't exist
    (project_dir / "session1.jsonl").write_text(json.dumps({
        "type": "system",
        "cwd": "/Users/test/deleted_project"
    }) + "\n" + json.dumps({
        "type": "user",
        "message": {"role": "user", "content": "hello"},
        "timestamp": "2026-01-01T10:00:00Z"
    }))

    # Create a project folder whose decoded path DOES exist
    existing_path = tmp_path / "existing_project"
    existing_path.mkdir()
    project_dir2 = tmp_path / (str(existing_path).replace("/", "-"))
    project_dir2.mkdir()
    (project_dir2 / "session1.jsonl").write_text(json.dumps({
        "type": "system",
        "cwd": str(existing_path)
    }) + "\n" + json.dumps({
        "type": "user",
        "message": {"role": "user", "content": "hello"},
        "timestamp": "2026-01-01T10:00:00Z"
    }))

    manager = SessionManager(projects_dir=str(tmp_path))
    projects = manager.list_projects()

    # Only the existing project should appear
    assert len(projects) == 1
    assert projects[0].path == str(existing_path)
```

**Step 2: Run test to verify it fails**

```bash
cd voice_server/tests && python -m pytest test_session_manager.py::TestSessionManager::test_list_projects_excludes_deleted_paths -v
```

Expected: FAIL — deleted project is still returned.

**Step 3: Implement the fix**

In `voice_server/session_manager.py`, in `list_projects()`, add a path existence check after line 86 (after `decoded_path` is determined). Add the check before the `projects.append(...)` call:

```python
                # Skip projects whose actual directory no longer exists
                if not os.path.exists(decoded_path):
                    continue
```

Insert this line at line 87, just before `name = os.path.basename(decoded_path)`.

**Step 4: Run test to verify it passes**

```bash
cd voice_server/tests && python -m pytest test_session_manager.py::TestSessionManager::test_list_projects_excludes_deleted_paths -v
```

Expected: PASS

**Step 5: Run all session manager tests**

```bash
cd voice_server/tests && python -m pytest test_session_manager.py -v
```

Expected: All pass.

**Step 6: Commit**

```bash
cd /Users/aaron/Desktop/max && git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "fix: hide projects whose directory no longer exists"
```

---

### Task 2: Sort sessions by last message timestamp

**Files:**
- Modify: `voice_server/session_manager.py:225-313` (list_sessions, _parse_session_file)
- Test: `voice_server/tests/test_session_manager.py`

**Step 1: Write the failing test**

This test creates two sessions where file mtime order differs from message timestamp order, and verifies sessions are sorted by message timestamp.

```python
def test_list_sessions_sorted_by_message_timestamp_not_mtime(self, tmp_path):
    """Sessions should be sorted by last message timestamp, not file mtime"""
    from session_manager import SessionManager

    project_dir = tmp_path / "-Users-test-myproject"
    project_dir.mkdir()

    # Session A: old file mtime, but NEWER message timestamp
    session_a = project_dir / "aaa111.jsonl"
    session_a.write_text(json.dumps({
        "type": "user",
        "message": {"role": "user", "content": "Session A"},
        "timestamp": "2026-03-20T12:00:00Z"
    }))

    # Session B: new file mtime, but OLDER message timestamp
    session_b = project_dir / "bbb222.jsonl"
    session_b.write_text(json.dumps({
        "type": "user",
        "message": {"role": "user", "content": "Session B"},
        "timestamp": "2026-03-10T12:00:00Z"
    }))

    # Set file mtimes: B is newer on disk than A
    os.utime(session_a, (time.time() - 200, time.time() - 200))
    os.utime(session_b, (time.time(), time.time()))

    manager = SessionManager(projects_dir=str(tmp_path))
    sessions = manager.list_sessions("-Users-test-myproject")

    assert len(sessions) == 2
    # Session A should be first (newer message timestamp) despite older file mtime
    assert sessions[0].id == "aaa111"
    assert sessions[1].id == "bbb222"
```

**Step 2: Run test to verify it fails**

```bash
cd voice_server/tests && python -m pytest test_session_manager.py::TestSessionManager::test_list_sessions_sorted_by_message_timestamp_not_mtime -v
```

Expected: FAIL — bbb222 is first because it has a newer file mtime.

**Step 3: Implement the fix**

Two changes in `voice_server/session_manager.py`:

**3a.** In `_parse_session_file()`, parse the actual timestamp from JSONL entries.

Currently line 282 sets `last_timestamp = os.path.getmtime(filepath)` and never updates it. Add timestamp extraction inside the loop. After `message_count += 1` (line 293), add:

```python
                            # Track last message timestamp
                            entry_ts = entry.get('timestamp', '')
                            if entry_ts:
                                try:
                                    parsed = datetime.fromisoformat(entry_ts.replace('Z', '+00:00')).timestamp()
                                    last_timestamp = parsed
                                except Exception:
                                    pass
```

Also add `from datetime import datetime` at the top of `session_manager.py` (with the other imports, around line 7).

**3b.** In `list_sessions()`, change from pre-sorting files by mtime to post-sorting Session objects by timestamp. Replace the current approach:

Remove the mtime sort (line 241: `session_files.sort(key=os.path.getmtime, reverse=True)`).

Remove the early-break limit (lines 258-260), since we need to parse all files to sort correctly.

After the for loop, sort and slice:

```python
        sessions.sort(key=lambda s: s.timestamp, reverse=True)
        return sessions[:limit]
```

**Step 4: Run test to verify it passes**

```bash
cd voice_server/tests && python -m pytest test_session_manager.py::TestSessionManager::test_list_sessions_sorted_by_message_timestamp_not_mtime -v
```

Expected: PASS

**Step 5: Run all session manager tests**

```bash
cd voice_server/tests && python -m pytest test_session_manager.py -v
```

Expected: All pass. The existing `test_list_sessions_returns_sessions_sorted_by_time` test may need updating — it currently relies on file mtime ordering. Check if it passes; if not, update it to set message timestamps that match the intended order.

**Step 6: Commit**

```bash
cd /Users/aaron/Desktop/max && git add voice_server/session_manager.py voice_server/tests/test_session_manager.py
git commit -m "fix: sort sessions by last message timestamp instead of file mtime"
```

---

### Task 3: Fix auto-scroll in SessionView

**Files:**
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`

This is an iOS-only change. No automated tests — SwiftUI scroll behavior can only be verified on device.

**Manual verification (REQUIRED before commit):**
1. Open a session, send a message — new messages should auto-scroll into view
2. Wait for tool results (they update in-place) — view should scroll to show updated content
3. Activity indicator (thinking/tool) — should scroll into view
4. Scroll up during a conversation — new messages should NOT pull you back down
5. When scrolled up and new content arrives, a down-arrow button should appear at bottom edge
6. Tap the down-arrow — should scroll to bottom and dismiss the button
7. When already at the bottom, no down-arrow should appear

**Step 1: Remove GeometryReader wrapping ScrollView**

In `SessionView.swift`, the current structure is:
```
ScrollViewReader { proxy in
    GeometryReader { geometry in
        ScrollView { ... }
            .frame(maxWidth: geometry.size.width)
    }
}
```

`GeometryReader` is only used for `geometry.size.width` on the inner VStack's `.frame()`. Remove `GeometryReader` and the `.frame(maxWidth:)` modifier — the parent `VStack(spacing: 0)` already constrains width. The structure becomes:

```
ScrollViewReader { proxy in
    ScrollView(.vertical, showsIndicators: true) {
        VStack(alignment: .leading, spacing: 12) {
            // ... ForEach items ...
            // ... activity indicator ...
        }
        .padding()
    }
    .contentMargins(.bottom, 20, for: .scrollContent)
    // ... onChange handlers ...
}
```

**Step 2: Add scroll tracking state**

Add these `@State` properties to `SessionView`:

```swift
@State private var scrollTrigger: Int = 0  // Incremented to trigger scroll
@State private var isNearBottom: Bool = true  // Track if user is near bottom
@State private var hasNewContent: Bool = false  // Show scroll-down button
```

**Step 3: Add bottom detection**

Add an invisible anchor view at the bottom of the VStack (after the activity indicator), and use a `GeometryReader` overlay on it to detect when it's visible:

```swift
// Bottom anchor for scroll detection
Color.clear
    .frame(height: 1)
    .id("bottom-anchor")
    .onAppear { isNearBottom = true; hasNewContent = false }
    .onDisappear { isNearBottom = false }
```

**Step 4: Replace scroll triggers**

Remove the existing two `.onChange` handlers (lines 104-124). Replace with a single handler:

```swift
.onChange(of: scrollTrigger) { _, _ in
    guard isNearBottom else {
        hasNewContent = true
        return
    }
    if isInitialLoad {
        isInitialLoad = false
        proxy.scrollTo("bottom-anchor", anchor: .bottom)
    } else {
        withAnimation {
            proxy.scrollTo("bottom-anchor", anchor: .bottom)
        }
    }
}
```

**Step 5: Fire scroll trigger on content changes**

Find all places in SessionView where items are modified and increment `scrollTrigger` after each:

1. **New item appended** — after every `items.append(...)` call, add `scrollTrigger += 1`
2. **Tool result updated in-place** — after the existing code that finds and updates a tool result (around line 662-664), add `scrollTrigger += 1`
3. **Activity state changes** — add a new `.onChange(of: webSocketManager.activityState)` that does `scrollTrigger += 1` when state is non-idle
4. **Initial history load** — after items are populated from session history, set `scrollTrigger += 1`

**Step 6: Add scroll-to-bottom button overlay**

Wrap the `ScrollViewReader` in a `ZStack` and add the down-arrow button:

```swift
ZStack(alignment: .bottom) {
    ScrollViewReader { proxy in
        // ... existing ScrollView ...
    }

    if hasNewContent && !isNearBottom {
        Button(action: {
            hasNewContent = false
            // scrollTrigger won't work here since we need to force scroll
            // Use a notification or just set isNearBottom and trigger
            isNearBottom = true
            scrollTrigger += 1
        }) {
            Image(systemName: "chevron.down.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(.white, .blue)
                .shadow(radius: 4)
        }
        .padding(.bottom, 8)
        .transition(.scale.combined(with: .opacity))
    }
}
```

Note: The button needs access to `proxy` from `ScrollViewReader`. Move the ZStack inside the ScrollViewReader, or use a different approach: store `proxy` in a binding/state, or move the button inside the ScrollViewReader but outside the ScrollView using an overlay. The cleanest approach:

```swift
ScrollViewReader { proxy in
    ZStack(alignment: .bottom) {
        ScrollView(.vertical, showsIndicators: true) {
            // ... content ...
        }
        .contentMargins(.bottom, 20, for: .scrollContent)

        if hasNewContent && !isNearBottom {
            Button(action: {
                hasNewContent = false
                withAnimation {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }) {
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(.white, .blue)
                    .shadow(radius: 4)
            }
            .padding(.bottom, 8)
            .transition(.scale.combined(with: .opacity))
        }
    }
    .onChange(of: scrollTrigger) { ... }
}
```

**Step 7: Deploy for verification**

Reinstall server (for Tasks 1-2 changes) and build + install iOS on device:

```bash
cd /Users/aaron/Desktop/max && pipx install --force .
cd ios-voice-app/ClaudeVoice && xcodebuild -target ClaudeVoice -sdk iphoneos build
xcrun devicectl list devices
xcrun devicectl device install app --device "<DEVICE_ID>" ios-voice-app/ClaudeVoice/build/Release-iphoneos/ClaudeVoice.app
```

**CHECKPOINT:** Run through manual verification steps above on the physical device. If auto-scroll doesn't work, debug the `onAppear`/`onDisappear` detection — the `Color.clear.frame(height: 1)` trick can be unreliable. Alternative: use `ScrollView` with `.onScrollGeometryChange` (iOS 18+) or a `PreferenceKey` approach to track scroll offset.

**Step 8: Commit**

```bash
cd /Users/aaron/Desktop/max && git add ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift
git commit -m "fix: auto-scroll session view on new messages with scroll-to-bottom button"
```

---

### Task 4: Unread message indicators

**Approach: Pure iOS-side tracking.** The server doesn't know what screen the user is on. The iOS app does. Track unread state entirely in the app.

**Files:**
- Revert: `voice_server/ios_server.py` (remove all server-side unread tracking added previously)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Models/Session.swift` (remove hasUnread, simplify back)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Services/WebSocketManager.swift` (add unreadSessionIds set)
- Modify: `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectDetailView.swift` (blue dot from unreadSessionIds)

**How it works:**
1. WebSocketManager has `@Published var unreadSessionIds: Set<String>`
2. When `assistant_response` arrives with a `session_id` that != the currently viewed session → add to set
3. When user taps into a session (selectedSession changes in ProjectDetailView) → remove from set
4. ProjectDetailView checks `webSocketManager.unreadSessionIds.contains(session.id)` for blue dot
5. Blue dot replaces green dot (not both shown)

**Step 1: Revert server-side tracking**

Remove from `voice_server/ios_server.py`:
- `self.session_last_seen_lines` dict from `__init__`
- `_record_last_seen()` method
- `has_unread()` function and `"has_unread"` key from list_sessions response
- All `_record_last_seen()` calls in handle_get_session, handle_view_session, handle_resume_session, handle_open_session
- The `session_last_seen_lines` update in TranscriptHandler.on_modified

**Step 2: Simplify Session model**

Remove `hasUnread` from Session.swift. Revert to simple struct with just id, title, timestamp, messageCount. Remove the custom `init(from decoder:)` and memberwise init that were added for hasUnread.

**Step 3: Add unreadSessionIds to WebSocketManager**

```swift
@Published var unreadSessionIds: Set<String> = []
```

In the `assistant_response` handler (where session_id is available): if session_id is non-empty and != the session the user is currently viewing, insert into unreadSessionIds.

The "currently viewed session" is already tracked — the app sends `view_session` or `get_session` when entering a session. WebSocketManager can track this with a simple `var viewedSessionId: String?` property, set when view_session/get_session is sent, cleared when navigating back.

**Step 4: Clear unread on session tap**

In ProjectDetailView's `SessionsContentView`, when `selectedSession` changes to a non-nil session, remove that session's ID from `unreadSessionIds`.

**Step 5: Update blue dot in ProjectDetailView**

Replace `session.hasUnread` with `webSocketManager.unreadSessionIds.contains(session.id)`:

```swift
if webSocketManager.unreadSessionIds.contains(session.id) {
    Circle()
        .fill(Color.blue)
        .frame(width: 8, height: 8)
        .padding(.leading, 4)
} else if webSocketManager.activeSessionIds.contains(session.id) {
    Circle()
        .fill(Color.green)
        .frame(width: 8, height: 8)
        .padding(.leading, 4)
}
```

**Step 6: Run server tests**

```bash
cd voice_server/tests && ./run_tests.sh
```

**Step 7: Build and deploy iOS**

```bash
cd ios-voice-app/ClaudeVoice && xcodebuild -target ClaudeVoice -sdk iphoneos build
xcrun devicectl device install app --device "<DEVICE_ID>" ios-voice-app/ClaudeVoice/build/Release-iphoneos/ClaudeVoice.app
```

**Step 8: Manual verification**

1. Open a project with an active session, send a message
2. Go back to session list while Claude is responding → blue dot should appear
3. Tap into the session → blue dot should clear on next list view
4. Active session with no new messages → green dot (not blue)

**Step 9: Commit**

```bash
cd /Users/aaron/Desktop/max && git add -A
git commit -m "feat: show blue dot for sessions with unread messages"
```
