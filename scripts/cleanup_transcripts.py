#!/usr/bin/env python3
"""Delete Claude Code transcripts with 2 or fewer messages."""

import os
import json
import glob
import shutil

base = os.path.expanduser("~/.claude/projects")
files = glob.glob(os.path.join(base, "*", "*.jsonl"))

deleted = 0
for f in files:
    if "/subagents/" in f:
        continue
    msg_count = 0
    try:
        with open(f) as fh:
            for line in fh:
                line = line.strip()
                if not line:
                    continue
                obj = json.loads(line)
                if obj.get("type") in ("user", "assistant"):
                    msg_count += 1
    except Exception:
        continue
    if msg_count <= 2:
        os.remove(f)
        # Also remove associated subagents dir if it exists
        session_dir = os.path.join(
            os.path.dirname(f),
            os.path.splitext(os.path.basename(f))[0],
        )
        if os.path.isdir(session_dir):
            shutil.rmtree(session_dir)
        deleted += 1

print(f"Deleted {deleted} transcripts with ≤2 messages")
print(f"Scanned {len([f for f in files if '/subagents/' not in f])} total transcripts")
