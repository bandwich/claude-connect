#!/bin/bash
# Claude Code PostToolUse hook
# Notifies server when a tool completes (to dismiss permission prompt)

SERVER_URL="${VOICE_SERVER_URL:-http://127.0.0.1:8766}"

# Read JSON payload from stdin
PAYLOAD=$(cat)

# POST to permission_resolved endpoint (fire and forget)
# Use 127.0.0.1 to avoid DNS resolution delays
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --connect-timeout 2 \
  --max-time 5 \
  "${SERVER_URL}/permission_resolved" >/dev/null 2>&1 || true

exit 0
