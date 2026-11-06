"""One managed memory push, freshly inspected at dispatch.

Ordinary callers cannot publish native history. The optional private record
owner can supply its typed, single-use in-process permit. This transport never
fetches, rebases, changes Git configuration, retries a push or writes a queue.
Manual Git remains outside this boundary. Existing Git configuration owns auth.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass, replace
import hashlib
import json
import math
import os
from pathlib import Path
import re
import subprocess
import time
from urllib.parse import urlsplit

from . import record_publish as history


@dataclass(frozen=True)
class PushLimits:
    seconds: float = 90
    command_seconds: float = 15
    push_seconds: float = 45
    output_bytes: int = 65536
    history: history.HistoryLimits = history.DEFAULT_LIMITS


DEFAULT_LIMITS = PushLimits()
EXIT_CODES = {"pushed": 0, "deferred": 2, "rejected": 3, "unknown": 4}


class _Refusal(Exception):
    def __init__(self, cause, *, status="rejected"):
        self.cause, self.status = cause, status


class _Transport(history._Git):
    def __init__(self, root, deadline, limits, allow_local):
        super().__init__(root, deadline)
        # Transport uses normal system/global/local credential configuration.
        # Repository/config/ref redirection from caller environment is removed.
        self.env.pop("GIT_CONFIG_NOSYSTEM", None)
        self.env.pop("GIT_CONFIG_GLOBAL", None)
        for key in ("GIT_ASKPASS", "GIT_SSL_CAINFO", "GIT_SSL_CAPATH"):
            if key in os.environ:
                self.env[key] = os.environ[key]
        self.limits, self.allow_local = limits, allow_local

    def start(self, args, *, stdin=False):
        return super().start(["-c", "protocol.https.allow=always", "-c",
            "protocol.file.allow=" + ("always" if self.allow_local else "never"),
            "-c", "http.followRedirects=false", "-c", "push.followTags=false",
            "-c", "push.recurseSubmodules=no", "-c", "push.gpgSign=false",
            "-c", "push.autoSetupRemote=false", *args], stdin=stdin)

    def command(self, *args, seconds=None):
        outer = self.deadline
        self.deadline = min(outer, time.monotonic() + (seconds or self.limits.command_seconds))
        try:
            return self.run(*args, limit=self.limits.output_bytes, allowed=tuple(range(256)))
        finally:
            self.deadline = outer


def _branch(value):
    if not isinstance(value, str):
        raise _Refusal("invalid_destination_branch")
    ref = value if value.startswith("refs/") else "refs/heads/" + value
    if not ref.startswith("refs/heads/") or not history._ref(ref):
        raise _Refusal("invalid_destination_branch")
    return ref


def _safe_ref(git_dir, ref):
    seen = set()
    while True:
        if ref in seen or len(seen) >= 8:
            raise _Refusal("ambiguous_source_ref")
        seen.add(ref)
        if ref != "HEAD" and (not history._ref(ref) or not ref.startswith("refs/heads/")):
            raise _Refusal("invalid_source_ref")
        selected = git_dir
        for part in ref.split("/"):
            selected /= part
            if selected.is_symlink():
                raise _Refusal("unsupported_repository")
        if (git_dir / "packed-refs").is_symlink():
            raise _Refusal("unsupported_repository")
        if not selected.exists():
            return
        raw = history._regular(selected, 1024).strip()
        if not raw.startswith(b"ref: "):
            return
        ref = raw[5:].decode("ascii")


def _url(value, allow_local):
    if not value or len(value) > 4096 or any(ord(char) <= 32 or ord(char) == 127 for char in value):
        raise _Refusal("unsupported_destination")
    parsed = urlsplit(value)
    if (parsed.scheme == "https" and parsed.hostname and parsed.username is None and parsed.password is None
            and not parsed.query and not parsed.fragment and parsed.path.startswith("/")
            and not re.search(r"[^A-Za-z0-9.:-]", parsed.netloc)):
        return value
    if allow_local and not parsed.scheme and value.startswith("/"):
        path = Path(value)
        if path == path.resolve() and path.is_dir():
            return value
    raise _Refusal("unsupported_destination")


def _snapshot(transport, repository, head_ref, branch_ref):
    root, git_dir = history._repository(repository, transport.deadline)
    _safe_ref(git_dir, head_ref)
    config, code = transport.command("config", "--null", "--list", "--includes")
    if code:
        raise _Refusal("configuration_unavailable", status="deferred")
    values = {}
    for entry in config.split(b"\0"):
        if not entry:
            continue
        key, sep, value = entry.partition(b"\n")
        if not sep:
            # A valueless Boolean key is true in Git's own configuration.
            value = b"true"
        name = key.decode("utf-8").lower()
        values.setdefault(name, []).append(value.decode("utf-8"))
    if any(re.fullmatch(r"url\..*\.(?:push)?insteadof", key) for key in values):
        raise _Refusal("destination_rewrite_unsupported")
    if (len(values.get("remote.origin.url", [])) != 1 or len(values.get("remote.origin.pushurl", [])) > 1
            or any(values.get(key) for key in ("remote.origin.push", "remote.origin.pushoption", "push.pushoption",
                                              "remote.origin.receivepack", "remote.origin.uploadpack", "remote.origin.vcs"))
            or any(value.lower() not in {"false", "no", "off", "0"} for value in values.get("remote.origin.mirror", []))):
        raise _Refusal("ambiguous_destination")
    selected = values.get("remote.origin.pushurl", values["remote.origin.url"])[0]
    selected = _url(selected, transport.allow_local)
    resolved, code = transport.command("remote", "get-url", "--push", "--all", "origin")
    if code or resolved.decode("utf-8").splitlines() != [selected]:
        raise _Refusal("ambiguous_destination")
    raw_head, code = transport.command("rev-parse", "--verify", head_ref)
    head = raw_head.strip().decode("ascii")
    if code or not history.OID.fullmatch(head):
        raise _Refusal("source_unavailable", status="deferred")
    info, git_info = root.stat(), git_dir.stat()
    return {"url": selected, "head_oid": head, "head_ref": head_ref, "branch_ref": branch_ref,
            "repository_identity": [info.st_dev, info.st_ino, git_info.st_dev, git_info.st_ino],
            "repository_fingerprint": history._digest({"repository": str(root), "git_dir": str(git_dir)}),
            "configuration_digest": hashlib.sha256(config).hexdigest(),
            "destination_fingerprint": history._digest({"url": selected, "ref": branch_ref})}


def _remote(transport, selection):
    raw, code = transport.command("ls-remote", "--refs", "--heads", "--", selection["url"], selection["branch_ref"])
    if code:
        raise _Refusal("remote_evidence_unavailable", status="deferred")
    lines = raw.decode("ascii").splitlines()
    if not lines:
        return None
    if len(lines) != 1:
        raise _Refusal("ambiguous_remote_evidence", status="deferred")
    oid, sep, ref = lines[0].partition("\t")
    if not sep or ref != selection["branch_ref"] or not history.OID.fullmatch(oid) or len(oid) != len(selection["head_oid"]):
        raise _Refusal("ambiguous_remote_evidence", status="deferred")
    return oid


def _same(expected, current):
    if expected != current:
        raise _Refusal("source_or_destination_changed", status="deferred")


def inspect_destination(repository, *, branch, head_ref="HEAD", limits=DEFAULT_LIMITS,
                        allow_local_transport=False, deadline_monotonic=None):
    """Fresh read-only host selection. This fact carries no publication grant.

    The native record owner uses the same bounded destination resolver before
    committing and while reconciling an uncertain exact commit. No fetch,
    reconciliation mutation or push occurs here.
    """
    _validate_arguments(limits, allow_local_transport, head_ref)
    branch_ref = _branch(branch)
    deadline = _deadline(limits, deadline_monotonic)
    root, _ = history._repository(repository, deadline)
    transport = _Transport(root, deadline, limits, allow_local_transport)
    selection = _snapshot(transport, root, head_ref, branch_ref)
    base = _remote(transport, selection)
    _same(selection, _snapshot(transport, root, head_ref, branch_ref))
    return selection, base


def _deadline(limits, inherited):
    if inherited is not None and (type(inherited) not in (float, int) or not math.isfinite(inherited)):
        raise ValueError("invalid inherited deadline")
    value = time.monotonic() + limits.seconds
    if inherited is not None:
        value = min(value, inherited)
    if value <= time.monotonic():
        raise ValueError("publication deadline expired")
    return value


def _validate_arguments(limits, allow_local_transport, head_ref):
    if (not isinstance(limits, PushLimits) or type(allow_local_transport) is not bool
            or any(type(getattr(limits, key)) not in (int, float) or not 0 < getattr(limits, key) <= getattr(DEFAULT_LIMITS, key)
                   for key in ("seconds", "command_seconds", "push_seconds"))
            or type(limits.output_bytes) is not int or not 1 <= limits.output_bytes <= DEFAULT_LIMITS.output_bytes
            or not isinstance(limits.history, history.HistoryLimits)):
        raise _Refusal("invalid_limits")
    if not isinstance(head_ref, str) or not (head_ref == "HEAD" or head_ref.startswith("refs/heads/") and history._ref(head_ref)):
        raise _Refusal("invalid_source_ref")


def _empty_receipt():
    return {"schema": "egregore.managed-memory-push/v1", "status": "deferred", "cause": "not_started",
               "source_oid": None, "source_ref": None, "base_oid": None, "destination_ref": None,
               "repository_fingerprint": None, "destination_fingerprint": None, "configuration_digest": None,
               "history_digest": None, "history_status": None, "dispatch_attempted": False,
               "reconciled": False, "retry_safe": False, "observed_remote_oid": None, "native_publication_authority": False}


def push_memory(repository, *, branch, head_ref="HEAD", limits=DEFAULT_LIMITS, allow_local_transport=False,
                native_permit=None, deadline_monotonic=None):
    """Inspect and perform at most one exact managed push; no reusable permit.

    HTTPS is the production transport. The explicit local-transport host option
    retains every history/CAS guard and exists for disposable local receivers.
    Config/source checks detect ordinary concurrent changes, not hostile local
    filesystem mutation after the final check. An explicit remote lease closes
    the destination-ref race; it is used only after proving fast-forward ancestry.
    """
    receipt = _empty_receipt()
    selection, transport = None, None
    try:
        _validate_arguments(limits, allow_local_transport, head_ref)
        branch_ref = _branch(branch)
        if native_permit is not None:
            # The fixed native owner is private. Human-only public bundles do
            # not carry it and must retain the same denied-native boundary.
            try:
                from .record_admission import NativePublicationPermit
                valid_permit = type(native_permit) is NativePublicationPermit
            except ImportError:
                valid_permit = False
            if not valid_permit:
                raise _Refusal("invalid_native_publication_permit")
        deadline = _deadline(limits, deadline_monotonic)
        root, _ = history._repository(repository, deadline)
        transport = _Transport(root, deadline, limits, allow_local_transport)
        selection = _snapshot(transport, root, head_ref, branch_ref)
        receipt.update(source_oid=selection["head_oid"], source_ref=head_ref, destination_ref=branch_ref,
                       **{key: selection[key] for key in ("repository_fingerprint", "destination_fingerprint", "configuration_digest")})
        base = _remote(transport, selection)
        receipt.update(base_oid=base, observed_remote_oid=base)
        if base is not None:
            local = history._Git(root, deadline)
            kind, code = local.run("cat-file", "-t", base, limit=32, allowed=(0, 128))
            if code == 128:
                raise _Refusal("remote_base_unavailable_locally", status="deferred")
            if kind.strip() != b"commit":
                raise _Refusal("remote_base_not_commit", status="deferred")
        inspection = history.inspect_outgoing_history(root, base_oid=base, base_ref=None,
                    head_oid=selection["head_oid"], head_ref=head_ref,
                    limits=replace(limits.history, seconds=min(limits.history.seconds, transport.remaining())))
        receipt.update(history_digest=inspection["digest"], history_status=inspection["status"])
        if inspection["status"] == "present" and native_permit is None:
            raise _Refusal("native_history_requires_admission")
        if inspection["status"] not in {"none", "present"} or not inspection["complete"]:
            raise _Refusal("outgoing_history_unavailable", status="deferred")
        _same(selection, _snapshot(transport, root, head_ref, branch_ref))
        if _remote(transport, selection) != base:
            raise _Refusal("remote_changed", status="deferred")
        # A further source/config check follows the potentially slow remote read.
        _same(selection, _snapshot(transport, root, head_ref, branch_ref))
        if native_permit is not None:
            try:
                native_permit._admit_dispatch(selection, base, inspection)
            except (ValueError, TypeError, AttributeError, OSError, RuntimeError):
                raise _Refusal("native_publication_admission_changed")
            # The fixed owner rechecks source and permissions, potentially over
            # an inherited pipe. Bind HEAD/config once more after that return.
            _same(selection, _snapshot(transport, root, head_ref, branch_ref))
            receipt["native_publication_authority"] = True
        if base == selection["head_oid"]:
            receipt.update(status="pushed", cause="already_current", reconciled=True)
        else:
            receipt["dispatch_attempted"] = True
            push_code = None
            try:
                _, push_code = transport.command("push", "--porcelain", "--no-verify", "--no-follow-tags",
                    "--recurse-submodules=no", "--force-with-lease=" + branch_ref + ":" + (base or ""),
                    "--", selection["url"], selection["head_oid"] + ":" + branch_ref, seconds=limits.push_seconds)
            except (history._Unknown, OSError, ValueError, subprocess.SubprocessError):
                pass  # The only follow-up is a read; never another push.
            try:
                _same(selection, _snapshot(transport, root, head_ref, branch_ref))
                observed = _remote(transport, selection)
                receipt["observed_remote_oid"] = observed
                if observed == selection["head_oid"]:
                    receipt.update(status="pushed", cause="acknowledged" if push_code == 0 else "acknowledgement_reconciled", reconciled=True)
                else:
                    receipt.update(status="unknown", cause="remote_changed_after_dispatch" if observed != base else "push_acknowledgement_unknown")
            except (history._Unknown, _Refusal, OSError, ValueError, UnicodeError, subprocess.SubprocessError):
                receipt.update(status="unknown", cause="push_acknowledgement_unknown")
    except _Refusal as exc:
        receipt.update(status="unknown" if receipt["dispatch_attempted"] else exc.status,
                       cause="push_acknowledgement_unknown" if receipt["dispatch_attempted"] else exc.cause,
                       retry_safe=not receipt["dispatch_attempted"] and exc.cause in {
                           "source_or_destination_changed", "remote_changed", "remote_base_unavailable_locally"})
    except (history._Unknown, OSError, ValueError, TypeError, UnicodeError, RecursionError, subprocess.SubprocessError):
        receipt.update(status="unknown" if receipt["dispatch_attempted"] else "deferred",
                       cause="push_acknowledgement_unknown" if receipt["dispatch_attempted"] else "bounded_evidence_unavailable")
    return {**receipt, "digest": history._digest(receipt)}


def main(argv=None):
    parser = argparse.ArgumentParser(description="Guard one exact managed memory push; native history remains local.")
    parser.add_argument("--repository", required=True)
    parser.add_argument("--branch", required=True)
    parser.add_argument("--head-ref", default="HEAD")
    parser.add_argument("--allow-local-transport", action="store_true", help="explicit local bare fixture transport; all guards remain enabled")
    args = parser.parse_args(argv)
    deadline = time.monotonic() + DEFAULT_LIMITS.seconds
    try:
        # The host selects the memory repository, normally project/memory -> a
        # sibling checkout. Bind that alias once here; the strict history and
        # transport owners receive only its physical path and never reread it.
        repository = Path(args.repository)
        if not repository.is_absolute() or any(ord(c) < 32 or ord(c) == 127 for c in args.repository):
            raise ValueError("invalid repository selection")
        repository = repository.resolve(strict=True)
    except (OSError, ValueError, RuntimeError, UnicodeError):
        receipt = _empty_receipt()
        receipt["cause"] = "bounded_evidence_unavailable"
        receipt["digest"] = history._digest(receipt)
    else:
        receipt = push_memory(repository, branch=args.branch, head_ref=args.head_ref,
                              allow_local_transport=args.allow_local_transport, deadline_monotonic=deadline)
    print(json.dumps(receipt, sort_keys=True, separators=(",", ":")))
    return 75 if receipt["retry_safe"] else EXIT_CODES[receipt["status"]]


if __name__ == "__main__":
    raise SystemExit(main())
