#!/usr/bin/env python3
"""Voice Mode - Send Claude's output to Kokoro TTS"""

import json
import sys
import os
import subprocess

# Import shared TTS utilities
from server.services.tts_manager import generate_tts_audio, save_wav

LOG_FILE = '/tmp/voice_debug.log'

def log(msg):
    with open(LOG_FILE, 'a') as f:
        f.write(f"{msg}\n")

try:
    log("Hook started")

    # Check if voice mode is active by looking for voice-chat.sh process
    result = subprocess.run(['pgrep', '-f', 'voice-chat.sh'], capture_output=True)
    if result.returncode != 0:
        log("Voice mode not active (voice-chat.sh not running), exiting")
        sys.exit(0)

    log("Voice mode is active, proceeding")

    # Read hook input
    log("Reading hook input")
    hook_input = json.load(sys.stdin)
    transcript_path = hook_input.get('transcript_path')
    log(f"Transcript path: {transcript_path}")

    if not transcript_path or not os.path.exists(transcript_path):
        log("No transcript path or file doesn't exist")
        sys.exit(0)

    # Extract last assistant message
    last_response = None
    with open(transcript_path, 'r') as f:
        for line in f:
            try:
                entry = json.loads(line.strip())
                # Check if this is an assistant message
                msg = entry.get('message', {})
                if msg.get('role') == 'assistant' or entry.get('role') == 'assistant':
                    # Get content from either entry.message.content or entry.content
                    content = msg.get('content', entry.get('content', ''))
                    if isinstance(content, str):
                        last_response = content
                    elif isinstance(content, list):
                        text_parts = [
                            block.get('text', '')
                            for block in content
                            if isinstance(block, dict) and block.get('type') == 'text'
                        ]
                        last_response = ' '.join(text_parts)
            except:
                continue

    if not last_response or len(last_response.strip()) < 3:
        log(f"Response too short or empty: {last_response}")
        sys.exit(0)

    log(f"Got response: {last_response[:50]}...")

    # Generate speech using Kokoro (via shared utilities)
    log("Generating audio")
    samples = generate_tts_audio(last_response, voice="af_heart")

    # Save to temp file
    output_file = '/tmp/claude_speech.wav'
    log(f"Writing to {output_file}")
    save_wav(samples, output_file)

    # Play audio (macOS)
    log("Playing audio")
    subprocess.run(['afplay', output_file], check=False)
    log("Done playing audio")

    # Don't auto-start voice input - let continuous-voice.sh handle the loop
    # subprocess removed - continuous script will manage the conversation flow

except Exception as e:
    log(f"ERROR: {e}")
    import traceback
    log(traceback.format_exc())
    sys.stderr.write(f"Voice mode error: {e}\n")
    sys.exit(1)
