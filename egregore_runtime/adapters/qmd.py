"""Local QMD implementation of the Egregore ``Retriever`` contract.

QMD-specific commands, query syntax, output parsing, model detection, and
daemon lifecycle are deliberately confined to this module.  Callers submit
typed domain requests and receive domain results.
"""

from __future__ import annotations

import hashlib
import hmac
import json
import os
import re
import shutil
import signal
import secrets
import socket
import stat
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from contextlib import contextmanager
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Mapping, Sequence

import fcntl

from egregore_runtime.contracts import (
    RetrievalHit,
    RetrievalMode,
    RetrievalRequest,
    RetrievalResult,
    RetrieverHealth,
)
from egregore_runtime.artifacts import (
    ArtifactSchemaError,
    canonical_artifact_id,
    split_frontmatter,
)


QMD_VERSION = "2.8.3"
INDEX_SPEC_VERSION = "egregore-qmd-local/v2"
RUNTIME_SCHEMA_VERSION = "egregore-qmd-runtime/v1"
EMBEDDING_MODEL = "EmbeddingGemma"
MAX_AUTHORIZED_CANDIDATES = 2_000
MAX_SDK_PASSAGE_CHARACTERS = 4_000
# Every query this adapter issues — daemon and CLI — disables model
# reranking; results come from typed lex/vec rank fusion only. Readiness
# surfaces report this posture from here rather than restating it.
RERANKING_ENABLED = False


class QmdAdapterError(RuntimeError):
    """Raised when the pinned local retrieval adapter cannot execute safely."""


@dataclass(frozen=True, slots=True)
class _DocumentMetadata:
    artifact_id: str
    title: str | None = None
    artifact_type: str | None = None
    workstream: str | None = None
    revision: str | None = None
    content_hash: str | None = None
    observed_at: datetime | None = None
    date_provenance: str | None = None


@dataclass(frozen=True, slots=True)
class QmdRuntimeMetadata:
    schema_version: str
    instance_id: str
    generation: str
    pid: int
    port: int
    endpoint: str
    qmd_version: str
    index_spec_version: str
    index_name: str
    index_path: str
    collection: str
    memory_root: str
    started_at: str
    process_started_at: str
    engine_signature: str | None = None
    worker_token: str | None = None

    @classmethod
    def from_mapping(cls, value: Mapping[str, Any]) -> "QmdRuntimeMetadata":
        token = value.get('worker_token')
        if token is not None and (not isinstance(token, str) or not re.fullmatch(r'[a-f0-9]{64}', token)):
            raise ValueError('invalid worker token')
        if int(value['pid']) <= 0 or not 1 <= int(value['port']) <= 65535:
            raise ValueError('invalid worker process identity')
        return cls(
            schema_version=str(value["schema_version"]),
            instance_id=str(value["instance_id"]),
            generation=str(value["generation"]),
            pid=int(value["pid"]),
            port=int(value["port"]),
            endpoint=str(value["endpoint"]),
            qmd_version=str(value["qmd_version"]),
            index_spec_version=str(value["index_spec_version"]),
            index_name=str(value["index_name"]),
            index_path=str(value["index_path"]),
            collection=str(value["collection"]),
            memory_root=str(value["memory_root"]),
            started_at=str(value["started_at"]),
            process_started_at=str(value["process_started_at"]),
            engine_signature=str(value['engine_signature']) if value.get('engine_signature') else None,
            worker_token=token,
        )

    def to_dict(self) -> dict[str, str | int]:
        return {
            "schema_version": self.schema_version,
            "instance_id": self.instance_id,
            "generation": self.generation,
            "pid": self.pid,
            "port": self.port,
            "endpoint": self.endpoint,
            "qmd_version": self.qmd_version,
            "index_spec_version": self.index_spec_version,
            "index_name": self.index_name,
            "index_path": self.index_path,
            "collection": self.collection,
            "memory_root": self.memory_root,
            "started_at": self.started_at,
            "process_started_at": self.process_started_at,
            "engine_signature": self.engine_signature,
            "worker_token": self.worker_token,
        }


class QmdLocalRetriever:
    """QMD 2.8.3-backed local retriever with explicit typed rank fusion.

    The persistent loopback daemon is preferred because it keeps local models
    warm.  Every daemon request supplies ``searches`` (never QMD's untyped
    expansion input) and disables reranking.  The exact same typed query is
    used by the pinned CLI fallback.
    """

    def __init__(
        self,
        *,
        repository_root: Path,
        memory_root: Path | None = None,
        collection: str | None = None,
        collection_purpose: str = "memory",
        qmd_command: Sequence[str] | None = None,
        environment: Mapping[str, str] | None = None,
    ) -> None:
        self.repository_root = repository_root.resolve()
        configured_memory = memory_root or self.repository_root / "memory"
        self.memory_root = configured_memory.resolve()
        self.environment = dict(os.environ if environment is None else environment)
        self.collection_purpose = re.sub(
            r"[^A-Za-z0-9_.-]", "-", collection_purpose.strip()
        ) or "memory"
        self.collection = collection or self._default_collection()
        self.index_name = self.environment.get("EGREGORE_QMD_INDEX_NAME") or (
            f"egregore-{self.collection_purpose}-{self._instance_hash()[:12]}-v2"
        )
        self._configured_command = tuple(qmd_command) if qmd_command else None
        self._resolved_command: tuple[str, ...] | None = None
        self._version_checked = False
        self._daemon_available = False
        # Outcome of the most recent typed query: True when the owned worker
        # answered, False when the pinned CLI ran cold, None when no query
        # ran or persistence is disabled. Read by the harness so a slow
        # retrieval is never silent.
        self._last_query_used_daemon: bool | None = None
        self._source_revision_cache: str | None = None
        self._configure_isolated_environment()
        self._prefer_usable_node_runtime()

    def _configure_isolated_environment(self) -> None:
        """Give QMD its own database, config, PID files, logs, and models."""

        runtime = self._runtime_root()
        cache = runtime / "cache"
        config = runtime / "config"
        index = self._index_path()
        self.environment["INDEX_PATH"] = str(index)
        self.environment["QMD_CONFIG_DIR"] = str(config)
        self.environment["XDG_CACHE_HOME"] = str(cache)
        self.environment["XDG_CONFIG_HOME"] = str(config)

    def _prefer_usable_node_runtime(self) -> None:
        """Put a working Node installation ahead of broken version-manager shims.

        Harnesses do not always inherit the interactive shell's fully expanded
        PATH.  In particular, Volta's shim directory can remain visible while
        the selected Node image directory is absent, causing every QMD/npm/npx
        shebang to fail with ``Node is not available``.  Validate candidates
        instead of trusting their presence, then prepend the first usable
        runtime without changing the parent process or the user's global Node
        configuration.
        """

        configured = self.environment.get("EGREGORE_QMD_NODE_BIN")
        path_value = self.environment.get("PATH", "")
        candidates: list[Path] = []
        if configured:
            candidates.append(Path(configured).expanduser())
        resolved = shutil.which("node", path=path_value)
        if resolved:
            candidates.append(Path(resolved))

        home = Path(self.environment.get("HOME", str(Path.home()))).expanduser()
        volta_images = home / ".volta" / "tools" / "image" / "node"
        if volta_images.is_dir():
            candidates.extend(
                sorted(
                    volta_images.glob("*/bin/node"),
                    key=lambda candidate: self._node_version_key(candidate),
                    reverse=True,
                )
            )
        candidates.extend((Path("/opt/homebrew/bin/node"), Path("/usr/local/bin/node")))

        seen: set[str] = set()
        for candidate in candidates:
            try:
                executable = candidate.resolve()
            except OSError:
                continue
            key = str(executable)
            if key in seen or not executable.is_file() or not os.access(executable, os.X_OK):
                continue
            seen.add(key)
            try:
                checked = subprocess.run(
                    (str(executable), "--version"),
                    cwd=self.repository_root,
                    env=self.environment,
                    text=True,
                    capture_output=True,
                    timeout=10,
                    check=False,
                    umask=0o077,
                )
            except (OSError, subprocess.TimeoutExpired):
                continue
            if checked.returncode != 0 or not re.search(r"^v\d+\.\d+\.\d+", checked.stdout.strip()):
                continue
            node_dir = str(executable.parent)
            entries = [entry for entry in path_value.split(os.pathsep) if entry]
            entries = [entry for entry in entries if Path(entry).expanduser() != executable.parent]
            self.environment["PATH"] = os.pathsep.join((node_dir, *entries))
            self.environment["EGREGORE_QMD_NODE_BIN"] = str(executable)
            return

    @staticmethod
    def _node_version_key(candidate: Path) -> tuple[int, ...]:
        try:
            return tuple(int(part) for part in candidate.parents[1].name.split("."))
        except (ValueError, IndexError):
            return ()

    def _ensure_runtime_layout(self) -> None:
        runtime = self._runtime_root()
        for directory in (
            runtime,
            runtime / "cache",
            runtime / "config",
            self._index_path().parent,
            self._models_path(),
        ):
            directory.mkdir(parents=True, exist_ok=True, mode=0o700)
            self._ensure_private_mode(directory, 0o700)
        for private_file in (
            self._index_path(),
            self._runtime_state_path(),
            self._index_state_path(),
            self._semantic_state_path(),
        ):
            if private_file.exists():
                self._ensure_private_mode(private_file, 0o600)
        self._reuse_embedding_model()

    @staticmethod
    def _ensure_private_mode(path: Path, mode: int) -> None:
        # A preprovisioned private cache should not require permission-changing
        # authority on every query. An unsafe mode must still be repaired or
        # rejected by the host, never silently accepted.
        if stat.S_IMODE(path.stat().st_mode) != mode:
            os.chmod(path, mode)

    def _reuse_embedding_model(self) -> None:
        if self._embedding_model_available():
            return
        configured = (
            self.environment.get("EGREGORE_QMD_REUSE_EMBEDDING_MODEL")
            or self.environment.get("EGREGORE_QMD_MODELS_PATH")
        )
        candidates: list[Path] = []
        if configured:
            configured_path = Path(configured).expanduser()
            if configured_path.is_dir():
                candidates.extend(sorted(configured_path.glob("*embeddinggemma*")))
            else:
                candidates.append(configured_path)
        home = Path(self.environment.get("HOME", str(Path.home()))).expanduser()
        candidates.extend(
            sorted((home / ".cache" / "qmd" / "models").glob("*embeddinggemma*"))
        )
        target_dir = self._models_path()
        for source in candidates:
            if not source.is_file():
                continue
            target = target_dir / source.name
            if not target.exists():
                target.symlink_to(source.resolve())
            return

    def _runtime_root(self) -> Path:
        override = self.environment.get("EGREGORE_QMD_RUNTIME_DIR")
        if override:
            return Path(override).expanduser().resolve()
        home = Path(self.environment.get("HOME", str(Path.home()))).expanduser()
        return home / ".egregore" / "runtime" / "qmd" / self._instance_hash()

    def _runtime_state_path(self) -> Path:
        return self._runtime_root() / "runtime.json"

    def _lifecycle_lock_path(self) -> Path:
        return self._runtime_root() / "lifecycle.lock"

    @contextmanager
    def _lifecycle_lock(self):
        self._ensure_runtime_layout()
        path = self._lifecycle_lock_path()
        with path.open("a+", encoding="utf-8") as handle:
            self._ensure_private_mode(path, 0o600)
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)

    # -- Retriever contract -------------------------------------------------

    def health(self) -> RetrieverHealth:
        try:
            return self._health()
        except OSError as exc:
            # Do not continue probing files after a sandbox/filesystem failure
            # or report stale readiness from an incompletely inspected cache.
            return self._filesystem_unavailable_health(exc)

    def _filesystem_unavailable_health(self, exc: OSError) -> RetrieverHealth:
        return RetrieverHealth(
            available=False, adapter="qmd-local", adapter_version=QMD_VERSION,
            index_spec_version=INDEX_SPEC_VERSION,
            index_revision="unavailable", source_revision="unavailable",
            embedding_state="unavailable", runtime_state="runtime_unavailable",
            warnings=(self._filesystem_recovery_message(exc),),
        )

    @staticmethod
    def _filesystem_recovery_message(exc: OSError) -> str:
        return (
            f"Local retrieval storage is unavailable ({type(exc).__name__}: {exc}). "
            "Provision the instance cache with private permissions and the host's "
            "required read/write access, then retry readiness."
        )

    def _health(self) -> RetrieverHealth:
        warnings: list[str] = []
        canonical_ready = self.memory_root.is_dir()
        qmd_available = True
        if not canonical_ready:
            warnings.append(f"canonical memory is unavailable: {self.memory_root}")

        try:
            self._ensure_runtime_layout()
            self._ensure_version()
        except QmdAdapterError as exc:
            qmd_available = False
            warnings.append(str(exc))

        status = ""
        status_ok = False
        if canonical_ready and qmd_available:
            completed = self._run(("status",), timeout=20)
            if completed.returncode == 0:
                status = completed.stdout
                status_ok = True
            else:
                warnings.append(self._failure_message("qmd status", completed))

        counts = self._status_counts(status)
        # BM25 readiness is usability, mirroring the semantic split: a
        # canonical write leaves the index trailing, not unusable — queries
        # refresh it inline. Only an identity mismatch makes it stale.
        bm25_ready = bool(
            status_ok
            and counts["documents"] > 0
            and self._index_state_usable()
        )
        # Semantic queries embed the query text at request time, so the model
        # must be present even when every stored vector is current. Stored
        # vectors without the model is a repair state, never "ready".
        model_available = self._embedding_model_available()
        semantic_ready = bool(
            bm25_ready
            and model_available
            and counts["vectors"] > 0
            and counts["pending"] == 0
            and self._semantic_state_current()
            and not self._live_lock(self._embed_lock_path())
        )
        embedding_state = self._embedding_state(status, semantic_ready=semantic_ready)
        if embedding_state == "missing_model":
            if counts["vectors"] > 0:
                warnings.append(
                    f"{EMBEDDING_MODEL} is missing while stored vectors are intact; "
                    "semantic queries are unavailable until repair — run: bin/search.sh reindex --embed"
                )
            else:
                warnings.append(
                    f"{EMBEDDING_MODEL} is not installed; hybrid requests degrade to lexical retrieval while embedding warms"
                )

        runtime = self._owned_runtime()
        if not canonical_ready or not qmd_available or not status_ok:
            runtime_state = "runtime_unavailable"
        elif self._persistent_enabled() and runtime is None:
            runtime_state = "runtime_unavailable"
        elif not self._index_state_usable() and self._index_path().exists():
            runtime_state = "runtime_stale"
        elif not bm25_ready:
            runtime_state = "canonical_state_ready"
        elif not semantic_ready:
            runtime_state = "semantic_index_building"
        else:
            runtime_state = "semantic_ready"

        return RetrieverHealth(
            available=canonical_ready and qmd_available and status_ok,
            adapter="qmd-local",
            adapter_version=QMD_VERSION,
            index_spec_version=INDEX_SPEC_VERSION,
            index_revision=self._index_revision(),
            source_revision=self._source_revision(),
            embedding_state=embedding_state,
            warnings=tuple(warnings),
            canonical_state_ready=canonical_ready,
            bm25_ready=bm25_ready,
            semantic_ready=semantic_ready,
            runtime_state=runtime_state,
            runtime_pid=runtime.pid if runtime else None,
            runtime_endpoint=runtime.endpoint if runtime else None,
            index_path=str(self._index_path()),
            collection=self.collection,
            index_source_revision=self._indexed_source_revision(),
            semantic_source_revision=self._semantic_source_revision(),
        )

    def start(self) -> RetrieverHealth:
        """Bring BM25 online, start/reuse the owned worker, then embed async."""

        warnings: list[str] = []
        self._source_revision_cache = None
        try:
            self._ensure_ready(warnings)
        except OSError as exc:
            raise QmdAdapterError(self._filesystem_recovery_message(exc)) from exc
        if not self._ensure_daemon():
            warnings.append("instance-owned QMD worker is unavailable; CLI fallback remains active")
        if not self._semantic_state_current():
            self._schedule_embed()
        health = self.health()
        if not warnings:
            return health
        return replace(health, warnings=tuple((*health.warnings, *warnings)))

    def shutdown(self) -> RetrieverHealth:
        """Stop only a worker whose full instance/process identity is proven."""

        with self._lifecycle_lock():
            runtime = self._owned_runtime()
            if runtime is not None:
                self._terminate_owned_worker(runtime)
            self._runtime_state_path().unlink(missing_ok=True)
            self._daemon_available = False
        return self.health()

    def _diagnostic_trace(self, phase: str, milliseconds: int, **extra: Any) -> None:
        """Local-only latency diagnostics, independent of telemetry consent.

        EGREGORE_RETRIEVAL_TRACE=1 appends one JSON line per phase to
        retrieval-trace.jsonl inside the instance runtime dir. Content-free
        by construction: phases, timings, counts — never queries or text.
        """

        if self.environment.get("EGREGORE_RETRIEVAL_TRACE") != "1":
            return
        try:
            line = json.dumps(
                {
                    "at": datetime.now(UTC).isoformat(),
                    "phase": phase,
                    "ms": milliseconds,
                    **extra,
                },
                sort_keys=True,
            )
            trace_path = self._runtime_root() / "retrieval-trace.jsonl"
            with trace_path.open("a", encoding="utf-8") as handle:
                handle.write(line + "\n")
            os.chmod(trace_path, 0o600)
        except OSError:
            pass

    def retrieve(self, request: RetrievalRequest) -> RetrievalResult:
        try:
            return self._retrieve(request)
        except OSError as exc:
            raise QmdAdapterError(self._filesystem_recovery_message(exc)) from exc

    def describe_source(self, canonical_path: str) -> _DocumentMetadata:
        """Canonical metadata for a path already authorized by Runtime."""
        return self._metadata(canonical_path)

    def retrieve_authorized(self, request, *, actor, admin_gate=None, lifecycle=None,
                            path_filter=None, metadata_filter=None):
        from ..eligibility import build_eligibility
        try:
            return self._retrieve(request, eligibility_builder=lambda: build_eligibility(
                self, request, actor=actor, admin_gate=admin_gate, lifecycle=lifecycle,
                path_filter=path_filter, metadata_filter=metadata_filter))
        except OSError as exc:
            raise QmdAdapterError(self._filesystem_recovery_message(exc)) from exc

    def _query_scoped(self, searches, limit, intent, eligibility):
        from .qmd_scoped import query_scoped
        try:
            return query_scoped(self, searches, limit, intent, eligibility)
        except RuntimeError as exc:
            raise QmdAdapterError(str(exc)) from exc

    def source_revision(self) -> str:
        """Fresh canonical revision for a continued investigation."""
        self._source_revision_cache = None
        return self._source_revision()

    def index_revision(self) -> str:
        return self._index_revision()

    def _retrieve(self, request: RetrievalRequest, *, eligibility_builder=None) -> RetrievalResult:
        started = time.monotonic()
        warnings: list[str] = []
        # A long-lived runtime may observe a new canonical Git revision between
        # requests. Cache only within one retrieval operation.
        self._source_revision_cache = None
        self._ensure_ready(warnings)

        eligibility = eligibility_builder() if eligibility_builder else None
        metadata_by_path = ({document.canonical_path: document.metadata
                             for document in eligibility.documents} if eligibility else None)
        coverage = {}
        if eligibility:
            warnings.extend(eligibility.warnings)

        requested_mode = request.mode
        executed_mode = requested_mode
        if requested_mode in (RetrievalMode.HYBRID, RetrievalMode.VEC):
            # Hybrid retrieval stays available across canonical writes: the
            # last complete vectors keep serving alongside current BM25 while
            # a newer embedding builds. Lexical fallback happens only when no
            # usable vector build exists at all.
            if not self._semantic_state_usable():
                executed_mode = RetrievalMode.LEX
                warnings.append(
                    "no usable vector index exists yet; request used lexical fallback and embedding was scheduled"
                )

        searches = self._typed_searches(request, executed_mode)
        if not searches:
            raise QmdAdapterError(
                f"retrieval request {request.request_id!r} has no {executed_mode.value} query"
            )

        candidate_limit = max(request.top_k * 8, 64)
        raw_hits: list[dict[str, Any]]
        def query():
            if eligibility is None:
                return self._query(searches, candidate_limit, request.task)
            scoped = self._query_scoped(searches, candidate_limit, request.task, eligibility)
            coverage.update(scoped['coverage'])
            warnings.extend(scoped.get('warnings', ()))
            return scoped['results']
        try:
            raw_hits = query()
        except QmdAdapterError as exc:
            if executed_mode is RetrievalMode.LEX or eligibility is not None:
                raise
            warnings.append(f"typed {executed_mode.value} retrieval failed: {exc}; used lexical fallback")
            executed_mode = RetrievalMode.LEX
            searches = self._typed_searches(request, executed_mode)
            if not searches:
                raise
            raw_hits = self._query(searches, candidate_limit, request.task)

        hits = self._authorized_hits(raw_hits, request, executed_mode, metadata_by_path)
        while (
            eligibility is None
            and len(hits) < request.top_k
            and len(raw_hits) >= candidate_limit
            and candidate_limit < MAX_AUTHORIZED_CANDIDATES
        ):
            candidate_limit = min(candidate_limit * 4, MAX_AUTHORIZED_CANDIDATES)
            raw_hits = self._query(searches, candidate_limit, request.task)
            hits = self._authorized_hits(raw_hits, request, executed_mode)
        if len(hits) < request.top_k and len(raw_hits) >= MAX_AUTHORIZED_CANDIDATES:
            warnings.append(
                "authorized candidates may be incomplete after bounded policy-safe overfetch"
            )
        self._schedule_embed()
        if eligibility is not None:
            if self.source_revision() != eligibility.source_revision:
                raise QmdAdapterError('sources changed during scoped retrieval; retry the operation')
            coverage.update(eligibility_ms=eligibility.latency_ms,
                            unknown_date_count=eligibility.unknown_dates,
                            canonical_source_revision=eligibility.source_revision)
            if eligibility.warnings:
                coverage['eligibility_complete'] = False
        latency_ms = round((time.monotonic() - started) * 1000)
        self._diagnostic_trace(
            "retrieve",
            latency_ms,
            mode=executed_mode.value,
            requested_mode=requested_mode.value,
            hits=len(hits[: request.top_k]),
            degraded=executed_mode is not requested_mode or bool(warnings),
        )
        return RetrievalResult(
            request_id=request.request_id,
            mode=executed_mode,
            requested_mode=requested_mode,
            hits=tuple(hits[: request.top_k]),
            index_spec_version=INDEX_SPEC_VERSION,
            index_revision=self._index_revision(),
            source_revision=self._source_revision(),
            latency_ms=latency_ms,
            degraded=executed_mode is not requested_mode or bool(warnings),
            warnings=tuple(warnings),
            coverage=coverage,
            semantic_source_revision=(
                self._semantic_source_revision()
                if executed_mode in (RetrievalMode.HYBRID, RetrievalMode.VEC)
                else None
            ),
        )

    def open_source(self, hit: RetrievalHit) -> str:
        started = time.monotonic()
        source = self._source_path(hit.canonical_path)
        if not source.is_file():
            raise QmdAdapterError(f"canonical source is unavailable: {hit.canonical_path}")
        content = source.read_text(encoding="utf-8")
        self._diagnostic_trace(
            "open_source",
            round((time.monotonic() - started) * 1000),
            bytes=len(content),
        )
        return content

    def update(self, paths: Sequence[str] = (), *, force: bool = False) -> RetrieverHealth:
        # QMD's update is already incremental.  Its v2.8.3 CLI scans registered
        # collections rather than accepting individual paths, so ``paths`` is a
        # writeback hint rather than a different command shape.
        del paths
        try:
            self._source_revision_cache = None
            if not force and self._index_state_current():
                # The index already matches the exact canonical revision — there
                # is nothing to scan. Boot-path syncs stop paying QMD subprocess
                # spawns for an unchanged corpus; any revision change (including
                # a dirty-tree hash change) still takes the full update path.
                return self.health()
            # A canonical write makes the semantic build stale, never unusable:
            # staleness is expressed by revision inequality alone, and the last
            # complete vector receipt persists so hybrid keeps serving while the
            # next embedding builds.
            self._ensure_collection(force=True)
            completed = self._run(("update",), timeout=300)
            if completed.returncode != 0:
                raise QmdAdapterError(self._failure_message("qmd update", completed))
            self._write_index_state()
            return self.health()
        except OSError as exc:
            return self._filesystem_unavailable_health(exc)

    def embed_background(self) -> RetrieverHealth:
        # Snapshot health before starting the worker. Once QMD begins embedding
        # it may hold SQLite's writer lock, so a status call made afterwards can
        # turn this nominally background operation into a foreground wait.
        health = self.health()
        if not self._schedule_embed():
            return health
        return replace(
            health,
            embedding_state="running",
            semantic_ready=False,
            runtime_state="semantic_index_building",
        )

    def install_managed(self) -> Path:
        """Provision the exact Local runtime for later offline use."""

        npm = shutil.which("npm", path=self.environment.get("PATH"))
        if not npm:
            raise QmdAdapterError(f"cannot install QMD {QMD_VERSION}: npm is unavailable")
        prefix = self._managed_prefix()
        prefix.mkdir(parents=True, exist_ok=True, mode=0o700)
        completed = self._run_raw(
            (
                npm,
                "install",
                "--prefix",
                str(prefix),
                "--no-save",
                "--no-package-lock",
                f"@tobilu/qmd@{QMD_VERSION}",
            ),
            timeout=900,
        )
        if completed.returncode != 0:
            raise QmdAdapterError(self._failure_message("managed qmd install", completed))
        binary = self._managed_binary()
        if not binary.is_file() or not os.access(binary, os.X_OK):
            raise QmdAdapterError("managed QMD install completed without an executable")
        self._resolved_command = (str(binary),)
        self._version_checked = False
        self._ensure_version()
        return binary

    def _schedule_embed(self) -> bool:
        if self.environment.get("EGREGORE_SEARCH_NO_WARM", "0") == "1":
            return False
        if self._semantic_state_current():
            return False

        with self._lifecycle_lock():
            lock = self._embed_lock_path()
            if self._live_lock(lock):
                return True
            lock.parent.mkdir(parents=True, exist_ok=True)
            source_revision = self._source_revision()
            command = [
                sys.executable,
                "-m",
                "egregore_runtime.adapters.qmd_embed_worker",
                "--repository-root",
                str(self.repository_root),
                "--memory-root",
                str(self.memory_root),
                "--collection",
                self.collection,
                "--collection-purpose",
                self.collection_purpose,
                "--source-revision",
                source_revision,
            ]
            worker_environment = dict(self.environment)
            package_root = str(Path(__file__).resolve().parents[2])
            existing_pythonpath = worker_environment.get("PYTHONPATH")
            worker_environment["PYTHONPATH"] = (
                f"{package_root}{os.pathsep}{existing_pythonpath}"
                if existing_pythonpath
                else package_root
            )
            try:
                process = subprocess.Popen(
                    command,
                    cwd=self.repository_root,
                    env=worker_environment,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    start_new_session=True,
                    umask=0o077,
                )
            except OSError as exc:
                raise QmdAdapterError(f"could not start background embedding: {exc}") from exc
            self._atomic_json(
                lock,
                {
                    "pid": process.pid,
                    "started_at": int(time.time()),
                    "source_revision": source_revision,
                    "index_spec_version": INDEX_SPEC_VERSION,
                },
            )
            return True

    # Explicit maintenance operation used by the compatibility shell adapter.
    def embed_foreground(self) -> RetrieverHealth:
        self._ensure_collection(force=True)
        # Read the covered revision before embedding: the vectors will cover
        # at least everything indexed now. Under-claiming is safe (the next
        # cycle re-embeds); claiming a revision the vectors do not cover
        # would silently strand newer documents without embeddings.
        covered_revision = self._indexed_source_revision()
        started = time.monotonic()
        completed = self._run(("embed", "-c", self.collection), timeout=3600)
        log = self._runtime_root() / "embedding.log"
        log.write_text(
            f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}\n",
            encoding="utf-8",
        )
        os.chmod(log, 0o600)
        if completed.returncode != 0:
            raise QmdAdapterError(self._failure_message("qmd embed", completed))
        self._source_revision_cache = None
        if covered_revision != "unknown":
            # Atomic advance: the semantic revision moves to what the vectors
            # actually represent — never to a newer canonical revision that
            # changed mid-embed. A stale-but-complete receipt keeps hybrid
            # serving until the next build completes.
            self._write_semantic_state(
                source_revision=covered_revision,
                duration_seconds=time.monotonic() - started,
            )
        return self.health()

    # -- Query execution ----------------------------------------------------

    def _query(
        self,
        searches: list[dict[str, str]],
        limit: int,
        intent: str,
    ) -> list[dict[str, Any]]:
        self._last_query_used_daemon = None
        if not self._persistent_enabled():
            daemon_error = "daemon unavailable"
        elif self._ensure_daemon():
            payload = {
                "searches": searches,
                "collections": [self.collection],
                "limit": limit,
                "candidateLimit": max(limit, 40),
                "rerank": False,
                "intent": intent,
            }
            try:
                from .qmd_scoped import signed_headers
                runtime = self._owned_runtime()
                if runtime is None:
                    raise QmdAdapterError('owned query worker identity changed')
                body = json.dumps(payload).encode('utf-8')
                request = urllib.request.Request(
                    f"{runtime.endpoint}/query",
                    data=body,
                    headers=signed_headers(body, runtime.worker_token),
                    method="POST",
                )
                with urllib.request.urlopen(request, timeout=30) as response:
                    body = json.loads(response.read().decode("utf-8"))
                results = body.get("results") if isinstance(body, dict) else None
                if isinstance(results, list):
                    self._last_query_used_daemon = True
                    return [item for item in results if isinstance(item, dict)]
            except (OSError, ValueError, urllib.error.URLError) as exc:
                self._daemon_available = False
                # A healthy daemon is only an accelerator; the pinned CLI is
                # the safe compatibility fallback.
                daemon_error = str(exc)
            else:
                daemon_error = "daemon returned an invalid result payload"
            self._last_query_used_daemon = False
        else:
            # The owned worker could not be started or reused. The pinned CLI
            # answers cold; the harness surfaces that instead of a silent
            # multi-second query.
            daemon_error = "daemon unavailable"
            self._last_query_used_daemon = False

        query_document = "\n".join(
            f"{item['type']}: {self._single_line(item['query'])}" for item in searches
        )
        completed = self._run(
            (
                "query",
                query_document,
                "-c",
                self.collection,
                "-n",
                str(limit),
                "--no-rerank",
                "--format",
                "json",
                "--full-path",
            ),
            timeout=60,
        )
        if completed.returncode != 0:
            message = self._failure_message("typed qmd query", completed)
            if daemon_error != "daemon unavailable":
                message = f"{message} (persistent path: {daemon_error})"
            raise QmdAdapterError(message)
        return self._parse_cli_results(completed.stdout)

    def _typed_searches(
        self, request: RetrievalRequest, mode: RetrievalMode
    ) -> list[dict[str, str]]:
        if mode is RetrievalMode.LEX:
            terms = request.lex or request.vec
            return [{"type": "lex", "query": term} for term in terms if term.strip()]
        if mode is RetrievalMode.VEC:
            terms = request.vec or request.lex
            return [{"type": "vec", "query": term} for term in terms if term.strip()]
        searches = [
            {"type": "lex", "query": term} for term in request.lex if term.strip()
        ]
        searches.extend(
            {"type": "vec", "query": term} for term in request.vec if term.strip()
        )
        return searches

    def _authorized_hits(
        self,
        raw_hits: Sequence[Mapping[str, Any]],
        request: RetrievalRequest,
        executed_mode: RetrievalMode,
        metadata_by_path=None,
    ) -> list[RetrievalHit]:
        accepted: list[tuple[Mapping[str, Any], str, _DocumentMetadata]] = []
        for raw in raw_hits:
            canonical_path = self._canonical_path(str(raw.get("file", "")))
            if canonical_path is None or not self._scope_allows(canonical_path, request):
                continue
            if metadata_by_path is not None and canonical_path not in metadata_by_path:
                raise QmdAdapterError('scoped QMD returned a document outside its eligible set')
            metadata = metadata_by_path[canonical_path] if metadata_by_path is not None else self._metadata(canonical_path)
            if request.allowed_artifact_ids and metadata.artifact_id not in request.allowed_artifact_ids:
                continue
            if request.artifact_types and metadata.artifact_type not in request.artifact_types:
                continue
            if request.workstream and metadata.workstream != request.workstream:
                continue
            if request.not_before is not None:
                if metadata.observed_at is None:
                    continue
                if metadata.observed_at < request.not_before.astimezone(UTC):
                    continue
            accepted.append((raw, canonical_path, metadata))

        # Exact canonical names are source-selection metadata, not generated
        # query terms or a model reranker. If the user names a returned title
        # verbatim, prefer that source while preserving QMD/RRF order otherwise.
        accepted.sort(
            key=lambda candidate: (
                0 if self._task_names_document(request.task, candidate[2]) else 1
            )
        )

        retrieval_types = {
            RetrievalMode.LEX: (RetrievalMode.LEX,),
            RetrievalMode.VEC: (RetrievalMode.VEC,),
            RetrievalMode.HYBRID: (RetrievalMode.LEX, RetrievalMode.VEC),
        }[executed_mode]
        return [
            RetrievalHit(
                artifact_id=metadata.artifact_id,
                canonical_path=canonical_path,
                rank=rank,
                score=float(raw.get("score") or 0),
                retrieval_types=retrieval_types,
                passage=self._passage(raw),
                passage_id=(
                    f"{metadata.artifact_id}:L{raw['line']}" if raw.get("line") else None
                ),
                revision=metadata.revision,
                content_hash=metadata.content_hash,
                observed_at=metadata.observed_at,
            )
            for rank, (raw, canonical_path, metadata) in enumerate(accepted, start=1)
        ]

    # -- QMD lifecycle ------------------------------------------------------

    def _ensure_ready(self, warnings: list[str]) -> None:
        if not self.memory_root.is_dir():
            raise QmdAdapterError(f"canonical memory is unavailable: {self.memory_root}")
        self._ensure_version()
        if self._index_state_current():
            return
        self._ensure_collection(force=True)
        completed = self._run(("update",), timeout=300)
        if completed.returncode != 0:
            warnings.append(
                self._failure_message(
                    "incremental qmd update",
                    completed,
                )
                + "; results may omit recent canonical writes"
            )
        else:
            self._write_index_state()

    def _ensure_collection(self, *, force: bool = False) -> None:
        self._ensure_version()
        if not force and self._index_state_current():
            return
        listed = self._run(("collection", "list"), timeout=30)
        names = self._collection_names(listed.stdout) if listed.returncode == 0 else ()
        for name in names:
            registered_path = self._collection_path(name)
            if name == self.collection:
                if registered_path == self.memory_root:
                    return
                raise QmdAdapterError(
                    f"QMD collection {name!r} belongs to {registered_path or 'an unknown path'}; "
                    "refusing to reuse a foreign corpus"
                )
            if registered_path == self.memory_root:
                # QMD permits only one collection registration per path. Keep
                # the existing disposable index and migrate its legacy name to
                # the instance-scoped name instead of deleting/re-embedding.
                renamed = self._run(
                    ("collection", "rename", name, self.collection), timeout=60
                )
                if renamed.returncode != 0:
                    raise QmdAdapterError(
                        self._failure_message("qmd collection name migration", renamed)
                    )
                return
        added = self._run(
            ("collection", "add", str(self.memory_root), "--name", self.collection),
            timeout=60,
        )
        if added.returncode != 0:
            raise QmdAdapterError(self._failure_message("qmd collection add", added))

    @staticmethod
    def _collection_names(output: str) -> tuple[str, ...]:
        return tuple(
            match.group(1)
            for match in re.finditer(
                r"^\s*([A-Za-z0-9_.-]+)\s+\(qmd://[^)]+/\)\s*$",
                output,
                re.MULTILINE,
            )
        )

    def _collection_path(self, name: str) -> Path | None:
        shown = self._run(("collection", "show", name), timeout=30)
        if shown.returncode != 0:
            return None
        match = re.search(r"^\s*Path:\s+(.+?)\s*$", shown.stdout, re.MULTILINE)
        if not match:
            return None
        return Path(match.group(1)).expanduser().resolve()

    def _ensure_version(self) -> None:
        if self._version_checked:
            return
        command = self._command()
        if self._version_checked:
            return
        completed = self._run_raw((*command, "--version"), timeout=20)
        output = f"{completed.stdout}\n{completed.stderr}"
        if completed.returncode != 0 or not re.search(
            rf"\b{re.escape(QMD_VERSION)}\b", output
        ):
            actual = output.strip() or f"exit {completed.returncode}"
            raise QmdAdapterError(f"QMD {QMD_VERSION} is required; adapter resolved {actual!r}")
        self._version_checked = True

    def _command(self) -> tuple[str, ...]:
        if self._resolved_command is not None:
            return self._resolved_command
        if self._configured_command:
            self._resolved_command = self._configured_command
            return self._resolved_command

        override = self.environment.get("EGREGORE_QMD_BIN")
        if override:
            self._resolved_command = (override,)
            return self._resolved_command

        managed = self._managed_binary()
        if managed.is_file() and os.access(managed, os.X_OK):
            self._resolved_command = (str(managed),)
            # The managed prefix embeds the exact pinned version in its path
            # (qmd-<QMD_VERSION>/) and install_managed verified the binary at
            # provisioning time — the same assertion the npx selector makes.
            # Skipping the per-process --version spawn saves a Node startup
            # on every boot-path health/status call.
            self._version_checked = True
            return self._resolved_command

        # Never a PATH global and never npx: those resolve through machine
        # state the Runtime does not own (a stale global or npx cache built
        # against another Node ABI produced exactly the dlopen failure the
        # Codex black-box hit). A missing managed install is provisioned now
        # into the instance-owned prefix; if that fails, retrieval fails as a
        # Runtime failure — degrading to unmanaged binaries is never correct.
        binary = self.install_managed()
        self._resolved_command = (str(binary),)
        self._version_checked = True
        return self._resolved_command

    def _managed_prefix(self) -> Path:
        """Install target for the managed QMD — instance-owned by default.

        A shared install couples every instance to whichever Node built its
        native modules; scoping the prefix to the instance runtime root keeps
        upgrades, ABI compatibility, and removal per-instance. An explicit
        EGREGORE_RUNTIME_ROOT keeps the historical shared layout for callers
        that opt into it.
        """
        runtime_root = self.environment.get("EGREGORE_RUNTIME_ROOT")
        if runtime_root:
            return Path(runtime_root).expanduser() / f"qmd-{QMD_VERSION}"
        return self._runtime_root() / f"qmd-{QMD_VERSION}"

    def _managed_binary(self) -> Path:
        instance = self._managed_prefix() / "node_modules" / ".bin" / "qmd"
        if instance.is_file():
            return instance
        # Existing installs provisioned the shared, version-addressed prefix;
        # keep resolving it so an upgrade is adoption, never breakage.
        legacy = Path.home() / ".egregore" / "runtime" / f"qmd-{QMD_VERSION}"
        legacy_binary = legacy / "node_modules" / ".bin" / "qmd"
        if legacy_binary.is_file():
            return legacy_binary
        return instance

    def _persistent_enabled(self) -> bool:
        return self.environment.get("EGREGORE_QMD_PERSISTENT", "1") != "0"

    @property
    def last_query_used_daemon(self) -> bool | None:
        """True when the last typed query answered through the owned worker,
        False when it fell back to a cold CLI run, None when no query ran or
        the persistent worker is disabled for this instance."""
        return self._last_query_used_daemon

    def _terminate_owned_worker(self, runtime):
        if self._static_runtime_matches(runtime) and runtime.worker_token and runtime.engine_signature and \
                self._daemon_health(runtime.port, signature=runtime.engine_signature, token=runtime.worker_token):
            from .qmd_scoped import signed_headers
            body = b'{"operation":"shutdown"}'
            request = urllib.request.Request(runtime.endpoint + '/shutdown', data=body,
                headers=signed_headers(body, runtime.worker_token, path='/shutdown'), method='POST')
            try:
                with urllib.request.urlopen(request, timeout=5) as response:
                    if json.load(response).get('stopping') is not True:
                        raise QmdAdapterError('owned query worker rejected shutdown')
            except (OSError, ValueError, urllib.error.URLError) as exc:
                raise QmdAdapterError('owned query worker shutdown was interrupted') from exc
            return
        if not self._static_runtime_matches(runtime) or not self._process_matches(runtime.pid, runtime.port) or \
                self._process_start_identity(runtime.pid) != runtime.process_started_at:
            raise QmdAdapterError('cannot verify worker process for shutdown; restart retrieval through the launcher')
        if runtime.engine_signature is None:
            stopped = self._run(("mcp", "stop"), timeout=20)
            if stopped.returncode != 0 and self._pid_alive(runtime.pid):
                raise QmdAdapterError(self._failure_message('owned qmd worker shutdown', stopped))
            return
        os.kill(runtime.pid, signal.SIGTERM)
        for _ in range(50):
            if not self._pid_alive(runtime.pid) or not self._process_matches(runtime.pid, runtime.port):
                return
            time.sleep(0.1)
        if self._process_matches(runtime.pid, runtime.port) and self._process_start_identity(runtime.pid) == runtime.process_started_at:
            os.kill(runtime.pid, signal.SIGKILL)

    def _ensure_daemon(self, *, require_scoped=False) -> bool:
        if not self._persistent_enabled():
            return False
        with self._lifecycle_lock():
            from .qmd_scoped import launch_worker, package_root, worker_signature
            signature = worker_signature()
            owned = self._owned_runtime()
            if owned is not None and (owned.engine_signature == signature or
                                      (not require_scoped and owned.engine_signature is None)):
                self._daemon_available = True
                return True

            stale = self._read_runtime_metadata()
            if stale and self._static_runtime_matches(stale):
                # Signal only a process whose complete QMD command identity is
                # still ours. Foreign listeners and recycled PIDs are untouched.
                if owned is not None or (
                    self._process_matches(stale.pid, stale.port)
                    and self._process_start_identity(stale.pid)
                    == stale.process_started_at
                ):
                    self._terminate_owned_worker(stale)
                self._cleanup_stale_runtime_files()

            preferred = self._preferred_port()
            port = preferred if self._port_available(preferred) else self._allocate_port()
            try:
                package_root(self)
            except RuntimeError:
                if require_scoped:
                    return False
            else:
                for attempt in range(2):
                    token = secrets.token_hex(32)
                    process = launch_worker(self, port, token)
                    for _ in range(100):
                        if process.poll() is not None:
                            break
                        if self._daemon_health(port, signature=signature, token=token):
                            self._write_runtime_metadata(pid=process.pid, port=port, engine_signature=signature, worker_token=token)
                            self._daemon_available = True
                            return True
                        time.sleep(0.1)
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait()
                    port = self._allocate_port()
                return False
            started = self._run(
                ("mcp", "--http", "--daemon", "--port", str(port)),
                timeout=20,
            )
            if started.returncode != 0:
                # A bind race must not cause adoption of the process that won.
                port = self._allocate_port()
                started = self._run(
                    ("mcp", "--http", "--daemon", "--port", str(port)),
                    timeout=20,
                )
            if started.returncode != 0:
                return False
            pid = self._started_pid(started.stdout)
            if pid is None:
                return False
            for _ in range(100):
                if self._process_matches(pid, port) and self._daemon_health(port):
                    self._write_runtime_metadata(pid=pid, port=port)
                    self._daemon_available = True
                    return True
                time.sleep(0.1)
            return False

    def _daemon_health(self, port: int, *, signature=None, token=None) -> bool:
        try:
            challenge = secrets.token_hex(32) if token else None
            url = f'http://localhost:{port}/health' + (f'?challenge={challenge}' if challenge else '')
            with urllib.request.urlopen(
                url, timeout=0.3
            ) as response:
                payload = json.loads(response.read().decode("utf-8"))
            return (
                response.status == 200
                and isinstance(payload, dict)
                and payload.get("status") == "ok"
                and (signature is None or (
                    payload.get('capability') == 'egregore-qmd-scoped/v1'
                    and payload.get('signature') == signature
                    and payload.get('index') == self.index_name
                    and payload.get('database') == str(self._index_path())
                    and payload.get('collection') == self.collection))
                and (token is None or hmac.compare_digest(str(payload.get('proof', '')),
                    hmac.new(token.encode(), ('health:' + challenge + ':' + '\n'.join([
                        signature, self.index_name, str(self._index_path()), self.collection])).encode(),
                        hashlib.sha256).hexdigest()))
            )
        except (OSError, ValueError, urllib.error.URLError):
            return False

    def _preferred_port(self) -> int:
        default_port = 20_000 + int(self._instance_hash()[:8], 16) % 20_000
        if default_port == 8181:
            default_port += 1
        raw = self.environment.get("EGREGORE_QMD_PORT", str(default_port))
        try:
            port = int(raw)
        except ValueError as exc:
            raise QmdAdapterError(f"invalid EGREGORE_QMD_PORT: {raw!r}") from exc
        if not 1 <= port <= 65535 or port == 8181:
            raise QmdAdapterError(f"invalid EGREGORE_QMD_PORT: {raw!r}")
        return port

    def _daemon_url(self) -> str:
        runtime = self._owned_runtime()
        if runtime is None:
            raise QmdAdapterError("instance-owned QMD worker is unavailable")
        return runtime.endpoint

    def _read_runtime_metadata(self) -> QmdRuntimeMetadata | None:
        try:
            value = json.loads(self._runtime_state_path().read_text(encoding="utf-8"))
            return QmdRuntimeMetadata.from_mapping(value)
        except (OSError, ValueError, KeyError, TypeError):
            return None

    def _static_runtime_matches(self, runtime: QmdRuntimeMetadata) -> bool:
        return (
            runtime.schema_version == RUNTIME_SCHEMA_VERSION
            and runtime.instance_id == self._instance_hash()
            and runtime.qmd_version == QMD_VERSION
            and runtime.index_spec_version == INDEX_SPEC_VERSION
            and runtime.index_name == self.index_name
            and Path(runtime.index_path).resolve() == self._index_path()
            and runtime.collection == self.collection
            and Path(runtime.memory_root).resolve() == self.memory_root
            and runtime.endpoint == f"http://localhost:{runtime.port}"
            and runtime.port != 8181
        )

    def _owned_runtime(self) -> QmdRuntimeMetadata | None:
        runtime = self._read_runtime_metadata()
        if runtime is None or not self._static_runtime_matches(runtime):
            return None
        if runtime.worker_token and runtime.engine_signature:
            # A sandbox may deny ps even for our own worker. Its fresh keyed
            # challenge proves possession of this private generation's token
            # and binds the exact engine/index/collection without exposing it.
            return runtime if self._daemon_health(runtime.port, signature=runtime.engine_signature,
                token=runtime.worker_token) else None
        if not self._process_matches(runtime.pid, runtime.port):
            return None
        if self._process_start_identity(runtime.pid) != runtime.process_started_at:
            return None
        if not (self._daemon_health(runtime.port, signature=runtime.engine_signature)
                if runtime.engine_signature else self._daemon_health(runtime.port)):
            return None
        return runtime

    def _process_matches(self, pid: int, port: int) -> bool:
        if not self._pid_alive(pid):
            return False
        completed = self._run_raw(("ps", "-ww", "-p", str(pid), "-o", "command="), timeout=5)
        if completed.returncode != 0:
            return False
        command = completed.stdout.strip()
        if str(Path(__file__).with_name('qmd_worker.mjs')) in command:
            return (f'--index {self.index_name} ' in command + ' '
                    and f'--port {port} ' in command + ' '
                    and f'--database {self._index_path()} ' in command + ' '
                    and f'--collection {self.collection} ' in command + ' ')
        return (
            "qmd" in command.lower()
            and "mcp" in command
            and f"--index {self.index_name}" in command
            and f"--port {port}" in command
        )

    def _process_start_identity(self, pid: int) -> str | None:
        completed = self._run_raw(
            ("ps", "-ww", "-p", str(pid), "-o", "lstart="), timeout=5
        )
        if completed.returncode != 0 or not completed.stdout.strip():
            return None
        return " ".join(completed.stdout.split())

    @staticmethod
    def _pid_alive(pid: int) -> bool:
        if pid <= 0:
            return False
        # The SDK worker is our child when launched in this process. Reap an
        # exited child before probing; kill(pid, 0) also succeeds for zombies.
        try:
            if os.waitpid(pid, os.WNOHANG)[0] == pid:
                return False
        except ChildProcessError:
            pass
        try:
            os.kill(pid, 0)
            return True
        except (OSError, ValueError):
            return False

    @staticmethod
    def _port_available(port: int) -> bool:
        """A port is free only when both loopback families can bind it.

        The worker binds "localhost", which resolves to ::1 as well as
        127.0.0.1. Probing IPv4 alone reported a port free while a foreign
        server held [::1] on it; the owned worker then died on bind and every
        query ran the CLI cold.
        """
        if port == 8181:
            return False
        for family, address in (
            (socket.AF_INET, "127.0.0.1"),
            (socket.AF_INET6, "::1"),
        ):
            try:
                probe = socket.socket(family, socket.SOCK_STREAM)
            except OSError:
                continue  # family not available on this host
            with probe:
                probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                try:
                    probe.bind((address, port))
                except OSError:
                    return False
        return True

    def _allocate_port(self) -> int:
        for _ in range(20):
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                probe.bind(("127.0.0.1", 0))
                port = int(probe.getsockname()[1])
            if port != 8181 and self._port_available(port):
                return port
        raise QmdAdapterError("could not allocate an instance-owned QMD port")

    def _started_pid(self, output: str) -> int | None:
        if match := re.search(r"\bPID\s+(\d+)\b", output):
            return int(match.group(1))
        candidates = (
            self._runtime_root() / "cache" / "qmd" / f"mcp-{self.index_name}.pid",
            self._runtime_root() / "cache" / "qmd" / "mcp.pid",
        )
        for candidate in candidates:
            try:
                return int(candidate.read_text(encoding="utf-8").strip())
            except (OSError, ValueError):
                continue
        return None

    def _write_runtime_metadata(self, *, pid: int, port: int, engine_signature=None, worker_token=None) -> None:
        process_started_at = self._process_start_identity(pid)
        if process_started_at is None:
            if worker_token and engine_signature:
                # Launch just proved a live child and its private-token
                # challenge. Do not invent an OS birth time when ps is denied.
                process_started_at = 'unavailable'
            else:
                raise QmdAdapterError("could not verify the QMD worker process birth identity")
        runtime = QmdRuntimeMetadata(
            schema_version=RUNTIME_SCHEMA_VERSION,
            instance_id=self._instance_hash(),
            generation=uuid.uuid4().hex,
            pid=pid,
            port=port,
            endpoint=f"http://localhost:{port}",
            qmd_version=QMD_VERSION,
            index_spec_version=INDEX_SPEC_VERSION,
            index_name=self.index_name,
            index_path=str(self._index_path()),
            collection=self.collection,
            memory_root=str(self.memory_root),
            started_at=datetime.now(UTC).isoformat(),
            process_started_at=process_started_at,
            engine_signature=engine_signature,
            worker_token=worker_token,
        )
        self._atomic_json(self._runtime_state_path(), runtime.to_dict())

    def _cleanup_stale_runtime_files(self) -> None:
        self._runtime_state_path().unlink(missing_ok=True)
        for candidate in (
            self._runtime_root() / "cache" / "qmd" / f"mcp-{self.index_name}.pid",
            self._runtime_root() / "cache" / "qmd" / "mcp.pid",
        ):
            candidate.unlink(missing_ok=True)

    # -- Canonical path, metadata, and revision helpers --------------------

    def _canonical_path(self, raw: str) -> str | None:
        raw = raw.strip().strip("`")
        uri_prefix = f"qmd://{self.collection}/"
        if raw.startswith(uri_prefix):
            relative = urllib.parse.unquote(raw[len(uri_prefix) :])
        else:
            candidate = Path(raw)
            if not candidate.is_absolute():
                candidate = (self.repository_root / candidate).resolve()
            else:
                candidate = candidate.resolve()
            try:
                relative = str(candidate.relative_to(self.memory_root))
            except ValueError:
                return None
        relative = relative.replace("\\", "/").lstrip("/")
        if not relative or ".." in Path(relative).parts:
            return None
        return f"memory/{relative}"

    def _source_path(self, canonical_path: str) -> Path:
        prefix = "memory/"
        if not canonical_path.startswith(prefix):
            raise QmdAdapterError(f"source is outside canonical memory: {canonical_path}")
        source = (self.memory_root / canonical_path[len(prefix) :]).resolve()
        try:
            source.relative_to(self.memory_root)
        except ValueError as exc:
            raise QmdAdapterError(f"source is outside canonical memory: {canonical_path}") from exc
        return source

    def _metadata(self, canonical_path: str) -> _DocumentMetadata:
        source = self._source_path(canonical_path)
        fallback_id = canonical_artifact_id("", canonical_path)
        if not source.is_file():
            return _DocumentMetadata(artifact_id=fallback_id)
        body = source.read_text(encoding="utf-8", errors="replace")
        try:
            frontmatter, markdown_body = split_frontmatter(body)
        except ArtifactSchemaError:
            frontmatter, markdown_body = {}, body
        title = next(
            (
                str(frontmatter[field]).strip()
                for field in ("title", "topic", "name")
                if frontmatter.get(field)
            ),
            None,
        )
        if title is None:
            heading = re.search(r"^#\s+(.+?)\s*$", markdown_body, re.MULTILINE)
            if heading:
                title = heading.group(1).strip()
        return _DocumentMetadata(
            artifact_id=canonical_artifact_id(body, canonical_path),
            title=title,
            artifact_type=(
                str(frontmatter.get("artifact_type") or frontmatter.get("type"))
                if frontmatter.get("artifact_type") or frontmatter.get("type")
                else None
            ),
            workstream=(
                str(frontmatter.get("workstream") or frontmatter.get("topic"))
                if frontmatter.get("workstream") or frontmatter.get("topic")
                else None
            ),
            revision=str(frontmatter.get("revision") or self._source_revision()),
            content_hash=hashlib.sha256(body.encode("utf-8")).hexdigest(),
            observed_at=self._observed_at(frontmatter, canonical_path),
            date_provenance=self._date_provenance(frontmatter, canonical_path),
        )

    @classmethod
    def _date_provenance(cls, frontmatter, canonical_path):
        for field in ('occurred_at', 'created_at', 'updated_at', 'date', 'created', 'started', 'ingested_at'):
            if cls._observed_at({field: frontmatter.get(field)}, '') is not None:
                return 'frontmatter.' + field
        return 'canonical_path' if cls._observed_at({}, canonical_path) is not None else None

    @staticmethod
    def _observed_at(
        frontmatter: Mapping[str, Any], canonical_path: str
    ) -> datetime | None:
        for field in (
            "occurred_at",
            "created_at",
            "updated_at",
            "date",
            "created",
            "started",
            "ingested_at",
        ):
            raw = frontmatter.get(field)
            if raw in (None, ""):
                continue
            value = str(raw).strip()
            try:
                parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
            except ValueError:
                continue
            return (
                parsed.replace(tzinfo=UTC)
                if parsed.tzinfo is None
                else parsed.astimezone(UTC)
            )

        match = re.search(r"(?:^|/)(20\d{2})-(\d{2})(?:/|-)(\d{2})(?:[-/]|$)", canonical_path)
        if match:
            try:
                return datetime(
                    int(match.group(1)),
                    int(match.group(2)),
                    int(match.group(3)),
                    tzinfo=UTC,
                )
            except ValueError:
                return None
        return None

    @staticmethod
    def _task_names_document(task: str, metadata: _DocumentMetadata) -> bool:
        if not metadata.title:
            return False

        def normalized(value: str) -> str:
            return " ".join(re.findall(r"[a-z0-9]+", value.lower()))

        title = normalized(metadata.title)
        return len(title) >= 8 and title in normalized(task)

    def _scope_allows(self, canonical_path: str, request: RetrievalRequest) -> bool:
        # Fail closed: a request that carries no authorized scope gets no
        # hits. Observe always sets scopes; a direct caller without them is
        # unauthorized by construction, not universally entitled.
        if not request.authorized_scopes:
            return False
        for raw_scope in request.authorized_scopes:
            scope = raw_scope.strip().replace("\\", "/").rstrip("/")
            if scope == "memory":
                return True
            if not scope.startswith("memory/"):
                scope = f"memory/{scope.lstrip('/')}"
            if canonical_path == scope or canonical_path.startswith(f"{scope}/"):
                return True
        return False

    def _source_revision(self) -> str:
        if self._source_revision_cache is not None:
            return self._source_revision_cache
        completed = self._run_raw(
            ("git", "-C", str(self.memory_root), "rev-parse", "HEAD"), timeout=10
        )
        if completed.returncode == 0 and completed.stdout.strip():
            head = completed.stdout.strip()
            changes = self._run_raw(
                (
                    "git", "-C", str(self.memory_root), "status", "--porcelain=v1",
                    "--untracked-files=all", "--ignored=matching", "--", "*.md",
                ),
                timeout=30,
            )
            if changes.returncode == 0 and not changes.stdout.strip():
                revision = f"git:{head}"
            else:
                revision = f"git:{head}+dirty:{self._markdown_manifest_hash()}"
        else:
            revision = f"filesystem:{self._markdown_manifest_hash()}"
        self._source_revision_cache = revision
        return revision

    def _markdown_manifest_hash(self) -> str:
        digest = hashlib.sha256()
        for source in sorted(self.memory_root.rglob("*.md")):
            if not source.is_file() or not source.resolve().is_relative_to(self.memory_root):
                continue
            relative = source.relative_to(self.memory_root).as_posix()
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            try:
                digest.update(source.read_bytes())
            except OSError:
                digest.update(b"<unreadable>")
            digest.update(b"\0")
        return digest.hexdigest()[:20]

    def _index_revision(self) -> str:
        index = self._index_path()
        stat_material = "missing"
        try:
            stat = index.stat()
            stat_material = f"{stat.st_mtime_ns}:{stat.st_size}"
        except OSError:
            pass
        material = (
            f"{INDEX_SPEC_VERSION}:{self.collection}:"
            f"{self._indexed_source_revision()}:{stat_material}"
        )
        return "qmd:" + hashlib.sha256(material.encode()).hexdigest()[:20]

    def _index_path(self) -> Path:
        override = self.environment.get("EGREGORE_QMD_INDEX_PATH")
        if override:
            return Path(override).expanduser().resolve()
        return self._runtime_root() / "index.sqlite"

    def _models_path(self) -> Path:
        return self._runtime_root() / "cache" / "qmd" / "models"

    def _index_state_path(self) -> Path:
        safe_collection = re.sub(r"[^A-Za-z0-9_.-]", "-", self.collection)
        return self._index_path().parent / f"egregore-index-{safe_collection}.json"

    def _index_state_current(self) -> bool:
        if not self._index_path().is_file():
            return False
        try:
            state = json.loads(self._index_state_path().read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return False
        return state == {
            "adapter_version": QMD_VERSION,
            "collection": self.collection,
            "index_name": self.index_name,
            "index_path": str(self._index_path()),
            "instance_id": self._instance_hash(),
            "index_spec_version": INDEX_SPEC_VERSION,
            "memory_root": str(self.memory_root),
            "source_revision": self._source_revision(),
        }

    def _index_state_usable(self) -> bool:
        """The BM25 index exists for this exact identity, revision aside.

        A canonical write leaves the index trailing the source revision, not
        unusable — retrieval refreshes it inline before querying. Usability
        breaks only on a missing index or a different index identity.
        """
        if not self._index_path().is_file():
            return False
        try:
            state = json.loads(self._index_state_path().read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return False
        expected = {
            "adapter_version": QMD_VERSION,
            "collection": self.collection,
            "index_name": self.index_name,
            "index_path": str(self._index_path()),
            "instance_id": self._instance_hash(),
            "index_spec_version": INDEX_SPEC_VERSION,
            "memory_root": str(self.memory_root),
        }
        return isinstance(state, dict) and all(
            state.get(key) == value for key, value in expected.items()
        )

    def _indexed_source_revision(self) -> str:
        try:
            state = json.loads(self._index_state_path().read_text(encoding="utf-8"))
            revision = state.get("source_revision")
            return str(revision) if revision else "unknown"
        except (OSError, ValueError, TypeError):
            return "unknown"

    def _write_index_state(self) -> None:
        state_path = self._index_state_path()
        state_path.parent.mkdir(parents=True, exist_ok=True)
        state = {
            "adapter_version": QMD_VERSION,
            "collection": self.collection,
            "index_name": self.index_name,
            "index_path": str(self._index_path()),
            "instance_id": self._instance_hash(),
            "index_spec_version": INDEX_SPEC_VERSION,
            "memory_root": str(self.memory_root),
            "source_revision": self._source_revision(),
        }
        self._atomic_json(state_path, state)

    def _embedding_model_available(self) -> bool:
        models = self._models_path()
        return any(models.glob("*embeddinggemma*")) if models.is_dir() else False

    @staticmethod
    def _status_counts(status: str) -> dict[str, int]:
        def count(pattern: str) -> int:
            match = re.search(pattern, status, re.IGNORECASE)
            return int(match.group(1)) if match else 0

        return {
            "documents": count(r"Total:\s*(\d+)\s+files?\s+indexed"),
            "vectors": count(r"Vectors:\s*(\d+)\s+embedded"),
            "pending": count(r"Pending:\s*(\d+)"),
        }

    def _semantic_state_path(self) -> Path:
        return self._runtime_root() / "semantic-state.json"

    def _semantic_state_current(self) -> bool:
        if not self._index_state_current():
            return False
        try:
            state = json.loads(self._semantic_state_path().read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return False
        expected = {
            "collection": self.collection,
            "index_name": self.index_name,
            "index_spec_version": INDEX_SPEC_VERSION,
            "source_revision": self._source_revision(),
        }
        return all(state.get(key) == value for key, value in expected.items())

    def _semantic_state_usable(self) -> bool:
        """A complete vector build exists for this exact index identity.

        Unlike currentness, usability survives canonical writes: the last
        complete vectors keep serving hybrid queries alongside current BM25
        while a newer embedding builds. Only an absent index, an absent
        receipt, or a different index identity makes vectors unusable.
        """
        if not self._index_path().is_file():
            return False
        try:
            state = json.loads(self._semantic_state_path().read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return False
        identity = {
            "collection": self.collection,
            "index_name": self.index_name,
            "index_spec_version": INDEX_SPEC_VERSION,
        }
        return all(
            state.get(key) == value for key, value in identity.items()
        ) and bool(state.get("source_revision"))

    def _semantic_source_revision(self) -> str | None:
        """The canonical revision the last complete vector build represents."""
        try:
            state = json.loads(self._semantic_state_path().read_text(encoding="utf-8"))
        except (OSError, ValueError, TypeError):
            return None
        revision = state.get("source_revision")
        return str(revision) if revision else None

    def _write_semantic_state(
        self,
        *,
        source_revision: str,
        duration_seconds: float | None = None,
    ) -> None:
        self._atomic_json(
            self._semantic_state_path(),
            {
                "schema_version": "egregore-qmd-semantic/v1",
                "collection": self.collection,
                "index_name": self.index_name,
                "index_spec_version": INDEX_SPEC_VERSION,
                "source_revision": source_revision,
                "completed_at": datetime.now(UTC).isoformat(),
                "duration_seconds": round(duration_seconds, 3)
                if duration_seconds is not None
                else None,
            },
        )

    def _embedding_state(self, status: str, *, semantic_ready: bool = False) -> str:
        if self._live_lock(self._embed_lock_path()):
            return "running"
        # Model presence outranks stored-vector completeness: query-time
        # embedding needs the model, so a complete build with a missing model
        # is a repair state, not "ready".
        if not self._embedding_model_available():
            return "missing_model"
        if semantic_ready:
            return "ready"
        counts = self._status_counts(status)
        if counts["pending"] > 0 or counts["documents"] > 0:
            return "pending"
        return "not_built"

    def _embed_lock_path(self) -> Path:
        safe_collection = re.sub(r"[^A-Za-z0-9_.-]", "-", self.collection)
        cache = self._index_path().parent
        return cache / f"egregore-embed-{safe_collection}.json"

    def _live_lock(self, lock: Path) -> bool:
        # Liveness is process identity, not revision equality: a worker whose
        # target revision was outrun by a canonical write is still embedding
        # and converges through its own retry loop. Treating it as dead would
        # spawn a second concurrent embedder against the same SQLite index.
        try:
            data = json.loads(lock.read_text(encoding="utf-8"))
            pid = int(data["pid"])
            index_spec_version = str(data["index_spec_version"])
        except (OSError, ValueError, KeyError, TypeError, json.JSONDecodeError):
            return False
        if index_spec_version != INDEX_SPEC_VERSION or not self._pid_alive(pid):
            lock.unlink(missing_ok=True)
            return False
        return True

    @staticmethod
    def _atomic_json(path: Path, value: Mapping[str, Any]) -> None:
        path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.chmod(path.parent, 0o700)
        temporary = path.with_name(f".{path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
        temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(path)
        os.chmod(path, 0o600)

    def _config_slug(self) -> str:
        try:
            config = json.loads((self.repository_root / "egregore.json").read_text())
            slug = str(config.get("slug") or "egregore").strip()
            return slug or "egregore"
        except (OSError, ValueError, TypeError):
            return "egregore"

    def _instance_hash(self) -> str:
        # Worktrees for one Egregore share the same canonical memory checkout.
        # Namespace by that stable root so they reuse one disposable index and
        # daemon instead of renaming the collection on every branch switch.
        material = str(self.memory_root)
        return hashlib.sha256(material.encode()).hexdigest()[:16]

    def _default_collection(self) -> str:
        slug = re.sub(r"[^A-Za-z0-9_.-]", "-", self._config_slug())
        return f"{slug}-{self.collection_purpose}-{self._instance_hash()[:12]}"

    # -- Process and output helpers ----------------------------------------

    def _run(self, arguments: Sequence[str], *, timeout: int) -> subprocess.CompletedProcess[str]:
        self._ensure_runtime_layout()
        self._ensure_version()
        return self._run_raw(
            (*self._command(), "--index", self.index_name, *arguments),
            timeout=timeout,
        )

    def _run_raw(
        self, command: Sequence[str], *, timeout: int
    ) -> subprocess.CompletedProcess[str]:
        try:
            return subprocess.run(
                command,
                cwd=self.repository_root,
                env=self.environment,
                text=True,
                capture_output=True,
                timeout=timeout,
                check=False,
                umask=0o077,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            return subprocess.CompletedProcess(command, 124, "", str(exc))

    @staticmethod
    def _parse_cli_results(output: str) -> list[dict[str, Any]]:
        start = output.find("[")
        end = output.rfind("]")
        if start == -1 or end < start:
            if "No results" in output or not output.strip():
                return []
            raise QmdAdapterError("typed qmd query returned non-JSON output")
        try:
            payload = json.loads(output[start : end + 1])
        except json.JSONDecodeError as exc:
            raise QmdAdapterError("typed qmd query returned invalid JSON") from exc
        if not isinstance(payload, list):
            raise QmdAdapterError("typed qmd query returned an invalid result shape")
        return [item for item in payload if isinstance(item, dict)]

    @staticmethod
    def _passage(raw: Mapping[str, Any]) -> str | None:
        snippet = raw.get("snippet")
        if isinstance(snippet, str) and snippet.strip():
            snippet = re.sub(r"^@@[^\n]*?@@\s*(?:\([^)]*\)\s*)?", "", snippet.strip())
            return re.sub(r"^\s*\d+:\s?", "", snippet, flags=re.MULTILINE)
        # structuredSearch returns raw source text in bestChunk, unlike the
        # CLI's decorated snippet. Do not strip literal numeric prefixes or
        # treat bestChunkPos (a character offset) as a source line number.
        chunk = raw.get("bestChunk")
        if isinstance(chunk, str) and chunk.strip():
            return QmdLocalRetriever._sdk_passage(raw, chunk)
        return None

    @staticmethod
    def _sdk_passage(raw: Mapping[str, Any], chunk: str) -> str:
        body, position = raw.get("body"), raw.get("bestChunkPos")
        if isinstance(body, str) and type(position) is int and position >= 0:
            header = re.match(r"\A---\r?\n.*?\r?\n---(?:\r?\n|$)", body, re.DOTALL)
            if header:
                try:
                    metadata, _ = split_frontmatter(header.group() + "\n")
                    # QMD positions count JavaScript UTF-16 code units. Only
                    # adjust a chunk that exactly matches this body's offset;
                    # malformed SDK data must not select unrelated source text.
                    prefix = body[:position].encode("utf-16-le")[:position * 2]
                    start = len(prefix.decode("utf-16-le"))
                    if (metadata and start < header.end()
                            and body[start:start + len(chunk)] == chunk):
                        # Identity matches often select the metadata envelope.
                        # Present the adjacent source prose without another read,
                        # while leaving selected chunks in the prose unchanged.
                        return body[header.end():].lstrip()[:MAX_SDK_PASSAGE_CHARACTERS]
                except (ArtifactSchemaError, UnicodeError):
                    pass
        return chunk[:MAX_SDK_PASSAGE_CHARACTERS]

    @staticmethod
    def _single_line(value: str) -> str:
        return " ".join(value.splitlines()).strip()

    @staticmethod
    def _failure_message(
        operation: str, completed: subprocess.CompletedProcess[str]
    ) -> str:
        detail = completed.stderr.strip() or completed.stdout.strip() or "unknown failure"
        return f"{operation} failed ({completed.returncode}): {detail[:400]}"


__all__ = [
    "EMBEDDING_MODEL",
    "INDEX_SPEC_VERSION",
    "QMD_VERSION",
    "RERANKING_ENABLED",
    "RUNTIME_SCHEMA_VERSION",
    "QmdAdapterError",
    "QmdLocalRetriever",
    "QmdRuntimeMetadata",
]
