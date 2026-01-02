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

        # Find project2
        p2 = next(p for p in projects if p.name == "project2")
        assert p2.session_count == 1
