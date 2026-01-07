# voice_server/tests/test_tmux_controller.py
import pytest
from unittest.mock import patch, MagicMock


class TestTmuxControllerAvailability:
    """Tests for TmuxController availability check"""

    def test_is_available_returns_true_when_tmux_installed(self):
        """Should return True when tmux command succeeds"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            assert controller.is_available() is True
            mock_run.assert_called_once()

    def test_is_available_returns_false_when_tmux_not_installed(self):
        """Should return False when tmux command fails"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=1)
            assert controller.is_available() is False


class TestTmuxControllerSession:
    """Tests for TmuxController session management"""

    def test_session_exists_returns_true_when_session_running(self):
        """Should return True when tmux session exists"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=0)
            assert controller.session_exists() is True
            mock_run.assert_called_with(
                ["tmux", "has-session", "-t", "claude_voice"],
                capture_output=True,
                text=True
            )

    def test_session_exists_returns_false_when_no_session(self):
        """Should return False when tmux session doesn't exist"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=1)
            assert controller.session_exists() is False


class TestTmuxControllerStartSession:
    """Tests for starting tmux sessions"""

    def test_start_session_creates_new_tmux_session(self):
        """Should create tmux session running claude"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            # First call: has-session (doesn't exist)
            # Second call: new-session
            mock_run.side_effect = [
                MagicMock(returncode=1),  # has-session fails
                MagicMock(returncode=0),  # new-session succeeds
            ]

            result = controller.start_session()

            assert result is True
            assert mock_run.call_count == 2

    def test_start_session_kills_existing_first(self):
        """Should kill existing session before starting new one"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            # First call: has-session (exists)
            # Second call: kill-session
            # Third call: new-session
            mock_run.side_effect = [
                MagicMock(returncode=0),  # has-session succeeds
                MagicMock(returncode=0),  # kill-session succeeds
                MagicMock(returncode=0),  # new-session succeeds
            ]

            result = controller.start_session()

            assert result is True
            assert mock_run.call_count == 3

    def test_start_session_with_resume_id(self):
        """Should run claude --resume when resume_id provided"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.side_effect = [
                MagicMock(returncode=1),  # has-session fails
                MagicMock(returncode=0),  # new-session succeeds
            ]

            result = controller.start_session(resume_id="abc123")

            assert result is True
            # Verify the claude --resume command was used
            new_session_call = mock_run.call_args_list[1]
            assert "--resume" in str(new_session_call)
            assert "abc123" in str(new_session_call)

    def test_start_session_with_working_dir(self):
        """Should set working directory when provided"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.side_effect = [
                MagicMock(returncode=1),
                MagicMock(returncode=0),
            ]

            result = controller.start_session(working_dir="/some/path")

            assert result is True
            new_session_call = mock_run.call_args_list[1]
            assert "-c" in str(new_session_call)
            assert "/some/path" in str(new_session_call)


class TestTmuxControllerInput:
    """Tests for sending input to tmux sessions"""

    def test_send_input_sends_keys_to_session(self):
        """Should send text + Enter to tmux session as separate calls"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=0)

            result = controller.send_input("hello world")

            assert result is True
            assert mock_run.call_count == 2
            # First call: send text
            first_call = mock_run.call_args_list[0][0][0]
            assert "send-keys" in first_call
            assert "hello world" in first_call
            # Second call: send Enter
            second_call = mock_run.call_args_list[1][0][0]
            assert "Enter" in second_call

    def test_send_input_returns_false_on_failure(self):
        """Should return False when send-keys fails"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=1)

            result = controller.send_input("test")

            assert result is False


class TestTmuxControllerKill:
    """Tests for killing tmux sessions"""

    def test_kill_session_kills_tmux_session(self):
        """Should kill the claude_voice tmux session"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=0)

            result = controller.kill_session()

            assert result is True
            mock_run.assert_called_with(
                ["tmux", "kill-session", "-t", "claude_voice"],
                capture_output=True,
                text=True
            )

    def test_kill_session_returns_false_on_failure(self):
        """Should return False when kill fails"""
        from tmux_controller import TmuxController

        controller = TmuxController()

        with patch('subprocess.run') as mock_run:
            mock_run.return_value = MagicMock(returncode=1)

            result = controller.kill_session()

            assert result is False
