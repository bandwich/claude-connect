"""Legacy re-export — all TTS functions live in server.services.tts_manager."""

from server.services.tts_manager import (
    generate_tts_audio,
    warmup_tts,
    save_wav,
    chunk_audio,
    samples_to_wav_bytes,
)

__all__ = [
    'generate_tts_audio',
    'warmup_tts',
    'save_wav',
    'chunk_audio',
    'samples_to_wav_bytes',
]
