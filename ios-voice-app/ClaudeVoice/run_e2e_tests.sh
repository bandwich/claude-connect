#!/bin/bash
# E2E Test Runner - Creates test session, starts server, runs tests
# Usage: ./run_e2e_tests.sh [TestSuiteName]
# Examples:
#   ./run_e2e_tests.sh                    # Run all E2E tests
#   ./run_e2e_tests.sh E2EPermissionTests # Run only permission tests

set -e
set -o pipefail  # Capture xcodebuild exit code, not tee's

# Save script directory before any cd commands (needed for xcodebuild later)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "🧪 E2E Test Runner"
echo "=================="

# Optional: specific test suite to run
SPECIFIC_SUITE="$1"

# Configuration
VENV_PYTHON="$PROJECT_ROOT/.venv/bin/python3"
SERVER_SCRIPT="$PROJECT_ROOT/voice_server/ios_server.py"
LOG_FILE="/tmp/e2e_server.log"

# Test project configuration
TEST_PROJECT_DIR="/tmp/e2e_test_project"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"

# All available E2E test suites
ALL_SUITES=(
    "E2EConnectionTests"
    "E2EErrorHandlingTests"
    "E2EPermissionTests"
    "E2EFullConversationFlowTests"
    "E2ENavigationFlowTests"
    "E2ESessionFlowTests"
)

# Kill any existing servers on ports 8765 (WebSocket) and 8766 (HTTP)
for port in 8765 8766; do
    if lsof -i :$port > /dev/null 2>&1; then
        echo "⚠️  Killing existing server on port $port..."
        lsof -ti :$port | xargs kill -9 2>/dev/null || true
    fi
done

# Kill any existing tmux claude_voice session
tmux kill-session -t claude_voice 2>/dev/null || true
sleep 1

# Create test project directory
echo "📁 Creating test project directory: $TEST_PROJECT_DIR"
mkdir -p "$TEST_PROJECT_DIR"

# Create a Claude session by running claude with a simple prompt
echo "🤖 Creating test Claude session..."
cd "$TEST_PROJECT_DIR"

# Run claude with a one-word response prompt, non-interactive
# The --print flag outputs response and exits
# Use gtimeout on macOS (from coreutils), fall back to no timeout
if command -v gtimeout &> /dev/null; then
    gtimeout 60 claude --print "Reply with only: ok" > /tmp/claude_init.log 2>&1 || true
elif command -v timeout &> /dev/null; then
    timeout 60 claude --print "Reply with only: ok" > /tmp/claude_init.log 2>&1 || true
else
    claude --print "Reply with only: ok" > /tmp/claude_init.log 2>&1 || true
fi

# Find the session ID from the transcript
# Claude resolves /tmp to /private/tmp and encodes both / and _ as -
# e.g., /private/tmp/e2e_test_project -> -private-tmp-e2e-test-project
REAL_PATH=$(cd "$TEST_PROJECT_DIR" && pwd -P)
ENCODED_PATH=$(echo "$REAL_PATH" | sed 's|/|-|g' | sed 's|_|-|g')
SESSION_DIR="$CLAUDE_PROJECTS_DIR/$ENCODED_PATH"

echo "📂 Looking for session in: $SESSION_DIR"

if [ ! -d "$SESSION_DIR" ]; then
    echo "❌ Session directory not created. Claude output:"
    cat /tmp/claude_init.log
    exit 1
fi

# Get the most recent main session file (not agent-*.jsonl)
SESSION_FILE=$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | grep -v '/agent-' | head -1)

if [ -z "$SESSION_FILE" ]; then
    echo "❌ No session file found in $SESSION_DIR"
    exit 1
fi

# Extract session ID from filename
TEST_SESSION_ID=$(basename "$SESSION_FILE" .jsonl)
echo "✅ Created test session: $TEST_SESSION_ID"

# The project name as it appears in the UI
# Due to encoding issues, the UI shows basename of simple /-for-- decoded path
# e.g., -private-tmp-e2e-test-project decodes to /private/tmp/e2e/test/project -> "project"
DECODED_FOR_UI=$(echo "$ENCODED_PATH" | sed 's|-|/|g')
TEST_PROJECT_NAME=$(basename "$DECODED_FOR_UI")
echo "   Project name in UI: $TEST_PROJECT_NAME"
echo "   Folder name: $ENCODED_PATH"

# Write config file for tests to read (xcodebuild doesn't pass env vars to test process)
E2E_CONFIG_FILE="/tmp/e2e_test_config.json"
cat > "$E2E_CONFIG_FILE" << EOF
{
    "session_id": "$TEST_SESSION_ID",
    "project_name": "$TEST_PROJECT_NAME",
    "folder_name": "$ENCODED_PATH"
}
EOF
echo "📝 Wrote test config to: $E2E_CONFIG_FILE"

# Cleanup function
cleanup() {
    echo ""
    echo "🧹 Cleaning up..."
    kill $SERVER_PID 2>/dev/null || true
    lsof -ti :8765 | xargs kill -9 2>/dev/null || true
    lsof -ti :8766 | xargs kill -9 2>/dev/null || true
    tmux kill-session -t claude_voice 2>/dev/null || true
    # Don't delete session files - useful for debugging
}

trap cleanup EXIT

# Return to script directory for xcodebuild
cd "$SCRIPT_DIR"

# Start server
echo "📡 Starting ios_server.py..."
PYTHONUNBUFFERED=1 $VENV_PYTHON "$SERVER_SCRIPT" > "$LOG_FILE" 2>&1 &
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

# Build test arguments
if [ -n "$SPECIFIC_SUITE" ]; then
    echo ""
    echo "🏃 Running E2E tests: $SPECIFIC_SUITE"
    echo ""
    TEST_ARGS="-only-testing:ClaudeVoiceUITests/$SPECIFIC_SUITE"
else
    echo ""
    echo "🏃 Running all E2E tests..."
    echo ""
    TEST_ARGS=""
    for suite in "${ALL_SUITES[@]}"; do
        TEST_ARGS="$TEST_ARGS -only-testing:ClaudeVoiceUITests/$suite"
    done
fi

# Run tests (config is read from /tmp/e2e_test_config.json)
xcodebuild test \
    -scheme ClaudeVoice \
    -sdk iphonesimulator \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    $TEST_ARGS \
    -parallel-testing-enabled NO \
    2>&1 | tee /tmp/e2e_test.log

TEST_EXIT_CODE=$?

if [ $TEST_EXIT_CODE -eq 0 ]; then
    if [ -n "$SPECIFIC_SUITE" ]; then
        echo "✅ $SPECIFIC_SUITE passed!"
    else
        echo "✅ All E2E tests passed!"
    fi
else
    echo "❌ Some E2E tests failed"
    echo "   Check server logs: $LOG_FILE"
fi

exit $TEST_EXIT_CODE
