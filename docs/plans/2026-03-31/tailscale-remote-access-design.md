# Tailscale Remote Access

Enable Claude Connect iOS app to connect to the Mac server from anywhere (cellular, different WiFi) using Tailscale, not just the same local network.

## Approach

Tailscale is a free private VPN (WireGuard-based) that gives each device a stable `100.x.x.x` IP reachable from anywhere. The user installs the Tailscale app on both Mac and iPhone, logs in once with the same account, and both devices join the same tailnet. The Claude Connect server detects the Tailscale IP and uses it in the QR code. The iOS app doesn't change — it connects to whatever IP is in the QR code.

## Components

### 1. Tailscale Detection — `server/infra/tailscale.py` (new)

Three functions:
- `is_tailscale_installed()` — `shutil.which("tailscale") is not None`
- `is_tailscale_running()` — runs `tailscale status --json`, returns True if `BackendState == "Running"`
- `get_tailscale_ip()` — runs `tailscale ip --4`, returns `100.x.x.x` string or None

### 2. Setup Flow — `server/infra/setup_check.py` (modified)

After tmux check, add optional Tailscale check:

- **Installed and running**: no output, proceed
- **Installed but not connected**: warn "Tailscale is installed but not connected. Run `tailscale up` to enable remote access." Proceed with local IP.
- **Not installed**: show explanation of what Tailscale is and what it adds, offer `[1] Install via Homebrew` / `[2] Skip`. If installed, print instructions for `tailscale up` and mention the Tailscale iOS app. Server continues either way.

### 3. IP Selection — `server/main.py` (modified)

At QR code display point (~line 1296):
1. Try `get_tailscale_ip()` — if it returns an IP, use it
2. Fall back to `get_local_ip()`
3. If neither works, show existing warning

`qr_display.py` unchanged — already takes an IP parameter.

### 4. No iOS Changes

The app scans a QR code containing a WebSocket URL. It doesn't know or care whether the IP is local or Tailscale.

## Testing

Unit tests for `tailscale.py` mocking `subprocess.run` and `shutil.which`:
- `test_is_tailscale_installed` — path vs None
- `test_is_tailscale_running` — Running vs Stopped vs error
- `test_get_tailscale_ip` — valid IP vs empty vs error

Test `setup_check.py` Tailscale prompt shown/skipped.

## Verification

1. Install Tailscale on Mac (`brew install tailscale`)
2. Run `tailscale up` (one-time browser login)
3. Install Tailscale iOS app, sign in with same account
4. Run `claude-connect` — QR code should show `100.x.x.x`
5. Turn off WiFi on phone, scan QR code over cellular
6. Confirm WebSocket connects and voice/text works

## Risk

Riskiest assumption: `tailscale ip --4` and `tailscale status --json` work reliably via Homebrew CLI on macOS. Verify by installing and testing the commands before writing code.
