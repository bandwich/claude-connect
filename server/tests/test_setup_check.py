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
