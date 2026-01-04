"""Tests for hook shell scripts"""

import pytest
import subprocess
import json
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

HOOKS_DIR = os.path.join(os.path.dirname(__file__), '..', 'hooks')


class TestPermissionHook:
    """Tests for permission_hook.sh"""

    def test_hook_exists_and_executable(self):
        """Test hook script exists and is executable"""
        hook_path = os.path.join(HOOKS_DIR, 'permission_hook.sh')
        assert os.path.exists(hook_path), f"Hook not found: {hook_path}"
        assert os.access(hook_path, os.X_OK), "Hook is not executable"

    def test_hook_reads_stdin_and_posts(self):
        """Test hook reads JSON from stdin and POSTs to server"""
        hook_path = os.path.join(HOOKS_DIR, 'permission_hook.sh')

        with open(hook_path, 'r') as f:
            content = f.read()

        assert 'curl' in content, "Hook should use curl"
        assert '/permission' in content, "Hook should POST to /permission"
        assert 'stdin' in content.lower() or 'cat' in content, "Hook should read from stdin"


class TestPostToolHook:
    """Tests for post_tool_hook.sh"""

    def test_hook_exists_and_executable(self):
        """Test hook script exists and is executable"""
        hook_path = os.path.join(HOOKS_DIR, 'post_tool_hook.sh')
        assert os.path.exists(hook_path), f"Hook not found: {hook_path}"
        assert os.access(hook_path, os.X_OK), "Hook is not executable"

    def test_hook_posts_resolved(self):
        """Test hook POSTs to /permission_resolved"""
        hook_path = os.path.join(HOOKS_DIR, 'post_tool_hook.sh')

        with open(hook_path, 'r') as f:
            content = f.read()

        assert 'curl' in content, "Hook should use curl"
        assert '/permission_resolved' in content, "Hook should POST to /permission_resolved"
