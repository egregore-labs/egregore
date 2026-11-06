"""Harness-neutral command adapter for organizational context.

Claude, Codex, Pi, Prime, and shell skills enter the Egregore Runtime here.
This module deliberately knows no QMD, graph, Supabase, or filesystem-index
implementation details.  Infrastructure is composed behind ``local_runtime``.
"""

from __future__ import annotations

from .investigation_guidance import INVESTIGATION_GUIDANCE, RECALL_WORKFLOW_GUIDANCE, investigation_guidance

import argparse
import fcntl
import hashlib
from io import StringIO
import json
import os
import re
import stat
import subprocess
import sys
import threading
import time
import unicodedata
import uuid
from contextlib import contextmanager, nullcontext, redirect_stdout
from contextvars import ContextVar
from dataclasses import asdict
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .contracts import (
    EvidenceItem,
    OrgContext,
    Permission,
    PolicyDecision,
    RetrievalMode,
    RetrievalRequest,
    TemporalScope,
)
from .errors import AuthorizationDenied, EgregoreRuntimeError
from .identity import actor_lexical_formulations, organization_member_presentations
from .investigation_contracts import InvestigationRequest, decode_request
from . import episode_binding
from .runtime import EgregoreRuntime, local_runtime
from .policy import is_admin
from .installation import installation_key, installation_root
from .optional_modules import optional_module

_record = optional_module(".record")
record_notice = _record.notice if _record is not None else lambda *args, **kwargs: None
member_cli = optional_module(".member_cli")
from .member_authority import MemberAuthorityError


# A later package adds a command as a new module with register(commands)
# and one line here; relative names resolve inside each Runtime bundle.
_COMMAND_MODULES: tuple[str, ...] = (".access_cli", ".mind_cli", ".outputs_cli")

_HISTORICAL_SCOPE = re.compile(
    r"\b(history|historical|previous|older|old decision|superseded|what changed|how .* evolv(?:e|ed))\b",
    re.I,
)
_RECALL_LEX_PREFIXES = tuple(
    re.compile(pattern, re.I)
    for pattern in (
        r"^\s*(?:what\s+)?did\s+we\s+(?:decide|discuss|agree|say|cover|talk\s+about)\s*(?:about|on)?\s*",
        r"^\s*have\s+we\s+(?:discussed|decided|covered|talked\s+about|looked\s+at)\s*(?:about|on)?\s*",
        r"^\s*do\s+we\s+have\s+(?:any\s+)?(?:notes?|docs?|anything|something)\s*(?:about|on)?\s*",
        r"^\s*what\s+(?:exact\s+)?(?:invariants?|decisions?|details?|content|status)\s+"
        r"(?:are|is)\s+(?:recorded|listed|defined|contained)\s+in\s+(?:the\s+)?",
    )
)
_WORKTREE_PATH_PATTERN = re.compile(
    r"(?P<path>/[^\s`\"']*?/\.claude/worktrees/[^\s`\"']+)",
)


def _root() -> Path:
    if pinned := _invocation_root.get():
        return pinned
    configured = os.environ.get("EGREGORE_ROOT")
    return Path(configured).resolve() if configured else Path.cwd().resolve()


def _prompt_root(payload: dict[str, object], default_root: Path) -> Path:
    """Select an explicitly named worktree inside this Egregore instance.

    Harness instructions and hooks are loaded when a session starts, so a
    continuation prompt may name a newer task worktree while the process still
    stands in the instance root. Runtime retrieval must follow that explicit
    workspace instead of silently querying the stale launch checkout.
    """

    prompt = str(payload.get("prompt") or payload.get("user_prompt") or "")
    root_text = str(default_root.resolve())
    marker = f"{os.sep}.claude{os.sep}worktrees{os.sep}"
    instance_root = Path(root_text.split(marker, 1)[0]) if marker in root_text else default_root
    worktree_root = (instance_root / ".claude" / "worktrees").resolve()
    for match in _WORKTREE_PATH_PATTERN.finditer(prompt):
        raw = match.group("path").rstrip(".,;:)]}")
        candidate = Path(raw).resolve()
        try:
            candidate.relative_to(worktree_root)
        except ValueError:
            continue
        if candidate.is_dir() and (candidate / ".git").exists() and (candidate / "egregore.json").is_file():
            return candidate
    return default_root


_episode_session: ContextVar[str | None] = ContextVar("observe_episode_session", default=None)
_prompt_binding: ContextVar[episode_binding.EpisodeBinding | None] = ContextVar('prompt_investigation_binding',default=None)
_invocation_root: ContextVar[Path | None] = ContextVar('investigation_root',default=None)

def _runtime(root, *, push_remote=False):
    member = (member_cli.current() if member_cli is not None else None)
    return (member.runtime(root, push_remote=push_remote) if member
            else local_runtime(root, push_remote=push_remote))


@contextmanager
def _invocation(root, reference=None):
    """A native prompt's explicit reference is stronger than shared shell state."""
    member = (member_cli.current() if member_cli is not None else None)
    if member:
        binding = (episode_binding.resolve(root, reference) if reference
                   else episode_binding.resolve_native(root, harness="durable", session_id=member.session_id))
        if binding is None or binding.session_id != member.session_id:
            raise MemberAuthorityError()
        session_token = _episode_session.set(member.session_id)
        binding_token = _prompt_binding.set(binding)
        root_token = _invocation_root.set(root)
        try:
            yield binding
        finally:
            _invocation_root.reset(root_token)
            _prompt_binding.reset(binding_token)
            _episode_session.reset(session_token)
        return
    binding = _prompt_binding.get()
    if binding is None and (reference or os.environ.get('EGREGORE_EPISODE_ID')):
        binding = episode_binding.resolve(root,reference or os.environ['EGREGORE_EPISODE_ID'])
    if binding is None:
        native_session = os.environ.get('EGREGORE_NATIVE_SESSION_ID')
        native_harness = os.environ.get('EGREGORE_NATIVE_HARNESS', 'shell')
        if not native_session:
            native_session = os.environ.get('CODEX_THREAD_ID')
            native_harness = 'codex'
        if native_session:
            binding = episode_binding.resolve_native(root, harness=native_harness, session_id=native_session)
    if binding is None and episode_binding.requires_binding(root):
        raise episode_binding.EpisodeBindingError('episode reference required; pass --episode from the current prompt context')
    token = _episode_session.set(binding.session_id) if binding else None
    binding_token = _prompt_binding.set(binding) if binding else None
    nested = _invocation_root.get() == root
    root_token = _invocation_root.set(root)
    try:
        if binding or nested or _episode_session.get():
            yield binding
        else:
            with _observe_episode(root):
                yield binding
    finally:
        _invocation_root.reset(root_token)
        if token is not None:
            _episode_session.reset(token)
        if binding_token is not None:
            _prompt_binding.reset(binding_token)


def _execute_investigation(root, harness, request, *, runtime=None, actor=None, reference=None, request_id=None, origin='investigate'):
    with _invocation(root,reference) as binding:
        runtime = runtime or _runtime(root,push_remote=False)
        actor = actor or _actor(runtime,root,harness)
        episode_id = binding.episode_id if binding else _session_id(root)
        # Old receipts are read only as a migration bridge; new calls never write them.
        receipt = None if binding or (member_cli.current() if member_cli is not None else None) else _active_observe_receipt(root,harness)
        contexts,initial_searches,bounds=[],0,{}
        if receipt:
            contexts=[entry.get('context',{}) for entry in _receipt_requests(receipt).values()]
            if receipt.get('context') not in contexts:
                contexts.append(receipt.get('context',{}))
            initial_searches=1+int(receipt.get('follow_ups',0))
            if receipt.get('not_before'):
                bounds['_not_before']=receipt['not_before']
            if receipt.get('terminal_gap'):
                bounds['_legacy_terminal_gap']=True
        response = runtime.investigate(actor,request,episode_id=episode_id,seeds=contexts,
            initial_searches=initial_searches,initial_bounds=bounds,request_id=request_id,
            binding=binding,origin=origin)
        _mind_call.set((response, origin, request))
        return response


def _publish_result(root, response, rendered, *, private=False, harness='shell'):
    if (member_cli.current() if member_cli is not None else None):
        # Member content stays on the authenticated host's private stdout.
        # Local attachment, record and mind surfaces have their own operator
        # lifecycle and are deliberately absent from this composition.
        sys.stdout.write(rendered)
        return False
    from .private_result import supports_attachment
    # An invalidated prompt cannot consume an attachment. Keep its error visible;
    # never use this fallback for successful evidence from a failed binding.
    private = private and response.get('error_code') not in {'episode_closed', 'binding_required'}
    try:
        private = private and supports_attachment(root, response['episode_id'], harness)
    except (OSError, ValueError, EgregoreRuntimeError):
        if response['ok']:
            raise
        private = False
    receipt = None
    if private:
        from .private_result import prepare
        reference=response['episode_id']
        session=episode_binding.resolve(root,reference).session_id if reference.startswith('ep_') else _session_id(root)
        receipt = prepare(root,response,rendered,session)
        print(receipt)
    else:
        from .private_result import record_stdout
        try:
            record_stdout(root,response,rendered)
        except (OSError, ValueError, KeyError, EgregoreRuntimeError):
            if response['ok']:
                raise
            # A missing/corrupt receipt must not replace the operation's error.
        sys.stdout.write(rendered)
    _mind_notice(root, response, rendered, harness, receipt)
    return private


# Notices for an open memory map (experiments/egregore-mind/AGENT-SPEC.md §3.6).
# Inert unless a map is open for this workspace. A notice goes to this
# checkout's door ($MIND_HOME, else experiments/egregore-mind/.mind) when its
# door.json names this checkout as the one it serves; only if that door took
# nothing, to the instance door (.egregore/runtime/mind under the installation
# this checkout belongs to) when its door.json names that installation. Either
# door needs a heartbeat under 3 s old and must be the user's alone, and no
# folder below the checkout or installation may be a link. Notices may cross
# the checkouts of one installation, never into another instance; `mind`
# requests stay per checkout (§3.3).
# Each notice is one small file of paths, counts and ids, never prompt, query or
# document text, and writing it never changes, fails or holds up the call it
# describes: every filesystem step runs on a writer thread the call waits for
# at most 0.1 s.
_mind_call: ContextVar[tuple | None] = ContextVar('mind_call', default=None)
_MIND_KINDS = ('seen-', 'asked-', 'delivered-')
_MIND_WAITING = 1000  # files a door may hold before notices are dropped (soft: writers do not lock)
_MIND_LARGEST = 65536  # bytes; a larger record is not written
_MIND_WRITERS = threading.BoundedSemaphore(4)  # stuck writers a process may hold; then notices drop
_MIND_WORKSPACE = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,63}')


def _mind_send(root, kind, harness, session, note):
    if _record is None:  # the Mind runtime is not installed
        return
    configured = os.environ.get('MIND_HOME')
    native, codex = os.environ.get('EGREGORE_NATIVE_SESSION_ID'), os.environ.get('CODEX_THREAD_ID')
    # Codex first: a Codex worker started from a Claude or Pi shell inherits that session's
    # EGREGORE_NATIVE_* variables, and its prompt hook names it codex/<thread>, so its searches must
    # too. The reverse nesting (Claude or Pi run inside a Codex shell) is split across two agents.
    environment = (_mind_actor('codex', codex) if codex else
                   _mind_actor(os.environ.get('EGREGORE_NATIVE_HARNESS') or 'agent', native) if native else '')
    if kind == 'asked' and harness == 'codex' and codex:
        actor = _mind_actor('codex', codex)  # one Codex session is one agent, whatever its hook calls itself
    elif kind == 'delivered':
        actor = _mind_actor(harness, session) if session else ''  # only the hook that attached the result
    else:
        actor = _mind_actor(harness, session) if session else environment  # the hook's own session first
    if not _MIND_WRITERS.acquire(blocking=False):
        return

    def write():
        try:
            _mind_write(root, configured, kind, harness, actor, note)
        except Exception:
            pass  # no map, a stopped map, or a door it must not use
        finally:
            _MIND_WRITERS.release()

    try:
        writer = threading.Thread(target=write, name='mind-notice', daemon=True)
        writer.start()
    except BaseException:
        _MIND_WRITERS.release()
        raise
    writer.join(0.1)


def _mind_actor(harness, session):
    """`<harness>/<session>` exactly as the map's bridge accepts an actor, else ''."""
    harness = 'claude' if harness == 'claude-code' else str(harness or '')
    if re.fullmatch(r'[a-z][a-z0-9-]{0,19}', harness) and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}', str(session)):
        return f'{harness}/{session}'
    return ''


def _mind_write(root, configured, kind, harness, actor, note):
    """One notice: this checkout's door, else the instance door. True once one is renamed into place."""
    here = os.path.realpath(root)
    instance = os.path.realpath(installation_root(here))
    folder = os.path.basename(here)
    fields = {'actor': actor, 'harness': str(harness)[:40],
              'workspace': 'main' if here == instance else folder if _MIND_WORKSPACE.fullmatch(folder) else 'other',
              **note}
    checkout = [configured, 'door'] if configured else [str(root), 'experiments', 'egregore-mind', '.mind', 'door']
    return (_mind_door(checkout, 'root', here, kind, fields) or  # MIND_HOME never reaches the instance door
            _mind_door([instance, '.egregore', 'runtime', 'mind', 'door'], 'instance', instance, kind, fields))


def _mind_door(walk, field, expected, kind, fields):
    """Write one notice into the live door at ``walk`` whose door.json names ``expected`` as its ``field``.

    Below the first folder none may be a link, so the door checked is the door written. True once the
    notice is renamed into place; False when the door is absent, stopped, someone else's, full, names
    another checkout or instance, or refuses the write.
    """
    held = []
    try:
        for part in walk:
            held.append(os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NONBLOCK | (os.O_NOFOLLOW if held else 0),
                                dir_fd=held[-1] if held else None))
        home, door = held[-2], held[-1]
        beat, info = os.stat('heartbeat', dir_fd=door, follow_symlinks=False), os.fstat(door)
        if (not stat.S_ISREG(beat.st_mode) or not -1 <= time.time() - beat.st_mtime <= 3
                or info.st_uid != os.getuid() or info.st_mode & 0o077):
            return False  # a stopped map, or a door someone else could open
        with os.fdopen(os.open('door.json', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=home), 'rb') as handle:
            pointer = json.loads(handle.read(4096))
        if not isinstance(pointer, dict) or pointer.get(field) != expected:
            return False  # a map serving another checkout or instance, or one that does not say which
        run = pointer.get('run')
        record = json.dumps({'v': 2, 'k': kind, 't': datetime.now(UTC).isoformat(timespec='milliseconds')
                             .replace('+00:00', 'Z'), 'run': str(run)[:40] if run else None, **fields},
                            ensure_ascii=False) + '\n'
        if len(record.encode('utf-8')) > _MIND_LARGEST:
            return False
        waiting, leftovers = 0, tuple('.' + k for k in _MIND_KINDS)
        with os.scandir(door) as entries:
            for entry in entries:
                try:
                    if entry.name.startswith(leftovers) and time.time() - entry.stat(
                            follow_symlinks=False).st_mtime > 60:
                        os.unlink(entry.name, dir_fd=door)  # a writer that died between create and rename
                        continue
                except FileNotFoundError:
                    continue  # its writer renamed it, or another writer reclaimed it, after the listing
                waiting += entry.name.lstrip('.').startswith(_MIND_KINDS)
        if waiting >= _MIND_WAITING:
            return False
        name = f'{kind}-{time.time_ns()}-{os.getpid()}-{uuid.uuid4().hex[:8]}'
        descriptor = os.open('.' + name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=door)
        try:
            with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
                handle.write(record)
            os.rename('.' + name, name, src_dir_fd=door, dst_dir_fd=door)
        except BaseException:
            os.unlink('.' + name, dir_fd=door)
            raise
        return True
    except (OSError, ValueError):
        return False  # no door here, or one it must not use: the next door may still take it
    finally:
        for descriptor in reversed(held):
            os.close(descriptor)


def _mind_asked(root, harness, payload):
    """The person asked something in this session: when and where, never what."""
    try:
        _mind_send(root, 'asked', harness, str(payload.get('session_id') or ''), {})
    except Exception:
        return


def _mind_digest(token):
    """A short name two notices share for one attachment or cursor; never the token itself."""
    return hashlib.sha256(str(token).encode()).hexdigest()[:16]


def _mind_delivered(root, harness, payload, receipt):
    """The agent's own hook attached a prepared result: the seen notice with this packet reached the agent."""
    try:
        _mind_send(root, 'delivered', harness, str(payload.get('session_id') or ''), {'packet': _mind_digest(receipt)})
    except Exception:
        return


def _mind_notice(root, response, rendered, harness, receipt=None):
    """What a find, open, query or investigate call showed the agent, or why it showed nothing.

    With ``receipt`` (Claude's attachment line) the result was only prepared: it counts as seen
    once a ``delivered`` notice with the same ``packet`` follows from the consuming hook.
    """
    if (member_cli.current() if member_cli is not None else None):
        return
    try:
        call = _mind_call.get()
        if call is None or call[0] is not response:
            return
        request = call[2].to_dict() if hasattr(call[2], 'to_dict') else dict(call[2])
        operation = request.get('operation')
        if operation not in {'discover', 'open', 'open_many'}:
            return
        projection = request.get('context_projection') or {}
        retrieval = projection.get('retrieval') or {}
        result = (response.get('result') or {}) if response.get('ok') else {}
        context, details = result.get('context') or {}, result.get('coverage_details') or {}
        def paths(values):
            return list(dict.fromkeys(p for p in values if isinstance(p, str) and p.startswith('memory/')
                                      and len(p) <= 300))[:100]
        # A result path counts only when the published text names it, plain or as JSON either way:
        # a query that missed its minimum evidence prints the gap, not the paths.
        shown = [p for p in paths([row.get('path') for row in result.get('results', ())] +
                                  [item.get('canonical_path') for item in context.get('evidence', ())])
                 if any(form in rendered for form in
                        (p, json.dumps(p)[1:-1], json.dumps(p, ensure_ascii=False)[1:-1]))]
        opened = paths([s.get('path') for s in result.get('sources', [result] if 'content' in result else ())] +
                       (shown if retrieval.get('open_sources') else []))
        kind = ({'lex': 'keyword', 'vec': 'semantic', 'lex+vec': 'hybrid'}.get(str(retrieval.get('mode')))
                or result.get('operation') or request.get('kind') or 'keyword')
        def day(value):
            return value if isinstance(value, str) and re.fullmatch(r'\d{4}-\d{2}-\d{2}', value) else None
        days = request.get('recent_days') or projection.get('recent_days')
        def count(value):
            return value if type(value) is int and 0 <= value <= 10**6 else None
        if receipt:
            from .private_result import MARKER
            receipt = json.loads(receipt.removeprefix(MARKER))['id']
        _mind_send(root, 'seen', harness, None, {
            'episode': str(response.get('episode_id') or '')[:80] or None,
            'invocation': str(response.get('invocation_id') or '')[:80] or None,
            'call': call[1], 'op': operation, 'delivery': 'attachment' if receipt else 'stdout',
            'packet': _mind_digest(receipt) if receipt else None,
            'kind': kind if operation == 'discover' and kind in
                {'filename', 'literal', 'dates', 'keyword', 'semantic', 'hybrid'} else None,
            # No query words: the kind, dates and paths say where the agent looked, never what it typed.
            # A next page carries only its cursor: `continues` names the notice whose `next` handed
            # that cursor out, and that notice holds the kind and dates this page continues.
            'continues': _mind_digest(request['cursor']) if request.get('cursor') else None,
            'next': _mind_digest(result['next_cursor']) if result.get('next_cursor') else None,
            # This call's own date arguments. Bounds the Runtime kept from earlier calls in the
            # prompt are not in its response, so these are never the whole scope searched.
            'requested': {'after': day(request.get('after')), 'before': day(request.get('before')),
                          'recent_days': days if type(days) is int and 1 <= days <= 36500 else None},
            'paths': shown, 'opened': opened,
            'searches_left': count(result.get('searches_remaining')), 'reads_left': count(result.get('reads_remaining')),
            'coverage': {'degraded': bool(result.get('degraded') or context.get('degraded')),
                         'absent_or_stale': count(details.get('stale_or_missing_count', 0)),
                         'vectors_missing': count(details.get('vector_missing_count', 0)),
                         'omitted': len(context.get('omissions') or ()),
                         'more': count(result.get('remaining_in_result_set', 0)),
                         'reach': str(result.get('coverage') or '')[:120]},
            'ok': bool(response.get('ok')), 'error': str(response.get('error_code') or '')[:40] or None})
    except Exception:
        return


# A worktree's parser and held rules can differ even when this hook's own
# source is identical. Compose and validate with that checkout's imported code,
# not just its data root. The bootstrap uses APIs present in older checkouts too.
_RESULT_CONSUMER = '''
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
sys.path.insert(0, str(root))
try:
    from egregore_runtime import private_result
    from egregore_runtime.runtime import local_runtime
    loaded = Path(private_result.__file__).resolve()
    if not loaded.is_relative_to(root.resolve()) or loaded.parent != (root / 'egregore_runtime').resolve():
        raise ValueError('packet Runtime could not be loaded from its checkout')
    for name, module in tuple(sys.modules.items()):
        if name == 'egregore_runtime' or name.startswith('egregore_runtime.'):
            filename = getattr(module, '__file__', None)
            if not filename or not Path(filename).resolve().is_relative_to(root.resolve()):
                raise ValueError('packet Runtime could not be loaded from its checkout')
    request = json.load(sys.stdin)
    runtime = local_runtime(root, push_remote=False)
    actor = runtime.resolve_actor(session_id=request['session_id'], harness=request['harness'])
    rendered = private_result.consume(root, request['id'], runtime, actor,
        session_id=request['session_id'], native_turn_id=request['native_turn_id'])
    result = {'rendered': rendered}
except Exception as error:
    result = {'error': str(error)}
print(json.dumps(result))
'''

# Context-projection packets recheck the same collection and index revision as
# the search. Keep those data-location overrides, not the harness environment.
_RESULT_CONSUMER_ENV = (
    'PATH', 'HOME', 'TMPDIR', 'LANG', 'LC_ALL', 'LC_CTYPE',
    'EGREGORE_QMD_COLLECTION', 'EGREGORE_QMD_INDEX_PATH', 'EGREGORE_QMD_RUNTIME_DIR',
)


def _validate_packet_runtime(root: Path) -> None:
    """Reject unchecked import paths anywhere in the packet's Runtime package."""
    package = root / 'egregore_runtime'

    def check(entry, regular_type):
        # lstat rejects links, including directory links that os.walk won't follow.
        if (not regular_type(entry.lstat().st_mode)
                or not entry.resolve(strict=True).is_relative_to(checkout)):
            raise ValueError('uncontained Runtime entry')

    def walk_error(error):
        raise error

    try:
        checkout = root.resolve(strict=True)
        check(package, stat.S_ISDIR)
        for directory, directories, files in os.walk(package, followlinks=False, onerror=walk_error):
            for name in directories:
                check(Path(directory) / name, stat.S_ISDIR)
            for name in files:
                check(Path(directory) / name, stat.S_ISREG)
        # Preserve the required package entry points as well as tree containment.
        for name in ('__init__.py', 'private_result.py'):
            check(package / name, stat.S_ISREG)
    except (OSError, RuntimeError, ValueError) as error:
        raise EgregoreRuntimeError('packet Runtime is not contained in its checkout') from error


def _consume_private_result(root, identifier, *, session_id, harness, native_turn_id):
    """Use the admitted packet checkout's Runtime without mixing module versions."""
    from .private_result import consume
    package = root / 'egregore_runtime'
    # Data-only Runtime roots use the installed package. A checkout carrying
    # its own package must validate with that package, with no fallback on error.
    checkout_package = package.exists() or package.is_symlink()
    if checkout_package:
        _validate_packet_runtime(root)
    if checkout_package and package.resolve() != Path(__file__).resolve().parent:
        environment = {name: os.environ[name] for name in _RESULT_CONSUMER_ENV if name in os.environ}
        environment['EGREGORE_ROOT'] = str(root)
        try:
            worker = subprocess.run(
                [sys.executable, '-I', '-B', '-c', _RESULT_CONSUMER, str(root)],
                input=json.dumps({'id': identifier, 'session_id': session_id,
                                  'harness': harness, 'native_turn_id': native_turn_id}),
                cwd=root, env=environment,
                capture_output=True, text=True, timeout=30)
        except subprocess.TimeoutExpired as error:
            raise EgregoreRuntimeError('packet Runtime validation timed out') from error
        if worker.returncode:
            raise EgregoreRuntimeError('packet Runtime validation failed')
        try:
            result = json.loads(worker.stdout)
            if not isinstance(result, dict):
                raise ValueError('expected a result object')
            if 'error' in result:
                raise EgregoreRuntimeError(str(result['error']))
            if not isinstance(result.get('rendered'), str):
                raise ValueError('expected rendered evidence')
            return result['rendered']
        except (ValueError, TypeError) as error:
            # Never include worker stdout in a failure: it may contain evidence.
            raise EgregoreRuntimeError('packet Runtime returned an invalid delivery') from error
    runtime = local_runtime(root, push_remote=False)
    actor = runtime.resolve_actor(session_id=session_id, harness=harness)
    return consume(root, identifier, runtime, actor, session_id=session_id, native_turn_id=native_turn_id)


def _result_hook(args):
    """Native PostToolUse adapter; stdin and stdout use the host hook contract."""
    from .private_result import allowed_root, receipts_from_tool
    delivered=[]
    try:
        payload=json.load(sys.stdin)
        if payload.get('tool_name')!='Bash':
            return 0
        command=payload.get('tool_input',{}).get('command','')
        if 'bin/search.sh' not in command or '--context-packet' not in command:
            return 0
        results=[]
        for receipt in receipts_from_tool(payload):
            root=allowed_root(_root(),receipt['root'])
            session=str(payload.get('session_id') or _session_id(root))
            results.append(_consume_private_result(root,receipt['id'],session_id=session,harness=args.harness,
                native_turn_id=payload.get('turn_id') or payload.get('prompt_id')))
            delivered.append((root,receipt['id']))
        if not results:
            return 0
        context='EGREGORE_RETRIEVAL_CONTEXT_V1\nAuthorized Runtime evidence for this invocation. Do not reproduce ranking traces.\n'+'\n'.join(results)+'\nEND_EGREGORE_RETRIEVAL_CONTEXT_V1'
    except (OSError,ValueError,TypeError,KeyError,EgregoreRuntimeError) as error:
        context=f'Runtime private result could not be attached: {error}. Do not treat it as received evidence.'
        delivered=[]  # nothing in this tool call reached the agent
    print(json.dumps({'hookSpecificOutput':{'hookEventName':'PostToolUse','additionalContext':context}}))
    for root,receipt in delivered:
        record_notice(root,'delivered',args.harness,payload.get('session_id'))
        _mind_delivered(root,args.harness,payload,receipt)
    return 0


def _session_id(root: Path) -> str:
    if member := (member_cli.current() if member_cli is not None else None):
        return member.session_id
    if pinned := _episode_session.get():
        return pinned
    configured = os.environ.get("EGREGORE_SESSION_ID", "").strip()
    if configured:
        return configured
    try:
        persisted = (root / ".egregore-session-id").read_text(encoding="utf-8").strip()
    except OSError:
        persisted = ""
    return persisted or f"session_{uuid.uuid4().hex}"


@contextmanager
def _observe_episode(root: Path):
    """Serialize query/read-modify-write and prompt reset across this session.

    Harness hooks and shell calls share one budget. Pin identity for the whole
    operation so a concurrently rewritten launch marker cannot move its receipt.
    Other explicitly identified sessions have separate locks and budgets.
    """
    session = _session_id(root)
    token = _episode_session.set(session)
    directory = root / ".egregore" / "runtime" / "observe"
    try:
        try:
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            os.chmod(directory, 0o700)
            name = hashlib.sha256(session.encode()).hexdigest()[:24] + ".lock"
            descriptor = os.open(directory / name, os.O_CREAT | os.O_RDWR, 0o600)
        except OSError as exc:
            raise EgregoreRuntimeError("Observe episode state is unavailable; repair local runtime state before retrying.") from exc
        with os.fdopen(descriptor, "a") as handle:
            try:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            except OSError as exc:
                raise EgregoreRuntimeError("Observe episode could not be locked; retry after repairing local runtime state.") from exc
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)
    finally:
        _episode_session.reset(token)


def _actor(runtime: EgregoreRuntime, root: Path, harness: str):
    return runtime.resolve_actor(session_id=_session_id(root), harness=harness)


def _observe_receipt_path(root: Path, harness: str) -> Path:
    """Return the gitignored, current-session Observe receipt path."""

    identity = f"{harness}:{_session_id(root)}".encode("utf-8")
    name = hashlib.sha256(identity).hexdigest()[:24] + ".json"
    return root / ".egregore" / "runtime" / "observe" / name


def _clear_observe_receipt(root: Path, harness: str) -> None:
    # Shell adapters and native hooks share a user episode. A new prompt must
    # retire every receipt in this session before any new retrieval.
    from .investigation import reset
    if _prompt_binding.get() is None:
        reset(root, _session_id(root))
    for runtime in {harness, "shell", "claude", "codex", "pi", "prime"}:
        try:
            _observe_receipt_path(root, runtime).unlink(missing_ok=True)
        except OSError as exc:
            raise EgregoreRuntimeError("Observe episode could not be reset; repair local runtime state before retrying.") from exc


def _actor_contract_marker_path(
    root: Path, harness: str, session: str | None = None
) -> Path:
    """Gitignored per-session marker: the full actor/retrieval contract was
    already attached once. Later prompts receive a short reminder instead of
    the ~4 KB block. bin/pre-compact.sh removes the marker so the first prompt
    after a compaction re-attaches the full contract.

    ``session`` is the harness's own session id from the hook payload. The
    Egregore session file in the checkout is shared by every concurrent
    session there and rewritten by each new one, so keying on it alone made
    parallel sessions re-attach the full contract on every prompt."""

    return _session_state_path(root, "actor-contract", harness, session, ".sent")


def _session_state_path(root: Path, kind: str, harness: str, session: str | None, suffix: str) -> Path:
    session = re.sub(r"[^A-Za-z0-9_.-]", "-", session or _session_id(root))[:120]
    return root / ".egregore" / "runtime" / "observe" / f"{kind}-{harness}-{session}{suffix}"


def _situated_hints_enabled(root: Path) -> bool:
    """Off switch: ``egregore.json`` → ``knowledge.situated_hints: false``."""
    try:
        config = json.loads((root / "egregore.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return True
    knowledge = config.get("knowledge") if isinstance(config, dict) else None
    return not (isinstance(knowledge, dict) and knowledge.get("situated_hints") is False)


def _working_paths(root: Path) -> list[str]:
    """Paths changed in this workspace: tracked edits plus untracked files."""
    paths: list[str] = []
    # NUL-delimited so Git does not quote non-ASCII names ("caf\303\251.md").
    for args in (("diff", "--name-only", "-z", "HEAD"), ("ls-files", "-z", "--others", "--exclude-standard")):
        try:
            result = subprocess.run(["git", "-C", str(root), *args], capture_output=True, text=True, timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            continue
        if result.returncode == 0:
            paths.extend(name for name in result.stdout.split("\0") if name)
    return list(dict.fromkeys(paths))[:500]


def _sweep_situated_state(directory: Path, max_age_days: int = 7) -> None:
    """Drop per-session offer records older than a week; a new session starts one."""
    cutoff = time.time() - max_age_days * 86400
    try:
        for stale in directory.glob("situated-*.json"):
            try:
                if stale.stat().st_mtime < cutoff:
                    stale.unlink()
            except OSError:
                continue
    except OSError:
        return


def _situated_hint(runtime, root: Path, harness: str, session: str | None, prompt: str) -> str:
    """At most one offer line per prompt, each pattern at most once per session.

    An offer, never a gate: the working changes and the prompt are matched
    against pattern situations; nothing is retrieved for the model.
    """
    memory = root / "memory"
    if not (memory / "knowledge" / "patterns").is_dir() or not _situated_hints_enabled(root):
        return ""
    from .knowledge import CanonicalKnowledgeService, situated_hint_line
    state = _session_state_path(root, "situated", harness, session, ".json")
    try:
        offered = set(json.loads(state.read_text(encoding="utf-8")))
    except (OSError, ValueError, TypeError):
        offered = set()
        _sweep_situated_state(state.parent)
    found = CanonicalKnowledgeService(runtime, memory).situated(
        _actor(runtime, root, harness), paths=_working_paths(root), text=prompt,
        limit=len(offered) + 3, count_instances=False,
    )
    for hit in found["patterns"]:
        line = situated_hint_line(hit["title"], hit["canonical_path"])
        if hit["id"] in offered or not line:
            continue
        try:
            state.parent.mkdir(parents=True, exist_ok=True)
            state.write_text(json.dumps(sorted(offered | {hit["id"]})), encoding="utf-8")
        except OSError:
            return ""  # without the record the same offer would repeat every prompt
        return line
    return ""


def _receipt_requests(receipt) -> dict:
    requests = receipt.get("requests")
    if isinstance(requests, dict):
        return dict(requests)
    # Keep a pre-upgrade v1 receipt and its global budget useful for this prompt.
    fingerprint = receipt.get("fingerprint")
    return {fingerprint: receipt} if fingerprint else {}


def _active_observe_receipt(root: Path, harness: str) -> dict[str, object] | None:
    """Load a useful receipt for the current harness prompt, if present."""

    receipt_dir = root / ".egregore" / "runtime" / "observe"
    try:
        modified_paths = []
        for candidate in receipt_dir.glob("*.json"):
            try:
                modified_paths.append((candidate.stat().st_mtime, candidate))
            except FileNotFoundError:
                continue  # a concurrent, different session may reset its receipt
        paths = [path for _, path in sorted(modified_paths, reverse=True)]
    except OSError:
        paths = []
    for path in paths:
        try:
            payload = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if not isinstance(payload, dict):
            continue
        if payload.get("session_id") != _session_id(root):
            continue
        if payload.get("context_id"):
            return payload
    return None


def _request(
    *,
    task: str,
    org_id: str,
    actor_id: str,
    mode: RetrievalMode,
    limit: int,
    lex: tuple[str, ...] = (),
    vec: tuple[str, ...] = (),
    open_sources: bool = False,
    temporal_scope: TemporalScope | None = None,
    recent_days: int | None = None,
) -> RetrievalRequest:
    if mode is RetrievalMode.LEX and not lex:
        lex = vec
    if mode is RetrievalMode.VEC and not vec:
        vec = lex
    return RetrievalRequest(
        request_id=f"observe-{uuid.uuid4().hex}",
        org_id=org_id,
        actor_id=actor_id,
        task=task,
        lex=lex,
        vec=vec,
        top_k=limit,
        mode=mode,
        open_sources=open_sources,
        temporal_scope=temporal_scope or temporal_scope_for_task(task),
        not_before=(
            datetime.now(UTC) - timedelta(days=recent_days)
            if recent_days is not None
            else None
        ),
    )


def temporal_scope_for_task(task: str) -> TemporalScope:
    """Select historical evidence only when the task explicitly asks for it."""

    return (
        TemporalScope.CURRENT_AND_HISTORICAL
        if _HISTORICAL_SCOPE.search(task)
        else TemporalScope.CURRENT
    )


def _render_evidence(evidence: EvidenceItem) -> str:
    parts = [
        "---",
        f"**file:** `{evidence.canonical_path}`",
        f"**artifact:** `{evidence.artifact_id}`",
        f"**reason:** {evidence.reason}",
    ]
    if evidence.content:
        parts.extend(("", evidence.content))
    return "\n".join(parts)


def _render_compact_evidence(evidence: EvidenceItem, rank: int) -> str:
    excerpt = " ".join(evidence.content.split())
    excerpt = re.sub(r"^@@.*?@@\s*(?:\([^)]*\)\s*)?", "", excerpt)
    if len(excerpt) > 220:
        excerpt = excerpt[:217].rstrip() + "..."
    return "\n".join(
        (
            f"[{rank}] **file:** `{evidence.canonical_path}` · "
            f"**artifact:** `{evidence.artifact_id}` · {evidence.reason}",
            f"    excerpt: {excerpt}",
        )
    )


def _session_receipt(root: Path, harness: str) -> str:
    """Describe observed local revisions; tool availability belongs to the host."""
    def git(*args):
        try:
            result = subprocess.run(["git", "-C", str(root), *args], capture_output=True,
                                    text=True, timeout=2)
            return result.stdout.strip() if result.returncode == 0 else "unknown"
        except (OSError, subprocess.TimeoutExpired):
            return "unknown"
    instruction = root / ("CLAUDE.md" if harness == "claude" else
                          ".pi/APPEND_SYSTEM.md" if harness == "pi" else
                          ".prime/agent/APPEND_SYSTEM.md" if harness == "prime" else "AGENTS.md")
    digest = hashlib.sha256(instruction.read_bytes()).hexdigest()[:16] if instruction.is_file() else "unavailable"
    from .readiness import session_boundary_state
    boundary = "computed" if session_boundary_state(root) is not None else "not computed for this workspace"
    return "\n".join((
        f"Session workspace: {root}; branch={git('branch', '--show-current')}",
        f"Framework revision: {git('rev-parse', 'HEAD')}; instruction SHA256={digest}",
        f"Session boundary receipt: {boundary}. Host permissions remain authoritative.",
        "Native capabilities: consult this session's tool inventory and operating mode. "
        "Use delegation and structured questions only when available and permitted; otherwise work inline and use plain text. "
        "Do not infer capabilities from the harness name.",
    ))


def _coverage(context) -> str:
    omissions = tuple(getattr(context, "omissions", ()))
    warnings = tuple(getattr(context, "warnings", ()))
    degraded = bool(getattr(context, "degraded", False))
    freshness = getattr(context, "freshness", {})
    return "\n".join((
        "Evidence coverage: " + ("partial" if omissions or degraded or not context.evidence else "returned evidence delivered; sufficiency requires judgment"),
        f"Executed retrieval mode: {getattr(context, 'retrieval_mode', 'unknown')}; degraded={str(degraded).lower()}",
        f"Requested retrieval mode: {getattr(context, 'requested_retrieval_mode', 'unknown')}",
        f"Index revision: {freshness.get('index_revision', 'unknown')}",
        "Omissions: " + ("; ".join(omissions) or "none recorded"),
        "Warnings: " + ("; ".join(warnings) or "none recorded"),
    ))


def _observe_entry(context) -> dict:
    evidence = tuple(getattr(context, "evidence", ()) or ())
    coverage = _coverage(context)
    return {
        "context_id": str(getattr(context, "context_id", "")),
        "source_paths": [str(item.canonical_path) for item in evidence],
        "evidence_count": len(evidence),
        "coverage": coverage,
        "rendered": "\n\n".join(_render_evidence(item) for item in evidence) + "\n" + coverage,
        "rendered_compact": "\n".join(_render_compact_evidence(item, rank) for rank, item in enumerate(evidence, 1)) + "\n" + coverage,
        "context": context.to_dict(),
    }


def _restore_context(value):
    """Rehydrate the shared context result for existing presentation adapters."""
    fields = {**value, 'evidence':tuple(EvidenceItem(**item) for item in value['evidence']),
              'action_permissions':frozenset(Permission(item) for item in value['action_permissions'])}
    return OrgContext(**fields)


def _render_query_result(args, entry, *, reused=False) -> None:
    actual = entry.get("evidence_count", len(entry.get("source_paths", ())))
    minimum = getattr(args, "min_evidence", 1)
    recent_days = getattr(args, "recent_days", None)
    requirement = {"met": actual >= minimum, "actual": actual,
                   "minimum": minimum, "recent_days": recent_days}
    if args.json:
        # Preserve the OrgContext fields and evidence in machine-readable mode,
        # with the same explicit requirement status for fresh and cached reads.
        print(json.dumps({**entry["context"], "evidence_requirement": requirement}, indent=2))
        return
    if reused:
        print("EGREGORE_OBSERVE_CONTEXT_REUSED")
        print("Equivalent authorized request; no second retrieval was run.")
    coverage = entry.get("coverage")
    if coverage is None:
        # Compatibility with a receipt written before shared rendering.
        coverage = "Evidence coverage:" + entry.get("rendered", "").partition("Evidence coverage:")[2]
    if not requirement["met"] and (recent_days is not None or minimum > 1):
        window = f" within the last {recent_days} days" if recent_days is not None else ""
        print(f"EGREGORE_EVIDENCE_GAP actual={actual} required={minimum} recent_days={recent_days or 0}")
        label = "Freshness evidence gap" if recent_days is not None else "Evidence gap"
        print(f"{label}: found {actual} authorized source(s){window}; "
              f"at least {minimum} are required for this synthesis. Do not substitute older sources.")
        print("Evidence coverage: partial; minimum evidence requirement not met")
        if "\n" in coverage:
            print(coverage.split("\n", 1)[1])
    elif actual:
        print(entry.get("rendered_compact" if getattr(args, "compact", False) else "rendered", ""))
    else:
        print("No results found.")
        print(coverage)


def _query(args: argparse.Namespace) -> int:
    root = _root()
    with _invocation(root, getattr(args, 'episode', None)):
        return _query_in_episode(args, root)


def _query_in_episode(args: argparse.Namespace, root: Path) -> int:
    runtime = _runtime(root, push_remote=False)
    actor = _actor(runtime, root, args.harness)
    request = _request(
        task=args.task, org_id=actor.profile.org_id, actor_id=actor.actor.actor_id,
        lex=identity_aware_lexical_formulations(root, actor, args.task, tuple(args.lex),
                                                decision=runtime.authorize(actor, Permission.READ)),
        vec=tuple(args.vec), mode=args.mode, limit=args.limit,
        temporal_scope=getattr(args, 'temporal_scope', None),
        recent_days=getattr(args, 'recent_days', None),
    )
    operation = InvestigationRequest.discover_context(
        request, token_budget=actor.profile.default_context_budget,
        gap=getattr(args, 'follow_up', '') or '',
        minimum_evidence=getattr(args, 'min_evidence', 1),
        recent_days=getattr(args, 'recent_days', None),
    )
    response = _execute_investigation(root, args.harness, operation,
        runtime=runtime, actor=actor, reference=getattr(args, 'episode', None),
        request_id=getattr(args, 'request_id', None), origin='query')
    if not response['ok']:
        if getattr(args,'private_result',False):
            attached = _publish_result(root,response,json.dumps(response,ensure_ascii=False)+'\n',
                private=True,harness=args.harness)
            return 0 if attached else 2  # Claude's attachment carries its operation error.
        print(response['error'], file=sys.stderr)
        _mind_notice(root, response, '', args.harness)
        return 2
    context = _restore_context(response['result']['context'])
    entry = _observe_entry(context)
    rendered=StringIO()
    with redirect_stdout(rendered):
        _render_query_result(args, entry, reused=response.get('replayed', False) or response['result'].get('reused', False))
    attached = _publish_result(root,response,rendered.getvalue(),private=getattr(args,'private_result',False),harness=args.harness)
    retriever = getattr(runtime, 'retriever', None)
    if not args.json and not attached and getattr(retriever, 'last_query_used_daemon', None) is False:
        print('EGREGORE_RETRIEVAL_COLD_START')
    return 0


def prompt_requests_actor_context(prompt: str) -> bool:
    """Return whether a normal prompt needs stable actor attribution.

    Identity is cheap, local organizational context. Supplying it on every
    prompt keeps every skill and harness consistent about ``me``/``myself``
    without triggering retrieval or asking models to infer from OS/Git names.
    """

    return bool(prompt and prompt.strip())


_RECALL_ONLY_SCOPE = (
    "Egregore Runtime is for organizational recall and memory only: team memory, "
    "decisions, handoffs, meetings, prior work. Code search, file reads, Git, tests, "
    "and every other task use the harness's normal tools (Grep, Glob, Read, Bash) "
    "with no retrieval ritual and no Runtime call."
)


def _actor_context_block(
    runtime: EgregoreRuntime, root: Path, harness: str, *, full: bool = True
) -> str:
    """Render the stable identity and the recall contract for harness rituals.

    ``full`` renders the complete contract (once per session); otherwise a
    short reminder that keeps identity and the recall-only scope in view.
    """

    actor_context = _actor(runtime, root, harness)
    actor = actor_context.actor
    aliases = ", ".join(
        dict.fromkeys(
            value.strip()
            for value in getattr(actor, "aliases", {}).values()
            if value and value.strip() and value.strip().casefold() != actor.display_name.casefold()
        )
    ) or "none"
    # Prompt context is a read surface: only profiles this actor may read name anyone.
    readable = runtime.authorize(actor_context, Permission.READ)
    member_names = "; ".join(
        f"{', '.join(member.aliases)} → {member.display_name}"
        if member.aliases
        else member.display_name
        for member in organization_member_presentations(root, actor_context, decision=readable)
    ) or "unavailable"
    search_command = 'bash bin/search.sh find "<query>" --kind <kind>'
    if harness == "claude":
        search_command += " --context-packet"
    if not full:
        # Rides on every later prompt, so every line here costs once per turn.
        return "\n".join(
            (
                "EGREGORE_ACTOR_CONTEXT_V1",
                "Reminder: the full contract was attached earlier in this session; if it is no longer "
                "in your context, read `.claude/context/retrieval-investigation.md` once.",
                f"Actor: {actor.display_name} · Actor ID: {actor.actor_id} · "
                f"Organization ID: {actor_context.profile.org_id} · Runtime root: {root}",
                "`me` and `myself` mean this actor; never infer identity from OS, Git, or GitHub names.",
                _RECALL_ONLY_SCOPE,
                RECALL_WORKFLOW_GUIDANCE,
                "When a prompt needs that recall and no EGREGORE_ORG_CONTEXT_V1 block is "
                f"attached, choose the operation kind and use `{search_command}`; exact latest/oldest/open "
                "handoff questions use `bash bin/search.sh handoffs …` instead.",
                "END_EGREGORE_ACTOR_CONTEXT_V1",
            )
        )
    packet_note = (
        "On Claude, `--context-packet` keeps the internal evidence trace out of the user "
        "transcript and attaches it through PostToolUse. Keep that flag on model-led "
        "searches; never repeat the attached ranking trace in the answer."
    ) if harness == "claude" else None
    return "\n".join(line for line in
        (
            "EGREGORE_ACTOR_CONTEXT_V1",
            "Resolved automatically by EgregoreRuntime before the ritual.",
            f"Actor ID: {actor.actor_id}",
            f"Actor display name: {actor.display_name}",
            f"Actor aliases: {aliases}",
            f"Organization ID: {actor_context.profile.org_id}",
            f"Organization member names: {member_names}",
            "Member names are presentation-only identity context. Use the display name when "
            "retrieved evidence names one of its aliases. The directory is not activity "
            "evidence: never mention a member merely because they are listed, never append it "
            "to a retrieval query, and never use it for authorization.",
            f"Runtime root: {root}",
            _session_receipt(root, harness),
            "Run Egregore retrieval and workflow commands from this Runtime root. "
            "Do not fall back to a launch checkout named elsewhere in the session.",
            _RECALL_ONLY_SCOPE,
            "Organizational retrieval status: NOT_PERFORMED. This actor-only block "
            "does not mean organizational recall is unnecessary.",
            "Interpret the user's intent semantically, without requiring trigger words. "
            "If the request needs organizational history, synthesis of current team or person "
            "work, a prior handoff, or continuation of earlier work and no "
            "EGREGORE_ORG_CONTEXT_V1 block is attached, choose the operation kind and use "
            f"`{search_command}`. ",
            investigation_guidance(harness),
            packet_note,
            "Recognize exact lifecycle questions from meaning: the latest/newest/oldest handoff "
            "addressed to or sent by someone (including `me`), or open/unresolved handoffs, use "
            "`bash bin/search.sh handoffs` with [--mine|--sent|--addressed-to X|--sent-by X] "
            "[--status open] [--order newest|oldest] [--limit N] [--open], never a semantic "
            "query. Topical handoff questions (`the handoff about privacy`) stay `search.sh find` recall.",
            "Do not substitute Activity, Dashboard, Project, Git inspection, optional hosted indexes, or raw "
            "memory scans for that recall. A named request to display a status card is an "
            "explicit status workflow; a question asking for an explained synthesis of "
            "organizational work is Runtime/QMD recall. Do not query optional hosted indexes unless the user "
            "explicitly requests relationship or optional hosted index status.",
            "For every identity-bearing workflow, `me`, `myself`, `from me`, "
            "and `to myself` mean this Actor ID and display name. Use the "
            "display name for presentation and the Actor ID for ownership, "
            "authorization, attribution, creator, steward, recipient, and "
            "respondent fields. Never infer identity from the OS user, Git, "
            "GitHub, a branch name, or prose aliases.",
            "END_EGREGORE_ACTOR_CONTEXT_V1",
        ) if line is not None
    )


def lexical_formulation(prompt: str) -> str:
    """Remove conversational recall framing from the BM25 formulation.

    This is deterministic typed-query planning, not query expansion: the
    vector lane still receives the untouched task and no new terms are added.
    """

    concept = prompt.strip()
    for prefix in _RECALL_LEX_PREFIXES:
        match = prefix.match(concept)
        if not match:
            continue
        reduced = concept[match.end() :].strip(" \t\r\n?!.:")
        if reduced:
            return reduced
    return concept


def identity_aware_lexical_formulations(
    root: Path,
    actor: object,
    task: str,
    formulations: tuple[str, ...],
    *,
    decision: PolicyDecision,
) -> tuple[str, ...]:
    """Bind the active actor and expand explicitly named organization members.

    This keeps cold BM25 retrieval equivalent to stable identity resolution:
    a chosen display name, provider handle, and legacy local alias all refer to
    one member. First-person references use the active actor; the directory is
    never added wholesale, and only profiles ``decision`` lets the reader see
    add terms. Semantic identity binding happens at request construction.
    """

    def normalized(value: str) -> str:
        decomposed = unicodedata.normalize("NFKD", value.casefold())
        ascii_like = "".join(
            character for character in decomposed if not unicodedata.combining(character)
        )
        return " ".join(re.findall(r"[^\W_]+", ascii_like, re.UNICODE))

    task_tokens = f" {normalized(task)} "
    expanded = list(actor_lexical_formulations(actor, task, formulations))
    seen = {value.strip().casefold() for value in expanded if value.strip()}
    for member in organization_member_presentations(root, actor, decision=decision):
        references = (member.display_name, *member.aliases)
        if not any(
            reference_normalized
            and f" {reference_normalized} " in task_tokens
            for reference_normalized in (normalized(value) for value in references)
        ):
            continue
        for reference in references:
            key = reference.strip().casefold()
            if not key or key in seen:
                continue
            expanded.append(reference)
            seen.add(key)
    return tuple(expanded)


def _member_prompt_hook(args):
    """Trusted Durable hook: member identity only, no operator startup surfaces."""
    member = (member_cli.current() if member_cli is not None else None)
    raw = sys.stdin.read(262145)
    if len(raw) > 262144:
        raise MemberAuthorityError()
    try:
        payload = json.loads(raw)
    except (ValueError, TypeError):
        raise MemberAuthorityError() from None
    if (not isinstance(payload, dict) or payload.get("session_id") != member.native_session
            or not isinstance(payload.get("prompt", payload.get("user_prompt", "")), str)):
        raise MemberAuthorityError()
    prompt = payload.get("prompt", payload.get("user_prompt", "")).strip()
    runtime = member.runtime(member.root)
    actor = runtime.resolve_actor(session_id=member.session_id, harness="durable")
    if not runtime.authorize(actor, Permission.READ).allowed:
        raise MemberAuthorityError()
    binding = episode_binding.begin(
        member.root, actor, harness="durable", session_id=member.session_id,
        native_turn_id=payload.get("turn_id") or payload.get("prompt_id"), question=prompt,
    )
    context = "\n".join((
        episode_binding.context_line(binding),
        "EGREGORE_ACTOR_CONTEXT_V1",
        f"Actor ID: {actor.actor.actor_id}",
        f"Actor display name: {actor.actor.display_name}",
        f"Organization ID: {actor.profile.org_id}",
        "`me` and `myself` mean this verified member, never the host operator.",
        "Organizational retrieval status: NOT_PERFORMED.",
        _RECALL_ONLY_SCOPE,
        'Use the supplied memory tools: `bash bin/search.sh find "<query>" --kind <kind>`, '
        '`bash bin/search.sh open memory/path.md`, or `bash bin/search.sh handoffs --mine`.',
        "The host supplies member authority to those tools. Status and identity context do not grant access.",
        INVESTIGATION_GUIDANCE,
        "END_EGREGORE_ACTOR_CONTEXT_V1",
    ))
    # Verification is current at delivery, not only before writing the binding.
    if not runtime.authorize(actor, Permission.READ).allowed:
        raise MemberAuthorityError()
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "UserPromptSubmit", "additionalContext": context,
    }}, separators=(",", ":")))
    return 0


def _member_ready(args):
    member = (member_cli.current() if member_cli is not None else None)
    if member is None:
        raise MemberAuthorityError()
    runtime = member.runtime(member.root)
    actor = runtime.resolve_actor(session_id=member.session_id, harness="durable")
    if not runtime.retrieval_health().available:
        raise MemberAuthorityError()
    if not all(runtime.authorize(actor, operation).allowed
               for operation in (Permission.DISCOVER, Permission.READ)):
        raise MemberAuthorityError()
    print(json.dumps({
        "schema": "egregore.member-ready/v1",
        "accountId": actor.account.account_id,
        "orgId": actor.profile.org_id,
        "actorId": actor.actor.actor_id,
        "membershipId": actor.membership.membership_id,
        "verifiedAt": int(time.time() * 1000),
    }, separators=(",", ":")))
    return 0


def _bind_native_session(root: Path, harness: str, session) -> None:
    """Codex starts before its thread exists, so its first prompt maps it.

    bin/session-id.sh binds the thread to the Egregore session id it resolves
    now and keeps an existing map, so commits made in this thread keep their
    own Egregore-Session trailer after a later session start elsewhere.
    """
    script = Path(root) / 'bin' / 'session-id.sh'
    if not isinstance(session, str) or not session or not script.is_file():
        return
    try:
        subprocess.run(['bash', str(script), 'bind', harness, session, '--root', str(root)],
                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, timeout=2, check=False)
    except (OSError, subprocess.SubprocessError):
        pass  # a missing map falls back to the shared file; never cost the prompt


def _prompt_hook(args: argparse.Namespace) -> int:
    if (member_cli.current() if member_cli is not None else None):
        return _member_prompt_hook(args)
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    prompt = str(payload.get("prompt") or payload.get("user_prompt") or "").strip()
    launch = _root()
    root = _prompt_root(payload, launch)
    if args.harness == 'codex':
        _bind_native_session(launch, 'codex', payload.get('session_id'))
    record_notice(launch, 'asked', args.harness, payload.get('session_id'))
    _mind_asked(launch, args.harness, payload)  # the root the hook runs in (§3.3), never one the prompt names
    try:
        native_session = str(payload.get('session_id') or '').strip()
        if native_session:
            token = _episode_session.set(native_session)
            binding_token = None
            try:
                runtime = local_runtime(root,push_remote=False)
                actor = _actor(runtime,root,args.harness)
                binding = episode_binding.begin(root,actor,harness=args.harness,session_id=native_session,
                    native_turn_id=payload.get('turn_id') or payload.get('prompt_id'), question=prompt)
                binding_token = _prompt_binding.set(binding)
                return _prompt_hook_in_episode(args,payload,prompt,root)
            finally:
                if binding_token is not None:
                    _prompt_binding.reset(binding_token)
                _episode_session.reset(token)
        with _observe_episode(root):
            return _prompt_hook_in_episode(args, payload, prompt, root)
    except EgregoreRuntimeError as exc:
        print(json.dumps({"hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": f"Egregore Runtime context is unavailable ({exc}).",
        }}))
        return 0


def _prompt_hook_in_episode(args, payload, prompt, root):
    # A new prompt resets retained retrieval state. Startup supplies identity
    # and guidance only; the answering model chooses every discovery/read.
    _clear_observe_receipt(root, args.harness)
    if not prompt_requests_actor_context(prompt):
        if _prompt_binding.get():
            print(json.dumps({'hookSpecificOutput':{'hookEventName':'UserPromptSubmit',
                'additionalContext':episode_binding.context_line(_prompt_binding.get())}}))
        return 0
    try:
        runtime = local_runtime(root, push_remote=False)
        hook_session = str(payload.get("session_id") or "").strip() or None
        marker = _actor_contract_marker_path(root, args.harness, hook_session)
        full = not marker.exists()
        additional_context = _actor_context_block(runtime, root, args.harness, full=full)
        if full:
            try:
                marker.parent.mkdir(parents=True, exist_ok=True)
                marker.write_text(datetime.now(UTC).isoformat(), encoding="utf-8")
            except OSError:
                pass
        try:
            hint = _situated_hint(runtime, root, args.harness, hook_session, prompt)
        except Exception:  # an offer only; a failure never costs the prompt its context
            hint = ""
        if hint:
            additional_context += "\n" + hint
    except Exception as exc:  # Hooks are advisory and must never block a prompt.
        additional_context = (
            f"Actor context is unavailable ({type(exc).__name__}). "
            "Do not guess actor identity. Organizational retrieval has not run.\n"
            + investigation_guidance(args.harness)
        )
    if _prompt_binding.get():
        additional_context = episode_binding.context_line(_prompt_binding.get()) + '\n' + additional_context
    print(json.dumps({'hookSpecificOutput': {
        'hookEventName': 'UserPromptSubmit', 'additionalContext': additional_context,
    }}, separators=(",", ":")))
    return 0


def _admin_status(args: argparse.Namespace) -> int:
    """Stable-identity admin capability for shell surfaces — fails closed.

    Egregore-surface admin protection only: repository members retain raw Git
    access regardless of this answer, and callers must treat any failure as
    non-admin.
    """

    root = _root()
    result = {"admin": False, "display_name": None, "actor_id": None}
    try:
        runtime = local_runtime(root, push_remote=False)
        actor = _actor(runtime, root, args.harness)
        result["display_name"] = actor.actor.display_name
        result["actor_id"] = actor.actor.actor_id
        result["admin"] = is_admin(runtime.authorize(actor, Permission.READ))
    except Exception:
        result = {"admin": False, "display_name": None, "actor_id": None}
    print(json.dumps(result, sort_keys=True))
    return 0


def _handoffs(args: argparse.Namespace) -> int:
    """Typed lifecycle lookup — exact handoff questions, zero semantic search.

    This is not a second model-led query: it is a bounded deterministic
    operation over canonical artifact metadata, available even when an
    attached Observe packet missed.
    """

    from .handoff_lookup import HandoffLookupService

    root = _root()
    runtime = _runtime(root, push_remote=False)
    actor = _actor(runtime, root, args.harness)
    service = HandoffLookupService(runtime, root)
    started = time.monotonic()
    records = service.query(
        actor,
        addressed_to="me" if args.mine else args.addressed_to,
        sent_by="me" if args.sent else args.sent_by,
        status_filter=args.status,
        order=args.order,
        limit=args.limit,
    )
    lookup_ms = round((time.monotonic() - started) * 1000)
    if args.timing:
        print(f"lookup: {lookup_ms}ms", file=sys.stderr)
    from . import held
    from .policy import allows
    decision, memory = runtime.authorize(actor, Permission.READ), service.memory_root
    records = [record for record in records  # the lookup's rows, decided again where they are printed
               if allows(decision, "memory/" + record.canonical_path.removeprefix("memory/"), root=memory)]
    if args.json:
        return held.emit(decision, {"records": [asdict(record) for record in records], "lookup_ms": lookup_ms},
                         root=memory, render=lambda shown: json.dumps(shown, sort_keys=True))
    lines = []
    for index, record in enumerate(records, start=1):
        day = record.occurred_at.split("T")[0]
        lines.append(f"{index}. {day} · from {record.sender} · to {record.recipient} · {record.status} · {record.topic}")
        lines += [f"   claim: {record.claim}"] * bool(record.claim) + [f"   ask: {record.ask}"] * bool(record.ask)
        lines.append(f"   source: {record.canonical_path}")
    if args.open and records:
        lines += ["", runtime.open_source(actor, records[0].canonical_path)]
    return held.emit(decision, "\n".join(lines) or "no matching handoff exists for that filter", root=memory, render=str)


def _status(args: argparse.Namespace) -> int:
    from dataclasses import replace
    from . import held
    root = _root()
    runtime = local_runtime(root, push_remote=False)
    health = runtime.retrieval_health()
    try:
        actor = _actor(runtime, root, "shell")
    except Exception:  # noqa: BLE001 - no identity: health still prints, its warnings (which can name memory) counted
        actor = None
        health = replace(health, warnings=(f"{len(health.warnings)} warnings withheld: identity is unavailable",)
                         if health.warnings else ())
    value = health.to_dict() if args.json else "\n".join((
        f"adapter: {health.adapter} {health.adapter_version}",
        f"index spec: {health.index_spec_version}",
        f"index revision: {health.index_revision}",
        f"source revision: {health.source_revision}",
        f"embedding: {health.embedding_state}",
        f"readiness: {health.runtime_state}",
        f"bm25 ready: {'yes' if health.bm25_ready else 'no'}",
        f"semantic ready: {'yes' if health.semantic_ready else 'no'}",
        f"semantic build: {health.semantic_source_revision or 'none'}",
        f"worker pid: {health.runtime_pid or 'none'}",
        f"endpoint: {health.runtime_endpoint or 'none'}",
        f"index: {health.index_path or 'unknown'}",
        f"collection: {health.collection or 'unknown'}",
        f"available: {'yes' if health.available else 'no'}",
        *(f"warning: {warning}" for warning in health.warnings)))
    render = (lambda shown: json.dumps(shown, indent=2)) if args.json else str  # JSON packaged field by field
    shown = held.emit_for(runtime, actor, value, render=render) if actor else _content_free(render(value))
    return shown or (0 if health.available else 1)


def _content_free(text: str) -> int:
    """Health with every warning replaced by a count: no memory text to package."""
    print(text)
    return 0


_RUNTIME_CANDIDATE_VERSION = re.compile(
    r"(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-runtime-mvp\.(0|[1-9]\d*))?",
    re.ASCII,
)


def _is_runtime_candidate_version(version: str) -> bool:
    match = _RUNTIME_CANDIDATE_VERSION.fullmatch(version)
    if not match:
        return False
    components = tuple(part for part in match.groups() if part is not None)
    if any(len(part) > 16 for part in components):
        return False
    parts = tuple(int(part) for part in components)
    # Match the launcher's exact-version policy and JS safe-integer boundary.
    return parts[:3] >= (0, 21, 0) and all(part <= 9007199254740991 for part in parts)


def _upgrade_context(root: Path):
    from .upgrade import build_cli_context

    return build_cli_context(root)


def _legacy_installer_version(root: Path) -> str | None:
    """Read pre-Runtime installer receipts without granting Runtime ownership.

    Public templates omit the installer source package. Their durable harness
    receipts are the version evidence, even though they own no Runtime core.
    User edits do not invalidate a receipt's installed-version provenance.
    """
    from .upgrade import _runtime_install_receipt_paths

    versions = set()
    for path in _runtime_install_receipt_paths(root):
        try:
            receipt = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            continue
        if not isinstance(receipt, dict):
            raise ValueError("invalid installer receipt")
        if receipt.get("package") != "create-egregore":
            continue
        files = receipt.get("files")
        version = receipt.get("version")
        if (not isinstance(version, str)
                or re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)(?:-[0-9A-Za-z.-]+)?", version) is None
                or not isinstance(files, dict) or not files
                or any(not isinstance(entry, dict)
                       or not isinstance(entry.get("hash"), str)
                       or re.fullmatch(r"[a-f0-9]{64}", entry["hash"]) is None
                       for entry in files.values())):
            raise ValueError("invalid legacy installer version evidence")
        versions.add(version)
    if len(versions) > 1:
        raise ValueError("legacy installer versions disagree")
    return next(iter(versions), None)


def _active_runtime_version(root: Path, store) -> str:
    from .upgrade import UpgradeError, installed_runtime_receipt

    activation = store.load_activation()
    if activation and activation.get("active_version"):
        return str(activation["active_version"])
    # Fresh installs have package receipts, not upgrade activation records.
    # Their cloned template can carry an older package.json, so it cannot
    # describe the installed Runtime or the version rollback will restore.
    try:
        receipt = installed_runtime_receipt(root)
    except UpgradeError:
        return "unknown"
    if receipt is not None:
        return str(receipt.get("version") or "unknown")
    try:
        legacy_version = _legacy_installer_version(root)
    except (UpgradeError, OSError, ValueError):
        return "unknown"
    if legacy_version is not None:
        return legacy_version
    try:
        package = json.loads(
            (root / "packages" / "create-egregore" / "package.json").read_text(encoding="utf-8")
        )
        return str(package.get("version") or "unknown")
    except (OSError, ValueError):
        return "unknown"


def _upgrade(args: argparse.Namespace) -> int:
    from . import upgrade as upgrade_module
    from .teamsync import team_sync

    root = _root()
    try:
        store, engine, retriever = _upgrade_context(root)
    except upgrade_module.UpgradeError as exc:
        # Fail closed: no stable organization identity means no upgrade
        # state — never fall back to a path-inferred identity.
        print(str(exc), file=sys.stderr)
        return 1
    action = args.action

    if action == "status":
        state = upgrade_module.describe(store.load())
        state["active_version"] = _active_runtime_version(root, store)
        state["instance_hash"] = installation_key(root)
        # A live apply journal means a previous candidate application died
        # mid-transaction; the next activate recovers deterministically.
        state["interrupted_apply"] = store.load_apply_journal() is not None
        memory_root = (root / "memory").resolve()
        if memory_root.is_dir():
            state["team_sync"] = team_sync(memory_root, fetch=bool(args.fetch)).to_dict()
        print(json.dumps(state, indent=2, sort_keys=True))
        return 0

    if action == "init":
        if store.apply_journal_path.exists():
            print(
                "an interrupted Runtime change needs recovery before staging another upgrade; "
                "retry the interrupted activation or rollback",
                file=sys.stderr,
            )
            return 1
        version = (args.candidate or "").strip()
        if not _is_runtime_candidate_version(version):
            print(
                f"candidate {version!r} is not a supported Runtime version "
                "(expected X.Y.Z or X.Y.Z-runtime-mvp.N, starting at 0.21.0)",
                file=sys.stderr,
            )
            return 1
        config = json.loads((root / "egregore.json").read_text(encoding="utf-8"))
        org_id = str(config.get("org_id") or "")
        if not org_id:
            print("this instance has no stable org_id; refusing to stage an upgrade", file=sys.stderr)
            return 1
        existing = store.load()
        if existing and existing.get("status") in (
            upgrade_module.STATUS_PREPARING,
            upgrade_module.STATUS_READY,
        ):
            print("an upgrade is already staged for this instance", file=sys.stderr)
            return 1
        tarball = Path(args.tarball).expanduser().resolve() if args.tarball else None
        if tarball is None or not tarball.is_file():
            print(
                "upgrade init requires --tarball <candidate .tgz>: the upgrade "
                "installs actual packaged bytes, never a version string",
                file=sys.stderr,
            )
            return 1
        state = upgrade_module.new_state(
            instance_path=root,
            org_id=org_id,
            instance_hash=installation_key(root),
            candidate_version=version,
            active_version=_active_runtime_version(root, store),
            candidate_source=str(tarball),
        )
        store.write(state)
        print(json.dumps(upgrade_module.describe(state), indent=2, sort_keys=True))
        return 0

    if action == "prepare":
        state = store.load()
        if state is None:
            print("run `upgrade init --candidate <version>` first", file=sys.stderr)
            return 1
        worker = state.get("worker") or {}
        if state.get("status") == upgrade_module.STATUS_PREPARING and worker.get("pid"):
            if upgrade_module._pid_alive(worker["pid"]):
                print(json.dumps(upgrade_module.describe(state), indent=2, sort_keys=True))
                return 0
        environment = dict(os.environ)
        package_root = str(Path(__file__).resolve().parents[1])
        environment["PYTHONPATH"] = (
            f"{package_root}{os.pathsep}{environment['PYTHONPATH']}"
            if environment.get("PYTHONPATH")
            else package_root
        )
        process = subprocess.Popen(
            (
                sys.executable,
                "-m",
                "egregore_runtime.upgrade_worker",
                "--repository-root",
                str(root),
            ),
            cwd=root,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        state["worker"] = {"pid": process.pid, "started_at": int(time.time())}
        state["status"] = upgrade_module.STATUS_PREPARING
        store.write(state)
        print(json.dumps(upgrade_module.describe(state, worker_alive=True), indent=2, sort_keys=True))
        return 0

    if action == "activate":
        state = engine.activate()
        print(json.dumps(upgrade_module.describe(state), indent=2, sort_keys=True))
        return 0

    if action == "cancel":
        state = engine.cancel()
        print(json.dumps(upgrade_module.describe(state), indent=2, sort_keys=True))
        return 0

    if action == "rollback":
        state = engine.rollback()
        print(json.dumps(upgrade_module.describe(state), indent=2, sort_keys=True))
        return 0

    print(f"unknown upgrade action: {action}", file=sys.stderr)
    return 2


def _team_sync_cmd(args: argparse.Namespace) -> int:
    from .teamsync import team_sync

    root = _root()
    memory_root = (root / "memory").resolve()
    if not memory_root.is_dir():
        print(json.dumps({"state": "attention", "label": "Sync needs attention"}))
        return 1
    result = team_sync(memory_root, fetch=bool(args.fetch))
    print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
    return 0


def _readiness(args: argparse.Namespace) -> int:
    from .readiness import collect_report, render

    root = _root()
    runtime = local_runtime(root, push_remote=False)
    report = collect_report(
        root, runtime, harness=args.harness, session_id=_session_id(root)
    )
    if args.json:
        print(json.dumps(report.to_dict(), indent=2))
    else:
        tty = sys.stdout.isatty() and not args.plain
        print(render(report, tty=tty))
    ready = {item.key: item.stage for item in report.items}
    return 0 if ready.get("search") == "ready" else 1


def _sync(args: argparse.Namespace) -> int:
    # push_remote lets the pull reconcile locally-ahead canonical history (a
    # writeback whose detached push was rejected). It never pushes anything
    # that is not already committed on the canonical branch.
    receipt = local_runtime(_root(), push_remote=True).synchronize()
    if args.json:
        print(json.dumps(receipt.to_dict(), indent=2))
    else:
        canonical = receipt.canonical_sync
        retrieval = receipt.retrieval
        print(f"synchronization: {receipt.status}")
        print(
            "canonical revision: "
            f"{canonical.local_revision if canonical is not None else 'unavailable'}"
        )
        print(f"canonical current: {'yes' if receipt.canonical_current else 'no'}")
        print(
            "canonical changed: "
            f"{'yes' if canonical is not None and canonical.changed else 'no'}"
        )
        print(
            "lexical ready: "
            f"{'yes' if retrieval is not None and retrieval.bm25_ready else 'no'}"
        )
        print(
            "semantic: "
            + (
                "ready"
                if retrieval is not None and retrieval.semantic_ready
                else "building"
                if receipt.semantic_building
                else "unavailable"
            )
        )
        print(
            "index/source aligned: "
            f"{'yes' if receipt.index_source_aligned else 'no'}"
        )
        if retrieval is not None:
            print(f"index revision: {retrieval.index_revision}")
            print(f"index source revision: {retrieval.index_source_revision or 'unavailable'}")
            print(f"source revision: {retrieval.source_revision}")
        print(
            f"recall: {receipt.retrieval_grade}"
            + (f" — {receipt.retrieval_detail}" if receipt.retrieval_detail else "")
        )
        if receipt.failure_kind:
            print(f"failure kind: {receipt.failure_kind}")
        if receipt.remedy:
            print(f"remedy: {receipt.remedy}")
        for failure in receipt.failures:
            print(f"failure: {failure}")
    return 0 if receipt.status == "ready" else 1


def _start(args: argparse.Namespace) -> int:
    health = local_runtime(_root(), push_remote=False).start_retrieval()
    print(json.dumps(health.to_dict(), indent=2) if args.json else health.runtime_state)
    return 0 if health.available and health.bm25_ready else 1


def _stop(args: argparse.Namespace) -> int:
    health = local_runtime(_root(), push_remote=False).shutdown_retrieval()
    print(json.dumps(health.to_dict(), indent=2) if args.json else "stopped")
    return 0


def _open(args: argparse.Namespace) -> int:
    root = _root()
    paths = args.path if isinstance(args.path, list) else [args.path]
    parameters = {'offset':getattr(args, 'offset', 0), 'length':getattr(args, 'length', 16000)}
    request = ({'operation':'open_many', 'paths':paths, **parameters} if len(paths)>1 else
               {'operation':'open', 'path':paths[0], **parameters})
    response = _execute_investigation(root,args.harness,
        InvestigationRequest.parse(request),
        reference=getattr(args,'episode',None),request_id=getattr(args,'request_id',None),origin='open')
    if not response['ok']:
        if getattr(args,'private_result',False):
            attached = _publish_result(root,response,json.dumps(response,ensure_ascii=False)+'\n',
                private=True,harness=args.harness)
            return 0 if attached else 2  # Claude's attachment carries its operation error.
        print(response['error'],file=sys.stderr)
        _mind_notice(root, response, '', args.harness)
        return 2
    sources = response['result'].get('sources', [response['result']])
    parts = []
    for source in sources:
        rendered = (f"Source: {source['path']}\n" if len(paths)>1 else '') + source['content']
        if source.get('next_offset') is not None:
            rendered += f"\n[Continues: search.sh open {source['path']} --offset {source['next_offset']}]\n"
        parts.append(rendered)
    rendered = '\n\n'.join(parts)
    if len(paths)>1 and any(source.get('next_offset') is not None for source in sources):
        rendered = ('[Batch output is bounded; some source windows are partial. '
                    'Use the per-source continuation commands only where more evidence is needed.]\n\n'
                    + rendered)
    _publish_result(root,response,rendered,private=getattr(args,'private_result',False),harness=args.harness)
    return 0


def _find(args):
    root = _root()
    if args.cursor:
        if args.query or any(getattr(args, key, None) is not None for key in
                             ('kind','after','before','recent_days','timezone','prefix','artifact_type','limit')):
            raise ValueError('a continuation uses only --cursor')
        request = {'operation':'discover', 'cursor':args.cursor}
    else:
        request = {'operation':'discover', 'query':args.query or ''}
        for key in ('kind','after','before','recent_days','timezone','prefix','artifact_type','limit'):
            value = getattr(args, key, None)
            if value is not None:
                request[key] = value
    response = _execute_investigation(root, args.harness, request,
        reference=getattr(args,'episode',None), request_id=getattr(args,'request_id',None), origin='find')
    if args.json:
        rendered = json.dumps(response, ensure_ascii=False, indent=2)+'\n'
    elif not response['ok']:
        rendered = response['error']+'\n'
    else:
        result = response['result']
        lines = []
        for index, row in enumerate(result['results'], 1):
            lines.append(f"{index}. {row.get('document_date') or 'undated'} · {row.get('title') or row['path']}")
            lines.append(f"   {row['path']}")
            excerpt = ' '.join(row.get('excerpt', '').split())
            if excerpt:
                lines.append(f"   {excerpt}")
        if not lines:
            lines.append('No matching sources.')
        lines.append('Coverage: '+result['coverage'])
        if result.get('next_cursor'):
            lines.append('More matches: search.sh find --cursor '+result['next_cursor'])
        if result.get('degraded'):
            lines.append('Search degraded; some retrieval capabilities were unavailable.')
        lines.extend('Note: '+warning for warning in result.get('warnings', []))
        rendered = '\n'.join(lines)+'\n'
    attached = _publish_result(root, response, rendered, private=args.private_result, harness=args.harness)
    return 0 if attached or response['ok'] else 2


def _investigate_request(root, harness, request, *, reference=None, request_id=None, private=False):
    response = _execute_investigation(root,harness,request,reference=reference,
                                      request_id=request_id,origin='investigate')
    attached = _publish_result(root,response,json.dumps(response,ensure_ascii=False,indent=2)+'\n',private=private,harness=harness)
    return 0 if attached or response['ok'] else 2


def _investigate(args):
    root = _root()
    raw = args.request if args.request is not None else sys.stdin.read(32769)
    request = decode_request(raw)
    reference = request.pop('episode_id',None)
    request_id = request.pop('request_id',None)
    for name, embedded, supplied in [('episode',reference,getattr(args,'episode',None)),
                                     ('request_id',request_id,getattr(args,'request_id',None))]:
        if embedded and supplied and embedded != supplied:
            raise ValueError(f'conflicting {name} values')
    return _investigate_request(root,args.harness,request,
        reference=reference or getattr(args,'episode',None),
        request_id=request_id or getattr(args,'request_id',None),private=getattr(args,'private_result',False))


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("value must be a positive integer")
    return parsed


def _session_env(args):
    """Claude's SessionStart environment bridge; evidence is never exported."""
    import shlex
    destination = os.environ.get('CLAUDE_ENV_FILE')
    if not destination:
        return 0
    payload = json.load(sys.stdin)
    session_id = payload.get('session_id')
    if not isinstance(session_id, str) or not session_id or len(session_id) > 200:
        raise ValueError('native session identity is required')
    with open(destination, 'a', encoding='utf-8') as handle:
        handle.write('\nexport EGREGORE_NATIVE_SESSION_ID='+shlex.quote(session_id)+'\n')
        handle.write('export EGREGORE_NATIVE_HARNESS='+shlex.quote(args.harness)+'\n')
    return 0


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="egregore-runtime")
    if member_cli is not None:
        member_cli.add_arguments(parser)
    commands = parser.add_subparsers(dest="command", required=True)
    if member_cli is not None:
        member_ready = commands.add_parser("member-ready", help=argparse.SUPPRESS)
        member_ready.set_defaults(handler=_member_ready)

    session_env = commands.add_parser('session-env', help=argparse.SUPPRESS)
    session_env.add_argument('--harness', choices=['claude'], required=True)
    session_env.set_defaults(handler=_session_env)

    find = commands.add_parser('find', help='find sources with compact excerpts')
    find.add_argument('query', nargs='?')
    find.add_argument('--kind', choices=['filename','literal','dates','keyword','semantic','hybrid'])
    for name in ('after','before','timezone','prefix','artifact-type','cursor'):
        find.add_argument('--'+name)
    find.add_argument('--recent-days', type=_positive_int)
    find.add_argument('-n', '--limit', type=_positive_int)
    find.add_argument('--harness', default=os.environ.get('EGREGORE_RUNTIME', 'shell'))
    find.add_argument('--episode', help=argparse.SUPPRESS)
    find.add_argument('--request-id', help=argparse.SUPPRESS)
    find.add_argument('--private-result', action='store_true', help=argparse.SUPPRESS)
    find.add_argument('--json', action='store_true')
    find.set_defaults(handler=_find)

    query = commands.add_parser("query")
    query.add_argument("--task", required=True)
    query.add_argument("--lex", action="append", default=[])
    query.add_argument("--vec", action="append", default=[])
    query.add_argument("--mode", type=RetrievalMode, default=RetrievalMode.LEX)
    query.add_argument("--limit", type=int, default=6)
    query.add_argument("--harness", default=os.environ.get("EGREGORE_RUNTIME", "shell"))
    query.add_argument(
        "--new-search",
        action="store_true",
        help="compatibility flag; a new user prompt is required to reset retrieval limits",
    )
    query.add_argument("--temporal-scope", type=TemporalScope)
    query.add_argument("--recent-days", type=_positive_int)
    query.add_argument("--min-evidence", type=_positive_int, default=1)
    query.add_argument("--compact", action="store_true")
    query.add_argument("--follow-up", help="name the missing evidence within the shared investigation budget")
    query.add_argument('--episode',help='investigation reference attached to this prompt')
    query.add_argument('--request-id',help='stable id for retrying this exact invocation')
    query.add_argument('--private-result',action='store_true',help=argparse.SUPPRESS)
    query.add_argument("--json", action="store_true")
    query.set_defaults(handler=_query)

    investigate = commands.add_parser('investigate', help='bounded Runtime discovery, continuation, and source windows')
    investigate.add_argument('request', nargs='?', help='JSON operation; omit to read JSON from stdin')
    investigate.add_argument('--harness', default=os.environ.get('EGREGORE_RUNTIME','shell'))
    investigate.add_argument('--episode',help='investigation reference attached to this prompt')
    investigate.add_argument('--request-id',help='stable id for retrying this exact invocation')
    investigate.add_argument('--private-result',action='store_true',help=argparse.SUPPRESS)
    investigate.set_defaults(handler=_investigate)

    prompt_hook = commands.add_parser("prompt-hook")
    prompt_hook.add_argument("--harness", required=True)
    prompt_hook.add_argument("--limit", type=int, default=6)
    prompt_hook.set_defaults(handler=_prompt_hook)
    result_hook = commands.add_parser('result-hook')
    result_hook.add_argument('--harness', default='claude')
    result_hook.set_defaults(handler=_result_hook)

    status = commands.add_parser("status")
    status.add_argument("--json", action="store_true")
    status.set_defaults(handler=_status)

    admin_status = commands.add_parser("admin-status")
    admin_status.add_argument(
        "--harness", default=os.environ.get("EGREGORE_RUNTIME", "shell")
    )
    admin_status.set_defaults(handler=_admin_status)

    handoffs = commands.add_parser("handoffs")
    handoffs.add_argument("--mine", action="store_true", help="addressed to the resolved actor")
    handoffs.add_argument("--addressed-to", default=None)
    handoffs.add_argument("--sent", action="store_true", help="sent by the resolved actor")
    handoffs.add_argument("--sent-by", default=None)
    handoffs.add_argument("--status", choices=("any", "open", "unresolved"), default="any")
    handoffs.add_argument("--order", choices=("newest", "oldest"), default="newest")
    handoffs.add_argument("--limit", type=_positive_int, default=1)
    handoffs.add_argument("--open", action="store_true", help="open the top result through Runtime read policy")
    handoffs.add_argument("--json", action="store_true")
    handoffs.add_argument("--timing", action="store_true")
    handoffs.add_argument(
        "--harness", default=os.environ.get("EGREGORE_RUNTIME", "shell")
    )
    handoffs.set_defaults(handler=_handoffs)

    readiness = commands.add_parser("readiness")
    readiness.add_argument("--json", action="store_true")
    readiness.add_argument("--plain", action="store_true")
    readiness.add_argument(
        "--harness", default=os.environ.get("EGREGORE_RUNTIME", "shell")
    )
    readiness.set_defaults(handler=_readiness)

    upgrade = commands.add_parser("upgrade")
    upgrade.add_argument(
        "action",
        choices=("status", "init", "prepare", "activate", "cancel", "rollback"),
    )
    upgrade.add_argument("--candidate", default="")
    upgrade.add_argument("--tarball", default="")
    upgrade.add_argument("--fetch", action="store_true")
    upgrade.set_defaults(handler=_upgrade)

    team_sync_parser = commands.add_parser("team-sync")
    team_sync_parser.add_argument("--fetch", action="store_true")
    team_sync_parser.set_defaults(handler=_team_sync_cmd)

    sync = commands.add_parser("sync")
    sync.add_argument("--json", action="store_true")
    sync.set_defaults(handler=_sync)

    start = commands.add_parser("start")
    start.add_argument("--json", action="store_true")
    start.set_defaults(handler=_start)

    stop = commands.add_parser("stop")
    stop.add_argument("--json", action="store_true")
    stop.set_defaults(handler=_stop)

    source = commands.add_parser("open")
    source.add_argument("path", nargs='+')
    source.add_argument('--offset', type=int, default=0)
    source.add_argument('--length', type=int, default=16000)
    source.add_argument("--harness", default=os.environ.get("EGREGORE_RUNTIME", "shell"))
    source.add_argument('--episode',help='investigation reference attached to this prompt')
    source.add_argument('--request-id',help='stable id for retrying this exact invocation')
    source.add_argument('--private-result',action='store_true',help=argparse.SUPPRESS)
    source.set_defaults(handler=_open)
    for name in _COMMAND_MODULES:
        module = optional_module(name)
        if module is not None:
            module.register(commands)
    return parser


def main(argv=None) -> int:
    args = _parser().parse_args(argv)
    if getattr(args, "limit", None) is not None and args.limit < 1:
        raise ValueError("retrieval limit must be positive")
    with (member_cli.invocation(args, _root(), allowed_commands={
        "prompt-hook", "find", "open", "handoffs", "member-ready",
    }) if member_cli is not None else nullcontext()):
        return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuthorizationDenied, EgregoreRuntimeError, RuntimeError, ValueError) as exc:
        print(f"egregore: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
