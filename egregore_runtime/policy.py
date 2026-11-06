"""Deterministic v1 policy and action-permission implementations."""

from __future__ import annotations

import contextlib
from dataclasses import dataclass, field, replace
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time
from typing import Mapping, Sequence

from .access import PROJECTION_ROOT, AuthorizationInputs, authorization_inputs, bounded_committed_memory, committed_memory, principal
from . import held, shadow
from .contracts import (
    ActionAuthorizer,
    ActorContext,
    Permission,
    PolicyDecision,
    RetrievalRequest,
)


ACTIONS = ("read", "write", "append")


@dataclass(frozen=True, slots=True)
class Verdict:
    allowed: bool
    reason: str
    canonical: str | None = None
    resolved: Path | None = None
    note: str = ""


def _canonical_parts(path: str) -> tuple[str, ...] | None:
    normalized = path.strip()
    if normalized.startswith("/") or re.match(r"^[A-Za-z]:", normalized) or "\x00" in normalized or "\\" in normalized:
        return None
    normalized = normalized.strip("/")
    parts = tuple(normalized.split("/")) if normalized else ()
    if not parts or any(part in {"", ".", ".."} for part in parts):
        return None
    return parts


def _resolve(path: Path) -> Path:
    try:
        return path.resolve(strict=True)
    except FileNotFoundError:
        return path.resolve(strict=False)


def within(path: str, prefixes: Sequence[str], *, root: Path | None = None) -> bool:
    """Containment only: both requested and resolved spellings must fit."""
    canonical = _canonical_parts(path)
    if canonical is None:
        return False
    if not any(canonical[:len(prefix)] == prefix for raw in prefixes if (prefix := _canonical_parts(raw))):
        return False
    if root is None:
        return True
    try:
        if canonical[0] != "memory":
            return False
        resolved = _resolve(root / Path(*canonical[1:]))
        relative = resolved.relative_to(_resolve(root))
        physical = ("memory", *relative.parts)
        return not any("\\" in part or "\x00" in part for part in physical) and any(
            physical[:len(prefix)] == prefix for raw in prefixes if (prefix := _canonical_parts(raw)))
    except (OSError, RuntimeError, ValueError):
        return False


def is_admin(decision: PolicyDecision) -> bool:
    return decision.allowed and decision.audience == "admin"


_POLICIES = frozenset({"all-access-v1", "roster-v1-shadow", "roster-v1"})


def _trusted(decision: PolicyDecision) -> bool:
    return decision.audience != "outside" and decision.policy_epoch in _POLICIES


class _ReadProjection:
    __slots__ = ("decision", "root", "paths", "budget", "held", "rechecked", "binding")

    def __init__(self, decision, root, paths, budget):
        self.decision, self.root, self.paths, self.budget = decision, root, paths, budget
        source = bounded_committed_memory(root, decision.memory_revision, budget=budget) if decision.memory_revision else None
        self.held = held.bounded_tree(root, decision.released, budget=budget, committed=source)
        self.rechecked, self.binding = False, None

    def validate(self, decision, root):
        self.budget.remaining()
        if (decision != self.decision or Path(root) != self.root or self.root.resolve(strict=True) != self.root
                or held._file_identity(self.root.stat()) != self.held.identity or self.held.rules != held.HELD_RULES_VERSION):
            self.budget.fail()


def prepare_read_projection(decision, *, root, paths, budget):
    """Prepare complete bounded hold inputs; this object is not a reusable grant."""
    held._read_budget(budget)
    try:
        root = Path(root)
        if (type(decision) is not PolicyDecision or not decision.allowed or decision.permission != Permission.READ
                or decision.scope not in {"read", "hand-over"} or decision.policy_epoch not in _POLICIES
                or decision.audience not in {"member", "admin", "outside"}
                or decision.audience == "outside" and (decision.scope != "hand-over" or not decision.memory_revision)
                or not root.is_absolute() or root != root.resolve(strict=True)
                or not isinstance(paths, (tuple, list)) or len(paths) > 64):
            budget.fail()
        selected = set()
        for path in paths:
            parts = _canonical_parts(path) if isinstance(path, str) else None
            if (not parts or parts[0] != "memory" or path != "/".join(parts)
                    or len(os.fsencode(path)) > budget.limits.path_bytes):
                budget.fail()
            selected.add(path)
        return _ReadProjection(decision, root, tuple(sorted(selected)), budget)
    except (OSError, ValueError, RuntimeError):
        budget.fail()


def _projection(projection, decision, root):
    if type(projection) is not _ReadProjection:
        raise held.BoundedReadUnavailable("bounded read unavailable")
    projection.validate(decision, root)
    return projection


def _projection_path(projection, decision, root, path):
    projection = _projection(projection, decision, root)
    if path not in projection.paths or not within(path, decision.read_prefixes):
        return None
    relative = path.removeprefix("memory/")
    entry = projection.held.documents.get(relative)
    if entry is None:
        return None
    target, raw = entry
    if not within("memory/" + target, decision.read_prefixes):
        return None
    if projection.held.source is not None:
        if projection.held.source.entries.get(relative, (None,))[0] not in {"100644", "100755"}:
            return None
    else:
        original, physical = projection.held.identities[relative]
        if not stat.S_ISREG(original[2]) or original[3] != 1 or physical[3] != 1:
            return None
    return relative, target, raw


def read_projection_header(decision, path, *, root, projection, max_bytes=16384):
    try:
        projection = _projection(projection, decision, root)
        if type(max_bytes) is not int or not 1 <= max_bytes <= 16384:
            projection.budget.fail()
        entry = _projection_path(projection, decision, root, path)
        if entry is None:
            return None
        raw = entry[2]
        if not raw.startswith(b"---\n"):
            return None
        end = raw.find(b"\n---\n", 3, max_bytes)
        if end < 0:
            end = raw.find(b"\n---\r\n", 3, max_bytes)
            size = end + 6
        else:
            size = end + 5
        if end < 0 or size > max_bytes:
            return None
        projection.budget.charge("selected_bytes", size)
        return raw[:size]
    except (OSError, ValueError, RuntimeError):
        return None


def read_projection_bytes(decision, path, *, root, projection):
    try:
        projection = _projection(projection, decision, root)
        entry = _projection_path(projection, decision, root, path)
        if entry is None:
            return None
        raw = entry[2]
        if len(raw) > 256 * 1024:
            return None
        verdict = check(decision, path, root=root, observe_shadow=False, max_source_bytes=256 * 1024,
                        read_projection=projection)
        if not verdict.allowed or bytes_held(decision, path, raw, root=root, read_projection=projection):
            return None
        projection.budget.charge("selected_bytes", len(raw))
        return raw
    except (OSError, ValueError, RuntimeError):
        return None


def recheck_read_projection(decision, *, root, projection):
    try:
        projection = _projection(projection, decision, root)
        projection.budget.recheck()
        projection.held.recheck()
        projection.validate(decision, root)
        preimage = {"schema": "egregore.policy-read-projection/v1", "decision": decision.to_dict(),
                    "root": str(projection.root), "root_identity": projection.held.identity,
                    "source_revision": decision.memory_revision, "inventory": projection.held.fingerprint,
                    "rules": projection.held.rules, "releases": list(decision.released),
                    "selection": [{"path": path, "target": entry[0], "digest": hashlib.sha256(entry[1]).hexdigest()}
                                  if (entry := projection.held.documents.get(path.removeprefix("memory/"))) is not None
                                  else {"path": path, "target": None, "digest": None} for path in projection.paths],
                    "authority": sorted((list(key), value) for key, value in projection.budget.authority.items())}
        projection.binding = hashlib.sha256(json.dumps(preimage, sort_keys=True, ensure_ascii=True, separators=(",", ":")).encode()).hexdigest()
        projection.rechecked = True
        projection.budget.remaining()
        return True
    except (OSError, ValueError, RuntimeError):
        if type(projection) is _ReadProjection:
            projection.budget.invalid = True
        return False


def read_projection_binding(decision, *, root, projection):
    try:
        projection = _projection(projection, decision, root)
        return projection.binding if projection.rechecked else None
    except (OSError, ValueError, RuntimeError):
        return None


def tree_for(decision: PolicyDecision, root: Path) -> held.Tree:
    """The memory a decision judges every class against: as committed at its revision, or as walked,
    with the hint only for the operator's own configured decision."""
    if decision.memory_revision:
        return held.committed_tree(committed_memory(root, decision.memory_revision), decision.released)
    return held.tree(root, decision.released, trust_cache=_trusted(decision))


def _committed(decision: PolicyDecision, relative: str, action: str, root: Path, every: bool) -> tuple[int, ...] | str:
    """Held classes of the committed file, or the reason committed memory refuses it."""
    try:
        tree = committed_memory(root, decision.memory_revision)
        kind = tree.kind(relative)
        if action == "append":
            return "exists" if kind else ()
        if kind != "file":
            return "link" if kind == "link" else "not-committed"
        data = tree.read(relative)
        return tree_for(decision, root).classes(relative, data) if every else held.blob_classes(data)
    except (OSError, ValueError, subprocess.SubprocessError):
        return "uncommitted-source"


def _counted_later(decision: PolicyDecision) -> bool:
    """A roster-v1-shadow read: only class 1 holds it, so the class roster-v1 would hold is counted, not awaited."""
    return decision.scope == "read" and decision.policy_epoch == "roster-v1-shadow"


def check(decision: PolicyDecision, path: str, action: str = "read", *, root: Path, explain: bool = False,
          observe_shadow: bool = True, max_source_bytes: int | None = None, read_projection=None) -> Verdict:
    """The authority predicate; callers open or write only the returned path.

    A decision bound to a ``memory_revision`` is also decided on memory as
    committed there; an outside decision without one is refused, so nothing
    handed to another principal reads working-tree bytes or hold markers.

    Under roster-v1-shadow a read holds class 1 alone, read from the bytes;
    the class roster-v1 would hold is counted by ``shadow.defer``, which
    never builds a tree on the read path. ``explain`` judges it now, for a
    verdict's ``note``: ``access check`` names it. A bounded read-only caller may
    set ``observe_shadow=False`` to suppress this optional shadow accounting,
    including its deferred tree walk and writes, without changing the verdict.
    This does not make roster-v1 or an explained read a bounded tree-free read.
    ``max_source_bytes`` optionally bounds each working-file authority read
    (plus one byte to detect overflow). It does not bound a rule tree, and
    committed-memory reads refuse this option until their owner supports it.
    """
    projected = None
    if read_projection is not None:
        try:
            _projection(read_projection, decision, root)
            if action != "read":
                return Verdict(False, "invalid-action")
            projected = _projection_path(read_projection, decision, root, path)
            if projected is None:
                return Verdict(False, "bounded-read-unavailable")
        except (OSError, ValueError, RuntimeError):
            return Verdict(False, "bounded-read-unavailable")
    if action not in ACTIONS:
        return Verdict(False, "invalid-action")
    if decision.scope not in {"read", "hand-over"}:
        return Verdict(False, "invalid-scope")
    if not decision.allowed:
        return Verdict(False, "denied")
    if max_source_bytes is not None:
        if type(max_source_bytes) is not int or not 1 <= max_source_bytes <= 8 * 1024 * 1024:
            return Verdict(False, "invalid-source-limit")
        if decision.memory_revision and read_projection is None:
            return Verdict(False, "bounded-committed-read-unavailable")
    if decision.audience == "root":  # a read-only copy: only the generation its slot admits now, never a stale one
        from .projection import serves
        if not serves(root):
            return Verdict(False, "being-rebuilt")
    prefixes = getattr(decision, action + "_prefixes") + (decision.write_prefixes if action == "append" else ())
    if not prefixes:
        return Verdict(False, "outside-scope")
    canonical = _canonical_parts(path)
    if canonical is None:
        return Verdict(False, "invalid-path")
    parts, canonical = canonical, "/".join(canonical)
    if parts[0] != "memory":
        return Verdict(False, "outside-scope", canonical)
    if decision.audience == "outside" and not decision.memory_revision:
        return Verdict(False, "uncommitted-source", canonical)
    try:
        requested = root / Path(*parts[1:])
        resolved, base = ((root / projected[1], root) if projected is not None else (_resolve(requested), _resolve(root)))
        if not resolved.is_relative_to(base):
            return Verdict(False, "outside-root", canonical)
        if not within(canonical, prefixes, root=None if projected is not None else root):
            return Verdict(False, "outside-scope", canonical)
        if action == "append" and (os.path.lexists(resolved) or os.path.lexists(requested)):
            return Verdict(False, "exists", canonical)
        every = not (decision.scope == "read" and decision.policy_epoch == "all-access-v1")  # else class 1 alone matters
        relative = "/".join(parts[1:])
        found = (read_projection.held.classes(relative, projected[2], projected[1]) if projected is not None
                 else _committed(decision, relative, action, root, every) if decision.memory_revision else None)
        if projected is not None and max_source_bytes is not None and len(projected[2]) > max_source_bytes:
            return Verdict(False, "source-limit", canonical)
        if isinstance(found, str):
            return Verdict(False, found, canonical)
        if is_admin(decision):
            return Verdict(True, "allowed", canonical, resolved)
        released = (within(canonical, decision.released) and within("memory/" + projected[1], decision.released)
                    if projected is not None else within(canonical, decision.released, root=None if decision.memory_revision else root))
        later = None
        if found is None and not every and max_source_bytes is None:
            found = held.classes(resolved)
        elif found is None:
            if not resolved.is_file():
                data = None
            elif max_source_bytes is None:
                data = resolved.read_bytes()
            else:
                with resolved.open("rb") as source:
                    data = source.read(max_source_bytes + 1)
                if len(data) > max_source_bytes:
                    return Verdict(False, "source-limit", canonical)
            physical = resolved.relative_to(base).as_posix()
            if data is None:
                found = ()
            elif not every:
                found = held.blob_classes(data)
            elif _counted_later(decision) and not explain:
                found = held.admin_class(data)
                later = None if found or released else (relative, physical, data)
            else:
                found = tree_for(decision, root).classes(relative, data, physical)
        hold, would = held.judge(decision.scope, decision.policy_epoch, found, released)
        if hold:
            return Verdict(False, f"held:{hold}", canonical)
        if observe_shadow and would and read_projection is None:
            shadow.note(root, would)
        if observe_shadow and later and read_projection is None:
            shadow.defer(root, decision.released, *later)
    except (OSError, RuntimeError, ValueError):
        return Verdict(False, "invalid-path", canonical)
    note = f"shadow:{would}" if would else "released" if released and any(number != 1 for number in found) else ""
    return Verdict(True, "allowed", canonical, resolved, note)


_REFUSALS = {
    "outside-root": "it resolves outside memory", "invalid-path": "not a memory path",
    "invalid-action": "not an action", "invalid-scope": "not a decision scope",
    "exists": "it already exists; append adds new files only", "not-committed": "it is not in committed memory",
    "link": "it is a link in committed memory", "uncommitted-source": "decided without the committed settings",
    "being-rebuilt": "this read-only copy is being rebuilt",
}


def rule(decision: PolicyDecision, verdict: Verdict, action: str) -> str:
    """Name the rule that decided a verdict, in plain words."""
    if verdict.allowed:
        granted = getattr(decision, action + "_prefixes") + (decision.write_prefixes if action == "append" else ())
        prefix = next((p for p in granted if within(verdict.canonical or "", (p,))), "")
        named = f"{action} grant {prefix}" + (" · admin" if is_admin(decision) else "")
        if verdict.note.startswith("shadow:"):
            number = int(verdict.note.removeprefix("shadow:"))
            return named + f" · roster-v1 would hold it ({held.CLASS_NAMES.get(number, f'class {number}')})"
        return named + (" · released by access.release" if verdict.note == "released" else "")
    if verdict.reason.startswith("held:"):
        number = int(verdict.reason.removeprefix("held:"))
        return f"held: {held.CLASS_NAMES.get(number, f'class {number}')}"
    if verdict.reason == "denied":
        return "no grant: " + "; ".join(decision.reasons)
    if verdict.reason == "outside-scope":
        return f"outside the {action} grant"
    return _REFUSALS.get(verdict.reason, verdict.reason)


def allows(decision: PolicyDecision, path: str, action: str = "read", *, root: Path) -> bool:
    return check(decision, path, action, root=root).allowed


def bytes_held(decision: PolicyDecision, path: str, data: bytes, *, root: Path, read_projection=None) -> int | None:
    """The class that holds ``data``, bytes a caller read at memory ``path``, as ``check`` would hold
    the file if it read them: every class the decision applies, less the rule classes ``access.release``
    lifts. None for an admin. ``check`` decides the path and this the bytes read from it, so a file
    rewritten between the read and the check never carries bytes that were held. Fails closed."""
    projected = None
    if read_projection is not None:
        try:
            projected = _projection_path(read_projection, decision, root, path)
            if projected is None or type(data) is not bytes or data != projected[2]:
                read_projection.budget.fail()
        except (OSError, ValueError, RuntimeError, AttributeError):
            return 1
    if is_admin(decision):
        return None
    parts = _canonical_parts(path)
    try:
        if parts is None or parts[0] != "memory":
            raise ValueError("not a memory path")
        relative = "/".join(parts[1:])
        every = not (decision.scope == "read" and decision.policy_epoch == "all-access-v1")
        if projected is not None:
            found = read_projection.held.classes(relative, data, projected[1])
        elif not every:
            found = held.blob_classes(data)
        elif _counted_later(decision):  # only class 1 holds it; check counts what roster-v1 would hold
            found = held.admin_class(data)
        elif decision.memory_revision:
            found = tree_for(decision, root).classes(relative, data)
        else:
            physical = _resolve(root / relative).relative_to(_resolve(root)).as_posix()
            found = tree_for(decision, root).classes(relative, data, physical)
        released = (within("/".join(parts), decision.released) and within("memory/" + projected[1], decision.released)
                    if projected is not None else within("/".join(parts), decision.released, root=None if decision.memory_revision else root))
        return held.judge(decision.scope, decision.policy_epoch, found, released)[0]
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
        return 1


def strips(decision: PolicyDecision) -> bool:
    """Whether a decision strips held names: a non-admin's, in a scope that applies every class (``held.judge``)."""
    return not is_admin(decision) and not (decision.scope == "read" and decision.policy_epoch in held.LENIENT)


_REDACTORS: dict[tuple, held.Redactor] = {}
_DOTTED: dict[str, tuple[float, tuple]] = {}


def _dotted(root: Path) -> tuple[tuple, tuple]:
    """What the held walk skips and ``check`` still reads, as listed within ``held.FRESH_SECONDS``: Markdown
    documents under a dot name (``.git`` aside) with the stat of what they read as, and folder links inside
    memory as (link, target)."""
    now, seen = time.monotonic(), _DOTTED.get(str(root))
    if seen is None or now - seen[0] >= held.FRESH_SECONDS:
        found, links, base = [], [], _resolve(root)
        for folder, folders, files in os.walk(root):
            parts = Path(folder).relative_to(root).parts
            for name in [name for name in folders if os.path.islink(os.path.join(folder, name))]:
                with contextlib.suppress(OSError, RuntimeError, ValueError):
                    target = _resolve(Path(folder, name))
                    links += [("/".join((*parts, name)), target.relative_to(base).as_posix())] if target.is_dir() else []
            folders[:] = [name for name in folders if name != ".git"]
            for name in files:
                if name.lower().endswith(".md") and any(part.startswith(".") for part in (*parts, name)):
                    with contextlib.suppress(OSError):
                        info = os.stat(os.path.join(folder, name))
                        found.append(("/".join((*parts, name)), info.st_mtime_ns, info.st_size, info.st_ino))
        seen = _DOTTED[str(root)] = (now, (tuple(sorted(found)), tuple(sorted(links))))
    return seen[1]


def redactor(decision: PolicyDecision, root: Path) -> held.Redactor | None:
    """The held names a decision strips, from the memory its holds are judged on (``tree_for``); None when it
    strips none. Each held document is read for its title and ids; the shown ones only for their titles,
    once a held title turns up in a text. Shown means readable by this decision: a committed link, or a
    link out of the read grant, shields no name."""
    if not strips(decision):
        return None
    root = Path(root)
    tree = tree_for(decision, root)
    memory = committed_memory(root, decision.memory_revision) if decision.memory_revision else None
    dotted, links = ((tuple((name,) for name in memory.entries if name.lower().endswith(".md")
                            and any(part.startswith(".") for part in name.split("/"))), ()) if memory else _dotted(root))
    stamp = tree.walk or decision.memory_revision
    key = (str(root), stamp, dotted, links, decision.released, decision.read_prefixes, _trusted(decision))
    if stamp and key in _REDACTORS:
        return _REDACTORS[key]
    if memory is not None:
        def read(rel: str) -> bytes:
            target = held.committed_target(memory, rel)
            return memory.read(target) if target else b""
    else:
        base = _resolve(root)

        def read(rel: str) -> bytes:
            path = _resolve(base / rel)
            return path.read_bytes() if path.is_relative_to(base) and path.is_file() else b""
    holds = set(tree.held)
    shown = [rel for rel, target in tree.listed if rel not in holds and (target == rel if memory else
             within("memory/" + target, decision.read_prefixes)) and within("memory/" + rel, decision.read_prefixes)]
    whole = replace(decision, read_prefixes=("memory",))  # held whatever the grant, as the walked tree is
    for rel, *_ in dotted:  # judged one by one, as a read of each would be
        holds.update((rel,) if check(whole, "memory/" + rel, "read", root=root).reason.startswith("held:") else ())
        shown += [rel] if check(decision, "memory/" + rel, "read", root=root).allowed else []
    named = {rel: {rel} for rel in holds}  # and every spelling through a folder link, a chain of them too
    for _ in range(held.LINK_HOPS if links else 0):
        grown = {rel: names | {link + name[len(target):] for name in names for link, target in links
                               if name.startswith(target + "/")} for rel, names in named.items()}
        named, done = grown, grown == named
        if done:
            break
    found = held.Redactor([("memory/" + name, *held.describe("memory/" + rel, read(rel)))
                           for rel in sorted(holds) for name in sorted(named[rel])],
                          ["memory/" + rel for rel in shown],
                          lambda: [held.describe("memory/" + rel, read(rel))[0] for rel in shown])
    if stamp:
        while len(_REDACTORS) >= 4:
            _REDACTORS.pop(next(iter(_REDACTORS)))
        _REDACTORS[key] = found
    return found


def narrow(decision: PolicyDecision, action: str, prefixes: Sequence[str]) -> PolicyDecision:
    if action not in ACTIONS:
        raise ValueError("invalid action")
    selected = tuple(prefix for prefix in prefixes if within(prefix, getattr(decision, action + "_prefixes")))
    return replace(decision, **{action + "_prefixes": selected}, **({"scopes": selected} if action_for(decision.permission) == action else {}))


def action_for(permission: Permission) -> str:
    return "read" if permission in {Permission.READ, Permission.DISCOVER} else "write"


@dataclass(frozen=True, slots=True)
class ActorGrant:
    permissions: frozenset[Permission]
    scopes: tuple[str, ...] = ()
    resource_ids: tuple[str, ...] = ()
    audience: str = "member"
    read: tuple[str, ...] | None = None
    write: tuple[str, ...] | None = None
    append: tuple[str, ...] | None = None

    def decision_fields(self, allowed: bool) -> dict:
        return dict(
            audience=self.audience if allowed else "member", scope="read", holds_epoch="",
            read_prefixes=self.read if self.read is not None else (self.scopes if any(action_for(p) == "read" for p in self.permissions) else ()),
            write_prefixes=self.write if self.write is not None else (self.scopes if any(action_for(p) == "write" for p in self.permissions) else ()),
            append_prefixes=self.append if self.append is not None else (),
        )


@dataclass(slots=True)
class StaticPolicy(ActionAuthorizer):
    """Fail-closed policy driven by explicit actor grants.

    This is deliberately small. It proves that dogfood uses a real policy
    boundary while leaving room for a future ACL-backed policy adapter.
    """

    org_id: str
    policy_epoch: str
    grants: Mapping[str, ActorGrant] = field(default_factory=dict)

    def _base_reasons(self, actor: ActorContext) -> list[str]:
        reasons: list[str] = []
        if actor.profile.org_id != self.org_id:
            reasons.append("actor profile belongs to a different organization")
        if actor.membership is None:
            reasons.append("actor has no organization membership")
        elif actor.membership.org_id != self.org_id:
            reasons.append("membership belongs to a different organization")
        elif actor.membership.actor_id != actor.actor.actor_id:
            reasons.append("membership belongs to a different actor")
        elif actor.membership.status != "active":
            reasons.append("membership is not active")
        if (
            actor.actor.account_id is not None
            and (actor.account is None or actor.account.account_id != actor.actor.account_id)
        ):
            reasons.append("actor account does not match the resolved account")
        return reasons

    def authorize_observe(
        self, actor: ActorContext, request: RetrievalRequest
    ) -> PolicyDecision:
        reasons = self._base_reasons(actor)
        if request.org_id != self.org_id:
            reasons.append("retrieval request belongs to a different organization")
        if request.actor_id != actor.actor.actor_id:
            reasons.append("retrieval request actor does not match the active actor")
        grant = self.grants.get(actor.actor.actor_id)
        if grant is None:
            reasons.append("actor has no policy grant")
        elif not {Permission.DISCOVER, Permission.READ}.issubset(grant.permissions):
            reasons.append("actor lacks discover/read permission")

        return PolicyDecision(
            allowed=not reasons,
            actor_id=actor.actor.actor_id,
            org_id=self.org_id,
            permission=Permission.READ,
            policy_epoch=self.policy_epoch,
            resource_ids=grant.resource_ids if grant else (),
            scopes=grant.scopes if grant else (),
            reasons=tuple(reasons) if reasons else ("explicit actor grant",),
            **(grant or ActorGrant(frozenset())).decision_fields(not reasons),
        )

    def authorize_action(
        self,
        actor: ActorContext,
        permission: Permission,
        resource_ids: Sequence[str] = (),
    ) -> PolicyDecision:
        reasons = self._base_reasons(actor)
        grant = self.grants.get(actor.actor.actor_id)
        if grant is None:
            reasons.append("actor has no policy grant")
        elif permission not in grant.permissions:
            reasons.append(f"actor lacks {permission.value} permission")
        elif grant.resource_ids and any(
            resource_id not in grant.resource_ids for resource_id in resource_ids
        ):
            reasons.append("requested resource is outside the actor grant")

        return PolicyDecision(
            allowed=not reasons,
            actor_id=actor.actor.actor_id,
            org_id=self.org_id,
            permission=permission,
            policy_epoch=self.policy_epoch,
            resource_ids=tuple(resource_ids),
            scopes=grant.scopes if grant else (),
            reasons=tuple(reasons) if reasons else ("explicit actor grant",),
            **(grant or ActorGrant(frozenset())).decision_fields(not reasons),
        )


@dataclass(slots=True)
class _ConfiguredPolicy(ActionAuthorizer):
    inputs: AuthorizationInputs

    def _policy(self, actor: ActorContext) -> StaticPolicy:
        return StaticPolicy(actor.profile.org_id, self.inputs.policy, {
            actor.actor.actor_id: ActorGrant(frozenset(Permission), scopes=("memory",)),
        })

    def _finish(self, actor: ActorContext, decision: PolicyDecision) -> PolicyDecision:
        alias = actor.actor.aliases.get("github.username")
        handle = alias.strip().casefold() if isinstance(alias, str) else ""
        reasons = list(decision.reasons) if not decision.allowed else []
        if self.inputs.problem:
            reasons.append(self.inputs.problem)
        if handle and handle in self.inputs.removed:
            reasons.append("this person was removed from the organization")
        if self.inputs.policy not in {"all-access-v1", "roster-v1-shadow", "roster-v1"}:
            reasons.append(f"unknown access policy {self.inputs.policy}")
        return replace(decision, allowed=not reasons, reasons=tuple(reasons) or decision.reasons,
                       audience="admin" if not reasons and handle and handle in self.inputs.admins else "member",
                       holds_epoch=held.holds_epoch(self.inputs.admins, self.inputs.released),
                       released=self.inputs.released)

    def authorize_observe(self, actor: ActorContext, request: RetrievalRequest) -> PolicyDecision:
        return self._finish(actor, self._policy(actor).authorize_observe(actor, request))

    def authorize_action(self, actor: ActorContext, permission: Permission, resource_ids: Sequence[str] = ()) -> PolicyDecision:
        return self._finish(actor, self._policy(actor).authorize_action(actor, permission, resource_ids))

    def authorize_principal(self, handle: str, permission: Permission, resource_ids: Sequence[str] = ()) -> PolicyDecision:
        handle = handle.strip().casefold()
        row = principal(self.inputs, handle)
        reasons = [reason for reason in (self.inputs.problem, self.inputs.principals_problem) if reason]
        if row is None:
            reasons.append(f"no outside principal {handle}")
        elif row.problem:
            reasons.append(f"access.principals.{handle} is invalid: {row.problem}")
        if row and (row.handle in self.inputs.removed or row.identity in self.inputs.removed):
            reasons.append("this person was removed from the organization")
        action = action_for(permission)
        if permission not in {Permission.DISCOVER, Permission.READ, Permission.WRITE}:
            reasons.append(f"outside principals cannot {permission.value}")
        elif row and not (row.read if action == "read" else row.append):
            reasons.append(f"{handle} holds no {'read' if action == 'read' else 'append'} grant")
        if self.inputs.policy not in {"all-access-v1", "roster-v1-shadow", "roster-v1"}:
            reasons.append(f"unknown access policy {self.inputs.policy}")
        # A decision carries only the action it decided, so nothing it holds goes unchecked by as_principal.
        read = row.read if not reasons and row and action == "read" else ()
        append = row.append if not reasons and row and action != "read" else ()
        return PolicyDecision(
            allowed=not reasons, actor_id=f"principal:{handle}", org_id=self.inputs.org_id,
            permission=permission, policy_epoch=self.inputs.policy, resource_ids=tuple(resource_ids),
            reasons=tuple(reasons) or ("outside principal grant",), audience="outside", scope="hand-over",
            read_prefixes=read, append_prefixes=append, write_prefixes=(), scopes=read if action == "read" else (),
            holds_epoch=held.holds_epoch(self.inputs.admins, self.inputs.released),
            released=self.inputs.released, memory_revision=self.inputs.memory_revision,
        )


@dataclass(slots=True)
class _RootPolicy(_ConfiguredPolicy):
    """A Runtime over a projection root (``access materialize``) reads the generation the root admits and writes
    nothing. Whoever its copied settings or identity name, the decision is the same: audience ``root``, read
    ``memory`` (all of it is the grant, held material and held names already gone), and ``check`` refuses it while
    the root is dark."""

    def _decide(self, actor: ActorContext, permission: Permission, resource_ids: Sequence[str] = ()) -> PolicyDecision:
        from .projection import READ_ONLY
        reasons = [self.inputs.problem] if self.inputs.problem else []
        if permission not in {Permission.READ, Permission.DISCOVER}:
            reasons = [READ_ONLY]
        granted = () if reasons else ("memory",)
        return PolicyDecision(allowed=not reasons, actor_id=actor.actor.actor_id, org_id=actor.profile.org_id,
                              permission=permission, policy_epoch="all-access-v1", resource_ids=tuple(resource_ids),
                              scopes=granted, reasons=tuple(reasons) or ("read-only copy",), audience="root",
                              read_prefixes=granted)

    def authorize_observe(self, actor: ActorContext, request: RetrievalRequest) -> PolicyDecision:
        return self._decide(actor, Permission.READ)

    def authorize_action(self, actor: ActorContext, permission: Permission, resource_ids: Sequence[str] = ()) -> PolicyDecision:
        return self._decide(actor, permission, resource_ids)


def policy_for(inputs: AuthorizationInputs) -> ActionAuthorizer:
    """Build operator policy and authorize_principal decisions from authorization inputs."""
    return _RootPolicy(inputs) if inputs.source == PROJECTION_ROOT else _ConfiguredPolicy(inputs)


def committed_settings(root: Path, decision: PolicyDecision, *, read_budget=None) -> AuthorizationInputs | None:
    """The committed inputs an outside principal's decision (``as_principal``) was made from, read again for what a
    hand-over copies besides memory; None once they make another decision (the base moved in between)."""
    handle = decision.actor_id.removeprefix("principal:")
    inputs = authorization_inputs(root, handle, read_budget=read_budget)
    return inputs if policy_for(inputs).authorize_principal(handle, decision.permission) == decision else None


def as_principal(root: Path, actor: ActorContext, operator: PolicyDecision, handle: str,
                 permission: Permission, *, read_budget=None) -> PolicyDecision:
    """Act for an outside principal: its committed grant, refused unless the actor holds all of it.

    The one way a Runtime surface decides another principal. The principal's
    grant, policy, releases and memory come only from the committed base; the
    acting operator stays an operator: ``operator`` is their own working-tree
    decision, and they must also be eligible on the committed base (a removal
    undone only in the working tree acts for no one). Every prefix the result
    holds must sit inside the operator's for that action.
    """
    handle = handle.strip().casefold()
    policy = policy_for(authorization_inputs(root, handle, read_budget=read_budget))
    decision = policy.authorize_principal(handle, permission)
    if not decision.allowed:
        return decision
    reasons = [] if operator.allowed and policy.authorize_action(actor, permission).allowed else [
        "whoever acts for them holds no grant"]
    if operator.org_id != decision.org_id:
        reasons.append("the shared settings name another organization")
    for action, holding in (("read", operator.read_prefixes), ("append", operator.append_prefixes + operator.write_prefixes)):
        reasons += [f"acting for {handle} would widen {action} to {prefix}"
                    for prefix in getattr(decision, action + "_prefixes") if not within(prefix, holding)]
    if not reasons:
        return decision
    return replace(decision, allowed=False, reasons=tuple(reasons),
                   read_prefixes=(), append_prefixes=(), write_prefixes=(), scopes=())
