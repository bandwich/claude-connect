#!/bin/bash
# Claude Voice Server - Installation Script
# Installs system dependencies and sets up the claude-connect CLI

set -e

# Parse arguments
FORCE=""
if [[ "$1" == "--force" || "$1" == "-f" ]]; then
    FORCE="--force"
fi

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}==>${NC} $1"; }
error() { echo -e "${RED}==>${NC} $1"; }

# Get the directory where this script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "Claude Voice Server - Installation"
echo "==================================="
echo ""

# Check for macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    error "This installer is for macOS only"
    exit 1
fi

# Check for Homebrew
if ! command -v brew &> /dev/null; then
    error "Homebrew is required but not installed."
    echo "Install it from: https://brew.sh"
    exit 1
fi

# Install system dependencies
info "Checking system dependencies..."

BREW_PACKAGES=("tmux" "zbar")
MISSING_PACKAGES=()

for pkg in "${BREW_PACKAGES[@]}"; do
    if ! brew list "$pkg" &> /dev/null; then
        MISSING_PACKAGES+=("$pkg")
    fi
done

if [ ${#MISSING_PACKAGES[@]} -gt 0 ]; then
    info "Installing: ${MISSING_PACKAGES[*]}"
    brew install "${MISSING_PACKAGES[@]}"
else
    info "System dependencies already installed (tmux, zbar)"
fi

# Check for Python 3.9+
info "Checking Python version..."
PYTHON_VERSION=$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')
PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)

if [ "$PYTHON_MAJOR" -lt 3 ] || ([ "$PYTHON_MAJOR" -eq 3 ] && [ "$PYTHON_MINOR" -lt 9 ]); then
    error "Python 3.9+ required, found $PYTHON_VERSION"
    exit 1
fi
info "Python $PYTHON_VERSION found"

# Check for pipx
if ! command -v pipx &> /dev/null; then
    info "Installing pipx..."
    brew install pipx
    pipx ensurepath
    warn "You may need to restart your terminal for pipx to be in PATH"
fi

# Install the package
info "Installing claude-connect via pipx..."

# Find system Python 3.9-3.12 (kokoro deps don't have wheels for 3.14 yet)
PYTHON_BIN=""
for v in 3.12 3.11 3.10 3.9; do
    if command -v "python$v" &> /dev/null; then
        PYTHON_BIN="python$v"
        break
    fi
done

if [ -z "$PYTHON_BIN" ]; then
    error "Python 3.9-3.12 required (kokoro doesn't support 3.14 yet)"
    echo "Install with: brew install python@3.11"
    exit 1
fi

info "Using $PYTHON_BIN for installation"

# Install from local directory with specific Python version
pipx install "$SCRIPT_DIR" --python "$PYTHON_BIN" $FORCE

echo ""
echo -e "${GREEN}Installation complete!${NC}"
echo ""
echo "Usage:"
echo "  claude-connect        # Start the server (run from anywhere)"
echo ""
echo "The server will display a QR code for your iOS app to scan."
echo ""

# Check for Claude CLI
if ! command -v claude &> /dev/null; then
    warn "Note: 'claude' CLI not found in PATH"
    echo "  Install Claude Code from: https://claude.ai/code"
    echo ""
fi
