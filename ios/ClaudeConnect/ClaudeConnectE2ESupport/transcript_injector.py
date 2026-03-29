#!/usr/bin/env python3
"""Inject mock messages into transcript files for E2E tests

Simulates Claude and user writing to transcript. Server watches and reacts naturally.
"""
import json
import sys
import os
import time


def inject_user_message(transcript_path, message):
    """
    Inject a user message into transcript file (simulates user input being logged)

    Args:
        transcript_path: Path to transcript JSONL file
        message: User message text to inject

    Returns:
        0 on success, 1 on error
    """
    try:
        os.makedirs(os.path.dirname(transcript_path), exist_ok=True)

        entry = {
            "role": "user",
            "content": message,
            "timestamp": time.time()
        }

        json_line = json.dumps(entry)
        json.loads(json_line)  # Validate

        with open(transcript_path, 'a') as f:
            f.write(json_line + '\n')
            f.flush()

        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


def inject_assistant_message(transcript_path, message):
    """
    Inject an assistant message into transcript file (simulates Claude responding)

    Args:
        transcript_path: Path to transcript JSONL file
        message: Assistant message text to inject

    Returns:
        0 on success, 1 on error
    """
    try:
        os.makedirs(os.path.dirname(transcript_path), exist_ok=True)

        entry = {
            "role": "assistant",
            "content": message,
            "timestamp": time.time()
        }

        json_line = json.dumps(entry)
        json.loads(json_line)  # Validate

        with open(transcript_path, 'a') as f:
            f.write(json_line + '\n')
            f.flush()

        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


def main():
    """CLI interface for transcript injection"""
    import argparse

    parser = argparse.ArgumentParser(description="Inject mock messages for E2E tests")
    parser.add_argument("--transcript", required=True, help="Path to transcript file")
    parser.add_argument("--role", required=True, choices=["user", "assistant"])
    parser.add_argument("--message", required=True, help="Message to inject")

    args = parser.parse_args()

    if args.role == "user":
        exit_code = inject_user_message(args.transcript, args.message)
    else:
        exit_code = inject_assistant_message(args.transcript, args.message)

    sys.exit(exit_code)


if __name__ == "__main__":
    main()
