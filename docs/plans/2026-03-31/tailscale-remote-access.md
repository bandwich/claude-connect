# Tailscale Remote Access Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use execute-plan to implement this plan task-by-task.

**Goal:** Enable Claude Connect to use Tailscale IP in the QR code so the iOS app can connect from anywhere (cellular, different WiFi), with guided optional Tailscale setup at first run.

**Architecture:** New `server/infra/tailscale.py` module detects Tailscale state via CLI subprocess calls. `setup_check.py` gets an optional Tailscale prompt after the tmux check. `main.py` prefers Tailscale IP over local IP when available.

**Tech Stack:** Python subprocess (`tailscale` CLI), shutil.which, existing test patterns (pytest, unittest.mock)

**Risky Assumptions:** `tailscale ip --4` and `tailscale status --json` work reliably on macOS via Homebrew. Verified by installing Tailscale and testing CLI commands before writing code.

---

### Task 1: Tailscale Detection Module

**Files:**
- Create: `server/infra/tailscale.py`
- Create: `server/tests/test_tailscale.py`

**Step 1: Write the failing tests**

```python
"""Tests for Tailscale detection utilities."""
import json
import subprocess
from unittest.mock import patch, MagicMock

from server.infra.tailscale import is_tailscale_installed, is_tailscale_running, get_tailscale_ip

TS = "server.infra.tailscale"


class TestIsTailscaleInstalled:
    def test_installed(self):
        with patch(f"{TS}.shutil.which", return_value="/opt/homebrew/bin/tailscale"):
            assert is_tailscale_installed() is True

    def test_not_installed(self):
        with patch(f"{TS}.shutil.which", return_value=None):
            assert is_tailscale_installed() is False


class TestIsTailscaleRunning:
    def test_running(self):
        status = {"BackendState": "Running"}
        result = MagicMock(returncode=0, stdout=json.dumps(status))
        with patch(f"{TS}.subprocess.run", return_value=result):
            assert is_tailscale_running() is True

    def test_stopped(self):
        status = {"BackendState": "Stopped"}
        result = MagicMock(returncode=0, stdout=json.dumps(status))
        with patch(f"{TS}.subprocess.run", return_value=result):
            assert is_tailscale_running() is False

    def test_not_installed(self):
        with patch(f"{TS}.subprocess.run", side_effect=FileNotFoundError):
            assert is_tailscale_running() is False

    def test_daemon_not_running(self):
        result = MagicMock(returncode=1, stdout="", stderr="failed to connect")
        with patch(f"{TS}.subprocess.run", return_value=result):
            assert is_tailscale_running() is False


class TestGetTailscaleIp:
    def test_returns_ip(self):
        result = MagicMock(returncode=0, stdout="100.64.0.1\n")
        with patch(f"{TS}.subprocess.run", return_value=result):
            assert get_tailscale_ip() == "100.64.0.1"

    def test_not_running(self):
        result = MagicMock(returncode=1, stdout="")
        with patch(f"{TS}.subprocess.run", return_value=result):
            assert get_tailscale_ip() is None

    def test_not_installed(self):
        with patch(f"{TS}.subprocess.run", side_effect=FileNotFoundError):
            assert get_tailscale_ip() is None

    def test_empty_output(self):
        result = MagicMock(returncode=0, stdout="")
        with patch(f"{TS}.subprocess.run", return_value=result):
            assert get_tailscale_ip() is None
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/aaron/Desktop/max/server/tests && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest test_tailscale.py -v`
Expected: FAIL with `ModuleNotFoundError` (module doesn't exist yet)

**Step 3: Write the implementation**

```python
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


def get_tailscale_ip() -> str | None:
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
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/aaron/Desktop/max/server/tests && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest test_tailscale.py -v`
Expected: All 10 tests PASS

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max && git add server/infra/tailscale.py server/tests/test_tailscale.py
git commit -m "feat: add Tailscale detection module"
```

---

### Task 2: Guided Tailscale Setup in Startup Check

**Files:**
- Modify: `server/infra/setup_check.py`
- Create: `server/tests/test_setup_check.py`

**Step 1: Write the failing tests**

```python
"""Tests for startup dependency checks."""
from unittest.mock import patch, MagicMock

from server.infra.setup_check import check_tailscale_setup

SC = "server.infra.setup_check"


class TestCheckTailscaleSetup:
    def test_running_no_output(self, capsys):
        """When Tailscale is running, nothing is printed."""
        with patch(f"{SC}.is_tailscale_installed", return_value=True), \
             patch(f"{SC}.is_tailscale_running", return_value=True):
            check_tailscale_setup()
        assert capsys.readouterr().out == ""

    def test_installed_not_running_shows_warning(self, capsys):
        """When installed but not running, show warning."""
        with patch(f"{SC}.is_tailscale_installed", return_value=True), \
             patch(f"{SC}.is_tailscale_running", return_value=False):
            check_tailscale_setup()
        output = capsys.readouterr().out
        assert "tailscale up" in output
        assert "not connected" in output.lower() or "not running" in output.lower()

    def test_not_installed_skip(self, capsys):
        """When not installed and user skips, server continues."""
        with patch(f"{SC}.is_tailscale_installed", return_value=False), \
             patch("builtins.input", return_value="2"):
            check_tailscale_setup()
        output = capsys.readouterr().out
        assert "remote access" in output.lower() or "tailscale" in output.lower()

    def test_not_installed_brew_install(self, capsys):
        """When not installed and user picks brew, run brew install."""
        with patch(f"{SC}.is_tailscale_installed", return_value=False), \
             patch("builtins.input", return_value="1"), \
             patch(f"{SC}.subprocess.run") as mock_run, \
             patch(f"{SC}.shutil.which", return_value="/opt/homebrew/bin/brew"):
            mock_run.return_value.returncode = 0
            check_tailscale_setup()
        mock_run.assert_called_once_with(["brew", "install", "tailscale"])
        output = capsys.readouterr().out
        assert "tailscale up" in output

    def test_not_installed_no_brew(self, capsys):
        """When brew not available, show manual install instructions."""
        with patch(f"{SC}.is_tailscale_installed", return_value=False), \
             patch("builtins.input", return_value="1"), \
             patch(f"{SC}.shutil.which", return_value=None):
            check_tailscale_setup()
        output = capsys.readouterr().out
        assert "homebrew" in output.lower() or "brew.sh" in output.lower()
```

**Step 2: Run tests to verify they fail**

Run: `cd /Users/aaron/Desktop/max/server/tests && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest test_setup_check.py -v`
Expected: FAIL with `ImportError` (function doesn't exist yet)

**Step 3: Write the implementation**

Add to `server/infra/setup_check.py`, after the existing `ensure_dependencies()` function:

```python
from server.infra.tailscale import is_tailscale_installed, is_tailscale_running


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
```

Then add the call in `ensure_dependencies()`:

```python
def ensure_dependencies():
    # ... existing tmux check ...
    if check_tmux():
        check_tailscale_setup()
        return
    # ... rest of tmux install flow ...
```

Also add `check_tailscale_setup()` after successful tmux install:

```python
    if choice == "1":
        if install_tmux_homebrew() and check_tmux():
            check_tailscale_setup()
            return
        sys.exit(1)
```

**Step 4: Run tests to verify they pass**

Run: `cd /Users/aaron/Desktop/max/server/tests && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest test_setup_check.py -v`
Expected: All 5 tests PASS

**Step 5: Commit**

```bash
cd /Users/aaron/Desktop/max && git add server/infra/setup_check.py server/infra/tailscale.py server/tests/test_setup_check.py
git commit -m "feat: add guided Tailscale setup in startup checks"
```

---

### Task 3: Use Tailscale IP in QR Code

**Files:**
- Modify: `server/main.py:1296-1302`

**Step 1: Modify main.py IP selection**

Replace lines ~1296-1302 in `server/main.py`:

```python
        from server.infra.qr_display import get_local_ip, print_startup_banner
        from server.infra.tailscale import get_tailscale_ip

        ip = get_tailscale_ip() or get_local_ip()
        if ip:
            print_startup_banner(ip, PORT)
        else:
            print(f"WARNING: Could not detect local IP. Server running on port {PORT}")
```

**Step 2: Run all tests to verify nothing broke**

Run: `cd /Users/aaron/Desktop/max/server/tests && /Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest test_qr_display.py test_tailscale.py test_setup_check.py -v`
Expected: All tests PASS

**Step 3: Commit**

```bash
cd /Users/aaron/Desktop/max && git add server/main.py
git commit -m "feat: prefer Tailscale IP over local IP in QR code"
```

---

### Task 4: Install Tailscale and Verify End-to-End

This is the verification task. No code changes.

**Step 1: Install Tailscale on Mac**

```bash
brew install tailscale
```

**Step 2: Start Tailscale and authenticate**

```bash
sudo tailscaled &
tailscale up
```

This opens a browser for login. Sign in with Google/Apple/GitHub.

**Step 3: Verify CLI commands work**

```bash
tailscale status --json | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['BackendState'])"
# Expected: Running

tailscale ip --4
# Expected: 100.x.x.x
```

**Step 4: Install Tailscale on iPhone**

- Install "Tailscale" from the App Store
- Open it, sign in with the same account used on Mac

**Step 5: Reinstall server and test**

```bash
pipx install --force /Users/aaron/Desktop/max
claude-connect
```

- QR code should show `ws://100.x.x.x:8765`
- Turn off WiFi on phone
- Scan QR code with Claude Connect app over cellular
- Confirm connection works

**CHECKPOINT:** If the QR code shows a `192.168.x.x` address instead of `100.x.x.x`, debug the Tailscale detection. If the phone can't connect over cellular, verify both devices are on the same tailnet (`tailscale status` should show both).
