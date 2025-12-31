"""
Test configuration for integration tests
"""

import os
import tempfile

# Server configuration
TEST_PORT = int(os.environ.get("TEST_SERVER_PORT", "8765"))
TEST_HOST = os.environ.get("TEST_SERVER_HOST", "127.0.0.1")
CONTROL_PORT = 8766  # HTTP port for test control (inject responses, get logs)

# Test mode flags
MOCK_TTS = True  # Use pre-generated WAV file instead of Kokoro
MOCK_VS_CODE = True  # Skip AppleScript, use test transcript file
LOG_LEVEL = "DEBUG"

# Paths
TEST_TEMP_DIR = tempfile.mkdtemp(prefix="voice_mode_test_")
TEST_TRANSCRIPT_PATH = os.path.join(TEST_TEMP_DIR, "test_transcript.jsonl")
TEST_AUDIO_PATH = os.path.join(
    os.path.dirname(__file__), "fixtures", "test_audio.wav"
)

# Audio streaming
AUDIO_CHUNK_DELAY = 0.01  # Faster for testing (still 10ms between chunks)
CHUNK_SIZE = 8192

# Timeouts
SERVER_STARTUP_TIMEOUT = 10.0
CLIENT_CONNECTION_TIMEOUT = 5.0

def cleanup_temp_dir():
    """Clean up temporary test directory"""
    import shutil
    if os.path.exists(TEST_TEMP_DIR):
        shutil.rmtree(TEST_TEMP_DIR)
