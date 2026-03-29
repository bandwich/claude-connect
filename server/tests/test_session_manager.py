# server/tests/test_session_manager.py
import pytest
import tempfile
import os
import json
import time


class TestSessionManager:
    """Tests for SessionManager class"""

    def test_list_projects_returns_empty_for_empty_dir(self, tmp_path):
        """Should return empty list when no projects exist"""
        from server.services.session_manager import SessionManager

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert projects == []

    def test_list_projects_returns_projects_with_sessions(self, tmp_path):
        """Should return projects with correct session counts"""
        from server.services.session_manager import SessionManager

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
        from server.services.session_manager import SessionManager

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
        from server.services.session_manager import SessionManager

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
        from server.services.session_manager import SessionManager

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

    def test_list_sessions_filters_system_message_sessions(self, tmp_path):
        """Sessions where only system-injected messages exist should be filtered out"""
        from server.services.session_manager import SessionManager

        project_dir = tmp_path / "test-project"
        project_dir.mkdir()

        # Create a session with only a local-command-caveat message
        caveat_session = project_dir / "caveat123.jsonl"
        caveat_session.write_text(json.dumps({
            "message": {"role": "user", "content": "<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>"}
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

    def test_title_skips_system_messages_to_find_real_user_input(self, tmp_path):
        """Title should come from first real user message, not system-injected ones"""
        from server.services.session_manager import SessionManager

        project_dir = tmp_path / "test-project"
        project_dir.mkdir()

        # Create a session with system message first, then real user message
        session = project_dir / "mixed123.jsonl"
        lines = [
            json.dumps({"message": {"role": "user", "content": "<local-command-caveat>Caveat: system message</local-command-caveat>"}}),
            json.dumps({"message": {"role": "user", "content": "What is the weather today?"}}),
        ]
        session.write_text("\n".join(lines) + "\n")

        manager = SessionManager(str(tmp_path))
        sessions = manager.list_sessions("test-project")

        assert len(sessions) == 1
        assert sessions[0].title == "What is the weather today?"

    def test_list_sessions_filters_zero_message_sessions(self, tmp_path):
        """Sessions with 0 messages should be filtered out"""
        from server.services.session_manager import SessionManager

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
        /Users/aaron/Desktop/max/server (not /Users/aaron/Desktop/max/voice/server)

        Without cwd from sessions, we can't know which - was originally _ vs /
        """
        from server.services.session_manager import SessionManager

        # Claude encodes /Users/aaron/Desktop/max/server as:
        # -Users-aaron-Desktop-max-voice-server (both / and _ become -)
        project_dir = tmp_path / "-Users-aaron-Desktop-max-voice-server"
        project_dir.mkdir()

        # Create a session with cwd that shows the ACTUAL path
        session_file = project_dir / "session123.jsonl"
        session_file.write_text(json.dumps({
            "cwd": "/Users/aaron/Desktop/max/server",
            "message": {"role": "user", "content": "Hello"}
        }) + "\n")

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert len(projects) == 1
        p = projects[0]
        # The path should preserve the underscore (from cwd), not convert to slash
        assert p.path == "/Users/aaron/Desktop/max/server"
        assert "voice/server" not in p.path  # Should NOT have slash here
        assert p.name == "server"
        assert p.folder_name == "-Users-aaron-Desktop-max-voice-server"

    def test_get_session_history_includes_content_blocks(self, tmp_path):
        """get_session_history should return content_blocks for structured messages"""
        from server.services.session_manager import SessionManager

        folder = tmp_path / "-test-project"
        folder.mkdir(parents=True)

        session_file = folder / "test-session.jsonl"
        lines = [
            json.dumps({"message": {"role": "user", "content": "list files"}, "timestamp": "2026-01-01T00:00:00Z"}),
            json.dumps({"message": {"role": "assistant", "content": [
                {"type": "text", "text": "Let me check."},
                {"type": "tool_use", "id": "toolu_01A", "name": "Bash", "input": {"command": "ls"}}
            ]}, "timestamp": "2026-01-01T00:00:01Z"}),
            json.dumps({"message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_01A", "content": "file1.txt\nfile2.txt", "is_error": False}
            ]}, "timestamp": "2026-01-01T00:00:02Z"}),
            json.dumps({"message": {"role": "assistant", "content": [
                {"type": "text", "text": "Here are your files."}
            ]}, "timestamp": "2026-01-01T00:00:03Z"}),
        ]
        session_file.write_text("\n".join(lines) + "\n")

        manager = SessionManager(projects_dir=str(tmp_path))
        messages = manager.get_session_history("-test-project", "test-session")

        # Should have 4 messages: user text, assistant with blocks, tool_result, assistant text
        assert len(messages) == 4

        # First: user text
        assert messages[0].role == "user"
        assert messages[0].content == "list files"
        assert messages[0].content_blocks is None

        # Second: assistant with tool_use
        assert messages[1].role == "assistant"
        assert messages[1].content == "Let me check."
        assert messages[1].content_blocks is not None
        assert len(messages[1].content_blocks) == 2
        assert messages[1].content_blocks[0]["type"] == "text"
        assert messages[1].content_blocks[1]["type"] == "tool_use"

        # Third: tool_result
        assert messages[2].role == "tool_result"
        assert messages[2].content == "file1.txt\nfile2.txt"
        assert messages[2].content_blocks is not None
        assert messages[2].content_blocks[0]["tool_use_id"] == "toolu_01A"

        # Fourth: assistant text
        assert messages[3].role == "assistant"
        assert messages[3].content == "Here are your files."

    def test_get_session_history_strips_text_newlines(self, tmp_path):
        """Text blocks with leading/trailing newlines should be stripped in history"""
        from server.services.session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-project"
        project_dir.mkdir()

        session_file = project_dir / "sess123.jsonl"
        session_file.write_text(
            json.dumps({
                "message": {"role": "assistant", "content": [
                    {"type": "text", "text": "\n\nHello, how can I help?"}
                ]},
                "timestamp": "2026-01-01T10:00:00Z"
            }) + "\n"
        )

        manager = SessionManager(projects_dir=str(tmp_path))
        messages = manager.get_session_history("-Users-test-project", "sess123")

        assert len(messages) == 1
        assert messages[0].content == "Hello, how can I help?"
        assert not messages[0].content.startswith("\n")

    def test_get_session_history_rewrites_image_source(self, tmp_path):
        """[Image: source: /path/file.png] should become [Image: file.png]"""
        from server.services.session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-proj"
        project_dir.mkdir()
        session_file = project_dir / "sess1.jsonl"
        session_file.write_text(
            json.dumps({
                "type": "user",
                "timestamp": "2026-01-01T00:00:00Z",
                "message": {"role": "user", "content": [
                    {"type": "text", "text": "[Image: source: /Users/aaron/Downloads/IMG_5594.PNG]"}
                ]}
            }) + "\n"
        )

        manager = SessionManager(projects_dir=str(tmp_path))
        messages = manager.get_session_history("-Users-test-proj", "sess1")
        assert len(messages) == 1
        assert messages[0].content == "[Image: IMG_5594.PNG]"

    def test_list_projects_sorted_by_latest_session_mtime(self, tmp_path):
        """Projects are returned sorted by most recent session file modification time"""
        from server.services.session_manager import SessionManager

        old_project = tmp_path / "-Users-test-old"
        old_project.mkdir()
        (old_project / "session1.jsonl").write_text('{"type":"summary"}')
        os.utime(old_project / "session1.jsonl", (1000, 1000))

        new_project = tmp_path / "-Users-test-new"
        new_project.mkdir()
        (new_project / "session1.jsonl").write_text('{"type":"summary"}')
        os.utime(new_project / "session1.jsonl", (3000, 3000))

        mid_project = tmp_path / "-Users-test-mid"
        mid_project.mkdir()
        (mid_project / "session1.jsonl").write_text('{"type":"summary"}')
        os.utime(mid_project / "session1.jsonl", (2000, 2000))

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert len(projects) == 3
        assert projects[0].name == "new"
        assert projects[1].name == "mid"
        assert projects[2].name == "old"

    def test_list_projects_empty_project_sorts_last(self, tmp_path):
        """Projects with no sessions sort to the end"""
        from server.services.session_manager import SessionManager

        empty_project = tmp_path / "-Users-test-empty"
        empty_project.mkdir()

        has_sessions = tmp_path / "-Users-test-active"
        has_sessions.mkdir()
        (has_sessions / "session1.jsonl").write_text('{"type":"summary"}')

        manager = SessionManager(projects_dir=str(tmp_path))
        projects = manager.list_projects()

        assert len(projects) == 2
        assert projects[0].name == "active"
        assert projects[1].name == "empty"

    def test_get_session_history_skips_image_blocks(self, tmp_path):
        """Image blocks with base64 data should be skipped entirely"""
        from server.services.session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-proj"
        project_dir.mkdir()
        session_file = project_dir / "sess1.jsonl"
        session_file.write_text(
            json.dumps({
                "type": "user",
                "timestamp": "2026-01-01T00:00:00Z",
                "message": {"role": "user", "content": [
                    {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "abc"}}
                ]}
            }) + "\n"
        )

        manager = SessionManager(projects_dir=str(tmp_path))
        messages = manager.get_session_history("-Users-test-proj", "sess1")
        assert len(messages) == 0

    def test_get_session_history_skips_synthetic_messages(self, tmp_path):
        """Synthetic assistant messages (model='<synthetic>') like 'No response requested' should be filtered"""
        from server.services.session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-proj"
        project_dir.mkdir()
        session_file = project_dir / "sess1.jsonl"
        lines = [
            json.dumps({
                "timestamp": "2026-01-01T00:00:00Z",
                "message": {
                    "role": "assistant",
                    "model": "<synthetic>",
                    "content": [{"type": "text", "text": "No response requested."}]
                }
            }),
            json.dumps({
                "timestamp": "2026-01-01T00:00:01Z",
                "message": {
                    "role": "assistant",
                    "model": "claude-sonnet-4-20250514",
                    "content": [{"type": "text", "text": "Hello, how can I help?"}]
                }
            }),
        ]
        session_file.write_text("\n".join(lines) + "\n")

        manager = SessionManager(projects_dir=str(tmp_path))
        messages = manager.get_session_history("-Users-test-proj", "sess1")
        assert len(messages) == 1
        assert messages[0].content == "Hello, how can I help?"

    def test_list_session_ids_returns_all_ids(self, tmp_path):
        """list_session_ids returns set of all session IDs in a folder"""
        from server.services.session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-project"
        project_dir.mkdir()
        (project_dir / "abc123.jsonl").write_text('{"message": {"role": "user", "content": "hi"}}\n')
        (project_dir / "def456.jsonl").write_text('{"message": {"role": "user", "content": "hi"}}\n')
        (project_dir / "agent-xyz.jsonl").write_text('{"message": {"role": "user", "content": "hi"}}\n')

        manager = SessionManager(projects_dir=str(tmp_path))
        ids = manager.list_session_ids("-Users-test-project")

        assert ids == {"abc123", "def456"}  # agent- files excluded

    def test_list_session_ids_empty_folder(self, tmp_path):
        """list_session_ids returns empty set for nonexistent folder"""
        from server.services.session_manager import SessionManager
        manager = SessionManager(projects_dir=str(tmp_path))
        ids = manager.list_session_ids("nonexistent")
        assert ids == set()

    def test_find_new_session_detects_new_file(self, tmp_path):
        """find_new_session returns a session ID not in the exclude set"""
        from server.services.session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-project"
        project_dir.mkdir()
        (project_dir / "old-session.jsonl").write_text('{"message": {"role": "user", "content": "hi"}}\n')

        manager = SessionManager(projects_dir=str(tmp_path))
        existing = manager.list_session_ids("-Users-test-project")
        assert existing == {"old-session"}

        # Simulate Claude creating a new session file
        (project_dir / "new-session.jsonl").write_text('{"message": {"role": "user", "content": "hello"}}\n')

        result = manager.find_new_session("-Users-test-project", existing)
        assert result == "new-session"

    def test_list_sessions_sorted_by_message_timestamp_not_mtime(self, tmp_path):
        """Sessions should be sorted by last message timestamp, not file mtime"""
        from server.services.session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-myproject"
        project_dir.mkdir()

        # Session A: old file mtime, but NEWER message timestamp
        session_a = project_dir / "aaa111.jsonl"
        session_a.write_text(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "Session A"},
            "timestamp": "2026-03-20T12:00:00Z"
        }))

        # Session B: new file mtime, but OLDER message timestamp
        session_b = project_dir / "bbb222.jsonl"
        session_b.write_text(json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "Session B"},
            "timestamp": "2026-03-10T12:00:00Z"
        }))

        # Set file mtimes: B is newer on disk than A
        os.utime(session_a, (time.time() - 200, time.time() - 200))
        os.utime(session_b, (time.time(), time.time()))

        manager = SessionManager(projects_dir=str(tmp_path))
        sessions = manager.list_sessions("-Users-test-myproject")

        assert len(sessions) == 2
        # Session A should be first (newer message timestamp) despite older file mtime
        assert sessions[0].id == "aaa111"
        assert sessions[1].id == "bbb222"

    def test_list_projects_excludes_deleted_paths(self, tmp_path):
        """Should not return projects whose decoded path no longer exists on disk"""
        from server.services.session_manager import SessionManager

        # Use a subdirectory as projects_dir to avoid picking up helper dirs
        projects_dir = tmp_path / "projects"
        projects_dir.mkdir()

        # Create a project folder whose decoded path does NOT exist
        project_dir = projects_dir / "-Users-test-deleted_project"
        project_dir.mkdir()
        (project_dir / "session1.jsonl").write_text(json.dumps({
            "type": "system",
            "cwd": "/Users/test/deleted_project"
        }) + "\n" + json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "hello"},
            "timestamp": "2026-01-01T10:00:00Z"
        }))

        # Create a project folder whose decoded path DOES exist
        existing_path = tmp_path / "existing_project"
        existing_path.mkdir()
        encoded_name = str(existing_path).replace("/", "-")
        project_dir2 = projects_dir / encoded_name
        project_dir2.mkdir()
        (project_dir2 / "session1.jsonl").write_text(json.dumps({
            "type": "system",
            "cwd": str(existing_path)
        }) + "\n" + json.dumps({
            "type": "user",
            "message": {"role": "user", "content": "hello"},
            "timestamp": "2026-01-01T10:00:00Z"
        }))

        manager = SessionManager(projects_dir=str(projects_dir))
        projects = manager.list_projects()

        # Only the existing project should appear
        assert len(projects) == 1
        assert projects[0].path == str(existing_path)

    def test_find_new_session_returns_none_when_no_new(self, tmp_path):
        """find_new_session returns None when all sessions are in exclude set"""
        from server.services.session_manager import SessionManager

        project_dir = tmp_path / "-Users-test-project"
        project_dir.mkdir()
        (project_dir / "old-session.jsonl").write_text('{"message": {"role": "user", "content": "hi"}}\n')

        manager = SessionManager(projects_dir=str(tmp_path))
        existing = manager.list_session_ids("-Users-test-project")

        result = manager.find_new_session("-Users-test-project", existing)
        assert result is None