"""TTS Manager - text-to-speech generation and audio streaming via Kokoro."""

import asyncio
import base64
import json
import re
import time
from typing import TYPE_CHECKING

import numpy as np

from server.models.content_models import ContentBlock, TextBlock

if TYPE_CHECKING:
    from server.main import ConnectServer

import logging
import sys
sys.path.insert(0, '/Users/aaron/Desktop/max/.venv/lib/python3.9/site-packages')

from huggingface_hub import try_to_load_from_cache
from kokoro import KPipeline
from kokoro.model import KModel
import soundfile as sf

# Cached pipeline instance (initialized eagerly via warmup_tts())
_pipeline = None


def warmup_tts(lang_code: str = "en-us", voice: str = "af_heart"):
    """Initialize the Kokoro TTS pipeline eagerly so first TTS has no load delay."""
    global _pipeline
    if _pipeline is not None:
        return

    # Enable huggingface_hub logging so download progress bars are visible
    logging.getLogger("huggingface_hub").setLevel(logging.INFO)

    # Check if model files need downloading
    repo_id = KModel.REPO_ID
    model_cached = try_to_load_from_cache(repo_id, "kokoro-v1_0.pth")
    config_cached = try_to_load_from_cache(repo_id, "config.json")
    voice_cached = try_to_load_from_cache(repo_id, f"voices/{voice}.pt")

    if not model_cached or not config_cached:
        print(f"[TTS] Downloading Kokoro model from {repo_id} (first run)...")
    else:
        print("[TTS] Loading model from cache...")

    _pipeline = KPipeline(lang_code=lang_code)

    if not voice_cached:
        print(f"[TTS] Downloading voice '{voice}'...")
    else:
        print(f"[TTS] Loading voice '{voice}'...")
    _pipeline.load_single_voice(voice)


def generate_tts_audio(text: str, voice: str = "af_heart", lang_code: str = "en-us") -> np.ndarray:
    """Generate TTS audio from text using Kokoro."""
    global _pipeline
    if _pipeline is None:
        _pipeline = KPipeline(lang_code=lang_code)
    audio_chunks = _pipeline(text, voice=voice)

    all_samples = []
    for chunk in audio_chunks:
        audio_tensor = chunk.output.audio
        all_samples.append(audio_tensor.numpy())

    return np.concatenate(all_samples)


def save_wav(samples: np.ndarray, filepath: str, sample_rate: int = 24000):
    """Save audio samples to WAV file."""
    sf.write(filepath, samples, sample_rate)


def chunk_audio(samples: np.ndarray, chunk_size: int = 4096) -> list:
    """Split audio into chunks for streaming."""
    chunks = []
    for i in range(0, len(samples), chunk_size):
        chunks.append(samples[i:i+chunk_size])
    return chunks


def samples_to_wav_bytes(samples: np.ndarray, sample_rate: int = 24000) -> bytes:
    """Convert audio samples to WAV format bytes."""
    import io
    wav_buffer = io.BytesIO()
    sf.write(wav_buffer, samples, sample_rate, format='WAV')
    wav_buffer.seek(0)
    return wav_buffer.read()


# --- Text processing for TTS ---

def strip_markdown_for_speech(text: str) -> str:
    """Strip markdown formatting so TTS doesn't speak asterisks, backticks, etc."""
    s = text
    s = re.sub(r'\*{1,3}(.+?)\*{1,3}', r'\1', s)
    s = re.sub(r'`([^`]+)`', r'\1', s)
    s = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', s)
    s = re.sub(r'^#{1,6}\s+', '', s, flags=re.MULTILINE)
    return s


def extract_text_for_tts(content_blocks: list[ContentBlock]) -> str:
    """Extract only text blocks for TTS, with markdown stripped."""
    text_parts = []
    for block in content_blocks:
        if isinstance(block, TextBlock):
            text_parts.append(strip_markdown_for_speech(block.text))
    return ' '.join(text_parts).strip()


# --- TTSManager delegate class ---

class TTSManager:
    """Manages TTS queue, generation, and audio streaming."""

    def __init__(self, server: "ConnectServer"):
        self.server = server
        self.queue: asyncio.Queue | None = None
        self.cancel: asyncio.Event | None = None
        self.active = False
        self._worker_task: asyncio.Task | None = None

    def init_async(self):
        """Initialize async primitives (must be called from async context)."""
        self.queue = asyncio.Queue()
        self.cancel = asyncio.Event()

    def start_worker(self):
        """Start the background TTS worker task."""
        self._worker_task = asyncio.create_task(self._worker())

    async def handle_claude_response(self, text):
        """Queue text for TTS. Cancels active TTS if running."""
        if not self.server.tts_enabled:
            print(f"[{time.strftime('%H:%M:%S')}] TTS disabled, skipping audio for: '{text[:50]}...'")
            for client in list(self.server.clients):
                try:
                    await self.server.send_status(client, "idle", "Ready")
                except Exception:
                    pass
            return

        print(f"[{time.strftime('%H:%M:%S')}] Claude response queued for TTS: '{text[:100]}...'")
        if self.active:
            print(f"[TTS] Interrupting active TTS for new message")
            self.cancel.set()
            await self._send_stop_audio()
        await self.queue.put(text)

    async def _worker(self):
        """Background worker that processes TTS requests one at a time."""
        while True:
            try:
                text = await self.queue.get()

                # Drain queue — keep only the latest
                while not self.queue.empty():
                    try:
                        text = self.queue.get_nowait()
                    except asyncio.QueueEmpty:
                        break

                self.cancel.clear()
                self.active = True

                try:
                    print(f"[TTS] Generating audio for: '{text[:50]}...'")
                    loop = asyncio.get_running_loop()
                    samples = await loop.run_in_executor(
                        None, lambda: generate_tts_audio(text, voice="af_heart")
                    )

                    if self.cancel.is_set():
                        print(f"[TTS] Cancelled after generation")
                        continue

                    wav_bytes = samples_to_wav_bytes(samples)

                    for websocket in list(self.server.clients):
                        await self.server.send_status(websocket, "speaking", "Playing response")
                        completed = await self.stream_audio(websocket, wav_bytes, self.cancel)
                        if completed:
                            await self.server.send_status(websocket, "idle", "Ready")

                finally:
                    self.active = False

            except asyncio.CancelledError:
                self.active = False
                raise
            except Exception as e:
                self.active = False
                print(f"[TTS] Worker error: {e}")
                import traceback
                traceback.print_exc()

    async def cancel_tts(self):
        """Cancel any active or queued TTS and tell clients to stop audio."""
        if self.cancel:
            self.cancel.set()
        if self.queue:
            while not self.queue.empty():
                try:
                    self.queue.get_nowait()
                except asyncio.QueueEmpty:
                    break
        await self._send_stop_audio()

    async def _send_stop_audio(self):
        """Send stop_audio message to all connected clients."""
        message = json.dumps({"type": "stop_audio"})
        for websocket in list(self.server.clients):
            try:
                await websocket.send(message)
            except Exception:
                pass

    async def stream_audio(self, websocket, wav_bytes, cancel_event):
        """Stream pre-generated WAV audio to client. Returns False if cancelled."""
        try:
            chunk_size = 8192
            total_chunks = (len(wav_bytes) + chunk_size - 1) // chunk_size
            print(f"Streaming {total_chunks} audio chunks...")

            for i in range(0, len(wav_bytes), chunk_size):
                if cancel_event.is_set():
                    print(f"[TTS] Streaming cancelled at chunk {i // chunk_size}/{total_chunks}")
                    return False

                chunk = wav_bytes[i:i+chunk_size]
                await websocket.send(json.dumps({
                    "type": "audio_chunk",
                    "format": "wav",
                    "sample_rate": 24000,
                    "chunk_index": i // chunk_size,
                    "total_chunks": total_chunks,
                    "data": base64.b64encode(chunk).decode('utf-8')
                }))
                await asyncio.sleep(0.01)

            print(f"Finished streaming {total_chunks} chunks")
            return True

        except Exception as e:
            print(f"Error streaming audio: {e}")
            import traceback
            traceback.print_exc()
            return False
