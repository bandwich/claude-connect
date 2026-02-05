# UI Header Fixes Design

## Problem

Three headers in the iOS app have broken layouts:

1. **Projects header** - Title and gear icon centered together instead of title left / gear right
2. **Sessions header** - Breadcrumb shows "/" and "s" on separate lines instead of "/projectname"
3. **Session chat header** - Completely broken with overlapping text, truncated breadcrumb, mispositioned context % and branch indicators

## Root Cause

These headers were working previously and regressed. The fix likely exists in git history.

## Target Layouts

### Projects Header
```
┌─────────────────────────────────────┐
│ Projects                        ⚙️  │
└─────────────────────────────────────┘
```
- "Projects" left-aligned
- Gear icon (filled) far right

### Sessions Header
```
┌─────────────────────────────────────┐
│ ‹  /max                         ⚙️  │
│                                     │
│   ┌─────────────┬─────────────┐    │
│   │  Sessions   │    Files    │    │
│   └─────────────┴─────────────┘    │
└─────────────────────────────────────┘
```
- Back chevron + breadcrumb "/projectname" on left
- Gear icon far right
- Sessions/Files tab bar unchanged

### Session Chat Header
```
┌─────────────────────────────────────┐
│ ‹ test kit removal      ●67%  ⎇main │
└─────────────────────────────────────┘
```
- Back chevron + session title (truncates with "...")
- Context indicator: colored dot (green >50%, yellow 20-50%, red <20%) + percentage
- Branch indicator: branch icon + name (truncates if needed)

## Design Decisions

- Keep gear icon filled (`gearshape.fill`)
- Keep Sessions/Files tab bar styling as-is
- Keep context percentage indicator in Session chat header

## Implementation Approach

1. Search git history for when headers were working correctly
2. Identify the commit(s) that broke them
3. Restore the working code rather than rewriting from scratch
4. Test on device after applying fix

## Files Likely Involved

- `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectsListView.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionsListView.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/SessionView.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/ProjectDetailView.swift`
- `ios-voice-app/ClaudeVoice/ClaudeVoice/Views/CustomNavigationBar.swift`

## Verification

- Build and install on device
- Check all three screens match target layouts
- Verify context % and branch indicators display correctly in Session chat
