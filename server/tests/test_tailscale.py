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
