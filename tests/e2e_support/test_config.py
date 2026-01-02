"""Configuration for E2E tests"""
import os

# Server configuration
TEST_SERVER_HOST = "127.0.0.1"
TEST_SERVER_PORT = 8765
SERVER_STARTUP_TIMEOUT = 10  # seconds

# Paths
PROJECT_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "../.."))
SERVER_SCRIPT = os.path.join(PROJECT_ROOT, "voice_server/ios_server.py")
PYTHON_VENV = os.path.join(PROJECT_ROOT, ".venv/bin/python3")

# Transcript configuration
TEMP_TRANSCRIPT_DIR = "/tmp/claude_voice_e2e_tests"
