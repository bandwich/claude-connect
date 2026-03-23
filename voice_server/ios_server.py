#!/usr/bin/env python3
"""
iOS Voice Mode Server
WebSocket server that bridges iOS app with Claude Code
"""

import sys
sys.dont_write_bytecode = True

import asyncio
import websockets
import json
import re
import sys
import os
import subprocess
import time
import glob
import base64
import threading
from typing import Optional

from watchdog.observers import Observer
from watchdog.events import FileSystemEventHandler
from voice_server.tts_utils import generate_tts_audio, samples_to_wav_bytes
from voice_server.content_models import TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock, ContentBlock, AssistantResponse
from voice_server.session_manager import SessionManager, HIDDEN_TOOLS
from voice_server.context_tracker import ContextTracker
from voice_server.usage_checker import UsageChecker
from voice_server.tmux_controller import TmuxController, session_name_for
from voice_server.session_context import SessionContext, MAX_ACTIVE_SESSIONS
from voice_server.permission_handler import PermissionHandler
from voice_server.http_server import start_http_server, set_tmux_controller, set_voice_server

# Configuration
PORT = 8765
TRANSCRIPT_DIR = os.path.expanduser("~/.claude/projects/")
PROJECTS_BASE_PATH = os.path.expanduser("~/Desktop/code")
IMAGE_EXTENSIONS = {'.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp', '.ico'}
MAX_IMAGE_SIZE = 10 * 1024 * 1024  # 10MB


def strip_markdown_for_speech(text: str) -> str:
    """Strip markdown formatting so TTS doesn't speak asterisks, backticks, etc."""
    import re
    s = text
    # Bold/italic: **text** or *text* or ***text***
    s = re.sub(r'\*{1,3}(.+?)\*{1,3}', r'\1', s)
    # Inline code: `text`
    s = re.sub(r'`([^`]+)`', r'\1', s)
    # Links: [text](url) → text
    s = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', s)
    # Heading prefixes: ### text → text
    s = re.sub(r'^#{1,6}\s+', '', s, flags=re.MULTILINE)
    return s


def extract_text_for_tts(content_blocks: list[ContentBlock]) -> str:
    """Extract only text blocks for TTS, with markdown stripped"""
    text_parts = []
    for block in content_blocks:
        if isinstance(block, TextBlock):
            text_parts.append(strip_markdown_for_speech(block.text))
    return ' '.join(text_parts).strip()


IMAGE_SOURCE_RE = re.compile(r'^\[Image: source: (.+)\]$')

def rewrite_user_text(text: str) -> str:
    """Clean up user text for display: rewrite image sources, strip suffixes."""
    stripped = text.strip()
    # [Image: source: /path/to/file.png] -> [Image: file.png]
    m = IMAGE_SOURCE_RE.match(stripped)
    if m:
        filename = os.path.basename(m.group(1))
        return f"[Image: {filename}]"
    # Strip "for tool use" suffix from interrupt messages
    if stripped.startswith('[Request interrupted by user'):
        return "[Request interrupted by user]"
    return stripped


async def poll_for_session_file(find_fn, timeout=10.0, interval=0.2):
    """Poll for a session transcript file to appear.

    Args:
        find_fn: Callable that returns file path/session ID or None
        timeout: Max seconds to wait
        interval: Seconds between polls

    Returns:
        Result from find_fn, or None if timeout
    """
    elapsed = 0.0
    while elapsed < timeout:
        result = find_fn()
        if result:
            return result
        await asyncio.sleep(interval)
        elapsed += interval
    return None


from voice_server.content_models import strip_agent_metadata as _strip_agent_metadata


class TranscriptHandler(FileSystemEventHandler):
    """Monitors transcript file for new assistant messages

    Uses line-position tracking to stream ALL assistant content,
    regardless of whether voice input initiated the interaction.

    Only processes events from the expected session file, ignoring
    sub-agent transcripts (agent-*.jsonl) and other sessions.
    """

    def __init__(self, content_callback, audio_callback, loop, server, user_callback=None):
        self.content_callback = content_callback  # Sends AssistantResponse
        self.audio_callback = audio_callback       # Sends text for TTS
        self.user_callback = user_callback          # Sends user text messages
        self.loop = loop
        self.server = server
        self.last_modified = 0
        self.processed_line_count = 0
        self.expected_session_file = None  # Only process events from this file
        self.context_tracker = ContextTracker()
        self.hidden_tool_ids = set()  # Track IDs of hidden tool_use blocks
        self.agent_tool_ids = set()  # Track IDs of Agent tool_use blocks
        self._lock = threading.Lock()  # Protects processed_line_count and expected_session_file

    def on_modified(self, event):
        if event.is_directory or not event.src_path.endswith('.jsonl'):
            return

        # Ignore sub-agent transcripts (they have their own sessions)
        filename = os.path.basename(event.src_path)
        if filename.startswith('agent-'):
            return

        with self._lock:
            # Only process events from the expected session file
            # Use realpath to normalize paths - watchdog may report resolved paths
            # while expected_session_file uses unresolved paths (e.g., /tmp vs /private/tmp on macOS)
            if self.expected_session_file:
                if os.path.realpath(event.src_path) != os.path.realpath(self.expected_session_file):
                    return

            line_count_before = self.processed_line_count
            try:
                new_blocks, user_texts, task_completed_ids, start_line = self.extract_new_content_with_seq(event.src_path)
            except Exception as e:
                print(f"Error processing transcript: {e}")
                import traceback
                traceback.print_exc()
                return

            line_count_after = self.processed_line_count
            if new_blocks or user_texts:
                print(f"[SYNC] on_modified: lines {line_count_before}→{line_count_after}, "
                      f"blocks={len(new_blocks)}, user_texts={len(user_texts)}")
            elif line_count_after > line_count_before:
                print(f"[SYNC] on_modified: lines {line_count_before}→{line_count_after} (no extractable content)")

        # Send callbacks OUTSIDE the lock (they schedule async work)
        try:
            if new_blocks:
                response = AssistantResponse(
                    content_blocks=new_blocks,
                    timestamp=time.time(),
                    is_incremental=True
                )

                asyncio.run_coroutine_threadsafe(
                    self.content_callback(response, start_line),
                    self.loop
                )

                # Only generate TTS if the iOS app has this session open
                # (active_session_id is set when the app opens/resumes a session)
                # Skip TTS when server exists but no session is active in the app
                if not self.server or self.server.active_session_id:
                    text = extract_text_for_tts(new_blocks)
                    if text:
                        asyncio.run_coroutine_threadsafe(
                            self.audio_callback(text),
                            self.loop
                        )
                    else:
                        # No TTS text (e.g., only thinking/tool_use blocks)
                        # Send idle status to reset client's outputState
                        asyncio.run_coroutine_threadsafe(
                            self.server.send_idle_to_all_clients(),
                            self.loop
                        )

            if new_blocks:
                print(f"[SYNC] Scheduled content_callback (seq={start_line})")
            if user_texts and self.user_callback:
                for user_text, user_line_num in user_texts:
                    asyncio.run_coroutine_threadsafe(
                        self.user_callback(user_text, user_line_num),
                        self.loop
                    )
                print(f"[SYNC] Scheduled {len(user_texts)} user_callbacks")

            if task_completed_ids and self.server:
                for tool_id in task_completed_ids:
                    asyncio.run_coroutine_threadsafe(
                        self.server.broadcast_task_completed(tool_id),
                        self.loop
                    )
                print(f"[SYNC] Scheduled {len(task_completed_ids)} task_completed broadcasts")

            # Broadcast context update after processing
            if self.server and getattr(self.server, 'active_session_id', None):
                self.broadcast_context_update(event.src_path, self.server.active_session_id)
        except Exception as e:
            print(f"Error processing transcript: {e}")
            import traceback
            traceback.print_exc()

    def extract_new_content_with_seq(self, filepath) -> tuple:
        """Like extract_new_content but also returns the starting line number.

        Returns:
            (content_blocks, user_texts_with_line, task_completed_ids, start_line_number)
            user_texts_with_line is list of (text, line_number) tuples
            task_completed_ids is list of tool_use_id strings
        """
        start_line = self.processed_line_count
        blocks, user_texts_with_line, task_completed_ids = self.extract_new_content(filepath)
        return blocks, user_texts_with_line, task_completed_ids, start_line

    def extract_new_assistant_content(self, filepath) -> list[ContentBlock]:
        """Legacy wrapper — returns only content blocks."""
        blocks, _, _ = self.extract_new_content(filepath)
        return blocks

    def extract_new_content(self, filepath) -> tuple:
        """Extract assistant content, tool results, and user texts from new lines.

        Returns:
            (content_blocks, user_texts_with_line, task_completed_ids) where
            user_texts_with_line is a list of (text, line_number) tuples and
            task_completed_ids is a list of tool_use_id strings from background task completions.
        """
        all_blocks = []
        user_texts = []
        task_completed_ids = []

        with open(filepath, 'r') as f:
            lines = f.readlines()

        # Reset if file was truncated/overwritten (fewer lines than we've processed)
        if len(lines) < self.processed_line_count:
            self.processed_line_count = 0

        new_lines = lines[self.processed_line_count:]

        for line_offset, line in enumerate(new_lines):
            line_num = self.processed_line_count + line_offset
            try:
                entry = json.loads(line.strip())
                # Track git branch from transcript entries
                branch = entry.get('gitBranch', '')
                if branch:
                    self.server.current_branch = branch
                msg = entry.get('message', {})
                role = msg.get('role') or entry.get('role')

                if role == 'assistant':
                    # Skip synthetic messages (Claude Code internal, e.g. "No response requested")
                    if msg.get('model') == '<synthetic>':
                        continue
                    content = msg.get('content', entry.get('content', ''))

                    if isinstance(content, str) and content.strip():
                        all_blocks.append(TextBlock(type="text", text=content.strip()))
                    elif isinstance(content, list):
                        for block in content:
                            if isinstance(block, dict):
                                block_type = block.get('type')
                                try:
                                    if block_type == 'text':
                                        text = block.get('text', '').strip()
                                        if not text:
                                            continue
                                        all_blocks.append(TextBlock(type="text", text=text))
                                    elif block_type == 'thinking':
                                        all_blocks.append(ThinkingBlock(**block))
                                    elif block_type == 'tool_use':
                                        if block.get('name', '') in HIDDEN_TOOLS:
                                            self.hidden_tool_ids.add(block.get('id', ''))
                                            continue
                                        if block.get('name', '') == 'Agent':
                                            self.agent_tool_ids.add(block.get('id', ''))
                                        all_blocks.append(ToolUseBlock(**block))
                                except Exception:
                                    continue

                elif role == 'user':
                    content = msg.get('content', entry.get('content', ''))
                    if isinstance(content, list):
                        has_tool_result = any(
                            isinstance(b, dict) and b.get('type') == 'tool_result'
                            for b in content
                        )
                        if has_tool_result:
                            for block in content:
                                if isinstance(block, dict) and block.get('type') == 'tool_result':
                                    if block.get('tool_use_id', '') in self.hidden_tool_ids:
                                        continue
                                    try:
                                        raw_content = block.get('content', '')
                                        if isinstance(raw_content, str):
                                            content_str = raw_content
                                        elif isinstance(raw_content, list):
                                            content_str = '\n'.join(
                                                b.get('text', '') for b in raw_content
                                                if isinstance(b, dict) and b.get('type') == 'text'
                                            )
                                        else:
                                            content_str = str(raw_content)
                                        tool_use_id = block.get('tool_use_id', '')
                                        # Strip metadata from Agent tool results
                                        if tool_use_id in self.agent_tool_ids:
                                            content_str = _strip_agent_metadata(content_str)
                                        all_blocks.append(ToolResultBlock(
                                            type="tool_result",
                                            tool_use_id=tool_use_id,
                                            content=content_str,
                                            is_error=block.get('is_error', False)
                                        ))
                                    except Exception:
                                        continue
                        else:
                            # User text blocks (non-tool_result): interrupts, image refs, etc.
                            for block in content:
                                if isinstance(block, dict):
                                    if block.get('type') == 'text':
                                        text = block.get('text', '').strip()
                                        if not text:
                                            continue
                                        if text.startswith('Base directory for this skill:'):
                                            continue
                                        if text.startswith('<task-notification'):
                                            match = re.search(r'<tool-use-id>([^<]+)</tool-use-id>', text)
                                            if match:
                                                task_completed_ids.append(match.group(1))
                                            continue
                                        user_texts.append((rewrite_user_text(text), line_num))
                                    # Skip image blocks (base64 data) silently
                    elif isinstance(content, str) and content.strip():
                        stripped = content.strip()
                        if stripped.startswith('Base directory for this skill:'):
                            pass
                        elif stripped.startswith('<task-notification'):
                            match = re.search(r'<tool-use-id>([^<]+)</tool-use-id>', stripped)
                            if match:
                                task_completed_ids.append(match.group(1))
                        else:
                            user_texts.append((rewrite_user_text(stripped), line_num))

            except json.JSONDecodeError:
                continue

        self.processed_line_count = len(lines)

        if all_blocks:
            print(f"[DEBUG] Extracted {len(all_blocks)} blocks from {len(new_lines)} new lines")
        if user_texts:
            print(f"[DEBUG] Extracted {len(user_texts)} user texts from {len(new_lines)} new lines")
        if task_completed_ids:
            print(f"[DEBUG] Extracted {len(task_completed_ids)} task completions from {len(new_lines)} new lines")

        return all_blocks, user_texts, task_completed_ids

    def broadcast_context_update(self, filepath: str, session_id: str):
        """Calculate and broadcast context usage for the session."""
        context_data = self.context_tracker.calculate_context(filepath)
        context_data["type"] = "context_update"
        context_data["session_id"] = session_id

        asyncio.run_coroutine_threadsafe(
            self.server.broadcast_message(context_data),
            self.loop
        )

    def set_session_file(self, file_path: Optional[str], from_beginning: bool = False):
        """Set the expected session file and initialize line count.

        When switching sessions, we initialize the line count to the current
        number of lines in the file, so only NEW content triggers callbacks.
        For new sessions, use from_beginning=True to process all content.
        """
        with self._lock:
            self.expected_session_file = file_path
            self.hidden_tool_ids = set()  # Reset on session switch
            self.agent_tool_ids = set()
            if from_beginning:
                self.processed_line_count = 0
                print(f"[INFO] Watching session file: {file_path} (from beginning)")
            elif file_path and os.path.exists(file_path):
                with open(file_path, 'r') as f:
                    self.processed_line_count = sum(1 for _ in f)
                print(f"[INFO] Watching session file: {file_path} (starting at line {self.processed_line_count})")
            else:
                self.processed_line_count = 0
                print(f"[INFO] Watching session file: {file_path} (new file)")

    def reconcile(self):
        """Check for lines that watchdog missed and extract their content.

        Returns:
            (content_blocks, user_texts, task_completed_ids, start_line) — same as extract_new_content_with_seq
        """
        with self._lock:
            if not self.expected_session_file or not os.path.exists(self.expected_session_file):
                return [], [], [], 0
            return self.extract_new_content_with_seq(self.expected_session_file)

    def reset_tracking_state(self):
        """Reset tracking state (legacy - prefer set_session_file)"""
        with self._lock:
            self.processed_line_count = 0
            self.expected_session_file = None

class VoiceServer:
    """WebSocket server for iOS voice mode"""

    def __init__(self):
        self.clients = set()
        self.transcript_path = None
        self.observer = None
        self.transcript_handler = None
        self.loop = None
        self.waiting_for_response = False  # Track if we're waiting for a response to voice input
        self.last_voice_input = None  # Track the last voice input text
        self.last_content_blocks = []  # New: store for future reference
        self.session_manager = SessionManager()
        self.tmux = TmuxController()
        set_tmux_controller(self.tmux)  # Enable HTTP endpoints to access tmux
        set_voice_server(self)  # Enable HTTP endpoints to access server state
        self.permission_handler = PermissionHandler()
        self.usage_checker = UsageChecker()
        self.projects_base_path = PROJECTS_BASE_PATH
        self.active_session_id = None  # Track which session is active in tmux
        self.active_folder_name = None  # Track which project folder is active
        self._active_tmux_session = None  # Track current tmux session name
        self._pending_session_snapshot = None  # (folder_name, existing_ids) for deferred detection
        self.current_branch = ""  # Track git branch from transcript
        # Multi-session support
        self.active_sessions: dict[str, SessionContext] = {}  # tmux_session_name -> SessionContext
        self.viewed_session_id: Optional[str] = None  # Which session the iOS app is viewing
        self.tts_enabled = True  # TTS on by default, toggled via set_preference
        # TTS queue: serializes audio generation/streaming (created in start())
        self.tts_queue = None
        self.tts_cancel = None
        self.tts_active = False
        self._tts_worker_task = None
        # Pane polling for activity status
        self._pane_poll_task = None
        self._last_activity_state = None
        # Reconciliation loop for catching missed watchdog events
        self._reconciliation_task = None

    # --- Multi-session helpers ---

    def _get_viewed_context(self) -> Optional[SessionContext]:
        """Get the SessionContext for the currently viewed session."""
        if not self.viewed_session_id:
            return None
        for ctx in self.active_sessions.values():
            if ctx.session_id == self.viewed_session_id:
                return ctx
        return None

    def _get_context_by_session_id(self, session_id: str) -> Optional[SessionContext]:
        """Get SessionContext by Claude session ID."""
        for ctx in self.active_sessions.values():
            if ctx.session_id == session_id:
                return ctx
        return None

    def find_transcript_path(self):
        """Find the transcript file to watch.

        If E2E_TRANSCRIPT_PATH is set, use that exact path (for testing).
        Otherwise, find the most recent transcript file (normal operation).
        """
        # Check for explicit test transcript path
        explicit_path = os.environ.get('E2E_TRANSCRIPT_PATH')
        if explicit_path and os.path.exists(explicit_path):
            print(f"[E2E] Using explicit transcript path: {explicit_path}")
            return explicit_path

        # Normal operation: find most recent transcript
        pattern = os.path.join(TRANSCRIPT_DIR, "**/*.jsonl")
        files = glob.glob(pattern, recursive=True)
        if not files:
            return None
        files.sort(key=os.path.getmtime, reverse=True)
        return files[0]

    def get_session_transcript_path(self, folder_name: str, session_id: str) -> Optional[str]:
        """Get the transcript path for a specific session.

        Args:
            folder_name: The project folder name (e.g., "-Users-aaron-Desktop-max")
            session_id: The session ID (filename without .jsonl)

        Returns:
            Full path to the transcript file, or None if not found
        """
        transcript_path = os.path.join(TRANSCRIPT_DIR, folder_name, f"{session_id}.jsonl")
        if os.path.exists(transcript_path):
            return transcript_path
        return None

    def switch_watched_session(self, folder_name: str, session_id: str, from_beginning: bool = False) -> bool:
        """Switch the file watcher to watch a different session's transcript.

        Args:
            folder_name: The project folder name
            session_id: The session ID to watch

        Returns:
            True if switch was successful, False otherwise
        """
        new_path = self.get_session_transcript_path(folder_name, session_id)
        if not new_path:
            print(f"[WARN] Transcript not found for session {session_id}")
            return False

        new_dir = os.path.dirname(new_path)
        old_dir = os.path.dirname(self.transcript_path) if self.transcript_path else None

        # Update tracking state
        self.transcript_path = new_path
        self.active_folder_name = folder_name
        self.active_session_id = session_id

        # Set expected session file (initializes line count from existing content)
        if self.transcript_handler:
            self.transcript_handler.set_session_file(new_path, from_beginning=from_beginning)

        # Only reschedule observer if directory changed
        if old_dir != new_dir and self.observer and self.transcript_handler:
            # Remove all existing watches
            self.observer.unschedule_all()
            # Add new watch for the session's directory
            self.observer.schedule(self.transcript_handler, new_dir)
            print(f"[INFO] Switched file watcher to: {new_dir}")

        print(f"[INFO] Now watching session: {session_id}")

        # Send initial context update for the session
        if self.transcript_handler and new_path:
            self.transcript_handler.broadcast_context_update(new_path, session_id)

        # Start reconciliation loop if not already running
        if self._reconciliation_task is None or self._reconciliation_task.done():
            self._reconciliation_task = asyncio.ensure_future(self._reconciliation_loop())

        return True

    async def _reconciliation_loop(self):
        """Periodically check for lines watchdog missed and send them to clients."""
        last_watchdog_time = time.time()
        tick = 0
        while True:
            try:
                await asyncio.sleep(3.0)
                tick += 1
                if not self.active_session_id or not self.transcript_handler:
                    continue

                # Heartbeat every tick so we know the loop is alive
                file_lines = 0
                if self.transcript_handler.expected_session_file:
                    try:
                        with open(self.transcript_handler.expected_session_file) as f:
                            file_lines = sum(1 for _ in f)
                    except OSError:
                        pass
                processed = self.transcript_handler.processed_line_count
                if file_lines > processed or tick % 10 == 0:
                    print(f"[RECONCILE] tick={tick}, processed={processed}, "
                          f"file_lines={file_lines}, gap={file_lines - processed}")

                # Check if watchdog has been silent while file changed
                if self.transcript_handler.expected_session_file:
                    try:
                        file_mtime = os.path.getmtime(self.transcript_handler.expected_session_file)
                        if file_mtime > last_watchdog_time + 10:
                            print(f"[SYNC WARNING] No watchdog events for {time.time() - last_watchdog_time:.0f}s "
                                  f"but file mtime is newer")
                    except OSError:
                        pass

                new_blocks, user_texts, task_completed_ids, start_line = self.transcript_handler.reconcile()

                if new_blocks:
                    print(f"[RECONCILE] Found {len(new_blocks)} missed blocks (seq={start_line})")
                    response = AssistantResponse(
                        content_blocks=new_blocks,
                        timestamp=time.time(),
                        is_incremental=True
                    )
                    await self.handle_content_response(response, seq=start_line)

                    if not self.tts_enabled:
                        await self.send_idle_to_all_clients()

                if user_texts:
                    print(f"[RECONCILE] Found {len(user_texts)} missed user messages")
                    for text, line_num in user_texts:
                        await self.handle_user_message(text, seq=line_num)

                if task_completed_ids:
                    print(f"[RECONCILE] Found {len(task_completed_ids)} missed task completions")
                    for tool_id in task_completed_ids:
                        await self.broadcast_task_completed(tool_id)

                last_watchdog_time = time.time()

            except asyncio.CancelledError:
                return
            except Exception as e:
                print(f"[RECONCILE ERROR] {e}")
                import traceback
                traceback.print_exc()

    async def send_status(self, websocket, state, message):
        """Send status update to client"""
        await websocket.send(json.dumps({
            "type": "status",
            "state": state,
            "message": message,
            "timestamp": time.time()
        }))

    def _get_current_branch(self) -> str:
        """Get current git branch for the active session's working directory."""
        try:
            if self.active_session_id and self.active_folder_name:
                cwd = self.session_manager.get_session_cwd(
                    self.active_folder_name, self.active_session_id
                )
                if cwd:
                    result = subprocess.run(
                        ["git", "branch", "--show-current"],
                        cwd=cwd,
                        capture_output=True,
                        text=True,
                        timeout=2
                    )
                    if result.returncode == 0:
                        return result.stdout.strip()
        except Exception as e:
            print(f"[DEBUG] _get_current_branch error: {e}")
        return ""

    async def send_connection_status(self, websocket):
        """Send connection status to a single client"""
        active_session_ids = [
            ctx.session_id for ctx in self.active_sessions.values()
            if ctx.session_id and self.tmux.session_exists(ctx.tmux_session_name)
        ]
        response = {
            "type": "connection_status",
            "connected": bool(self._active_tmux_session and self.tmux.session_exists(self._active_tmux_session)),
            "active_session_id": self.active_session_id,
            "active_session_ids": active_session_ids,
            "branch": self._get_current_branch()
        }
        await websocket.send(json.dumps(response))

    async def broadcast_connection_status(self):
        """Broadcast connection status to all connected clients"""
        for websocket in list(self.clients):
            try:
                await self.send_connection_status(websocket)
            except Exception as e:
                print(f"Error broadcasting status: {e}")

    async def send_to_terminal(self, text: str):
        """Send text to Claude Code terminal via tmux"""
        print(f"[DEBUG] send_to_terminal: tmux_session={self._active_tmux_session}")
        if not self._active_tmux_session:
            print("[DEBUG] send_to_terminal: no active tmux session")
            return
        result = self.tmux.send_input(self._active_tmux_session, text)
        print(f"[DEBUG] send_input returned: {result}")

        # If we have a pending snapshot, resolve it now that Claude has input
        await self._resolve_pending_session()

    async def _resolve_pending_session(self):
        """Detect new session file using saved snapshot, if pending."""
        if not self._pending_session_snapshot:
            return
        folder_name, existing_ids = self._pending_session_snapshot
        self._pending_session_snapshot = None
        session_id = await poll_for_session_file(
            find_fn=lambda: self.session_manager.find_new_session(folder_name, existing_ids),
            timeout=10.0,
            interval=0.3
        )
        if session_id:
            print(f"[DEBUG] Deferred detection found new session: {session_id}")
            self.active_session_id = session_id
            self.viewed_session_id = session_id

            # Update the SessionContext with the real session ID
            if self._active_tmux_session and self._active_tmux_session in self.active_sessions:
                ctx = self.active_sessions[self._active_tmux_session]
                ctx.session_id = session_id
                ctx.pending_session_snapshot = None

            self.switch_watched_session(folder_name, session_id, from_beginning=True)

            # Broadcast so iOS knows the session ID
            await self.broadcast_connection_status()
            await self.broadcast_message({
                "type": "session_created",
                "success": True,
                "session_id": session_id
            })
        else:
            print(f"[WARN] Deferred detection timed out for new session file")

    async def verify_delivery(self, text: str, timeout: float = 5.0) -> bool:
        """Poll transcript file to verify a user message was written by Claude Code.

        Returns True if a user-role line containing `text` appears within timeout.
        """
        if not self.transcript_handler or not self.transcript_handler.expected_session_file:
            return False

        filepath = self.transcript_handler.expected_session_file
        start_line = self.transcript_handler.processed_line_count
        deadline = time.time() + timeout
        poll_interval = 0.5

        while time.time() < deadline:
            try:
                with open(filepath, 'r') as f:
                    lines = f.readlines()

                for line in lines[start_line:]:
                    try:
                        entry = json.loads(line.strip())
                        msg = entry.get('message', {})
                        role = msg.get('role') or entry.get('role')
                        if role == 'user':
                            content = msg.get('content', '')
                            if isinstance(content, str) and text in content:
                                return True
                            elif isinstance(content, list):
                                for block in content:
                                    if isinstance(block, dict) and text in block.get('text', ''):
                                        return True
                    except (json.JSONDecodeError, KeyError):
                        continue
            except FileNotFoundError:
                pass

            await asyncio.sleep(poll_interval)

        return False

    async def stream_audio(self, websocket, wav_bytes, cancel_event):
        """Stream pre-generated WAV audio to client. Returns False if cancelled."""
        try:
            chunk_size = 8192
            total_chunks = (len(wav_bytes) + chunk_size - 1) // chunk_size
            print(f"Streaming {total_chunks} audio chunks...")

            for i in range(0, len(wav_bytes), chunk_size):
                if cancel_event.is_set():
                    print(f"[TTS] Streaming cancelled at chunk {i // chunk_size}/{total_chunks}")
                    return False

                chunk = wav_bytes[i:i+chunk_size]
                await websocket.send(json.dumps({
                    "type": "audio_chunk",
                    "format": "wav",
                    "sample_rate": 24000,
                    "chunk_index": i // chunk_size,
                    "total_chunks": total_chunks,
                    "data": base64.b64encode(chunk).decode('utf-8')
                }))
                await asyncio.sleep(0.01)

            print(f"Finished streaming {total_chunks} chunks")
            return True

        except Exception as e:
            print(f"Error streaming audio: {e}")
            import traceback
            traceback.print_exc()
            return False

    async def handle_voice_input(self, websocket, data):
        """Handle voice input from iOS"""
        text = data.get('text', '').strip()
        print(f"[{time.strftime('%H:%M:%S')}] Voice input received: '{text}'")
        if text:
            # CRITICAL: Set state FIRST, before any async calls that might fail
            # (e.g., test WebSocket may close immediately after sending)
            # NOTE: Don't reset transcript tracking here - line-based tracking
            # should persist across voice inputs. File-change detection handles
            # resetting when switching to a different transcript file.
            self.waiting_for_response = True
            self.last_voice_input = text
            # Also set on the viewed SessionContext
            ctx = self._get_viewed_context()
            if ctx:
                ctx.waiting_for_response = True
                ctx.last_voice_input = text

            print(f"[{time.strftime('%H:%M:%S')}] Sending to terminal...")
            for client in list(self.clients):
                try:
                    await self.send_status(client, "processing", "Sending to Claude...")
                except Exception:
                    pass

            await self.send_to_terminal(text)
            print(f"[{time.strftime('%H:%M:%S')}] Sent to terminal successfully")

            # Verify delivery — check if message appears in transcript
            delivered = await self.verify_delivery(text)
            delivery_msg = {
                "type": "delivery_status",
                "status": "confirmed" if delivered else "failed",
                "text": text
            }
            for client in list(self.clients):
                try:
                    await client.send(json.dumps(delivery_msg))
                except Exception:
                    pass

            if not delivered:
                print(f"[SYNC WARNING] Message delivery not confirmed: '{text[:50]}'")
        else:
            print("Empty text received, ignoring")

    async def handle_content_response(self, response: AssistantResponse, seq: int = 0):
        """Send structured content to iOS clients"""
        print(f"[{time.strftime('%H:%M:%S')}] Sending structured content: {len(response.content_blocks)} blocks (seq={seq})")

        # Serialize using Pydantic and add session tracking
        message = response.model_dump()
        message["session_id"] = self.active_session_id  # Include session for filtering
        message["seq"] = seq
        if self.current_branch:
            message["branch"] = self.current_branch

        for websocket in list(self.clients):
            try:
                await websocket.send(json.dumps(message))
                print(f"[{time.strftime('%H:%M:%S')}] Sent content to client (session: {self.active_session_id})")
            except Exception as e:
                print(f"Error sending content: {e}")


    async def handle_user_message(self, text: str, seq: int = 0):
        """Send user text message to iOS clients (for terminal-typed input)"""
        # Skip echo of messages we sent from the app (voice_input or user_input)
        # Use startswith because user_input appends [Image: /path] to the text
        if self.last_voice_input is not None:
            if self.last_voice_input == "" and text.startswith("[Image:"):
                # Image-only send: text was empty, server prompt is just [Image: ...]
                self.last_voice_input = None
                return
            elif self.last_voice_input and text.startswith(self.last_voice_input):
                self.last_voice_input = None
                return

        message = {
            "type": "user_message",
            "role": "user",
            "content": text,
            "timestamp": time.time(),
            "session_id": self.active_session_id,
            "seq": seq,
        }
        if self.current_branch:
            message["branch"] = self.current_branch

        for websocket in list(self.clients):
            try:
                await websocket.send(json.dumps(message))
            except Exception as e:
                print(f"Error sending user message: {e}")

    async def handle_resync(self, websocket, data):
        """Handle resync request — replay content from a given sequence number.

        The client sends from_seq (a transcript line number). We re-read the
        transcript from that line forward and send the content as a resync_response.
        """
        from_seq = data.get("from_seq", 0)
        print(f"[RESYNC] Client requested resync from seq {from_seq}")

        if not self.transcript_path or not os.path.exists(self.transcript_path):
            await websocket.send(json.dumps({
                "type": "resync_response",
                "from_seq": from_seq,
                "messages": []
            }))
            return

        messages = []
        with open(self.transcript_path, 'r') as f:
            lines = f.readlines()

        for line_num, line in enumerate(lines):
            if line_num < from_seq:
                continue
            try:
                entry = json.loads(line.strip())
                msg = entry.get('message', {})
                role = msg.get('role') or entry.get('role')
                content = msg.get('content', entry.get('content', ''))

                messages.append({
                    "seq": line_num,
                    "role": role,
                    "content": content,
                    "timestamp": entry.get('timestamp', 0)
                })
            except json.JSONDecodeError:
                continue

        await websocket.send(json.dumps({
            "type": "resync_response",
            "from_seq": from_seq,
            "messages": messages
        }))
        print(f"[RESYNC] Sent {len(messages)} messages from seq {from_seq}")

    async def handle_set_preference(self, data):
        """Handle preference changes from iOS app"""
        if 'tts_enabled' in data:
            self.tts_enabled = data['tts_enabled']
            print(f"[Preference] TTS enabled: {self.tts_enabled}")

    async def handle_user_input(self, websocket, data):
        """Handle text + optional image input from iOS"""
        text = data.get('text', '').strip()
        images = data.get('images', [])

        if not text and not images:
            print("Empty user_input received, ignoring")
            return

        # Save images to temp files and build prompt
        image_paths = []
        for img in images:
            try:
                import uuid
                img_data = base64.b64decode(img['data'])
                ext = os.path.splitext(img.get('filename', 'image.jpg'))[1] or '.jpg'
                filename = f"claude_voice_img_{uuid.uuid4().hex[:12]}{ext}"
                filepath = os.path.join('/tmp', filename)
                with open(filepath, 'wb') as f:
                    f.write(img_data)
                image_paths.append(filepath)
                print(f"[UserInput] Saved image: {filepath} ({len(img_data)} bytes)")
            except Exception as e:
                print(f"[UserInput] Failed to save image: {e}")

        # Build prompt with image references
        prompt = text
        for path in image_paths:
            prompt += f"\n[Image: {path}]"

        print(f"[{time.strftime('%H:%M:%S')}] User input: '{prompt[:100]}'")

        self.waiting_for_response = True
        self.last_voice_input = text  # Track for echo dedup

        for client in list(self.clients):
            try:
                await self.send_status(client, "processing", "Sending to Claude...")
            except Exception:
                pass

        await self.send_to_terminal(prompt)

    async def handle_claude_response(self, text):
        """Handle Claude's response - queue text for TTS.

        If TTS is currently active (generating or streaming), cancel it
        so the worker can pick up this new message promptly.
        """
        if not self.tts_enabled:
            print(f"[{time.strftime('%H:%M:%S')}] TTS disabled, skipping audio for: '{text[:50]}...'")
            for client in list(self.clients):
                try:
                    await self.send_status(client, "idle", "Ready")
                except Exception:
                    pass
            return

        print(f"[{time.strftime('%H:%M:%S')}] Claude response queued for TTS: '{text[:100]}...'")
        if self.tts_active:
            print(f"[TTS] Interrupting active TTS for new message")
            self.tts_cancel.set()
            await self._send_stop_audio()
        await self.tts_queue.put(text)

    async def _tts_worker(self):
        """Background worker that processes TTS requests one at a time.

        Drains the queue to keep only the latest message.
        Cancels in-progress TTS when new messages arrive.
        """
        while True:
            try:
                # Wait for a TTS request
                text = await self.tts_queue.get()

                # Drain queue — keep only the latest
                while not self.tts_queue.empty():
                    try:
                        text = self.tts_queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break

                # Reset cancel event and mark active
                self.tts_cancel.clear()
                self.tts_active = True

                try:
                    # Generate TTS in executor (blocking call)
                    print(f"[TTS] Generating audio for: '{text[:50]}...'")
                    loop = asyncio.get_running_loop()
                    samples = await loop.run_in_executor(
                        None, lambda: generate_tts_audio(text, voice="af_heart")
                    )

                    # Check for cancellation after generation
                    if self.tts_cancel.is_set():
                        print(f"[TTS] Cancelled after generation")
                        continue

                    wav_bytes = samples_to_wav_bytes(samples)

                    # Stream to all clients
                    for websocket in list(self.clients):
                        await self.send_status(websocket, "speaking", "Playing response")
                        completed = await self.stream_audio(websocket, wav_bytes, self.tts_cancel)
                        if completed:
                            await self.send_status(websocket, "idle", "Ready")

                finally:
                    self.tts_active = False

            except asyncio.CancelledError:
                self.tts_active = False
                raise
            except Exception as e:
                self.tts_active = False
                print(f"[TTS] Worker error: {e}")
                import traceback
                traceback.print_exc()

    async def cancel_tts(self):
        """Cancel any active or queued TTS and tell clients to stop audio."""
        if self.tts_cancel:
            self.tts_cancel.set()
        if self.tts_queue:
            while not self.tts_queue.empty():
                try:
                    self.tts_queue.get_nowait()
                except asyncio.QueueEmpty:
                    break
        await self._send_stop_audio()

    async def _send_stop_audio(self):
        """Send stop_audio message to all connected clients."""
        message = json.dumps({"type": "stop_audio"})
        for websocket in list(self.clients):
            try:
                await websocket.send(message)
            except Exception:
                pass

    async def send_idle_to_all_clients(self):
        """Send idle status to all connected clients.

        Called when content is sent but there's no TTS audio (e.g., only thinking blocks).
        This ensures the client's outputState is reset even without audio playback.
        """
        for websocket in list(self.clients):
            try:
                print(f"[{time.strftime('%H:%M:%S')}] Sending idle status (no TTS)")
                await self.send_status(websocket, "idle", "Ready")
            except Exception:
                pass  # Client may have disconnected, that's OK

    async def broadcast_task_completed(self, tool_use_id: str):
        """Notify iOS that a background task has completed."""
        message = {
            "type": "task_completed",
            "tool_use_id": tool_use_id,
        }
        print(f"[TASK] Broadcasting task_completed for tool_use_id={tool_use_id}")
        await self.broadcast_message(message)

    async def broadcast_message(self, message: dict):
        """Broadcast a JSON message to all connected clients."""
        message_json = json.dumps(message)
        for websocket in list(self.clients):
            try:
                await websocket.send(message_json)
            except Exception:
                pass

    async def _pane_poll_loop(self):
        """Poll tmux panes for all active sessions, broadcast on change."""
        from voice_server.pane_parser import parse_pane_status
        try:
            while True:
                for tmux_name, ctx in list(self.active_sessions.items()):
                    if not self.tmux.session_exists(tmux_name):
                        continue
                    pane_text = self.tmux.capture_pane(tmux_name, include_history=False)
                    state = parse_pane_status(pane_text)

                    if ctx.last_activity_state is None or \
                       state.state != ctx.last_activity_state.state or \
                       state.detail != ctx.last_activity_state.detail:
                        ctx.last_activity_state = state
                        # Only broadcast activity for the viewed session
                        if ctx.session_id == self.viewed_session_id:
                            await self.broadcast_message({
                                "type": "activity_status",
                                "state": state.state,
                                "detail": state.detail
                            })

                # Fallback: also poll the single active session if no multi-session contexts
                if not self.active_sessions and self._active_tmux_session and self.tmux.session_exists(self._active_tmux_session):
                    pane_text = self.tmux.capture_pane(self._active_tmux_session, include_history=False)
                    state = parse_pane_status(pane_text)
                    if self._last_activity_state is None or \
                       state.state != self._last_activity_state.state or \
                       state.detail != self._last_activity_state.detail:
                        self._last_activity_state = state
                        await self.broadcast_message({
                            "type": "activity_status",
                            "state": state.state,
                            "detail": state.detail
                        })

                await asyncio.sleep(1.0)
        except asyncio.CancelledError:
            pass

    async def handle_interrupt(self):
        """Handle interrupt request from iOS - send Escape to tmux"""
        if self._active_tmux_session and self.tmux.session_exists(self._active_tmux_session):
            self.tmux.send_escape(self._active_tmux_session)
            print(f"[{time.strftime('%H:%M:%S')}] Sent interrupt (Escape) to {self._active_tmux_session}")

    async def handle_list_projects(self, websocket):
        """Handle list_projects request"""
        projects = self.session_manager.list_projects()
        response = {
            "type": "projects",
            "projects": [
                {
                    "path": p.path,
                    "name": p.name,
                    "session_count": p.session_count,
                    "folder_name": p.folder_name  # For direct lookup without re-encoding
                }
                for p in projects
            ]
        }
        await websocket.send(json.dumps(response))

    async def handle_list_sessions(self, websocket, data):
        """Handle list_sessions request"""
        folder_name = data.get("folder_name", "")
        sessions = self.session_manager.list_sessions(folder_name)

        active_ids = [
            ctx.session_id for ctx in self.active_sessions.values()
            if ctx.session_id and ctx.folder_name == folder_name
        ]

        response = {
            "type": "sessions",
            "sessions": [
                {
                    "id": s.id,
                    "title": s.title,
                    "timestamp": s.timestamp,
                    "message_count": s.message_count,
                }
                for s in sessions
            ],
            "active_session_ids": active_ids
        }
        await websocket.send(json.dumps(response))

    async def handle_get_session(self, websocket, data):
        """Handle get_session request"""
        folder_name = data.get("folder_name", "")
        session_id = data.get("session_id", "")
        messages = self.session_manager.get_session_history(folder_name, session_id)

        # Include transcript line count so iOS can initialize seq tracking
        line_count = 0
        transcript_path = self.get_session_transcript_path(folder_name, session_id)
        if transcript_path and os.path.exists(transcript_path):
            with open(transcript_path, 'r') as f:
                line_count = sum(1 for _ in f)

        response = {
            "type": "session_history",
            "line_count": line_count,
            "messages": [
                {
                    "role": m.role,
                    "content": m.content,
                    "timestamp": m.timestamp,
                    **({"content_blocks": m.content_blocks} if m.content_blocks else {})
                }
                for m in messages
            ]
        }
        await websocket.send(json.dumps(response))

    async def handle_stop_session(self, websocket, data):
        """Handle stop_session request - kills one session's tmux"""
        session_id = data.get("session_id", "")
        if session_id and session_id == self.viewed_session_id:
            await self.cancel_tts()
        ctx = self._get_context_by_session_id(session_id) if session_id else None

        # Also try by tmux session name if no context found by session_id
        if not ctx and self._active_tmux_session:
            ctx = self.active_sessions.get(self._active_tmux_session)

        success = False
        if ctx:
            ctx.cleanup()
            success = self.tmux.kill_session(ctx.tmux_session_name)
            self.active_sessions.pop(ctx.tmux_session_name, None)
            self.permission_handler.cleanup_session(session_id)
            if self._active_tmux_session == ctx.tmux_session_name:
                self._active_tmux_session = None
                self.active_session_id = None
            if self.viewed_session_id == session_id:
                self.viewed_session_id = None

        # Also kill legacy single session if it matches
        elif self._active_tmux_session:
            success = self.tmux.kill_session(self._active_tmux_session)
            self._active_tmux_session = None
            self.active_session_id = None

        await websocket.send(json.dumps({
            "type": "session_stopped",
            "success": success,
            "session_id": session_id
        }))
        await self.broadcast_connection_status()

    async def handle_view_session(self, websocket, data):
        """Handle view_session request - switch which session the app is viewing"""
        session_id = data.get("session_id", "")
        ctx = self._get_context_by_session_id(session_id)
        if ctx:
            await self.cancel_tts()
            self.viewed_session_id = session_id
            self._active_tmux_session = ctx.tmux_session_name
            self.active_session_id = session_id
            self.switch_watched_session(ctx.folder_name, session_id)
            print(f"[INFO] Viewing session: {session_id}")
            await self.broadcast_connection_status()
            # Immediately send this session's current activity state
            # so the iOS app doesn't show stale state from the previous session
            state = ctx.last_activity_state
            await self.broadcast_message({
                "type": "activity_status",
                "state": state.state if state else "idle",
                "detail": state.detail if state else ""
            })

    def _reset_session_state(self):
        """Reset all session-related state.

        Called at the start of handle_new_session and handle_resume_session
        to ensure clean state before starting a new session lifecycle.
        """
        # Stop reconciliation loop
        if self._reconciliation_task and not self._reconciliation_task.done():
            self._reconciliation_task.cancel()
            self._reconciliation_task = None

        # Reset session tracking
        self.active_session_id = None
        self.active_folder_name = None
        self._active_tmux_session = None
        self._pending_session_snapshot = None
        self.current_branch = ""
        self.transcript_path = None

        # Reset transcript handler
        if self.transcript_handler:
            self.transcript_handler.reset_tracking_state()
            self.transcript_handler.expected_session_file = None

        # Unschedule file watcher
        if self.observer:
            self.observer.unschedule_all()

        # NOTE: Do NOT clear permission_handler state here.
        # Permissions are global (shared across sessions). Clearing them
        # would wipe pending permissions for other active sessions.

    async def poll_claude_ready(self, tmux_name: str = None, timeout: float = 15.0, interval: float = 0.3) -> bool:
        """Poll tmux pane until Claude Code is loaded and ready.

        Returns True if Claude becomes ready within timeout, False otherwise.
        """
        from voice_server.pane_parser import is_claude_ready

        tmux_name = tmux_name or self._active_tmux_session
        if not tmux_name:
            return False

        elapsed = 0.0
        while elapsed < timeout:
            pane_text = self.tmux.capture_pane(tmux_name, include_history=False)
            if is_claude_ready(pane_text):
                print(f"[INFO] Claude ready after {elapsed:.1f}s")
                return True
            await asyncio.sleep(interval)
            elapsed += interval

        print(f"[WARN] Claude not ready after {timeout}s timeout")
        return False

    def reset_state(self):
        """Reset all server state for test isolation

        Called by /reset HTTP endpoint to ensure clean state between E2E tests.
        """
        # Kill all active sessions
        for ctx in list(self.active_sessions.values()):
            ctx.cleanup()
            self.tmux.kill_session(ctx.tmux_session_name)
        self.active_sessions.clear()
        self.viewed_session_id = None
        # Also kill the legacy single-session if present
        if self._active_tmux_session:
            self.tmux.kill_session(self._active_tmux_session)
        self._reset_session_state()
        self.permission_handler.clear_all()
        print("[RESET] Server state cleared for test isolation")

    async def handle_new_session(self, websocket, data):
        """Handle new_session request - starts claude in tmux"""
        project_path = data.get("project_path", "")
        print(f"[DEBUG] handle_new_session: project_path={project_path}")

        # Check session limit
        if len(self.active_sessions) >= MAX_ACTIVE_SESSIONS:
            await websocket.send(json.dumps({
                "type": "session_created",
                "success": False,
                "error": f"Maximum {MAX_ACTIVE_SESSIONS} active sessions reached"
            }))
            return

        # Full state reset before anything else
        self._reset_session_state()

        # Snapshot existing session IDs BEFORE starting Claude
        existing_ids = set()
        folder_name = None
        if project_path:
            folder_name = self.session_manager.encode_path_to_folder(project_path)
            existing_ids = self.session_manager.list_session_ids(folder_name)
            print(f"[DEBUG] Snapshot: {len(existing_ids)} existing sessions in {folder_name}")

        import uuid
        temp_id = f"pending-{uuid.uuid4().hex[:8]}"
        tmux_name = session_name_for(temp_id)

        success = self.tmux.start_session(
            tmux_name,
            working_dir=project_path if project_path else None,
            env={"CLAUDE_CONNECT_SESSION_ID": temp_id}
        )
        print(f"[DEBUG] start_session returned: {success}, tmux_name: {tmux_name}")

        error = None
        if success:
            self._active_tmux_session = tmux_name
            # Verify Claude actually started and is ready for input
            ready = await self.poll_claude_ready(tmux_name)
            if ready:
                self.active_session_id = None  # New session has no ID yet

                # Create SessionContext and add to active_sessions
                ctx = SessionContext(
                    session_id=None,
                    folder_name=folder_name or "",
                    tmux_session_name=tmux_name,
                )

                # Save snapshot for deferred detection on first voice input
                if folder_name:
                    self._pending_session_snapshot = (folder_name, existing_ids)
                    ctx.pending_session_snapshot = (folder_name, existing_ids)
                    self.active_folder_name = folder_name
                    print(f"[INFO] Session snapshot saved, will detect new file on first voice input")

                self.active_sessions[tmux_name] = ctx
                self.viewed_session_id = None  # Will be set once session ID is detected
                print(f"[INFO] New session started: tmux={tmux_name}")
            else:
                # Claude didn't start — clean up
                self.tmux.kill_session(tmux_name)
                self._active_tmux_session = None
                success = False
                error = "Claude failed to start"
                print(f"[ERROR] Claude not ready after timeout, killed tmux session")

        response = {
            "type": "session_created",
            "success": success
        }
        if error:
            response["error"] = error
        await websocket.send(json.dumps(response))

        if success:
            await self.broadcast_connection_status()

    async def handle_resume_session(self, websocket, data):
        """Handle resume_session request - runs 'claude --resume <id>' in tmux"""
        session_id = data.get("session_id", "")
        folder_name = data.get("folder_name", "")

        # Check if this session is already active — just switch view
        existing_ctx = self._get_context_by_session_id(session_id)
        if existing_ctx:
            self.viewed_session_id = session_id
            self._active_tmux_session = existing_ctx.tmux_session_name
            self.active_session_id = session_id
            if folder_name:
                self.active_folder_name = folder_name
                self.switch_watched_session(folder_name, session_id)
            await websocket.send(json.dumps({
                "type": "session_resumed",
                "success": True,
                "session_id": session_id
            }))
            await self.broadcast_connection_status()
            return

        # Check session limit
        if len(self.active_sessions) >= MAX_ACTIVE_SESSIONS:
            await websocket.send(json.dumps({
                "type": "session_resumed",
                "success": False,
                "session_id": session_id,
                "error": f"Maximum {MAX_ACTIVE_SESSIONS} active sessions reached"
            }))
            return

        # Full state reset before anything else
        self._reset_session_state()

        success = False
        error = None

        if session_id:
            # Get the actual cwd from the session file
            working_dir = None
            if folder_name and session_id:
                working_dir = self.session_manager.get_session_cwd(folder_name, session_id)
                print(f"[DEBUG] handle_resume_session: get_session_cwd -> {working_dir}")

            tmux_name = session_name_for(session_id)
            success = self.tmux.start_session(
                tmux_name, working_dir=working_dir, resume_id=session_id,
                env={"CLAUDE_CONNECT_SESSION_ID": session_id}
            )
            print(f"[DEBUG] start_session(resume_id={session_id}) returned: {success}")

            if success:
                self._active_tmux_session = tmux_name
                # Verify Claude actually started
                ready = await self.poll_claude_ready(tmux_name)
                if ready:
                    self.active_session_id = session_id

                    # Create SessionContext and add to active_sessions
                    ctx = SessionContext(
                        session_id=session_id,
                        folder_name=folder_name,
                        tmux_session_name=tmux_name,
                    )
                    self.active_sessions[tmux_name] = ctx
                    self.viewed_session_id = session_id

                    if folder_name:
                        self.switch_watched_session(folder_name, session_id)

                    print(f"[INFO] Resumed session: {session_id}, tmux={tmux_name}")
                else:
                    self.tmux.kill_session(tmux_name)
                    self._active_tmux_session = None
                    success = False
                    error = "Claude failed to start"
                    print(f"[ERROR] Claude not ready after timeout, killed tmux session")
            else:
                error = "Failed to start tmux session"
                print(f"[ERROR] Failed to start tmux session for resume_id={session_id}")

        response = {
            "type": "session_resumed",
            "success": success,
            "session_id": session_id
        }
        if error:
            response["error"] = error
        await websocket.send(json.dumps(response))

        if success:
            await self.broadcast_connection_status()

    async def handle_list_directory(self, websocket, data):
        """Handle list_directory request - returns files and folders in a directory"""
        path = data.get("path", "")

        if not path or not os.path.isdir(path):
            response = {
                "type": "directory_listing",
                "path": path,
                "entries": [],
                "error": "invalid_path"
            }
            await websocket.send(json.dumps(response))
            return

        try:
            entries = []
            for name in os.listdir(path):
                full_path = os.path.join(path, name)
                entry_type = "directory" if os.path.isdir(full_path) else "file"
                entries.append({"name": name, "type": entry_type})

            # Sort: directories first, then files, both alphabetical
            entries.sort(key=lambda e: (0 if e["type"] == "directory" else 1, e["name"].lower()))

            response = {
                "type": "directory_listing",
                "path": path,
                "entries": entries
            }
        except PermissionError:
            response = {
                "type": "directory_listing",
                "path": path,
                "entries": [],
                "error": "permission_denied"
            }

        await websocket.send(json.dumps(response))

    async def handle_read_file(self, websocket, data):
        """Handle read_file request - returns file contents as text, or base64 for images"""
        path = data.get("path", "")

        if not path or not os.path.isfile(path):
            response = {
                "type": "file_contents",
                "path": path,
                "error": "not_found"
            }
            await websocket.send(json.dumps(response))
            return

        ext = os.path.splitext(path)[1].lower()

        # Image files: base64-encode (except SVG which is text)
        if ext in IMAGE_EXTENSIONS:
            file_size = os.path.getsize(path)
            if file_size > MAX_IMAGE_SIZE:
                response = {
                    "type": "file_contents",
                    "path": path,
                    "error": "file_too_large",
                    "file_size": file_size
                }
            else:
                with open(path, 'rb') as f:
                    image_bytes = f.read()
                response = {
                    "type": "file_contents",
                    "path": path,
                    "image_data": base64.b64encode(image_bytes).decode('utf-8'),
                    "image_format": ext.lstrip('.'),
                    "file_size": file_size
                }
            await websocket.send(json.dumps(response))
            return

        # Text files: read as UTF-8
        try:
            with open(path, 'r', encoding='utf-8') as f:
                contents = f.read()

            response = {
                "type": "file_contents",
                "path": path,
                "contents": contents
            }
        except UnicodeDecodeError:
            response = {
                "type": "file_contents",
                "path": path,
                "error": "binary_file"
            }
        except PermissionError:
            response = {
                "type": "file_contents",
                "path": path,
                "error": "permission_denied"
            }

        await websocket.send(json.dumps(response))

    async def handle_add_project(self, websocket, data):
        """Handle add_project request - creates directory and starts Claude"""
        name = data.get("name", "").strip()
        success = False
        project_path = ""

        if not name:
            response = {
                "type": "project_created",
                "success": False,
                "error": "Project name is required"
            }
            await websocket.send(json.dumps(response))
            return

        safe_name = "".join(c for c in name if c.isalnum() or c in "-_. ")
        project_path = os.path.join(self.projects_base_path, safe_name)

        try:
            os.makedirs(project_path, exist_ok=True)
            import uuid
            temp_id = f"pending-{uuid.uuid4().hex[:8]}"
            tmux_name = session_name_for(temp_id)
            success = self.tmux.start_session(tmux_name, working_dir=project_path)

            if success:
                self._active_tmux_session = tmux_name
                # Wait for Claude to initialize by polling for transcript
                folder_name = self.session_manager.encode_path_to_folder(project_path)
                await poll_for_session_file(
                    find_fn=lambda: self.session_manager.find_newest_session(folder_name),
                    timeout=10.0,
                    interval=0.2
                )
                # Send Enter to accept any prompts
                self.tmux.send_input(tmux_name, "")

        except Exception as e:
            print(f"Error creating project: {e}")

        response = {
            "type": "project_created",
            "success": success,
            "path": project_path,
            "name": safe_name
        }
        await websocket.send(json.dumps(response))

    async def handle_permission_response(self, data):
        """Handle permission response from iOS"""
        request_id = data.get('request_id', '')
        decision = data.get('decision', 'deny')
        print(f"[PERM] Received permission_response: id={request_id}, decision={decision}")

        is_pending = self.permission_handler.is_request_pending(request_id)
        is_timed_out = self.permission_handler.is_request_timed_out(request_id)
        print(f"[PERM] Request state: pending={is_pending}, timed_out={is_timed_out}, "
              f"all_pending={list(self.permission_handler.pending_permissions.keys())}")

        if is_pending:
            # Normal flow - resolve the waiting hook
            self.permission_handler.resolve_request(request_id, {
                "decision": decision,
                "input": data.get('input'),
                "selected_option": data.get('selected_option'),
                "updated_permissions": data.get('updated_permissions')
            })
            print(f"[PERM] Resolved request {request_id}")
            # Notify iOS that the permission was resolved
            await self.permission_handler.broadcast({
                "type": "permission_resolved",
                "request_id": request_id,
                "answered_in": "ios"
            })
        elif is_timed_out:
            # Late response - inject into terminal
            print(f"[PERM] Late response for timed-out request {request_id}")
            await self.inject_terminal_response(decision, data)
        else:
            print(f"[PERM] WARNING: Request {request_id} is neither pending nor timed out — response dropped")

    async def handle_question_response(self, data):
        """Handle question response from iOS"""
        request_id = data.get('request_id', '')
        answer = data.get('answer', '')
        dismissed = data.get('dismissed', False)
        print(f"[QUESTION] Received question_response: id={request_id}, dismissed={dismissed}, answer={answer[:60] if answer else ''}")

        if self.permission_handler.is_request_pending(request_id):
            if dismissed:
                self.permission_handler.resolve_request(request_id, {"dismissed": True})
            else:
                self.permission_handler.resolve_request(request_id, {"answer": answer})
            print(f"[QUESTION] Resolved request {request_id}")
        else:
            print(f"[QUESTION] No pending request for {request_id}")

    async def inject_terminal_response(self, decision, data):
        """Inject permission response into terminal after timeout"""
        if decision == "allow":
            text = data.get('input', 'y')
        else:
            text = 'n'

        if self._active_tmux_session:
            self.tmux.send_input(self._active_tmux_session, text)
            print(f"Injected late response: {text}")

    async def handle_usage_request(self, websocket):
        """Handle usage_request - send cached immediately, then fetch fresh."""
        # Send cached immediately if available
        cached = self.usage_checker.get_cached()
        if cached:
            await websocket.send(json.dumps(cached))

        # Fetch fresh
        fresh = await self.usage_checker.check_usage()
        await websocket.send(json.dumps(fresh))

    async def handle_message(self, websocket, message):
        """Handle incoming message with state validation"""
        try:
            data = json.loads(message)
            msg_type = data.get('type')
            print(f"[DISPATCH] msg_type={msg_type}")

            # Validate permission_response has a pending request
            if msg_type == 'permission_response':
                request_id = data.get('request_id', '')
                pending = self.permission_handler.is_request_pending(request_id)
                timed_out = self.permission_handler.is_request_timed_out(request_id)
                print(f"[PERM VALIDATE] permission_response id={request_id}, pending={pending}, timed_out={timed_out}")
                if not pending and not timed_out:
                    print(f"[PERM VALIDATE] REJECTED — no matching request")
                    await websocket.send(json.dumps({
                        "type": "error",
                        "message": "No pending permission request"
                    }))
                    return

            if msg_type == 'voice_input':
                await self.handle_voice_input(websocket, data)
            elif msg_type == 'user_input':
                print(f"[USER_INPUT] Dispatching to handle_user_input")
                await self.handle_user_input(websocket, data)
            elif msg_type == 'list_projects':
                await self.handle_list_projects(websocket)
            elif msg_type == 'list_sessions':
                await self.handle_list_sessions(websocket, data)
            elif msg_type == 'get_session':
                await self.handle_get_session(websocket, data)
            elif msg_type == 'stop_audio':
                await self.cancel_tts()
            elif msg_type == 'stop_session':
                await self.handle_stop_session(websocket, data)
            elif msg_type == 'view_session':
                await self.handle_view_session(websocket, data)
            elif msg_type == 'new_session':
                await self.handle_new_session(websocket, data)
            elif msg_type == 'resume_session':
                await self.handle_resume_session(websocket, data)
            elif msg_type == 'add_project':
                await self.handle_add_project(websocket, data)
            elif msg_type == 'list_directory':
                await self.handle_list_directory(websocket, data)
            elif msg_type == 'read_file':
                await self.handle_read_file(websocket, data)
            elif msg_type == 'permission_response':
                await self.handle_permission_response(data)
            elif msg_type == 'question_response':
                await self.handle_question_response(data)
            elif msg_type == 'interrupt':
                await self.handle_interrupt()
            elif msg_type == 'usage_request':
                asyncio.create_task(self.handle_usage_request(websocket))
            elif msg_type == 'set_preference':
                await self.handle_set_preference(data)
            elif msg_type == 'resync':
                await self.handle_resync(websocket, data)
            elif msg_type == 'debug_log':
                print(f"[iOS DEBUG] {data.get('message', '')}")
        except Exception as e:
            import traceback
            print(f"Error handling message: {e}")
            traceback.print_exc()

    async def handle_client(self, websocket, path=None):
        """Handle client connection"""
        self.clients.add(websocket)
        self.permission_handler.websocket_clients.add(websocket)
        print(f"Client connected. Total clients: {len(self.clients)}")

        # Preserve active_session_id across reconnects - app receives current state
        # via send_connection_status below

        try:
            await self.send_status(websocket, "idle", "Connected")
            await self.send_connection_status(websocket)
            await self.permission_handler.send_pending_to_client(websocket)
            async for message in websocket:
                print(f"Received message: {message[:100]}...")
                await self.handle_message(websocket, message)
        except Exception as e:
            print(f"Client error: {e}")
        finally:
            self.clients.discard(websocket)
            self.permission_handler.websocket_clients.discard(websocket)
            print(f"Client disconnected. Total clients: {len(self.clients)}")

    async def start(self):
        """Start server"""
        # Get the running event loop
        self.loop = asyncio.get_running_loop()

        # Check tmux availability
        if not self.tmux.is_available():
            print("WARNING: tmux not installed. Install with: brew install tmux")
        else:
            print("tmux available for session management")

        self.transcript_path = self.find_transcript_path()

        if self.transcript_path:
            self.transcript_handler = TranscriptHandler(
                self.handle_content_response,  # New: content callback
                self.handle_claude_response,   # Existing: audio callback
                self.loop,
                self,
                user_callback=self.handle_user_message,
            )
            # Set expected session file (initializes line count from existing content)
            self.transcript_handler.set_session_file(self.transcript_path)
            self.observer = Observer()
            self.observer.schedule(self.transcript_handler, os.path.dirname(self.transcript_path))
            self.observer.start()

        # Initialize TTS queue (requires running event loop)
        self.tts_queue = asyncio.Queue()
        self.tts_cancel = asyncio.Event()

        # Start TTS worker
        self._tts_worker_task = asyncio.create_task(self._tts_worker())

        # Start pane polling loop
        self._pane_poll_task = asyncio.create_task(self._pane_poll_loop())

        # Start HTTP server for permission hooks
        http_runner = await start_http_server(self.permission_handler)

        from voice_server.qr_display import get_local_ip, print_startup_banner

        local_ip = get_local_ip()
        if local_ip:
            print_startup_banner(local_ip, PORT)
        else:
            print(f"WARNING: Could not detect local IP. Server running on port {PORT}")

        async with websockets.serve(self.handle_client, "0.0.0.0", PORT, max_size=20 * 1024 * 1024, ping_interval=30, ping_timeout=60):
            try:
                await asyncio.Future()
            finally:
                if self._tts_worker_task:
                    self._tts_worker_task.cancel()
                if self._pane_poll_task:
                    self._pane_poll_task.cancel()
                # Kill all active tmux sessions on shutdown
                killed = self.tmux.cleanup_all()
                if killed:
                    print(f"[SHUTDOWN] Killed {killed} active session(s)")


def main():
    """Entry point for claude-connect command."""
    from voice_server.setup_check import ensure_dependencies
    ensure_dependencies()
    asyncio.run(VoiceServer().start())


if __name__ == "__main__":
    main()
