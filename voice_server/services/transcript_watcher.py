"""
Transcript Watcher - monitors Claude Code transcript files for new content.

Contains the TranscriptHandler (watchdog FileSystemEventHandler) and
the poll_for_session_file utility.
"""

import asyncio
import json
import os
import re
import threading
import time
from typing import Optional

from watchdog.events import FileSystemEventHandler

from voice_server.models.content_models import (
    TextBlock, ThinkingBlock, ToolUseBlock, ToolResultBlock,
    ContentBlock, AssistantResponse, strip_agent_metadata as _strip_agent_metadata,
)
from voice_server.services.context_tracker import ContextTracker
from voice_server.services.session_manager import HIDDEN_TOOLS
from voice_server.services.tts_manager import extract_text_for_tts


IMAGE_SOURCE_RE = re.compile(r'^\[Image: source: (.+)\]$')


def rewrite_user_text(text: str) -> str:
    """Clean up user text for display: rewrite image sources, strip suffixes."""
    stripped = text.strip()
    m = IMAGE_SOURCE_RE.match(stripped)
    if m:
        filename = os.path.basename(m.group(1))
        return f"[Image: {filename}]"
    if stripped.startswith('[Request interrupted by user'):
        return "[Request interrupted by user]"
    return stripped


async def poll_for_session_file(find_fn, timeout=10.0, interval=0.2):
    """Poll until find_fn() returns a non-None value (e.g. a session ID or path).

    Args:
        find_fn: Callable that returns None (not found) or a value (found)
        timeout: Max seconds to wait
        interval: Seconds between polls

    Returns:
        The value from find_fn, or None on timeout
    """
    deadline = time.time() + timeout
    while time.time() < deadline:
        result = find_fn()
        if result is not None:
            return result
        await asyncio.sleep(interval)
    return None


class TranscriptHandler(FileSystemEventHandler):
    """Monitors transcript file for new assistant messages.

    Uses line-position tracking to stream ALL assistant content,
    regardless of whether voice input initiated the interaction.

    Only processes events from the expected session file, ignoring
    sub-agent transcripts (agent-*.jsonl) and other sessions.
    """

    def __init__(self, content_callback, audio_callback, loop, server, user_callback=None):
        self.content_callback = content_callback
        self.audio_callback = audio_callback
        self.user_callback = user_callback
        self.loop = loop
        self.server = server
        self.last_modified = 0
        self.processed_line_count = 0
        self.expected_session_file = None
        self.context_tracker = ContextTracker()
        self.hidden_tool_ids = set()
        self.agent_tool_ids = set()
        self._lock = threading.Lock()

    @staticmethod
    def _is_command_noise(text: str) -> bool:
        """Check if user message text is slash command XML noise."""
        return ('<local-command-caveat>' in text or
                '<command-name>' in text or
                '<local-command-stdout>' in text)

    def on_modified(self, event):
        if event.is_directory or not event.src_path.endswith('.jsonl'):
            return

        filename = os.path.basename(event.src_path)
        if filename.startswith('agent-'):
            return

        with self._lock:
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
                print(f"[SYNC] on_modified: lines {line_count_before}\u2192{line_count_after}, "
                      f"blocks={len(new_blocks)}, user_texts={len(user_texts)}")
            elif line_count_after > line_count_before:
                print(f"[SYNC] on_modified: lines {line_count_before}\u2192{line_count_after} (no extractable content)")

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

                if not self.server or self.server.active_session_id:
                    text = extract_text_for_tts(new_blocks)
                    if text:
                        asyncio.run_coroutine_threadsafe(
                            self.audio_callback(text),
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

            if self.server and getattr(self.server, 'active_session_id', None):
                self.broadcast_context_update(event.src_path, self.server.active_session_id)
        except Exception as e:
            print(f"Error processing transcript: {e}")
            import traceback
            traceback.print_exc()

    def extract_new_content_with_seq(self, filepath) -> tuple:
        """Like extract_new_content but also returns the starting line number."""
        start_line = self.processed_line_count
        blocks, user_texts_with_line, task_completed_ids = self.extract_new_content(filepath)
        return blocks, user_texts_with_line, task_completed_ids, start_line

    def extract_new_assistant_content(self, filepath) -> list[ContentBlock]:
        """Legacy wrapper -- returns only content blocks."""
        blocks, _, _ = self.extract_new_content(filepath)
        return blocks

    def extract_new_content(self, filepath) -> tuple:
        """Extract assistant content, tool results, and user texts from new lines."""
        all_blocks = []
        user_texts = []
        task_completed_ids = []

        with open(filepath, 'r') as f:
            lines = f.readlines()

        if len(lines) < self.processed_line_count:
            self.processed_line_count = 0

        new_lines = lines[self.processed_line_count:]

        for line_offset, line in enumerate(new_lines):
            line_num = self.processed_line_count + line_offset
            try:
                entry = json.loads(line.strip())
                branch = entry.get('gitBranch', '')
                if branch:
                    self.server.current_branch = branch
                msg = entry.get('message', {})
                role = msg.get('role') or entry.get('role')

                if role == 'assistant':
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
                                        if not self._is_command_noise(text):
                                            user_texts.append((rewrite_user_text(text), line_num))
                    elif isinstance(content, str) and content.strip():
                        stripped = content.strip()
                        if stripped.startswith('Base directory for this skill:'):
                            pass
                        elif stripped.startswith('<task-notification'):
                            match = re.search(r'<tool-use-id>([^<]+)</tool-use-id>', stripped)
                            if match:
                                task_completed_ids.append(match.group(1))
                        elif self._is_command_noise(stripped):
                            pass
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
        """Set the expected session file and initialize line count."""
        with self._lock:
            self.expected_session_file = file_path
            self.hidden_tool_ids = set()
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
        """Check for lines that watchdog missed and extract their content."""
        with self._lock:
            if not self.expected_session_file or not os.path.exists(self.expected_session_file):
                return [], [], [], 0
            return self.extract_new_content_with_seq(self.expected_session_file)

    def reset_tracking_state(self):
        """Reset tracking state (legacy - prefer set_session_file)"""
        with self._lock:
            self.processed_line_count = 0
            self.expected_session_file = None
