# Fix Usage Checker: Replace tmux Approach with Direct API Call

## Problem

The usage checker spawns a Claude Code instance in tmux, sends `/usage`, and parses terminal output. This broke because `/usage` now renders as a TUI modal dialog that `tmux capture-pane` cannot capture. Result: timeouts, 0% for all categories.

## Solution

Replace the entire tmux-based approach with a direct HTTP call to `https://api.anthropic.com/api/oauth/usage`.

### API Details

**Endpoint:** `GET https://api.anthropic.com/api/oauth/usage`

**Auth:** Bearer token from macOS Keychain (`Claude Code-credentials` → `claudeAiOauth.accessToken`)

**Headers:**
- `Authorization: Bearer <token>`
- `anthropic-beta: oauth-2025-04-20`

**Response:**
```json
{
  "five_hour": {"utilization": 9.0, "resets_at": "2026-03-03T23:00:00+00:00"},
  "seven_day": {"utilization": 19.0, "resets_at": "2026-03-06T19:00:00+00:00"},
  "seven_day_sonnet": {"utilization": 0.0, "resets_at": "2026-03-07T21:00:00+00:00"},
  "extra_usage": {"is_enabled": true, "monthly_limit": 2000, "used_credits": 0.0}
}
```

### Field Mapping

| API field | Mapped to | iOS label |
|-----------|-----------|-----------|
| `five_hour.utilization` | `session.percentage` | Session |
| `seven_day.utilization` | `week_all_models.percentage` | Week (All Models) |
| `seven_day_sonnet.utilization` | `week_sonnet_only.percentage` | Week (Sonnet) |
| `*.resets_at` | `*.resets_at` + `*.timezone` | Reset time |

## Changes

### 1. Rewrite `voice_server/usage_checker.py`

Remove all tmux logic. New implementation:

- `_get_oauth_token()`: Run `security find-generic-password -s "Claude Code-credentials" -w`, parse JSON, extract `claudeAiOauth.accessToken`. Check `expiresAt` — if expired, return error.
- `check_usage()`: Use `aiohttp` (already available) or `urllib` to GET the endpoint. Parse JSON response. Map fields to existing structure. Cache result.
- Remove `_capture_pane()`, `_wait_for_content()`, `_wait_for_ready()` — all tmux helpers gone.

### 2. Delete or gut `voice_server/usage_parser.py`

Terminal output parsing is no longer needed. Either:
- Delete the file entirely and put the trivial JSON mapping in `usage_checker.py`
- Or keep it with a simple `parse_api_response(data: dict) -> dict` function

### 3. Update tests

- Update `voice_server/tests/` for the new implementation
- Mock the keychain call and HTTP request instead of tmux

### 4. No iOS changes

The response shape (`session`, `week_all_models`, `week_sonnet_only` with `percentage`, `resets_at`, `timezone`) stays identical. `UsageStats.swift` works as-is.

### 5. No `ios_server.py` changes

`handle_usage_request()` already just calls `usage_checker.check_usage()` and sends the result.

## Risks

- **Token expiry:** OAuth tokens expire. If expired, return a clear error rather than silent 0%. Claude Code refreshes tokens during active sessions, so this should rarely happen.
- **API stability:** This is an undocumented endpoint. Could change. But it's what Claude Code itself uses internally, so it's stable as long as Claude Code works.
- **macOS only:** `security` CLI is macOS-specific. Linux would need `~/.claude/.credentials.json` instead. Current server only runs on macOS so this is fine for now.
