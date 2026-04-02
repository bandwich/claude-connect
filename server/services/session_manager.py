"""Session management for Claude Code projects"""

import os
import re
import json
import glob
import subprocess
from dataclasses import dataclass, field
from datetime import datetime
from typing import Optional


IMAGE_SOURCE_RE = re.compile(r'^\[Image: source: (.+)\]$')
COMMAND_ARGS_RE = re.compile(r'<command-args>(.*?)(?:</command-args>|$)', re.DOTALL)
COMMAND_NAME_RE = re.compile(r'<command-name>(/\S+)</command-name>')

def rewrite_user_text(text: str) -> str:
    """Clean up user text for display: rewrite image sources, strip suffixes."""
    stripped = text.strip()
    m = IMAGE_SOURCE_RE.match(stripped)
    if m:
        return f"[Image: {os.path.basename(m.group(1))}]"
    if stripped.startswith('[Request interrupted by user'):
        return "[Request interrupted by user]"
    return stripped


@dataclass
class Project:
    """Represents a Claude Code project"""
    path: str
    name: str
    session_count: int
    folder_name: str  # Original folder name for direct lookup


@dataclass
class Session:
    """Represents a session within a project"""
    id: str
    title: str
    timestamp: float
    message_count: int
    folder_name: str = ""  # Source folder (for worktree sessions that live in a different folder)
    worktree_branch: str = ""  # Git branch name if this session is from a worktree


@dataclass
class SessionMessage:
    """Represents a message in a session"""
    role: str
    content: str
    timestamp: float
    content_blocks: list = None  # Raw block dicts for structured messages


# Internal tool names that are bookkeeping, not shown in terminal UI
HIDDEN_TOOLS = {'TaskCreate', 'TaskUpdate', 'TaskGet', 'TaskList', 'TaskStop', 'TaskOutput'}


from server.models.content_models import strip_agent_metadata as _strip_agent_metadata


class SessionManager:
    """Manages reading Claude Code projects and sessions from disk"""

    def __init__(self, projects_dir: Optional[str] = None):
        self.projects_dir = projects_dir or os.path.expanduser("~/.claude/projects/")

    def _get_worktree_folders(self, project_path: str) -> dict[str, str]:
        """Get project folders for linked worktrees of a given project.

        Runs `git worktree list` in the project directory and returns a mapping
        of {folder_name: branch_name} for each linked worktree that has a
        corresponding folder in ~/.claude/projects/.

        Excludes the main worktree (first entry in porcelain output), so this
        is safe to call from any worktree path — it always returns only linked
        worktrees, never the main repo.
        """
        result = {}
        try:
            proc = subprocess.run(
                ["git", "worktree", "list", "--porcelain"],
                cwd=project_path, capture_output=True, text=True, timeout=5
            )
            if proc.returncode != 0:
                return result
        except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
            return result

        # Parse porcelain output: blocks separated by blank lines
        # Each block has: worktree <path>\nHEAD <sha>\nbranch refs/heads/<name>
        # First entry is always the main worktree — skip it.
        main_worktree_path = None
        current_path = None
        current_branch = None
        for line in proc.stdout.splitlines():
            if line.startswith("worktree "):
                current_path = line[9:]
                current_branch = None
            elif line.startswith("branch refs/heads/"):
                current_branch = line[18:]
            elif line == "":
                if current_path:
                    real_path = os.path.realpath(current_path)
                    if main_worktree_path is None:
                        main_worktree_path = real_path  # First entry = main
                    elif current_branch:
                        folder = self.encode_path_to_folder(real_path)
                        folder_dir = os.path.join(self.projects_dir, folder)
                        if os.path.isdir(folder_dir):
                            result[folder] = current_branch
                current_path = None
                current_branch = None
        # Handle last block (porcelain output may not end with blank line)
        if current_path:
            real_path = os.path.realpath(current_path)
            if main_worktree_path is None:
                pass  # Only one worktree (the main one), nothing to return
            elif current_branch:
                folder = self.encode_path_to_folder(real_path)
                folder_dir = os.path.join(self.projects_dir, folder)
                if os.path.isdir(folder_dir):
                    result[folder] = current_branch
        return result

    def list_projects(self) -> list[Project]:
        """List all projects with session counts.

        Worktree project folders are hidden — their sessions are merged into
        the parent project via list_sessions().
        """
        if not os.path.exists(self.projects_dir):
            return []

        # First pass: build project list with decoded paths
        raw_projects = []
        for entry in os.listdir(self.projects_dir):
            project_path = os.path.join(self.projects_dir, entry)
            if os.path.isdir(project_path):
                session_count = len(glob.glob(os.path.join(project_path, "*.jsonl")))

                # Try to get actual path from session cwd (authoritative source)
                # This handles the lossy encoding where both / and _ become -
                actual_path = self._get_project_cwd(entry)

                if actual_path:
                    decoded_path = actual_path
                    # Skip projects whose actual directory no longer exists
                    if not os.path.exists(decoded_path):
                        continue
                else:
                    # Fallback: naive decode (can't distinguish _ from / in encoded form)
                    decoded_path = entry.replace("-", "/")
                    if not decoded_path.startswith("/"):
                        decoded_path = "/" + decoded_path

                raw_projects.append((entry, decoded_path, session_count))

        # Second pass: find worktree folders to hide and cache results
        worktree_map = {}  # decoded_path -> {folder: branch}
        worktree_folders = set()
        for entry, decoded_path, _ in raw_projects:
            wt_folders = self._get_worktree_folders(decoded_path)
            worktree_map[decoded_path] = wt_folders
            worktree_folders.update(wt_folders.keys())

        projects = []
        for entry, decoded_path, session_count in raw_projects:
            if entry in worktree_folders:
                continue  # Hidden — sessions appear under parent project
            # Add worktree session counts to parent
            for wt_folder in worktree_map.get(decoded_path, {}):
                wt_path = os.path.join(self.projects_dir, wt_folder)
                session_count += len(glob.glob(os.path.join(wt_path, "*.jsonl")))

            name = os.path.basename(decoded_path)
            projects.append(Project(
                path=decoded_path,
                name=name,
                session_count=session_count,
                folder_name=entry,
            ))

        projects.sort(key=lambda p: self._get_project_latest_mtime(p.folder_name), reverse=True)
        return projects

    def _get_project_latest_mtime(self, folder_name: str) -> float:
        """Get the mtime of the most recent session file in a project."""
        project_path = os.path.join(self.projects_dir, folder_name)
        session_files = glob.glob(os.path.join(project_path, "*.jsonl"))
        if not session_files:
            return 0
        return max(os.path.getmtime(f) for f in session_files)

    def _get_project_cwd(self, folder_name: str) -> Optional[str]:
        """Get the actual project path from session cwd fields.

        Claude's folder encoding is lossy (both / and _ become -), so we
        read the cwd from session files to get the authoritative path.
        Tries multiple sessions since some may lack cwd (e.g., file-history-snapshot).
        """
        folder_path = os.path.join(self.projects_dir, folder_name)
        if not os.path.exists(folder_path):
            return None

        session_files = glob.glob(os.path.join(folder_path, "*.jsonl"))
        session_files = [f for f in session_files if not os.path.basename(f).startswith("agent-")]
        session_files.sort(key=os.path.getmtime, reverse=True)

        # Try sessions until we find one with cwd
        for filepath in session_files[:10]:  # Check up to 10 newest
            session_id = os.path.splitext(os.path.basename(filepath))[0]
            cwd = self.get_session_cwd(folder_name, session_id)
            if cwd:
                return cwd
        return None

    def _encode_project_path(self, project_path: str) -> str:
        """Encode project path to folder name format"""
        return project_path.replace("/", "-")

    def encode_path_to_folder(self, path: str) -> str:
        """Encode a path to Claude's folder name format.

        Claude encodes both / and _ as - in folder names.
        e.g., /tmp/e2e_test_project -> -tmp-e2e-test-project
        """
        # Resolve symlinks (e.g., /tmp -> /private/tmp on macOS)
        resolved = os.path.realpath(path)
        return resolved.replace("/", "-").replace("_", "-")

    def find_newest_session(self, folder_name: str) -> Optional[str]:
        """Find the most recently created session in a folder.

        Args:
            folder_name: The folder name in projects_dir

        Returns:
            Session ID of the newest session, or None if no sessions found
        """
        folder_path = os.path.join(self.projects_dir, folder_name)
        if not os.path.exists(folder_path):
            return None

        session_files = glob.glob(os.path.join(folder_path, "*.jsonl"))
        # Filter out agent files
        session_files = [f for f in session_files if not os.path.basename(f).startswith("agent-")]

        if not session_files:
            return None

        # Sort by modification time (newest first)
        session_files.sort(key=os.path.getmtime, reverse=True)

        # Return the session ID (filename without .jsonl)
        return os.path.splitext(os.path.basename(session_files[0]))[0]

    def list_session_ids(self, folder_name: str) -> set[str]:
        """Return set of all session IDs (excluding agent files) in a folder."""
        folder_path = os.path.join(self.projects_dir, folder_name)
        if not os.path.exists(folder_path):
            return set()

        session_files = glob.glob(os.path.join(folder_path, "*.jsonl"))
        session_files = [f for f in session_files if not os.path.basename(f).startswith("agent-")]
        return {os.path.splitext(os.path.basename(f))[0] for f in session_files}

    def find_new_session(self, folder_name: str, exclude_ids: set[str]) -> Optional[str]:
        """Find a session ID that is not in the exclude set.

        Used to detect a newly created session after snapshotting existing IDs.
        """
        current_ids = self.list_session_ids(folder_name)
        new_ids = current_ids - exclude_ids
        if not new_ids:
            return None
        if len(new_ids) == 1:
            return new_ids.pop()
        # If multiple new IDs (unlikely), return the newest by mtime
        folder_path = os.path.join(self.projects_dir, folder_name)
        newest = max(new_ids, key=lambda sid: os.path.getmtime(os.path.join(folder_path, f"{sid}.jsonl")))
        return newest

    def get_session_cwd(self, folder_name: str, session_id: str) -> Optional[str]:
        """Get the working directory from a session file.

        Args:
            folder_name: The folder name in projects_dir
            session_id: The session ID (filename without .jsonl)

        Returns:
            The cwd path, or None if not found
        """
        filepath = os.path.join(self.projects_dir, folder_name, f"{session_id}.jsonl")

        if not os.path.exists(filepath):
            return None

        try:
            with open(filepath, 'r') as f:
                for line in f:
                    try:
                        entry = json.loads(line.strip())
                        if 'cwd' in entry:
                            return entry['cwd']
                    except json.JSONDecodeError:
                        continue
        except Exception:
            pass

        return None

    def _collect_sessions(self, folder_name: str, worktree_branch: str = "") -> list[Session]:
        """Collect sessions from a single project folder."""
        project_dir = os.path.join(self.projects_dir, folder_name)
        if not os.path.exists(project_dir):
            return []

        sessions = []
        session_files = glob.glob(os.path.join(project_dir, "*.jsonl"))

        for filepath in session_files:
            session_id = os.path.splitext(os.path.basename(filepath))[0]
            title, message_count, timestamp = self._parse_session_file(filepath)

            if title.startswith("Warmup") or title == "Untitled" or message_count == 0:
                continue

            sessions.append(Session(
                id=session_id,
                title=title,
                timestamp=timestamp,
                message_count=message_count,
                folder_name=folder_name,
                worktree_branch=worktree_branch,
            ))

        return sessions

    def list_sessions(self, folder_name: str, limit: int = 10) -> list[Session]:
        """List sessions for a project, sorted by most recent first.

        Includes sessions from git worktree folders that belong to this project.

        Args:
            folder_name: The actual folder name in projects_dir (not encoded path)
            limit: Maximum number of sessions to return
        """
        sessions = self._collect_sessions(folder_name)

        # Find worktree folders and include their sessions
        project_path = self._get_project_cwd(folder_name)
        if project_path:
            for wt_folder, branch in self._get_worktree_folders(project_path).items():
                sessions.extend(self._collect_sessions(wt_folder, worktree_branch=branch))

        # Sort by last message timestamp (most recent first)
        sessions.sort(key=lambda s: s.timestamp, reverse=True)
        return sessions[:limit]

    @staticmethod
    def _extract_title(text: str) -> str:
        """Extract a session title from a user message.

        For normal messages, returns the text (up to 50 chars).
        For skill commands (system-injected), extracts command-args if present,
        or falls back to the command name (e.g. "/dispatch").
        Returns empty string if no title can be extracted.
        """
        if not text or not text.strip():
            return ""
        stripped = text.strip()
        if not SessionManager._is_system_injected(stripped):
            return stripped[:50]
        # Skill command — try to extract args
        m = COMMAND_ARGS_RE.search(stripped)
        if m:
            args = m.group(1).strip()
            if args:
                return args[:50]
        # Fall back to command name
        m = COMMAND_NAME_RE.search(stripped)
        if m:
            return m.group(1)
        return ""

    @staticmethod
    def _is_system_injected(text: str) -> bool:
        """Check if a user message is actually system-injected, not real user input."""
        stripped = text.strip()
        return (
            stripped.startswith('<local-command-caveat>')
            or stripped.startswith('<task-notification')
            or stripped.startswith('Base directory for this skill:')
            or '<command-name>' in stripped
            or '<local-command-stdout>' in stripped
        )

    def _parse_session_file(self, filepath: str) -> tuple[str, int, float]:
        """Parse session file to extract title, message count, and timestamp

        Returns:
            Tuple of (title, message_count, last_timestamp)
        """
        title = "Untitled"
        message_count = 0
        last_timestamp = os.path.getmtime(filepath)

        try:
            with open(filepath, 'r') as f:
                for line in f:
                    try:
                        entry = json.loads(line.strip())
                        msg = entry.get('message', {})
                        role = msg.get('role') or entry.get('role')

                        if role in ('user', 'assistant'):
                            message_count += 1

                            # Track last message timestamp
                            entry_ts = entry.get('timestamp', '')
                            if entry_ts:
                                try:
                                    parsed = datetime.fromisoformat(entry_ts.replace('Z', '+00:00')).timestamp()
                                    last_timestamp = parsed
                                except Exception:
                                    pass

                            # Get title from first real user message
                            if role == 'user' and title == "Untitled":
                                content = msg.get('content', entry.get('content', ''))
                                if isinstance(content, str):
                                    title = self._extract_title(content) or title
                                elif isinstance(content, list):
                                    for block in content:
                                        if isinstance(block, dict) and block.get('type') == 'text':
                                            title = self._extract_title(block.get('text', '')) or title
                                            break
                    except json.JSONDecodeError:
                        continue
        except Exception:
            pass

        return title, message_count, last_timestamp

    def get_session_history(self, folder_name: str, session_id: str) -> list[SessionMessage]:
        """Get all messages from a session with structured content blocks.

        Args:
            folder_name: The actual folder name in projects_dir (not encoded path)
            session_id: The session ID (filename without .jsonl)
        """
        filepath = os.path.join(self.projects_dir, folder_name, f"{session_id}.jsonl")

        if not os.path.exists(filepath):
            return []

        messages = []
        hidden_tool_ids = set()  # Track tool_use IDs for hidden tools
        agent_tool_ids = set()  # Track tool_use IDs for Agent tools

        with open(filepath, 'r') as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                    msg = entry.get('message', {})
                    role = msg.get('role') or entry.get('role')

                    if role not in ('user', 'assistant'):
                        continue

                    # Skip synthetic messages (Claude Code internal, e.g. "No response requested")
                    if role == 'assistant' and msg.get('model') == '<synthetic>':
                        continue

                    content = msg.get('content', entry.get('content', ''))

                    timestamp_str = entry.get('timestamp', '')
                    try:
                        from datetime import datetime
                        timestamp = datetime.fromisoformat(timestamp_str.replace('Z', '+00:00')).timestamp()
                    except Exception:
                        timestamp = 0.0

                    if isinstance(content, list):
                        # Check if this is a tool_result message
                        has_tool_result = any(
                            isinstance(b, dict) and b.get('type') == 'tool_result'
                            for b in content
                        )

                        if has_tool_result:
                            # Emit each tool_result as a separate message (skip hidden tools)
                            for block in content:
                                if isinstance(block, dict) and block.get('type') == 'tool_result':
                                    # Skip results for hidden tools
                                    if block.get('tool_use_id', '') in hidden_tool_ids:
                                        continue
                                    raw_content = block.get('content', '')
                                    # Normalize content to string (can be a list of text blocks)
                                    if isinstance(raw_content, list):
                                        str_content = '\n'.join(
                                            b.get('text', '') for b in raw_content
                                            if isinstance(b, dict) and b.get('type') == 'text'
                                        )
                                    elif isinstance(raw_content, str):
                                        str_content = raw_content
                                    else:
                                        str_content = str(raw_content)
                                    # Strip metadata from Agent tool results
                                    if block.get('tool_use_id', '') in agent_tool_ids:
                                        str_content = _strip_agent_metadata(str_content)
                                    # Build normalized block for iOS decoding
                                    normalized_block = {
                                        'type': 'tool_result',
                                        'tool_use_id': block.get('tool_use_id', ''),
                                        'content': str_content,
                                        'is_error': block.get('is_error', False),
                                    }
                                    messages.append(SessionMessage(
                                        role="tool_result",
                                        content=str_content,
                                        timestamp=timestamp,
                                        content_blocks=[normalized_block]
                                    ))
                            continue

                        # Track and filter hidden tool_use blocks
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'tool_use':
                                if block.get('name', '') in HIDDEN_TOOLS:
                                    hidden_tool_ids.add(block.get('id', ''))
                                if block.get('name', '') == 'Agent':
                                    agent_tool_ids.add(block.get('id', ''))
                        content = [
                            b for b in content
                            if not (isinstance(b, dict) and b.get('type') == 'tool_use'
                                    and b.get('name', '') in HIDDEN_TOOLS)
                        ]

                        # Skip image blocks (base64 data too large for display)
                        content = [
                            b for b in content
                            if not (isinstance(b, dict) and b.get('type') == 'image')
                        ]

                        # Assistant message with structured blocks
                        text_parts = []
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'text':
                                text_parts.append(rewrite_user_text(block.get('text', '').strip()))
                        flat_content = ' '.join(text_parts).strip()

                        # Check if there are non-text blocks worth keeping
                        has_tool_use = any(
                            isinstance(b, dict) and b.get('type') == 'tool_use'
                            for b in content
                        )

                        if not flat_content.strip() and not has_tool_use:
                            continue  # Skip thinking-only or whitespace-only messages

                        # Skip skill expansions and command noise
                        if role == 'user' and self._is_system_injected(flat_content):
                            continue

                        messages.append(SessionMessage(
                            role=role,
                            content=flat_content,
                            timestamp=timestamp,
                            content_blocks=content if has_tool_use else None
                        ))
                    else:
                        # Simple string content
                        if not content or not content.strip():
                            continue

                        # Skip skill expansions and system-injected messages
                        if role == 'user' and self._is_system_injected(content):
                            continue

                        messages.append(SessionMessage(
                            role=role,
                            content=rewrite_user_text(content),
                            timestamp=timestamp,
                            content_blocks=None
                        ))
                except json.JSONDecodeError:
                    continue

        return messages
