"""Harness-neutral command adapter for organizational context.

Claude, Codex, Pi, Prime, and shell skills enter the Egregore Runtime here.
This module deliberately knows no QMD, graph, Supabase, or filesystem-index
implementation details.  Infrastructure is composed behind ``local_runtime``.
"""

from __future__ import annotations

from .investigation_guidance import INVESTIGATION_GUIDANCE, RECALL_WORKFLOW_GUIDANCE

import argparse
import fcntl
import hashlib
from io import StringIO
import json
import os
import re
import subprocess
import sys
import time
import unicodedata
import uuid
from contextlib import contextmanager, redirect_stdout
from contextvars import ContextVar
from dataclasses import asdict
from datetime import UTC, datetime, timedelta
from pathlib import Path

from .contracts import (
    EvidenceItem,
    OrgContext,
    Permission,
    RetrievalMode,
    RetrievalRequest,
    TemporalScope,
)
from .errors import AuthorizationDenied, EgregoreRuntimeError
from .identity import actor_lexical_formulations, organization_member_presentations
from .investigation_contracts import InvestigationRequest, decode_request
from . import episode_binding
from .runtime import EgregoreRuntime, local_runtime


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


@contextmanager
def _invocation(root, reference=None):
    """A native prompt's explicit reference is stronger than shared shell state."""
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
        runtime = runtime or local_runtime(root,push_remote=False)
        actor = actor or _actor(runtime,root,harness)
        episode_id = binding.episode_id if binding else _session_id(root)
        # Old receipts are read only as a migration bridge; new calls never write them.
        receipt = None if binding else _active_observe_receipt(root,harness)
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
        return runtime.investigate(actor,request,episode_id=episode_id,seeds=contexts,
            initial_searches=initial_searches,initial_bounds=bounds,request_id=request_id,
            binding=binding,origin=origin)


def _publish_result(root, response, rendered, *, private=False, harness='shell'):
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
    if private:
        from .private_result import prepare
        reference=response['episode_id']
        session=episode_binding.resolve(root,reference).session_id if reference.startswith('ep_') else _session_id(root)
        print(prepare(root,response,rendered,session))
    else:
        from .private_result import record_stdout
        try:
            record_stdout(root,response,rendered)
        except (OSError, ValueError, KeyError, EgregoreRuntimeError):
            if response['ok']:
                raise
            # A missing/corrupt receipt must not replace the operation's error.
        sys.stdout.write(rendered)
    return private


def _result_hook(args):
    """Native PostToolUse adapter; stdin and stdout use the host hook contract."""
    from .private_result import allowed_root, consume, receipts_from_tool
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
            runtime=local_runtime(root,push_remote=False)
            actor=runtime.resolve_actor(session_id=session,harness=args.harness)
            results.append(consume(root,receipt['id'],runtime,actor,session_id=session,
                                   native_turn_id=payload.get('turn_id') or payload.get('prompt_id')))
        if not results:
            return 0
        context='EGREGORE_RETRIEVAL_CONTEXT_V1\nAuthorized Runtime evidence for this invocation. Do not reproduce ranking traces.\n'+'\n'.join(results)+'\nEND_EGREGORE_RETRIEVAL_CONTEXT_V1'
    except (OSError,ValueError,TypeError,KeyError,EgregoreRuntimeError) as error:
        context=f'Runtime private result could not be attached: {error}. Do not treat it as received evidence.'
    print(json.dumps({'hookSpecificOutput':{'hookEventName':'PostToolUse','additionalContext':context}}))
    return 0


def _session_id(root: Path) -> str:
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

    session = re.sub(r"[^A-Za-z0-9_.-]", "-", session or _session_id(root))[:120]
    return (
        root / ".egregore" / "runtime" / "observe"
        / f"actor-contract-{harness}-{session}.sent"
    )


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
    runtime = local_runtime(root, push_remote=False)
    actor = _actor(runtime, root, args.harness)
    request = _request(
        task=args.task, org_id=actor.profile.org_id, actor_id=actor.actor.actor_id,
        lex=identity_aware_lexical_formulations(root, actor, args.task, tuple(args.lex)),
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
    member_names = "; ".join(
        f"{', '.join(member.aliases)} → {member.display_name}"
        if member.aliases
        else member.display_name
        for member in organization_member_presentations(root, actor_context)
    ) or "unavailable"
    search_command = 'bash bin/search.sh find "<query>" --kind <kind>'
    if harness == "claude":
        search_command += " --context-packet"
    if not full:
        return "\n".join(
            (
                "EGREGORE_ACTOR_CONTEXT_V1",
                "Reminder — the full contract was attached earlier in this session.",
                RECALL_WORKFLOW_GUIDANCE,
                f"Actor: {actor.display_name} · Actor ID: {actor.actor_id} · "
                f"Organization ID: {actor_context.profile.org_id} · Runtime root: {root}",
                _RECALL_ONLY_SCOPE,
                "When a prompt needs that recall and no EGREGORE_ORG_CONTEXT_V1 block is "
                f"attached, choose the operation kind and use `{search_command}`; exact latest/oldest/open "
                "handoff questions use `bash bin/search.sh handoffs …` instead.",
                'Reuse evidence; batch source reads with search.sh open path-a path-b. '
                'Runtime retains evidence and enforces the prompt budget and date boundary.',
                "`me` and `myself` mean this Actor ID and display name; never infer identity "
                "from the OS user, Git, or GitHub names.",
                "END_EGREGORE_ACTOR_CONTEXT_V1",
            )
        )
    return "\n".join(
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
            INVESTIGATION_GUIDANCE,
            "On Claude, `--context-packet` keeps the internal evidence trace out of the user "
            "transcript and attaches it through PostToolUse. Keep that flag on model-led "
            "searches; never repeat the attached ranking trace in the answer.",
            "Exact lifecycle questions route differently: recognize them from meaning, not "
            "fixed phrases. When the user asks for the latest/newest/oldest handoff addressed "
            "to or sent by a specific person (including `me`), or open/unresolved handoffs, "
            "run the typed deterministic lookup `bash bin/search.sh handoffs "
            "[--mine|--sent|--addressed-to X|--sent-by X] [--status open] "
            "[--order newest|oldest] [--limit N] [--open]` instead of a semantic query — one "
            "memory-form retrieval beat, then answer from its result. Topical or synthesis "
            "questions about handoffs (`the handoff about privacy`) remain semantic "
            "`search.sh find` recall.",
            "Do not substitute Activity, Dashboard, Project, Git inspection, optional hosted indexes, or raw "
            "memory scans for that recall. A named request to display a status card is an "
            "explicit status workflow; a question asking for an explained synthesis of "
            "organizational work is Runtime/QMD recall. Do not query optional hosted indexes unless the user "
            "explicitly requests relationship "
            "or optional hosted index status.",
            "For every identity-bearing workflow, `me`, `myself`, `from me`, "
            "and `to myself` mean this Actor ID and display name. Use the "
            "display name for presentation and the Actor ID for ownership, "
            "authorization, attribution, creator, steward, recipient, and "
            "respondent fields. Never infer identity from the OS user, Git, "
            "GitHub, a branch name, or prose aliases.",
            "END_EGREGORE_ACTOR_CONTEXT_V1",
        )
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
) -> tuple[str, ...]:
    """Bind the active actor and expand explicitly named organization members.

    This keeps cold BM25 retrieval equivalent to stable identity resolution:
    a chosen display name, provider handle, and legacy local alias all refer to
    one member. First-person references use the active actor; the directory is
    never added wholesale. Semantic identity binding happens at request construction.
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
    for member in organization_member_presentations(root, actor):
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


def _prompt_hook(args: argparse.Namespace) -> int:
    try:
        payload = json.load(sys.stdin)
    except (json.JSONDecodeError, OSError):
        return 0
    if not isinstance(payload, dict):
        return 0
    prompt = str(payload.get("prompt") or payload.get("user_prompt") or "").strip()
    root = _prompt_root(payload, _root())
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
    except Exception as exc:  # Hooks are advisory and must never block a prompt.
        additional_context = (
            f"Actor context is unavailable ({type(exc).__name__}). "
            "Do not guess actor identity. Organizational retrieval has not run.\n"
            + INVESTIGATION_GUIDANCE
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
        gate = runtime.admin_gate
        result["admin"] = bool(gate is not None and gate.actor_is_admin(actor))
    except Exception:
        result = {"admin": False, "display_name": None, "actor_id": None}
    print(json.dumps(result, sort_keys=True))
    return 0


def _access_status(args: argparse.Namespace) -> int:
    """One authorized snapshot of identity, membership, and capabilities.

    The Runtime authorization backend is the source of truth: every value is
    a real authorize() decision, never derived independently by a UI. Any
    failure reports status "attention" and nothing else — no partial claims.
    """

    root = _root()
    try:
        runtime = local_runtime(root, push_remote=False)
        actor = _actor(runtime, root, args.harness)
        gate = runtime.admin_gate

        def allowed(*permissions: Permission) -> bool:
            return all(
                runtime.authorize(actor, permission).allowed
                for permission in permissions
            )

        read_decision = runtime.authorize(actor, Permission.READ)
        membership = actor.membership
        out = {
            "status": "ok",
            "display_name": actor.actor.display_name,
            "actor_id": actor.actor.actor_id,
            "org_name": actor.profile.name,
            "org_id": actor.profile.org_id,
            "membership_status": membership.status if membership else "unknown",
            "roles": sorted(membership.roles) if membership else [],
            "admin": bool(gate is not None and gate.actor_is_admin(actor)),
            "capabilities": {
                "read": allowed(Permission.READ),
                "create": allowed(Permission.WRITE),
                "update": allowed(Permission.WRITE),
                "publish": allowed(Permission.SHARE),
                "notify": allowed(Permission.SHARE, Permission.EXECUTE),
                "org_settings": allowed(Permission.ADMINISTER),
            },
            "shared_memory_scope": sorted(read_decision.scopes),
        }
    except Exception:
        out = {"status": "attention"}
    print(json.dumps(out, sort_keys=True))
    return 0


def _handoffs(args: argparse.Namespace) -> int:
    """Typed lifecycle lookup — exact handoff questions, zero semantic search.

    This is not a second model-led query: it is a bounded deterministic
    operation over canonical artifact metadata, available even when an
    attached Observe packet missed.
    """

    from .handoff_lookup import HandoffLookupService

    root = _root()
    runtime = local_runtime(root, push_remote=False)
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
    if args.json:
        print(
            json.dumps(
                {
                    "records": [asdict(record) for record in records],
                    "lookup_ms": lookup_ms,
                },
                sort_keys=True,
            )
        )
        return 0
    if not records:
        print("no matching handoff exists for that filter")
        return 0
    for index, record in enumerate(records, start=1):
        day = record.occurred_at.split("T")[0]
        print(f"{index}. {day} · from {record.sender} · to {record.recipient} · {record.status} · {record.topic}")
        if record.claim:
            print(f"   claim: {record.claim}")
        if record.ask:
            print(f"   ask: {record.ask}")
        print(f"   source: {record.canonical_path}")
    if args.open and records:
        content = runtime.open_source(actor, records[0].canonical_path)
        print()
        print(content)
    return 0


def _status(args: argparse.Namespace) -> int:
    health = local_runtime(_root(), push_remote=False).retrieval_health()
    if args.json:
        print(json.dumps(health.to_dict(), indent=2))
    else:
        print(f"adapter: {health.adapter} {health.adapter_version}")
        print(f"index spec: {health.index_spec_version}")
        print(f"index revision: {health.index_revision}")
        print(f"source revision: {health.source_revision}")
        print(f"embedding: {health.embedding_state}")
        print(f"readiness: {health.runtime_state}")
        print(f"bm25 ready: {'yes' if health.bm25_ready else 'no'}")
        print(f"semantic ready: {'yes' if health.semantic_ready else 'no'}")
        print(f"semantic build: {health.semantic_source_revision or 'none'}")
        print(f"worker pid: {health.runtime_pid or 'none'}")
        print(f"endpoint: {health.runtime_endpoint or 'none'}")
        print(f"index: {health.index_path or 'unknown'}")
        print(f"collection: {health.collection or 'unknown'}")
        print(f"available: {'yes' if health.available else 'no'}")
        for warning in health.warnings:
            print(f"warning: {warning}")
    return 0 if health.available else 1


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
        state["instance_hash"] = upgrade_module.instance_key(root)
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
            instance_hash=upgrade_module.instance_key(root),
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
    commands = parser.add_subparsers(dest="command", required=True)

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

    access_status = commands.add_parser("access-status")
    access_status.add_argument(
        "--harness", default=os.environ.get("EGREGORE_RUNTIME", "shell")
    )
    access_status.set_defaults(handler=_access_status)

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
    return parser


def main() -> int:
    args = _parser().parse_args()
    if getattr(args, "limit", None) is not None and args.limit < 1:
        raise ValueError("retrieval limit must be positive")
    return args.handler(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (AuthorizationDenied, EgregoreRuntimeError, RuntimeError, ValueError) as exc:
        print(f"egregore: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
