#!/bin/bash
# Full test suite: iOS unit tests, server tests, E2E tests
# Usage: ./full_test.sh
#
# Logs are saved to:
#   tests/unit_test_logs/
#   tests/server_test_logs/
#   tests/e2e_test_logs/

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Timestamp for log files
TIMESTAMP=$(date "+%Y-%m-%d_%H-%M-%S")

# Create log directories
UNIT_LOG_DIR="$SCRIPT_DIR/unit_test_logs"
SERVER_LOG_DIR="$SCRIPT_DIR/server_test_logs"
E2E_LOG_DIR="$SCRIPT_DIR/e2e_test_logs"

mkdir -p "$UNIT_LOG_DIR" "$SERVER_LOG_DIR" "$E2E_LOG_DIR"

# Log file paths
UNIT_LOG="$UNIT_LOG_DIR/$TIMESTAMP.txt"
SERVER_LOG="$SERVER_LOG_DIR/$TIMESTAMP.txt"
E2E_LOG="$E2E_LOG_DIR/$TIMESTAMP.txt"

print_header() {
    echo ""
    echo -e "${BLUE}==================================================${NC}"
    echo -e "${YELLOW}$1${NC}"
    echo -e "${BLUE}==================================================${NC}"
    echo ""
}

# Track results
IOS_UNIT_RESULT=0
SERVER_RESULT=0
E2E_RESULT=0

# ============================================
# 1. iOS Unit Tests
# ============================================
print_header "iOS Unit Tests"
echo "📝 Log file: $UNIT_LOG"
echo ""

cd "$ROOT_DIR/ios/ClaudeConnect"

echo "🧹 Cleaning build..."
xcodebuild clean -scheme ClaudeConnect -quiet 2>/dev/null || true

echo ""
echo "🧪 Running iOS unit tests..."
echo "================================"

set +e
xcodebuild test -scheme ClaudeConnect \
    -destination 'platform=iOS Simulator,name=iPhone 16' \
    -only-testing:ClaudeConnectTests \
    2>&1 | tee "$UNIT_LOG"
UNIT_EXIT_CODE=${PIPESTATUS[0]}
set -e

echo ""
if [ $UNIT_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✅ iOS unit tests passed!${NC}"
else
    echo -e "${RED}❌ iOS unit tests failed${NC}"
    IOS_UNIT_RESULT=1
fi

# ============================================
# 2. Server Tests
# ============================================
print_header "Server Tests"
echo "📝 Log file: $SERVER_LOG"
echo ""

cd "$ROOT_DIR/server/tests"

echo "🧪 Running server tests..."
echo "================================"

set +e
./run_tests.sh 2>&1 | tee "$SERVER_LOG"
SERVER_EXIT_CODE=${PIPESTATUS[0]}
set -e

echo ""
if [ $SERVER_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✅ Server tests passed!${NC}"
else
    echo -e "${RED}❌ Server tests failed${NC}"
    SERVER_RESULT=1
fi

# ============================================
# 3. E2E Tests
# ============================================
print_header "E2E Tests"
echo "📝 Log file: $E2E_LOG"
echo ""

cd "$ROOT_DIR/ios/ClaudeConnect"

echo "🧪 Running E2E tests..."
echo "================================"

set +e
./run_e2e_tests.sh 2>&1 | tee "$E2E_LOG"
E2E_EXIT_CODE=${PIPESTATUS[0]}
set -e

echo ""
if [ $E2E_EXIT_CODE -eq 0 ]; then
    echo -e "${GREEN}✅ E2E tests passed!${NC}"
else
    echo -e "${RED}❌ E2E tests failed${NC}"
    E2E_RESULT=1
fi

# ============================================
# Summary
# ============================================
print_header "Summary"

TOTAL_FAILED=$((IOS_UNIT_RESULT + SERVER_RESULT + E2E_RESULT))

echo "Results:"
if [ $IOS_UNIT_RESULT -eq 0 ]; then
    echo -e "  ${GREEN}✅ iOS Unit Tests${NC}"
else
    echo -e "  ${RED}❌ iOS Unit Tests${NC} - see $UNIT_LOG"
fi

if [ $SERVER_RESULT -eq 0 ]; then
    echo -e "  ${GREEN}✅ Server Tests${NC}"
else
    echo -e "  ${RED}❌ Server Tests${NC} - see $SERVER_LOG"
fi

if [ $E2E_RESULT -eq 0 ]; then
    echo -e "  ${GREEN}✅ E2E Tests${NC}"
else
    echo -e "  ${RED}❌ E2E Tests${NC} - see $E2E_LOG"
fi

echo ""
echo "Log files:"
echo "  Unit:   $UNIT_LOG"
echo "  Server: $SERVER_LOG"
echo "  E2E:    $E2E_LOG"

echo ""
if [ $TOTAL_FAILED -eq 0 ]; then
    echo -e "${GREEN}🎉 All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}💥 $TOTAL_FAILED test suite(s) failed${NC}"
    exit 1
fi
