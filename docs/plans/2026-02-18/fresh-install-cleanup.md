# Fresh Install Cleanup Plan

## Problems

### 1. `build/` directory is tracked in git (stale code)
`.gitignore` has `build/` but the directory is already tracked with stale compiled code. A fresh clone includes it, risking import confusion.

**Fix:** `git rm -r --cached build/` to untrack it.

### 2. `requirements.txt` is out of sync and redundant
- `pyproject.toml` has `aiohttp>=3.9.0` and `qrcode>=7.0` — both missing from `requirements.txt`
- pipx uses `pyproject.toml`, so `requirements.txt` is dead weight that misleads people into running `pip install -r requirements.txt` (which would be incomplete)

**Fix:** Delete `requirements.txt`. pyproject.toml is the single source of truth.

### 3. Hook setup is manual and undiscoverable
A fresh user must manually edit `~/.claude/settings.json` with absolute paths to the hook scripts. The README doesn't mention this at all, and CLAUDE.md documents it but a new user won't know to look there.

**Fix:** Add a hook auto-setup step to `install.sh` that:
- Detects the install path of the hooks (via pipx or the repo checkout)
- Writes/merges the PermissionRequest and PostToolUse hooks into `~/.claude/settings.json`
- Skips if hooks are already configured
- Prints a message about what was configured

### 4. `zbar` may not be needed
`install.sh` installs `zbar` via brew. `zbar` is a barcode/QR reading library — but the server generates QR codes (using the `qrcode` Python package, which doesn't need zbar) and the iOS app reads them natively via AVFoundation.

**Fix:** Verify zbar isn't imported/used anywhere. If not, remove from `install.sh`.

### 5. README doesn't mention `--force` for reinstall
If someone pulls updates and re-runs `./install.sh`, pipx refuses to overwrite. The `--force` flag exists but isn't documented.

**Fix:** Add a one-liner to README: `./install.sh --force` to update after pulling changes.

## Execution Order

1. Verify zbar usage (grep for it) — remove from install.sh if unused
2. `git rm -r --cached build/`
3. Delete `requirements.txt`
4. Add hook auto-setup to `install.sh`
5. Update README with reinstall note and brief hook mention
6. Commit
