#!/bin/bash
# Unified testing skill for Claude Voice Mode project
# Handles: unit tests, server tests, integration tests, or all
set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Parse arguments
TEST_TYPE="${1:-integration}"  # Default to integration tests
TEST_TARGET="${2:-simulator}"   # Default to simulator; can be "device"
# Valid TEST_TYPE values: unit, server, integration, all
# Valid TEST_TARGET values: simulator, device

# Configuration paths
VENV_PYTHON="/Users/aaron/Desktop/max/.venv/bin/python3"
IOS_PROJECT="/Users/aaron/Desktop/max/ios-voice-app/ClaudeVoice"
SERVER_TESTS="/Users/aaron/Desktop/max/voice_server/tests/run_tests.sh"
TEST_SERVER_SCRIPT="/Users/aaron/Desktop/max/voice_server/integration_tests/test_server.py"

# Device configuration
SIMULATOR_ID="7FF7B0F7-7C42-44D6-A990-BB2F0807B89C"
DEVICE_UDID="00008140-00165C8036E8801C"  # Your iPhone

# Network configuration (use Mac's IP for device testing)
if [ "$TEST_TARGET" = "device" ]; then
    # Get Mac's local IP address for iOS app to connect to
    MAC_IP=$(ipconfig getifaddr en0 || ipconfig getifaddr en1)
    TEST_CLIENT_HOST="$MAC_IP"      # iOS app connects to this
    TEST_SERVER_HOST="0.0.0.0"      # Server binds to all interfaces
    echo -e "${YELLOW}Device testing mode: Server binding to 0.0.0.0, iOS will connect to $TEST_CLIENT_HOST${NC}"
else
    TEST_CLIENT_HOST="127.0.0.1"
    TEST_SERVER_HOST="127.0.0.1"
fi
TEST_SERVER_PORT="8765"

# Output files
TEST_OUTPUT="/tmp/test_output.log"
SERVER_LOG="/tmp/test_server.log"
MONITOR_LOG="/tmp/test_monitor.log"

# Process tracking
SERVER_PID=""
XCODEBUILD_PID=""
PYTEST_PID=""

# Cleanup function
cleanup() {
    echo -e "\n${YELLOW}Cleaning up...${NC}"

    # Kill xcodebuild if running
    if [ ! -z "$XCODEBUILD_PID" ] && kill -0 $XCODEBUILD_PID 2>/dev/null; then
        echo "Stopping xcodebuild (PID: $XCODEBUILD_PID)..."
        kill $XCODEBUILD_PID 2>/dev/null || true
        wait $XCODEBUILD_PID 2>/dev/null || true
    fi

    # Kill pytest if running
    if [ ! -z "$PYTEST_PID" ] && kill -0 $PYTEST_PID 2>/dev/null; then
        echo "Stopping pytest (PID: $PYTEST_PID)..."
        kill $PYTEST_PID 2>/dev/null || true
        wait $PYTEST_PID 2>/dev/null || true
    fi

    # Kill test server if running
    if [ ! -z "$SERVER_PID" ] && kill -0 $SERVER_PID 2>/dev/null; then
        echo "Stopping test server (PID: $SERVER_PID)..."
        kill $SERVER_PID 2>/dev/null || true
        wait $SERVER_PID 2>/dev/null || true
    fi

    # Kill lingering app instances
    APP_PIDS=$(ps aux | grep "ClaudeVoice.app/ClaudeVoice" | grep -v grep | awk '{print $2}' || true)
    if [ ! -z "$APP_PIDS" ]; then
        echo "Killing lingering app instances..."
        echo "$APP_PIDS" | xargs kill -9 2>/dev/null || true
        echo -e "${GREEN}✓ App instances killed${NC}"
    fi

    # Shutdown simulator (only if not testing on device)
    if [ "$TEST_TARGET" != "device" ] && [ ! -z "$SIMULATOR_ID" ]; then
        echo "Shutting down simulator..."
        xcrun simctl shutdown "$SIMULATOR_ID" 2>/dev/null || true
        echo -e "${GREEN}✓ Simulator shutdown${NC}"
    fi

    echo -e "${GREEN}✓ Cleanup complete${NC}"
}

trap cleanup EXIT INT TERM

# Function to run unit tests (ClaudeVoiceTests)
run_unit_tests() {
    echo -e "${BLUE}=== Running Unit Tests (ClaudeVoiceTests) ===${NC}\n"

    > "$TEST_OUTPUT"

    cd "$IOS_PROJECT"
    xcodebuild test \
        -scheme ClaudeVoice \
        -destination "platform=iOS Simulator,name=iPhone 16 Pro" \
        -only-testing:ClaudeVoiceTests \
        2>&1 | tee -a "$TEST_OUTPUT" &

    XCODEBUILD_PID=$!
    echo -e "${GREEN}✓ Unit tests started (PID: $XCODEBUILD_PID)${NC}"
    echo -e "${BLUE}📝 Output: $TEST_OUTPUT${NC}\n"

    monitor_xcodebuild_tests "unit"
}

# Function to run server tests (pytest)
run_server_tests() {
    echo -e "${BLUE}=== Running Server Tests (pytest) ===${NC}\n"

    > "$TEST_OUTPUT"

    cd /Users/aaron/Desktop/max/voice_server/tests
    bash run_tests.sh 2>&1 | tee -a "$TEST_OUTPUT" &

    PYTEST_PID=$!
    echo -e "${GREEN}✓ Server tests started (PID: $PYTEST_PID)${NC}"
    echo -e "${BLUE}📝 Output: $TEST_OUTPUT${NC}\n"

    monitor_pytest_tests
}

# Function to run integration tests (UI tests with server)
run_integration_tests() {
    echo -e "${BLUE}=== Running Integration Tests (UI + Server) ===${NC}\n"

    > "$TEST_OUTPUT"
    > "$SERVER_LOG"

    # Start test server with host binding
    echo "Starting test server on $TEST_SERVER_HOST:$TEST_SERVER_PORT..."

    # Export environment variables for test server configuration
    export TEST_SERVER_HOST="$TEST_SERVER_HOST"
    export TEST_SERVER_PORT="$TEST_SERVER_PORT"

    $VENV_PYTHON "$TEST_SERVER_SCRIPT" > "$SERVER_LOG" 2>&1 &
    SERVER_PID=$!
    echo -e "${GREEN}✓ Server started (PID: $SERVER_PID)${NC}"

    # Wait for server
    echo "Waiting for server to be ready..."
    for i in {1..10}; do
        if grep -q "READY" "$SERVER_LOG" 2>/dev/null; then
            echo -e "${GREEN}✓ Server ready${NC}\n"
            break
        fi
        sleep 1
    done

    # Determine test destination
    if [ "$TEST_TARGET" = "device" ]; then
        DESTINATION="platform=iOS,id=$DEVICE_UDID"
        echo -e "${YELLOW}Testing on physical device: $DEVICE_UDID${NC}"
        echo -e "${YELLOW}Make sure your iPhone is unlocked!${NC}\n"
    else
        DESTINATION="platform=iOS Simulator,id=$SIMULATOR_ID"
        echo -e "${YELLOW}Testing on simulator: $SIMULATOR_ID${NC}\n"
    fi

    # Run UI tests
    cd "$IOS_PROJECT"
    # Pass environment variables directly to xcodebuild
    TEST_SERVER_HOST="$TEST_CLIENT_HOST" TEST_SERVER_PORT="$TEST_SERVER_PORT" xcodebuild test \
        -scheme ClaudeVoice \
        -destination "$DESTINATION" \
        -only-testing:ClaudeVoiceUITests \
        2>&1 | tee -a "$TEST_OUTPUT" &

    XCODEBUILD_PID=$!
    echo -e "${GREEN}✓ Integration tests started (PID: $XCODEBUILD_PID)${NC}"
    echo -e "${BLUE}📝 Test output: $TEST_OUTPUT${NC}"
    echo -e "${BLUE}📝 Server log: $SERVER_LOG${NC}\n"

    monitor_xcodebuild_tests "integration"
}

# Monitor xcodebuild tests
monitor_xcodebuild_tests() {
    local test_type="$1"
    local check_count=0
    local last_line_count=0
    local no_change_count=0

    echo -e "${YELLOW}=== Monitoring test execution ===${NC}\n" | tee -a "$MONITOR_LOG"

    while kill -0 $XCODEBUILD_PID 2>/dev/null; do
        check_count=$((check_count + 1))
        echo "[Monitor check #$check_count]" | tee -a "$MONITOR_LOG"

        # Check process status
        PROC_INFO=$(ps -p $XCODEBUILD_PID -o pid=,pcpu=,rss=,state=,time= 2>/dev/null || echo "GONE")
        echo "Process: $PROC_INFO" | tee -a "$MONITOR_LOG"

        # Check log growth
        current_line_count=$(wc -l < "$TEST_OUTPUT" 2>/dev/null || echo "0")
        line_diff=$((current_line_count - last_line_count))

        if [ $line_diff -gt 0 ]; then
            echo "Log: $current_line_count lines (+$line_diff new)" | tee -a "$MONITOR_LOG"
            no_change_count=0
        else
            no_change_count=$((no_change_count + 1))
            echo "Log: $current_line_count lines (no change for $no_change_count checks)" | tee -a "$MONITOR_LOG"
        fi

        last_line_count=$current_line_count

        # Check for crashes
        LATEST_CRASH=$(ls -t ~/Library/Logs/DiagnosticReports/ClaudeVoice*.ips 2>/dev/null | head -1)
        if [ ! -z "$LATEST_CRASH" ]; then
            CRASH_TIME=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M:%S" "$LATEST_CRASH" 2>/dev/null)
            echo -e "\n${RED}⚠ CRASH DETECTED: $LATEST_CRASH${NC}" | tee -a "$MONITOR_LOG"
            echo "Crash time: $CRASH_TIME" | tee -a "$MONITOR_LOG"
        fi

        # Show test progress
        echo -e "\n=== Last 40 lines of test output ===" | tee -a "$MONITOR_LOG"
        tail -40 "$TEST_OUTPUT" 2>/dev/null | tee -a "$MONITOR_LOG"
        echo "===================================" | tee -a "$MONITOR_LOG"

        # Show server log if integration tests
        if [ "$test_type" = "integration" ]; then
            echo -e "\n=== Last 20 lines of server log ===" | tee -a "$MONITOR_LOG"
            tail -20 "$SERVER_LOG" 2>/dev/null | tee -a "$MONITOR_LOG"
            echo "===================================\n" | tee -a "$MONITOR_LOG"
        fi

        # Check if stuck
        if [ $no_change_count -ge 6 ]; then
            echo -e "${RED}⚠ BUILD STUCK: No log activity for 60+ seconds${NC}" | tee -a "$MONITOR_LOG"
        fi

        sleep 10
    done

    # Test completed
    echo -e "\n${GREEN}✓ Test process exited${NC}" | tee -a "$MONITOR_LOG"
    analyze_results "$test_type"
}

# Monitor pytest tests
monitor_pytest_tests() {
    local check_count=0
    local last_line_count=0

    echo -e "${YELLOW}=== Monitoring pytest execution ===${NC}\n" | tee -a "$MONITOR_LOG"

    while kill -0 $PYTEST_PID 2>/dev/null; do
        check_count=$((check_count + 1))
        echo "[Monitor check #$check_count]" | tee -a "$MONITOR_LOG"

        # Check log growth
        current_line_count=$(wc -l < "$TEST_OUTPUT" 2>/dev/null || echo "0")
        line_diff=$((current_line_count - last_line_count))

        if [ $line_diff -gt 0 ]; then
            echo "Log: $current_line_count lines (+$line_diff new)" | tee -a "$MONITOR_LOG"
        else
            echo "Log: $current_line_count lines (no change)" | tee -a "$MONITOR_LOG"
        fi

        last_line_count=$current_line_count

        # Show recent output
        echo -e "\n=== Last 30 lines of pytest output ===" | tee -a "$MONITOR_LOG"
        tail -30 "$TEST_OUTPUT" 2>/dev/null | tee -a "$MONITOR_LOG"
        echo "======================================\n" | tee -a "$MONITOR_LOG"

        sleep 10
    done

    echo -e "\n${GREEN}✓ Pytest process exited${NC}" | tee -a "$MONITOR_LOG"
    analyze_results "server"
}

# Analyze test results
analyze_results() {
    local test_type="$1"

    echo -e "\n${BLUE}=== Test Results ===${NC}\n"

    if [ "$test_type" = "server" ]; then
        # Pytest results
        if grep -q "passed" "$TEST_OUTPUT"; then
            PASSED=$(grep -o "[0-9]* passed" "$TEST_OUTPUT" | head -1)
            FAILED=$(grep -o "[0-9]* failed" "$TEST_OUTPUT" | head -1 || echo "0 failed")

            echo -e "${GREEN}✓ $PASSED${NC}"
            if [ "$FAILED" != "0 failed" ]; then
                echo -e "${RED}✗ $FAILED${NC}"
            fi
        fi
    else
        # XCTest results
        if grep -q "TEST SUCCEEDED" "$TEST_OUTPUT"; then
            PASSED=$(grep -c "Test Case.*passed" "$TEST_OUTPUT" || echo "0")
            echo -e "${GREEN}✓ ALL TESTS PASSED ($PASSED tests)${NC}"
        else
            PASSED=$(grep -c "Test Case.*passed" "$TEST_OUTPUT" || echo "0")
            FAILED=$(grep -c "Test Case.*failed" "$TEST_OUTPUT" || echo "0")

            echo -e "${YELLOW}Passed: $PASSED${NC}"
            echo -e "${RED}Failed: $FAILED${NC}"

            if [ $FAILED -gt 0 ]; then
                echo -e "\n${RED}Failed tests:${NC}"
                grep "Test Case.*failed" "$TEST_OUTPUT"
            fi
        fi
    fi

    echo -e "\n${BLUE}Full logs:${NC}"
    echo "  Test output: $TEST_OUTPUT"
    if [ "$test_type" = "integration" ]; then
        echo "  Server log: $SERVER_LOG"
    fi
    echo "  Monitor log: $MONITOR_LOG"
}

# Main execution
echo -e "${BLUE}╔════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Claude Voice Mode Test Suite         ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════╝${NC}\n"

case "$TEST_TYPE" in
    unit)
        run_unit_tests
        ;;
    server)
        run_server_tests
        ;;
    integration)
        run_integration_tests
        ;;
    all)
        echo -e "${BLUE}Running ALL test suites...${NC}\n"
        run_unit_tests
        echo -e "\n${BLUE}─────────────────────────────────────${NC}\n"
        run_server_tests
        echo -e "\n${BLUE}─────────────────────────────────────${NC}\n"
        run_integration_tests
        ;;
    *)
        echo -e "${RED}Invalid test type: $TEST_TYPE${NC}"
        echo "Usage: $0 [unit|server|integration|all] [simulator|device]"
        echo ""
        echo "Examples:"
        echo "  $0 integration          # Run integration tests on simulator (default)"
        echo "  $0 integration device   # Run integration tests on physical iPhone"
        echo "  $0 all device           # Run all tests with device for integration"
        exit 1
        ;;
esac

echo -e "\n${GREEN}✓ Test suite complete${NC}\n"
