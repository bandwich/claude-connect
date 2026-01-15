"""QR code display for server startup"""
import socket
import qrcode


def get_local_ip() -> str:
    """Get the local IP address for LAN connections.

    Uses UDP socket trick to find the IP that would be used
    to reach external hosts (works across network configs).
    """
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("8.8.8.8", 80))
        ip = s.getsockname()[0]
        s.close()
        return ip
    except Exception:
        return None


def get_websocket_url(ip: str, port: int) -> str:
    """Generate WebSocket URL from IP and port."""
    return f"ws://{ip}:{port}"


def generate_qr_code(url: str) -> str:
    """Generate ASCII QR code for terminal display.

    Uses ANSI background colors so line gaps don't break scanning.
    """
    BLACK_BG = "\033[40m"
    WHITE_BG = "\033[47m"
    RESET = "\033[0m"

    qr = qrcode.QRCode(
        version=1,
        error_correction=qrcode.constants.ERROR_CORRECT_M,
        box_size=1,
        border=4,
    )
    qr.add_data(url)
    qr.make(fit=True)

    matrix = qr.get_matrix()
    lines = []
    for row in matrix:
        line = ""
        for cell in row:
            bg = BLACK_BG if cell else WHITE_BG
            line += f"{bg}  "
        lines.append(line + RESET)
    return "\n".join(lines)


def print_startup_banner(ip: str, port: int):
    """Print startup banner with QR code."""
    url = get_websocket_url(ip, port)
    qr = generate_qr_code(url)

    print("\n" + "=" * 50)
    print("Claude Voice Server")
    print("=" * 50 + "\n")
    print(qr)
    print(f"\nScan QR code with Claude Voice app\n")
    print(f"{url}\n")
    print("Waiting for connection...")
    print("=" * 50 + "\n")
