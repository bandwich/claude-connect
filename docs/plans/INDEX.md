# Plans Index

## Active Plans

<!-- write-plan adds entries here. finish-branch moves them to Completed when done. -->



---

## Completed

## Transcript Pipeline & Message Streaming
How Claude's output gets from transcript file to iOS app.

- [Structured content blocks](2025-12-31/2025-12-31-structured-content-design.md) — Pydantic models for content blocks, transcript parsing into typed blocks
- [Streaming content blocks](2025-12-31/2025-12-31-streaming-content-blocks.md) — Real-time streaming of parsed blocks to iOS via WebSocket
- [Fix transcript streaming](2026-01-05/2026-01-05-fix-transcript-streaming.md) — Fixing transcript watcher for permission-only flows
- [Sync reliability](2026-02-28/sync-reliability-design.md) — Sequence numbers, resync protocol, fixing message drops ([phase 1](2026-02-28/sync-reliability-phase1.md), [phase 2](2026-02-28/sync-reliability-phase2.md))
- [Surface user messages](2026-02-16/surface-user-messages.md) — Showing terminal-typed user messages in iOS
- [New session messages fix](2026-03-03/new-session-messages-design.md) — Fix assistant messages not appearing for new sessions
- [Filter synthetic messages](2026-03-17/auto-fix-no-response-requested.md) — Filter "No response requested" and other synthetic messages

## Permission & Question Flow
Hook-based remote control of Claude Code from iOS. **Reference pattern for any new hook-to-iOS flow.**

- [Remote permissions design](2026-01-03/2026-01-03-remote-permissions-design.md) — Full architecture: hooks, HTTP server, WebSocket relay, iOS UI ([part 1: models](2026-01-03/2026-01-03-remote-permissions-part1-models.md), [part 2: hooks](2026-01-03/2026-01-03-remote-permissions-part2-hooks.md), [part 3: iOS UI](2026-01-03/2026-01-03-remote-permissions-part3-ui.md), [part 4: integration](2026-01-03/2026-01-03-remote-permissions-part4-integration.md))
- [Inline permission UI](2026-02-16/inline-permission-ui-design.md) — Moving permissions from input bar to inline cards in conversation
- [Question prompts](2026-03-09/question-prompt-design.md) — AskUserQuestion via PreToolUse hook, same pattern as permissions ([plan](2026-03-09/question-prompt-plan.md))
- [Permission session isolation](2026-03-27/auto-fix-permission-session-isolation.md) — Fix permission prompts bleeding across sessions

## Session Management & Lifecycle
How sessions are created, resumed, viewed, and stopped.

- [Sync sessions](2026-01-02/2026-01-02-sync-sessions-design.md) — Session browsing from ~/.claude/projects/
- [Filter sessions](2026-01-03/2026-01-03-filter-sessions.md) — Filtering session list
- [Session lifecycle](2026-03-11/session-lifecycle-design.md) — Reliable create/resume/view/stop flows ([plan](2026-03-11/session-lifecycle-plan.md))
- [Multi-session](2026-03-18/multi-session-design.md) — Up to 5 concurrent sessions, SessionContext, viewed vs active ([phase 1: server](2026-03-18/multi-session-phase1.md), [phase 2: iOS](2026-03-18/multi-session-phase2.md))
- [Session list polish](2026-03-23/session-list-polish-design.md) — Hide deleted projects, active session dots, UX improvements
- [Adopt tmux sessions](2026-04-02/adopt-tmux-sessions.md) — Adopt external tmux (dispatch) instead of creating duplicate; session-aware stale tool marking

## iOS UI
Views, navigation, and display.

- [UI overhaul](2026-01-08/ui-overhaul-design.md) — Projects screen, session view, navigation structure
- [Tool display](2026-02-09/ios-tool-display-design.md) — Collapsible tool use blocks with input summaries ([plan](2026-02-09/ios-tool-display-plan.md))
- [Agent status UI](2026-03-06/agent-status-ui-design.md) — Grouped agent execution cards ([plan](2026-03-06/agent-status-ui-impl.md))
- [Bash output display](2026-03-16/bash-output-display-design.md) — Collapsed bash results with preview ([plan](2026-03-16/bash-output-display-plan.md))
- [Image viewing](2026-02-06/image-viewing-and-tool-output-design.md) — Image files in file browser ([phase 1](2026-02-06/image-viewing-phase1.md), [phase 2: tool output](2026-02-06/tool-output-phase2.md))
- [File browser](2026-01-12/file-browser-design.md) — Lazy-loaded directory tree, text + image viewing
- [Markdown rendering](2026-02-09/auto-fix-render-markdown.md) — Rich text in assistant messages
- [UI header fixes](2026-02-04/ui-header-fixes-design.md) — Header layout and spacing fixes

## Input Bar & Voice
Text input, voice recording, TTS, and the input bar state machine.

- [Input bar state machine](2026-03-02/input-bar-state-machine-design.md) — InputBarMode enum, transitions between normal/permission/question/syncing/disconnected
- [Input bar + TTS toggle](2026-02-17/input-bar-and-tts-toggle-design.md) — Keyboard accessory input bar ([phase 1](2026-02-17/input-bar-tts-toggle-phase1.md), [phase 2: images](2026-02-17/input-bar-tts-toggle-phase2.md))
- [TTS queue + context fix](2026-02-16/tts-queue-and-context-fix-design.md) — Serialized TTS queue, stale entry draining
- [Audio queue](2026-01-05/2026-01-05-audio-queue.md) — Chunked audio streaming via AVAudioEngine
- [Voice recording fixes](2026-01-16/auto-fix-ios-voice-recording.md) — iOS speech recognition issues
- [Multiline input](2026-03-27/auto-fix-multiline-input.md) — Expanding text field for multi-line messages

## Activity & Status
How the app shows what Claude is doing.

- [Activity status](2026-02-17/activity-status-design.md) — Pane parsing for idle/thinking/tool_active/waiting_permission + interrupt button
- [Activity indicator reliability](2026-03-27/activity-indicator-reliability.md) — Idle debounce, event-driven checks
- [Context tracking](2026-01-15/claude-stats-sync-design.md) — Token usage from transcripts, displayed in session header
- [Usage checker](2026-03-03/usage-checker-fix-design.md) — OAuth API for session/weekly quotas ([plan](2026-03-03/usage-checker-fix.md))
- [Background task completion](2026-03-17/background-task-completion.md) — Detecting when background tasks finish

## Connection & Networking
WebSocket, reconnection, QR setup.

- [QR connect](2026-01-14/qr-connect-design.md) — QR code scanning for server connection
- [Background reconnect](2026-03-10/background-reconnect-design.md) — Reconnection on app foreground, exponential backoff
- [Tailscale remote access](2026-03-31/tailscale-remote-access.md) — Tailscale IP in QR code, guided setup, iOS ATS fix for CGNAT range

## Slash Commands
iOS-initiated slash commands sent to Claude Code.

- [Slash commands UI](2026-03-25/slash-commands-ui-design.md) — Dropdown picker + attributed text field ([phase 1: data](2026-03-25/slash-commands-phase1.md), [phase 2: UI](2026-03-25/slash-commands-phase2.md))
- [Slash commands delivery fix](2026-03-25/slash-commands-delivery-fix.md) — Making all commands work from iOS
- [/clear command](2026-03-29/clear-command-design.md) — Transcript file detection for /clear support

## E2E Testing
Test infrastructure and stabilization.

- [E2E testing design](2026-01-01/2026-01-01-e2e-testing-design.md) — Test server, mock transcripts, iOS UI tests
- [True E2E architecture](2026-01-05/2026-01-05-true-e2e-test-architecture.md) — Real server + simulator approach
- [E2E test stabilization](2026-01-07/e2e-test-stabilization.md) — Fixing flaky tests
- [Test efficiency](e2e-test-efficiency.md) — Reducing E2E test run time
- [Fix iOS unit tests](2026-04-01/fix-ios-unit-tests-v2.md) — Fix AudioPlayer crash, reconnect test races, update simulator to iPhone 17, add Tailscale/session_cleared coverage

## Server Refactoring & Infrastructure
- [Voice server refactor](2026-03-23/voice-server-refactor-design.md) — Splitting monolithic server into services/handlers/infra
- [TTS startup logging](2026-03-31/tts-startup-logging.md) — Startup logs for TTS model download, lazy imports, tts_utils dedup
- [VSCode removal](2026-01-06/vscode-removal-design.md) — Removing VSCode extension support
- [PyPI publishing](2026-02-25/pypi-publishing-design.md) — Package distribution via pipx
- [Fresh install cleanup](2026-02-18/fresh-install-cleanup.md) — First-run experience fixes
- [Health check cleanup](2026-03-31/health-check-cleanup.md) — Dead code removal, doc drift fixes, tts_utils/rewrite_user_text dedup
- [E2E test rewrite](2026-04-01/e2e-test-rewrite-design.md) — Two-tier E2E architecture: test server (tier 1) + real Claude smoke tests (tier 2) ([phase 1](2026-04-01/e2e-test-rewrite-phase1.md), [phase 2](2026-04-01/e2e-test-rewrite-phase2.md), [phase 3](2026-04-01/e2e-test-rewrite-phase3.md), [idle-wait fix](2026-04-01/e2e-idle-wait-fix.md))
