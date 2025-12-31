#!/usr/bin/env python3
"""
Generate test audio file for integration tests
Creates a short WAV file with a simple tone
"""

import sys
import os
import numpy as np

sys.path.insert(0, '/Users/aaron/Desktop/max/.venv/lib/python3.9/site-packages')
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from tts_utils import save_wav

def generate_test_audio():
    """Generate test audio file (6 seconds, 440Hz tone)"""
    sample_rate = 24000
    duration = 6.0  # seconds - longer duration to give UI tests time to detect Speaking state
    frequency = 440  # Hz (A note)

    t = np.linspace(0, duration, int(sample_rate * duration))
    samples = np.sin(2 * np.pi * frequency * t) * 0.3  # 30% amplitude

    output_path = os.path.join(os.path.dirname(__file__), 'fixtures', 'test_audio.wav')
    save_wav(samples, output_path, sample_rate)
    print(f"Generated test audio: {output_path}")
    print(f"Duration: {duration}s, Sample rate: {sample_rate}Hz, Size: {len(samples)} samples")

if __name__ == "__main__":
    generate_test_audio()
