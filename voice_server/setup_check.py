"""Startup dependency checks for claude-connect."""

import shutil
import subprocess
import sys

# Colors
GREEN = "\033[0;32m"
YELLOW = "\033[1;33m"
RED = "\033[0;31m"
BOLD = "\033[1m"
NC = "\033[0m"


def check_tmux() -> bool:
    """Check if tmux is installed."""
    return shutil.which("tmux") is not None


def install_tmux_homebrew() -> bool:
    """Install tmux via Homebrew. Returns True if successful."""
    if shutil.which("brew") is None:
        print(f"\n{YELLOW}Homebrew is not installed.{NC}")
        print(f"Install it from: {BOLD}https://brew.sh{NC}")
        print(f"Then run {BOLD}claude-connect{NC} again.\n")
        return False

    print(f"\n{GREEN}Installing tmux via Homebrew...{NC}")
    result = subprocess.run(["brew", "install", "tmux"])
    if result.returncode != 0:
        print(f"\n{RED}Failed to install tmux.{NC}")
        print(f"Try manually: {BOLD}brew install tmux{NC}\n")
        return False

    print(f"{GREEN}Done!{NC}\n")
    return True


def ensure_dependencies():
    """Check dependencies and interactively install if missing.

    Called before server start. Exits if dependencies can't be resolved.
    """
    if check_tmux():
        return

    print(f"\n{BOLD}Claude Connect{NC} requires {BOLD}tmux{NC}, which is not currently installed.\n")
    print("How would you like to install it?")
    print(f"  {BOLD}[1]{NC} Install via Homebrew (recommended)")
    print(f"  {BOLD}[2]{NC} Install manually")
    print()

    try:
        choice = input("> ").strip()
    except (KeyboardInterrupt, EOFError):
        print()
        sys.exit(1)

    if choice == "1":
        if install_tmux_homebrew() and check_tmux():
            return
        sys.exit(1)
    else:
        print(f"\nInstall tmux and run {BOLD}claude-connect{NC} again.")
        print(f"See: {BOLD}https://github.com/tmux/tmux/wiki/Installing{NC}\n")
        sys.exit(0)
