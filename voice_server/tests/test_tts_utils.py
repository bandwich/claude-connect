#!/usr/bin/env python3
"""
Tests for tts_utils.py - TTS Utility Functions
"""

import pytest
import numpy as np
import tempfile
import os
from unittest.mock import Mock, patch, MagicMock
import sys

from voice_server.tts_utils import (
    generate_tts_audio,
    save_wav,
    chunk_audio,
    samples_to_wav_bytes
)


class TestGenerateTTSAudio:
    """Tests for generate_tts_audio function"""

    def setup_method(self):
        """Clear cached pipeline before each test"""
        import voice_server.tts_utils as tts_mod
        tts_mod._pipeline = None

    def teardown_method(self):
        """Clear cached pipeline after each test"""
        import voice_server.tts_utils as tts_mod
        tts_mod._pipeline = None

    @patch('voice_server.tts_utils.KPipeline')
    def test_generate_tts_audio(self, mock_pipeline_class):
        """Test basic TTS generation returns valid numpy array"""
        # Setup mock
        mock_chunk = Mock()
        mock_chunk.output.audio.numpy.return_value = np.array([0.1, 0.2, 0.3])

        mock_pipeline = Mock()
        mock_pipeline.return_value = [mock_chunk]
        mock_pipeline_class.return_value = mock_pipeline

        # Test
        result = generate_tts_audio("Hello world")

        # Verify
        assert isinstance(result, np.ndarray)
        assert len(result) == 3
        mock_pipeline_class.assert_called_once_with(lang_code="en-us")
        mock_pipeline.assert_called_once_with("Hello world", voice="af_heart")

    @patch('voice_server.tts_utils.KPipeline')
    def test_generate_tts_audio_empty_text(self, mock_pipeline_class):
        """Test with empty string"""
        mock_chunk = Mock()
        mock_chunk.output.audio.numpy.return_value = np.array([])

        mock_pipeline = Mock()
        mock_pipeline.return_value = [mock_chunk]
        mock_pipeline_class.return_value = mock_pipeline

        result = generate_tts_audio("")

        assert isinstance(result, np.ndarray)
        assert len(result) == 0

    @patch('voice_server.tts_utils.KPipeline')
    def test_generate_tts_audio_multiple_chunks(self, mock_pipeline_class):
        """Test concatenation of multiple audio chunks"""
        mock_chunk1 = Mock()
        mock_chunk1.output.audio.numpy.return_value = np.array([0.1, 0.2])

        mock_chunk2 = Mock()
        mock_chunk2.output.audio.numpy.return_value = np.array([0.3, 0.4])

        mock_pipeline = Mock()
        mock_pipeline.return_value = [mock_chunk1, mock_chunk2]
        mock_pipeline_class.return_value = mock_pipeline

        result = generate_tts_audio("Hello world")

        assert len(result) == 4
        np.testing.assert_array_equal(result, np.array([0.1, 0.2, 0.3, 0.4]))


class TestSaveWav:
    """Tests for save_wav function"""

    @patch('voice_server.tts_utils.sf.write')
    def test_save_wav(self, mock_write):
        """Test WAV file creation"""
        samples = np.array([0.1, 0.2, 0.3])
        filepath = '/tmp/test.wav'

        save_wav(samples, filepath)

        mock_write.assert_called_once_with(filepath, samples, 24000)

    @patch('voice_server.tts_utils.sf.write')
    def test_save_wav_custom_sample_rate(self, mock_write):
        """Test with custom sample rate"""
        samples = np.array([0.1, 0.2, 0.3])
        filepath = '/tmp/test.wav'

        save_wav(samples, filepath, sample_rate=48000)

        mock_write.assert_called_once_with(filepath, samples, 48000)

    def test_save_wav_file_exists(self):
        """Test file is actually created and readable"""
        samples = np.random.random(1000)

        with tempfile.NamedTemporaryFile(suffix='.wav', delete=False) as f:
            filepath = f.name

        try:
            save_wav(samples, filepath)
            assert os.path.exists(filepath)
            assert os.path.getsize(filepath) > 0
        finally:
            if os.path.exists(filepath):
                os.unlink(filepath)


class TestChunkAudio:
    """Tests for chunk_audio function"""

    def test_chunk_audio(self):
        """Test audio chunking with default size"""
        samples = np.arange(10000)
        chunks = chunk_audio(samples, chunk_size=4096)

        assert len(chunks) == 3  # 4096, 4096, 1808
        assert len(chunks[0]) == 4096
        assert len(chunks[1]) == 4096
        assert len(chunks[2]) == 1808

    def test_chunk_audio_small_array(self):
        """Test with array smaller than chunk size"""
        samples = np.arange(100)
        chunks = chunk_audio(samples, chunk_size=4096)

        assert len(chunks) == 1
        assert len(chunks[0]) == 100

    def test_chunk_audio_exact_multiple(self):
        """Test when array size is exact multiple of chunk size"""
        samples = np.arange(8192)
        chunks = chunk_audio(samples, chunk_size=4096)

        assert len(chunks) == 2
        assert len(chunks[0]) == 4096
        assert len(chunks[1]) == 4096

    def test_chunk_audio_preserves_data(self):
        """Test that chunking preserves all data"""
        samples = np.arange(10000)
        chunks = chunk_audio(samples, chunk_size=4096)

        reconstructed = np.concatenate(chunks)
        np.testing.assert_array_equal(samples, reconstructed)


class TestSamplesToWavBytes:
    """Tests for samples_to_wav_bytes function"""

    def test_samples_to_wav_bytes(self):
        """Test WAV byte conversion"""
        samples = np.random.random(1000)
        wav_bytes = samples_to_wav_bytes(samples)

        assert isinstance(wav_bytes, bytes)
        assert len(wav_bytes) > 0

    def test_samples_to_wav_bytes_valid_format(self):
        """Verify WAV header is valid"""
        samples = np.random.random(1000)
        wav_bytes = samples_to_wav_bytes(samples)

        # Check RIFF header
        assert wav_bytes[:4] == b'RIFF'
        # Check WAVE format
        assert wav_bytes[8:12] == b'WAVE'

    def test_samples_to_wav_bytes_custom_sample_rate(self):
        """Test with custom sample rate"""
        samples = np.random.random(1000)
        wav_bytes = samples_to_wav_bytes(samples, sample_rate=48000)

        assert isinstance(wav_bytes, bytes)
        assert len(wav_bytes) > 0

    def test_samples_to_wav_bytes_empty_array(self):
        """Test with empty array"""
        samples = np.array([])
        wav_bytes = samples_to_wav_bytes(samples)

        # Should still have valid WAV header
        assert wav_bytes[:4] == b'RIFF'
        assert wav_bytes[8:12] == b'WAVE'


class TestWarmupTTS:
    """Tests for TTS pipeline caching and warmup"""

    @patch('voice_server.tts_utils.KPipeline')
    def test_warmup_initializes_pipeline(self, mock_pipeline_class):
        """Test that warmup_tts creates the cached pipeline"""
        from voice_server.tts_utils import warmup_tts, _pipeline
        import voice_server.tts_utils as tts_mod

        # Clear any cached pipeline
        tts_mod._pipeline = None

        warmup_tts()

        mock_pipeline_class.assert_called_once_with(lang_code="en-us")
        assert tts_mod._pipeline is not None

        # Cleanup
        tts_mod._pipeline = None

    @patch('voice_server.tts_utils.KPipeline')
    def test_generate_reuses_cached_pipeline(self, mock_pipeline_class):
        """Test that generate_tts_audio reuses the cached pipeline instead of creating a new one"""
        import voice_server.tts_utils as tts_mod

        mock_pipeline_instance = Mock()
        mock_chunk = Mock()
        mock_chunk.output.audio.numpy.return_value = np.array([0.1, 0.2])
        mock_pipeline_instance.return_value = [mock_chunk]

        # Pre-cache the pipeline
        tts_mod._pipeline = mock_pipeline_instance

        generate_tts_audio("Hello")
        generate_tts_audio("World")

        # KPipeline constructor should NOT have been called since we pre-cached
        mock_pipeline_class.assert_not_called()
        # But the pipeline should have been called twice
        assert mock_pipeline_instance.call_count == 2

        # Cleanup
        tts_mod._pipeline = None


if __name__ == '__main__':
    pytest.main([__file__, '-v'])
