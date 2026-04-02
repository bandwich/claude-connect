#!/bin/bash
# E2E Test Runner — Two-tier architecture
#
# Usage:
#   ./run_e2e_tests.sh                     # Run all (tier 1 + tier 2)
#   ./run_e2e_tests.sh --fast              # Tier 1 only (test server, fast)
#   ./run_e2e_tests.sh --smoke             # Tier 2 only (real Claude)
#   ./run_e2e_tests.sh E2EPermissionTests  # Specific suite
#   ./run_e2e_tests.sh --fast E2EPermissionTests  # Specific suite, tier 1

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "🧪 E2E Test Runner"
echo "=================="

# Parse flags
MODE="all"
SPECIFIC_SUITE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --fast) MODE="fast"; shift ;;
        --smoke) MODE="smoke"; shift ;;
        *) SPECIFIC_SUITE="$1"; shift ;;
    esac
done

# Configuration
PYTHON="/Users/aaron/.local/pipx/venvs/claude-connect/bin/python"
SERVER_SCRIPT="$PROJECT_ROOT/server/main.py"
LOG_FILE="/tmp/e2e_server.log"
E2E_CONFIG_FILE="/tmp/e2e_test_config.json"

# Test project configuration
TEST_PROJECT_DIR="/tmp/e2e_test_project"
CLAUDE_PROJECTS_DIR="$HOME/.claude/projects"

# Tier 1: Test server suites (fast, deterministic)
FAST_SUITES=(
    "E2EConnectionTests"
    "E2EConversationTests"
    "E2EPermissionTests"
    "E2EQuestionTests"
    "E2ENavigationTests"
    "E2ESessionTests"
    "E2EFileBrowserTests"
)

# Tier 2: Real Claude smoke tests
SMOKE_SUITES=(
    "E2ESmokeTests"
)

SERVER_PID=""

# Ports: tier 1 uses 8765/8766, tier 2 uses 18765/18766 (avoids hook interference)
FAST_WS_PORT=8765
FAST_HTTP_PORT=8766
SMOKE_WS_PORT=18765
SMOKE_HTTP_PORT=18766

# Kill any existing servers on test ports
kill_servers() {
    for port in $FAST_WS_PORT $FAST_HTTP_PORT $SMOKE_WS_PORT $SMOKE_HTTP_PORT; do
        if lsof -i :$port > /dev/null 2>&1; then
            echo "⚠️  Killing existing server on port $port..."
            lsof -ti :$port | xargs kill -9 2>/dev/null || true
        fi
    done
}

# Cleanup function
cleanup() {
    echo ""
    echo "🧹 Cleaning up..."
    if [ -n "$SERVER_PID" ]; then
        kill $SERVER_PID 2>/dev/null || true
    fi
    for port in $FAST_WS_PORT $FAST_HTTP_PORT $SMOKE_WS_PORT $SMOKE_HTTP_PORT; do
        lsof -ti :$port | xargs kill -9 2>/dev/null || true
    done
    tmux kill-session -t claude_voice 2>/dev/null || true
    # Kill all claude-connect_* tmux sessions
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-connect_' | while read s; do
        tmux kill-session -t "$s" 2>/dev/null || true
    done
}

trap cleanup EXIT

# Write config file for tests to read
write_config() {
    local mode="$1"
    local session_id="${2:-test-session-1}"
    local project_name="${3:-e2e_test_project}"
    local folder_name="${4:--private-tmp-e2e-test-project}"
    local port="${5:-$FAST_WS_PORT}"

    cat > "$E2E_CONFIG_FILE" << EOF
{
    "mode": "$mode",
    "session_id": "$session_id",
    "project_name": "$project_name",
    "folder_name": "$folder_name",
    "port": $port
}
EOF
    echo "📝 Config: mode=$mode, port=$port"
}

# Start test server (tier 1)
start_test_server() {
    echo "📡 Starting test server..."
    kill_servers
    sleep 1

    cd "$PROJECT_ROOT"
    PYTHONUNBUFFERED=1 "$PYTHON" -m server.integration_tests.test_server > "$LOG_FILE" 2>&1 &
    SERVER_PID=$!
    echo "   PID: $SERVER_PID"

    # Wait for READY signal
    for i in $(seq 1 10); do
        if grep -q "READY" "$LOG_FILE" 2>/dev/null; then
            echo "✅ Test server started"
            return 0
        fi
        sleep 1
    done

    echo "❌ Test server failed to start. Logs:"
    cat "$LOG_FILE"
    exit 1
}

# Create real Claude session and start real server (tier 2)
start_real_server() {
    echo "🤖 Creating real Claude session..."
    kill_servers
    sleep 1

    # Kill any existing claude-connect tmux sessions
    tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^claude-connect_' | while read s; do
        tmux kill-session -t "$s" 2>/dev/null || true
    done || true

    mkdir -p "$TEST_PROJECT_DIR"
    cd "$TEST_PROJECT_DIR"

    # Run claude with one-word response
    run_with_timeout() {
        local timeout=$1
        shift
        "$@" &
        local pid=$!
        ( sleep "$timeout"; kill -9 $pid 2>/dev/null ) &
        local killer=$!
        wait $pid 2>/dev/null
        local ret=$?
        kill $killer 2>/dev/null
        wait $killer 2>/dev/null
        return $ret
    }

    if command -v gtimeout &> /dev/null; then
        gtimeout 60 claude --print "Reply with only: ok" > /tmp/claude_init.log 2>&1 || true
    elif command -v timeout &> /dev/null; then
        timeout 60 claude --print "Reply with only: ok" > /tmp/claude_init.log 2>&1 || true
    else
        run_with_timeout 60 claude --print "Reply with only: ok" > /tmp/claude_init.log 2>&1 || true
    fi

    # Find session ID
    REAL_PATH=$(cd "$TEST_PROJECT_DIR" && pwd -P)
    ENCODED_PATH=$(echo "$REAL_PATH" | sed 's|/|-|g' | sed 's|_|-|g')
    SESSION_DIR="$CLAUDE_PROJECTS_DIR/$ENCODED_PATH"

    echo "📂 Looking for session in: $SESSION_DIR"

    if [ ! -d "$SESSION_DIR" ]; then
        echo "❌ Session directory not created. Claude output:"
        cat /tmp/claude_init.log
        exit 1
    fi

    SESSION_FILE=$(ls -t "$SESSION_DIR"/*.jsonl 2>/dev/null | grep -v '/agent-' | head -1 || true)

    if [ -z "$SESSION_FILE" ]; then
        echo "❌ No session file found in $SESSION_DIR"
        exit 1
    fi

    TEST_SESSION_ID=$(basename "$SESSION_FILE" .jsonl)
    TEST_PROJECT_NAME=$(basename "$REAL_PATH")
    echo "✅ Session: $TEST_SESSION_ID"

    write_config "real" "$TEST_SESSION_ID" "$TEST_PROJECT_NAME" "$ENCODED_PATH" "$SMOKE_WS_PORT"

    # Start real server on isolated ports to avoid hook interference
    echo "📡 Starting real server on ports 18765/18766..."
    cd "$SCRIPT_DIR"
    CLAUDE_CONNECT_PORT=18765 CLAUDE_CONNECT_HTTP_PORT=18766 PYTHONUNBUFFERED=1 "$PYTHON" "$SERVER_SCRIPT" > "$LOG_FILE" 2>&1 &
    SERVER_PID=$!
    echo "   PID: $SERVER_PID"
    sleep 3

    if ! ps -p $SERVER_PID > /dev/null; then
        echo "❌ Real server failed to start. Logs:"
        cat "$LOG_FILE"
        exit 1
    fi

    echo "✅ Real server started"
}

# Run test suites
run_suites() {
    local suite_type="$1"
    shift
    local suites=("$@")

    cd "$SCRIPT_DIR"

    # Build test arguments
    local TEST_ARGS=""
    if [ -n "$SPECIFIC_SUITE" ]; then
        echo ""
        echo "🏃 Running: $SPECIFIC_SUITE ($suite_type)"
        echo ""
        TEST_ARGS="-only-testing:ClaudeConnectUITests/$SPECIFIC_SUITE"
    else
        echo ""
        echo "🏃 Running $suite_type suites: ${suites[*]}"
        echo ""
        for suite in "${suites[@]}"; do
            TEST_ARGS="$TEST_ARGS -only-testing:ClaudeConnectUITests/$suite"
        done
    fi

    xcodebuild test \
        -scheme ClaudeConnect \
        -sdk iphonesimulator \
        -destination 'platform=iOS Simulator,name=iPhone 17' \
        $TEST_ARGS \
        -parallel-testing-enabled NO \
        2>&1 | tee /tmp/e2e_test.log

    return ${PIPESTATUS[0]}
}

# ============================================================
# Main
# ============================================================

FAST_EXIT=0
SMOKE_EXIT=0

if [ "$MODE" = "fast" ] || [ "$MODE" = "all" ]; then
    write_config "test_server"
    start_test_server

    if run_suites "tier-1" "${FAST_SUITES[@]}"; then
        echo "✅ Tier 1 (fast) tests passed!"
    else
        echo "❌ Tier 1 (fast) tests failed"
        FAST_EXIT=1
    fi

    # Kill test server before smoke tests
    if [ "$MODE" = "all" ]; then
        kill $SERVER_PID 2>/dev/null || true
        SERVER_PID=""
        kill_servers
        sleep 1
    fi
fi

if [ "$MODE" = "smoke" ] || [ "$MODE" = "all" ]; then
    start_real_server

    if run_suites "tier-2" "${SMOKE_SUITES[@]}"; then
        echo "✅ Tier 2 (smoke) tests passed!"
    else
        echo "❌ Tier 2 (smoke) tests failed"
        SMOKE_EXIT=1
    fi
fi

# Exit with failure if either tier failed
if [ $FAST_EXIT -ne 0 ] || [ $SMOKE_EXIT -ne 0 ]; then
    echo "❌ Some tests failed"
    exit 1
fi

echo "✅ All tests passed!"
exit 0
