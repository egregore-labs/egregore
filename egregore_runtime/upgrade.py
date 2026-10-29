"""Transactional Runtime upgrade engine — staged, durable, per instance.

The engine prepares a candidate Runtime for exactly one registered Egregore
instance while the currently active Runtime keeps serving. Preparation is a
sequence of durable stages; every transition is an atomic write to an
instance-scoped state file, so an interrupted worker resumes completed work
instead of restarting it. Activation is a separate, explicit, atomic step
that only succeeds when every gate passes — BM25 alone never activates.

All state lives under the instance's own runtime root, keyed by the same
stable instance hash the QMD adapter uses. Nothing here reads or writes
another instance's files, processes, indexes, or configuration.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Mapping

from .adapters.qmd import QMD_VERSION, RERANKING_ENABLED, QmdLocalRetriever

SCHEMA_VERSION = "egregore-runtime-upgrade/v1"

# Stage keys in preparation order. Labels are the user-facing truth shown by
# Settings; keep them in plain team language.
STAGES: tuple[tuple[str, str], ...] = (
    ("sync", "Team memory synchronized"),
    ("candidate", "Runtime candidate recorded"),
    ("install", "Runtime candidate installed"),
    ("node", "Node runtime ready"),
    ("qmd", "QMD installed"),
    ("bm25", "Keyword index built"),
    ("embed", "Meaning index generated"),
    ("delta", "Late team changes embedded"),
    ("verify", "Retrieval, identity, and boundary verified"),
)

# The harness bundle applied to the instance at activation. All four bundles
# must be present in the candidate package; the Claude bundle carries the
# shared core (bin/, egregore_runtime/, .claude/) this instance runs on.
BUNDLE_TREES = ("claude", "codex", "pi", "prime")
# Activation applies every harness adapter tree, not only Claude's: the
# Codex black-box found a live instance whose .codex adapters were still the
# pre-cutover generation, sending Codex sessions through a broken global QMD
# and graph-era instructions while Claude ran the new Runtime. Shared paths
# (bin/, egregore_runtime/) are byte-identical across trees; the first tree
# wins and duplicates are skipped.
APPLY_TREES = ("claude", "codex", "pi", "prime")
APPLY_TREE = APPLY_TREES[0]
# Bundle metadata at the root of each adapter tree; never instance content.
BUNDLE_MANIFEST = "manifest.json"
# The harness settings adapter the bundle generates; an instance's richer
# committed copy is preserved on activation.
SETTINGS_ADAPTER = ".claude/settings.json"
CODEX_SETTINGS_ADAPTER = ".codex/config.toml"
NATIVE_SETTINGS_ADAPTERS = (".pi/settings.json", ".prime/agent/settings.json")
CODEX_HOOKS_ADAPTER = ".codex/hooks.json"
CODEX_PROMPT_BRIDGE = ".codex/hooks/search-hint.js"
CLAUDE_PROMPT_BRIDGE = ".claude/hooks/search-hint.sh"
_CLAUDE_LEGACY_PROMPT_COMMAND = '"$CLAUDE_PROJECT_DIR"/.claude/hooks/search-hint.sh'
_CLAUDE_HINT_SHA256 = "2d5cd92097040aadabeeeda21cf1ab3e107938e9fbf0f1520edfd367e76ce7a8"
_CLAUDE_BRIDGE_SHA256 = "80da9077e898022e50a1045d407e0bf9e65db17aee866d17c1b4c50bd0bfae1d"
_CODEX_LEGACY_PROMPT_COMMAND = 'node "$(git rev-parse --show-toplevel)/.codex/hooks/search-hint.js"'
_CODEX_PROMPT_COMMAND = 'bash "$(git rev-parse --show-toplevel)/bin/observe-context.sh" codex'
# Reviewed public hint-only adapter (Git blob 177aa8e1f1ac85147a5ee61da86110dfe6579a9f).
# Names alone never authorize replacing a user-authored hook.
_CODEX_HINT_SHA256 = "67b05ed43d040aab53dc1e2ec3426f6a90256d45622db3b02bba89a65abef83d"
_CODEX_BRIDGE_SHA256 = "1c45dc461f7f7f4249121efb43bbe933efd722085a2f1d9d6874f57889e68b3d"
_OBSERVE_ADAPTER_SHA256 = "812ffe0707e2c63af6a05f78a170b4b09ecb84920d851ae4279bc8a8c5610f75"
# The .28 installer core at 6df97b58 has the native prompt binding API.
_NATIVE_BINDING_CLI_SHA256 = "0d4f5b1fd66f63bacee0f8724be4a717607a4bbb34af0cda26d3f8fb88866157"
_NATIVE_BINDING_MODULE_SHA256 = "e3d1a387d6d26f0181c25b051dcff17f9eb929e6ad6b04b44119120a5058904d"
ROLLBACK_OWNERSHIP_SCHEMA = "egregore-rollback-ownership/v1"
LEGACY_BASELINE_SCHEMA = "egregore-legacy-baseline/v1"
_LEGACY_TEMPLATE_FILES = ("egregore.json", "CLAUDE.md", "bin/session-start.sh")
_RUNTIME_CORE_FILES = ("egregore_runtime/runtime.py", "egregore_runtime/harness_cli.py")


def _runtime_install_receipt_paths(repository_root: Path):
    """Only receipts belonging to this checkout and its shared Git directory."""
    root = repository_root.resolve()
    directories = [root / ".egregore"]
    environment = {key: value for key, value in os.environ.items() if key not in {
        "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR",
    }}
    for flag in (("--absolute-git-dir", "--git-common-dir") if (root / ".git").exists() else ()):
        try:
            result = subprocess.run(
                ["git", "-C", str(root), "rev-parse", flag], capture_output=True,
                text=True, timeout=5, env=environment, check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise UpgradeError("cannot resolve Runtime installation metadata; repair Git before upgrading") from exc
        if result.returncode != 0 or not result.stdout.strip():
            raise UpgradeError("cannot resolve Runtime installation metadata; repair Git before upgrading")
        directory = Path(result.stdout.strip())
        directories.append((directory if directory.is_absolute() else root / directory) / "info")
    seen: set[Path] = set()
    for directory in directories:
        for harness in BUNDLE_TREES:
            name = (f"{harness}-runtime-manifest.json" if directory == root / ".egregore"
                    else f"egregore-{harness}-runtime.json")
            path = directory / name
            if path in seen:
                continue
            seen.add(path)
            yield path


def installed_runtime_receipt(repository_root: Path) -> dict[str, Any] | None:
    """Read this installation's durable package ownership, never global state.

    Local edits do not surrender ownership, so recorded hashes are validated
    structurally, not compared with current bytes. All receipts must agree on
    the shared core; choosing one harness could hide a partial upgrade.
    """
    receipts = []
    for path in _runtime_install_receipt_paths(repository_root):
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            continue
        except (OSError, ValueError) as exc:
            raise UpgradeError("installed Runtime receipt is unreadable; repair the installation before upgrading") from exc
        if not isinstance(value, dict):
            raise UpgradeError("installed Runtime receipt is malformed; repair the installation before upgrading")
        if value.get("package") != "create-egregore":
            continue
        files = value.get("files")
        if not isinstance(files, dict):
            raise UpgradeError("installed Runtime ownership is malformed; repair the installation before upgrading")
        if not any(relative in files for relative in _RUNTIME_CORE_FILES):
            # Pre-Runtime adapter receipts own skills only.
            continue
        hashes = {}
        for relative in _RUNTIME_CORE_FILES:
            entry = files.get(relative)
            digest = entry.get("hash") if isinstance(entry, dict) else None
            if not isinstance(digest, str) or re.fullmatch(r"[a-f0-9]{64}", digest) is None:
                raise UpgradeError("installed Runtime ownership is incomplete; repair the installation before upgrading")
            hashes[relative] = {"hash": digest}
        else:
            version = value.get("version")
            receipts.append({
                "version": version.strip() if isinstance(version, str) and version.strip() else None,
                "files": hashes,
            })
    if not receipts:
        return None
    if any(receipt != receipts[0] for receipt in receipts[1:]):
        raise UpgradeError("installed Runtime receipts disagree; repair the installation before upgrading")
    return receipts[0]


def _preserve_codex_settings(instance: Path, activation: Mapping[str, Any] | None) -> bool:
    """Preserve user TOML verbatim unless durable ownership proves it unmodified."""
    import hashlib

    existing = instance / CODEX_SETTINGS_ADAPTER
    if existing.is_symlink():
        return True
    if not existing.exists():
        return False
    if not existing.is_file():
        return True
    try:
        current = existing.read_bytes()
    except OSError:
        return True
    digest = hashlib.sha256(current).hexdigest()
    managed = (activation or {}).get("managed_config_hashes")
    if activation is not None and "managed_config_hashes" in activation:
        # Runtime activation supersedes an older installer receipt. A local
        # edit or an explicitly unowned config never falls back to stale
        # installer metadata, including after rollback.
        if not isinstance(managed, dict) or CODEX_SETTINGS_ADAPTER not in managed:
            return True
        return managed[CODEX_SETTINGS_ADAPTER] != digest
    applied = (activation or {}).get("applied")
    if isinstance(applied, dict):
        preserved = applied.get("preserved", [])
        if not isinstance(preserved, list) or CODEX_SETTINGS_ADAPTER in preserved:
            return True
    hashes: set[str] = set()
    try:
        for path in _runtime_install_receipt_paths(instance):
            try:
                receipt = json.loads(path.read_text(encoding="utf-8"))
            except FileNotFoundError:
                continue
            if not isinstance(receipt, dict):
                return True
            if receipt.get("package") != "create-egregore":
                continue
            files = receipt.get("files")
            if not isinstance(files, dict):
                return True
            if CODEX_SETTINGS_ADAPTER not in files:
                continue
            entry = files[CODEX_SETTINGS_ADAPTER]
            owned_hash = entry.get("hash") if isinstance(entry, dict) else None
            if not isinstance(owned_hash, str) or re.fullmatch(r"[a-f0-9]{64}", owned_hash) is None:
                return True
            hashes.add(owned_hash)
    except (OSError, ValueError, UpgradeError):
        return True
    return hashes != {digest}


def _settings_carries_more(existing: Path, candidate: Path) -> bool:
    """True when the instance's settings file has hook events or permission
    allows the candidate's generated adapter lacks. An unreadable candidate
    keeps the existing file; an unreadable or missing existing file does not."""
    if not existing.is_file():
        return False
    try:
        current = json.loads(existing.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return False
    try:
        incoming = json.loads(candidate.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return True
    if not isinstance(current, dict) or not isinstance(incoming, dict):
        return False

    def hooks(doc: dict) -> set[str]:
        value = doc.get("hooks")
        return set(value.keys()) if isinstance(value, dict) else set()

    def allows(doc: dict) -> set[str]:
        perms = doc.get("permissions")
        value = perms.get("allow") if isinstance(perms, dict) else None
        return {str(v) for v in value} if isinstance(value, list) else set()

    return bool(hooks(current) - hooks(incoming)) or bool(allows(current) - allows(incoming))

STATUS_PENDING = "pending"
STATUS_PREPARING = "preparing"
STATUS_FAILED = "failed"
STATUS_READY = "ready-to-activate"
STATUS_ACTIVE = "active"
STATUS_CANCELLED = "cancelled"
STATUS_ROLLED_BACK = "rolled-back"


class UpgradeError(RuntimeError):
    pass


def _now() -> int:
    return int(time.time())


@dataclass
class UpgradeStore:
    """Durable, instance-scoped upgrade state with atomic writes."""

    root: Path

    @property
    def state_path(self) -> Path:
        return self.root / "state.json"

    @property
    def activation_path(self) -> Path:
        return self.root / "active.json"

    @property
    def cancel_path(self) -> Path:
        return self.root / "cancel"

    @property
    def apply_lock_path(self) -> Path:
        return self.root / "apply.lock"

    @property
    def apply_journal_path(self) -> Path:
        # Durable transaction marker: present exactly while instance bytes may
        # be mixed (from first mutation until the activation record is
        # written). Its presence after a crash is the deterministic recovery
        # signal.
        return self.root / "apply-journal.json"

    def load_apply_journal(self) -> dict[str, Any] | None:
        try:
            value = json.loads(self.apply_journal_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    def write_apply_journal(self, journal: Mapping[str, Any]) -> None:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        payload = dict(journal)
        payload["updated_at"] = _now()
        temporary = self.apply_journal_path.with_suffix(f".tmp.{os.getpid()}")
        temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(self.apply_journal_path)

    def clear_apply_journal(self) -> None:
        self.apply_journal_path.unlink(missing_ok=True)

    def load(self) -> dict[str, Any] | None:
        try:
            value = json.loads(self.state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    def write(self, state: Mapping[str, Any]) -> None:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(self.root, 0o700)
        payload = dict(state)
        payload["updated_at"] = _now()
        temporary = self.state_path.with_suffix(f".tmp.{os.getpid()}")
        temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(self.state_path)

    def load_activation(self) -> dict[str, Any] | None:
        try:
            value = json.loads(self.activation_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return None
        return value if isinstance(value, dict) else None

    def write_activation(self, record: Mapping[str, Any]) -> None:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        temporary = self.activation_path.with_suffix(f".tmp.{os.getpid()}")
        temporary.write_text(json.dumps(dict(record), indent=2, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(self.activation_path)

    def cancel_requested(self) -> bool:
        return self.cancel_path.exists()

    def request_cancel(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self.cancel_path.write_text(str(_now()) + "\n", encoding="utf-8")

    def clear_cancel(self) -> None:
        self.cancel_path.unlink(missing_ok=True)


def installation_root(repository_root: Path) -> Path:
    """The main installation directory a checkout belongs to.

    A linked git worktree (``.git`` is a file) belongs to its main checkout;
    upgrade state is per installation, so every worktree of one install
    shares it. A standalone clone is its own installation.
    """
    root = repository_root.resolve()
    git_marker = root / ".git"
    if git_marker.is_file():
        try:
            content = git_marker.read_text(encoding="utf-8")
            for line in content.splitlines():
                if line.startswith("gitdir:"):
                    git_dir = Path(line.split(":", 1)[1].strip())
                    if not git_dir.is_absolute():
                        git_dir = (root / git_dir).resolve()
                    # <main>/.git/worktrees/<name> → <main>
                    if git_dir.parent.name == "worktrees" and git_dir.parent.parent.name == ".git":
                        return git_dir.parent.parent.parent.resolve()
        except OSError:
            pass
    return root


def instance_key(repository_root: Path) -> str:
    """Durable upgrade-state key: stable org identity × installation identity.

    Identity is never inferred from a path alone: the stable organization ID
    from egregore.json is required and leads the key, so two organizations
    that share, symlink, or otherwise resolve to the same memory repository
    can never share activation, worker, lock, or rollback state. The
    installation path is composed in explicitly so two installs of the same
    organization stay independent, while worktrees of one install share it.
    A checkout without a stable org_id fails closed.
    """
    root = repository_root.resolve()
    try:
        config = json.loads((root / "egregore.json").read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise UpgradeError(f"cannot read egregore.json for instance identity: {exc}") from exc
    org_id = str(config.get("org_id") or "").strip()
    if not org_id:
        raise UpgradeError(
            "this instance has no stable org_id; upgrade state fails closed "
            "without a stable organization identity"
        )
    install = installation_root(root)
    import hashlib

    return hashlib.sha256(f"{org_id}|{install}".encode("utf-8")).hexdigest()[:16]


def upgrade_root(repository_root: Path) -> Path:
    """Instance-scoped upgrade state dir, keyed by composed stable identity."""
    override = os.environ.get("EGREGORE_UPGRADE_ROOT")
    if override:
        return Path(override).expanduser() / instance_key(repository_root)
    return Path.home() / ".egregore" / "runtime" / "upgrade" / instance_key(repository_root)


def build_cli_context(repository_root: Path):
    """Store/engine/retriever wiring for the CLI — keeps retrieval adapter
    imports out of harness_cli, which must stay behind Runtime contracts."""
    from .runtime import local_runtime

    retriever = QmdLocalRetriever(repository_root=repository_root)
    store = UpgradeStore(root=upgrade_root(repository_root))
    engine = UpgradeEngine(
        repository_root=repository_root,
        store=store,
        runtime=local_runtime(repository_root, push_remote=False),
        retriever=retriever,
    )
    return store, engine, retriever


def _pid_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
        return True
    except (OSError, ValueError, TypeError):
        return False


def new_state(
    *,
    instance_path: Path,
    org_id: str,
    instance_hash: str,
    candidate_version: str,
    active_version: str,
    candidate_source: str = "",
) -> dict[str, Any]:
    return {
        "schema_version": SCHEMA_VERSION,
        "instance_path": str(instance_path),
        "org_id": org_id,
        "instance_hash": instance_hash,
        "candidate_version": candidate_version,
        "candidate_source": candidate_source,
        "candidate_digest": None,
        "installed_path": None,
        "active_version": active_version,
        "rollback_version": active_version,
        "status": STATUS_PENDING,
        "stages": [
            {"key": key, "label": label, "state": "pending", "detail": ""}
            for key, label in STAGES
        ],
        "source_revision": None,
        "semantic_revision": None,
        "progress": {},
        "gates": {},
        "failure": None,
        "worker": None,
        "started_at": _now(),
    }


def stage_index(state: Mapping[str, Any], key: str) -> int:
    for index, stage in enumerate(state.get("stages", ())):
        if stage.get("key") == key:
            return index
    raise UpgradeError(f"unknown upgrade stage: {key}")


def describe(state: Mapping[str, Any] | None, *, worker_alive: bool | None = None) -> dict[str, Any]:
    """Status projection for adapters (Settings, session start, readiness)."""
    if state is None:
        return {"schema_version": SCHEMA_VERSION, "status": "none"}
    projected = dict(state)
    worker = state.get("worker") or {}
    pid = worker.get("pid")
    alive = worker_alive if worker_alive is not None else (_pid_alive(pid) if pid else False)
    projected["worker_alive"] = bool(alive)
    # A preparing status with a dead worker is not "active work" — it is a
    # resumable interruption and must be presented as such.
    if state.get("status") == STATUS_PREPARING and not alive:
        projected["status"] = "interrupted"
    return projected


@dataclass
class UpgradeEngine:
    """Runs preparation stages against one instance. Resumable by design."""

    repository_root: Path
    store: UpgradeStore
    runtime: Any  # EgregoreRuntime; typed loosely to keep import edges thin
    retriever: QmdLocalRetriever
    poll_seconds: float = 1.0
    log: Any = None  # callable(str) for worker logs; never user-facing

    def _mark(self, state: dict[str, Any], key: str, stage_state: str, detail: str = "") -> None:
        index = stage_index(state, key)
        stage = state["stages"][index]
        stage["state"] = stage_state
        stage["detail"] = detail
        if stage_state == "running" and "started_at" not in stage:
            stage["started_at"] = _now()
        if stage_state in ("done", "failed"):
            stage["finished_at"] = _now()
        self.store.write(state)

    def _fail(self, state: dict[str, Any], key: str, message: str) -> None:
        self._mark(state, key, "failed", message[:300])
        state["status"] = STATUS_FAILED
        state["failure"] = {"stage": key, "message": message[:300]}
        self.store.write(state)

    def _cancelled(self, state: dict[str, Any]) -> bool:
        if not self.store.cancel_requested():
            return False
        state["status"] = STATUS_CANCELLED
        self.store.write(state)
        return True

    def _stage_done(self, state: dict[str, Any], key: str) -> bool:
        return state["stages"][stage_index(state, key)].get("state") == "done"

    # -- stages ----------------------------------------------------------

    def _run_sync(self, state: dict[str, Any]) -> bool:
        receipt = self.runtime.synchronize()
        current = bool(getattr(receipt, "canonical_current", False))
        if not current:
            failures = tuple(getattr(receipt, "failures", ()) or ())
            self._fail(state, "sync", "; ".join(failures) or "team memory could not be synchronized")
            return False
        self._mark(state, "sync", "done", "canonical memory current")
        return True

    def _run_candidate(self, state: dict[str, Any]) -> bool:
        revision = self.retriever._source_revision()
        state["source_revision"] = revision
        self._mark(state, "candidate", "done", revision)
        return True

    @staticmethod
    def _sha256(path: Path) -> str:
        import hashlib

        digest = hashlib.sha256()
        with path.open("rb") as handle:
            for block in iter(lambda: handle.read(1 << 20), b""):
                digest.update(block)
        return digest.hexdigest()

    def _run_install(self, state: dict[str, Any]) -> bool:
        import shutil
        import tarfile

        source = Path(state.get("candidate_source") or "")
        if not source.is_file():
            self._fail(state, "install", "no candidate package tarball was staged for this upgrade")
            return False
        state["candidate_digest"] = self._sha256(source)
        self.store.write(state)

        target = self.store.root / "candidate"
        if target.exists():
            shutil.rmtree(target)
        target.mkdir(parents=True, mode=0o700)
        try:
            with tarfile.open(source, "r:gz") as archive:
                for member in archive.getmembers():
                    member_path = (target / member.name).resolve()
                    if not str(member_path).startswith(str(target.resolve())):
                        raise UpgradeError(f"unsafe path in candidate archive: {member.name}")
                archive.extractall(target)
        except Exception as exc:
            self._fail(state, "install", f"candidate extraction failed: {exc}")
            return False

        package_root = target / "package"
        try:
            manifest = json.loads((package_root / "package.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            self._fail(state, "install", f"candidate package.json unreadable: {exc}")
            return False
        if str(manifest.get("version")) != state["candidate_version"]:
            self._fail(
                state,
                "install",
                f"candidate package is {manifest.get('version')}, expected {state['candidate_version']}",
            )
            return False
        scripts = manifest.get("scripts") or {}
        for lifecycle in ("preinstall", "install", "postinstall"):
            if lifecycle in scripts:
                self._fail(state, "install", f"candidate declares a {lifecycle} lifecycle script; refused")
                return False
        missing = [tree for tree in BUNDLE_TREES if not (package_root / "runtime" / tree).is_dir()]
        if missing:
            self._fail(state, "install", "candidate is missing packaged bundles: " + ", ".join(missing))
            return False
        state["installed_path"] = str(package_root)
        self._mark(
            state,
            "install",
            "done",
            f"{manifest.get('version')} · sha256 {state['candidate_digest'][:16]} · all four bundles present",
        )
        return True

    def _run_node(self, state: dict[str, Any]) -> bool:
        node = self.retriever.environment.get("EGREGORE_QMD_NODE_BIN")
        if not node:
            self._fail(state, "node", "no usable Node runtime was found for this instance")
            return False
        probe = subprocess.run(
            (node, "--version"), capture_output=True, text=True, timeout=15, check=False
        )
        if probe.returncode != 0:
            self._fail(state, "node", "the selected Node runtime failed its version probe")
            return False
        self._mark(state, "node", "done", f"{probe.stdout.strip()} at instance-selected path")
        return True

    def _run_qmd(self, state: dict[str, Any]) -> bool:
        # An explicitly pinned QMD (constructor command or EGREGORE_QMD_BIN)
        # is the instance's chosen binary — verify it instead of installing
        # over it. Otherwise ensure the instance-owned managed install.
        if self.retriever._configured_command or self.retriever.environment.get("EGREGORE_QMD_BIN"):
            try:
                self.retriever._ensure_version()
            except Exception as exc:
                self._fail(state, "qmd", f"pinned QMD failed verification: {exc}")
                return False
            self._mark(state, "qmd", "done", f"QMD {QMD_VERSION} (pinned by configuration)")
            return True
        binary = self.retriever._managed_binary()
        if not (binary.is_file() and os.access(binary, os.X_OK)):
            try:
                binary = self.retriever.install_managed()
            except Exception as exc:
                self._fail(state, "qmd", f"QMD {QMD_VERSION} install failed: {exc}")
                return False
        self._mark(state, "qmd", "done", f"QMD {QMD_VERSION} (instance-owned)")
        return True

    def _run_bm25(self, state: dict[str, Any]) -> bool:
        try:
            health = self.retriever.update()
        except Exception as exc:
            self._fail(state, "bm25", f"keyword index build failed: {exc}")
            return False
        if not health.bm25_ready:
            self._fail(state, "bm25", "keyword index did not become ready")
            return False
        self._record_progress(state)
        self._mark(state, "bm25", "done", "keyword search current for the candidate revision")
        return True

    def _record_progress(self, state: dict[str, Any]) -> None:
        completed = self.retriever._run(("status",), timeout=30)
        counts = self.retriever._status_counts(completed.stdout if completed.returncode == 0 else "")
        state["progress"] = {
            "documents": counts["documents"],
            "vectors": counts["vectors"],
            "pending": counts["pending"],
            "counted_at": _now(),
        }
        self.store.write(state)

    def _run_embed(self, state: dict[str, Any], key: str = "embed") -> bool:
        self._mark(state, key, "running", "embedding team memory")
        # One `qmd embed` invocation proves nothing by itself: qmd embeds in
        # bounded batches, a concurrent session's embedder can hold the embed
        # lock (our pass prints "Skipping" and exits 0 while theirs runs), and
        # freshly written vectors become countable slightly after the process
        # exits. Drain instead: keep invoking embed and re-reading the real
        # count for as long as pending falls; fail only after a full settle
        # window passes with no progress from anyone.
        try:
            settle = float(
                self.retriever.environment.get(
                    "EGREGORE_UPGRADE_EMBED_SETTLE_SECONDS", "20"
                )
            )
        except (AttributeError, TypeError, ValueError):
            settle = 20.0
        previous: int | None = None
        deadline = time.monotonic() + settle
        while True:
            if self._cancelled(state):
                return False
            try:
                self.retriever.embed_foreground()
            except Exception as exc:
                self._fail(state, key, f"meaning-index build failed: {exc}")
                return False
            self._record_progress(state)
            pending = int(state["progress"].get("pending", 0) or 0)
            if not pending:
                break
            if previous is None or pending < previous:
                previous = pending
                deadline = time.monotonic() + settle
                vectors = state["progress"].get("vectors", 0)
                self._mark(
                    state, key, "running", f"{vectors} chunks embedded · {pending} pending"
                )
            elif time.monotonic() >= deadline:
                self._fail(state, key, f"{pending} documents still awaiting embeddings after the build")
                return False
            if settle > 0:
                time.sleep(min(2.0, settle))
        self._mark(state, key, "done", f"{state['progress'].get('vectors', 0)} chunks embedded")
        return True

    def _run_delta(self, state: dict[str, Any]) -> bool:
        # Canonical memory may have moved while the initial build ran. Converge:
        # re-sync, re-index, embed the remaining delta — bounded, resumable.
        for _ in range(5):
            if self._cancelled(state):
                return False
            self.retriever._source_revision_cache = None
            if self.retriever._semantic_state_current():
                state["semantic_revision"] = self.retriever._semantic_source_revision()
                state["source_revision"] = self.retriever._source_revision()
                self._mark(state, "delta", "done", "meaning index matches the candidate revision")
                return True
            receipt = self.runtime.synchronize()
            if not bool(getattr(receipt, "canonical_current", False)):
                self._fail(state, "delta", "team memory changed and could not be re-synchronized")
                return False
            # Bring the keyword index to the new revision before embedding the
            # delta — a no-op when synchronize already did it.
            try:
                self.retriever.update()
            except Exception as exc:
                self._fail(state, "delta", f"keyword index refresh failed: {exc}")
                return False
            if not self._run_embed(state, key="delta"):
                return False
            # _run_embed marked delta done; loop re-checks currency in case
            # memory moved again during that embed.
            self._mark(state, "delta", "running", "verifying the delta landed")
        self._fail(state, "delta", "team memory kept changing during preparation; retry when quieter")
        return False

    def _run_verify(self, state: dict[str, Any]) -> bool:
        from .readiness import build_report, session_boundary_state
        from .contracts import Permission

        health = self.retriever.health()
        gates: dict[str, bool | str] = {}
        gates["bm25_current"] = bool(health.bm25_ready and health.index_source_revision == health.source_revision)
        gates["semantic_complete"] = bool(health.semantic_ready)
        gates["semantic_matches_source"] = bool(
            health.semantic_source_revision is not None
            and health.semantic_source_revision == health.source_revision
        )
        gates["reranker_disabled"] = not RERANKING_ENABLED
        boundary = session_boundary_state(self.repository_root)
        authorization: Any
        try:
            actor = self.runtime.resolve_actor(
                session_id=os.environ.get("EGREGORE_SESSION_ID", "upgrade-verify"),
                harness="upgrade",
            )
            authorization = self.runtime.authorize(actor, Permission.READ)
            gates["identity_resolves"] = True
            gates["authorization_allows"] = bool(authorization.allowed)
        except Exception as exc:
            authorization = exc
            gates["identity_resolves"] = False
            gates["authorization_allows"] = False
        report = build_report(
            root=self.repository_root,
            health=health,
            boundary=boundary,
            authorization=authorization if not isinstance(authorization, bool) else None,
        )
        stages = {item.key: item.stage for item in report.items}
        gates["boundary_ready"] = stages.get("boundary") == "ready"
        gates["hybrid_probe"] = stages.get("search") == "ready" and gates["semantic_complete"]
        # Retrieval in the upgraded Runtime is QMD-only by construction: the
        # engine never consults graph projections and records that contract.
        gates["graph_retrieval"] = "not-used-by-this-runtime"
        state["gates"] = gates
        state["semantic_revision"] = health.semantic_source_revision
        failed = [name for name, value in gates.items() if value is False]
        if failed:
            self._fail(state, "verify", "gates failed: " + ", ".join(failed))
            return False
        self._mark(state, "verify", "done", "all activation gates passed")
        return True

    # -- driver ----------------------------------------------------------

    def prepare(self) -> dict[str, Any]:
        state = self.store.load()
        if state is None:
            raise UpgradeError("no upgrade has been initialized for this instance")
        if state.get("status") == STATUS_ACTIVE:
            return state
        self.store.clear_cancel()
        state["status"] = STATUS_PREPARING
        state["worker"] = {"pid": os.getpid(), "started_at": _now()}
        self.store.write(state)

        runners = {
            "sync": self._run_sync,
            "candidate": self._run_candidate,
            "install": self._run_install,
            "node": self._run_node,
            "qmd": self._run_qmd,
            "bm25": self._run_bm25,
            "embed": self._run_embed,
            "delta": self._run_delta,
            "verify": self._run_verify,
        }
        for key, _label in STAGES:
            if self._cancelled(state):
                return state
            if self._stage_done(state, key):
                continue
            self._mark(state, key, "running")
            if not runners[key](state):
                return state
        state["status"] = STATUS_READY
        self.store.write(state)
        return state

    def _acquire_apply_lock(self) -> None:
        """Per-instance mutual exclusion for activation and rollback. A stale
        lock from a dead process is reclaimed; a live one refuses."""
        self.store.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        lock = self.store.apply_lock_path
        for attempt in (0, 1):
            try:
                fd = os.open(str(lock), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
                os.write(fd, str(os.getpid()).encode("utf-8"))
                os.close(fd)
                return
            except FileExistsError:
                try:
                    holder = int(lock.read_text(encoding="utf-8").strip() or "0")
                except (OSError, ValueError):
                    holder = 0
                if holder and _pid_alive(holder):
                    raise UpgradeError(
                        f"another Runtime apply is in progress (pid {holder}); retry after it finishes"
                    )
                if attempt == 0:
                    lock.unlink(missing_ok=True)
        raise UpgradeError("could not acquire the Runtime apply lock")

    def _release_apply_lock(self) -> None:
        self.store.apply_lock_path.unlink(missing_ok=True)

    @staticmethod
    def _valid_legacy_baseline(value: Any) -> bool:
        if (not isinstance(value, dict) or value.get("schema_version") != LEGACY_BASELINE_SCHEMA
                or value.get("kind") != "legacy-template"
                or not isinstance(value.get("git_head"), str)
                or re.fullmatch(r"(?:[a-f0-9]{40}|[a-f0-9]{64})", value["git_head"]) is None
                or not isinstance(value.get("files"), dict)
                or set(value["files"]) != set(_LEGACY_TEMPLATE_FILES)):
            return False
        return all(isinstance(digest, str) and re.fullmatch(r"[a-f0-9]{64}", digest)
                   for digest in value["files"].values())

    @staticmethod
    def _committed_unchanged(instance: Path, relative: str) -> bool:
        """Git tracks the path and nothing under it differs from HEAD."""
        environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        tracked = subprocess.run(["git", "-C", str(instance), "ls-files", "-z", "--", relative],
                                 capture_output=True, text=True, timeout=5, env=environment, check=False)
        status = subprocess.run(["git", "-C", str(instance), "status", "--porcelain", "-z",
                                 "--untracked-files=all", "--", relative],
                                capture_output=True, text=True, timeout=5, env=environment, check=False)
        if tracked.returncode != 0 or status.returncode != 0 or not tracked.stdout.strip("\0"):
            return False
        return all(entry[3:].endswith(".pyc") and "/__pycache__/" in f"/{entry[3:]}"
                   for entry in status.stdout.split("\0") if entry)

    def _legacy_template_baseline(self, instance: Path, *, previously_restored: bool) -> dict:
        """Recognize an unversioned template without claiming installed Runtime.

        Git identifies provenance only. Dirty bytes are captured by the normal
        rollback archive, never reconstructed by checking out a Git revision.
        Runtime files a framework update committed are template content; an
        untracked or edited Runtime file is unreceipted installation evidence.
        """
        try:
            for receipt in _runtime_install_receipt_paths(instance):
                if receipt.exists() or receipt.is_symlink():
                    raise ValueError("installer evidence needs repair")
            for relative in ("bin/observe-context.sh", "bin/runtime-identity.sh", "bin/runtime-upgrade.sh"):
                marker = instance / relative
                if marker.is_symlink() or (marker.exists() and not self._committed_unchanged(instance, relative)):
                    raise ValueError("Runtime adapter evidence needs repair")
            core = instance / "egregore_runtime"
            delivered = (not core.is_symlink() and core.is_dir()
                         and not any(path.is_symlink() for path in core.rglob("*"))
                         and self._committed_unchanged(instance, "egregore_runtime"))
            if (core.exists() or core.is_symlink()) and not delivered:
                # A completed legacy rollback removes added files, not their
                # parent directories or Python's generated caches. Only a
                # validated prior baseline permits these harmless remnants.
                if not previously_restored or core.is_symlink() or not core.is_dir():
                    raise ValueError("Runtime code is present")
                for path in core.rglob("*"):
                    if path.is_symlink() or (not path.is_dir() and not (
                        path.is_file() and path.suffix == ".pyc" and path.parent.name == "__pycache__"
                    )):
                        raise ValueError("unexpected Runtime files remain")
            files = {}
            for relative in _LEGACY_TEMPLATE_FILES:
                path = instance / relative
                if path.is_symlink() or path.parent.is_symlink() or not path.is_file():
                    raise ValueError("template evidence is missing")
                files[relative] = self._sha256(path)
            config = json.loads((instance / "egregore.json").read_text(encoding="utf-8"))
            if (not isinstance(config, dict) or not isinstance(config.get("org_id"), str)
                    or not config["org_id"].strip()):
                raise ValueError("template identity is missing")
            environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
            head = subprocess.run(["git", "-C", str(instance), "rev-parse", "--show-toplevel", "HEAD^{commit}"],
                                  capture_output=True, text=True, timeout=5, env=environment, check=False)
            lines = head.stdout.strip().splitlines()
            baseline = {"schema_version": LEGACY_BASELINE_SCHEMA, "kind": "legacy-template",
                        "git_head": lines[-1] if lines else "", "files": files}
            if (head.returncode != 0 or len(lines) != 2 or Path(lines[0]).resolve() != instance.resolve()
                    or not self._valid_legacy_baseline(baseline)):
                raise ValueError("template Git provenance is missing")
            return baseline
        except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
            raise UpgradeError("previous Runtime version is unknown and no intact legacy template was found; "
                               "repair the installation before upgrading") from exc

    def _rollback_ownership(self, state: Mapping[str, Any]) -> dict[str, Any]:
        previous = self.store.load_activation()
        if (self.store.activation_path.exists() or self.store.activation_path.is_symlink()) and previous is None:
            raise UpgradeError("cannot read prior Runtime activation; repair it before upgrading")
        version = state.get("rollback_version")
        if not isinstance(version, str) or not version:
            raise UpgradeError("previous Runtime version is unknown; repair the installation before upgrading")
        if version == "unknown":
            if previous is not None and not (
                previous.get("active_version") == "unknown" and previous.get("retrieval") == "previous-runtime"
                and self._valid_legacy_baseline(previous.get("baseline"))
            ):
                raise UpgradeError("prior Runtime ownership is unknown; repair activation before upgrading")
            baseline = self._legacy_template_baseline(Path(state["instance_path"]), previously_restored=previous is not None)
            return {"schema_version": ROLLBACK_OWNERSHIP_SCHEMA, "active_version": "unknown",
                    "retrieval": "previous-runtime", "source": "legacy-template", "baseline": baseline,
                    "provenance": {"baseline": baseline}}
        if previous is not None:
            retrieval = previous.get("retrieval")
            if not isinstance(retrieval, str) or retrieval not in {"runtime-qmd", "previous-runtime"}:
                raise UpgradeError("prior Runtime ownership is unknown; repair activation before upgrading")
            if previous.get("active_version") != version:
                raise UpgradeError("active Runtime changed after preparation; stage the upgrade again")
            source = "activation"
        else:
            receipt = installed_runtime_receipt(Path(state["instance_path"]))
            if receipt is not None and receipt["version"] != version:
                raise UpgradeError("installed Runtime version differs from preparation; stage the upgrade again")
            retrieval = "runtime-qmd" if receipt is not None else "previous-runtime"
            source = "package-install" if receipt is not None else "legacy"
        # Keep provenance without recursively nesting earlier rollback records.
        provenance = {key: previous[key] for key in (
            "schema_version", "active_version", "source_revision", "semantic_revision",
            "candidate_digest", "installed_path", "activated_at", "graph_retrieval",
            "managed_config_hashes",
        ) if previous is not None and key in previous}
        return {
            "schema_version": ROLLBACK_OWNERSHIP_SCHEMA,
            "active_version": version, "retrieval": retrieval,
            "source": source, "provenance": provenance,
        }

    @staticmethod
    def _validate_rollback_ownership(value: Any) -> dict[str, Any]:
        if (not isinstance(value, dict)
                or value.get("schema_version") != ROLLBACK_OWNERSHIP_SCHEMA
                or not isinstance(value.get("retrieval"), str)
                or value.get("retrieval") not in {"runtime-qmd", "previous-runtime"}
                or not isinstance(value.get("source"), str)
                or value.get("source") not in {"activation", "package-install", "legacy", "legacy-template"}
                or not isinstance(value.get("active_version"), str)
                or not value["active_version"]
                or not isinstance(value.get("provenance"), dict)):
            raise UpgradeError(
                "rollback ownership metadata is missing or invalid; no files were restored. "
                "Repair the rollback record before retrying"
            )
        if value["active_version"] == "unknown" or value["source"] == "legacy-template":
            if (value["active_version"] != "unknown" or value["source"] != "legacy-template"
                    or value["retrieval"] != "previous-runtime"
                    or not UpgradeEngine._valid_legacy_baseline(value.get("baseline"))
                    or value["provenance"].get("baseline") != value["baseline"]):
                raise UpgradeError("unversioned rollback lacks valid legacy baseline metadata; no files were restored")
        return value

    def _restore_prior_activation(self, journal: Mapping[str, Any]) -> None:
        if "previous_activation" not in journal:
            raise UpgradeError("interrupted activation lacks prior ownership metadata; recovery needs repair")
        previous = journal["previous_activation"]
        if previous is None:
            self.store.activation_path.unlink(missing_ok=True)
        elif isinstance(previous, dict):
            self.store.write_activation(previous)
        else:
            raise UpgradeError("interrupted activation has invalid prior ownership metadata")

    def _codex_rollback_compatibility(
        self, instance: Path, selected: dict[str, Path], ownership: Mapping[str, Any],
        *, legacy_prompt: dict | None = None,
    ) -> dict:
        """Keep verified historical prompt hooks usable with durable bindings.

        This narrowly repairs a shipped hint-only hook, not arbitrary scripts.
        Unknown adapters fail before activation changes instance bytes. The
        original backup remains exact for automatic failed-apply recovery;
        explicit rollback retains only these compatibility adapters.
        """
        # Genuine pre-Runtime installs do not enforce native bindings after
        # rollback; candidate-added core files are removed with the archive.
        # A partial Runtime is not evidence of a legacy installation.
        core = [instance / relative for relative in (*_RUNTIME_CORE_FILES, "egregore_runtime/episode_binding.py")]
        pre_runtime = (ownership["retrieval"] == "previous-runtime"
                       and not any(path.exists() or path.is_symlink() for path in core))
        path = instance / CODEX_HOOKS_ADAPTER
        if CODEX_HOOKS_ADAPTER not in selected or not path.exists():
            return {}
        try:
            if path.is_symlink():
                raise ValueError("linked hooks")
            original_content = path.read_text(encoding="utf-8")
            hooks = json.loads(original_content)
            events = hooks["hooks"].get("UserPromptSubmit", [])
            legacy = [(event, hook) for event in events for hook in event.get("hooks", [])
                      if any(adapter in str(hook.get("command", ""))
                             for adapter in ("search-hint.js", "observe-context.sh"))]
            if not legacy:
                return {}
            if len(legacy) != 1:
                raise ValueError("ambiguous prompt handlers")
            event, hook = legacy[0]
            if (event.get("matcher", "") != "" or set(event) - {"matcher", "hooks"}
                    or hook.get("type") != "command"
                    or hook.get("command") not in {_CODEX_LEGACY_PROMPT_COMMAND, _CODEX_PROMPT_COMMAND}
                    or set(hook) - {"type", "command", "timeout", "statusMessage"}):
                raise ValueError("custom prompt command or condition")
            original_hook = dict(hook)
            contents = {}
            if hook["command"] == _CODEX_LEGACY_PROMPT_COMMAND:
                script = instance / CODEX_PROMPT_BRIDGE
                if script.is_symlink() or self._sha256(script) not in {_CODEX_HINT_SHA256, _CODEX_BRIDGE_SHA256}:
                    raise ValueError("custom prompt script")
                # Verify known supporting bytes, never infer API support from a
                # package version or execute code from the installation being read.
                supports = {
                    "bin/observe-context.sh": {_OBSERVE_ADAPTER_SHA256},
                    "egregore_runtime/episode_binding.py": {_NATIVE_BINDING_MODULE_SHA256},
                    "egregore_runtime/harness_cli.py": {
                        _NATIVE_BINDING_CLI_SHA256,
                        self._sha256(Path(__file__).with_name("harness_cli.py")),
                    },
                }
                if not pre_runtime:
                    for relative, hashes in supports.items():
                        target = instance / relative
                        if target.is_symlink() or self._sha256(target) not in hashes:
                            raise ValueError("unsupported previous native prompt API")
                candidate_bridge = selected[CODEX_PROMPT_BRIDGE]
                if self._sha256(candidate_bridge) != _CODEX_BRIDGE_SHA256:
                    raise ValueError("unsupported candidate prompt bridge")
                contents[CODEX_PROMPT_BRIDGE] = candidate_bridge.read_text(encoding="utf-8")
                hook["command"] = _CODEX_PROMPT_COMMAND
                hook["timeout"] = 45
            else:
                # A custom historical-name script may now be unrelated to the
                # direct native handler. Preserve it instead of claiming it.
                script = instance / CODEX_PROMPT_BRIDGE
                if script.exists() or script.is_symlink():
                    try:
                        custom = script.is_symlink() or self._sha256(script) not in {
                            _CODEX_HINT_SHA256, _CODEX_BRIDGE_SHA256,
                        }
                    except OSError:
                        custom = True
                    if custom:
                        selected.pop(CODEX_PROMPT_BRIDGE, None)
            # Already-native hooks need no historical API migration. Keep the
            # existing adapter and user siblings across subsequent upgrades;
            # never gate normal future releases on the legacy CLI hash pins.
            contents[CODEX_HOOKS_ADAPTER] = json.dumps(hooks, indent=2) + "\n"
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
            raise UpgradeError(
                "Codex prompt hooks need compatibility repair before upgrading; "
                "custom hooks were left unchanged. Restore a supported native prompt adapter and prepare again"
            ) from exc
        import hashlib
        compatibility = {}
        for relative, content in contents.items():
            staged = self.store.root / "rollback-compatibility" / relative
            staged.parent.mkdir(parents=True, exist_ok=True)
            staged.write_text(content, encoding="utf-8")
            selected[relative] = staged
            compatibility[relative] = {
                "content": content, "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest(),
            }
        if pre_runtime and legacy_prompt is not None and original_hook != hook:
            legacy_prompt.update({"original_hook": original_hook, "active_hook": dict(hook),
                                  "active_hash": compatibility[CODEX_HOOKS_ADAPTER]["sha256"],
                                  "original_content": original_content,
                                  "active_bridge_hash": compatibility[CODEX_PROMPT_BRIDGE]["sha256"],
                                  "original_bridge_hash": self._sha256(instance / CODEX_PROMPT_BRIDGE)})
        # Stable installs get the merged native hook on activation, but their
        # old code does not enforce bindings. Rollback restores their exact
        # original adapters instead of retaining a bridge to removed core.
        return {} if pre_runtime else compatibility

    def _claude_rollback_compatibility(
        self, instance: Path, selected: dict[str, Path], ownership: Mapping[str, Any],
    ) -> dict:
        """Retain only the reviewed Claude bridge when older core needs bindings."""
        script = instance / CLAUDE_PROMPT_BRIDGE
        if CLAUDE_PROMPT_BRIDGE not in selected or not (script.exists() or script.is_symlink()):
            return {}
        try:
            settings = instance / SETTINGS_ADAPTER
            if settings.is_symlink():
                raise ValueError("linked Claude settings")
            hooks = json.loads(settings.read_text(encoding="utf-8"))
            legacy = [(event, hook) for event in hooks.get("hooks", {}).get("UserPromptSubmit", [])
                      for hook in event.get("hooks", []) if "search-hint.sh" in str(hook.get("command", ""))]
            script_hash = None if script.is_symlink() else self._sha256(script)
            if not legacy:
                # An unrelated custom script is never adopted by the package.
                if script_hash not in {_CLAUDE_HINT_SHA256, _CLAUDE_BRIDGE_SHA256}:
                    selected.pop(CLAUDE_PROMPT_BRIDGE)
                return {}
            if len(legacy) != 1:
                raise ValueError("ambiguous Claude prompt handlers")
            event, hook = legacy[0]
            if (event.get("matcher", "") != "" or set(event) - {"matcher", "hooks"}
                    or hook.get("type") != "command" or hook.get("command") != _CLAUDE_LEGACY_PROMPT_COMMAND
                    or set(hook) - {"type", "command", "timeout", "statusMessage"}
                    or script_hash not in {_CLAUDE_HINT_SHA256, _CLAUDE_BRIDGE_SHA256}):
                raise ValueError("custom Claude prompt adapter")
            candidate = selected[CLAUDE_PROMPT_BRIDGE]
            if self._sha256(candidate) != _CLAUDE_BRIDGE_SHA256:
                raise ValueError("unsupported candidate Claude bridge")
            core = [instance / relative for relative in (*_RUNTIME_CORE_FILES, "egregore_runtime/episode_binding.py")]
            pre_runtime = (ownership["retrieval"] == "previous-runtime"
                           and not any(path.exists() or path.is_symlink() for path in core))
            if pre_runtime:
                return {}  # Restore the original script when candidate core is removed.
            if script_hash == _CLAUDE_HINT_SHA256:
                supports = {
                    "bin/observe-context.sh": {_OBSERVE_ADAPTER_SHA256},
                    "egregore_runtime/episode_binding.py": {_NATIVE_BINDING_MODULE_SHA256},
                    "egregore_runtime/harness_cli.py": {
                        _NATIVE_BINDING_CLI_SHA256, self._sha256(Path(__file__).with_name("harness_cli.py")),
                    },
                }
                for relative, hashes in supports.items():
                    target = instance / relative
                    if target.is_symlink() or self._sha256(target) not in hashes:
                        raise ValueError("unsupported previous native prompt API")
            # Already compatible bridges need no migration/API hash pinning.
            # The existing transaction preserves subsequent edits and deletion.
            return {CLAUDE_PROMPT_BRIDGE: {"content": candidate.read_text(encoding="utf-8"),
                                           "sha256": _CLAUDE_BRIDGE_SHA256}}
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
            raise UpgradeError("Claude prompt hooks need compatibility repair before upgrading; "
                               "custom hooks were left unchanged. Restore a supported native prompt adapter and prepare again") from exc

    def _legacy_prompt_rollback_plan(self, instance: Path, handler: Any) -> dict:
        """Journal a late-custom-hook merge before touching restored bytes."""
        if not handler:
            return {}
        if (not isinstance(handler, dict) or not isinstance(handler.get("original_hook"), dict)
                or not isinstance(handler.get("active_hook"), dict)
                or handler["original_hook"].get("command") != _CODEX_LEGACY_PROMPT_COMMAND
                or handler["active_hook"].get("command") != _CODEX_PROMPT_COMMAND):
            raise UpgradeError("legacy rollback prompt metadata is invalid; no files were restored")
        path = instance / CODEX_HOOKS_ADAPTER
        if path.is_symlink():
            raise UpgradeError("Codex prompt hooks changed to a link; repair them before rollback")
        if not path.exists():
            return {"deleted": True}
        try:
            current_hash = self._sha256(path)
            hooks = json.loads(path.read_text(encoding="utf-8"))
            matches = [(event, hook) for event in hooks["hooks"].get("UserPromptSubmit", [])
                       for hook in event.get("hooks", [])
                       if any(name in str(hook.get("command", ""))
                              for name in ("observe-context.sh", "search-hint.js"))]
            if matches:
                if len(matches) != 1:
                    raise ValueError("ambiguous prompt handler")
                event, hook = matches[0]
                if event.get("matcher", "") != "" or set(event) - {"matcher", "hooks"} or hook != handler["active_hook"]:
                    raise ValueError("customized framework prompt handler")
                hook.clear()
                hook.update(handler["original_hook"])
            # Removing the framework event is a deliberate user customization.
            # Keep its absence, as well as all added/edited/deleted siblings.
            content = (handler["original_content"] if current_hash == handler.get("active_hash")
                       else json.dumps(hooks, indent=2) + "\n")
        except (OSError, ValueError, KeyError, TypeError, AttributeError) as exc:
            raise UpgradeError("Codex prompt hooks need repair before rollback; no files were restored") from exc
        import hashlib
        return {"before_hash": current_hash, "content": content,
                "sha256": hashlib.sha256(content.encode("utf-8")).hexdigest()}

    @staticmethod
    def _validate_prompt_compatibility(value: Any) -> dict:
        import hashlib
        if value == {}:
            return value
        if (not isinstance(value, dict)
                or set(value) - {CODEX_HOOKS_ADAPTER, CODEX_PROMPT_BRIDGE, CLAUDE_PROMPT_BRIDGE}
                or (CODEX_PROMPT_BRIDGE in value and CODEX_HOOKS_ADAPTER not in value)):
            raise UpgradeError("rollback prompt compatibility metadata is invalid; no files were restored")
        for entry in value.values():
            if (not isinstance(entry, dict) or not isinstance(entry.get("content"), str)
                    or entry.get("sha256") != hashlib.sha256(entry["content"].encode("utf-8")).hexdigest()):
                raise UpgradeError("rollback prompt compatibility bytes are invalid; no files were restored")
        return value

    def _restore_from_backup(self, instance: Path) -> bool:
        """Restore the exact pre-apply tree: replaced files come back from the
        backup archive, candidate-added files are removed. Returns whether a
        backup existed to restore."""
        import tarfile

        backup_path = self.store.root / "rollback-files.tar.gz"
        manifest_path = self.store.root / "rollback-manifest.json"
        if not (backup_path.is_file() and manifest_path.is_file()):
            raise UpgradeError("rollback backup is missing; no files were restored")
        try:
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise UpgradeError("rollback backup metadata is unavailable; no files were restored") from exc
        journal = self.store.load_apply_journal() or {}
        ownership = self._validate_rollback_ownership(journal.get("rollback_ownership"))
        if not isinstance(manifest, dict) or manifest.get("rollback_ownership") != ownership:
            raise UpgradeError("rollback backup lacks matching ownership metadata; no files were restored")
        if ownership["source"] == "legacy-template":
            digest = journal.get("backup_sha256")
            if (not isinstance(digest, str) or re.fullmatch(r"[a-f0-9]{64}", digest) is None
                    or manifest.get("backup_sha256") != digest or self._sha256(backup_path) != digest):
                raise UpgradeError("legacy rollback backup digest differs; no files were restored")
        compatibility = {}
        if journal.get("phase") == "rolling-back":
            compatibility = self._validate_prompt_compatibility(manifest.get("prompt_compatibility", {}))
            if journal.get("prompt_compatibility", {}) != compatibility:
                raise UpgradeError("rollback prompt compatibility metadata differs; no files were restored")
        preserve_bridge = False
        if journal.get("phase") == "rolling-back" and manifest.get("legacy_prompt_handler"):
            handler = manifest["legacy_prompt_handler"]
            if journal.get("legacy_prompt_handler") != handler:
                raise UpgradeError("legacy rollback prompt metadata differs; no files were restored")
            bridge = instance / CODEX_PROMPT_BRIDGE
            preserve_bridge = (bridge.is_symlink() or not bridge.is_file() or self._sha256(bridge) not in {
                handler.get("active_bridge_hash"), handler.get("original_bridge_hash"),
            })
        legacy_restore = journal.get("legacy_prompt_restore", {}) if journal.get("phase") == "rolling-back" else {}
        legacy_target = instance / CODEX_HOOKS_ADAPTER
        if legacy_restore:
            if journal.get("legacy_prompt_handler") != manifest.get("legacy_prompt_handler"):
                raise UpgradeError("legacy rollback prompt metadata differs; no files were restored")
            import hashlib
            if legacy_restore != {"deleted": True}:
                if (not isinstance(legacy_restore, dict) or not isinstance(legacy_restore.get("content"), str)
                        or legacy_restore.get("sha256") != hashlib.sha256(legacy_restore["content"].encode()).hexdigest()):
                    raise UpgradeError("legacy rollback prompt bytes are invalid; no files were restored")
                if legacy_target.is_symlink() or (legacy_target.exists() and self._sha256(legacy_target) not in {
                    legacy_restore.get("before_hash"), legacy_restore["sha256"],
                }):
                    raise UpgradeError("Codex prompt hooks changed during rollback; repair them before retrying")
        preserve_settings = set()
        if journal.get("phase") == "rolling-back":
            # A connection configured after activation belongs to the user.
            # The journal retains the activated hash across interrupted
            # rollback retries, even after active.json has been restored.
            hashes = journal.get("active_config_hashes")
            for relative in (CODEX_SETTINGS_ADAPTER, *NATIVE_SETTINGS_ADAPTERS):
                expected = hashes.get(relative) if isinstance(hashes, dict) else None
                config = instance / relative
                try:
                    if (not isinstance(expected, str) or config.is_symlink()
                            or not config.is_file() or self._sha256(config) != expected):
                        preserve_settings.add(relative)
                except OSError:
                    preserve_settings.add(relative)
        with tarfile.open(backup_path, "r:gz") as backup:
            members = [member for member in backup.getmembers()
                       if member.name not in compatibility
                       and not (legacy_restore and member.name == CODEX_HOOKS_ADAPTER)
                       and not (preserve_bridge and member.name == CODEX_PROMPT_BRIDGE)
                       and member.name not in preserve_settings]
            for member in members:
                member_path = (instance / member.name).resolve()
                if not member_path.is_relative_to(instance.resolve()):
                    raise UpgradeError(f"unsafe path in rollback archive: {member.name}")
            backup.extractall(instance, members=members)
        for relative in manifest.get("added", ()):  # candidate-only files
            if (relative in compatibility or (legacy_restore and relative == CODEX_HOOKS_ADAPTER)
                    or (preserve_bridge and relative == CODEX_PROMPT_BRIDGE)
                    or relative in preserve_settings):
                continue
            candidate_file = (instance / relative).resolve()
            if candidate_file.is_relative_to(instance.resolve()):
                candidate_file.unlink(missing_ok=True)
        if legacy_restore and "content" in legacy_restore and legacy_target.exists():
            temporary = legacy_target.with_suffix(f".runtime-rollback.{os.getpid()}")
            temporary.write_text(legacy_restore["content"], encoding="utf-8")
            temporary.replace(legacy_target)
        if ownership["source"] == "legacy-template":
            # This baseline had no Runtime package. Remove disposable caches
            # and empty candidate-created directories so failed activation can
            # retry without manufacturing prior installation evidence. Any
            # other new/user file remains untouched.
            core = instance / "egregore_runtime"
            if core.is_dir() and not core.is_symlink():
                for path in core.rglob("*.pyc"):
                    if path.parent.name == "__pycache__" and path.is_file() and not path.is_symlink():
                        path.unlink()
                for directory in sorted(core.rglob("*"), key=lambda path: len(path.parts), reverse=True):
                    if directory.is_dir() and not directory.is_symlink():
                        try:
                            directory.rmdir()
                        except OSError:
                            pass
                try:
                    core.rmdir()
                except OSError:
                    pass
        # Compatibility adapters already landed at activation. Keeping their
        # current bytes also preserves later user edits/deletions on replay.
        return True

    def recover_interrupted_apply(self) -> bool:
        """Deterministic recovery: a live apply journal means a previous apply
        died between first mutation and the activation record. The backup
        archive holds the complete pre-apply tree — restore it, clear the
        journal, and the instance is coherent legacy again, safe to retry."""
        journal = self.store.load_apply_journal()
        if journal is None:
            if self.store.apply_journal_path.exists():
                raise UpgradeError("Runtime transaction journal is unreadable; recovery needs repair")
            return False
        if journal.get("phase") == "rolling-back":
            self._finish_rollback(journal)
            return True
        if not isinstance(journal.get("phase"), str) or journal.get("phase") not in {"backing-up", "copying"}:
            raise UpgradeError("unknown Runtime transaction phase; recovery needs repair")
        # Phase "backing-up" means no instance byte had moved yet — there is
        # nothing to restore; discard the partial backup and the journal.
        if journal.get("phase") != "backing-up":
            ownership = self._validate_rollback_ownership(journal.get("rollback_ownership"))
            if "previous_activation" not in journal:
                raise UpgradeError("interrupted activation lacks prior ownership metadata; recovery needs repair")
            if journal["previous_activation"] is not None and not isinstance(journal["previous_activation"], dict):
                raise UpgradeError("interrupted activation has invalid prior ownership metadata")
            state = self.store.load() or {}
            if (state.get("instance_path") != journal.get("instance_path")
                    or state.get("candidate_version") != journal.get("candidate_version")
                    or state.get("candidate_digest") != journal.get("candidate_digest")
                    or state.get("rollback_version") != ownership["active_version"]):
                raise UpgradeError("interrupted activation journal does not match the candidate; recovery needs repair")
            previous = journal["previous_activation"]
            if previous is not None and (
                previous.get("retrieval") != ownership["retrieval"]
                or previous.get("active_version") != ownership["active_version"]
            ):
                raise UpgradeError("interrupted activation prior ownership is inconsistent; recovery needs repair")
            instance = Path(state["instance_path"])
            self._restore_from_backup(instance)
            self._restore_prior_activation(journal)
            state["status"] = STATUS_READY
            state["active_version"] = ownership["active_version"]
            self.store.write(state)
        self.store.clear_apply_journal()
        (self.store.root / "rollback-files.tar.gz").unlink(missing_ok=True)
        (self.store.root / "rollback-manifest.json").unlink(missing_ok=True)
        return True

    @staticmethod
    def _owned_skill_files(instance: Path, selected: Mapping[str, Path]) -> list[str]:
        """Organization-owned skill trees never become candidate-owned bytes."""
        try:
            config = json.loads((instance / "egregore.json").read_text(encoding="utf-8"))
            owned = config.get("owned_skills", [])
            if (not isinstance(owned, list) or any(
                not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_-]+", name)
                for name in owned
            )):
                raise ValueError("invalid owned skill names")
        except (OSError, ValueError, AttributeError) as exc:
            raise UpgradeError("cannot read owned skill configuration; repair it before upgrading") from exc
        prefixes = tuple(f"{directory}/{name}/" for directory in (
            ".claude/skills", ".codex/skills", ".pi/skills", ".prime/agent/skills",
        ) for name in owned)
        # Match lexical paths only: do not follow skills links to any target.
        return sorted(relative for relative in selected if relative.startswith(prefixes))

    def _apply_candidate_bytes(
        self, state: dict[str, Any], rollback_ownership: dict[str, Any],
    ) -> dict[str, Any]:
        """Copy the installed candidate bundle into the instance under a
        durable journal: complete backup before any mutation, per-file digest
        verification after every copy, and restoration of the exact previous
        tree on any failure. The caller writes the activation record only
        after this returns."""
        import shutil
        import tarfile

        package_root = Path(state.get("installed_path") or "")
        if not (package_root / "runtime" / APPLY_TREES[0]).is_dir():
            raise UpgradeError("candidate bundle tree is missing; re-run preparation")
        instance = Path(state["instance_path"])
        replaced: list[str] = []
        added: list[str] = []
        selected: dict[str, Path] = {}
        for tree_name in APPLY_TREES:
            tree = package_root / "runtime" / tree_name
            if not tree.is_dir():
                continue
            for source_file in tree.rglob("*"):
                if not source_file.is_file():
                    continue
                relative = str(source_file.relative_to(tree))
                selected.setdefault(relative, source_file)
        # The bundle's own manifest describes the package, not the instance;
        # nothing in an instance reads it and it only shows up as an untracked
        # file in the instance's repository.
        selected.pop(BUNDLE_MANIFEST, None)
        # The instance's own settings adapter may carry hook events or
        # permission allows the generated public-safe adapter lacks (an org's
        # committed .claude/settings.json). Activation never reduces it — the
        # same rule the installer applies. A stale generated adapter (equal or
        # a subset) still upgrades.
        preserved = self._owned_skill_files(instance, selected)
        for relative in preserved:
            selected.pop(relative)
        candidate_settings = selected.get(SETTINGS_ADAPTER)
        if candidate_settings is not None and _settings_carries_more(
            instance / SETTINGS_ADAPTER, candidate_settings
        ):
            selected.pop(SETTINGS_ADAPTER, None)
            preserved.append(SETTINGS_ADAPTER)
        codex_settings = selected.get(CODEX_SETTINGS_ADAPTER)
        if codex_settings is not None and _preserve_codex_settings(
            instance, self.store.load_activation()
        ):
            selected.pop(CODEX_SETTINGS_ADAPTER, None)
            preserved.append(CODEX_SETTINGS_ADAPTER)
        # Pi/Prime settings hold user preferences and resource paths. Their
        # Runtime extensions load automatically; installation does not require
        # replacing existing settings with package defaults.
        for relative in NATIVE_SETTINGS_ADAPTERS:
            config = instance / relative
            if relative in selected and (config.exists() or config.is_symlink()):
                selected.pop(relative)
                preserved.append(relative)
        before_prompt_adapters = set(selected)
        legacy_prompt = {}
        prompt_compatibility = self._codex_rollback_compatibility(
            instance, selected, rollback_ownership, legacy_prompt=legacy_prompt,
        )
        prompt_compatibility.update(self._claude_rollback_compatibility(instance, selected, rollback_ownership))
        preserved.extend(sorted(before_prompt_adapters - set(selected)))
        managed_config_hashes = {
            relative: self._sha256(selected[relative])
            for relative in (CODEX_SETTINGS_ADAPTER, *NATIVE_SETTINGS_ADAPTERS)
            if relative in selected
        }
        # Git cleanliness does not make a linked destination safe. Check every
        # file and parent before opening the journal or backing up any bytes;
        # copy2 follows destination links, including links inside a tracked tree.
        # Preserved org-owned paths are not selected and remain untouched.
        for relative in selected:
            destination = instance / relative
            # copy2 treats a directory destination as a container and appends
            # the source basename, which could select an unchecked child link.
            if destination.exists() and not destination.is_file():
                raise UpgradeError(
                    f"Runtime destination is not a regular file: {relative}; "
                    "repair the destination before upgrading"
                )
            while destination != instance:
                if destination.is_symlink():
                    raise UpgradeError(
                        f"Runtime destination contains a symbolic link: {destination.relative_to(instance)}; "
                        "replace it with an instance-local file or directory before upgrading"
                    )
                destination = destination.parent
        # Journal opens the transaction BEFORE the first byte moves. From here
        # until the caller clears it, a crash is recoverable from the backup.
        journal = {
            "phase": "backing-up",
            "pid": os.getpid(),
            "started_at": _now(),
            "instance_path": str(instance),
            "candidate_version": state.get("candidate_version"),
            "candidate_digest": state.get("candidate_digest"),
            "rollback_ownership": rollback_ownership,
            "previous_activation": self.store.load_activation(),
        }
        self.store.write_apply_journal(journal)
        backup_path = self.store.root / "rollback-files.tar.gz"
        with tarfile.open(backup_path, "w:gz") as backup:
            for relative in sorted(selected):
                destination = instance / relative
                if destination.exists():
                    backup.add(destination, arcname=relative)
                    replaced.append(relative)
                else:
                    added.append(relative)
        manifest = {
            "replaced": replaced, "added": added, "trees": list(APPLY_TREES),
            "prompt_compatibility": prompt_compatibility,
            "legacy_prompt_handler": legacy_prompt,
            "rollback_ownership": rollback_ownership,
        }
        if rollback_ownership["source"] == "legacy-template":
            manifest["backup_sha256"] = self._sha256(backup_path)
            journal["backup_sha256"] = manifest["backup_sha256"]
        (self.store.root / "rollback-manifest.json").write_text(
            json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
        )
        journal["phase"] = "copying"
        self.store.write_apply_journal(journal)
        try:
            for relative in sorted(selected):
                destination = instance / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(selected[relative], destination)
                if self._sha256(destination) != self._sha256(selected[relative]):
                    raise UpgradeError(f"verification failed after copying {relative}")
        except BaseException:
            # Any failure mid-apply restores the complete original tree; the
            # instance is never left as a mixture. Order matters: the journal
            # clears only AFTER the restore, and the backup is deleted only
            # after the journal — so a second crash inside this cleanup still
            # leaves a recoverable (journal + backup) pair, never a journal
            # with no backup behind it.
            self._restore_from_backup(instance)
            self.store.clear_apply_journal()
            (self.store.root / "rollback-files.tar.gz").unlink(missing_ok=True)
            (self.store.root / "rollback-manifest.json").unlink(missing_ok=True)
            raise
        return {
            "applied_files": len(selected),
            "replaced": len(replaced),
            "added": len(added),
            "preserved": preserved,
            "managed_config_hashes": managed_config_hashes,
            "prompt_compatibility": {path: entry["sha256"] for path, entry in prompt_compatibility.items()},
            "legacy_prompt_handler": legacy_prompt,
            **({"backup_sha256": manifest["backup_sha256"]} if "backup_sha256" in manifest else {}),
        }

    def activate(self) -> dict[str, Any]:
        self._acquire_apply_lock()
        try:
            # A journal left by a crashed apply is recovered FIRST: the
            # original tree comes back and the retry starts clean.
            self.recover_interrupted_apply()
            state = self.store.load()
            if state is None or state.get("status") != STATUS_READY:
                raise UpgradeError(
                    "the candidate Runtime is not ready to activate; every gate must pass first"
                )
            gates = state.get("gates", {})
            if any(value is False for value in gates.values()):
                raise UpgradeError("activation refused: a recorded gate is failing")
            # The recorded tarball digest must still match the bytes on disk —
            # a swapped or corrupted candidate never activates.
            source = Path(state.get("candidate_source") or "")
            if not source.is_file() or self._sha256(source) != state.get("candidate_digest"):
                raise UpgradeError("candidate package digest no longer matches; re-run preparation")
            rollback_ownership = self._rollback_ownership(state)
            applied = self._apply_candidate_bytes(state, rollback_ownership)
            record = {
                "schema_version": SCHEMA_VERSION,
                "active_version": state["candidate_version"],
                "rollback_version": state["rollback_version"],
                "rollback_ownership": rollback_ownership,
                "source_revision": state["source_revision"],
                "semantic_revision": state["semantic_revision"],
                "candidate_digest": state["candidate_digest"],
                "installed_path": state["installed_path"],
                "applied": applied,
                "managed_config_hashes": applied["managed_config_hashes"],
                "activated_at": _now(),
                "retrieval": "runtime-qmd",
                "graph_retrieval": "not-used-by-this-runtime",
            }
            # The activation record is written only after every candidate file
            # has been applied and digest-verified. The journal clears only
            # after the record lands — a crash at any earlier point recovers
            # to the exact previous tree, never to an active-but-mixed state.
            self.store.write_activation(record)
            state["status"] = STATUS_ACTIVE
            state["active_version"] = state["candidate_version"]
            self.store.write(state)
            self.store.clear_apply_journal()
            return state
        finally:
            self._release_apply_lock()

    def rollback(self) -> dict[str, Any]:
        self._acquire_apply_lock()
        try:
            self.recover_interrupted_apply()
            return self._rollback_locked()
        finally:
            self._release_apply_lock()

    def _rollback_locked(self) -> dict[str, Any]:
        state = self.store.load()
        if state is None:
            raise UpgradeError("no upgrade state exists for this instance")
        if state.get("status") == STATUS_ROLLED_BACK:
            return state
        if state.get("status") != STATUS_ACTIVE:
            raise UpgradeError("no fully activated candidate is available to roll back")
        activation = self.store.load_activation() or {}
        target = activation.get("rollback_version") or state.get("rollback_version")
        if not target:
            raise UpgradeError("no rollback version is recorded for this instance")
        ownership = self._validate_rollback_ownership(activation.get("rollback_ownership"))
        if ownership["active_version"] != target:
            raise UpgradeError("rollback version and ownership metadata disagree; no files were restored")
        try:
            manifest = json.loads((self.store.root / "rollback-manifest.json").read_text(encoding="utf-8"))
        except (OSError, ValueError) as exc:
            raise UpgradeError("rollback backup metadata is unavailable; no files were restored") from exc
        if not isinstance(manifest, dict) or manifest.get("rollback_ownership") != ownership:
            raise UpgradeError("rollback backup lacks matching ownership metadata; no files were restored")
        if not (self.store.root / "rollback-files.tar.gz").is_file():
            raise UpgradeError("rollback backup is missing; no files were restored")
        if ownership["source"] == "legacy-template":
            digest = (activation.get("applied") or {}).get("backup_sha256")
            if (not isinstance(digest, str) or manifest.get("backup_sha256") != digest
                    or self._sha256(self.store.root / "rollback-files.tar.gz") != digest):
                raise UpgradeError("legacy rollback backup digest differs; no files were restored")
        compatibility = self._validate_prompt_compatibility(manifest.get("prompt_compatibility", {}))
        expected_compatibility = (activation.get("applied") or {}).get("prompt_compatibility", {})
        if expected_compatibility != {path: entry["sha256"] for path, entry in compatibility.items()}:
            raise UpgradeError("rollback prompt compatibility differs from activation; no files were restored")
        legacy_handler = manifest.get("legacy_prompt_handler", {})
        if legacy_handler != (activation.get("applied") or {}).get("legacy_prompt_handler", {}):
            raise UpgradeError("legacy rollback prompt metadata differs from activation; no files were restored")
        legacy_restore = self._legacy_prompt_rollback_plan(Path(state["instance_path"]), legacy_handler)
        record = {
            **ownership["provenance"],
            "schema_version": SCHEMA_VERSION,
            "active_version": target,
            "rollback_version": target,
            "prompt_compatibility": {path: entry["sha256"] for path, entry in compatibility.items()},
            "rolled_back_from": state.get("candidate_version"),
            "rolled_back_at": _now(),
            "retrieval": ownership["retrieval"],
        }
        journal = {
            "phase": "rolling-back", "pid": os.getpid(), "started_at": _now(),
            "instance_path": state["instance_path"],
            "rollback_ownership": ownership, "restored_activation": record,
            "active_config_hashes": activation.get("managed_config_hashes", {}),
            "prompt_compatibility": compatibility,
            "legacy_prompt_handler": legacy_handler, "legacy_prompt_restore": legacy_restore,
            **({"backup_sha256": manifest["backup_sha256"]} if ownership["source"] == "legacy-template" else {}),
        }
        self.store.write_apply_journal(journal)
        return self._finish_rollback(journal)

    def _finish_rollback(self, journal: Mapping[str, Any]) -> dict[str, Any]:
        """Replay safely after any interruption between byte and metadata restore."""
        ownership = self._validate_rollback_ownership(journal.get("rollback_ownership"))
        record = journal.get("restored_activation")
        if (not isinstance(record, dict) or record.get("retrieval") != ownership["retrieval"]
                or record.get("active_version") != ownership["active_version"]
                or (ownership["source"] == "legacy-template" and record.get("baseline") != ownership["baseline"])):
            raise UpgradeError("rollback journal ownership is inconsistent; recovery needs repair")
        state = self.store.load()
        if state is None or state.get("instance_path") != journal.get("instance_path"):
            raise UpgradeError("rollback journal does not match this installation; recovery needs repair")
        self._restore_from_backup(Path(journal["instance_path"]))
        self.store.write_activation(record)
        state["status"] = STATUS_ROLLED_BACK
        state["active_version"] = ownership["active_version"]
        self.store.write(state)
        self.store.clear_apply_journal()
        return state

    def cancel(self) -> dict[str, Any]:
        state = self.store.load()
        if state is None:
            raise UpgradeError("no upgrade state exists for this instance")
        self.store.request_cancel()
        worker = state.get("worker") or {}
        pid = worker.get("pid")
        status = state.get("status")
        if status in (STATUS_PENDING, STATUS_READY, STATUS_FAILED):
            # Nothing is running: release the staged candidate outright so a
            # newer one can be staged. A ready or failed candidate used to be
            # unreleasable — cancel ignored it and init refused "already staged".
            state["status"] = STATUS_CANCELLED
            self.store.write(state)
        elif status == STATUS_PREPARING and not (pid and _pid_alive(pid)):
            # No live worker will observe the flag — record the cancel now.
            state["status"] = STATUS_CANCELLED
            self.store.write(state)
        return self.store.load() or state


__all__ = [
    "SCHEMA_VERSION",
    "STAGES",
    "STATUS_ACTIVE",
    "STATUS_CANCELLED",
    "STATUS_FAILED",
    "STATUS_PENDING",
    "STATUS_PREPARING",
    "STATUS_READY",
    "STATUS_ROLLED_BACK",
    "UpgradeEngine",
    "UpgradeError",
    "UpgradeStore",
    "describe",
    "new_state",
    "upgrade_root",
]
