#!/usr/bin/env python3
"""Send voice input to server via WebSocket for E2E tests

Simulates the iOS app sending voice input to the server.
"""
import asyncio
import websockets
import json
import time
import sys


async def send_voice_input(host, port, text):
    """
    Send voice input to server via WebSocket

    Args:
        host: Server host
        port: Server port
        text: Voice input text to send

    Returns:
        0 on success, 1 on error
    """
    try:
        uri = f"ws://{host}:{port}"

        async with websockets.connect(uri) as websocket:
            # Send voice input message (same format as iOS app)
            message = {
                "type": "voice_input",
                "text": text,
                "timestamp": time.time()
            }

            await websocket.send(json.dumps(message))

            # Wait briefly for server to process
            await asyncio.sleep(0.5)

        return 0
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


def main():
    """CLI interface for sending voice input"""
    import argparse

    parser = argparse.ArgumentParser(description="Send voice input to server")
    parser.add_argument("--host", default="127.0.0.1", help="Server host")
    parser.add_argument("--port", type=int, default=8765, help="Server port")
    parser.add_argument("--text", required=True, help="Voice input text")

    args = parser.parse_args()

    exit_code = asyncio.run(send_voice_input(args.host, args.port, args.text))
    sys.exit(exit_code)


if __name__ == "__main__":
    main()
