# voice_server/tests/test_session_manager.py
import pytest
import tempfile
import os
import json
import time


class TestSessionManager:
    """Tests for SessionManager class"""

    def test_list_projects_returns_empty_for_empty_dir(self, tmp_path):
        """Should return empty list when no projects exist"""
        from session_manager import SessionManager

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert projects == []

    def test_list_projects_returns_projects_with_sessions(self, tmp_path):
        """Should return projects with correct session counts"""
        from session_manager import SessionManager

        # Create mock project structure: -Users-test-project1
        project1_dir = tmp_path / "-Users-test-project1"
        project1_dir.mkdir()
        (project1_dir / "session1.jsonl").write_text('{"type":"summary"}')
        (project1_dir / "session2.jsonl").write_text('{"type":"summary"}')

        # Create another project
        project2_dir = tmp_path / "-Users-test-project2"
        project2_dir.mkdir()
        (project2_dir / "session1.jsonl").write_text('{"type":"summary"}')

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert len(projects) == 2

        # Find project1
        p1 = next(p for p in projects if p.name == "project1")
        assert p1.path == "/Users/test/project1"
        assert p1.session_count == 2
        assert p1.folder_name == "-Users-test-project1"  # Original folder name for direct lookup

        # Find project2
        p2 = next(p for p in projects if p.name == "project2")
        assert p2.session_count == 1
        assert p2.folder_name == "-Users-test-project2"

    def test_list_sessions_returns_sessions_sorted_by_time(self, tmp_path):
        """Should return sessions sorted by most recent first"""
        from session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-myproject"
        project_dir.mkdir()

        # Create session files with different timestamps
        session1 = project_dir / "abc123.jsonl"
        session1.write_text(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "Hello"},
            "timestamp": "2026-01-01T10:00:00Z"
        }) + "\n" + json.dumps({
            "type": "assistant",
            "message": {"role": "assistant", "content": [{"type": "text", "text": "Hi there!"}]},
            "timestamp": "2026-01-01T10:00:05Z"
        }))

        session2 = project_dir / "def456.jsonl"
        session2.write_text(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "Later message"},
            "timestamp": "2026-01-02T10:00:00Z"
        }))

        # Set file mtimes to control sort order
        os.utime(session1, (time.time() - 100, time.time() - 100))
        os.utime(session2, (time.time(), time.time()))

        manager = SessionManager(projects_dir=str(tmp_path))
        # Pass the actual folder name, not the decoded path
        sessions = manager.list_sessions("-Users-test-myproject")

        assert len(sessions) == 2
        assert sessions[0].id == "def456"  # Most recent first
        assert sessions[1].id == "abc123"
        assert sessions[1].title == "Hello"  # First user message
        assert sessions[1].message_count == 2

    def test_get_session_history_returns_messages(self, tmp_path):
        """Should return all messages from a session"""
        from session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-myproject"
        project_dir.mkdir()

        session_file = project_dir / "abc123.jsonl"
        session_file.write_text(
            json.dumps({
                "type": "user",
                "message": {"role": "user", "content": "Hello Claude"},
                "timestamp": "2026-01-01T10:00:00Z"
            }) + "\n" +
            json.dumps({
                "type": "assistant",
                "message": {"role": "assistant", "content": [{"type": "text", "text": "Hello! How can I help?"}]},
                "timestamp": "2026-01-01T10:00:05Z"
            }) + "\n" +
            json.dumps({
                "type": "user",
                "message": {"role": "user", "content": "What is 2+2?"},
                "timestamp": "2026-01-01T10:00:10Z"
            })
        )

        manager = SessionManager(projects_dir=str(tmp_path))
        # Pass the actual folder name, not the decoded path
        messages = manager.get_session_history("-Users-test-myproject", "abc123")

        assert len(messages) == 3
        assert messages[0].role == "user"
        assert messages[0].content == "Hello Claude"
        assert messages[1].role == "assistant"
        assert "Hello! How can I help?" in messages[1].content
        assert messages[2].content == "What is 2+2?"

    def test_list_sessions_filters_warmup_sessions(self, tmp_path):
        """Sessions with titles starting with 'Warmup' should be filtered out"""
        from session_manager import SessionManager

        project_dir = tmp_path / "test-project"
        project_dir.mkdir()

        # Create a Warmup session
        warmup_session = project_dir / "warmup123.jsonl"
        warmup_session.write_text(json.dumps({
            "message": {"role": "user", "content": "Warmup test"}
        }) + "\n")

        # Create a normal session
        normal_session = project_dir / "normal456.jsonl"
        normal_session.write_text(json.dumps({
            "message": {"role": "user", "content": "Hello Claude"}
        }) + "\n")

        manager = SessionManager(str(tmp_path))
        sessions = manager.list_sessions("test-project")

        assert len(sessions) == 1
        assert sessions[0].id == "normal456"

    def test_list_sessions_filters_zero_message_sessions(self, tmp_path):
        """Sessions with 0 messages should be filtered out"""
        from session_manager import SessionManager

        project_dir = tmp_path / "test-project"
        project_dir.mkdir()

        # Create an empty session (no user/assistant messages)
        empty_session = project_dir / "empty123.jsonl"
        empty_session.write_text('{"type": "system", "content": "init"}\n')

        # Create a session with messages
        normal_session = project_dir / "normal456.jsonl"
        normal_session.write_text(json.dumps({
            "message": {"role": "user", "content": "Hello"}
        }) + "\n")

        manager = SessionManager(str(tmp_path))
        sessions = manager.list_sessions("test-project")

        assert len(sessions) == 1
        assert sessions[0].id == "normal456"

    def test_list_projects_decodes_path_with_underscores_correctly(self, tmp_path):
        """Underscores in paths should NOT be converted to slashes.

        Claude encodes both / and _ as - in folder names, so we need to
        read the cwd from session files to get the actual path.
        e.g., folder -Users-aaron-Desktop-max-voice-server should decode to
        /Users/aaron/Desktop/max/voice_server (not /Users/aaron/Desktop/max/voice/server)

        Without cwd from sessions, we can't know which - was originally _ vs /
        """
        from session_manager import SessionManager

        # Claude encodes /Users/aaron/Desktop/max/voice_server as:
        # -Users-aaron-Desktop-max-voice-server (both / and _ become -)
        project_dir = tmp_path / "-Users-aaron-Desktop-max-voice-server"
        project_dir.mkdir()

        # Create a session with cwd that shows the ACTUAL path
        session_file = project_dir / "session123.jsonl"
        session_file.write_text(json.dumps({
            "cwd": "/Users/aaron/Desktop/max/voice_server",
            "message": {"role": "user", "content": "Hello"}
        }) + "\n")

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert len(projects) == 1
        p = projects[0]
        # The path should preserve the underscore (from cwd), not convert to slash
        assert p.path == "/Users/aaron/Desktop/max/voice_server"
        assert "voice/server" not in p.path  # Should NOT have slash here
        assert p.name == "voice_server"
        assert p.folder_name == "-Users-aaron-Desktop-max-voice-server"