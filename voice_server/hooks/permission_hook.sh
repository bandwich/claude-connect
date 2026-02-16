#!/bin/bash
# Claude Code PermissionRequest hook
# Forwards permission requests to iOS voice server
#
# Reads JSON from stdin, POSTs to server, outputs response JSON
# Exit 0 on success with decision, exit 2 to fall back to terminal

SERVER_URL="${VOICE_SERVER_URL:-http://127.0.0.1:8766}"

# Read JSON payload from stdin first
PAYLOAD=$(cat)

# POST to permission endpoint with 3 minute timeout
# Use 127.0.0.1 to avoid DNS resolution delays
# If server is down, curl fails fast and we fall back to terminal
RESPONSE=$(curl -s -X POST \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" \
  --connect-timeout 3 \
  --max-time 185 \
  "${SERVER_URL}/permission" 2>/dev/null) || {
    # Server not running or network error - fall back to terminal
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
