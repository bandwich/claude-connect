"""Startup dependency checks for claude-connect."""

import shutil
import subprocess
import sys

from server.infra.tailscale import is_tailscale_installed, is_tailscale_running

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


def check_tailscale_setup():
    """Check Tailscale status and offer setup if not installed.

    Optional — server runs without Tailscale (local network only).
    Called after tmux check in ensure_dependencies().
    """
    if is_tailscale_installed():
        if is_tailscale_running():
            return
        print(f"\n{YELLOW}Tailscale is installed but not connected.{NC}")
        print(f"Run {BOLD}tailscale up{NC} to enable remote access.\n")
        return

    print(f"\n{BOLD}Remote Access (optional){NC}\n")
    print("Tailscale lets you connect to Claude Connect from anywhere —")
    print("cellular, different WiFi, etc. It's a free encrypted VPN that")
    print("runs in the background. Both your Mac and iPhone need it.\n")
    print(f"  {BOLD}[1]{NC} Install via Homebrew")
    print(f"  {BOLD}[2]{NC} Skip — local network only")
    print()

    try:
        choice = input("> ").strip()
    except (KeyboardInterrupt, EOFError):
        print()
        return

    if choice == "1":
        if shutil.which("brew") is None:
            print(f"\n{YELLOW}Homebrew is not installed.{NC}")
            print(f"Install it from: {BOLD}https://brew.sh{NC}")
            print(f"Then run {BOLD}brew install tailscale{NC}\n")
            return

        print(f"\n{GREEN}Installing Tailscale via Homebrew...{NC}")
        subprocess.run(["brew", "install", "tailscale"])

        print(f"\n{BOLD}Next steps:{NC}")
        print(f"  1. Run {BOLD}tailscale up{NC} to log in (opens browser)")
        print(f"  2. Install {BOLD}Tailscale{NC} from the App Store on your iPhone")
        print(f"  3. Sign in with the same account on both devices")
        print(f"  4. Restart {BOLD}claude-connect{NC}\n")
    else:
        print(f"\n{BOLD}Skipped.{NC} Server will use local network only.\n")


def ensure_dependencies():
    """Check dependencies and interactively install if missing.

    Called before server start. Exits if dependencies can't be resolved.
    """
    if check_tmux():
        check_tailscale_setup()
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
            check_tailscale_setup()
            return
        sys.exit(1)
    else:
        print(f"\nInstall tmux and run {BOLD}claude-connect{NC} again.")
        print(f"See: {BOLD}https://github.com/tmux/tmux/wiki/Installing{NC}\n")
        sys.exit(0)
