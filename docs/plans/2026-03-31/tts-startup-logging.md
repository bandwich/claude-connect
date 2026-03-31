# TTS Startup Logging & Cleanup

**Task:** Add logging during TTS model download on first startup so the server doesn't appear hung.

**Approach:** Lazy-load kokoro/torch imports so a log line prints immediately, detect cached vs uncached model files, suppress noisy third-party warnings.

---

## Changes

### 1. Lazy imports + startup logging (`server/services/tts_manager.py`)
- Deferred kokoro/torch/huggingface_hub imports into `_ensure_imports()` so `[TTS] Loading TTS engine...` prints before the ~20s import
- `warmup_tts()` checks `try_to_load_from_cache()` to print "Downloading model..." vs "Loading model..."
- Pre-loads voice file during warmup (was previously lazy on first TTS call)
- Suppresses torch `FutureWarning` and `UserWarning` about weight_norm/dropout
- Sets huggingface_hub logger to WARNING to hide verbose file move logs

### 2. Deduplicate tts_utils (`server/tts_utils.py`)
- Replaced duplicate function definitions with thin re-exports from `tts_manager.py`

### 3. Clean up verbose startup logs
- `server/main.py` — removed redundant warmup prints, removed "tmux available" log
- `server/services/transcript_watcher.py` — removed session file watching log
- `server/infra/http_server.py` — removed HTTP server ready log

### 4. Fix run_tests.sh (`server/tests/run_tests.sh`)
- Replaced broken `.venv/bin/activate` with pipx Python path

### 5. Update tests (`server/tests/test_tts_utils.py`)
- Tests point at `server.services.tts_manager` instead of `server.tts_utils`
- Added tests for download vs cache logging, voice preloading, lazy import compatibility
- Added re-export identity tests

### 6. Doc updates
- CLAUDE.md, server/CLAUDE.md, tests/TESTS.md, server/tests/README.md — updated tts_utils references and removed stale .venv instructions
