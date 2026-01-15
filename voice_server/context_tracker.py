"""Context tracking service for Claude Code sessions."""

import json
from typing import Optional

CONTEXT_LIMIT = 200000

class ContextTracker:
    """Calculates context usage from transcript files."""

    def calculate_context(self, transcript_path: str) -> dict:
        """Parse transcript and sum token usage.

        Args:
            transcript_path: Path to session .jsonl transcript file

        Returns:
            Dict with tokens_used, context_limit, context_percentage
        """
        total_tokens = 0

        try:
            with open(transcript_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                        message = entry.get('message', {})
                        usage = message.get('usage', {})
                        total_tokens += usage.get('input_tokens', 0)
                        total_tokens += usage.get('output_tokens', 0)
                    except json.JSONDecodeError:
                        continue
        except FileNotFoundError:
            pass

        percentage = round((total_tokens / CONTEXT_LIMIT) * 100, 2)

        return {
            "tokens_used": total_tokens,
            "context_limit": CONTEXT_LIMIT,
            "context_percentage": percentage
        }
