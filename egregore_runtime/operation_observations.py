"""At-most-once observations of bounded operations, never skill completion.

The ledger is disposable local telemetry state, not organizational memory. A
reservation is persisted before a sink append: a crash may lose an observation,
but retrying that identifier never duplicates it or overwrites a terminal error.
Expired identifiers are rejected even after their bounded dedup record expires.
"""
from __future__ import annotations

from dataclasses import replace
import hashlib
import json
from pathlib import Path
import re
import time
from typing import Callable
from uuid import uuid4

from .telemetry import LocalTelemetrySink, make_event

OPERATIONS = frozenset({"search", "save"})
HARNESSES = frozenset({"claude", "codex", "pi", "prime", "shell", "test", "unknown"})
OUTCOMES = frozenset({"success", "error", "cancelled"})
INVOCATION_ID = re.compile(r"^op_([0-9]{10})_([a-f0-9]{32})$")
MAX_AGE_SECONDS = 7 * 24 * 60 * 60
MAX_OBSERVATIONS = 2048


def new_invocation_id(now: float | None = None) -> str:
    return f"op_{int(time.time() if now is None else now)}_{uuid4().hex}"


class OperationObserver:
    def __init__(
        self, sink: LocalTelemetrySink, *, instance_id: str,
        org_id: str, actor_id: str, session_id: str, harness: str = "unknown",
        clock: Callable[[], float] = time.time,
        max_records: int = MAX_OBSERVATIONS, max_age: int = MAX_AGE_SECONDS,
        lock_timeout: float = 0.1,
    ) -> None:
        self.sink = sink
        self.instance_id = instance_id
        self.org_id = org_id
        self.actor_id = actor_id
        self.session_id = session_id
        self.harness = harness if harness in HARNESSES else "unknown"
        self.clock = clock
        self.max_records = max_records
        self.max_age = max_age
        self.lock_timeout = lock_timeout
        self.path = sink.storage_dir / "operation-observations.json"

    def _load(self) -> dict:
        if self.path.exists():
            state = json.loads(self.path.read_text(encoding="utf-8"))
            if state.get("schema_version") != "egregore.operation-observations/v1":
                raise ValueError("unsupported operation ledger")
            if state.get("instance_id") != self.instance_id:
                raise ValueError("operation ledger belongs to another instance")
            if not isinstance(state.get("records"), dict):
                raise ValueError("invalid operation ledger")
            return state
        return {
            "schema_version": "egregore.operation-observations/v1",
            "instance_id": self.instance_id,
            "since": self.clock(),
            "scope": "operation-observations-only",
            "records": {},
            "started": 0, "terminal": 0, "replayed": 0,
            "capacity_refused": 0, "expired_records": 0,
            "append_failures": 0,
        }

    def _write(self, state: dict) -> None:
        self.sink._write_private_json(self.path, state)

    def _key(self, operation: str, invocation_id: str) -> str:
        return hashlib.sha256(f"{operation}:{invocation_id}".encode()).hexdigest()

    def _valid(self, operation: str, invocation_id: str) -> bool:
        match = INVOCATION_ID.fullmatch(invocation_id)
        return bool(operation in OPERATIONS and match and
                    0 <= self.clock() - int(match[1]) <= self.max_age)

    def _event(self, operation: str, invocation_id: str, phase: str, **metrics):
        event = make_event(
            event_type=f"operation.{phase}", org_id=self.org_id,
            actor_id=self.actor_id, session_id=self.session_id,
            metrics={"operation": operation, "layer": "operation",
                     "invocation_id": invocation_id, "harness": self.harness, **metrics},
        )
        identity = f"{self.instance_id}:{operation}:{invocation_id}:{phase}"
        return replace(event, event_id=f"tel_op_{hashlib.sha256(identity.encode()).hexdigest()}")

    def begin(self, operation: str, invocation_id: str | None = None) -> str | None:
        """Return the observed ID, or None without affecting the operation."""
        try:
            if self.sink._disabled_reason() is not None:
                return None
            invocation_id = invocation_id or new_invocation_id(self.clock())
            if not self._valid(operation, invocation_id):
                return None
            event = self._event(operation, invocation_id, "start")
            with self.sink._lock(timeout=self.lock_timeout):
                state = self._load()
                records = state["records"]
                for key in list(records):
                    if self.clock() - records[key]["created"] > self.max_age:
                        del records[key]
                        state["expired_records"] += 1
                key = self._key(operation, invocation_id)
                if key in records:
                    record = records[key]
                    if record["actor_id"] != self.actor_id or record["org_id"] != self.org_id:
                        return None
                    state["replayed"] += 1
                    self._write(state)
                    return invocation_id
                if len(records) >= self.max_records:
                    state["capacity_refused"] += 1
                    self._write(state)
                    return None
                records[key] = {
                    "created": int(INVOCATION_ID.fullmatch(invocation_id)[1]),
                    "started_at": self.clock(),
                    "actor_id": self.actor_id, "org_id": self.org_id,
                    "session_id": self.session_id, "harness": self.harness,
                    "start_recorded": False, "terminal_reserved": False,
                    "terminal_recorded": False,
                }
                # Reserve before append. A failed append remains a visible gap,
                # and a restart never publishes a duplicate observation.
                self._write(state)
                try:
                    self.sink._append_locked(event)
                except Exception:
                    state["append_failures"] += 1
                    self._write(state)
                    return None
                records[key]["start_recorded"] = True
                state["started"] += 1
                self._write(state)
                return invocation_id
        except Exception:
            return None

    def finish(self, operation: str, invocation_id: str, *, outcome: str,
               exit_status: int | None = None) -> bool:
        """Only an observed terminal boundary calls this; interruption is unknown."""
        try:
            if self.sink._disabled_reason() is not None or not self._valid(operation, invocation_id):
                return False
            if outcome not in OUTCOMES:
                return False
            if exit_status is not None and (type(exit_status) is not int or not 0 <= exit_status < 128):
                return False  # signal-shaped statuses do not establish cancellation
            if outcome == "success" and exit_status not in (None, 0):
                return False
            if outcome == "error" and exit_status == 0:
                return False
            with self.sink._lock(timeout=self.lock_timeout):
                state = self._load()
                record = state["records"].get(self._key(operation, invocation_id))
                if not record or not record["start_recorded"]:
                    return False
                if record["org_id"] != self.org_id or record["actor_id"] != self.actor_id:
                    return False
                if record["terminal_reserved"]:
                    state["replayed"] += 1
                    self._write(state)
                    return False
                # Attribution belongs to the original start even across a retry
                # from another process/session; reusing an ID is not a new run.
                metrics = {"outcome": outcome,
                           "duration_ms": max(0, round((self.clock() - record["started_at"]) * 1000))}
                if exit_status is not None:
                    metrics["exit_status"] = exit_status
                event = replace(self._event(operation, invocation_id, "result", **metrics),
                                session_id=record["session_id"],
                                metrics={"operation": operation, "layer": "operation",
                                         "invocation_id": invocation_id, "harness": record["harness"], **metrics})
                record["terminal_reserved"] = True
                self._write(state)
                try:
                    self.sink._append_locked(event)
                except Exception:
                    state["append_failures"] += 1
                    self._write(state)
                    return False
                record["terminal_recorded"] = True
                state["terminal"] += 1
                self._write(state)
                return True
        except Exception:
            return False

    def coverage(self) -> dict:
        """Local pilot counters; never a denominator for all skill invocations."""
        with self.sink._lock(timeout=self.lock_timeout):
            state = self._load()
            counters = {key: value for key, value in state.items() if key != "records"}
            counters["retained_dedup_records"] = len(state["records"])
            counters["unresolved_retained"] = sum(
                record["start_recorded"] and not record["terminal_recorded"]
                for record in state["records"].values())
            counters["sink_retention"] = self.sink.status().retention
            counters["unobserved_invocations"] = "unknown"
            return counters
