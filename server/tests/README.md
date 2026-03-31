# Voice Mode Tests

Comprehensive test suite for the iOS voice mode WebSocket server and TTS utilities.

## Test Files

- `test_tts_utils.py` - Tests for TTS functions (tts_manager.py)
- `test_main.py` - Tests for WebSocket server and transcript handling
- `conftest.py` - Pytest fixtures and configuration
- `pytest.ini` - Pytest settings
- `requirements-test.txt` - Test dependencies
- `run_tests.sh` - Test runner script

## Running Tests

### Quick Start

```bash
cd server/tests
./run_tests.sh
```

### Run with Coverage

```bash
./run_tests.sh coverage
```

### Run with Verbose Output

```bash
./run_tests.sh verbose
```

### Run Specific Test File

```bash
/Users/aaron/.local/pipx/venvs/claude-connect/bin/python -m pytest test_tts_utils.py -v
```

### Run Specific Test

```bash
pytest test_main.py::TestConnectServer::test_send_status -v
```

## Test Coverage

### tts_manager.py
- ✅ TTS audio generation
- ✅ WAV file saving
- ✅ Audio chunking for streaming
- ✅ WAV byte conversion
- ✅ Startup logging (download vs cache)
- ✅ Voice preloading

### main.py

**ConnectServer class:**
- ✅ Server initialization
- ✅ Transcript file discovery
- ✅ Status message formatting
- ✅ VS Code integration (AppleScript)
- ✅ Audio streaming with chunking
- ✅ Voice input handling
- ✅ Claude response handling
- ✅ WebSocket message parsing
- ✅ Client connection lifecycle
- ✅ Multi-client broadcasting

**TranscriptHandler class:**
- ✅ Handler initialization
- ✅ Assistant message extraction (string content)
- ✅ Assistant message extraction (list/block content)
- ✅ Message filtering (role, length)
- ✅ File event filtering (.jsonl only)
- ✅ Duplicate message detection

## Test Structure

```
tests/
├── test_tts_utils.py          # TTS utility tests
├── test_main.py          # WebSocket server tests
├── conftest.py                 # Shared fixtures
├── pytest.ini                  # Pytest configuration
├── requirements-test.txt       # Dependencies
├── run_tests.sh               # Test runner
└── README.md                  # This file
```

## Writing New Tests

### Testing Philosophy: NO MOCKS for Core Functionality

**CRITICAL**: Tests must verify real behavior, not mock implementations.

- **DO NOT** mock `subprocess.run` for tmux commands - call real tmux
- **DO NOT** mock file operations for transcript watching - use real files
- **DO NOT** inject fake responses - test real data flow
- **DO** use real tmux sessions (with test-specific session names)
- **DO** use real file watchers with real file modifications
- **DO** clean up test resources (kill sessions, delete files)

If a test passes but the feature doesn't work on a real device, the test is worthless.

### Using Fixtures

```python
def test_example(temp_transcript_file, sample_audio_data):
    """Test using fixtures from conftest.py"""
    # temp_transcript_file is a path to a temporary .jsonl file
    # sample_audio_data is a numpy array of audio samples
    pass
```

### Testing Async Functions

```python
@pytest.mark.asyncio
async def test_async_function():
    """Test async functions"""
    result = await some_async_function()
    assert result is not None
```

### When Mocking IS Acceptable

Only mock external services that:
- Cost money (API calls to Claude)
- Are non-deterministic (network latency)
- Are unavailable in test environment

Never mock:
- Local subprocess calls (tmux, file operations)
- File system operations
- Internal module interactions

## CI/CD Integration

To integrate with CI/CD pipelines:

```yaml
# Example GitHub Actions
- name: Run tests
  run: |
    cd server/tests
    ./run_tests.sh coverage
```

## Troubleshooting

### Import Errors

Make sure the package is installed via pipx with latest code:

```bash
pipx install --force /Users/aaron/Desktop/max
```

### Async Test Warnings

If you see warnings about async tests, make sure `pytest-asyncio` is installed and `pytest.ini` has `asyncio_mode = auto`.

### Path Issues

Tests add the server directory to Python path automatically. If you still have import issues, check that the path in the test files matches your setup:

```python
sys.path.insert(0, os.path.join(os.path.dirname(__file__), '..'))
```
