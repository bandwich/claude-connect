# Tests

## Mock Philosophy

Real behavior over mock implementations:
- **Use real**: file I/O, watchdog Observer, subprocess (tmux), aiohttp test client
- **Only mock**: WebSocket clients (test fixtures), external APIs, non-deterministic behavior
- Never mock internal module interactions

## Running

```bash
cd server/tests && ./run_tests.sh           # all tests
./run_tests.sh verbose                              # -vv output
./run_tests.sh coverage                             # with coverage
./run_tests.sh unit                                 # @pytest.mark.unit only
./run_tests.sh integration                          # @pytest.mark.integration only
```

## Async Tests

`asyncio_mode = auto` in pytest.ini — just write `async def test_*()`, no decorator needed.

HTTP endpoint tests inherit `AioHTTPTestCase` and use `@unittest_run_loop`.

## Key Fixtures (conftest.py)

- `temp_transcript_file` — temporary .jsonl with cleanup
- `sample_transcript_data` — sample JSONL entries (user + assistant messages)
- `populated_transcript_file` — transcript pre-filled with sample data

## Common Patterns

**Watchdog integration tests**: Create real Observer, schedule handler on tmp_path, write to file, `time.sleep(1.0)` for detection, then assert. Call `reconcile()` to catch any watchdog misses.

**HTTP tests**: Inherit `AioHTTPTestCase`, create app in `get_application()`, use `self.client.post()`. For async responses (e.g., permission approval while waiting), use `asyncio.create_task()` to resolve the Event after a short delay.

**Mock WebSocket clients**: `AsyncMock()` added to handler's client set. Inspect `mock_client.send.call_args` for sent messages.

## Test File → Source Mapping

| Test | Tests |
|------|-------|
| `test_main.py` | ConnectServer, TranscriptHandler core |
| `test_message_handlers.py` | WebSocket message dispatch (handle_*) |
| `test_permission_integration.py` | Full permission + question flow |
| `test_sync_integration.py` | Transcript sync reliability, reconciliation |
| `test_http_server.py` | HTTP hook endpoints |
| `test_session_manager.py` | Project/session listing and history |
| `test_response_extraction.py` | Content block parsing |
| `test_transcript_watcher.py` | Real file watching with Observer |
| `test_pane_parser.py` | Activity state detection |
| `test_context_tracker.py` | Token usage calculation |
| `test_tts_utils.py` | Kokoro TTS generation |
| `test_permission_handler.py` | Request registration/resolution |
| `test_content_handler.py` | Content handling logic |
| `test_content_models.py` | Pydantic content block models |
| `test_context_broadcast.py` | Context update broadcasting |
| `test_hooks.py` | Hook scripts |
| `test_message_formats.py` | Message format validation |
| `test_qr_display.py` | QR code display + local IP |
| `test_text_extraction.py` | Text extraction from transcripts |
| `test_tmux_controller.py` | Tmux subprocess wrapper |
| `test_tts_preference.py` | TTS preference handling |
| `test_tts_queue.py` | TTS queue management |
| `test_state_validation.py` | State validation logic |
| `test_usage_handler.py` | Usage request handling |
| `test_usage_parser.py` | Usage API response parsing |

## iOS E2E Tests

Located in `ios/ClaudeConnect/ClaudeConnectUITests/`. Run via `run_e2e_tests.sh`.

- Inherit `E2ETestBase` which auto-connects to a real test server
- Server state reset via `/reset` endpoint before each test
- Config read from `/tmp/e2e_test_config.json`
- App launched with `INTEGRATION_TEST_MODE=1` environment variable
- Use `waitForExistence(timeout:)` for element checks, not hardcoded sleeps
