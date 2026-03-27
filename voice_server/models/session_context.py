"""Per-session state container for multi-session support"""

import asyncio
from dataclasses import dataclass, field
from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from watchdog.observers import Observer


MAX_ACTIVE_SESSIONS = 5


@dataclass
class SessionContext:
    """Bundles all state for one active Claude Code session."""

    session_id: str  # Claude session ID (may be None for new sessions)
    folder_name: str  # Project folder name
    tmux_session_name: str  # e.g. "claude-connect_<session_id>"
    transcript_path: Optional[str] = None
    observer: Optional["Observer"] = None
    reconciliation_task: Optional[asyncio.Task] = None
    last_activity_state: object = None  # ActivityState from pane_parser
    idle_since: Optional[float] = None  # Timestamp when idle first detected (for debounce)
    current_branch: str = ""
    # For deferred new-session detection
    pending_session_snapshot: Optional[tuple] = None
    # Echo dedup
    last_voice_input: Optional[str] = None
    waiting_for_response: bool = False

    def cleanup(self):
        """Cancel async tasks and stop observer. Does NOT kill tmux."""
        if self.reconciliation_task and not self.reconciliation_task.done():
            self.reconciliation_task.cancel()
            self.reconciliation_task = None
        if self.observer:
            self.observer.unschedule_all()
