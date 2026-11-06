#!/usr/bin/env python3
"""Reflex: your session cost over seven days. Show tier.

Reads the current person's session records from the last seven days, today
included, and only the files whose names fall in that window. A priced record
counts under its harness (a record priced at list price is a Codex session);
an unpriced record counts apart, with the input tokens from its Cost section.
Prints one line, leaving out the parts that are zero, and nothing without
records. Numbers only: no topic, branch or prompt text.
"""
import datetime
import json
import math
import os
import re
import sys
from pathlib import Path

DAYS = 7
READ_LIMIT = 256 * 1024
PRICED = ("ledger", "estimate", "list price")
LABELS = {"claude": "Claude", "codex": "Codex", "pi": "Pi", "prime": "Prime", "other": "Other"}
TOKENS = re.compile(r"^- tokens: (\d+) input\b", re.M)


def front_matter(text):
    if not text.startswith("---\n"):
        return {}
    block = text[4:].partition("\n---")[0]
    fields = {}
    for line in block.splitlines():
        key, sep, value = line.partition(":")
        if not sep:
            continue
        value = value.strip()
        try:
            value = json.loads(value)
        except ValueError:
            pass
        fields[key.strip()] = value
    return fields


def amount(value):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return 0.0
    return number if math.isfinite(number) and number > 0 else 0.0


def compact(count):
    value, unit = float(count), ""
    for name in ("K", "M", "B"):
        if round(value, 1) < 1000:
            break
        value, unit = value / 1000, name
    return (f"{value:.1f}".removesuffix(".0") if unit else str(count)) + unit


def main():
    memory = os.environ.get("EGREGORE_MEMORY", "")
    author = re.sub(r"[^a-z0-9_-]", "", os.environ.get("EGREGORE_AUTHOR", "").strip().lower())
    sessions = Path(memory) / "sessions" if memory else None
    if not author or sessions is None or not sessions.is_dir():
        return 0
    today = datetime.date.today()
    priced = dict.fromkeys(LABELS.values(), 0.0)
    unpriced, tokens, seen = 0, 0, set()
    for offset in range(DAYS):
        day = today - datetime.timedelta(days=offset)
        try:
            paths = sorted((sessions / day.strftime("%Y-%m")).glob(day.strftime("%d-") + author + "-*.md"))
        except OSError:
            continue
        for path in paths:
            try:
                with path.open("rb") as stream:
                    text = stream.read(READ_LIMIT).decode("utf-8", errors="replace")
            except OSError:
                continue
            meta = front_matter(text)
            owner = str(meta.get("from", "")).strip().lower()
            # Producer-bearing records are never a person's session, including
            # malformed metadata and records copied without a private adapter.
            if any(key.strip().strip("\"'").casefold() in
                   {"producer", "producer_principal_id", "producer_identity", "record_owner_actor_id", "subject_kind"}
                   and (key != "subject_kind" or value != "human-session") for key, value in meta.items()):
                continue
            session = str(meta.get("session", path.name))
            if meta.get("kind") != "session-record" or owner != author or session in seen:
                continue
            seen.add(session)
            source = meta.get("cost_source", "estimate")
            if source in PRICED:
                harness = "codex" if source == "list price" else str(meta.get("harness") or "claude").lower()
                priced[LABELS.get(harness, "Other")] += amount(meta.get("cost_usd"))
                continue
            unpriced += 1
            match = TOKENS.search(text.partition("\n## Cost\n")[2])
            tokens += int(match.group(1)) if match else 0
    parts = []
    total = sum(priced.values())
    if round(total, 2) > 0:
        split = ", ".join(f"{label} ${value:,.2f}" for label, value in priced.items() if round(value, 2) > 0)
        parts.append(f"${total:,.2f} priced ({split})")
    if unpriced:
        part = f"{unpriced} unpriced session" + ("" if unpriced == 1 else "s")
        parts.append(part + (f", {compact(tokens)} input tokens" if tokens else ""))
    if parts:
        print("7 days: " + " · ".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
