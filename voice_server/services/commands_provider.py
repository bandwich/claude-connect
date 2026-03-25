"""Provides the merged list of slash commands (builtins + custom skills)."""

import os
import re

# All builtin commands from Claude Code docs
BUILTIN_COMMANDS = [
    ("add-dir", "Add a new working directory to the current session"),
    ("agents", "Manage agent configurations"),
    ("btw", "Ask a quick side question without adding to the conversation"),
    ("chrome", "Configure Claude in Chrome settings"),
    ("clear", "Clear conversation history and free up context"),
    ("color", "Set the prompt bar color for the current session"),
    ("compact", "Compact conversation with optional focus instructions"),
    ("config", "Open the Settings interface"),
    ("context", "Visualize current context usage"),
    ("copy", "Copy the last assistant response to clipboard"),
    ("cost", "Show token usage statistics"),
    ("desktop", "Continue the current session in the Desktop app"),
    ("diff", "Open an interactive diff viewer"),
    ("doctor", "Diagnose and verify your installation"),
    ("effort", "Set the model effort level"),
    ("exit", "Exit the CLI"),
    ("export", "Export the current conversation as plain text"),
    ("extra-usage", "Configure extra usage for rate limits"),
    ("fast", "Toggle fast mode"),
    ("feedback", "Submit feedback about Claude Code"),
    ("branch", "Create a branch of the current conversation"),
    ("help", "Show help and available commands"),
    ("hooks", "View hook configurations"),
    ("ide", "Manage IDE integrations"),
    ("init", "Initialize project with a CLAUDE.md guide"),
    ("insights", "Generate a report analyzing your sessions"),
    ("install-github-app", "Set up the Claude GitHub Actions app"),
    ("install-slack-app", "Install the Claude Slack app"),
    ("keybindings", "Open keybindings configuration file"),
    ("login", "Sign in to your Anthropic account"),
    ("logout", "Sign out from your Anthropic account"),
    ("mcp", "Manage MCP server connections"),
    ("memory", "Edit CLAUDE.md memory files"),
    ("mobile", "Show QR code to download the Claude mobile app"),
    ("model", "Select or change the AI model"),
    ("passes", "Share a free week of Claude Code with friends"),
    ("permissions", "View or update permissions"),
    ("plan", "Enter plan mode"),
    ("plugin", "Manage Claude Code plugins"),
    ("pr-comments", "Fetch and display comments from a GitHub PR"),
    ("privacy-settings", "View and update privacy settings"),
    ("release-notes", "View the full changelog"),
    ("reload-plugins", "Reload all active plugins"),
    ("remote-control", "Make session available for remote control"),
    ("remote-env", "Configure the default remote environment"),
    ("rename", "Rename the current session"),
    ("resume", "Resume a conversation by ID or name"),
    ("rewind", "Rewind conversation to a previous point"),
    ("sandbox", "Toggle sandbox mode"),
    ("schedule", "Create or manage Cloud scheduled tasks"),
    ("security-review", "Analyze pending changes for security vulnerabilities"),
    ("skills", "List available skills"),
    ("stats", "Visualize daily usage and session history"),
    ("status", "Show version, model, account, and connectivity"),
    ("statusline", "Configure the status line"),
    ("stickers", "Order Claude Code stickers"),
    ("tasks", "List and manage background tasks"),
    ("terminal-setup", "Configure terminal keybindings"),
    ("theme", "Change the color theme"),
    ("upgrade", "Open the upgrade page"),
    ("usage", "Show plan usage limits and rate limit status"),
    ("vim", "Toggle between Vim and Normal editing modes"),
    ("voice", "Toggle push-to-talk voice dictation"),
    # Bundled skills
    ("batch", "Orchestrate large-scale changes across a codebase in parallel"),
    ("claude-api", "Load Claude API reference material for your project"),
    ("debug", "Troubleshoot your current Claude Code session"),
    ("loop", "Run a prompt repeatedly on an interval"),
    ("simplify", "Review changed files for code reuse, quality, and efficiency"),
]

_FRONTMATTER_RE = re.compile(r"^---\s*\n(.*?)\n---", re.DOTALL)


def _parse_frontmatter(content: str) -> dict:
    """Extract name and description from SKILL.md YAML frontmatter."""
    match = _FRONTMATTER_RE.match(content)
    if not match:
        return {}
    result = {}
    for line in match.group(1).splitlines():
        if ":" in line:
            key, _, value = line.partition(":")
            key = key.strip()
            value = value.strip()
            if key in ("name", "description"):
                result[key] = value
    return result


class CommandsProvider:
    """Builds merged list of slash commands from builtins + skill directories."""

    def __init__(self, user_skills_path=None):
        if user_skills_path is None:
            user_skills_path = os.path.expanduser("~/.claude/skills")
        self._user_skills_path = user_skills_path

    def get_builtin_commands(self):
        return [
            {"name": name, "description": desc, "source": "builtin"}
            for name, desc in BUILTIN_COMMANDS
        ]

    def scan_skills_directory(self, path):
        """Scan a skills directory for SKILL.md files, return command dicts."""
        if not os.path.isdir(path):
            return []
        skills = []
        for entry in os.listdir(path):
            skill_file = os.path.join(path, entry, "SKILL.md")
            if not os.path.isfile(skill_file):
                continue
            try:
                with open(skill_file, "r") as f:
                    content = f.read()
                fm = _parse_frontmatter(content)
                skills.append({
                    "name": fm.get("name", entry),
                    "description": fm.get("description", ""),
                    "source": "skill",
                })
            except OSError:
                continue
        return skills

    def get_all_commands(self, project_skills_path=None):
        """Merge builtins + user skills + optional project skills, deduped."""
        builtins = self.get_builtin_commands()
        builtin_names = {c["name"] for c in builtins}

        user_skills = self.scan_skills_directory(self._user_skills_path)
        if project_skills_path:
            user_skills.extend(self.scan_skills_directory(project_skills_path))

        # Builtins win on name conflicts
        for skill in user_skills:
            if skill["name"] not in builtin_names:
                builtins.append(skill)
                builtin_names.add(skill["name"])

        builtins.sort(key=lambda c: c["name"])
        return builtins
