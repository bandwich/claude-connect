#!/bin/bash
# Test runner for voice mode tests

set -e

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_MODE_DIR="$(dirname "$SCRIPT_DIR")"

# Activate virtual environment
echo "Activating virtual environment..."
source /Users/aaron/Desktop/max/.venv/bin/activate

# Set library path for zbar (required by pyzbar for QR scanning tests)
export DYLD_LIBRARY_PATH="/opt/homebrew/lib:$DYLD_LIBRARY_PATH"

# Install test dependencies if needed
if ! python -c "import pytest" 2>/dev/null; then
    echo "Installing test dependencies..."
    pip install -r "$SCRIPT_DIR/requirements-test.txt"
fi

# Run tests
echo ""
echo "Running voice mode tests..."
echo "================================"
cd "$SCRIPT_DIR"

# Run with different options based on arguments
if [ "$1" == "coverage" ]; then
    pytest --cov="$VOICE_MODE_DIR" --cov-report=term-missing --cov-report=html
    echo ""
    echo "Coverage report generated in htmlcov/index.html"
elif [ "$1" == "verbose" ]; then
    pytest -vv
elif [ "$1" == "unit" ]; then
    pytest -m unit
elif [ "$1" == "integration" ]; then
    pytest -m integration
else
    pytest
fi

echo ""
echo "Tests complete!"
