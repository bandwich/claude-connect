# E2E Test Rewrite Design

## Problem

E2E tests (~18 tests, 6 suites) haven't been maintained alongside app evolution. Tests are likely broken against current UI/server, slow (real Claude sessions with 60s+ waits), flaky (sleep-heavy), and some reference missing helpers. Need fresh test cases that are fast, reliable, and catch real regressions.

## Approach: Two-Tier E2E Tests

### Tier 1 — Test Server (fast, deterministic)

Use `server/integration_tests/test_server.py` with injected mock responses. Tests inject transcript content via HTTP, verify the iOS app renders and behaves correctly. No real Claude sessions, no token cost, no flaky waits.

### Tier 2 — Real Claude Smoke Tests (contract validation)

2 tests that hit real Claude Code. Purpose: validate that Claude Code's transcript format matches what we parse. Exercises all content block types:

- **Smoke test 1:** Prompt that produces plain text + thinking blocks
- **Smoke test 2:** Prompt that forces tool use (e.g., "Read file X") producing tool_use + tool_result blocks

If Claude Code changes its output format, these fail. Not testing app UI logic (tier 1 does that) — testing the data contract.

## Test Suites

| Suite | Server | What it validates |
|-------|--------|-------------------|
| Connection | Test | Connect, disconnect, reconnect states |
| Conversation | Test | Send input, receive response, renders correctly |
| Permissions | Test | Permission card appears, approve/deny flows back |
| Questions | Test | Question prompt appears, answer selection works |
| Navigation | Test | Projects → sessions → session view → back |
| Session management | Test | Open, switch, stop sessions |
| File browser | Test | Directory listing, file viewing |
| Smoke / Contract | Real | All content block types parse and render |

## Runner Script

Three modes:

- `./run_e2e_tests.sh` — runs everything (tier 1 + tier 2)
- `./run_e2e_tests.sh --fast` — tier 1 only (test server, for quick iteration)
- `./run_e2e_tests.sh --smoke` — tier 2 only (real Claude, contract check)

## E2ETestBase

Keep and update the existing 601-line base class. The coordinate-based tapping and HTTP-based verification workarounds solve real SwiftUI/XCTest problems. Strip dead code, update for current UI elements and server endpoints, add helpers for test server injection.

## Test Server Integration

Existing endpoints: `/inject_response`, `/inject_status`, `/reset`. E2E tests POST mock transcript content, then verify the iOS app handles it correctly. May need new endpoints for question injection and other flows — to be determined during implementation.

## Risks

**Riskiest assumption:** Test server's injected responses produce realistic enough transcript state for the iOS app to handle them identically to real transcripts. If mock format diverges from real output, tier 1 passes but app breaks in production.

**Mitigation:** Tier 2 smoke tests validate the real format. If tier 2 fails but tier 1 passes, mock format has drifted.

**Verification strategy:** Run tier 2 first during development to capture current real transcript format, then build tier 1 mocks from that captured data.

## Open Questions

1. Does the test server need new endpoints for question injection, or can existing ones cover it? Determine during implementation.
2. Exact prompts for smoke tests — need to find minimal prompts that reliably produce all block types.
