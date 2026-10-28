"""Journaled transfer of current Local ownership before Connected identity adoption.

Historical attribution is separate. Only pending question recipients and current
thread stewards change here, with fresh provider/membership proof and canonical
Runtime writeback. The caller holds the instance identity lock until it persists
the destination identity. This module never resolves or changes that identity.
"""
from __future__ import annotations

from dataclasses import replace
import hashlib
import json
import os
import re
from pathlib import Path, PurePosixPath
import tempfile
from typing import Any, Mapping

from .artifacts import parse_canonical_markdown, render_canonical_markdown, split_frontmatter
from .contracts import ActorContext, Permission
from .policy import scope_allows_path
from .runtime import local_runtime

SCHEMA = "egregore-identity-transfer/v1"
MAX_SCAN_FILES = 5_000
MAX_DOCUMENT_BYTES = 2_000_000
MAX_SCAN_BYTES = 32_000_000
MAX_JOURNAL_BYTES = 64_000_000


class IdentityTransferError(ValueError):
    """Ownership could not safely advance; the previous identity must remain."""


def _hash(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def journal_path(root: Path) -> Path:
    # Older installations do not ignore .egregore/runtime/ inside the project.
    # Keep source preimages outside every checkout, keyed to the resolved user
    # state so the same journal is found from that user's linked worktrees.
    state = (Path(root).resolve() / ".egregore-state.json").resolve()
    key = _hash(str(state).encode("utf-8"))
    return Path.home() / ".egregore" / "runtime" / "identity-transfers" / f"{key}.json"


def _save(path: Path, value: Mapping[str, Any]) -> None:
    if path.is_symlink():
        raise IdentityTransferError("identity transfer journal must not be a symlink")
    encoded = json.dumps(value, sort_keys=True, indent=2, ensure_ascii=False) + "\n"
    if len(encoded.encode("utf-8")) > MAX_JOURNAL_BYTES:
        raise IdentityTransferError("identity transfer journal exceeds its byte limit")
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(encoded)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
        parent = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def _target(memory: Path, relative: str) -> Path:
    parts = PurePosixPath(relative).parts
    if not (len(parts) == 3 and parts[:2] == ("knowledge", "questions")
            or len(parts) == 2 and parts[0] == "threads"):
        raise IdentityTransferError("identity transfer contains an unsupported canonical path")
    if any(part in {"", ".", ".."} for part in parts) or not relative.endswith(".md"):
        raise IdentityTransferError("identity transfer contains an invalid canonical path")
    target = memory
    for part in parts:
        target = target / part
        if target.is_symlink():
            raise IdentityTransferError("ownership transfer refuses canonical symlinks")
    return target


def _changed_fields(fields: Mapping[str, Any], source_id: str, destination_id: str) -> dict[str, Any]:
    kind = fields.get("type") or fields.get("artifact_type")
    if kind == "question" and fields.get("status") == "pending" and fields.get("to_actor_id") == source_id:
        return {"to_actor_id": destination_id}
    if kind != "thread" or fields.get("status") not in {"active", "paused"}:
        return {}
    steward = fields.get("steward_id")
    stewards = fields.get("steward_ids")
    if stewards is not None and (not isinstance(stewards, list) or not all(isinstance(item, str) for item in stewards)):
        raise IdentityTransferError("thread steward_ids must be a list of stable identifiers")
    updates: dict[str, Any] = {}
    if steward == source_id:
        updates["steward_id"] = destination_id
    if isinstance(stewards, list) and source_id in stewards:
        updates["steward_ids"] = list(dict.fromkeys(destination_id if item == source_id else item for item in stewards))
    return updates


def _malformed_transfer_candidate(markdown: str, source_id: str) -> bool:
    """Identify an invalid document that could still require ownership transfer.

    Existing memory can contain old or adversarial Markdown that is not a valid
    Runtime artifact. Identity reconciliation must not fail because an unrelated
    document is malformed, but it must fail closed when that document explicitly
    names the current actor as a transferable owner.
    """

    if not source_id:
        return False
    actor = re.escape(source_id)
    question = re.search(r"(?m)^type:\s*[\"']?question[\"']?\s*$", markdown)
    recipient = re.search(rf"(?m)^to_actor_id:\s*[\"']?{actor}[\"']?\s*$", markdown)
    thread = re.search(r"(?m)^type:\s*[\"']?thread[\"']?\s*$", markdown)
    steward = re.search(rf"(?m)^steward_id:\s*[\"']?{actor}[\"']?\s*$", markdown)
    stewards = re.search(rf"(?m)^steward_ids:\s*.*\b{actor}\b", markdown)
    return bool((question and recipient) or (thread and (steward or stewards)))


def _document(before: str, path: str, pair: Mapping[str, Any], transfer_id: str):
    fields, _ = split_frontmatter(before)
    updates = _changed_fields(fields, pair["source"]["actor_id"], pair["destination"]["actor_id"])
    if not updates:
        raise IdentityTransferError("journal source no longer declares transferable ownership")
    document = parse_canonical_markdown(before, canonical_path=path)
    if document.artifact.org_id != pair["source"]["org_id"]:
        raise IdentityTransferError("ownership source belongs to another organization")
    # Do not rewrite a legacy/multiline envelope whose unsupported fields could
    # disappear during canonical rendering. Normal Runtime-created files match.
    if document.migrated_from is not None or render_canonical_markdown(document) != before:
        raise IdentityTransferError("ownership source requires canonical normalization before connecting")
    history = document.legacy_fields.get("ownership_transfers", [])
    if not isinstance(history, list):
        raise IdentityTransferError("ownership transfer history must be a list")
    history = [*history, {"transfer_id": transfer_id, "from_actor_id": pair["source"]["actor_id"],
                         "to_actor_id": pair["destination"]["actor_id"], "source_revision": document.artifact.revision}]
    return replace(document, artifact=replace(document.artifact, revision=f"{document.artifact.revision}-identity-{transfer_id[:12]}"),
                   legacy_fields={**document.legacy_fields, **updates, "ownership_transfers": history})


def _authorize(runtime, source: ActorContext, path: str, permission: Permission) -> None:
    decision = runtime.authorize(source, permission, (f"memory/{path}",))
    if not decision.allowed or not scope_allows_path(f"memory/{path}", decision.scopes):
        raise IdentityTransferError("current actor cannot authorize ownership transfer for the canonical path")


def _inventory(memory: Path, runtime, source: ActorContext, destination_id: str):
    planned = []
    count = size = 0
    for directory in ("knowledge/questions", "threads"):
        folder = memory / directory
        if folder.is_symlink() or folder.parent.is_symlink():
            raise IdentityTransferError("ownership transfer refuses canonical directory symlinks")
        for path in folder.glob("*.md"):
            count += 1
            if count > MAX_SCAN_FILES:
                raise IdentityTransferError("ownership inventory exceeds its file limit; retain the current identity")
            relative = path.relative_to(memory).as_posix()
            path = _target(memory, relative)
            _authorize(runtime, source, relative, Permission.READ)
            with path.open("rb") as handle:
                raw = handle.read(MAX_DOCUMENT_BYTES + 1)
            size += len(raw)
            if len(raw) > MAX_DOCUMENT_BYTES or size > MAX_SCAN_BYTES:
                raise IdentityTransferError("ownership inventory exceeds its byte limit; retain the current identity")
            before = raw.decode("utf-8")
            try:
                fields, _ = split_frontmatter(before)
            except ValueError as error:
                # A malformed legacy or test document outside the transfer
                # contract must not block identity reconciliation. If it names
                # the current owner, fail closed so ownership is never left
                # half-transferred.
                if _malformed_transfer_candidate(before, source.actor.actor_id):
                    raise IdentityTransferError(
                        f"ownership inventory cannot parse {relative}: {error}"
                    ) from error
                continue
            if (fields.get("org") or fields.get("org_id")) not in {None, source.profile.org_id}:
                continue
            if _changed_fields(fields, source.actor.actor_id, destination_id):
                planned.append((relative, before))
    return sorted(planned)


class _RevisionStore:
    def __init__(self, store, path: str, expected: str):
        self.store, self.path, self.expected = store, path, expected

    def check_write(self, document):
        if document.artifact.canonical_path != self.path:
            raise IdentityTransferError("ownership transfer attempted an unplanned write")
        return self.store.check_write(document)

    def persist(self, document):
        self.check_write(document)
        return self.store.persist_if_unchanged(document, self.expected)


def transfer_local_ownership(
    root: Path, *, source: ActorContext, destination: Mapping[str, str],
    verified_subject: str, destination_active: bool, runtime=None,
) -> dict[str, Any]:
    """Complete a same-pair ownership transfer, or raise before identity adoption.

    ``verified_subject`` is freshly attested by the control plane; it must not
    come from an alias or a saved reconciliation history. Missing proof is
    tolerated only when neither relevant ownership nor a prior journal exists.
    Runtime injection supports isolated canonical-only acceptance; production
    retains its real policy, store, local Git and retrieval adapters.
    """
    root = Path(root).resolve()
    memory = (root / "memory").resolve()
    journal_file = journal_path(root)
    if journal_file.is_symlink():
        raise IdentityTransferError("identity transfer journal must not be a symlink")
    if runtime is None:
        runtime = local_runtime(root, push_remote=False)
    if Path(runtime.canonical_root).resolve() != memory:
        raise IdentityTransferError("ownership Runtime belongs to another canonical root")
    source_ids = {"org_id": source.profile.org_id, "actor_id": source.actor.actor_id,
                  "account_id": source.account.account_id if source.account else "",
                  "membership_id": source.membership.membership_id if source.membership else ""}
    target_ids = {key: destination.get(key, "") for key in source_ids}
    if not all(isinstance(value, str) and value for value in target_ids.values()):
        raise IdentityTransferError("destination identity is incomplete")

    prior = None
    if journal_file.exists():
        try:
            if journal_file.stat().st_size > MAX_JOURNAL_BYTES:
                raise IdentityTransferError("identity transfer journal exceeds its byte limit")
            prior = json.loads(journal_file.read_text(encoding="utf-8"))
        except (OSError, ValueError) as error:
            raise IdentityTransferError("identity transfer journal is unreadable; retain the current identity") from error
        if not isinstance(prior, dict) or prior.get("schema_version") != SCHEMA:
            raise IdentityTransferError("identity transfer journal schema is invalid")
    planned = []
    if prior is None:
        planned = _inventory(memory, runtime, source, target_ids["actor_id"])
        if not planned:
            return {"status": "not-needed", "transferred": 0}

    if (source.membership is None or source.membership.status != "active"
        or source.membership.org_id != source.profile.org_id or source.membership.actor_id != source.actor.actor_id
        or source.account is None or source.actor.account_id != source.account.account_id
        or source.profile.org_id != target_ids["org_id"] or not destination_active
        or not isinstance(verified_subject, str) or not verified_subject.isascii() or not verified_subject.isdigit()
        or source.account.provider_aliases.get("github") != verified_subject):
        raise IdentityTransferError("ownership transfer requires matching verified provider identity and active memberships; refresh Connected identity and retry")
    pair = {"source": source_ids, "destination": target_ids, "verified_subject": verified_subject,
            "memory_root": str(memory)}
    transfer_id = _hash(json.dumps(pair, sort_keys=True, separators=(",", ":")).encode())
    if prior is not None:
        if prior.get("pair") != pair or prior.get("transfer_id") != transfer_id:
            raise IdentityTransferError("identity transfer journal belongs to another identity pair; retain the current identity")
        journal = prior
    else:
        entries = []
        for relative, before in planned:
            _authorize(runtime, source, relative, Permission.WRITE)
            document = _document(before, relative, pair, transfer_id)
            after = render_canonical_markdown(document)
            entries.append({"path": relative, "before": before, "before_sha256": _hash(before.encode()),
                            "after_sha256": _hash(after.encode()), "git_revision": None})
        journal = {"schema_version": SCHEMA, "transfer_id": transfer_id, "pair": pair,
                   "status": "pending", "entries": entries}
        _save(journal_file, journal)
    entries = journal.get("entries")
    if not isinstance(entries, list) or not entries or len(entries) > MAX_SCAN_FILES:
        raise IdentityTransferError("identity transfer journal has no valid entries")
    documents = []
    paths = set()
    # Revalidate the complete set before resuming even one write.
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("before"), str) or not isinstance(entry.get("path"), str):
            raise IdentityTransferError("identity transfer journal entry is invalid")
        path = _target(memory, entry["path"])
        if entry["path"] in paths:
            raise IdentityTransferError("identity transfer journal repeats a canonical path")
        paths.add(entry["path"])
        _authorize(runtime, source, entry["path"], Permission.READ)
        _authorize(runtime, source, entry["path"], Permission.WRITE)
        document = _document(entry["before"], entry["path"], pair, transfer_id)
        after_hash = _hash(render_canonical_markdown(document).encode())
        if entry.get("before_sha256") != _hash(entry["before"].encode()) or entry.get("after_sha256") != after_hash:
            raise IdentityTransferError("identity transfer journal source digest is inconsistent")
        current = _hash(path.read_bytes())
        if current not in {entry["before_sha256"], after_hash}:
            raise IdentityTransferError("canonical ownership changed during transfer; retain the current identity and reconcile the edit")
        if entry.get("git_revision") and current != after_hash:
            raise IdentityTransferError("a completed ownership transfer path changed before identity adoption")
        documents.append((entry, document, current))
    for entry, document, current in documents:
        if entry.get("git_revision"):
            continue
        guarded = replace(runtime, store=_RevisionStore(runtime.store, entry["path"], current))
        receipt = guarded.write_document(source, document)
        if not receipt.git_revision or receipt.status.value == "rejected":
            raise IdentityTransferError("ownership transfer lacks canonical Git provenance; retain the current identity and retry")
        if _hash(_target(memory, entry["path"]).read_bytes()) != entry["after_sha256"]:
            raise IdentityTransferError("canonical ownership changed during writeback; retain the current identity")
        entry["git_revision"] = receipt.git_revision
        _save(journal_file, journal)
    # Re-check skipped/completed entries too: a later item may have yielded to
    # another writer. Never adopt the new identity over an incomplete set.
    for entry in entries:
        if _hash(_target(memory, entry["path"]).read_bytes()) != entry["after_sha256"]:
            raise IdentityTransferError("canonical ownership changed before identity adoption; retain the current identity")
    if _inventory(memory, runtime, source, target_ids["actor_id"]):
        raise IdentityTransferError("new ownership appeared during transfer; retain the current identity and reconcile the new work")
    journal["status"] = "complete"
    _save(journal_file, journal)
    return {"status": "complete", "transferred": len(entries), "transfer_id": transfer_id,
            "journal_path": str(journal_file)}
