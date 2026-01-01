#!/bin/bash
set -e

# E2E Test Runner - Manages server lifecycle and runs UI tests

PROJECT_ROOT="/Users/aaron/Desktop/max"
PYTHON_VENV="$PROJECT_ROOT/.venv/bin/python3"
SERVER_SCRIPT="$PROJECT_ROOT/voice_server/ios_server.py"
TRANSCRIPT_PATH="/tmp/claude_voice_e2e_tests/transcript_$$.jsonl"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}🚀 Starting E2E Test Runner${NC}"

# Create transcript directory
mkdir -p "$(dirname "$TRANSCRIPT_PATH")"
touch "$TRANSCRIPT_PATH"

# Start server
echo -e "${YELLOW}📡 Starting ios_server.py...${NC}"
export TEST_MODE=1
export TEST_TRANSCRIPT_PATH="$TRANSCRIPT_PATH"

"$PYTHON_VENV" "$SERVER_SCRIPT" > /tmp/e2e_server.log 2>&1 &
SERVER_PID=$!

echo "Server PID: $SERVER_PID"

# Wait for server to be ready
echo "Waiting for server to start..."
sleep 3

# Check if server is still running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo -e "${RED}❌ Server failed to start${NC}"
    cat /tmp/e2e_server.log
    exit 1
fi

echo -e "${GREEN}✅ Server started successfully${NC}"

# Run tests
echo -e "${YELLOW}🧪 Running E2E tests...${NC}"
cd /Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice

xcodebuild test \
    -scheme ClaudeVoice \
    -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -only-testing:ClaudeVoiceUITests/E2EHappyPathTests \
    -only-testing:ClaudeVoiceUITests/E2EConnectionTests \
    -only-testing:ClaudeVoiceUITests/E2EErrorHandlingTests \
    TEST_SERVER_RUNNING=1 \
    TEST_TRANSCRIPT_PATH="$TRANSCRIPT_PATH"

TEST_RESULT=$?

# Cleanup
echo -e "${YELLOW}🧹 Cleaning up...${NC}"
kill $SERVER_PID 2>/dev/null || true
rm -f "$TRANSCRIPT_PATH"

if [ $TEST_RESULT -eq 0 ]; then
    echo -e "${GREEN}✅ All tests passed!${NC}"
else
    echo -e "${RED}❌ Tests failed${NC}"
    exit 1
fi
