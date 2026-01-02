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
