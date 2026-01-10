# UI Overhaul Design

Replace three iOS screens (Projects, Sessions, Session) with new cleaner design while keeping existing functionality.

## Projects Screen

**Layout:**
- Title "Projects" top-left
- Settings gear icon top-right (keep existing)
- Remove folder.badge.plus from toolbar
- Each row: Project name (bold), path below (gray), session count as plain number on right
- Floating "+" button bottom-right corner (folder icon inside, outlined style)

**Disconnected state:** Keep existing wifi.slash + "Open Settings" flow

## Sessions Screen

**Layout:**
- "/projectname" small text above "Sessions" title
- Settings gear icon top-right
- Remove "+" from toolbar
- Each row:
  - Session title (bold)
  - "X messages" below (gray)
  - Relative time on right
- Remove green checkmark active indicator
- Floating "+" button bottom-right corner (circled plus, outlined style)

**Relative time format:**
- < 1 min: "X seconds ago"
- < 1 hour: "X minutes ago"
- < 24 hours: "X hours ago"
- Otherwise: "Yesterday" or date

## Session Screen

**Header:**
- Back chevron + session title (left)
- Git branch icon + placeholder text (right) - actual branch detection later
- Remove settings gear
- Remove sync checkmark indicator

**Messages:**
- User: "‹" prefix, left-aligned, no background
- Assistant: Gray rounded card background
- Permission messages: Use assistant card style

**Bottom area:**
- Mic icon centered
- No status text
- No text input field
- Proper scroll separation from messages

**Error state:**
- Hide mic when error occurs
- Show red icon + error message in mic's place

## Implementation Order

1. ProjectsListView - establish floating button pattern
2. SessionsListView - apply pattern + relative time
3. SessionView - new message styling + simplified bottom area
