"""Tailscale detection utilities for remote access."""
import json
import shutil
import subprocess


def is_tailscale_installed() -> bool:
    """Check if the Tailscale CLI is installed."""
    return shutil.which("tailscale") is not None


def is_tailscale_running() -> bool:
    """Check if Tailscale daemon is running and authenticated."""
    try:
        result = subprocess.run(
            ["tailscale", "status", "--json"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return False
        status = json.loads(result.stdout)
        return status.get("BackendState") == "Running"
    except (FileNotFoundError, json.JSONDecodeError, subprocess.TimeoutExpired):
        return False


def get_tailscale_ip() -> "str | None":
    """Get the Tailscale IPv4 address, or None if unavailable."""
    try:
        result = subprocess.run(
            ["tailscale", "ip", "--4"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode != 0:
            return None
        ip = result.stdout.strip()
        return ip if ip else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
