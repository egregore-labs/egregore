#!/usr/bin/env python3
"""Read harness transcripts and derive local trails and shared record sections.

Only this module reads transcript JSONL. Instance admission is based on physical
paths for Claude and admitted header working directories for Codex and Pi.
Python 3.11+, standard library only.
"""
import argparse
import hashlib
import io
import itertools
import json
import math
import os
import re
import shlex
import stat
import sys
from collections import Counter, deque
from datetime import datetime
from pathlib import Path

SEARCH_RE = re.compile(r"\bsearch\.sh\s+(find|open|query|handoffs|investigate)\b")
KIND_RE = re.compile(r"--kind[ =]([a-z]+)")
SLEEP_RE = re.compile(r"^\s*sleep\s+(\d+(?:\.\d+)?)")
# Claude Code's worktree guard opens every refusal with this sentence, for a
# shell command it cannot prove stays in the worktree and for an edit aimed at
# the shared checkout alike. The texts, as found, are fixtures in the tests.
GUARD_RE = re.compile(r"(?:<tool_use_error>)?This session is isolated in the worktree ")
# Claude Code reports a command that ran and exited non-zero this way.
NONZERO_EXIT_RE = re.compile(r"Exit code -?0*[1-9]")
# A recall that cannot bind to its prompt: the episode binding is missing, or
# the private receipt carrying its evidence cannot be consumed. The receipt
# texts are raised in egregore_runtime/private_result.py.
BINDING_MARKERS = ("episode reference required", "binding unavailable",
                   "private receipt belongs to another native prompt",
                   "private receipt belongs to another native session",
                   "private receipt has no native prompt binding",
                   "private receipt is unavailable")
# A sandbox refuses an operation with these OS errors. The Runtime words a
# refused retrieval store itself (egregore_runtime/adapters/qmd.py), and when
# it detects a sandbox it says so: "is not writable (sandbox)" (qmd.py and
# sandbox.py) and "refused by the sandbox" (qmd.py). Permission denied counts
# only when it names the Runtime's lock or state directory.
SANDBOX_RE = re.compile(r"operation not permitted|\bEPERM\b|read-only file system"
                        r"|Local retrieval storage is unavailable"
                        r"|is not writable \(sandbox\)|refused by the sandbox"
                        r"|(?:permission denied|PermissionError)[^\n]*(?:lifecycle\.lock|\.egregore/(?:runtime|mind)/)",
                        re.I)
# Consecutive events further apart than this are idle time, not work.
ACTIVE_GAP_SECONDS = 300


def _ts(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() if value else None


def _mapping(value):
    return value if isinstance(value, dict) else {}


def _string(value, default=''):
    return value if isinstance(value, str) else default


def _number(value, default=0):
    try:
        return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) and value >= 0 else default
    except OverflowError:
        return default


def _inline(value):
    """Keep deterministic metadata on one line, without hiding path characters."""
    return re.sub(r'[\x00-\x1f\x7f]', lambda match: '\\u%04x' % ord(match.group()), _string(value))


def _text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(_string(b.get("text")) for b in content if isinstance(b, dict))
    return ""


def _pct(values, q):
    if not values:
        return None
    values = sorted(values)
    return values[min(len(values) - 1, int(round(q * (len(values) - 1))))]


def _add_event(spans, ts):
    """Extend the latest stretch of activity with an event, or open a new one."""
    if spans and spans[-1][0] <= ts and ts - spans[-1][1] < ACTIVE_GAP_SECONDS:
        spans[-1][1] = max(spans[-1][1], ts)
    else:
        spans.append([ts, ts])


def _merge_spans(spans):
    """Join stretches closer than the idle gap; out-of-order events fold in here."""
    merged = []
    for start, end in sorted(spans):
        if merged and start - merged[-1][1] < ACTIVE_GAP_SECONDS:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return merged


def _clock(seconds):
    minutes = int(seconds / 60)
    return f'{minutes // 60}h {minutes % 60}m' if minutes >= 60 else f'{minutes}m'


def _recall_failure(text, is_error):
    if any(marker in text for marker in BINDING_MARKERS):
        return "episode-binding"
    if is_error and SANDBOX_RE.search(text):
        return "sandbox"
    if "moved to the background" in text or "timed out" in text.lower():
        return "timeout"
    if "interrupted" in text:
        return "interrupted"
    return "error" if is_error else None


# The receipt attach hook (egregore_runtime/harness_cli.py) reports a failure
# as hook context, which Claude Code keeps in an attachment entry after the
# tool result rather than inside it.
ATTACH_FAILURE = "Runtime private result could not be attached:"


def _strings(value, limit=256):
    """Strings inside a parsed JSON value, breadth first and bounded; keeps nothing.

    At most `limit` values are visited, four levels deep, fifty children each,
    and each string is read to 4,000 characters.
    """
    queue, visited = deque([(value, 0)]), 0
    while queue and visited < limit:
        item, depth = queue.popleft()
        visited += 1
        if isinstance(item, str):
            yield item[:4000]
        elif depth < 4 and isinstance(item, (dict, list)):
            children = item.values() if isinstance(item, dict) else item
            queue.extend((child, depth + 1) for child in itertools.islice(children, 50))


def _attach_failure(attachment):
    """The recall failure kind of an attach-hook failure in an attachment, else None."""
    for text in _strings(attachment):
        start = text.find(ATTACH_FAILURE)
        if start >= 0:
            return _recall_failure(text[start:].split("\n", 1)[0], True)
    return None


# A hook asks the agent to put a question to the person in these words
# (.claude/hooks/admin-content-detector.sh). The request is decided when the
# agent calls AskUserQuestion before the person's next prompt.
DECISION_REQUEST = "Call AskUserQuestion now"
# A hook left undecided this many times in one session becomes an open item.
IGNORED_REQUESTS_RAISED = 3
# A hook's name is a word, never a phrase of its context: the text before the
# context's first colon, else its script's name, else Claude Code's hook label.
HOOK_NAME_RE = re.compile(r"[A-Za-z0-9][\w.:-]{0,63}", re.A)
HOOK_SCRIPT_RE = re.compile(r"([A-Za-z0-9][\w.-]{0,63})\.(?:sh|bash|zsh|py|mjs|cjs|js|ts|rb|pl)\b", re.A)
# A quoted stretch of one line, or one word.
QUOTED_OR_WORD_RE = re.compile(r"""(['"`])([^'"`\n]+)\1|\S+""")
FILE_NAME_RE = re.compile(r"[\w.-]{1,100}")
EXTENSION_RE = re.compile(r"\.\w{1,10}$")


def _bare(word):
    return word.lstrip("'\"`([{<").rstrip("'\"`)]}>,;:.!?")


def _path_like(text):
    """A slash, no scheme, and a path's start or a file name's end."""
    return ("/" in text and "://" not in text
            and (text.startswith(("/", "~/", "./", "../")) or bool(EXTENSION_RE.search(text))))


def _file_name(path):
    name = path.rstrip("/").rpartition("/")[2]
    return name if FILE_NAME_RE.fullmatch(name) and name.strip(".") else None


def _first_basename(text):
    """The file name of the first path in a hook's text, else None; never a
    directory. A quoted path is read whole, and only when its closing quote
    ends the path at whitespace or the end of a line; a quoted stretch with a
    slash is never read for paths inside it. An unquoted path ends at a line's
    end, or at a word that cannot continue it after a name with an extension;
    any other end is uncertain ("/private/Acme Corp/notes.md",
    '"/private/Acme"/notes.md'), and nothing is taken."""
    position = 0
    while (match := QUOTED_OR_WORD_RE.search(text, position)):
        position = match.end()
        if match.group(1):
            quoted = match.group(2)
            if "/" not in quoted:
                continue  # a quoted phrase that holds no path
            name = _file_name(quoted) if _path_like(quoted) else None
            ends = match.end() == len(text) or text[match.end()].isspace()
            if name and ends and (EXTENSION_RE.search(name) or not re.search(r"\s", quoted)):
                return name
            return None
        path = _bare(match.group())
        if not _path_like(path) or not path.rstrip("/"):
            continue
        name = _file_name(path)
        word = re.match(r"[ \t]*(\S*)", text[match.end():])[1]
        continues = "/" in _bare(word) or bool(EXTENSION_RE.search(_bare(word)))
        if name and (not word or (EXTENSION_RE.search(name) and not continues)):
            return name
        return None
    return None


def _decision_request(attachment):
    """A hook's request that the agent ask the person: the hook's name and the
    file name of the first path it names. Nothing else of the context is kept."""
    try:
        output = json.loads(_string(attachment.get("stdout")))
    except (ValueError, RecursionError):
        return None
    context = _string(_mapping(_mapping(output).get("hookSpecificOutput")).get("additionalContext"))
    if DECISION_REQUEST not in context:
        return None
    head, colon, _ = context.partition(":")
    script = HOOK_SCRIPT_RE.search(_string(attachment.get("command")))
    names = (head.strip() if colon else "", script[1] if script else "", _string(attachment.get("hookName")))
    return {"hook": next((name for name in names if HOOK_NAME_RE.fullmatch(name)), "hook"),
            "file": _first_basename(context)}


# $ per million tokens: input, output, cache read. Cache writes bill at 1.25x
# input for the 5-minute TTL and 2x for the 1-hour TTL. A request whose input
# (fresh plus cached) exceeds 200k tokens pays the long-context premium: the
# input side doubles and output costs 1.5x. Only the 1M-context variants reach it.
LONG_CONTEXT_TOKENS = 200_000
PRICES = {
    "claude-fable-5-1": (10.0, 50.0, 0.25),
    "claude-fable-5": (10.0, 50.0, 0.25),
    "claude-opus-5-5": (4.0, 20.0, 0.20),
    "claude-opus-5": (5.0, 25.0, 0.50),
    "claude-sonnet-5": (2.0, 10.0, 0.20),
    "claude-haiku-4-5": (1.0, 5.0, 0.10),
}
# OpenAI's published list (developers.openai.com/api/docs/pricing, read
# 2026-10-16), $ per million tokens: input, cached input, output; the first
# row up to 272K input tokens per request, the second above it. Codex counts
# its cached tokens inside its input. codex-auto-review is a label, not a
# model, so it has no row and its tokens stay unpriced.
CODEX_LONG_CONTEXT_TOKENS = 272_000
CODEX_PRICES = {
    "gpt-6-astra": ((10.00, 1.00, 50.00), (20.00, 2.00, 75.00)),
    "gpt-6-luna": ((0.10, 0.01, 0.50), (0.20, 0.02, 0.75)),
    "gpt-5.6-sol": ((4.00, 0.40, 20.00), (8.00, 0.80, 30.00)),
    "gpt-5.6-luna": ((0.20, 0.02, 1.20), (0.40, 0.04, 1.80)),
    "gpt-5.6-terra": ((2.00, 0.20, 12.00), (4.00, 0.40, 18.00)),
}


def estimate_cost(calls):
    """Price token usage when a session left no cost-state ledger."""
    total = 0.0
    for c in calls:
        if not isinstance(c, dict):
            continue
        price = PRICES.get(_string(c.get("model")).split("[")[0])
        if not price:
            continue
        c = {**c, **{key: _number(c.get(key)) for key in ("input", "output", "cache_read", "cache_write", "cache_write_1h")}}
        inp, out, read = price
        context = c["input"] + c["cache_read"] + c["cache_write"]
        if context > LONG_CONTEXT_TOKENS:
            inp, read, out = inp * 2, read * 2, out * 1.5
        one_hour = c["cache_write_1h"]
        five_min = (c["cache_write"] or 0) - one_hour
        total += (c["input"] * inp + c["output"] * out + c["cache_read"] * read
                  + five_min * inp * 1.25 + one_hour * inp * 2.0) / 1e6
    return total


def list_price(calls):
    """Price Codex token usage at list; return the total, its split and what stayed unpriced."""
    total, by_model = 0.0, Counter()
    unpriced = {"models": set(), "input": 0, "output": 0}
    for c in calls:
        if not isinstance(c, dict):
            continue
        model = _string(c.get("model"))
        inp, cached, out = (_number(c.get(key)) for key in ("input", "cache_read", "output"))
        rows = CODEX_PRICES.get(model)
        if not rows:
            unpriced["models"].add(_inline(model) or "unknown model")
            unpriced["input"] += inp
            unpriced["output"] += out
            continue
        price_in, price_cached, price_out = rows[1] if inp > CODEX_LONG_CONTEXT_TOKENS else rows[0]
        cached = min(cached, inp)
        amount = ((inp - cached) * price_in + cached * price_cached + out * price_out) / 1e6
        total += amount
        by_model[model] += amount
    return total, by_model, unpriced


def session_cost(cost_states):
    """cost-state is a running total per process; a resume starts a new one."""
    total, previous, by_model = 0.0, 0.0, Counter()
    finals, prev_state = [], None
    for state in cost_states:
        if not isinstance(state, dict):
            continue
        value = _number(state.get("totalCostUSD", 0), None)
        if value is None:
            continue
        if value < previous and prev_state is not None:
            finals.append(prev_state)
        previous, prev_state = value, state
    if prev_state is not None:
        finals.append(prev_state)
    for state in finals:
        total += _number(state.get("totalCostUSD"))
        for model, usage in _mapping(state.get("modelUsage")).items():
            by_model[model] += _number(_mapping(usage).get("costUSD"))
    return total, by_model


NOTABLE_RE = re.compile(r"search\.sh|publish-artifact|notify\.sh|graph-op|telemetry\.sh|handoff|wrap|save")


def _short(text, n):
    text = " ".join(_string(text).split())
    return text if len(text) <= n else text[: n - 1] + "…"


def _hm(ts):
    return datetime.fromisoformat(ts.replace("Z", "+00:00")).astimezone().strftime("%m-%d %H:%M") if ts else "?"


def _find(projects, prefix, session):
    """Locate a transcript by full session id or unique id prefix."""
    matches = []
    for directory in transcript_folders(projects, prefix):
        matches.extend(p for p in directory.glob(f"{session}*.jsonl")
                       if p.is_file() and within_instance(p, projects, prefix))
    if len(matches) == 1:
        return matches[0]
    if matches:
        raise SystemExit(f"{session} is ambiguous: " + ", ".join(m.stem[:12] for m in matches))
    raise SystemExit(f"no transcript for {session}")


def project_root(project_root):
    """Resolve the main checkout without running git or following other instances."""
    root = Path(project_root).resolve()
    git_file = root / '.git'
    if git_file.is_file():
        try:
            value = git_file.read_text().strip()
            if value.startswith('gitdir: '):
                target = Path(value[8:])
                if not target.is_absolute():
                    target = root / target
                target = target.resolve()
                parts = target.parts
                for index in range(len(parts) - 2):
                    if parts[index:index + 2] == ('.git', 'worktrees'):
                        return Path(*parts[:index])
        except (OSError, ValueError):
            pass
    return root


def instance_prefix(project_root):
    return re.sub(r'[/.]', '-', str(globals()['project_root'](project_root)))


def default_prefix():
    return instance_prefix(os.environ.get('EGREGORE_ROOT') or os.getcwd())


def transcript_folders(projects_dir, prefix):
    projects = Path(projects_dir)
    try:
        return sorted(d for d in projects.iterdir()
                      if (d.name == prefix or d.name.startswith(prefix + '--'))
                      and within_instance(d, projects, prefix) and d.is_dir())
    except OSError:
        return []


def valid_trail_folder(folder, projects_dir, prefix):
    """Admit only real cache directories belonging to this instance's folders."""
    try:
        folder, projects = Path(folder), Path(projects_dir)
        trails = projects.parent.parent / '.egregore' / 'trails'
        if not stat.S_ISDIR(folder.lstat().st_mode):
            return False
        physical = folder.resolve()
        if physical.parent != trails.resolve():
            return False
        return folder.name in {prefix, *(prefix + '--' + name for name in ('codex', 'pi', 'prime'))} or folder.name in {
            item.name for item in transcript_folders(projects, prefix)}
    except (OSError, ValueError, RuntimeError):
        return False


def within_instance(path, projects_dir, prefix):
    """Check physical containment; a sibling sharing a bare prefix is excluded."""
    try:
        relative = Path(path).resolve().relative_to(Path(projects_dir).resolve())
        folder = relative.parts[0]
        return folder == prefix or folder.startswith(prefix + '--')
    except (ValueError, OSError, RuntimeError, IndexError):
        return False


HEADER_LIMIT = 1024 * 1024


def read_header_result(path):
    """Return the bounded first-line JSON value and whether it was readable."""
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o444:
            return None, False
        with os.fdopen(descriptor, 'rb', buffering=0) as stream:
            descriptor = None
            line = stream.readline(HEADER_LIMIT + 1)
        if len(line) > HEADER_LIMIT:
            return None, False
        value = json.loads(line)
        return value, True
    except (OSError, ValueError, TypeError, RecursionError):
        return None, False
    finally:
        if descriptor is not None:
            os.close(descriptor)


def read_header(path):
    """Read a bounded mapping header; never block on a pipe or device."""
    value, _ = read_header_result(path)
    return value if isinstance(value, dict) else None


def _header_format(header):
    header = _mapping(header)
    kind, payload = header.get('type'), _mapping(header.get('payload'))
    if kind == 'cost-state' or (kind in ('user', 'assistant') and isinstance(header.get('message'), dict)):
        return 'claude'
    if kind == 'session_meta' and isinstance(payload.get('id'), str) and isinstance(payload.get('cwd'), str):
        return 'codex'
    if (kind == 'session' and type(header.get('version')) is int
            and isinstance(header.get('id'), str) and isinstance(header.get('cwd'), str)):
        return 'pi'
    return None


def probe_format(path, projects_dir=None, prefix=None):
    """Probe native headers, retaining Claude's bounded content detector."""
    kind = _header_format(read_header(path))
    if kind is not None:
        return kind
    projects = Path(projects_dir) if projects_dir is not None else Path.home() / '.claude' / 'projects'
    if within_instance(path, projects, prefix or default_prefix()) and is_claude_code_transcript(path):
        return 'claude'
    return None


def parent_of(header):
    """Normalize every Codex child spelling for both discovery and merging."""
    payload = _mapping(_mapping(header).get('payload', header))
    for name in ('parent_thread_id', 'forked_from_id'):
        if _string(payload.get(name)):
            return payload[name]
    subagent = _mapping(_mapping(payload.get('source')).get('subagent'))
    spawned = _mapping(subagent.get('thread_spawn'))
    for source in (spawned, subagent):
        for name in ('parent_thread_id', 'parent_session_id', 'parent_id', 'parent'):
            if _string(source.get(name)):
                return source[name]
    if _string(payload.get('session_id')) and payload['session_id'] != payload.get('id'):
        return payload['session_id']
    if isinstance(_mapping(payload.get('source')).get('subagent'), dict):
        # A child with missing lineage must never become a standalone record.
        # A self-parent keeps discovery and family traversal fail-closed.
        return _string(payload.get('id')) or '__orphan_subagent__'
    return None


def within_instance_cwd(cwd, root):
    """Admit a harness header only when its physical cwd belongs to the repo."""
    try:
        return bool(isinstance(cwd, str) and Path(cwd).is_absolute()
                    and Path(cwd).resolve().is_relative_to(project_root(root)))
    except (OSError, ValueError, RuntimeError):
        return False


def read_session(path, agent='main', root=None, projects_dir=None, prefix=None):
    """The common reader entry point; native cwd gates precede content reads."""
    kind = probe_format(path, projects_dir, prefix or (instance_prefix(root) if root else None))
    if kind == 'claude':
        return read_transcript(path, agent)
    if kind == 'codex':
        return read_codex_rollout(path, agent, root=root)
    if kind == 'pi':
        return read_pi_session(path, agent, root=root)
    raise ValueError('unsupported transcript format')


def is_claude_code_transcript(path):
    """A bounded, nonblocking 1 MiB probe of at most 500 nonempty lines."""
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o444:
            return False
        data = os.read(descriptor, 1024 * 1024).decode('utf-8', errors='replace')
        lines = (line for line in data.splitlines() if line.strip())
        for index, line in enumerate(lines):
            if index >= 500:
                break
            try:
                entry = json.loads(line)
            except (ValueError, TypeError, RecursionError):
                continue
            if not isinstance(entry, dict):
                continue
            if entry.get('type') == 'cost-state':
                return True
            if entry.get('type') in ('user', 'assistant') and isinstance(entry.get('message'), dict):
                # Pi also has message objects, but its entries carry a role rather
                # than Claude's top-level user/assistant event types.
                return True
        return False
    except (OSError, ValueError):
        return False
    finally:
        if descriptor is not None:
            os.close(descriptor)


def read_transcript(path, agent='main'):
    """Return original spike facts plus the text/event data needed by records."""
    path = Path(path)
    calls, tools, hooks, prompts, costs = {}, {}, [], [], []
    events, prompt_texts, assistant_texts, said_texts, decided = [], [], [], [], []
    branches, models = set(), set()
    session, first, last, pending_text, pending_full_text = None, None, None, None, None
    compactions, valid_entries, parse_failures, branch = 0, 0, 0, None
    pending_said_blocks, spans = [], []
    packet = None  # (session, tool id) of the latest --context-packet recall
    requests, awaiting = [], 0  # hook decision requests; the first still awaiting one
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o444:
        os.close(descriptor)
        raise OSError('transcript is not a readable regular file')
    with os.fdopen(descriptor, 'rb') as stream:
        for line in stream:
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except (ValueError, TypeError, RecursionError):
                parse_failures += 1
                continue
            if not isinstance(entry, dict):
                parse_failures += 1
                continue
            valid_entries += 1
            session = session or _string(entry.get('sessionId'), None)
            stamp = entry.get('timestamp')
            try:
                ts = _ts(stamp)
            except (ValueError, TypeError, AttributeError):
                ts, stamp = None, None
            if ts:
                first, last = first or ts, ts
                _add_event(spans, ts)
            if _string(entry.get('gitBranch')):
                branch = _inline(entry['gitBranch'])
                branches.add(branch)
            kind = entry.get('type')
            if kind == 'cost-state':
                costs.append(entry)
            elif kind == 'assistant':
                message = entry.get('message') or {}
                if not isinstance(message, dict):
                    continue
                rid = entry.get('requestId') or entry.get('uuid')
                if not isinstance(rid, (str, int, type(None))):
                    rid = None
                usage = _mapping(message.get('usage'))
                model = _string(message.get('model'), None)
                calls[rid] = {'model': model, 'ts': ts, 'agent': agent,
                              'usage_complete': all(_number(usage.get(key), None) is not None
                                                    for key in ('input_tokens', 'output_tokens')),
                              'input': _number(usage.get('input_tokens')), 'output': _number(usage.get('output_tokens')),
                              'cache_read': _number(usage.get('cache_read_input_tokens')),
                              'cache_write': _number(usage.get('cache_creation_input_tokens')),
                              'cache_write_1h': _number(_mapping(usage.get('cache_creation')).get('ephemeral_1h_input_tokens'))}
                if model and not model.startswith('<'):
                    models.add(model)
                blocks = message.get('content') or []
                for block in blocks if isinstance(blocks, list) else []:
                    if not isinstance(block, dict):
                        continue
                    if block.get('type') == 'text' and _string(block.get('text')).strip():
                        assistant_texts.append({'ts': stamp, 'text': block['text']})
                        pending_text = ('SAID', stamp, _short(block['text'], 500))
                        pending_full_text = {'ts': stamp, 'text': block['text']}
                        pending_said_blocks.append(pending_full_text)
                    elif block.get('type') == 'tool_use':
                        name, inp = _string(block.get('name'), None), _mapping(block.get('input'))
                        if _string(block.get('id')):
                            tools[block['id']] = {'name': name, 'input': inp, 'start': ts, 'agent': agent, 'request': rid}
                        if name == 'AskUserQuestion':
                            # A question put to the person decides every request awaiting one.
                            for request in requests[awaiting:]:
                                request['decided'] = True
                            awaiting = len(requests)
                        if name in ('Write', 'Edit', 'NotebookEdit'):
                            events.append(('FILE', stamp, f"{name} {inp.get('file_path', inp.get('notebook_path', ''))}"))
                        elif name == 'Bash':
                            command = _string(inp.get('command'))
                            if GIT_RE.search(command) or NOTABLE_RE.search(command):
                                events.append(('RUN', stamp, _short(command, 180)))
                            # The attach hook acts only on these calls.
                            if '--context-packet' in command and SEARCH_RE.search(command) and _string(block.get('id')):
                                packet = (_string(entry.get('sessionId'), None), block['id'])
                        elif name == 'Skill':
                            events.append(('SKILL', stamp, _string(inp.get('skill'))))
                        elif name in ('Agent', 'Task'):
                            events.append(('AGENT', stamp, _short(inp.get('description', ''), 120)))
                        elif name == 'Workflow':
                            events.append(('WORKFLOW', stamp, _short(_string(inp.get('script'))[:400], 160)))
                        elif name in ('WebFetch', 'WebSearch'):
                            events.append(('WEB', stamp, _short(inp.get('url') or inp.get('query', ''), 120)))
                        elif name == 'Artifact':
                            events.append(('ARTIFACT', stamp, _short(json.dumps(inp)[:200], 160)))
            elif kind == 'user':
                message = entry.get('message') or {}
                if not isinstance(message, dict):
                    continue
                content = message.get('content')
                texts = [content] if isinstance(content, str) else [_string(b.get('text')) for b in content or []
                         if isinstance(b, dict) and b.get('type') == 'text'] if isinstance(content, list) else []
                if not entry.get('isMeta'):
                    for value in texts:
                        if agent == 'main' and not value.startswith('<'):
                            prompts.append(ts)
                            prompt_texts.append({'ts': stamp, 'text': value})
                        if value and not value.startswith('<'):
                            if pending_text:
                                events.append(pending_text)
                                said_texts.extend(pending_said_blocks)
                                pending_said_blocks.clear()
                                pending_text = None
                            events.append(('ASK', stamp, _short(value, 700)))
                            # The person's next prompt leaves earlier requests undecided.
                            awaiting = len(requests)
                        elif value.startswith('<command-name>'):
                            name = re.search(r'<command-name>(.*?)</command-name>', value)
                            events.append(('CMD', stamp, name.group(1) if name else value[:60]))
                for block in content if isinstance(content, list) else []:
                    if not isinstance(block, dict) or block.get('type') != 'tool_result':
                        continue
                    tool = tools.get(_string(block.get('tool_use_id')))
                    if tool and 'end' not in tool:
                        text = _text(block.get('content'))
                        tool.update(end=ts, error=bool(block.get('is_error')), result=text[:4000])
                        if tool['error'] and NONZERO_EXIT_RE.match(text):
                            tool['nonzero_exit'] = True
                        if tool['name'] == 'AskUserQuestion' and not tool['error']:
                            for item in _question_answers(block.get('content'), tool['input']):
                                decided.append({'ts': stamp, **item})
                                labels = ', '.join(_choice_label(label) for label in item['selected_labels'])
                                answer = _short(labels, 160) if labels else 'a free-text answer'
                                events.append(('DECIDED', stamp, f'{_decision_header(item)}: {answer} ← "{_short(item["question"], 160)}"'))
                    if block.get('is_error') and not entry.get('isMeta'):
                        body = block.get('content')
                        body = body if isinstance(body, str) else _text(body).replace('\n', ' ')
                        events.append(('ERR', stamp, _short(body, 160)))
            elif kind == 'attachment':
                a = _mapping(entry.get('attachment'))
                if a.get('type') == 'hook_success':
                    hooks.append({'hook': _string(a.get('hookName'), None), 'command': _string(a.get('command'), None), 'ms': _number(a.get('durationMs'), None)})
                    request = _decision_request(a)
                    if request:
                        requests.append(dict(request, decided=False))
                # An attach failure belongs to the latest packet recall of the
                # same session; only its failure kind is kept.
                own = _string(entry.get('sessionId'), None)
                if packet and packet[1] in tools and (not own or not packet[0] or own == packet[0]):
                    failure = _attach_failure(a)
                    if failure:
                        tools[packet[1]]['attach_failure'] = failure
            elif kind == 'system':
                if entry.get('subtype') == 'stop_hook_summary':
                    infos = entry.get('hookInfos')
                    for info in infos if isinstance(infos, list) else []:
                        if not isinstance(info, dict):
                            continue
                        hooks.append({'hook': 'Stop', 'command': _string(info.get('command'), None), 'ms': _number(info.get('durationMs'), None)})
                if entry.get('subtype') in ('compact_boundary', 'compaction', 'context_compaction'):
                    compactions += 1
    if pending_text:
        events.append(pending_text)
    return {'session': session, 'first': first, 'last': last, 'calls': calls, 'tools': tools,
            'hooks': hooks, 'prompts': prompts, 'costs': costs, 'events': events,
            'prompt_texts': prompt_texts, 'assistant_texts': assistant_texts, 'said_texts': said_texts,
            'decided': decided, 'hook_requests': requests, 'active_spans': _merge_spans(spans),
            'branches': sorted(branches), 'branch': branch, 'models': sorted(models), 'compactions': compactions,
            'valid_entries': valid_entries, 'parse_failures': parse_failures, 'harness': 'claude'}


def _native_entries(path, expected, root, facts):
    """Yield admitted entries once, recording parse loss without retaining content."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o444:
        os.close(descriptor)
        raise OSError('transcript is not a readable regular file')
    with os.fdopen(descriptor, 'rb', buffering=0) as stream:
        first = stream.readline(HEADER_LIMIT + 1)
        try:
            header = json.loads(first) if len(first) <= HEADER_LIMIT else None
        except (ValueError, TypeError, RecursionError):
            header = None
        if _header_format(header) != expected:
            raise ValueError('unsupported transcript format')
        payload = header['payload'] if expected == 'codex' else header
        if not within_instance_cwd(payload.get('cwd'), root or os.environ.get('EGREGORE_ROOT') or os.getcwd()):
            raise ValueError('transcript is outside this instance')
        yield header
        for line in io.BufferedReader(stream):
            if not line.strip():
                continue
            try:
                entry = json.loads(line)
            except (ValueError, TypeError, RecursionError):
                facts['parse_failures'] += 1
                continue
            if isinstance(entry, dict):
                yield entry
            else:
                facts['parse_failures'] += 1


def _native_facts(harness):
    return {'session': None, 'first': None, 'last': None, 'calls': {}, 'tools': {},
            'hooks': [], 'prompts': [], 'costs': [], 'events': [], 'prompt_texts': [],
            'assistant_texts': [], 'said_texts': [], 'decided': [], 'hook_requests': [], 'active_spans': [], 'branches': [],
            'branch': None, 'models': [], 'compactions': 0, 'valid_entries': 0, 'parse_failures': 0,
            'harness': harness}


def _native_stamp(facts, entry):
    stamp = entry.get('timestamp')
    try:
        ts = _ts(stamp)
    except (ValueError, TypeError, AttributeError):
        ts, stamp = None, None
    if ts is not None:
        facts['first'] = facts['first'] if facts['first'] is not None else ts
        facts['last'] = ts
        _add_event(facts['active_spans'], ts)
    facts['valid_entries'] += 1
    return stamp, ts


def _native_ask(facts, text, stamp, ts, pending):
    if not text or text.startswith('<'):
        return
    if pending:
        facts['events'].append(('SAID', pending[-1]['ts'], _short(pending[-1]['text'], 500)))
        facts['said_texts'].extend(pending)
        pending.clear()
    facts['prompts'].append(ts)
    facts['prompt_texts'].append({'ts': stamp, 'text': text})
    facts['events'].append(('ASK', stamp, _short(text, 700)))


def _native_said(facts, text, stamp, pending):
    if text.strip():
        value = {'ts': stamp, 'text': text}
        facts['assistant_texts'].append(value)
        pending.append(value)


def _native_file(facts, name, value, stamp, repo):
    relative = _relative_file(value, Path(repo))
    if relative is not None:
        facts['events'].append(('FILE', stamp, f'{name} {relative}'))
    elif _string(value):
        # Keep outside-path cardinality without exposing the path in the trail.
        facts['events'].append(('FILE', stamp, f'{name} <outside:{facts["session"]}:{len(facts["events"])}>'))


def _native_error(facts, tool, output, stamp):
    # Successful output is never retained; error output has one shared 500-char cap.
    body = _text(output)[:500]
    tool['result'] = body
    facts['events'].append(('ERR', stamp, _short(body, 500)))


def _native_command(facts, ident, command, stamp, ts, agent, exit_code=None, output='', duration=0):
    command = _string(command)[:4000]
    error = exit_code not in (None, 0)
    tool = {'name': 'Bash', 'input': {'command': command}, 'start': ts - duration if ts is not None else None,
            'end': ts, 'error': error, 'agent': agent}
    facts['tools'][ident] = tool
    facts['events'].append(('RUN', stamp, _short(command, 180)))
    if error:
        # The command ran and returned a status: not an error of the harness.
        tool['nonzero_exit'] = True
        _native_error(facts, tool, output, stamp)
    return tool


def _duration(value):
    value = _mapping(value)
    return _number(value.get('secs')) + _number(value.get('nanos')) / 1e9


def _codex_answers(text):
    if not text.startswith('<send_user_message_question_reply>'):
        return []
    body = text[len('<send_user_message_question_reply>'):]
    try:
        values, _ = json.JSONDecoder().raw_decode(body.lstrip())
    except (ValueError, TypeError, RecursionError):
        return []
    return [{'header': 'Question', 'question': item['question'], 'answer': item['answer'],
             'options': [], 'selected_labels': []}
            for item in values if isinstance(item, dict)
            and _string(item.get('question')).strip() and _string(item.get('answer')).strip()] if isinstance(values, list) else []


def _codex_command(value):
    """Recover shell scripts while preserving ordinary argv argument boundaries."""
    if not isinstance(value, list):
        return _string(value)
    argv = [_string(argument) for argument in value]
    if (len(argv) >= 3 and Path(argv[0]).name in ('sh', 'bash', 'zsh', 'dash', 'fish')
            and argv[1] in ('-lc', '-c', '-lic')):
        script = 3 if argv[2] == '--' else 2
        if script < len(argv):
            return argv[script]
    return shlex.join(argv)


def read_codex_rollout(path, agent='main', root=None):
    """Translate Codex's completed items into the shared, privacy-bounded facts."""
    facts, pending, model = _native_facts('codex'), [], None
    repo = root or os.environ.get('EGREGORE_ROOT') or os.getcwd()
    for index, entry in enumerate(_native_entries(path, 'codex', root, facts)):
        stamp, ts = _native_stamp(facts, entry)
        payload, kind = _mapping(entry.get('payload')), entry.get('type')
        if index == 0:
            if ts is None:
                _native_stamp(facts, {'timestamp': payload.get('timestamp')})
                facts['valid_entries'] -= 1
            facts['session'] = payload['id']
            branch = _string(_mapping(payload.get('git')).get('branch'))
            if branch:
                facts['branch'], facts['branches'] = _inline(branch), [_inline(branch)]
            continue
        if kind == 'session_meta':
            # A child repeats its parent's metadata; it never changes identity.
            continue
        if kind == 'turn_context':
            model = _string(payload.get('model'), None)
            if model and model not in facts['models']:
                facts['models'].append(model)
        elif kind == 'token_usage_record':
            usage = _mapping(payload.get('usage'))
            facts['calls'][str(index)] = {'model': model, 'ts': ts, 'agent': agent,
                'usage_complete': all(_number(usage.get(key), None) is not None
                                      for key in ('input_tokens', 'output_tokens')),
                'input': _number(usage.get('input_tokens')), 'output': _number(usage.get('output_tokens')),
                'cache_read': _number(usage.get('cached_input_tokens')), 'cache_write': 0, 'cache_write_1h': 0}
        elif kind == 'compacted':
            facts['compactions'] += 1
        elif kind == 'event_msg' and payload.get('type') == 'item_completed':
            item = _mapping(payload.get('item'))
            item_kind = item.get('type')
            ident = str(index)
            if item_kind == 'UserMessage':
                content = item.get('content')
                texts = [_string(block.get('text')) for block in content if isinstance(block, dict)] if isinstance(content, list) else [_string(content)]
                for text in texts:
                    for answer in _codex_answers(text):
                        facts['decided'].append({'ts': stamp, **answer})
                        facts['events'].append(('DECIDED', stamp, f'Question: a free-text answer ← "{_short(answer["question"], 160)}"'))
                    _native_ask(facts, text, stamp, ts, pending)
            elif item_kind == 'AgentMessage':
                content = item.get('content')
                for block in content if isinstance(content, list) else []:
                    if isinstance(block, dict) and block.get('type') == 'Text':
                        _native_said(facts, _string(block.get('text')), stamp, pending)
            elif item_kind == 'CommandExecution':
                command = _codex_command(item.get('command'))
                _native_command(facts, ident, command, stamp, ts, agent,
                                item.get('exit_code'), item.get('aggregated_output'), _duration(item.get('duration')))
            elif item_kind == 'FileChange':
                facts['tools'][ident] = {'name': 'FileChange', 'input': {}, 'start': ts, 'end': ts,
                    'error': item.get('status') in ('failed', 'error'), 'agent': agent}
                for value, change in _mapping(item.get('changes')).items():
                    name = 'Edit' if _mapping(change).get('type') == 'update' else 'Write'
                    _native_file(facts, name, value, stamp, repo)
            elif item_kind in ('McpToolCall', 'Extension', 'SubAgentActivity', 'ContextCompaction'):
                name = ('mcp:' + _string(item.get('server')) + '.' + _string(item.get('tool'))
                        if item_kind == 'McpToolCall' else item_kind)
                duration = _duration(item.get('duration'))
                facts['tools'][ident] = {'name': name, 'input': {}, 'start': ts - duration if ts is not None else None,
                    'end': ts, 'error': item.get('status') in ('failed', 'error'), 'agent': agent}
                if item_kind == 'McpToolCall':
                    facts['events'].append(('RUN', stamp, _short(name, 180)))
                elif item_kind == 'Extension' and item.get('kind') == 'web.search':
                    facts['events'].append(('WEB', stamp, _short(item.get('query'), 120)))
                elif item_kind == 'SubAgentActivity':
                    facts['events'].append(('AGENT', stamp, _short(item.get('agent_thread_id'), 120)))
    if pending:
        facts['events'].append(('SAID', pending[-1]['ts'], _short(pending[-1]['text'], 500)))
    facts['models'].sort()
    facts['active_spans'] = _merge_spans(facts['active_spans'])
    return facts


def _bounded_arguments(value):
    """Retain tool arguments only to the same local-result bound as Claude."""
    value = _mapping(value)
    result = {}
    remaining = 4000
    for key, item in value.items():
        if remaining <= 0:
            break
        if isinstance(item, str):
            result[key] = item[:remaining]
            remaining -= len(result[key])
        elif isinstance(item, (bool, int, float, type(None))):
            result[key] = item
    return result


def _pi_file_arguments(arguments):
    arguments = _mapping(arguments)
    for name in ('path', 'file_path'):
        if _string(arguments.get(name)):
            yield arguments[name]
    # multi_edit tools may carry several independent file edits in one call.
    edits = arguments.get('edits')
    for edit in edits[:1000] if isinstance(edits, list) else []:
        for name in ('path', 'file_path'):
            if _string(_mapping(edit).get(name)):
                yield edit[name]


def read_pi_session(path, agent='main', root=None):
    """Read the common Pi/Prime v3 message stream and its native cost ledger."""
    harness = 'prime' if '.prime' in Path(path).parts else 'pi'
    facts, pending, total, by_model = _native_facts(harness), [], 0.0, Counter()
    repo = root or os.environ.get('EGREGORE_ROOT') or os.getcwd()
    for index, entry in enumerate(_native_entries(path, 'pi', root, facts)):
        stamp, ts = _native_stamp(facts, entry)
        if index == 0:
            facts['session'] = entry['id']
            continue
        kind = entry.get('type')
        if kind == 'compaction':
            facts['compactions'] += 1
            modified = _mapping(entry.get('details')).get('modifiedFiles')
            for value in modified if isinstance(modified, list) else []:
                _native_file(facts, 'Edit', value, stamp, repo)
        if kind != 'message':
            continue
        message = _mapping(entry.get('message'))
        role, content = message.get('role'), message.get('content')
        if role == 'user':
            _native_ask(facts, _text(content), stamp, ts, pending)
        elif role == 'assistant':
            model, usage = _string(message.get('model'), None), _mapping(message.get('usage'))
            if model and model not in facts['models']:
                facts['models'].append(model)
            facts['calls'][str(index)] = {'model': model, 'ts': ts, 'agent': agent,
                'input': _number(usage.get('input')), 'output': _number(usage.get('output')),
                'cache_read': _number(usage.get('cacheRead')), 'cache_write': _number(usage.get('cacheWrite')), 'cache_write_1h': 0}
            amount = _number(_mapping(usage.get('cost')).get('total'), None)
            facts['calls'][str(index)]['cost_complete'] = amount is not None and amount >= 0
            if amount is not None:
                total += amount
                by_model[model or 'unknown'] += amount
                facts['costs'].append({'totalCostUSD': total, 'modelUsage': {
                    name: {'costUSD': value} for name, value in by_model.items()}})
            for block in content if isinstance(content, list) else []:
                if not isinstance(block, dict):
                    continue
                if block.get('type') == 'text':
                    _native_said(facts, _string(block.get('text')), stamp, pending)
                elif block.get('type') == 'toolCall':
                    raw_name, inp = _string(block.get('name')), _bounded_arguments(block.get('arguments'))
                    command = raw_name.lower() == 'bash' or 'command' in inp
                    write_tool = raw_name.lower() in ('write', 'edit', 'multi_edit') or any(word in raw_name.lower() for word in ('write', 'edit'))
                    name = 'Bash' if command else ('Write' if write_tool else raw_name)
                    ident = _string(block.get('id')) or str(index)
                    facts['tools'][ident] = {'name': name, 'input': inp, 'start': ts, 'agent': agent}
                    if command:
                        facts['events'].append(('RUN', stamp, _short(inp.get('command'), 180)))
                    elif write_tool:
                        for value in dict.fromkeys(_pi_file_arguments(block.get('arguments'))):
                            _native_file(facts, 'Write', value, stamp, repo)
                        # Files are consumed from the native FILE events below.
                        facts['tools'][ident]['input'] = {key: value for key, value in inp.items() if key not in ('path', 'file_path')}
        elif role == 'toolResult':
            tool = facts['tools'].get(_string(message.get('toolCallId')))
            if tool and 'end' not in tool:
                details = _mapping(message.get('details'))
                exit_code = message.get('exitCode', message.get('exit_code', details.get('exitCode', details.get('exit_code'))))
                error = bool(message.get('isError')) or exit_code not in (None, 0)
                tool.update(end=ts, error=error)
                if exit_code not in (None, 0):
                    tool['nonzero_exit'] = True
                if error:
                    _native_error(facts, tool, content, stamp)
        elif role == 'bashExecution':
            _native_command(facts, str(index), message.get('command'), stamp, ts, agent,
                            message.get('exitCode'), message.get('output'))
    if pending:
        facts['events'].append(('SAID', pending[-1]['ts'], _short(pending[-1]['text'], 500)))
    facts['models'].sort()
    facts['active_spans'] = _merge_spans(facts['active_spans'])
    return facts


def trail(path):
    facts = path if isinstance(path, dict) else read_transcript(path)
    cost, _ = session_cost(facts['costs'])
    return facts['events'], cost, set(facts['branches']), set(facts['models'])


def withhold_free_text(text, facts):
    """Withhold known free-text answers, preserving common short words."""
    answers = {_string(item.get('answer')) for item in facts.get('decided', [])
               if not item.get('selected_labels') and len(_string(item.get('answer'))) >= 4}
    patterns = [(r'\b' if re.match(r'\w', answer[0]) else '') + re.escape(answer) +
                (r'\b' if re.match(r'\w', answer[-1]) else '')
                for answer in sorted(answers, key=lambda value: (-len(value), value))]
    return re.sub('|'.join(patterns), '[withheld]', text, flags=re.I) if patterns else text


def render_trail(path, session=None):
    facts = path if isinstance(path, dict) else read_transcript(path)
    events, cost, branches, models = trail(facts)
    stamps = [t for _, t, _ in events if t]
    lines = [f"# trail {session or facts.get('session') or 'unknown'}",
             f"{_hm(min(stamps) if stamps else None)} → {_hm(max(stamps) if stamps else None)} · ${cost:,.2f} · models {', '.join(sorted(models))} · branches {', '.join(sorted(branches))}"]
    files = sorted({d.split(' ', 1)[1] for k, _, d in events if k == 'FILE'})
    lines.append(f'files written: {len(files)}')
    lines.extend(f'  {f}' for f in files)
    lines.append('')
    previous = None
    for kind, ts, detail in events:
        if kind == 'FILE' or (kind, detail) == previous:
            continue
        previous = kind, detail
        lines.append(f'{_hm(ts)}  {kind:<8} {detail}')
    return withhold_free_text('\n'.join(lines), facts)


def _question_answers(content, tool_input):
    """Pair each answer with its question's header and exact offered labels."""
    content = _text(content)
    if not content.startswith('Your questions have been answered:'):
        return []
    questions = _mapping(tool_input).get('questions')
    questions = questions if isinstance(questions, list) else []
    pairs = []
    for match in re.finditer(r'"((?:\\.|[^"\\])*)"\s*=\s*"((?:\\.|[^"\\])*)"', content):
        try:
            question, answer = (json.loads('"' + value + '"', strict=False) for value in match.groups())
        except ValueError:
            continue
        if question.strip() and answer.strip():
            definition = next((item for item in questions if isinstance(item, dict)
                               and item.get('question') == question), {})
            options = definition.get('options')
            labels = [_string(option.get('label')) for option in options
                      if isinstance(option, dict) and _string(option.get('label')).strip()] if isinstance(options, list) else []
            selected = _selected_labels(answer, labels, definition.get('multiSelect') is True)
            pairs.append({'question': question, 'answer': answer,
                          'header': _string(definition.get('header')),
                          'options': labels, 'selected_labels': selected})
    return pairs


def _selected_labels(answer, labels, multi_select):
    if answer in labels:
        return [answer]
    if not multi_select:
        return []
    # Match whole offered labels before treating commas as separators: an
    # option label can itself contain a comma. Each reachable offset is tried
    # only once, so ambiguous label prefixes do not cause backtracking growth.
    choices_at = {0: []}
    for start in range(len(answer)):
        if start not in choices_at:
            continue
        for label in labels:
            if not answer.startswith(label, start):
                continue
            end = start + len(label)
            chosen = [*choices_at[start], label]
            if end == len(answer):
                return chosen
            separator = re.match(r',\s*', answer[end:])
            if separator:
                choices_at.setdefault(end + separator.end(), chosen)
    return []


def trim_trail(trail, cap=60_000):
    """Prefer the person's trail events, returning a shared-record trim receipt."""
    if len(trail) <= cap:
        return trail, None
    lines = trail.splitlines(keepends=True)
    kinds = []
    for line in lines:
        match = re.match(r'^(?:\d{2}-\d{2} \d{2}:\d{2}|\?)\s+([A-Z]+)\s', line)
        kinds.append(match.group(1) if match else None)
    remaining, removed, counts = len(trail), set(), []
    for eligible, label in (({'SAID'}, 'assistant'),
                            ({'RUN', 'WEB', 'ARTIFACT', 'AGENT', 'WORKFLOW'}, 'command'),
                            ({'ERR'}, 'error')):
        count = 0
        for index, kind in enumerate(kinds):
            if remaining <= cap:
                break
            if kind in eligible:
                removed.add(index)
                remaining -= len(lines[index])
                count += 1
        if count:
            counts.append(f'{count} {label} line' + ('s' if count != 1 else ''))
    trimmed = ''.join(line for index, line in enumerate(lines) if index not in removed)
    if len(trimmed) > cap:
        marker = '\n[trail truncated: middle omitted]\n'
        head = min(40_000, max(0, cap - len(marker)), cap * 2 // 3)
        tail = max(0, cap - head - len(marker))
        trimmed = trimmed[:head] + marker[:cap - head] + (trimmed[-tail:] if tail else '')
        counts.append(f'remaining trail truncated at {cap:,} characters')
    return trimmed, 'trail trimmed: ' + ', '.join(counts)

def last_event_time(path, header=None):
    """Check admission, then find the last event in a bounded one MiB tail."""
    descriptor = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    info = os.fstat(descriptor)
    if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o444:
        os.close(descriptor)
        raise OSError('transcript is not a readable regular file')
    last = None
    with os.fdopen(descriptor, 'rb', buffering=0) as stream:
        first = stream.readline(HEADER_LIMIT + 1)
        try:
            actual = json.loads(first) if len(first) <= HEADER_LIMIT else None
        except (ValueError, TypeError, RecursionError):
            actual = None
        if not isinstance(actual, dict) or (header is not None and actual != header):
            raise ValueError('transcript header changed after admission')
        try:
            last = _ts(actual.get('timestamp') or _mapping(actual.get('payload')).get('timestamp'))
        except (ValueError, TypeError, AttributeError):
            pass
        body_start = stream.tell()
        tail_start = max(body_start, info.st_size - HEADER_LIMIT)
        truncated = tail_start > body_start
        # Include one boundary byte to distinguish a complete first tail line
        # from the trailing fragment of an earlier, potentially enormous item.
        stream.seek(tail_start - 1 if truncated else tail_start)
        tail = stream.read(HEADER_LIMIT + (1 if truncated else 0))
        if truncated:
            tail = tail[1:] if tail[:1] == b'\n' else tail.partition(b'\n')[2]
        for line in reversed(tail.splitlines()):
            try:
                entry = json.loads(line)
                if isinstance(entry, dict):
                    stamp = _ts(entry.get('timestamp'))
                    if stamp is not None:
                        return stamp
            except (ValueError, TypeError, AttributeError, RecursionError):
                continue
    return info.st_mtime if truncated else last


def _codex_index(path, root):
    """Fixture/standalone fallback; record sweeps supply their persistent index."""
    path = Path(path)
    sessions = next((parent for parent in path.parents if parent.name == 'sessions' and parent.parent.name == '.codex'), path.parent)
    result = {}
    for candidate in sessions.rglob('*.jsonl'):
        header = read_header(candidate)
        payload = _mapping(_mapping(header).get('payload'))
        if _header_format(header) == 'codex' and within_instance_cwd(payload.get('cwd'), root):
            result[str(candidate)] = {'id': payload['id'], 'parent': parent_of(header),
                'mtime': candidate.stat().st_mtime, 'last_event': last_event_time(candidate, header), 'header': header}
    return result


def _merge_native(facts, sub, index):
    facts['calls'].update({f'{key}@{index}': value for key, value in sub['calls'].items()})
    facts['tools'].update({f'{key}@{index}': value for key, value in sub['tools'].items()})
    for key in ('hooks', 'prompts', 'costs', 'events', 'prompt_texts', 'assistant_texts', 'said_texts', 'decided'):
        facts[key].extend(sub[key])
    for key in ('branches', 'models'):
        facts[key] = sorted(set(facts[key]) | set(sub[key]))
    facts['compactions'] += sub['compactions']
    facts['valid_entries'] += sub['valid_entries']
    facts['active_spans'] = _merge_spans(facts['active_spans'] + sub['active_spans'])
    if sub['last'] is not None:
        facts['last'] = max(facts['last'] or sub['last'], sub['last'])


def load_session(path, projects_dir=None, prefix=None, root=None, codex_index=None, require_root_prompts=False):
    """Read a transcript and its admitted children through one reader interface."""
    path = Path(path)
    projects = Path(projects_dir) if projects_dir is not None else Path.home() / '.claude' / 'projects'
    harness = probe_format(path, projects, prefix or (instance_prefix(root) if root else None))
    if harness == 'claude' and prefix is not None and not within_instance(path, projects, prefix):
        raise ValueError('transcript is outside this instance')
    facts = read_session(path, root=root, projects_dir=projects, prefix=prefix)
    facts['cost_sessions'] = [facts['session']] if facts.get('session') else []
    facts['cost_scope_complete'] = bool(facts['cost_sessions'] and facts.get('calls')
                                        and not facts.get('parse_failures'))
    if harness == 'codex' and require_root_prompts and not facts['prompts']:
        facts.update(subagents=0, subagent_failures=0, workflow_runs=0)
        return facts
    accepted, failures = [], 0
    if harness == 'codex':
        index = codex_index if codex_index is not None else _codex_index(path, root or os.environ.get('EGREGORE_ROOT') or os.getcwd())
        members = {facts['session']}
        while True:
            children = {entry['id'] for entry in index.values() if entry.get('parent') in members}
            if children <= members:
                break
            members.update(children)
        accepted = sorted(Path(value) for value, entry in index.items()
                          if entry.get('id') in members - {facts['session']})
        if len(accepted) > 50:
            facts['cost_scope_complete'] = False
        accepted = accepted[:50]
    elif harness == 'claude':
        sub_dir = path.with_suffix('') / 'subagents'
        # Gate traversal before looking through a possibly symlinked directory.
        if prefix is not None and within_instance(sub_dir, projects, prefix) and sub_dir.is_dir():
            for current, dirs, filenames in os.walk(sub_dir, followlinks=False):
                dirs[:] = sorted(name for name in dirs if within_instance(Path(current) / name, projects, prefix))
                for name in sorted(filenames):
                    candidate = Path(current) / name
                    if name.endswith('.jsonl') and within_instance(candidate, projects, prefix):
                        accepted.append(candidate)
    read_subs = []
    for index, sub_path in enumerate(sorted(accepted)):
        try:
            if not sub_path.is_file() or not sub_path.stat().st_mode & 0o444:
                failures += 1
                continue
            sub = read_session(sub_path, 'workflow' if 'workflows' in sub_path.parts else 'sub', root=root,
                               projects_dir=projects, prefix=prefix)
            if not sub['valid_entries']:
                failures += 1
                continue
        except (OSError, ValueError):
            failures += 1
            continue
        component = sub.get('session')
        if harness == 'claude' and (not component or component == facts.get('session')):
            # Claude workers can reuse the parent's session id. Keep their
            # cost scope distinct without publishing local transcript paths.
            component = 'claude-worker-' + hashlib.sha256(
                (str(facts.get('session')) + '/' + str(sub_path.relative_to(path.with_suffix('')))).encode()
            ).hexdigest()[:32]
        if component:
            facts['cost_sessions'].append(component)
        else:
            facts['cost_scope_complete'] = False
        facts['parse_failures'] = facts.get('parse_failures', 0) + sub.get('parse_failures', 0)
        if not sub.get('calls') or sub.get('parse_failures'):
            # Missing usage or dropped rows leave the worker's contribution
            # incomplete even when the parent's own calls have full prices.
            facts['cost_scope_complete'] = False
        if harness == 'codex':
            _merge_native(facts, sub, index)
        else:
            facts['calls'].update({f'{key}@{index}': value for key, value in sub['calls'].items()})
            facts['tools'].update(sub['tools'])
            # A subagent's events fill the main thread's wait; the outline
            # keeps active time within the main thread's wall clock.
            facts['active_spans'] = _merge_spans(facts['active_spans'] + sub['active_spans'])
        read_subs.append(sub_path)
    facts['subagents'] = len(read_subs)
    facts['subagent_failures'] = failures
    # Codex records native child IDs; Claude records free-text descriptions.
    announced = ({detail for kind, _, detail in facts.get('events', []) if kind == 'AGENT' and detail}
                 if harness == 'codex' else set())
    launched = sum(tool.get('name') in ('Agent', 'Task', 'spawn_agent', 'collaboration.spawn_agent')
                   for tool in facts.get('tools', {}).values())
    facts['cost_scope_complete'] = (facts['cost_scope_complete'] and failures == 0
                                    and len(facts['cost_sessions']) == len(set(facts['cost_sessions']))
                                    and not (announced - set(facts['cost_sessions']))
                                    and launched <= len(read_subs))
    facts['workflow_runs'] = len({p.parent for p in read_subs if 'workflows' in p.parts})
    return facts


def skip_reason(facts):
    """Why a session gets no record, in the words record discovery already counts.

    A session with no tool calls and no prompt after the greeting did no work.
    Claude answers its first prompt (the launcher's `start`, or whatever was
    typed) with the greeting; Codex and Pi show the greeting as a card, not a
    model turn, so there every prompt follows it, and a session without one is
    skipped even when an agent ran tools in it.
    """
    prompts = len(facts.get('prompts') or [])
    if facts.get('harness') != 'claude':
        return None if prompts else 'no prompts'
    return 'no prompts' if prompts <= 1 and not facts.get('tools') else None


def _shell_commands(command):
    """Tokenize command positions, never punctuation inside quotes or heredocs.

    This is deliberately a conservative shell recognizer, not an interpreter.
    It does not expand variables, substitutions, aliases or sourced scripts.
    """
    if not isinstance(command, str):
        return []
    lines, pending = [], []
    for line in command.splitlines():
        if pending:
            if line.strip() == pending[0]:
                pending.pop(0)
            continue
        # Several heredocs can be declared on the same command line; their
        # bodies follow in declaration order. Strip all bodies before parsing.
        heredocs = list(re.finditer(r"<<-?\s*(['\"]?)([\w_-]+)\1", line))
        if heredocs:
            pending.extend(match.group(2) for match in heredocs)
            line = line[:heredocs[0].start()]
        lines.append(line)
    source = '\n'.join(lines)
    segments, current, quote, escaped, comment = [], [], None, False, False
    for character in source:
        if comment:
            if character != '\n':
                continue
            comment = False
        if escaped:
            current.append(character)
            escaped = False
            continue
        if character == '\\' and quote != "'":
            current.append(character)
            escaped = True
        elif quote:
            current.append(character)
            if character == quote:
                quote = None
        elif character == '#' and (not current or current[-1].isspace()):
            comment = True
        elif character in ("'", '\"'):
            current.append(character)
            quote = character
        elif character in ';&|\n':
            if current:
                segments.append(''.join(current))
            current = []
        else:
            current.append(character)
    if current:
        segments.append(''.join(current))
    commands = []
    for segment in segments:
        lexer = shlex.shlex(segment, posix=True)
        lexer.whitespace_split = True
        tokens = []
        try:
            tokens.extend(lexer)
        except ValueError:
            # An incomplete heredoc argument still leaves the command tokens.
            pass
        if tokens:
            commands.append(tokens)
    return commands


def git_commands(command, include_context=False):
    found = []
    for tokens in _shell_commands(command):
        while tokens and (re.match(r'^[A-Za-z_][A-Za-z_0-9]*=', tokens[0]) or tokens[0] in ('command', 'env')):
            tokens = tokens[1:]
        if not tokens:
            continue
        binary = Path(tokens[0]).name
        arguments = tokens[1:]
        if binary == 'git':
            relocated = False
            while arguments:
                option = arguments[0]
                if option in ('-C', '-c', '--git-dir', '--work-tree'):
                    relocated |= option != '-c'
                    arguments = arguments[2:]
                elif option.startswith(('--git-dir=', '--work-tree=')) or (option.startswith('-C') and len(option) > 2):
                    relocated = True
                    arguments = arguments[1:]
                else:
                    break
            if arguments and (arguments[0] in ('commit', 'push', 'merge', 'worktree') or arguments[:2] == ['checkout', '-b']):
                found.append((binary, arguments, relocated) if include_context else (binary, arguments))
        elif binary == 'gh' and len(arguments) >= 2 and arguments[0] == 'pr' and arguments[1] in ('create', 'merge'):
            found.append((binary, arguments, False) if include_context else (binary, arguments))
    return found


class _GitPattern:
    """Regex-like search interface with shell-aware command position checks."""
    def search(self, command):
        return git_commands(command) or None


# Kept regex-like for the spike's existing `GIT_RE.search(command)` call sites.
GIT_RE = _GitPattern()
MODEL_SECTIONS = ('Asked', 'Decided', 'Open', 'Risks', 'Friction')
# A section line that only says the section is empty or withheld: the whole
# line after its bullet, with any trailing punctuation. A real item that
# begins with the same words is kept. The record's readers use the same rule.
PLACEHOLDER_RE = re.compile(r'(?:[-*+]\s*)?(?:none (?:recorded|noted)|not derived(?: \([^()]*\))?'
                            r'|\(withheld\b[^()]*\))[\s.,;:!?]*', re.I)
# The bound on an Open line the record raises itself, its bullet included.
OPEN_LINE = 160


def _words(text):
    return tuple(re.findall(r'\w+', text.casefold()))


def _currency_safe(line):
    return not (re.search(r'[$€£]\s?\d', line) or
                (re.search(r'\b(?:salary|equity|compensation|valuation|runway|revenue)\b', line, re.I)
                 and re.search(r'\b\d[\d,.]*\s*[kKM]\b', line)))


def _paraphrase_evidence(facts):
    """Index source utterances once for the shared-text paraphrase check."""
    source = [item['text'] for key in ('prompt_texts', 'assistant_texts') for item in facts.get(key, [])]
    structured = []
    for tool in facts.get('tools', {}).values():
        if tool.get('name') != 'AskUserQuestion':
            continue
        questions = _mapping(tool.get('input')).get('questions')
        for question in questions if isinstance(questions, list) else []:
            question = _mapping(question)
            structured.append((_string(question.get('question')), 3))
            options = question.get('options')
            for option in options if isinstance(options, list) else []:
                label = _string(_mapping(option).get('label'))
                source.extend((label, _choice_label(label)))
    for item in facts.get('decided', []):
        structured.append((item['question'], 3))
        if not item.get('selected_labels'):
            structured.append((item['answer'], 2))
    runs, short, structured_short = set(), set(), set()
    for text, minimum in structured:
        source.append(text)
        words = _words(text)
        if minimum <= len(words) < 12:
            structured_short.add(words)
    for text in source:
        words = _words(text)
        if 0 < len(words) < 12:
            short.add(words)
        runs.update(words[i:i + 12] for i in range(max(0, len(words) - 11)))
    return runs, short, structured_short


def _paraphrase_safe(text, evidence):
    """Also reject question phrases (3+ words) and free-text phrases (2+)."""
    runs, short, structured_short = evidence
    words = _words(text)
    return (words not in short
            and not any(words[i:i + 12] in runs for i in range(max(0, len(words) - 11)))
            and not any(words[i:i + len(source)] == source for source in structured_short
                        for i in range(len(words) - len(source) + 1)))


def _choice_label(label):
    return re.sub(r'\s*\(recommended\)\s*$', '', label, flags=re.I)


def _decision_header(item):
    header = _short(item.get('header'), 40) or 'Question'
    if not _currency_safe(_string(item.get('header'))) or not _currency_safe(header):
        return 'Question'
    return header


def guard_model_sections(model_output, facts):
    """Keep named sections only; reject verbatim runs, whole short blocks, money."""
    raw = {name: [] for name in MODEL_SECTIONS}
    current = None
    for line in (model_output or '').splitlines():
        heading = re.fullmatch(r'\s*##\s+([^#]+?)\s*', line)
        if heading:
            current = heading.group(1) if heading.group(1) in raw else None
        elif current and line.strip():
            raw[current].append(line.strip())
    evidence = _paraphrase_evidence(facts)
    result = {}
    for name, lines in raw.items():
        kept = []
        for line in lines:
            if not _paraphrase_safe(line, evidence):
                continue
            if not _currency_safe(line):
                continue
            kept.append(line)
        if name == 'Asked':
            kept = kept[:12]
        elif name == 'Friction':
            kept = kept[:1]
        result[name] = '\n'.join(kept) if kept else '(withheld: paraphrase check failed)'
    return result


# Descriptive alias for consumers testing the mechanical paraphrase check.
paraphrase_guard = guard_model_sections


def _relative_file(value, repo):
    if not isinstance(value, str) or not value:
        return None
    try:
        candidate = Path(value) if Path(value).is_absolute() else repo / value
        physical, root = candidate.resolve(), project_root(repo)
        if physical.is_relative_to(root):
            # Preserve the supplied repo-relative spelling when it is safe.
            logical = Path(os.path.abspath(candidate))
            relative = logical.relative_to(root) if logical.is_relative_to(root) else physical.relative_to(root)
            if relative.parts[:2] == ('.claude', 'worktrees') and len(relative.parts) > 3:
                relative = Path(*relative.parts[3:])
            return _inline(relative.as_posix())
        # Shared memory is a documented repo-owned symlink. Other symlinks
        # escaping the project are counted without exposing their paths.
        for memory in (repo / 'memory', root / 'memory'):
            if memory.is_dir() and physical.is_relative_to(memory.resolve()):
                return _inline((Path('memory') / physical.relative_to(memory.resolve())).as_posix())
    except (OSError, ValueError, RuntimeError):
        pass
    return None


def _git_identifier(value, allow_slashes=False):
    """A bounded ref/name, never an option, URL, credential or filesystem path."""
    if not isinstance(value, str) or len(value) > 128 or '..' in value:
        return None
    pattern = r'[A-Za-z0-9][A-Za-z0-9._-]*(?:/[A-Za-z0-9][A-Za-z0-9._-]*)*' if allow_slashes else r'[A-Za-z0-9][A-Za-z0-9._-]*'
    return value if re.fullmatch(pattern, value) else None


def _git_operation(args, repo, relocated=False):
    """Render allowlisted operation fields instead of copying Git arguments."""
    operation = args[0]
    if operation == 'push':
        # Options with values must not shift their values into the remote/ref
        # slots. Unknown options are omitted along with any attached value.
        positional, skip = [], False
        for argument in args[1:]:
            if skip:
                skip = False
            elif argument in ('--repo', '--receive-pack', '--exec', '-o', '--push-option'):
                skip = True
            elif not argument.startswith('-'):
                positional.append(argument)
        if not positional:
            return 'git push'
        remote = _git_identifier(positional[0]) or '<redacted-remote>'
        refs = [safe for argument in positional[1:] if (safe := _git_identifier(argument))]
        return 'git push ' + ' '.join([remote, *refs[:8]])
    if operation == 'merge':
        refs, skip = [], False
        for argument in args[1:]:
            if skip:
                skip = False
            elif argument in ('-m', '--message', '-F', '--file', '-s', '--strategy', '-X', '--strategy-option'):
                skip = True
            elif not argument.startswith('-') and (safe := _git_identifier(argument, allow_slashes=True)):
                refs.append(safe)
        return 'git merge' + (' ' + ' '.join(refs[:8]) if refs else '')
    if operation == 'worktree':
        if len(args) < 2 or args[1] not in ('add', 'remove'):
            return 'git worktree'
        if relocated:
            return 'git worktree ' + args[1]
        # Paths are optional record data: include only a physically admitted
        # repository-relative path, never a caller's outside path.
        path, skip = None, False
        for argument in args[2:]:
            if skip:
                skip = False
            elif argument in ('-b', '-B', '--reason'):
                skip = True
            elif not argument.startswith('-'):
                try:
                    candidate = Path(argument) if Path(argument).is_absolute() else repo / argument
                    if candidate.resolve().is_relative_to(project_root(repo)):
                        path = _relative_file(argument, repo)
                except (OSError, ValueError, RuntimeError):
                    pass
                break
        return 'git worktree ' + args[1] + (' ' + path if path else '')
    if operation == 'checkout':
        branch = _git_identifier(args[2], allow_slashes=True) if len(args) > 2 else None
        return 'git checkout -b' + (' ' + branch if branch else '')
    return 'git ' + operation


HOOK_ITEM = 'hook asked for a decision and got none: '


def _shareable(text, facts, evidence):
    """Whether text may enter the shared record: it encodes as UTF-8 and holds
    nothing the record withholds, neither a known free-text answer nor a
    currency figure, nor words the paraphrase check keeps out of model lines."""
    try:
        text.encode('utf-8')
    except UnicodeEncodeError:
        return False
    return withhold_free_text(text, facts) == text and _currency_safe(text) and _paraphrase_safe(text, evidence)


def _raised_items(facts, flaked):
    """The Friction line for hook prompts left without a decision, by hook and
    most frequent first, and the Open lines the record raises itself: a hook
    left undecided three times or more in the session, and each CI job that
    flaked on its merges. Hooks are counted by their own names, and only the
    rendering withholds: a name or file is checked as found, then in its
    whole line and in the line cut to length; a name that fails is written
    `hook`, a file that fails is left off. A job is checked as found, then in
    its rewritten line, and a job that fails is left out. The lines name no
    owner, so the same hook and file, or the same job, raise one line in
    every session."""
    requests = [item for item in facts.get('hook_requests', []) if isinstance(item, dict) and not item.get('decided')]
    evidence, checked = (_paraphrase_evidence(facts) if requests or flaked else None), {}

    def shared(text):
        if text not in checked:
            checked[text] = _shareable(text, facts, evidence)
        return checked[text]

    fit = lambda text: _short(text, OPEN_LINE - 2)
    label = lambda name: _inline(name) if name and shared(name) else 'hook'
    undecided = [(_string(item.get('hook')), _string(item.get('file'))) for item in requests]
    by_hook = Counter(name for name, _ in undecided)
    rendered = Counter()
    for name, count in by_hook.items():
        rendered[label(name)] += count
    friction = '- hook prompts without a decision: '
    if facts.get('harness') not in (None, 'claude'):
        friction += 'unavailable in this harness'
    elif rendered:
        friction += str(sum(rendered.values()))
        named = f'{friction} (' + ', '.join(f'{name} {count}' for name, count in
                                           sorted(rendered.items(), key=lambda pair: (-pair[1], pair[0]))) + ')'
        friction = named if shared(named) else friction
    else:
        friction += '0'
    lines = []
    for name, count in sorted(by_hook.items(), key=lambda pair: (-pair[1], label(pair[0]), pair[0])):
        if count < IGNORED_REQUESTS_RAISED:
            continue
        files = Counter(file for hook, file in undecided if hook == name and file and shared(file))
        candidates = [f'{HOOK_ITEM}{label(name)} on {_inline(files.most_common(1)[0][0])}'] if files else []
        candidates.append(HOOK_ITEM + label(name))
        lines.append(next((fit(line) for line in candidates if shared(line) and shared(fit(line))), HOOK_ITEM + 'hook'))
    for job in flaked or ():
        job = _string(job)
        # An Open line's owner follows its last ' — ', so the line keeps no em dash of the job's.
        line = 'CI flaked: ' + job.replace('—', '–')
        if job.strip() and shared(job) and shared(line) and shared(fit(line)):
            lines.append(fit(line))
    return friction, list(dict.fromkeys(lines))


def cost_coverage(facts, source, unpriced=None):
    """Coverage of the observed cost scope, not proof of invoice completeness.

    Legacy facts without usage provenance remain partial. A parent ledger
    cannot establish that its workers' costs were included. Explicit outcome
    attribution separately accounts for other driver/retry/review sessions.
    """
    calls = list(facts.get('calls', {}).values())
    if source == 'unavailable' or not calls:
        return 'unavailable'
    if (facts.get('parse_failures') or facts.get('subagent_failures')
            or facts.get('cost_scope_complete') is False):
        return 'partial'
    harness = facts.get('harness')
    if harness == 'codex':
        complete = (not (unpriced or {}).get('models')
                    and all(call.get('usage_complete') is True for call in calls))
    elif harness in ('pi', 'prime'):
        complete = source == 'ledger' and all(call.get('cost_complete') is True for call in calls)
    elif source == 'estimate':
        complete = all(call.get('usage_complete') is True
                       and _string(call.get('model')).split('[')[0] in PRICES for call in calls)
    else:
        # A final running-total event after the last main call establishes the
        # local ledger horizon. Descendant inclusion is not established by it.
        states = facts.get('costs', [])
        final = states[-1] if states else {}
        try:
            stamp = _ts(final.get('timestamp'))
        except (ValueError, TypeError, AttributeError):
            stamp = None
        complete = (not facts.get('subagents') and stamp is not None
                    and stamp >= max((call.get('ts') or 0 for call in calls), default=0)
                    and _number(final.get('totalCostUSD'), None) is not None)
    return 'complete' if complete else 'partial'


def outline(path, repo=None, model_output=None, detail='outline', topic='session', author='', friction_reason=None, git_log=None, person=None, flaked=()):
    """Build ordered sections and metadata; no writes, subprocesses or model calls.

    `path` may be a facts dictionary from read_transcript/load_session. git_log
    is optional preobtained `%h %s` text; the reader never invokes git itself.
    `flaked` names the CI jobs that flaked on merges this session made, as the
    caller read them from the gate ledger.
    """
    facts = path if isinstance(path, dict) else read_transcript(path)
    repo = Path(os.path.abspath(repo or os.getcwd()))
    tools = list(facts.get('tools', {}).values())
    calls = list(facts.get('calls', {}).values())
    first, last = facts.get('first'), facts.get('last')
    seconds = max(0, (last or first or 0) - (first or last or 0))
    duration = _clock(seconds)
    # Active time sums the gaps under five minutes between events, inside the
    # wall clock above; duration keeps the idle stretches, as it always has.
    start = first if first is not None else last
    active_seconds = sum(max(0, min(end, start + seconds) - max(begin, start))
                         for begin, end in facts.get('active_spans', [])) if start is not None else 0
    active = _clock(active_seconds)
    harness = facts.get('harness')
    cost, by_model = session_cost(facts.get('costs', []))
    unpriced = None
    if harness == 'codex':
        cost, by_model, unpriced = list_price(calls)
        source = 'list price' if by_model else 'unavailable'
    else:
        source = 'ledger' if facts.get('costs') else 'estimate'
        if source == 'estimate':
            cost = estimate_cost(calls)
    model = guard_model_sections(model_output, facts) if model_output is not None else {name: 'not derived (model unavailable)' for name in MODEL_SECTIONS}
    result_detail = detail if model_output is not None else 'outline-deterministic'
    files, outside = set(), set()
    # Native harnesses can report many changed files in one completed tool item.
    # Their readers normalize FILE events without retaining outside path names.
    if facts.get('harness') in ('codex', 'pi', 'prime'):
        for kind, _, detail in facts.get('events', []):
            if kind != 'FILE' or ' ' not in detail:
                continue
            value = detail.split(' ', 1)[1]
            if value.startswith('<outside:'):
                outside.add(value)
            elif (relative := _relative_file(value, repo)) is not None:
                files.add(relative)
    recalls = Counter()
    recall_failures = Counter()
    recall_failures_by_op = Counter()
    # A harness error is a result the harness flagged with its own error body; a
    # command that ran and returned a non-zero status is counted on its own.
    errors, exits = Counter(), Counter()
    commits, git_lines = [], []
    sleeps, guards, published, notifications = [], 0, 0, 0
    for tool in tools:
        name, inp = _inline(tool.get('name')), _mapping(tool.get('input'))
        if tool.get('error'):
            (exits if tool.get('nonzero_exit') else errors)[name or 'unknown'] += 1
            # One refusal is one count, however many of the guard's phrases it carries.
            guards += bool(GUARD_RE.match(_string(tool.get('result'))))
        if name in ('Write', 'Edit', 'NotebookEdit'):
            value = _string(inp.get('file_path')) or _string(inp.get('notebook_path'))
            relative = _relative_file(value, repo)
            if relative is not None:
                files.add(relative)
            elif value:
                outside.add(value)
        if name != 'Bash':
            continue
        command = _string(inp.get('command'))
        match = SEARCH_RE.search(command)
        if match:
            op = match.group(1)
            kind = (KIND_RE.search(command) or [None, None])[1] or ('keyword' if op == 'find' else '-')
            recalls[(op, kind)] += 1
            failure = _recall_failure(tool.get('result', ''), tool.get('error')) or tool.get('attach_failure')
            if failure:
                recall_failures[(kind, failure)] += 1
                recall_failures_by_op[(op, kind)] += 1
        sleep = SLEEP_RE.match(command)
        if sleep:
            sleeps.append(float(sleep.group(1)))
        published += bool(re.search(r'\bpublish-artifact(?:\.sh)?\b', command))
        notifications += bool(re.search(r'\bnotify\.sh\b', command))
        for binary, args, relocated in git_commands(command, include_context=True):
            if binary == 'git' and args[0] == 'commit':
                subject = None
                for index, token in enumerate(args):
                    if token in ('-m', '--message') and index + 1 < len(args):
                        subject = args[index + 1].split('\n', 1)[0]
                        break
                    if token.startswith('--message='):
                        subject = token.split('=', 1)[1].split('\n', 1)[0]
                        break
                    if token.startswith('-') and not token.startswith('--') and 'm' in token[1:]:
                        suffix = token.split('m', 1)[1]
                        subject = (suffix or (args[index + 1] if index + 1 < len(args) else '')).split('\n', 1)[0]
                        break
                label = 'git commit' + (': ' + _short(subject, 240) if subject else '')
                commits.append(label)
            elif binary == 'gh':
                label = 'gh ' + ' '.join(args[:2])
                if args[1] == 'merge' and len(args) > 2 and args[2].isdigit():
                    label += ' #' + args[2]
                numbers = re.findall(r'(?:/pull/|#)(\d+)\b', tool.get('result', ''))
                if numbers:
                    label += ' · ' + ', '.join('#' + n for n in dict.fromkeys(numbers))
            else:
                label = _git_operation(args, repo, relocated)
            label = _inline(label)
            if label not in git_lines:
                git_lines.append(label)
    verified = [_inline(line) for line in (git_log or '').splitlines() if line.strip()]
    commit_count = len(verified) if git_log is not None else len(commits)
    recall_count, failed = sum(recalls.values()), sum(recall_failures.values())
    sections = {'Summary': f'{duration} on {topic}; {commit_count} commits, {len(files) + len(outside)} files, {recall_count} recalls ({failed} failed); ${cost:,.2f}'}
    for name in ('Asked', 'Decided', 'Open', 'Risks'):
        sections[name] = model[name]
    multiple_days = (first is not None and last is not None and
                     datetime.fromtimestamp(first).date() != datetime.fromtimestamp(last).date())
    chosen = []
    for item in facts.get('decided', []):
        when = _hm(item.get('ts'))
        if not multiple_days:
            when = when[-5:]
        header = _decision_header(item)
        labels = item.get('selected_labels') or []
        answer = ', '.join(_choice_label(label) for label in labels) if labels else 'a free-text answer'
        rendered_answer = _short(answer, 160)
        if not _currency_safe(answer) or not _currency_safe(rendered_answer):
            continue
        who = _inline(person or author or 'the person')
        chosen.append(f'- {header}: {rendered_answer} — {who}, {when}')
    if chosen:
        derived = [line for line in model['Decided'].splitlines() if not PLACEHOLDER_RE.fullmatch(line.strip())]
        sections['Decided'] = '\n'.join([*chosen, *derived])
    hook_friction, raised = _raised_items(facts, flaked)
    if raised:
        # After the model's own open items; the section exists even when it wrote none.
        kept = [line for line in model['Open'].splitlines() if not PLACEHOLDER_RE.fullmatch(line.strip())]
        sections['Open'] = '\n'.join([*kept, *('- ' + line for line in raised)])
    if result_detail == 'full':
        sections['Prompts'] = '\n'.join(withhold_free_text(f"- {_hm(item['ts'])[-5:]} {item['text'][:700]}", facts) for item in facts.get('prompt_texts', [])) or 'none recorded'
        sections['Said'] = '\n'.join(withhold_free_text(f"- {_hm(item['ts'])[-5:]} {item['text'][:500]}", facts) for item in facts.get('said_texts', [])) or 'none recorded'
    git_groups = []
    if git_lines:
        git_groups.append("attempted (from the session's commands):\n" + '\n'.join('- ' + line for line in git_lines))
    if verified:
        git_groups.append('verified (in the repository):\n' + '\n'.join('- ' + line for line in verified))
    sections['Commits and PRs'] = '\n\n'.join(git_groups) or 'none recorded'
    file_lines = ['- ' + name for name in sorted(files)[:40]]
    if len(files) > 40:
        file_lines.append(f'+{len(files) - 40} more')
    if outside:
        file_lines.append(f'outside the repo: {len(outside)} files')
    sections['Files'] = '\n'.join(file_lines) or 'none recorded'
    memory = [f'- {op}/{kind}: {count} calls, {recall_failures_by_op[(op, kind)]} failed' for (op, kind), count in sorted(recalls.items())]
    memory.extend([f'- publish-artifact: {published} calls', f'- notify.sh: {notifications} calls'])
    memory.extend('- ' + name for name in sorted(files) if name.startswith('memory/'))
    sections['Memory and artifacts'] = '\n'.join(memory)
    sections['Related'] = '\n'.join('- ' + name for name in sorted(files) if name.startswith(('memory/handoffs/', 'memory/wraps/'))) or 'none recorded'
    friction = [f'- tool errors: ' + (', '.join(f'{name} {count}' for name, count in sorted(errors.items())) or '0'),
                '- non-zero exits: ' + (', '.join(f'{name} {count}' for name, count in sorted(exits.items())) or '0'),
                f'- worktree-guard refusals: {guards}',
                '- recall failures: ' + (', '.join(f'{kind}/{failure} {count}' for (kind, failure), count in sorted(recall_failures.items())) or '0'),
                f'- sleep commands: {len(sleeps)}, {sum(sleeps) / 60:.1f} minutes',
                f"- compactions: {facts.get('compactions', 0)}",
                hook_friction]
    if facts.get('subagent_failures'):
        friction.append(f"- subagent transcripts unavailable: {facts['subagent_failures']}")
    if friction_reason:
        friction.append('- ' + str(friction_reason))
    friction.append(model['Friction'])
    sections['Friction'] = '\n'.join(friction)
    reads = [c['cache_read'] for c in calls if c.get('agent') == 'main' and c.get('cache_read')]
    cost_lines = [f'- total: ${cost:,.2f} ({source})']
    coverage = cost_coverage(facts, source, unpriced)
    if harness == 'codex':
        inputs = sum(_number(call.get('input')) for call in calls)
        cached = sum(_number(call.get('cache_read')) for call in calls)
        outputs = sum(_number(call.get('output')) for call in calls)
        tokens = f'- tokens: {inputs} input ({cached} cached), {outputs} output'
        models = ', '.join(sorted(unpriced['models']))
        if not calls:
            tokens += '; cost not derived (no token usage recorded)'
        elif source == 'unavailable':
            tokens += f'; cost not derived (no price for {models})'
        elif models:
            tokens += f"; not priced: {unpriced['input']} input, {unpriced['output']} output (no price for {models})"
        cost_lines.append(tokens)
    cost_lines.extend(f'- {_inline(name)}: ${amount:,.2f}' for name, amount in sorted(by_model.items()))
    if source == 'list price':
        cost_lines.append('- priced at list; a subscription account pays a flat rate')
    cost_lines.extend([f'- cache-read tokens p50 per main-thread call: {_pct(reads, .5) or 0:,}', f'- model calls: {len(calls)}', f'- tool calls: {len(tools)}'])
    cost_lines.append(f'- observed cost coverage: {coverage}')
    sections['Cost'] = '\n'.join(cost_lines)
    return {'body': '\n\n'.join(f'## {name}\n{body}' for name, body in sections.items()) + '\n', 'sections': sections,
            'detail': result_detail, 'cost': cost, 'cost_usd': cost, 'cost_source': source, 'cost_by_model': dict(by_model),
            'cost_coverage': coverage,
            'cost_sessions': sorted(set(facts.get('cost_sessions') or
                                        ([facts['session']] if facts.get('session') else []))),
            'duration': duration, 'duration_seconds': seconds, 'active': active, 'active_seconds': active_seconds,
            'first': first, 'last': last,
            'branch': facts.get('branch') or next(iter(facts.get('branches', [])), ''),
            'commits': commit_count, 'files': len(files) + len(outside), 'recalls': recall_count,
            'recall_failures': failed, 'model_calls': len(calls), 'tool_calls': len(tools)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('facts', 'trail', 'outline', 'gate', 'probe'))
    parser.add_argument('transcript')
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--repo', default=os.environ.get('EGREGORE_ROOT') or os.getcwd())
    args = parser.parse_args()
    header = read_header(args.transcript)
    harness = _header_format(header)
    admitted = (within_instance_cwd(_mapping(header.get('payload') if harness == 'codex' else header).get('cwd'), args.repo)
                if harness in ('codex', 'pi') else
                within_instance(args.transcript, Path.home() / '.claude' / 'projects', instance_prefix(args.repo)))
    if args.command == 'gate':
        return 0 if admitted else 1
    if not admitted:
        print('transcript is outside this instance', file=sys.stderr)
        return 1
    if args.command == 'probe':
        return 0 if probe_format(args.transcript, Path.home() / '.claude' / 'projects',
                                 instance_prefix(args.repo)) is not None else 1
    facts = read_session(args.transcript, root=args.repo)
    if args.command == 'facts':
        print(json.dumps(facts, default=str) if args.json else json.dumps(facts, indent=2, default=str))
    elif args.command == 'trail':
        print(json.dumps(trail(facts), default=lambda value: sorted(value)) if args.json else render_trail(facts))
    else:
        result = outline(facts, repo=args.repo)
        print(json.dumps(result, default=str) if args.json else result['body'], end='\n' if args.json else '')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
