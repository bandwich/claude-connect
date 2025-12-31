#!/usr/bin/env python3
"""
Shared TTS Utilities for Voice Mode
Provides reusable functions for Kokoro TTS generation
"""

import sys
import numpy as np

# Activate the venv's packages
sys.path.insert(0, '/Users/aaron/Desktop/max/.venv/lib/python3.9/site-packages')

from kokoro import KPipeline
import soundfile as sf


def generate_tts_audio(text: str, voice: str = "af_heart", lang_code: str = "en-us") -> np.ndarray:
    """
    Generate TTS audio from text using Kokoro.

    Args:
        text: The text to convert to speech
        voice: The voice to use (default: af_heart)
        lang_code: The language code (default: en-us)

    Returns:
        numpy array of audio samples at 24kHz
    """
    pipeline = KPipeline(lang_code=lang_code)
    audio_chunks = pipeline(text, voice=voice)

    all_samples = []
    for chunk in audio_chunks:
        audio_tensor = chunk.output.audio
        all_samples.append(audio_tensor.numpy())

    return np.concatenate(all_samples)


def save_wav(samples: np.ndarray, filepath: str, sample_rate: int = 24000):
    """
    Save audio samples to WAV file.

    Args:
        samples: Audio samples as numpy array
        filepath: Output file path
        sample_rate: Sample rate in Hz (default: 24000)
    """
    sf.write(filepath, samples, sample_rate)


def chunk_audio(samples: np.ndarray, chunk_size: int = 4096) -> list:
    """
    Split audio into chunks for streaming.

    Args:
        samples: Audio samples as numpy array
        chunk_size: Number of samples per chunk (default: 4096)

    Returns:
        List of audio chunks as numpy arrays
    """
    chunks = []
    for i in range(0, len(samples), chunk_size):
        chunks.append(samples[i:i+chunk_size])
    return chunks


def samples_to_wav_bytes(samples: np.ndarray, sample_rate: int = 24000) -> bytes:
    """
    Convert audio samples to WAV format bytes.

    Args:
        samples: Audio samples as numpy array
        sample_rate: Sample rate in Hz (default: 24000)

    Returns:
        WAV file as bytes
    """
    import io
    wav_buffer = io.BytesIO()
    sf.write(wav_buffer, samples, sample_rate, format='WAV')
    wav_buffer.seek(0)
    return wav_buffer.read()
