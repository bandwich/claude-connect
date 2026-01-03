"""Session management for Claude Code projects"""

import os
import json
import glob
from dataclasses import dataclass
from typing import Optional


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
                # Decode path from folder name (e.g., "-Users-aaron-Desktop-max" -> "/Users/aaron/Desktop/max")
                decoded_path = entry.replace("-", "/")
                if decoded_path.startswith("/"):
                    decoded_path = decoded_path  # Already absolute
                else:
                    decoded_path = "/" + decoded_path

                name = os.path.basename(decoded_path)
                session_count = len(glob.glob(os.path.join(project_path, "*.jsonl")))

                projects.append(Project(
                    path=decoded_path,
                    name=name,
                    session_count=session_count,
                    folder_name=entry  # Store original folder name
                ))

        return projects

    def _encode_project_path(self, project_path: str) -> str:
        """Encode project path to folder name format"""
        return project_path.replace("/", "-")

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

        for filepath in session_files[:limit]:
            session_id = os.path.splitext(os.path.basename(filepath))[0]
            title, message_count, timestamp = self._parse_session_file(filepath)

            sessions.append(Session(
                id=session_id,
                title=title,
                timestamp=timestamp,
                message_count=message_count
            ))

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
        """Get all messages from a session

        Args:
            folder_name: The actual folder name in projects_dir (not encoded path)
            session_id: The session ID (filename without .jsonl)
        """
        filepath = os.path.join(self.projects_dir, folder_name, f"{session_id}.jsonl")

        if not os.path.exists(filepath):
            return []

        messages = []

        with open(filepath, 'r') as f:
            for line in f:
                try:
                    entry = json.loads(line.strip())
                    msg = entry.get('message', {})
                    role = msg.get('role') or entry.get('role')

                    if role not in ('user', 'assistant'):
                        continue

                    content = msg.get('content', entry.get('content', ''))

                    # Flatten assistant content blocks to text
                    if isinstance(content, list):
                        text_parts = []
                        for block in content:
                            if isinstance(block, dict) and block.get('type') == 'text':
                                text_parts.append(block.get('text', ''))
                        content = ' '.join(text_parts)

                    timestamp_str = entry.get('timestamp', '')
                    try:
                        from datetime import datetime
                        timestamp = datetime.fromisoformat(timestamp_str.replace('Z', '+00:00')).timestamp()
                    except:
                        timestamp = 0.0

                    messages.append(SessionMessage(
                        role=role,
                        content=content,
                        timestamp=timestamp
                    ))
                except json.JSONDecodeError:
                    continue

        return messages
