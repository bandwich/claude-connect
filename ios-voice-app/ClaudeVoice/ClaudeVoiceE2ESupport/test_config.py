"""Configuration for E2E tests"""
import os

# Server configuration
TEST_SERVER_HOST = "127.0.0.1"
TEST_SERVER_PORT = 8765

# Paths
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
SERVER_SCRIPT = os.path.join(PROJECT_ROOT, "voice_server/server.py")
PYTHON_VENV = os.path.join(PROJECT_ROOT, ".venv/bin/python3")

# Transcript configuration - use server's actual watched directory
TRANSCRIPT_DIR = os.path.expanduser("~/.claude/projects/e2e_test_project")
