#!/bin/bash
# E2E Test Runner - Starts server then runs tests

set -e
set -o pipefail  # Capture xcodebuild exit code, not tee's

echo "🧪 E2E Test Runner"
echo "=================="

# Configuration
PROJECT_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
SERVER_SCRIPT="$PROJECT_ROOT/voice_server/ios_server.py"
TRANSCRIPT_DIR="$HOME/.claude/projects/e2e_test_project"
TRANSCRIPT_FILE="$TRANSCRIPT_DIR/e2e_transcript.jsonl"
LOG_FILE="/tmp/e2e_server.log"

# Ensure transcript directory exists and create transcript file
# Server needs a transcript file to exist BEFORE it starts so it can watch it
mkdir -p "$TRANSCRIPT_DIR"
echo "" > "$TRANSCRIPT_FILE"
echo "📝 Created transcript file: $TRANSCRIPT_FILE"

# Start server (unmodified, just watches its normal transcript dir)
echo "📡 Starting ios_server.py..."
$VENV_PYTHON "$SERVER_SCRIPT" > "$LOG_FILE" 2>&1 &
SERVER_PID=$!

echo "   Server PID: $SERVER_PID"
echo "   Logs: $LOG_FILE"

# Wait for server to be ready
echo "⏳ Waiting for server startup..."
sleep 3

# Verify server is running
if ! ps -p $SERVER_PID > /dev/null; then
    echo "❌ Server failed to start. Check logs:"
    cat "$LOG_FILE"
    exit 1
fi

echo "✅ Server started successfully"

# Run E2E tests
echo ""
echo "🏃 Running E2E tests..."
echo ""

xcodebuild test \
    -scheme ClaudeVoice \
    -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -only-testing:ClaudeVoiceUITests/E2EHappyPathTests \
    -only-testing:ClaudeVoiceUITests/E2EConnectionTests \
    -only-testing:ClaudeVoiceUITests/E2EErrorHandlingTests \
    -parallel-testing-enabled NO \
    2>&1 | tee /tmp/e2e_test.log

TEST_EXIT_CODE=$?

# Cleanup
echo ""
echo "🧹 Cleaning up..."
kill $SERVER_PID 2>/dev/null || true
rm -rf "$TRANSCRIPT_DIR"

if [ $TEST_EXIT_CODE -eq 0 ]; then
    echo "✅ All E2E tests passed!"
else
    echo "❌ Some E2E tests failed"
    echo "   Check server logs: $LOG_FILE"
fi

exit $TEST_EXIT_CODE
