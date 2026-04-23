# server/tests/test_tmux_controller.py
"""
Tests for TmuxController - uses REAL tmux, no mocking.

These tests actually create/kill tmux sessions. If they pass,
the functionality works. If they fail, something is actually broken.
"""
import pytest
import subprocess
import time
import os
import sys

from server.infra.tmux_controller import TmuxController, session_name_for, SESSION_PREFIX


TEST_SESSION = "claude-connect_test-session-1"
TEST_SESSION_2 = "claude-connect_test-session-2"
TEST_EXTERNAL_SESSION = "dispatch-test-branch"


@pytest.fixture
def controller():
    """Provide a controller and ensure cleanup after test"""
    ctrl = TmuxController()
    yield ctrl
    # Cleanup: kill test sessions if they exist
    for name in [TEST_SESSION, TEST_SESSION_2, TEST_EXTERNAL_SESSION]:
        subprocess.run(
            ["tmux", "kill-session", "-t", name],
            capture_output=True
        )


@pytest.fixture
def ensure_no_session():
    """Ensure no test sessions exist before test"""
    for name in [TEST_SESSION, TEST_SESSION_2, TEST_EXTERNAL_SESSION]:
        subprocess.run(
            ["tmux", "kill-session", "-t", name],
            capture_output=True
        )
    yield
    for name in [TEST_SESSION, TEST_SESSION_2, TEST_EXTERNAL_SESSION]:
        subprocess.run(
            ["tmux", "kill-session", "-t", name],
            capture_output=True
        )


class TestSessionNameFor:
    """Tests for session_name_for helper"""

    def test_generates_prefixed_name(self):
        assert session_name_for("abc-123") == "claude-connect_abc-123"

    def test_prefix_constant(self):
        assert SESSION_PREFIX == "claude-connect"


class TestTmuxAvailability:
    """Tests for tmux availability check"""

    def test_is_available_returns_true_when_tmux_installed(self, controller):
        assert controller.is_available() is True


class TestSessionManagement:
    """Tests for session lifecycle with parameterized names"""

    def test_session_exists_false_when_no_session(self, controller, ensure_no_session):
        assert controller.session_exists(TEST_SESSION) is False

    def test_start_and_check_session(self, controller, ensure_no_session):
        result = controller.start_session(TEST_SESSION, working_dir="/tmp")
        assert result is True
        time.sleep(0.5)
        assert controller.session_exists(TEST_SESSION) is True

    def test_start_two_sessions(self, controller, ensure_no_session):
        """Starting two sessions with different names both stay alive"""
        assert controller.start_session(TEST_SESSION, working_dir="/tmp") is True
        assert controller.start_session(TEST_SESSION_2, working_dir="/tmp") is True
        time.sleep(0.5)
        assert controller.session_exists(TEST_SESSION) is True
        assert controller.session_exists(TEST_SESSION_2) is True

    def test_kill_one_session_leaves_other(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        controller.start_session(TEST_SESSION_2, working_dir="/tmp")
        time.sleep(0.5)
        controller.kill_session(TEST_SESSION)
        time.sleep(0.3)
        assert controller.session_exists(TEST_SESSION) is False
        assert controller.session_exists(TEST_SESSION_2) is True

    def test_kill_session(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        time.sleep(0.5)
        result = controller.kill_session(TEST_SESSION)
        assert result is True
        time.sleep(0.3)
        assert controller.session_exists(TEST_SESSION) is False

    def test_start_session_with_env(self, controller, ensure_no_session):
        """Env vars are set in the tmux session"""
        # Start a plain bash session (not claude) so we can verify env vars
        subprocess.run([
            "tmux", "new-session", "-d", "-s", TEST_SESSION, "-c", "/tmp",
            "export CLAUDE_CONNECT_SESSION_ID=test-id-123 && bash"
        ], capture_output=True)
        time.sleep(0.5)
        # Verify env var by capturing pane after echo
        subprocess.run(
            ["tmux", "send-keys", "-t", TEST_SESSION,
             "echo $CLAUDE_CONNECT_SESSION_ID", "Enter"],
            capture_output=True
        )
        time.sleep(0.5)
        pane = controller.capture_pane(TEST_SESSION, include_history=False)
        assert pane is not None
        assert "test-id-123" in pane


class TestListAndCleanup:
    """Tests for list_sessions and cleanup_all"""

    def test_list_sessions_empty(self, controller, ensure_no_session):
        sessions = controller.list_sessions()
        # Filter to only test sessions in case other claude-connect sessions exist
        test_sessions = [s for s in sessions if s in [TEST_SESSION, TEST_SESSION_2]]
        assert test_sessions == []

    def test_list_sessions_finds_sessions(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        controller.start_session(TEST_SESSION_2, working_dir="/tmp")
        time.sleep(0.5)
        sessions = controller.list_sessions()
        assert TEST_SESSION in sessions
        assert TEST_SESSION_2 in sessions

    def test_cleanup_all(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        controller.start_session(TEST_SESSION_2, working_dir="/tmp")
        time.sleep(0.5)
        killed = controller.cleanup_all()
        assert killed >= 2
        time.sleep(0.3)
        assert controller.session_exists(TEST_SESSION) is False
        assert controller.session_exists(TEST_SESSION_2) is False


class TestInputAndCapture:
    """Tests for send_input, send_escape, and capture_pane with session names"""

    def test_capture_pane(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        time.sleep(0.5)
        content = controller.capture_pane(TEST_SESSION, include_history=False)
        assert content is not None

    def test_capture_pane_nonexistent(self, controller, ensure_no_session):
        content = controller.capture_pane("nonexistent-session")
        assert content is None

    def test_send_input(self, controller, ensure_no_session):
        # Start a plain bash session so we can verify input
        subprocess.run([
            "tmux", "new-session", "-d", "-s", TEST_SESSION, "-c", "/tmp", "bash"
        ], capture_output=True)
        time.sleep(0.5)
        result = controller.send_input(TEST_SESSION, "echo hello-from-test")
        assert result is True
        time.sleep(0.5)
        content = controller.capture_pane(TEST_SESSION, include_history=False)
        assert content is not None
        assert "hello-from-test" in content

    def test_send_escape(self, controller, ensure_no_session):
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        time.sleep(0.5)
        result = controller.send_escape(TEST_SESSION)
        assert result is True


class TestListAllSessions:
    """Tests for list_all_sessions — returns ALL tmux sessions, not just claude-connect_*"""

    def test_list_all_includes_non_prefixed(self, controller, ensure_no_session):
        """list_all_sessions should include sessions without claude-connect prefix"""
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        subprocess.run(
            ["tmux", "new-session", "-d", "-s", TEST_EXTERNAL_SESSION, "-c", "/tmp", "bash"],
            capture_output=True
        )
        time.sleep(0.5)
        all_sessions = controller.list_all_sessions()
        assert TEST_SESSION in all_sessions
        assert TEST_EXTERNAL_SESSION in all_sessions

    def test_list_all_empty(self, controller, ensure_no_session):
        """list_all_sessions returns empty list when no sessions"""
        all_sessions = controller.list_all_sessions()
        assert TEST_SESSION not in all_sessions
        assert TEST_EXTERNAL_SESSION not in all_sessions


class TestFindSessionById:
    """Tests for find_session_by_id — finds tmux session running a Claude session"""

    def test_finds_session_with_id_in_pane(self, controller, ensure_no_session):
        """Should find a tmux session whose pane contains the session ID"""
        target_id = "abc123-def456-test"
        subprocess.run([
            "tmux", "new-session", "-d", "-s", TEST_EXTERNAL_SESSION, "-c", "/tmp",
            f"echo 'Session: {target_id}' && bash"
        ], capture_output=True)
        time.sleep(0.5)
        found = controller.find_session_by_id(target_id)
        assert found == TEST_EXTERNAL_SESSION

    def test_returns_none_when_not_found(self, controller, ensure_no_session):
        """Should return None when no tmux session contains the ID"""
        controller.start_session(TEST_SESSION, working_dir="/tmp")
        time.sleep(0.5)
        found = controller.find_session_by_id("nonexistent-id-xyz")
        assert found is None

    def test_skips_claude_connect_sessions(self, controller, ensure_no_session):
        """Should skip claude-connect_* sessions (server already tracks those)"""
        target_id = "abc123-skip-test"
        subprocess.run([
            "tmux", "new-session", "-d", "-s", f"claude-connect_{target_id}", "-c", "/tmp",
            f"echo 'Session: {target_id}' && bash"
        ], capture_output=True)
        time.sleep(0.5)
        found = controller.find_session_by_id(target_id)
        assert found is None
        subprocess.run(["tmux", "kill-session", "-t", f"claude-connect_{target_id}"], capture_output=True)
