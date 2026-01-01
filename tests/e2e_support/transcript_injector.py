#!/usr/bin/env python3
"""Inject mock assistant messages into transcript files for E2E tests"""
import json
import sys
import os
import time


def inject_assistant_message(transcript_path, message):
    """
    Inject a mock assistant message into transcript file

    Args:
        transcript_path: Path to transcript JSONL file
        message: Assistant message text to inject

    Returns:
        0 on success, 1 on file error, 2 on format error
    """
    try:
        # Create directory if needed
        os.makedirs(os.path.dirname(transcript_path), exist_ok=True)

        # Create entry
        entry = {
            "role": "assistant",
            "content": message,
            "timestamp": time.time()
        }

        # Validate JSON
        json_line = json.dumps(entry)
        json.loads(json_line)  # Verify it's valid

        # Append to file
        with open(transcript_path, 'a') as f:
            f.write(json_line + '\n')
            f.flush()

        return 0

    except IOError as e:
        print(f"File error: {e}", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        print(f"Format error: {e}", file=sys.stderr)
        return 2


def main():
    """CLI interface for transcript injection"""
    import argparse

    parser = argparse.ArgumentParser(description="Inject mock responses for E2E tests")
    parser.add_argument("--transcript", required=True, help="Path to transcript file")
    parser.add_argument("--message", required=True, help="Assistant message to inject")

    args = parser.parse_args()

    exit_code = inject_assistant_message(args.transcript, args.message)
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
