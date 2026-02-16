"""Session management for Claude Code projects"""

import os
import re
import json
import glob
from dataclasses import dataclass
from typing import Optional


IMAGE_SOURCE_RE = re.compile(r'^\[Image: source: (.+)\]$')

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


@dataclass
class SessionMessage:
    """Represents a message in a session"""
    role: str
    content: str
    timestamp: float
    content_blocks: list = None  # Raw block dicts for structured messages


# Internal tool names that are bookkeeping, not shown in terminal UI
HIDDEN_TOOLS = {'TaskCreate', 'TaskUpdate', 'TaskGet', 'TaskList', 'TaskStop'}


class SessionManager:
    """Manages reading Claude Code projects and sessions from disk"""

    def __init__(self, projects_dir: Optional[str] = None):
        self.projects_dir = projects_dir or os.path.expanduser("~/.claude/projects/")

    def list_projects(self) -> list[Project]:
        """List all projects with session counts"""
        if not os.path.exists(self.projects_dir):
            return []

        projects = []
        for entry in os.listdir(self.projects_dir):
            project_path = os.path.join(self.projects_dir, entry)
            if os.path.isdir(project_path):
                session_count = len(glob.glob(os.path.join(project_path, "*.jsonl")))

                # Try to get actual path from session cwd (authoritative source)
                # This handles the lossy encoding where both / and _ become -
                actual_path = self._get_project_cwd(entry)

                if actual_path:
                    decoded_path = actual_path
                else:
                    # Fallback: naive decode (can't distinguish _ from / in encoded form)
                    decoded_path = entry.replace("-", "/")
                    if not decoded_path.startswith("/"):
                        decoded_path = "/" + decoded_path

                name = os.path.basename(decoded_path)

                projects.append(Project(
                    path=decoded_path,
                    name=name,
                    session_count=session_count,
                    folder_name=entry  # Store original folder name
                ))

        return projects

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

    def list_sessions(self, folder_name: str, limit: int = 10) -> list[Session]:
        """List sessions for a project, sorted by most recent first

        Args:
            folder_name: The actual folder name in projects_dir (not encoded path)
            limit: Maximum number of sessions to return
        """
        project_dir = os.path.join(self.projects_dir, folder_name)

        if not os.path.exists(project_dir):
            return []

        sessions = []
        session_files = glob.glob(os.path.join(project_dir, "*.jsonl"))

        # Sort by modification time (most recent first)
        session_files.sort(key=os.path.getmtime, reverse=True)

        for filepath in session_files:
            session_id = os.path.splitext(os.path.basename(filepath))[0]
            title, message_count, timestamp = self._parse_session_file(filepath)

            # Filter out Warmup sessions (subagent warmups) and empty sessions
            if title.startswith("Warmup") or message_count == 0:
                continue

            sessions.append(Session(
                id=session_id,
                title=title,
                timestamp=timestamp,
                message_count=message_count
            ))

            # Stop once we have enough valid sessions
            if len(sessions) >= limit:
                break

        return sessions

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

                            # Get title from first user message
                            if role == 'user' and title == "Untitled":
                                content = msg.get('content', entry.get('content', ''))
                                if isinstance(content, str):
                                    title = content[:50]
                                elif isinstance(content, list):
                                    for block in content:
                                        if isinstance(block, dict) and block.get('type') == 'text':
                                            title = block.get('text', '')[:50]
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

        with open(filepath, 'r') as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                    msg = entry.get('message', {})
                    role = msg.get('role') or entry.get('role')

                    if role not in ('user', 'assistant'):
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

                        # Skip skill expansions
                        if role == 'user' and flat_content.strip().startswith('Base directory for this skill:'):
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
                        if role == 'user':
                            stripped = content.strip()
                            if stripped.startswith('Base directory for this skill:'):
                                continue
                            if stripped.startswith('<task-notification'):
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
