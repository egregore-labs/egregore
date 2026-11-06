#!/usr/bin/env python3
"""Run the reflex probes and print their lines for the startup card.

A reflex is a probe with a tier. Each probe is a file in bin/reflexes/ (a
.sh or .py file, or any executable), run in name order with the environment
below. A probe prints nothing, one line or two lines on stdout: a fact about
yesterday (show), or a fact ending in the command to run (propose). The
act tier never prints from a probe; it lives in the path it governs.

The runner never fails the card. A probe that exits non-zero, prints
nothing, or runs past its budget is silent; --debug names the reason on
stderr. Probes run one at a time; the total budget stops launching the rest.

Environment given to every probe (on top of the caller's):
  EGREGORE_ROOT      the project root
  EGREGORE_MEMORY    the memory directory (may not exist)
  EGREGORE_STATE     the per-instance state file (.egregore-state.json)
  EGREGORE_AUTHOR    the GitHub username of the person, when known
  EGREGORE_HARNESS   claude, codex, pi or prime

Sessions started minutes apart print the same card, so the runner keeps the
last card per harness in .egregore/runtime/reflexes/ and reprints it while
the probes' inputs are unchanged and the card is under CACHE_SECONDS old
(see cache_key). --debug, a sandbox marker, or a run in which a probe was
cut off or never started skips the cache.

Usage: reflexes.py --root DIR [--dir DIR] [--memory DIR] [--author NAME]
                   [--harness NAME] [--budget S] [--total S] [--debug]
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from pathlib import Path

PROBE_BUDGET = 1.0
TOTAL_BUDGET = 3.0
MAX_LINES = 2
MAX_CHARS = 160
SIGIL = "  ◦ "
CONTROL = re.compile(r"[\x00-\x08\x0b-\x1f\x7f]")
CACHE_SCHEMA = "egregore-reflex-card/v1"
CACHE_SECONDS = 600
# What a probe reads from the caller's environment to find dates, tools and state.
KEY_ENVIRONMENT = ("HOME", "PATH", "TZ", "EGREGORE_QMD_RUNTIME_DIR", "EGREGORE_TELEMETRY_DIR")
# What a probe reads from the state file: the person's names and the records switch.
KEY_STATE = ("github_username", "display_name", "actor_id", "session_records_enabled")


def probes(directory):
    try:
        entries = sorted(path for path in Path(directory).iterdir() if path.is_file())
    except OSError:
        return []
    chosen = []
    for path in entries:
        if path.name.startswith((".", "_")) or path.name.lower().startswith("readme"):
            continue
        if path.suffix in (".sh", ".py") or os.access(path, os.X_OK):
            chosen.append(path)
    return chosen


def command_for(path):
    if path.suffix == ".sh":
        return ["bash", str(path)]
    if path.suffix == ".py":
        return [sys.executable or "python3", str(path)]
    return [str(path)]


def clean(line):
    line = CONTROL.sub(" ", line).strip()
    return line if len(line) <= MAX_CHARS else line[: MAX_CHARS - 1] + "…"


def run_probe(path, env, budget):
    try:
        result = subprocess.run(command_for(path), env=env, capture_output=True, text=True,
                                timeout=budget, stdin=subprocess.DEVNULL, errors="replace")
    except subprocess.TimeoutExpired:
        return [], "past its budget"
    except OSError as exc:
        return [], f"could not run: {exc}"
    if result.returncode != 0:
        return [], f"exit {result.returncode}"
    lines = [clean(line) for line in result.stdout.splitlines()]
    lines = [line for line in lines if line]
    if not lines:
        return [], "printed nothing"
    return lines[:MAX_LINES], None


def read_json(path):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def author_from_state(state_path):
    state = read_json(state_path)
    return str(state.get("github_username") or state.get("display_name") or "")


def sandboxed(env):
    """The positive markers bin/reflexes/20-sandbox.sh answers to; its write
    test is live, so a sandboxed card is never reprinted."""
    marker = env.get("CODEX_SANDBOX", "").lower()
    return marker not in ("", "none", "false", "0") or bool(env.get("APP_SANDBOX_CONTAINER_ID"))


def version(path):
    try:
        info = os.lstat(path)
    except OSError:
        return None
    return [info.st_ino, info.st_size, info.st_mtime_ns]


def entries(top, recursive):
    """Each entry under top with its version, in a stable order. A symlinked
    directory is listed, not followed; the bytecode cache is no input."""
    found = []
    for folder, names, files in os.walk(top):
        names[:] = sorted(name for name in names if name != "__pycache__")
        for name in names + sorted(files):
            path = os.path.join(folder, name)
            found.append([os.path.relpath(path, top), version(path)])
        if not recursive:
            break
    return found


def cache_key(args, root, directory, memory):
    """What the probes read that costs a few milliseconds to check: the
    runner's arguments, the local date their windows count from, the
    environment that selects tools and state, the probe and library files,
    every file under memory/sessions (records, the open-items and gate
    ledgers), the features in egregore.json, the state fields they read, and
    nightly's own cache. Memory lookups under .egregore/runtime and CI runs
    behind nightly's cache are left out; CACHE_SECONDS bounds their age.
    The state file itself changes on most startups, so only its fields count."""
    state = read_json(root / ".egregore-state.json")
    material = {
        "schema": CACHE_SCHEMA,
        "runner": [str(root), str(directory), str(memory), args.author, args.harness, args.budget, args.total,
                   version(Path(__file__))],
        "day": datetime.date.today().isoformat(),
        "environment": [os.environ.get(name) for name in KEY_ENVIRONMENT],
        "probes": entries(directory, False),
        "code": entries(root / "bin" / "lib", False) + [version(root / "egregore_runtime" / "installation.py")],
        "records": entries(memory / "sessions", True),
        "features": read_json(root / "egregore.json").get("features"),
        "state": [state.get(name) for name in KEY_STATE],
        "nightly": version(root / "tmp" / "reflexes" / "nightly.json"),
    }
    return hashlib.sha256(json.dumps(material, sort_keys=True, default=str).encode()).hexdigest()


def card_path(root, harness):
    return root / ".egregore" / "runtime" / "reflexes" / f"card-{re.sub(r'[^a-z0-9-]', '', harness.lower()) or 'other'}.json"


def cached_card(path, key):
    try:
        card = json.loads(path.read_text(encoding="utf-8"))
        fresh = 0 <= time.time() - card["at"] <= CACHE_SECONDS
        if card.get("schema") != CACHE_SCHEMA or card.get("key") != key or not fresh:
            return None
        if not isinstance(card["lines"], list) or not all(isinstance(line, str) for line in card["lines"]):
            return None
        return [line for line in map(clean, card["lines"]) if line]
    except Exception:  # an unreadable card is a miss; the runner never fails the card
        return None


def store_card(path, key, at, lines):
    try:
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        descriptor, temporary = tempfile.mkstemp(prefix=".card.", dir=path.parent)
        try:
            with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
                json.dump({"schema": CACHE_SCHEMA, "key": key, "at": at, "lines": lines}, stream)
            os.replace(temporary, path)
        except BaseException:
            os.unlink(temporary)
            raise
    except Exception:  # an unwritable runtime directory only costs the next card its reuse
        pass


def main(argv=None):
    parser = argparse.ArgumentParser(description="run the reflex probes for the startup card")
    parser.add_argument("--root", required=True)
    parser.add_argument("--dir", help="probe directory (default: <root>/bin/reflexes)")
    parser.add_argument("--memory", help="memory directory (default: <root>/memory)")
    parser.add_argument("--author", default="")
    parser.add_argument("--harness", default=os.environ.get("EGREGORE_HARNESS", "claude"))
    parser.add_argument("--budget", type=float, default=PROBE_BUDGET, help="seconds per probe")
    parser.add_argument("--total", type=float, default=TOTAL_BUDGET, help="seconds for all probes")
    parser.add_argument("--debug", action="store_true", help="name silent probes on stderr")
    args = parser.parse_args(argv)

    root = Path(args.root).resolve()
    directory = Path(args.dir) if args.dir else root / "bin" / "reflexes"
    memory = Path(args.memory) if args.memory else root / "memory"
    state = root / ".egregore-state.json"
    env = dict(os.environ)
    env.update({
        "EGREGORE_ROOT": str(root),
        "EGREGORE_MEMORY": str(memory),
        "EGREGORE_STATE": str(state),
        "EGREGORE_AUTHOR": args.author or author_from_state(state),
        "EGREGORE_HARNESS": args.harness,
    })

    key, card = None, card_path(root, args.harness)
    if not args.debug and not sandboxed(env):
        try:
            key = cache_key(args, root, directory, memory)
        except Exception:  # without a key the probes simply run
            key = None
    if key:
        lines = cached_card(card, key)
        if lines is not None:
            for line in lines:
                print(SIGIL + line)
            return 0

    at, started, printed, settled = time.time(), time.monotonic(), [], True
    for path in probes(directory):
        if time.monotonic() - started > args.total:
            settled = False
            if args.debug:
                print(f"reflex {path.name}: skipped, total budget spent", file=sys.stderr)
            continue
        lines, reason = run_probe(path, env, args.budget)
        if reason and args.debug:
            print(f"reflex {path.name}: silent, {reason}", file=sys.stderr)
        # A probe cut off or never started may speak next time; keep no card of it.
        if reason and not reason.startswith(("exit ", "printed nothing")):
            settled = False
        for line in lines:
            print(SIGIL + line)
        printed.extend(lines)
    if key and settled:
        try:
            unchanged = cache_key(args, root, directory, memory) == key
        except Exception:
            unchanged = False
        # An input that moved while the probes read it would file their lines
        # under a key that no longer describes them.
        if unchanged:
            store_card(card, key, at, printed)
    return 0


if __name__ == "__main__":
    sys.exit(main())
