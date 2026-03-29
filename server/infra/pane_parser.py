"""Parse tmux pane output to detect Claude Code's current activity state."""

import re
from dataclasses import dataclass
from typing import Optional


@dataclass
class ActivityState:
    state: str   # "idle", "thinking", "tool_active", "waiting_permission"
    detail: str  # e.g., "Reading 3 files…", "Searching for patterns…"


# Spinner characters used by Claude Code's thinking indicator
SPINNER_CHARS = set("✢✻✽✳·✶")

# Pattern: spinner char followed by text like "Manifesting…" or "Billowing…"
THINKING_RE = re.compile(r'^[✢✻✽✳·✶]\s+\S+…')

# Pattern: in-progress tool use — optional ⏺ followed by present-tense action with …
# e.g. "⏺ Searching for 1 pattern…", "Reading 3 files…",
# or compound "Searching for 1 pattern, reading 9 files…"
# The ⏺ prefix flickers on/off in the pane, so it's optional.
TOOL_ACTIVE_RE = re.compile(r'^(?:⏺\s+)?\w+ing\b.*…')

# Pattern: permission prompt — match the footer that's always near the bottom
PERMISSION_RE = re.compile(r'Esc to cancel · Tab to amend')


# Claude Code's input prompt character — indicates CLI is loaded and ready
READY_PROMPT_RE = re.compile(r'❯')

# Claude Code banner pattern — indicates CLI has started
BANNER_RE = re.compile(r'Claude Code')


def is_claude_ready(pane_text: Optional[str]) -> bool:
    """Check if Claude Code is loaded and ready for input.

    Looks for the ❯ prompt or the Claude Code banner, which indicate
    the CLI has finished initializing. Also returns True if Claude is
    already actively working (thinking, tool use, permission prompt).
    """
    if not pane_text:
        return False

    # If we can detect any Claude activity, it's ready
    state = parse_pane_status(pane_text)
    if state.state != "idle":
        return True

    # Check for ready prompt or banner
    return bool(READY_PROMPT_RE.search(pane_text)) or bool(BANNER_RE.search(pane_text))


def parse_pane_status(pane_text: Optional[str]) -> ActivityState:
    """Parse tmux pane capture to determine Claude's current state.

    Examines the last portion of pane output for status indicators.
    """
    if not pane_text:
        return ActivityState(state="idle", detail="")

    lines = [l for l in pane_text.splitlines() if l.strip()]
    if not lines:
        return ActivityState(state="idle", detail="")

    # Look at last ~15 non-empty lines (status is at the bottom)
    tail = lines[-15:] if len(lines) > 15 else lines

    # Check for permission prompt — only on the last 3 lines to avoid stale matches
    for line in lines[-3:] if len(lines) >= 3 else lines:
        if PERMISSION_RE.search(line):
            return ActivityState(state="waiting_permission", detail="")

    # Check for in-progress tool activity BEFORE thinking — when both are
    # present (tool line + spinner), the tool description is more informative.
    # Scan from bottom up to find the most recent tool line
    for line in reversed(tail):
        stripped = line.strip()
        if TOOL_ACTIVE_RE.match(stripped):
            # Extract the detail text (remove optional ⏺ prefix and (ctrl+o...) suffix)
            detail = stripped.lstrip('⏺').strip()
            detail = re.sub(r'\s*\(ctrl\+o.*\)$', '', detail)
            return ActivityState(state="tool_active", detail=detail)

    # Check for thinking indicator (spinner + text)
    for line in tail:
        stripped = line.strip()
        if THINKING_RE.match(stripped):
            return ActivityState(state="thinking", detail="")

    return ActivityState(state="idle", detail="")
