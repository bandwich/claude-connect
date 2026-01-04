#!/bin/bash
# Claude Code PermissionRequest hook
# Forwards permission requests to iOS voice server
#
# Reads JSON from stdin, POSTs to server, outputs response JSON
# Exit 0 on success with decision, exit 2 to fall back to terminal

set -e

SERVER_URL="${VOICE_SERVER_URL:-http://localhost:8766}"

# Read JSON payload from stdin
PAYLOAD=$(cat)

# POST to permission endpoint with 3 minute timeout
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --max-time 185 \
  "${SERVER_URL}/permission" 2>/dev/null) || {
    # Network error - fall back to terminal
    exit 2
}

# Check if response has behavior=ask (timeout occurred)
if echo "$RESPONSE" | grep -q '"behavior".*:.*"ask"'; then
    # Server timed out waiting for iOS response
    exit 2
fi

# Output the decision JSON for Claude Code
echo "$RESPONSE"
exit 0
