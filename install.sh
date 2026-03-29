#!/bin/bash
# Claude Connect - Setup
# Installs all dependencies and sets up the claude-connect CLI

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
NC='\033[0m'

info() { echo -e "${GREEN}==>${NC} $1"; }
warn() { echo -e "${YELLOW}==>${NC} $1"; }
error() { echo -e "${RED}==>${NC} $1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo ""
echo "Claude Connect"
echo "=============="
echo ""

# Check for macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    error "This installer is for macOS only"
    exit 1
fi

# Install Homebrew if missing
if ! command -v brew &> /dev/null; then
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add brew to PATH for this session (Apple Silicon vs Intel)
    if [[ -f /opt/homebrew/bin/brew ]]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
    elif [[ -f /usr/local/bin/brew ]]; then
        eval "$(/usr/local/bin/brew shellenv)"
    fi
fi

# Install tmux
if ! brew list tmux &> /dev/null; then
    info "Installing tmux..."
    brew install tmux
else
    info "tmux already installed"
fi

# Install pipx
if ! command -v pipx &> /dev/null; then
    info "Installing pipx..."
    brew install pipx
    pipx ensurepath
    warn "You may need to restart your terminal for pipx to be in PATH"
fi

# Find a compatible Python (3.9-3.12, needed for kokoro wheels)
PYTHON_BIN=""
for v in 3.12 3.11 3.10 3.9; do
    if command -v "python$v" &> /dev/null; then
        PYTHON_BIN="python$v"
        break
    fi
done

# Install Python 3.11 if no compatible version found
if [ -z "$PYTHON_BIN" ]; then
    info "Installing Python 3.11 (required for TTS dependencies)..."
    brew install python@3.11
    PYTHON_BIN="python3.11"
fi

info "Using $PYTHON_BIN for installation"

# Install from local directory
info "Installing claude-connect..."
pipx install "$SCRIPT_DIR" --python "$PYTHON_BIN" $FORCE

echo ""
echo -e "${GREEN}Setup complete!${NC}"
echo ""
echo "Usage:"
echo "  claude-connect        # Start the server"
echo ""
echo "After changing server code, reinstall:"
echo "  pipx install --force $SCRIPT_DIR"
echo ""

# Check for Claude CLI
if ! command -v claude &> /dev/null; then
    warn "Note: 'claude' CLI not found in PATH"
    echo "  Install Claude Code from: https://claude.ai/code"
    echo ""
fi
