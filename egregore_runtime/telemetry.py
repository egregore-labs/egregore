"""Local-first telemetry infrastructure for Egregore Runtime.

The canonical runtime contract intentionally exposes only ``TelemetrySink``.
This module supplies its local implementation and a separate, explicit sharing
boundary.  Merely constructing or emitting to ``LocalTelemetrySink`` never
opens a network connection.
"""

from __future__ import annotations

from contextlib import contextmanager
from dataclasses import dataclass, replace
from datetime import UTC, datetime, timedelta
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import time
from typing import Any, Iterator, Mapping, Protocol, Sequence
from urllib import request as urllib_request
from uuid import uuid4

from .contracts import TelemetryEvent


TELEMETRY_SCHEMA_VERSION = "egregore.telemetry/v1"
DEFAULT_MAX_BYTES = 1_048_576
DEFAULT_MAX_EVENTS = 500
DEFAULT_CONSENT_TTL = timedelta(minutes=10)

# Metric keys are intentionally enumerated. New instrumentation extends this
# set deliberately instead of gaining an accidental raw-content channel.
ALLOWED_METRIC_KEYS = frozenset(
    {
        "action",
        "branch",
        "class",
        "command",
        "connector",
        "cost_usd",
        "count",
        "degraded",
        "docs_read",
        "duration_ms",
        "edges",
        "error_code",
        "escalated",
        "failure_code",
        "index_revision",
        "input_tokens",
        "items",
        "invocation_id",
        "harness",
        "kind",
        "layer",
        "latency_ms",
        "lex_fingerprint",
        "message_count",
        "mode",
        "model",
        "opened_count",
        "operation",
        "outcome",
        "exit_status",
        "output_tokens",
        "override",
        "pass",
        "query_type",
        "rank",
        "result",
        "retrieval_type",
        "route_tier",
        "routed",
        "service",
        "signals",
        "source",
        "status",
        "step",
        "stop_reason",
        "subcommand",
        "success",
        "tier",
        "token_count",
        "tokens_in",
        "tokens_out",
        "tool_call_count",
        "transport",
        "type",
        "vec_fingerprint",
        "waves",
        "writeback_result",
    }
)

FORBIDDEN_KEY_FRAGMENTS = (
    "argument",
    "body",
    "code",
    "content",
    "email",
    "env",
    "file",
    "passage",
    "password",
    "path",
    "prompt",
    "query_text",
    "secret",
    "text",
    "token_value",
    "transcript",
)

SAFE_METRIC_STRING = re.compile(r"^[A-Za-z0-9_.:+@/\[\]-]+$")
FINGERPRINT = re.compile(r"^sha256:[0-9a-f]{6,64}$")
SAFE_SOURCES = frozenset(
    {"framework", "org", "default", "fallback", "user", "unknown", "local", "test"}
)


class TelemetryPrivacyError(ValueError):
    """Raised when an event could carry content outside the privacy envelope."""


class TelemetryShareError(RuntimeError):
    """Raised when explicit share consent is missing, stale, or mismatched."""


@dataclass(frozen=True, slots=True)
class TelemetryStatus:
    enabled: bool
    reason: str | None
    event_count: int
    byte_count: int
    storage_path: Path
    local_only: bool = True
    retention: Mapping[str, Any] | None = None


@dataclass(frozen=True, slots=True)
class TelemetrySharePlan:
    target: str
    event_count: int
    byte_count: int
    dataset_sha256: str
    fields: tuple[str, ...]
    expires_at: datetime
    confirmation_token: str


@dataclass(frozen=True, slots=True)
class TelemetryShareReceipt:
    target: str
    event_count: int
    dataset_sha256: str
    shared_at: datetime
    remote_receipt: str | None = None


class SharedTelemetrySink(Protocol):
    """Optional outbound sink; it is never called from ``emit``."""

    @property
    def target(self) -> str: ...

    def transmit(self, events: Sequence[TelemetryEvent]) -> str | None: ...


def _utcnow() -> datetime:
    return datetime.now(UTC)


def _safe_identifier(value: str, *, field: str, max_length: int = 200) -> None:
    if not value or len(value) > max_length:
        raise TelemetryPrivacyError(f"{field} must be 1-{max_length} characters")
    if any(char in value for char in ("\n", "\r", "\t", "\x00")):
        raise TelemetryPrivacyError(f"{field} must be a single-line identifier")
    if not SAFE_METRIC_STRING.fullmatch(value):
        raise TelemetryPrivacyError(f"{field} must be an opaque identifier")


def validate_event(event: TelemetryEvent) -> None:
    """Validate the content-free v1 telemetry envelope."""

    if event.schema_version != TELEMETRY_SCHEMA_VERSION:
        raise TelemetryPrivacyError(
            f"unsupported telemetry schema: {event.schema_version!r}"
        )
    for field, value in (
        ("event_id", event.event_id),
        ("event_type", event.event_type),
        ("org_id", event.org_id),
        ("actor_id", event.actor_id),
        ("session_id", event.session_id),
    ):
        _safe_identifier(value, field=field)
    if event.task_id is not None:
        _safe_identifier(event.task_id, field="task_id")
    if event.org_revision is not None:
        _safe_identifier(event.org_revision, field="org_revision")
    if event.index_spec_version is not None:
        _safe_identifier(event.index_spec_version, field="index_spec_version")
    if event.occurred_at.tzinfo is None:
        raise TelemetryPrivacyError("occurred_at must be timezone-aware")

    for key, value in event.metrics.items():
        normalized = key.lower()
        if any(fragment in normalized for fragment in FORBIDDEN_KEY_FRAGMENTS):
            raise TelemetryPrivacyError(f"metric {key!r} is content-bearing")
        if key not in ALLOWED_METRIC_KEYS:
            raise TelemetryPrivacyError(f"metric {key!r} is not allowlisted")
        if value is not None and not isinstance(value, (bool, int, float, str)):
            raise TelemetryPrivacyError(f"metric {key!r} must be a JSON scalar")
        operation_enums = {
            "operation": {"search", "save"}, "layer": {"operation"},
            "outcome": {"success", "error", "cancelled"},
            "harness": {"claude", "codex", "pi", "prime", "shell", "test", "unknown"},
        }
        if key in operation_enums and value not in operation_enums[key]:
            raise TelemetryPrivacyError(f"metric {key!r} must be a known operation enum")
        if key == "invocation_id" and (not isinstance(value, str) or not re.fullmatch(r"op_[0-9]{10}_[0-9a-f]{32}", value)):
            raise TelemetryPrivacyError("invocation_id must be a timestamped UUID")
        if key == "exit_status" and (type(value) is not int or not 0 <= value < 128):
            raise TelemetryPrivacyError("exit_status must be an observed ordinary exit")
        if isinstance(value, str):
            _safe_identifier(value, field=f"metrics.{key}", max_length=200)
            if "/" in value or value.startswith((".", "~")):
                raise TelemetryPrivacyError(f"metric {key!r} contains a path-like value")
            if key in {"lex_fingerprint", "vec_fingerprint"} and not FINGERPRINT.fullmatch(value):
                raise TelemetryPrivacyError(f"metric {key!r} must be a sha256 fingerprint")
            if key == "source" and value not in SAFE_SOURCES:
                raise TelemetryPrivacyError("metric 'source' must be a known routing source")

    for artifact_id in event.artifact_ids:
        _safe_identifier(artifact_id, field="artifact_ids[]", max_length=256)

    if event.event_type in {"operation.start", "operation.result"}:
        required = {"operation", "layer", "invocation_id", "harness"}
        allowed = required | {"outcome", "duration_ms", "exit_status"}
        if not required <= event.metrics.keys() or not event.metrics.keys() <= allowed:
            raise TelemetryPrivacyError("operation observation has unsupported metrics")
        if event.artifact_ids or event.task_id or event.org_revision or event.index_spec_version:
            raise TelemetryPrivacyError("operation observation must not carry task/artifact context")
        if event.metrics["operation"] not in {"search", "save"} or event.metrics["layer"] != "operation":
            raise TelemetryPrivacyError("operation observation requires a known operation layer")
        if event.metrics["harness"] not in {"claude", "codex", "pi", "prime", "shell", "test", "unknown"}:
            raise TelemetryPrivacyError("operation observation requires a known harness")
        if not isinstance(event.metrics["invocation_id"], str) or not re.fullmatch(r"op_[0-9]{10}_[0-9a-f]{32}", event.metrics["invocation_id"]):
            raise TelemetryPrivacyError("operation invocation must be a timestamped UUID")
        if event.event_type == "operation.start" and set(event.metrics) != required:
            raise TelemetryPrivacyError("start observation must not assert an outcome")
        if event.event_type == "operation.result":
            if event.metrics.get("outcome") not in {"success", "error", "cancelled"}:
                raise TelemetryPrivacyError("result observation requires a known outcome")
            duration = event.metrics.get("duration_ms")
            if type(duration) is not int or duration < 0:
                raise TelemetryPrivacyError("result duration must be a non-negative integer")
            status = event.metrics.get("exit_status")
            if status is not None and (type(status) is not int or not 0 <= status < 128):
                raise TelemetryPrivacyError("result exit status must be an observed ordinary exit")


def make_event(
    *,
    event_type: str,
    org_id: str,
    actor_id: str,
    session_id: str,
    metrics: Mapping[str, int | float | bool | str | None] | None = None,
    artifact_ids: Sequence[str] = (),
    task_id: str | None = None,
    org_revision: str | None = None,
    index_spec_version: str | None = None,
    occurred_at: datetime | None = None,
) -> TelemetryEvent:
    """Build and validate a content-free telemetry event."""

    event = TelemetryEvent(
        schema_version=TELEMETRY_SCHEMA_VERSION,
        event_id=f"tel_{uuid4().hex}",
        event_type=event_type,
        occurred_at=occurred_at or _utcnow(),
        org_id=org_id,
        actor_id=actor_id,
        session_id=session_id,
        task_id=task_id,
        org_revision=org_revision,
        index_spec_version=index_spec_version,
        metrics=dict(metrics or {}),
        artifact_ids=tuple(artifact_ids),
    )
    validate_event(event)
    return event


def _event_json(event: TelemetryEvent) -> str:
    return json.dumps(event.to_dict(), sort_keys=True, separators=(",", ":"))


def _parse_datetime(value: str) -> datetime:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=UTC)
    return parsed


def event_from_mapping(raw: Mapping[str, Any]) -> TelemetryEvent:
    """Read a v1 event or a bounded legacy event from the local buffer."""

    if raw.get("schema_version") == TELEMETRY_SCHEMA_VERSION:
        event = TelemetryEvent(
            schema_version=TELEMETRY_SCHEMA_VERSION,
            event_id=str(raw["event_id"]),
            event_type=str(raw["event_type"]),
            occurred_at=_parse_datetime(str(raw["occurred_at"])),
            org_id=str(raw["org_id"]),
            actor_id=str(raw["actor_id"]),
            session_id=str(raw["session_id"]),
            task_id=str(raw["task_id"]) if raw.get("task_id") is not None else None,
            org_revision=(
                str(raw["org_revision"])
                if raw.get("org_revision") is not None
                else None
            ),
            index_spec_version=(
                str(raw["index_spec_version"])
                if raw.get("index_spec_version") is not None
                else None
            ),
            metrics=dict(raw.get("metrics") or {}),
            artifact_ids=tuple(str(item) for item in raw.get("artifact_ids") or ()),
            shared=bool(raw.get("shared", False)),
        )
    else:
        # Compatibility reader for the pre-runtime local JSONL envelope. The
        # same allowlist applies, so old buffers cannot bypass export/share
        # privacy validation.
        data = raw.get("data") or {}
        if not isinstance(data, Mapping):
            raise TelemetryPrivacyError("legacy telemetry data must be an object")
        event = TelemetryEvent(
            schema_version=TELEMETRY_SCHEMA_VERSION,
            event_id=str(
                raw.get("event_id")
                or "legacy_"
                + hashlib.sha256(
                    json.dumps(raw, sort_keys=True, separators=(",", ":")).encode()
                ).hexdigest()[:32]
            ),
            event_type=str(raw.get("type") or "legacy"),
            occurred_at=_parse_datetime(str(raw.get("ts") or _utcnow().isoformat())),
            org_id=str(raw.get("org") or "unknown"),
            actor_id=str(raw.get("user") or "unknown"),
            session_id=str(raw.get("sid") or "unknown"),
            metrics=dict(data),
        )
    validate_event(event)
    return event


class LocalTelemetrySink:
    """Bounded, local JSONL sink implementing the runtime ``TelemetrySink``.

    Default storage is namespaced by the resolved instance root under
    ``~/.egregore/telemetry/``: on-device, outside canonical repositories, and
    unable to mix multiple Egregore instances. ``EGREGORE_TELEMETRY_DIR`` or
    an explicit ``storage_dir`` may relocate one sink for tests or managed
    local deployments.
    """

    def __init__(
        self,
        *,
        storage_dir: Path | None = None,
        state_file: Path | None = None,
        max_bytes: int = DEFAULT_MAX_BYTES,
        max_events: int = DEFAULT_MAX_EVENTS,
        consent_ttl: timedelta = DEFAULT_CONSENT_TTL,
        instance_root: Path | None = None,
    ) -> None:
        env_dir = os.environ.get("EGREGORE_TELEMETRY_DIR")
        if storage_dir is not None:
            self.storage_dir = storage_dir
        elif env_dir:
            self.storage_dir = Path(env_dir).expanduser()
        else:
            root = instance_root or (state_file.parent if state_file else Path.cwd())
            namespace = hashlib.sha256(str(root.resolve()).encode()).hexdigest()[:20]
            self.storage_dir = Path.home() / ".egregore" / "telemetry" / namespace
        self.buffer_path = self.storage_dir / "telemetry.jsonl"
        self.lock_path = self.storage_dir / "telemetry.lock"
        self.share_consent_path = self.storage_dir / "telemetry-share-consent.json"
        self.retention_path = self.storage_dir / "telemetry-retention.json"
        self.state_file = state_file
        self.max_bytes = max_bytes
        self.max_events = max_events
        self.consent_ttl = consent_ttl

    def _disabled_reason(self) -> str | None:
        if os.environ.get("EGREGORE_NO_TELEMETRY") == "1":
            return "EGREGORE_NO_TELEMETRY=1"
        if os.environ.get("DO_NOT_TRACK") == "1":
            return "DO_NOT_TRACK=1"
        env_file = self.state_file.parent / ".env" if self.state_file else None
        if env_file and env_file.exists():
            for line in env_file.read_text(encoding="utf-8").splitlines():
                key, sep, value = line.strip().partition("=")
                if sep and key == "EGREGORE_NO_TELEMETRY" and value.strip().strip("\"'") == "1":
                    return "EGREGORE_NO_TELEMETRY=1 in .env"
        if self.state_file and self.state_file.exists():
            try:
                state = json.loads(self.state_file.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                state = {}
            if state.get("telemetry") is False:
                return "telemetry=false in state"
        return None

    @contextmanager
    def _lock(self, *, timeout: float = 5.0) -> Iterator[None]:
        self.storage_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(self.storage_dir, 0o700)
        deadline = time.monotonic() + timeout
        while True:
            try:
                self.lock_path.mkdir(mode=0o700)
                break
            except FileExistsError:
                if time.monotonic() >= deadline:
                    raise TimeoutError("timed out acquiring telemetry lock")
                time.sleep(0.02)
        try:
            yield
        finally:
            shutil.rmtree(self.lock_path, ignore_errors=True)

    def emit(self, event: TelemetryEvent) -> None:
        if self._disabled_reason() is not None:
            return
        validate_event(event)
        self.storage_dir.mkdir(parents=True, exist_ok=True)
        with self._lock():
            self._append_locked(event)

    def _write_private_json(self, target: Path, value: Mapping[str, Any]) -> None:
        temporary = target.with_suffix(target.suffix + ".tmp")
        temporary.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(target)

    def _retention(self) -> dict[str, Any]:
        if self.retention_path.exists():
            return json.loads(self.retention_path.read_text(encoding="utf-8"))
        return {
            "schema_version": "egregore.telemetry-retention/v1",
            "since": _utcnow().isoformat(),
            "scope": "python-sink-only",
            "appended": 0,
            "evicted": 0,
            "operation_evicted": 0,
            "external_writes_tracked": False,
        }

    def _append_locked(self, event: TelemetryEvent) -> None:
        """Append under the shared sink lock; operation dedup uses this boundary."""
        retention = self._retention()
        with self.buffer_path.open("a", encoding="utf-8") as handle:
            handle.write(_event_json(event) + "\n")
        os.chmod(self.buffer_path, 0o600)
        retention["appended"] += 1
        dropped, operation_dropped = self._truncate_if_needed()
        retention["evicted"] += dropped
        retention["operation_evicted"] = retention.get("operation_evicted", 0) + operation_dropped
        self._write_private_json(self.retention_path, retention)

    def _truncate_if_needed(self) -> tuple[int, int]:
        lines = self.buffer_path.read_text(encoding="utf-8").splitlines()
        retained = lines[-max(0, self.max_events):] if self.max_events > 0 else []
        size = sum(len(line.encode("utf-8")) + 1 for line in retained)
        while retained and size > max(0, self.max_bytes):
            size -= len(retained.pop(0).encode("utf-8")) + 1
        dropped = len(lines) - len(retained)
        if not dropped:
            return 0, 0
        operation_dropped = 0
        for line in lines[:dropped]:
            try:
                if json.loads(line).get("event_type") in {"operation.start", "operation.result"}:
                    operation_dropped += 1
            except (ValueError, AttributeError):
                pass  # unvalidated external rows never become pilot evidence
        temporary = self.buffer_path.with_suffix(".jsonl.truncate")
        temporary.write_text("".join(line + "\n" for line in retained), encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(self.buffer_path)
        return dropped, operation_dropped

    def inspect(self, *, limit: int = 100) -> Sequence[TelemetryEvent]:
        if limit < 0:
            raise ValueError("limit must be non-negative")
        events = self._read_events()
        return tuple(events[-limit:]) if limit else ()

    def _read_events(self) -> list[TelemetryEvent]:
        if not self.buffer_path.exists():
            return []
        events: list[TelemetryEvent] = []
        for line_number, line in enumerate(
            self.buffer_path.read_text(encoding="utf-8").splitlines(), start=1
        ):
            if not line.strip():
                continue
            try:
                raw = json.loads(line)
                events.append(event_from_mapping(raw))
            except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
                raise TelemetryPrivacyError(
                    f"invalid local telemetry event at line {line_number}: {exc}"
                ) from exc
        return events

    def export(self, destination: Path) -> Path:
        destination = destination.expanduser().resolve()
        if destination == self.buffer_path.expanduser().resolve():
            raise ValueError("export destination must differ from the local buffer")
        events = self._read_events()
        destination.parent.mkdir(parents=True, exist_ok=True)
        temporary = destination.with_name(f".{destination.name}.{uuid4().hex}.tmp")
        with temporary.open("w", encoding="utf-8") as handle:
            for event in events:
                handle.write(_event_json(event) + "\n")
        os.chmod(temporary, 0o600)
        temporary.replace(destination)
        return destination

    def status(self) -> TelemetryStatus:
        byte_count = self.buffer_path.stat().st_size if self.buffer_path.exists() else 0
        event_count = 0
        if self.buffer_path.exists():
            with self.buffer_path.open("r", encoding="utf-8") as handle:
                event_count = sum(1 for line in handle if line.strip())
        reason = self._disabled_reason()
        return TelemetryStatus(
            enabled=reason is None,
            reason=reason,
            event_count=event_count,
            byte_count=byte_count,
            storage_path=self.buffer_path,
            retention=self._retention() if self.retention_path.exists() else None,
        )

    def set_enabled(self, enabled: bool) -> None:
        if self.state_file is None:
            raise ValueError("state_file is required to persist telemetry settings")
        if self.state_file.is_symlink():
            self.state_file = self.state_file.resolve()
        state: dict[str, Any] = {}
        if self.state_file.exists():
            try:
                state = json.loads(self.state_file.read_text(encoding="utf-8"))
            except json.JSONDecodeError as exc:
                raise ValueError(f"invalid state file: {self.state_file}") from exc
        state["telemetry"] = enabled
        self.state_file.parent.mkdir(parents=True, exist_ok=True)
        temporary = self.state_file.with_suffix(self.state_file.suffix + ".tmp")
        temporary.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
        os.chmod(temporary, 0o600)
        temporary.replace(self.state_file)

    def clear(self) -> None:
        with self._lock():
            self.buffer_path.unlink(missing_ok=True)
            self.share_consent_path.unlink(missing_ok=True)
            self.retention_path.unlink(missing_ok=True)
            (self.storage_dir / "operation-observations.json").unlink(missing_ok=True)

    def prepare_share(self, shared_sink: SharedTelemetrySink) -> TelemetrySharePlan:
        events = self._read_events()
        payload = "".join(_event_json(event) + "\n" for event in events).encode()
        dataset_sha256 = hashlib.sha256(payload).hexdigest()
        token = secrets.token_urlsafe(24)
        expires_at = _utcnow() + self.consent_ttl
        fields = {
            "actor_id",
            "artifact_ids",
            "event_id",
            "event_type",
            "occurred_at",
            "org_id",
            "schema_version",
            "session_id",
            "shared",
        }
        for event in events:
            fields.update(f"metrics.{key}" for key in event.metrics)
            if event.task_id:
                fields.add("task_id")
            if event.org_revision:
                fields.add("org_revision")
            if event.index_spec_version:
                fields.add("index_spec_version")
        consent = {
            "target": shared_sink.target,
            "dataset_sha256": dataset_sha256,
            "token_sha256": hashlib.sha256(token.encode()).hexdigest(),
            "expires_at": expires_at.isoformat(),
        }
        self.storage_dir.mkdir(parents=True, exist_ok=True)
        self.share_consent_path.write_text(
            json.dumps(consent, sort_keys=True) + "\n", encoding="utf-8"
        )
        os.chmod(self.share_consent_path, 0o600)
        return TelemetrySharePlan(
            target=shared_sink.target,
            event_count=len(events),
            byte_count=len(payload),
            dataset_sha256=dataset_sha256,
            fields=tuple(sorted(fields)),
            expires_at=expires_at,
            confirmation_token=token,
        )

    def share(
        self,
        shared_sink: SharedTelemetrySink,
        *,
        confirmation_token: str,
    ) -> TelemetryShareReceipt:
        if not self.share_consent_path.exists():
            raise TelemetryShareError("prepare_share must run before share")
        try:
            consent = json.loads(self.share_consent_path.read_text(encoding="utf-8"))
            expires_at = _parse_datetime(str(consent["expires_at"]))
        except (OSError, json.JSONDecodeError, KeyError, ValueError) as exc:
            raise TelemetryShareError("share consent record is invalid") from exc
        if _utcnow() > expires_at:
            self.share_consent_path.unlink(missing_ok=True)
            raise TelemetryShareError("share consent expired; prepare a new share")
        if not secrets.compare_digest(
            hashlib.sha256(confirmation_token.encode()).hexdigest(),
            str(consent.get("token_sha256", "")),
        ):
            raise TelemetryShareError("share confirmation token is invalid")
        if consent.get("target") != shared_sink.target:
            raise TelemetryShareError("share target changed; prepare a new share")

        events = self._read_events()
        payload = "".join(_event_json(event) + "\n" for event in events).encode()
        dataset_sha256 = hashlib.sha256(payload).hexdigest()
        if dataset_sha256 != consent.get("dataset_sha256"):
            raise TelemetryShareError("telemetry dataset changed; prepare a new share")

        receipt = shared_sink.transmit(tuple(replace(event, shared=True) for event in events))
        self.share_consent_path.unlink(missing_ok=True)
        return TelemetryShareReceipt(
            target=shared_sink.target,
            event_count=len(events),
            dataset_sha256=dataset_sha256,
            shared_at=_utcnow(),
            remote_receipt=receipt,
        )


class HttpSharedTelemetrySink:
    """Explicit HTTP shared sink, compatible with the current API when asked."""

    def __init__(
        self,
        endpoint: str,
        *,
        bearer_token: str | None = None,
        legacy_envelope: bool = False,
        timeout_seconds: float = 15.0,
    ) -> None:
        if not endpoint.startswith("https://") and not endpoint.startswith(
            ("http://127.0.0.1", "http://localhost", "http://[::1]")
        ):
            raise ValueError("telemetry endpoint must use https (or loopback http)")
        self.endpoint = endpoint
        self.bearer_token = bearer_token
        self.legacy_envelope = legacy_envelope
        self.timeout_seconds = timeout_seconds

    @property
    def target(self) -> str:
        return self.endpoint

    def _serialize(self, event: TelemetryEvent) -> str:
        if not self.legacy_envelope:
            return _event_json(event)
        data = dict(event.metrics)
        data.update(
            {
                "event_id": event.event_id,
                "schema_version": event.schema_version,
                "shared": True,
                "artifact_ids": list(event.artifact_ids),
                "task_id": event.task_id,
                "org_revision": event.org_revision,
                "index_spec_version": event.index_spec_version,
            }
        )
        return json.dumps(
            {
                "ts": event.occurred_at.isoformat(),
                "type": event.event_type,
                "sid": event.session_id,
                "org": event.org_id,
                "user": event.actor_id,
                "data": data,
            },
            sort_keys=True,
            separators=(",", ":"),
        )

    def transmit(self, events: Sequence[TelemetryEvent]) -> str | None:
        payload = "".join(self._serialize(event) + "\n" for event in events).encode()
        headers = {
            "Content-Type": "application/x-ndjson",
            "User-Agent": "egregore-runtime-telemetry/1",
        }
        if self.bearer_token:
            headers["Authorization"] = f"Bearer {self.bearer_token}"
        outbound = urllib_request.Request(
            self.endpoint, data=payload, headers=headers, method="POST"
        )
        with urllib_request.urlopen(outbound, timeout=self.timeout_seconds) as response:
            body = response.read(4096).decode("utf-8", errors="replace")
            return body or str(response.status)
