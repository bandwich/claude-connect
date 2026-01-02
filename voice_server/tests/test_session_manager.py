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
