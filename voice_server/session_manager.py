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
                    session_count=session_count
                ))

        return projects

    def _encode_project_path(self, project_path: str) -> str:
        """Encode project path to folder name format"""
        return project_path.replace("/", "-")

    def list_sessions(self, project_path: str, limit: int = 10) -> list[Session]:
        """List sessions for a project, sorted by most recent first"""
        folder_name = self._encode_project_path(project_path)
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
