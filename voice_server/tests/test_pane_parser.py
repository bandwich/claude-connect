#!/usr/bin/env python3
"""Tests for pane status parser - detects Claude Code's activity from tmux pane output."""

import os
import pytest
from voice_server.infra.pane_parser import parse_pane_status, ActivityState, is_claude_ready

FIXTURES_DIR = os.path.join(os.path.dirname(__file__), "fixtures", "pane_captures")


def load_fixture(name):
    with open(os.path.join(FIXTURES_DIR, name)) as f:
        return f.read()


class TestParsePaneStatus:
    def test_detects_idle_state(self):
        pane_text = load_fixture("idle.txt")
        result = parse_pane_status(pane_text)
        assert result.state == "idle"
        assert result.detail == ""

    def test_detects_thinking_state(self):
        pane_text = load_fixture("thinking.txt")
        result = parse_pane_status(pane_text)
        assert result.state == "thinking"

    def test_detects_thinking_with_label(self):
        pane_text = load_fixture("thinking_with_label.txt")
        result = parse_pane_status(pane_text)
        assert result.state == "thinking"

    def test_detects_tool_with_thinking(self):
        """When both in-progress tool and thinking lines are present, tool_active
        wins because the tool description is more informative than 'Thinking...'."""
        pane_text = load_fixture("tool_searching.txt")
        result = parse_pane_status(pane_text)
        # Fixture has both in-progress tool line and thinking line
        assert result.state == "tool_active"
        assert "Searching" in result.detail

    def test_detects_tool_active_alone(self):
        """Tool active without thinking indicator below it."""
        pane_text = "⏺ Searching for 1 pattern… (ctrl+o to expand)\n  ⎿  voice_server/**/*.py\n\nesc to interrupt\n"
        result = parse_pane_status(pane_text)
        assert result.state == "tool_active"
        assert "Searching" in result.detail

    def test_detects_permission_prompt(self):
        pane_text = load_fixture("permission_prompt.txt")
        result = parse_pane_status(pane_text)
        assert result.state == "waiting_permission"

    def test_returns_idle_for_empty_pane(self):
        result = parse_pane_status("")
        assert result.state == "idle"

    def test_returns_idle_for_none(self):
        result = parse_pane_status(None)
        assert result.state == "idle"

    def test_thinking_spinner_variants(self):
        """All spinner characters should be detected as thinking."""
        for char in "✢✻✽✳·✶":
            pane_text = f"{char} Manifesting…\n"
            result = parse_pane_status(pane_text)
            assert result.state == "thinking", f"Failed for spinner char: {char}"

    def test_tool_in_progress_pattern(self):
        """In-progress tool lines use present tense with …"""
        pane_text = "⏺ Reading 3 files… (ctrl+o to expand)\n"
        result = parse_pane_status(pane_text)
        assert result.state == "tool_active"
        assert "Reading 3 files" in result.detail

    def test_tool_completed_is_not_active(self):
        """Completed tool lines (past tense) should not be tool_active."""
        pane_text = "⏺ Searched for 2 patterns, read 1 file (ctrl+o to expand)\n\n❯ \n"
        result = parse_pane_status(pane_text)
        assert result.state == "idle"

    def test_esc_to_interrupt_indicates_processing(self):
        """If 'esc to interrupt' is in the pane, Claude is processing."""
        pane_text = "✢ Manifesting…\n\nesc to interrupt\n"
        result = parse_pane_status(pane_text)
        assert result.state == "thinking"

    def test_tool_active_without_dot_prefix(self):
        """Tool lines without ⏺ prefix should still be detected (⏺ flickers)."""
        pane_text = "  Reading 1 file… (ctrl+o to expand)\n  ⎿  voice_server/server.py\n\nesc to interrupt\n"
        result = parse_pane_status(pane_text)
        assert result.state == "tool_active"
        assert "Reading 1 file" in result.detail

    def test_tool_active_compound_action(self):
        """Compound tool actions like 'Searching for 1 pattern, reading 9 files…'."""
        pane_text = "⏺ Searching for 1 pattern, reading 9 files… (ctrl+o to expand)\n  ⎿  voice_server/**/*.py\n\nesc to interrupt\n"
        result = parse_pane_status(pane_text)
        assert result.state == "tool_active"
        assert "Searching" in result.detail

    def test_completed_tool_without_dot_not_active(self):
        """Completed tool lines without ⏺ and without … should be idle."""
        pane_text = "  Searched for 1 pattern, read 9 files (ctrl+o to expand)\n\n❯ \n"
        result = parse_pane_status(pane_text)
        assert result.state == "idle"


class TestIsClaudeReady:
    def test_ready_when_idle_prompt_visible(self):
        pane_text = load_fixture("idle.txt")
        assert is_claude_ready(pane_text) is True

    def test_not_ready_when_loading(self):
        pane_text = load_fixture("startup_loading.txt")
        assert is_claude_ready(pane_text) is False

    def test_not_ready_for_empty_pane(self):
        assert is_claude_ready("") is False

    def test_not_ready_for_none(self):
        assert is_claude_ready(None) is False

    def test_ready_when_thinking(self):
        """Claude is ready (running) even when actively thinking."""
        pane_text = load_fixture("thinking.txt")
        assert is_claude_ready(pane_text) is True

    def test_ready_when_permission_prompt(self):
        """Claude is ready when showing a permission prompt."""
        pane_text = load_fixture("permission_prompt.txt")
        assert is_claude_ready(pane_text) is True
