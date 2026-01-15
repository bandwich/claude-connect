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
        """QR code should be non-empty with ANSI codes"""
        qr = generate_qr_code("ws://192.168.1.42:8765")
        assert isinstance(qr, str)
        assert len(qr) > 100
        assert "\033[40m" in qr  # Black background ANSI code

    def test_qr_code_is_scannable(self):
        """QR code must be decodable - this verifies it will scan on a phone"""
        import re
        from PIL import Image, ImageDraw
        from pyzbar.pyzbar import decode

        url = "ws://192.168.1.42:8765"
        qr_output = generate_qr_code(url)

        # Parse ANSI codes to extract color information
        # Format: \033[40m (black) or \033[47m (white) followed by 2 spaces
        lines = qr_output.split("\n")
        cell_size = 10

        # Count cells per row by counting ANSI sequences
        first_line = lines[0]
        cells_per_row = len(re.findall(r'\033\[\d+m  ', first_line))

        width = cells_per_row * cell_size
        height = len(lines) * cell_size

        img = Image.new("RGB", (width, height), "white")
        draw = ImageDraw.Draw(img)

        for y, line in enumerate(lines):
            cells = re.findall(r'\033\[(\d+)m  ', line)
            for x, code in enumerate(cells):
                if code == "40":  # Black background
                    draw.rectangle(
                        [x * cell_size, y * cell_size, (x + 1) * cell_size, (y + 1) * cell_size],
                        fill="black",
                    )

        decoded = decode(img)
        assert len(decoded) == 1, "QR code must be decodable"
        assert decoded[0].data.decode() == url, "Decoded content must match original URL"
