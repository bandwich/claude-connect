#!/usr/bin/env python3
"""Manage ios_server.py lifecycle for E2E tests"""
import subprocess
import sys
import os
import time
import signal
import json

sys.path.insert(0, os.path.dirname(__file__))
from test_config import (
    SERVER_SCRIPT, PYTHON_VENV, TEST_SERVER_PORT,
    SERVER_STARTUP_TIMEOUT, TEMP_TRANSCRIPT_DIR
)


def start_server(transcript_path):
    """
    Start real ios_server.py for testing

    Args:
        transcript_path: Path to transcript file for server to watch

    Returns:
        dict with keys: pid, port, status
    """
    # Ensure transcript file exists
    os.makedirs(os.path.dirname(transcript_path), exist_ok=True)
    if not os.path.exists(transcript_path):
        with open(transcript_path, 'w') as f:
            pass  # Create empty file

    # Start server process
    # Note: May need to modify ios_server.py to accept --transcript-path arg
    env = os.environ.copy()
    env["TEST_MODE"] = "1"
    env["TEST_TRANSCRIPT_PATH"] = transcript_path

    process = subprocess.Popen(
        [PYTHON_VENV, "-u", SERVER_SCRIPT],  # -u for unbuffered output
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        env=env
    )

    # Wait for server to be ready
    start_time = time.time()
    ready = False

    while time.time() - start_time < SERVER_STARTUP_TIMEOUT:
        line = process.stdout.readline()
        if "Server running on" in line:
            ready = True
            break
        if process.poll() is not None:
            stderr = process.stderr.read()
            raise RuntimeError(f"Server failed to start: {stderr}")
        time.sleep(0.1)

    if not ready:
        process.kill()
        raise TimeoutError(f"Server did not start within {SERVER_STARTUP_TIMEOUT}s")

    return {
        "pid": process.pid,
        "port": TEST_SERVER_PORT,
        "status": "ready"
    }


def stop_server(pid):
    """
    Stop server process

    Args:
        pid: Process ID to kill
    """
    try:
        import psutil
        process = psutil.Process(pid)

        # Kill all child processes first
        for child in process.children(recursive=True):
            try:
                child.kill()
            except psutil.NoSuchProcess:
                pass

        # Then kill the parent
        process.kill()
        process.wait(timeout=3)

    except psutil.NoSuchProcess:
        pass  # Already dead
    except Exception as e:
        # Fallback to os.kill
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass


def main():
    """CLI interface for server management"""
    import argparse

    parser = argparse.ArgumentParser(description="Manage ios_server for E2E tests")
    subparsers = parser.add_subparsers(dest="command")

    # Start command
    start_parser = subparsers.add_parser("start")
    start_parser.add_argument("--transcript", required=True)

    # Stop command
    stop_parser = subparsers.add_parser("stop")
    stop_parser.add_argument("--pid", type=int, required=True)

    args = parser.parse_args()

    if args.command == "start":
        result = start_server(args.transcript)
        print(json.dumps(result))
    elif args.command == "stop":
        stop_server(args.pid)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()
