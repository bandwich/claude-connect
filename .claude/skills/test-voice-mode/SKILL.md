---
name: test-voice-mode
description: Run tests for Claude Voice Mode - unit tests (ClaudeVoiceTests), server tests (pytest), integration tests (UI+server), or all combined
args: unit|server|integration|all (default: integration)
---

# Unified Test Suite for Claude Voice Mode

Run any combination of tests for the Claude Voice Mode project:
- **Unit tests**: ClaudeVoiceTests (Swift unit tests)
- **Server tests**: WebSocket server pytest suite
- **Integration tests**: End-to-end UI tests with live server
- **All**: Run everything

## When to Use This Skill

Activate when the user:
- Asks to "test voice mode" or "run tests"
- Wants to verify unit tests, server tests, or integration tests
- Mentions testing specific components (iOS app, WebSocket server, etc.)
- After making code changes that need validation
- When debugging test failures

## Usage

```bash
# Run integration tests (default)
bash /Users/aaron/Desktop/max/.claude/skills/test-voice-mode/run.sh

# Run specific test type
bash /Users/aaron/Desktop/max/.claude/skills/test-voice-mode/run.sh unit
bash /Users/aaron/Desktop/max/.claude/skills/test-voice-mode/run.sh server
bash /Users/aaron/Desktop/max/.claude/skills/test-voice-mode/run.sh integration

# Run all tests
bash /Users/aaron/Desktop/max/.claude/skills/test-voice-mode/run.sh all
```

## EXECUTION PROTOCOL (MANDATORY)

### Step 1: Determine which tests to run

Based on context:
- Working on Swift code, models, services? → `unit`
- Working on WebSocket server (Python)? → `server`
- Working on full end-to-end flow? → `integration`
- After major changes or before release? → `all`

### Step 2: Start test script in background

**CRITICAL**: Always use `run_in_background: true`

```bash
bash /Users/aaron/Desktop/max/.claude/skills/test-voice-mode/run.sh [unit|server|integration|all]
```

### Step 3: Monitor output file

The script uses `tee` to write all output to `/tmp/test_output.log` (or `/tmp/integration_test_output.log` for integration tests).

**Monitor the background task output every 10-12 seconds:**

```bash
tail -100 /tmp/claude/-Users-aaron-Desktop-max/tasks/{TASK_ID}.output
```

**What you'll see:**
- `[Monitor check #N]` - Current check number
- `Process: PID CPU% RSS STATE TIME` - Test process status
- `Log: N lines (+X new)` - Log growth tracking
- `=== Last 40 lines of test output ===` - Test progress
- For integration: `=== Last 20 lines of server log ===`
- For all crashes: `⚠ CRASH DETECTED` with details

### Step 4: Active monitoring & reporting

After EACH check (every 10-12 seconds), report status:

```
[Check #{N}] {Phase}: {Brief status}
- {Key activity}
- {Progress indicators}
- {Any warnings}
```

**Examples:**

```
[Check #3] Unit tests: Building
- Log growing (+52 lines, total: 234)
- Compiling Swift files
- No issues

[Check #8] Unit tests: Running tests
- ✓ VoiceStateTests: 4/4 passed
- ✓ WebSocketManagerTests: 3/4 in progress
- No issues

[Check #5] Server tests: Running pytest
- Log growing (+28 lines)
- test_transcript_handler.py running
- 14 tests passed so far

[Check #12] Integration: Running UI tests
- ✓ ConnectionTests: 4/4 passed
- Server handling connections
- Audio streaming in progress
```

### Step 5: Detect problems

**Normal behavior (don't panic):**
- Log pauses 20-30s during build→test transition
- "may be stuck?" for 1-3 checks during linking
- Build phase takes 60-90 seconds

**Actual problems:**
- **STUCK**: No log growth for 60+ seconds during test execution
- **CRASH**: Crash report appears with recent timestamp
- **BUILD ERROR**: `error:` lines in output
- **TEST FAILED**: Test failures in output

**If problems detected:**
1. Note the specific issue (which test, what error)
2. Check full logs: `tail -100 /tmp/test_output.log`
3. Report findings to user
4. Ask if they want you to investigate further
5. **Use global `debug` skill** to investigate if requested

### Step 6: Keep monitoring until complete

**CRITICAL**: Monitor every 10-12 seconds until the test process exits.

**Check if process still running:**
```bash
ps aux | grep -E "xcodebuild|pytest" | grep -v grep
```

**When process exits:**
1. Get final results: `TaskOutput {TASK_ID}`
2. Analyze test counts and failures
3. Report summary to user
4. If failures exist and user wants help, use `debug` skill

## Test Types Explained

### Unit Tests (ClaudeVoiceTests)
- **What**: 46 Swift unit tests for iOS app
- **Duration**: ~60 seconds
- **Output**: `/tmp/test_output.log`
- **Tests**: Models, services, state management, callbacks

### Server Tests (pytest)
- **What**: 44 Python tests for WebSocket server
- **Duration**: ~30 seconds
- **Output**: `/tmp/test_output.log`
- **Tests**: Server logic, transcript handling, TTS, message parsing

### Integration Tests (UI + Server)
- **What**: 37 end-to-end UI tests with live server
- **Duration**: 2-3 minutes
- **Output**: `/tmp/test_output.log` + `/tmp/test_server.log`
- **Tests**: Full voice interaction flow, audio streaming, state sync

### All Tests
- **What**: Runs all three test suites sequentially
- **Duration**: 4-5 minutes total
- **Output**: Same logs, separated by test type

## Monitoring Details

### Output Files

All tests write to `/tmp/test_output.log` with `tee`, so you can:
```bash
# Check live progress
tail -f /tmp/test_output.log

# Count results
grep -c "passed" /tmp/test_output.log

# Find failures
grep "failed" /tmp/test_output.log
```

Additional files:
- `/tmp/test_server.log` - Server activity (integration tests only)
- `/tmp/test_monitor.log` - Monitoring script output

### Understanding Test Progress

**Unit/Integration tests (XCTest):**
```
Test Suite 'VoiceStateTests' started
Test Case '-[VoiceStateTests testVoiceStateDescriptions]' passed (0.010 seconds)
Test Case '-[VoiceStateTests testVoiceStateRawValues]' passed (0.032 seconds)
Test Suite 'VoiceStateTests' passed
** TEST SUCCEEDED **
```

**Server tests (pytest):**
```
test_transcript_handler.py::test_extract_message PASSED
test_ios_server.py::test_send_status PASSED
======================== 44 passed in 12.34s ========================
```

### Crash Detection

If app crashes during testing:
```
⚠ CRASH DETECTED: ~/Library/Logs/DiagnosticReports/ClaudeVoice-2025-12-30-163245.ips
Crash time: 2025-12-30 16:32:45

=== Crash Details ===
Exception Type: EXC_BAD_ACCESS
Termination Reason: SIGNAL 11 Segmentation fault
```

**When crash detected:**
1. Report to user immediately
2. Show crash time and type
3. Offer to investigate with `debug` skill
4. Don't continue monitoring - tests will terminate

## Handling Failures

When tests fail:

1. **Report what failed:**
   ```
   ✗ Failed tests:
   Test Case '-[AudioPlayerTests testReceiveAudioChunk]' failed
   ```

2. **Show error context:**
   ```bash
   grep -A 5 "testReceiveAudioChunk.*failed" /tmp/test_output.log
   ```

3. **Ask user:**
   - "Would you like me to investigate this failure using the debug skill?"
   - "Should I look at the specific test code?"

4. **If user wants investigation:**
   - Use global `debug` skill
   - Examine test code
   - Check related implementation files
   - Suggest fixes

## Important Notes

- Script handles cleanup automatically (kills processes, stops simulator)
- All test output is preserved in `/tmp` for investigation
- Monitoring runs in background - you actively check every 10-12s
- Never block waiting - always monitor actively
- Use `debug` skill for investigation, not manual code reading
- Tests run on iOS Simulator (iPhone 16 Pro)
- Requires Xcode and Python venv to be configured

## Common Issues

1. **Build stuck**: Check for compilation errors in output
2. **Tests hang**: Look for last test that ran, may be stuck in that test
3. **Server won't start**: Check server log for Python exceptions
4. **Crashes**: Examine crash reports with timestamps
5. **Random failures**: Often state management or race conditions

Remember: The skill does the heavy lifting - you just monitor, report, and use `debug` if problems arise!
