"""``artifacts find|list`` and ``package``: read surfaces that print only through ``held.emit``.

``artifacts`` ranks what someone generated as ``bin/artifacts.sh`` did (a word in the title, topics
or file name 8, a mention 1), as an index sees it, and prints a row only when the reader may read
every path it names: the document and the source it was rendered from. A hosted-index row carries a
url, no path: it maps to the artifact file registered for that url and is dropped when there is none
or it is refused. ``package`` prints stdin the same way for shell read surfaces (graph-op named reads).
"""

from __future__ import annotations

import argparse
from datetime import date, timedelta
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from . import harness_cli, held
from .contracts import Permission
from .policy import allows
from .runtime import local_runtime

CORPUS = ("artifacts", "handoffs", "knowledge/decisions", "knowledge/findings", "knowledge/patterns")
STOP = frozenset("the a an is for and or in of to on with our we my me i where".split())
PATH_KEYS = ("evidencePath", "filePath", "canonical_path")
TAGS = (("handoffs/outbound/", "emissary"), ("handoffs/", "handoff"), ("knowledge/decisions/", "decision"),
        ("knowledge/findings/", "finding"), ("knowledge/patterns/", "pattern"))
WINDOWS = (  # a relative-time phrase in a query: (pattern, days back or None, whether it bounds both ends)
    (r"(\d+) +(days?|weeks?) +ago", None, False), (r"(?:last|past) +(\d+) +(days?|weeks?)", None, False),
    (r"yesterday", 1, True), (r"today", 0, True), (r"(?:this|last|past) +week", 7, False),
    (r"(?:this|last|past) +month", 31, False), (r"recently|recent|lately", 14, False))
GRAPH_FIND = """MATCH (a:Artifact) WHERE any(w IN $words WHERE toLower(a.title) CONTAINS w
    OR toLower(coalesce(a.excerpt,"")) CONTAINS w OR any(t IN coalesce(a.topics,[]) WHERE toLower(t) CONTAINS w))
  AND ($since = "" OR (a.created IS NOT NULL AND a.created >= datetime($since)))
  AND ($until = "" OR (a.created IS NOT NULL AND a.created <= datetime($until + "T23:59:59")))
WITH a, reduce(s=0, w IN $words | s + (CASE WHEN toLower(a.title) CONTAINS w THEN 8 ELSE 0 END)
  + (CASE WHEN any(t IN coalesce(a.topics,[]) WHERE toLower(t) CONTAINS w) THEN 5 ELSE 0 END)
  + (CASE WHEN toLower(coalesce(a.excerpt,"")) CONTAINS w THEN 1 ELSE 0 END)) AS score
OPTIONAL MATCH (a)-[:CONTRIBUTED_BY]->(p:Person) OPTIONAL MATCH (a)-[:PART_OF]->(q:Quest)
RETURN a.title AS title, a.url AS url, a.type AS type, score, collect(DISTINCT p.name)[0] AS author,
  collect(DISTINCT q.title)[0] AS quest, CASE WHEN a.created IS NOT NULL THEN toString(date(a.created)) ELSE "" END AS created
ORDER BY score DESC, created DESC LIMIT 8"""


def register(commands) -> None:
    artifacts = commands.add_parser("artifacts", help="find what you generated, by name or content")
    verbs = artifacts.add_subparsers(dest="artifacts_verb", required=True)
    find = verbs.add_parser("find", help="rank matches; --since/--until/--on D bound the dates")
    for bound in ("--since", "--until", "--on"):
        find.add_argument(bound, default="")
    find.add_argument("words", nargs=argparse.REMAINDER)
    listing = verbs.add_parser("list", help="the most recently recorded artifacts")
    listing.add_argument("n", nargs="?", type=int, default=10)
    package = commands.add_parser("package", help="print JSON or text from stdin as you may see it")
    for parser, handler in ((find, _find), (listing, _list), (package, _package)):
        parser.add_argument("--harness", default=os.environ.get("EGREGORE_RUNTIME", "shell"))
        parser.set_defaults(handler=handler)


def _reader(args):
    root = harness_cli._root()
    runtime = local_runtime(root, push_remote=False)
    decision = runtime.authorize(harness_cli._actor(runtime, root, args.harness), Permission.READ)
    return root, runtime.canonical_root, decision


def _memory_path(path: str) -> str:
    return "memory/" + path.removeprefix("memory/")


def _corpus(memory: Path):
    for folder in CORPUS:
        for directory, _, names in os.walk(memory / folder):
            yield from (Path(directory) / name for name in sorted(names) if name.endswith(".md") and name != "index.md")


def _frontmatter(text: str) -> list[str]:
    """The lines of the frontmatter that opens a document; a ``---`` pair further down is body (a url there
    registers nothing)."""
    lines = text.splitlines()
    end = next((at for at, line in enumerate(lines[1:], 1) if line == "---"), 0) if lines[:1] == ["---"] else 0
    return lines[1:end]


def _field(text: str, key: str) -> str:
    found = next((line for line in _frontmatter(text) if line.lower().startswith(key + ":")), "")
    return found.split(":", 1)[1].lstrip() if found else ""


def _row(memory: Path, path: Path, text: str) -> tuple[dict, tuple[str, ...]]:
    """A document's row and every memory path it names: itself, and the source it was rendered from."""
    rel = "memory/" + path.relative_to(memory).as_posix()
    heading = next((line.lstrip("#").lstrip(" ") for line in text.splitlines() if line.startswith("# ")), "")
    link = re.search(r'https://egregore\.xyz/[^ )>"\n]+', text)
    tag = next((name for prefix, name in TAGS if rel.startswith("memory/" + prefix)), "") or _field(text, "type")
    source = _field(text, "source").strip().strip("'\"")
    return ({"tag": tag or "artifact", "title": _field(text, "title") or heading or path.stem, "rel": rel,
             "url": _field(text, "url") or (link.group() if link else "")},
            (rel, *((source,) if source.startswith("memory/") else ())))


def _date(path: Path, text: str) -> str:
    if found := re.match(r"\d{4}-\d{2}-\d{2}", path.name):
        return found.group()
    if re.fullmatch(r"\d{4}-\d{2}", path.parent.name) and (day := re.match(r"(\d{2})-", path.name)):
        return f"{path.parent.name}-{day.group(1)}"
    dated = (re.search(r"\d{4}-\d{2}-\d{2}", line) for line in _frontmatter(text) if line.lower().startswith("date:"))
    return next((found.group() for found in dated if found), "")


def _first(decision, memory: Path, ranked, limit: int) -> list[dict]:
    """The first ``limit`` rows the decision admits, in rank order, each packaged under the paths it names."""
    shown = []
    for row, paths in ranked:
        if len(shown) == limit:
            break
        if (kept := held.package(decision, row, root=memory, paths=paths)) is not None:
            shown.append(kept)
    return shown


def _words(query: str) -> list[str]:
    words = [word for word in re.sub(r"[^a-z0-9]", " ", query.lower()).split() if len(word) >= 3 and word not in STOP]
    return words or [query.lower()]


def _window(query: str) -> tuple[str, str, str]:
    """(since, until, the query without its time phrase), read from a relative-time phrase or a date."""
    lowered, today = query.lower(), date.today()
    for pattern, days, both in WINDOWS:
        if found := re.search(pattern, lowered):
            if days is None:
                days = int(found.group(1)) * (7 if found.group(2).startswith("week") else 1)
            since = (today - timedelta(days=days)).isoformat()
            return since, since if both else "", re.sub(pattern, "", lowered)
    if found := re.search(r"\d{4}-\d{2}-\d{2}", lowered):
        return found.group(), found.group(), lowered.replace(found.group(), "")
    return "", "", lowered


def _label(since: str, until: str) -> str:
    if since and since == until:
        return f" · on {since}"
    return f" · {since}..{until}" if since and until else f" · since {since}" if since else f" · until {until}" if until else ""


def _grep(memory: Path, decision, query: str, since: str, until: str) -> str:
    words = _words(query)
    scored = []
    for path in _corpus(memory):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        lowered = text.lower()
        if not any(word in lowered for word in words):
            continue
        day = _date(path, text)
        if (since or until) and (not day or (since and day < since) or (until and day > until)):
            continue
        header = "\n".join(line for line in text.splitlines()[:25]
                           if re.match(r"(?i)title:|topics:|# ", line)).lower() + "\n" + path.name.lower()
        hits = [8 if word in header else 1 for word in words if word in header or word in lowered]
        scored.append((len(hits), sum(hits), day or "0000-00-00", path, text))
    scored.sort(key=lambda row: row[3])  # equal ranks keep path order, as sort's last resort does
    scored.sort(key=lambda row: row[2], reverse=True)
    scored.sort(key=lambda row: (row[0], row[1]), reverse=True)
    ranked = ((dict(row, matched=matched, day=day), paths) for matched, _, day, path, text in scored
              for row, paths in (_row(memory, path, text),))
    lines = [f'⌕ artifacts · grep-rank · "{query}"{_label(since, until)}', ""]
    for row in _first(decision, memory, ranked, 8):
        lines += [f"  ● [{row['tag']}] {row['title']}", *([f"    {row['url']}"] if row["url"] else []),
                  f"    {row['rel']}  ({row['matched']}/{len(words)} matched · {row['day']})", ""]
    return "\n".join(lines if len(lines) > 2 else lines + ["  no matches across artifacts / handoffs / knowledge."])


def _registered(memory: Path) -> dict[str, list[tuple[dict, tuple[str, ...]]]]:
    """Each url recorded in a registered artifact file, with the files that record it and the paths they name."""
    found: dict[str, list] = {}
    for path in _corpus(memory):
        if path.relative_to(memory).parts[0] == "artifacts":
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            if url := _field(text, "url").strip().strip("'\""):
                found.setdefault(url, []).append(_row(memory, path, text))
    return found


def _graph(root: Path, memory: Path, decision, query: str, since: str, until: str) -> str:
    try:
        answer = subprocess.run(["bash", str(root / "bin/graph.sh"), "query", GRAPH_FIND,
                                 json.dumps({"words": _words(query), "since": since, "until": until})],
                                capture_output=True, text=True, timeout=60, check=False).stdout
        values = json.loads(answer).get("values") or []
    except (OSError, ValueError, AttributeError, subprocess.SubprocessError):
        return ""
    registry, ranked = _registered(memory), []
    for value in values:
        title, url, kind, score, author, quest, created = (list(value) + [None] * 7)[:7]
        files = registry.get(str(url or ""), [])
        if files:  # a url no registered file records is dropped: nothing decides it
            paths = tuple(dict.fromkeys(path for _, named in files for path in named))
            ranked.append(({"title": title or "(untitled)", "url": url, "tag": kind or "artifact", "score": score,
                            "author": author or "", "quest": quest or "", "created": created or ""}, paths))
    lines = []
    for row in _first(decision, memory, ranked, 8):
        detail = "".join(f" · {part}" for part in (row["created"], row["author"] and f"by {row['author']}", row["quest"]) if part)
        lines += [f"  ● [{row['tag']}] {row['title']}", f"    {row['url']}",
                  f"    graph · score {json.dumps(row['score'])}{detail}", ""]
    return "\n".join([f'⌕ artifacts · relationships · "{query}"{_label(since, until)}', "", *lines]) if lines else ""


def _find(args) -> int:
    since, until = args.since or args.on, args.until or args.on
    words, rest = list(args.words), []
    while words:
        word = words.pop(0)
        if word in ("--since", "--until", "--on") and words:
            value = words.pop(0)
            since = value if word in ("--since", "--on") else since
            until = value if word in ("--until", "--on") else until
        elif word != "--":
            rest.append(word)
    query = " ".join(rest)
    if not query:
        raise ValueError("usage: artifacts find [--since D|--until D|--on D] <query>")
    if not since and not until:
        since, until, cleaned = _window(query)
        query = cleaned.strip() or query
    root, memory, decision = _reader(args)
    if not memory.is_dir():
        return held.emit(decision, "(no memory linked)", root=memory, render=str)
    mode = os.environ.get("EGREGORE_MODE") or _mode(root)
    text = (_graph(root, memory, decision, query, since, until) if mode != "local" else "") or \
        _grep(memory, decision, query, since, until)
    return held.emit(decision, text, root=memory, render=str)


def _mode(root: Path) -> str:
    try:
        return str(json.loads((root / "egregore.json").read_text(encoding="utf-8")).get("mode") or "connected")
    except (OSError, ValueError, AttributeError):
        return "connected"


def _list(args) -> int:
    root, memory, decision = _reader(args)
    if not memory.is_dir():
        return held.emit(decision, "(no memory linked)", root=memory, render=str)

    def ranked():
        for path in sorted(_corpus(memory), key=lambda path: path.stat().st_mtime, reverse=True):
            yield _row(memory, path, path.read_text(encoding="utf-8", errors="replace"))
    rows = _first(decision, memory, ranked(), args.n)
    return held.emit(decision, "\n".join(f"  ● [{row['tag']:<8}] {row['title'][:52]:<52} {row['url']}" for row in rows),
                     root=memory, render=str)


def _admitted(decision, memory: Path, value):
    """``value`` without each object naming a memory file the decision refuses (``PATH_KEYS``) and each such
    path listed under a key ending in ``Paths``; None when ``value`` itself names one."""
    def ok(path) -> bool:
        return not isinstance(path, str) or not path or allows(decision, _memory_path(path), root=memory)
    if isinstance(value, dict):
        if not all(ok(value.get(key)) for key in PATH_KEYS):
            return None
        return {key: [path for path in item if ok(path)] if key.endswith("Paths") and isinstance(item, list)
                else _admitted(decision, memory, item) for key, item in value.items()}
    if isinstance(value, list):  # a row no path decides is dropped whole when it names held material
        kept = [(item, _admitted(decision, memory, item)) for item in value]
        return [shown for item, shown in kept if (shown is not None or item is None) and not (
            _pathless(item) and held.redact(decision, item, root=memory) != item)]
    return value


def _pathless(item) -> bool:
    """A row no path decides: a list, or an object whose path keys are absent, null or empty."""
    return isinstance(item, list) or isinstance(item, dict) and not any(
        isinstance(item.get(key), str) and item.get(key) for key in PATH_KEYS)


class _Repeated(ValueError):
    """A JSON object whose key repeats: one value would be judged, another printed."""


ESCAPED = re.compile(r"\\u([0-9a-fA-F]{4})")


def _unique(pairs) -> dict:
    if len({key for key, _ in pairs}) < len(pairs):
        raise _Repeated("a repeated key")
    return dict(pairs)


def _names_escaped(decision, memory: Path, raw: str) -> bool:
    """Whether text names held material once its JSON escapes are read, as the reader of a JSON-looking text
    would read them."""
    decoded = ESCAPED.sub(lambda found: chr(int(found.group(1), 16)), raw)
    try:
        return decoded != raw and held.redact(decision, decoded, root=memory) != decoded
    except held.RedactionError:
        return True


def _package(args) -> int:
    raw = sys.stdin.read()
    _, memory, decision = _reader(args)
    try:
        value = json.loads(raw, object_pairs_hook=_unique)
    except _Repeated:  # nothing is printed rather than a value that was never judged
        return held.emit(decision, None, root=memory)
    except ValueError:
        return held.emit(decision, None if _names_escaped(decision, memory, raw) else raw, root=memory, render=str,
                         end="")
    return held.emit(decision, _admitted(decision, memory, value), root=memory, end="", render=lambda shown:
                     raw if shown == value else json.dumps(shown, ensure_ascii=False, indent=2) + "\n")  # unchanged: as read
