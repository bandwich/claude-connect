#!/bin/bash
# Claude Code PostToolUse hook
# Notifies server when a tool completes (to dismiss permission prompt)

SERVER_URL="${VOICE_SERVER_URL:-http://localhost:8766}"

# Check if server is running - exit silently if not
if ! curl -s --max-time 0.5 "${SERVER_URL}/health" >/dev/null 2>&1; then
    cat >/dev/null  # Consume stdin
    exit 0
fi

# Read JSON payload from stdin
PAYLOAD=$(cat)

# POST to permission_resolved endpoint (fire and forget)
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --max-time 5 \
  "${SERVER_URL}/permission_resolved" >/dev/null 2>&1 || true

exit 0
