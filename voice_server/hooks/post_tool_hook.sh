#!/bin/bash
# Claude Code PostToolUse hook
# Notifies iOS voice server that a permission prompt was resolved
#
# Reads JSON from stdin, extracts request info, POSTs to server

SERVER_URL="${VOICE_SERVER_URL:-http://localhost:8766}"

# Read JSON payload from stdin
PAYLOAD=$(cat)

# POST to permission_resolved endpoint (fire and forget)
curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  "${SERVER_URL}/permission_resolved" >/dev/null 2>&1 || true

exit 0
