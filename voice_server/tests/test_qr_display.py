import pytest
from qr_display import get_local_ip, generate_qr_code, get_websocket_url


class TestQRDisplay:
    def test_get_local_ip_returns_valid_ip(self):
        """IP should be IPv4 format, not localhost"""
        ip = get_local_ip()
        assert ip is not None
        assert not ip.startswith("127.")
        parts = ip.split(".")
        assert len(parts) == 4
        assert all(p.isdigit() and 0 <= int(p) <= 255 for p in parts)

    def test_get_websocket_url(self):
        """URL should be ws:// format with port"""
        url = get_websocket_url("192.168.1.42", 8765)
        assert url == "ws://192.168.1.42:8765"

    def test_generate_qr_code_returns_string(self):
        """QR code should be non-empty ASCII art"""
        qr = generate_qr_code("ws://192.168.1.42:8765")
        assert isinstance(qr, str)
        assert len(qr) > 100  # QR codes are substantial
        assert "█" in qr or "#" in qr  # Contains block characters
