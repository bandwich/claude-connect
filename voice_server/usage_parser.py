"""Parser for Claude Code /usage command output."""

import re
from typing import Optional

# ANSI escape code pattern
ANSI_ESCAPE = re.compile(r'\x1b\[[0-9;]*m')

def strip_ansi(text: str) -> str:
    """Remove ANSI escape codes from text."""
    return ANSI_ESCAPE.sub('', text)

def parse_usage_output(output: str) -> dict:
    """Parse /usage command output into structured data.

    Args:
        output: Raw terminal output from /usage command

    Returns:
        Dict with session, week_all_models, week_sonnet_only stats
    """
    clean = strip_ansi(output)

    result = {
        "session": {"percentage": None, "resets_at": None, "timezone": None},
        "week_all_models": {"percentage": None, "resets_at": None, "timezone": None},
        "week_sonnet_only": {"percentage": None}
    }

    # Split into sections by looking for headers
    sections = re.split(r'\n\s*\n', clean)

    current_section = None

    for section in sections:
        section_lower = section.lower()

        if 'current session' in section_lower:
            current_section = 'session'
        elif 'current week (all models)' in section_lower:
            current_section = 'week_all_models'
        elif 'current week (sonnet' in section_lower:
            current_section = 'week_sonnet_only'
        else:
            current_section = None

        if current_section:
            # Extract percentage: look for "X% used"
            pct_match = re.search(r'(\d+)%\s*used', section)
            if pct_match:
                result[current_section]["percentage"] = int(pct_match.group(1))

            # Extract reset time: "Resets X:XXam/pm (Timezone)"
            reset_match = re.search(r'Resets\s+(\d+:\d+[ap]m)\s*\(([^)]+)\)', section)
            if reset_match and current_section != 'week_sonnet_only':
                result[current_section]["resets_at"] = reset_match.group(1)
                result[current_section]["timezone"] = reset_match.group(2)

    return result
