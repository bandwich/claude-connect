"""
Mock transcript file generation for testing
"""

import json
import time
from typing import List, Dict, Any


class MockTranscript:
    """Helper to create and manage mock Claude transcript files"""

    def __init__(self, filepath: str):
        self.filepath = filepath
        self.messages: List[Dict[str, Any]] = []

    def add_user_message(self, text: str):
        """Add a user message to the transcript"""
        message = {
            "role": "user",
            "content": [{"type": "text", "text": text}],
            "timestamp": time.time(),
        }
        self.messages.append(message)
        self._write()

    def add_assistant_message(self, text: str):
        """Add an assistant message to the transcript"""
        message = {
            "role": "assistant",
            "content": [{"type": "text", "text": text}],
            "timestamp": time.time(),
        }
        self.messages.append(message)
        self._write()

    def add_assistant_message_with_blocks(self, blocks: List[Dict[str, Any]]):
        """Add an assistant message with multiple content blocks"""
        message = {
            "role": "assistant",
            "content": blocks,
            "timestamp": time.time(),
        }
        self.messages.append(message)
        self._write()

    def clear(self):
        """Clear all messages"""
        self.messages = []
        self._write()

    def _write(self):
        """Write messages to the transcript file"""
        with open(self.filepath, "w") as f:
            for msg in self.messages:
                f.write(json.dumps(msg) + "\n")

    def get_last_assistant_message(self) -> str:
        """Get the last assistant message text"""
        for msg in reversed(self.messages):
            if msg.get("role") == "assistant":
                content = msg.get("content", [])
                if isinstance(content, str):
                    return content
                elif isinstance(content, list):
                    for block in content:
                        if isinstance(block, dict) and block.get("type") == "text":
                            return block.get("text", "")
        return ""

    def simulate_conversation(self, exchanges: List[tuple]):
        """
        Simulate a conversation with multiple exchanges

        Args:
            exchanges: List of (user_text, assistant_text) tuples
        """
        for user_text, assistant_text in exchanges:
            if user_text:
                self.add_user_message(user_text)
            if assistant_text:
                self.add_assistant_message(assistant_text)
                time.sleep(0.1)  # Small delay to simulate real conversation


def create_empty_transcript(filepath: str):
    """Create an empty transcript file"""
    with open(filepath, "w") as f:
        f.write("")


def create_sample_transcript(filepath: str):
    """Create a sample transcript with test data"""
    transcript = MockTranscript(filepath)
    transcript.add_user_message("Hello, how are you?")
    transcript.add_assistant_message("I'm doing well, thank you for asking! How can I help you today?")
    return transcript
