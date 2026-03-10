#!/bin/bash
# Claude Code PreToolUse hook for AskUserQuestion
# Intercepts questions and forwards to iOS voice server for remote answering
#
# Reads JSON from stdin, POSTs to server, outputs PreToolUse decision JSON
# Exit 0 on success with decision, exit 2 to fall back to terminal
#
# NOTE: The settings.json matcher is "AskUserQuestion" so this hook
# only fires for that tool. No need to check tool_name here.

SERVER_URL="${VOICE_SERVER_URL:-http://127.0.0.1:8766}"

# Save stdin to a temp file to avoid shell variable expansion mangling
# JSON with special characters ($, backticks, quotes, backslashes)
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT
cat > "$TMPFILE"

# POST to question endpoint with 3 minute timeout
# Use 127.0.0.1 to avoid DNS resolution delays
# If server is down, curl fails fast and we fall back to terminal
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  --data-binary @"$TMPFILE" \
  --connect-timeout 3 \
  --max-time 185 \
  "${SERVER_URL}/question" 2>/dev/null) || {
    # Server not running or network error - fall back to terminal
    exit 2
}

# Check if response has fallback=true (timeout occurred)
if echo "$RESPONSE" | grep -q '"fallback".*:.*true'; then
    exit 2
fi

# Output the decision JSON for Claude Code
echo "$RESPONSE"
exit 0
