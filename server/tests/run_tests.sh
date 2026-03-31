#!/bin/bash
# Test runner for voice mode tests

set -e

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VOICE_MODE_DIR="$(dirname "$SCRIPT_DIR")"

# Use the pipx-installed Python
PYTHON="/Users/aaron/.local/pipx/venvs/claude-connect/bin/python"

# Set library path for zbar (required by pyzbar for QR scanning tests)
export DYLD_LIBRARY_PATH="/opt/homebrew/lib:$DYLD_LIBRARY_PATH"

# Install test dependencies if needed
if ! "$PYTHON" -c "import pytest" 2>/dev/null; then
    echo "pytest not found in pipx venv"
    exit 1
fi

# Run tests
echo ""
echo "Running voice mode tests..."
echo "================================"
cd "$SCRIPT_DIR"

# Run with different options based on arguments
if [ "$1" == "coverage" ]; then
    "$PYTHON" -m pytest --cov="$VOICE_MODE_DIR" --cov-report=term-missing --cov-report=html
    echo ""
    echo "Coverage report generated in htmlcov/index.html"
elif [ "$1" == "verbose" ]; then
    "$PYTHON" -m pytest -vv
elif [ "$1" == "unit" ]; then
    "$PYTHON" -m pytest -m unit
elif [ "$1" == "integration" ]; then
    "$PYTHON" -m pytest -m integration
else
    "$PYTHON" -m pytest
fi

echo ""
echo "Tests complete!"
