#!/usr/bin/env python3
"""Reflex: refused shell shapes. Show tier.

Reads yesterday's session records of the current person and sums the
`worktree-guard refusals` counter from their Friction sections. Three or
more prints one line with the count and the pointer to the plain forms.
"""
import datetime
import os
import re
import sys
from pathlib import Path

COUNTER = re.compile(r"^- worktree-guard refusals: (\d+)\s*$", re.M)
FROM = re.compile(r"^from:\s*(.+?)\s*$", re.M)


def main():
    memory = os.environ.get("EGREGORE_MEMORY", "")
    author = os.environ.get("EGREGORE_AUTHOR", "").strip().casefold()
    sessions = Path(memory) / "sessions" if memory else None
    if sessions is None or not sessions.is_dir():
        return 0
    yesterday = datetime.date.today() - datetime.timedelta(days=1)
    folder = sessions / yesterday.strftime("%Y-%m")
    total, files = 0, 0
    try:
        paths = sorted(folder.glob(yesterday.strftime("%d-") + "*.md"))
    except OSError:
        return 0
    for path in paths:
        try:
            text = path.read_text(encoding="utf-8", errors="replace")[:200000]
        except OSError:
            continue
        head = text.partition("\n---")[0]
        owner = FROM.search(head)
        if author and owner and owner.group(1).strip("\"'").casefold() != author:
            continue
        match = COUNTER.search(text)
        if match:
            total += int(match.group(1))
            files += 1
    if total >= 3:
        noun = "session" if files == 1 else "sessions"
        print(f"{total} refused shell commands yesterday across {files} {noun} · plain forms: .claude/context/plain-shell.md")
    return 0


if __name__ == "__main__":
    sys.exit(main())
