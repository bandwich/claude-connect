# PyPI Publishing & Installation UX Design

## Goal

Make the server installable with `pipx install claude-connect` from PyPI. No git clone, no install script required. Interactive dependency check at startup handles tmux.

## Package Naming

Rename everything from `claude-voice-server` / `hands-free` to `claude-connect`:
- PyPI package name: `claude-connect`
- CLI command: `claude-connect` (unchanged)
- pyproject.toml `name`: `claude-connect`
- README title and references
- GitHub repo description (manual)

## Installation Flow

```
pipx install claude-connect
claude-connect
```

That's it. No install script needed for the happy path.

## Startup Dependency Check

When `claude-connect` runs, before starting the server, check for tmux. If missing, present an interactive menu:

```
Claude Connect requires tmux, which is not currently installed.

How would you like to install it?
  [1] Install via Homebrew (recommended)
  [2] Install manually

> 1
Installing tmux via Homebrew...
Done!

Starting Claude Connect...
```

**Option 1 (Homebrew):**
- If `brew` is available: run `brew install tmux`, then continue startup
- If `brew` is not available: explain Homebrew is needed, show install URL (https://brew.sh), exit

**Option 2 (Manual):**
- Print: "Install tmux and run claude-connect again. See https://github.com/tmux/tmux/wiki/Installing"
- Exit

**Implementation:** New module `voice_server/setup_check.py` with a `check_dependencies()` function called from `main()` before server start. Keeps the check isolated from server logic.

## pyproject.toml Changes

```toml
[project]
name = "claude-connect"
version = "0.1.0"
description = "Control Claude Code hands-free from your iPhone"
requires-python = ">=3.9"
# ... dependencies unchanged
```

## What Stays / What Goes

- **Keep:** `install.sh` — still useful for contributors/dev setup, but no longer the primary install path. Update it to install from PyPI instead of local path.
- **Remove from README:** install.sh as the primary method. Move to a "Development" section.
- **Remove:** zbar from install.sh brew dependencies (only needed for tests)

## README Updates

The Setup section becomes:

```markdown
### Server (Mac)

\```bash
pipx install claude-connect
claude-connect
\```

Scan the QR code from the iOS app to connect.
```

Development/contributing section documents install.sh for local dev.

## Files to Change

1. `pyproject.toml` — rename to `claude-connect`
2. `voice_server/ios_server.py` — call dependency check in `main()`
3. `voice_server/setup_check.py` — new file, interactive tmux check
4. `README.md` — update install instructions, rename references
5. `CLAUDE.md` — update package name references
6. `install.sh` — update to install from PyPI, remove zbar dep

## Publishing to PyPI

Manual first, automate later:

```bash
pip install build twine
python -m build
twine upload dist/*
```

Could add GitHub Actions for auto-publish on tag later.
