"""Context tracking service for Claude Code sessions."""

import json
from typing import Optional

CONTEXT_LIMIT = 200000

class ContextTracker:
    """Calculates context usage from transcript files."""

    def calculate_context(self, transcript_path: str) -> dict:
        """Parse transcript and calculate context usage from the last assistant message.

        Uses the last assistant message's token counts (including cache tokens)
        as the estimate for current context usage.

        Args:
            transcript_path: Path to session .jsonl transcript file

        Returns:
            Dict with tokens_used, context_limit, context_percentage
        """
        total_tokens = 0
        last_usage = None

        try:
            with open(transcript_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        entry = json.loads(line)
                        message = entry.get('message', {})
                        usage = message.get('usage')
                        if usage:
                            last_usage = usage
                    except json.JSONDecodeError:
                        continue
        except FileNotFoundError:
            pass

        if last_usage:
            # Sum all token types from the last assistant response
            # This represents the current context size
            total_tokens = (
                last_usage.get('input_tokens', 0) +
                last_usage.get('output_tokens', 0) +
                last_usage.get('cache_creation_input_tokens', 0) +
                last_usage.get('cache_read_input_tokens', 0)
            )

        percentage = round((total_tokens / CONTEXT_LIMIT) * 100, 2)

        return {
            "tokens_used": total_tokens,
            "context_limit": CONTEXT_LIMIT,
            "context_percentage": percentage
        }
