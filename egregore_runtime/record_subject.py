"""Pure, public presentation of record subjects. Classification grants no access.

Unknown or damaged producer metadata never falls back to a human session. Only
the fixed, closed metadata facts shape is projected; Markdown prose is not data.
Callers must authorize the source and mask held records before using this module.
"""
from __future__ import annotations

from collections import Counter
from datetime import datetime
import hashlib
import json
import math
import re

PRODUCER = "pi-durable.metadata/v1"
CONTROL = re.compile(r"^spirit-[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$")
ACTOR = re.compile(r"^[A-Za-z0-9._:-]{1,160}$")
PRINCIPAL = re.compile(r"^principal:[a-z0-9][a-z0-9_.-]{0,63}$")
HASH = re.compile(r"^[a-f0-9]{64}$")
MARKERS = {"producer", "producer_principal_id", "record_owner_actor_id", "producer_identity", "subject_kind",
           "source_projection_version", "source_projection_revision", "source_evidence_revision"}
STATE = {
    "execution": {"queued", "running", "stopped"},
    "outcome": {"pending", "unverified", "fulfilled", "partial", "needs_input", "blocked", "failed", "cancelled"},
    "verification": {"not_run", "passed", "failed", "inconclusive"},
    "delivery": {"not_requested", "pending", "unknown", "sent", "failed"},
}
GAPS = {"attachment_unavailable", "submission_unavailable", "reconciliation_failed", "entry_limit",
        "incomplete_submission", "observer_stopped", "identity_conflict"}

OBSERVATION_ENUMS = {
    **STATE,
    "transition": {"admitted", "claimed", "settled", "cancelled", "retried", "answered", "recovered", "delivery"},
    "status": {"queued", "placed", "done", "unanswered"},
    "entry_kind": {"user", "assistant", "tool_result", "other"},
    "tool_status": {"success", "error", "unknown"},
}
OBSERVATION_FIELDS = {
    "lifecycle": {"transition", "execution", "outcome", "verification", "delivery", "attempt"},
    "submission": {"status"}, "entry": {"entry_kind", "tool_status"}, "gap": {"reason"},
}
OBSERVATION_REQUIRED = {"lifecycle": "transition", "submission": "status", "entry": "entry_kind", "gap": "reason"}
V2_GAPS = GAPS | {"restart_gap", "queue_overflow", "stream_snapshot", "write_failed", "flush_failed",
    "source_unavailable", "unattributed", "lineage_limit", "usage_unavailable", "usage_reset", "shutdown_incomplete"}
V2_FIELDS = {
    "task": {"task_kind", "state", "outcome", "parent_ref", "background", "abort_requested"},
    "run": {"phase", "submission_ref"},
    "tool": {"phase", "status", "capability_ref", "call_ref", "task_ref", "parent_call_ref", "parent_task_ref"},
    "retry": {"phase", "attempt"}, "compaction": {"phase", "reason", "task_ref", "blocking", "status"},
}
V2_ENUMS = {
    "task_kind": {"run", "generation", "tool", "compaction", "other"},
    "state": {"pending", "running", "waiting", "completing", "terminal"},
    "outcome": {"completed", "failed", "aborted", "orphaned", "faulted", "unknown"},
    "phase": {"start", "end", "snapshot"}, "status": {"success", "error", "unknown"},
    "reason": {"manual", "threshold", "overflow", "unknown"},
}
USAGE_COUNTERS = {"model_tokens", "tool_tokens", "model_reported_cost", "tool_reported_cost"}

def _int(value, maximum=2**53 - 1):
    return type(value) is int and 0 <= value <= maximum


def _stamp(value):
    try:
        return isinstance(value, str) and len(value) <= 40 and datetime.fromisoformat(value.replace("Z", "+00:00")).tzinfo is not None
    except ValueError:
        return False


def _observation_fields(value, allowed, required=None):
    if not isinstance(value, dict) or not set(value) <= set(allowed) or not set(required if required is not None else allowed) <= set(value):
        raise ValueError("invalid metadata shape")


def _observation_stamp(value):
    if not isinstance(value, str) or len(value) > 40 or not value.endswith(("Z", "+00:00")):
        raise ValueError("invalid metadata time")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("invalid metadata time")
    return parsed.timestamp()


def _observation_reference(value, *, nullable=False):
    if nullable and value is None:
        return
    if not isinstance(value, str) or not HASH.fullmatch(value):
        raise ValueError("invalid opaque reference")


def _observation_metadata_v2(kind, metadata):
    if kind in OBSERVATION_FIELDS:
        _observation_fields(metadata, OBSERVATION_FIELDS[kind], {OBSERVATION_REQUIRED[kind]})
        for key, item in metadata.items():
            valid = _int(item) if key == "attempt" else isinstance(item, str) and item in (V2_GAPS if kind == "gap" else OBSERVATION_ENUMS[key])
            if not valid:
                raise ValueError("invalid metadata value")
        return
    if kind not in V2_FIELDS:
        raise ValueError("invalid metadata kind")
    _observation_fields(metadata, V2_FIELDS[kind])
    for key, item in metadata.items():
        if key.endswith("_ref"):
            _observation_reference(item, nullable=True)
        elif key in {"background", "abort_requested", "blocking"}:
            if type(item) is not bool and not (key == "blocking" and item is None):
                raise ValueError("invalid metadata boolean")
        elif key == "attempt":
            if not _int(item):
                raise ValueError("invalid metadata attempt")
        elif not isinstance(item, str) or item not in (V2_ENUMS[key] | {"update"} if kind == "tool" and key == "phase" else V2_ENUMS[key]):
            raise ValueError("invalid metadata enum")


def _observation_usage_values(value, *, bound=False):
    _observation_fields(value, USAGE_COUNTERS | ({"ref"} if bound else set()))
    if bound:
        _observation_reference(value["ref"])
    for key in USAGE_COUNTERS:
        item = value[key]
        if item is not None and (not _int(item) if key.endswith("_tokens") else
                type(item) not in {int, float} or not math.isfinite(item) or item < 0):
            raise ValueError("invalid usage counter")


def validate_spirit_snapshot_v2(snapshot, *, revision):
    """Pure closed V2 projection validation, with no live freshness or authority.

    Private capture separately enforces current collection time and permissions;
    public readers validate historical canonical facts without renewing either.
    """
    _observation_fields(snapshot, {"state", "events", "coverage", "captured_at"})
    state = snapshot["state"]
    _observation_fields(state, {*STATE, "revision", "attempt"})
    if (not _int(revision) or not _int(state["revision"]) or state["revision"] != revision
            or not _int(state["attempt"]) or any(not isinstance(state[key], str) or state[key] not in allowed for key, allowed in STATE.items())):
        raise ValueError("invalid intent state")
    captured = _observation_stamp(snapshot["captured_at"])
    events, coverage = snapshot["events"], snapshot["coverage"]
    if (not isinstance(events, list) or len(events) > 256
            or len(json.dumps(events, separators=(",", ":"), ensure_ascii=False).encode()) > 128 * 1024
            or len(json.dumps(snapshot, separators=(",", ":"), ensure_ascii=False).encode()) > 256 * 1024):
        raise ValueError("invalid metadata count")
    identities = set()
    for event in events:
        _observation_fields(event, {"id", "revision", "source", "source_ref", "source_revision_ref", "epoch_ref", "kind", "metadata", "observed_at", "native_event_time"})
        for key in ("id", "source_ref", "source_revision_ref", "epoch_ref"):
            _observation_reference(event[key], nullable=key == "epoch_ref")
        if (event["id"] in identities or type(event["revision"]) is not int or event["revision"] != revision
                or event["source"] not in {"application", "commit", "semantic", "reconcile"}
                or _observation_stamp(event["observed_at"]) > captured + 2
                or event["native_event_time"] is not None and _observation_stamp(event["native_event_time"]) > captured + 2):
            raise ValueError("invalid metadata event")
        identities.add(event["id"])
        _observation_metadata_v2(event["kind"], event["metadata"])
    _observation_fields(coverage, {"schema", "projection_revision", "historical", "native_journal", "window", "capture", "gaps", "epochs", "usage"})
    if (coverage["schema"] != "egregore.spirit-observation-coverage/v2" or not _int(coverage["projection_revision"])
            or coverage["historical"] != "unknown" or coverage["native_journal"] != "unknown"):
        raise ValueError("invalid coverage")
    window = coverage["window"]
    _observation_fields(window, {"selection", "revision", "limit", "event_count", "earlier", "last_event_ref"})
    if (window["selection"] != "revision_tail" or type(window["revision"]) is not int or window["revision"] != revision
            or type(window["limit"]) is not int or window["limit"] != 256 or not _int(window["event_count"], 256)
            or window["event_count"] != len(events) or window["earlier"] not in {"none", "omitted"}
            or window["last_event_ref"] != (events[-1]["id"] if events else None)):
        raise ValueError("invalid coverage window")
    capture = coverage["capture"]
    _observation_fields(capture, {"durable", "semantic", "application", "unattributed"})
    if (any(capture[key] not in {"captured", "partial", "unknown"} for key in ("durable", "semantic", "application"))
            or capture["unattributed"] != "unknown"):
        raise ValueError("invalid capture coverage")
    gaps = coverage["gaps"]
    _observation_fields(gaps, {"reasons", "dropped_lower_bound", "unmeasured_loss"})
    if (not isinstance(gaps["reasons"], list) or any(not isinstance(item, str) or item not in V2_GAPS for item in gaps["reasons"])
            or gaps["reasons"] != sorted(set(gaps["reasons"])) or not _int(gaps["dropped_lower_bound"])
            or type(gaps["unmeasured_loss"]) is not bool):
        raise ValueError("invalid gap coverage")
    epochs = coverage["epochs"]
    _observation_fields(epochs, {"items", "earlier"})
    if not isinstance(epochs["items"], list) or len(epochs["items"]) > 32 or epochs["earlier"] not in {"none", "omitted"}:
        raise ValueError("invalid epoch coverage")
    seen = set()
    for epoch in epochs["items"]:
        _observation_fields(epoch, {"ref", "conversation_ref", "scope", "state", "opened_at", "closed_at", "first_commit_ref", "last_commit_ref", "last_semantic_ref"})
        for key in ("ref", "conversation_ref", "first_commit_ref", "last_commit_ref", "last_semantic_ref"):
            _observation_reference(epoch[key], nullable=key not in {"ref", "conversation_ref"})
        opened = _observation_stamp(epoch["opened_at"])
        closed = _observation_stamp(epoch["closed_at"]) if epoch["closed_at"] is not None else None
        if (epoch["ref"] in seen or epoch["scope"] not in {"root", "owned_child"} or epoch["state"] not in {"open", "closed", "uncertain"}
                or opened > captured + 2 or closed is not None and (closed < opened or closed > captured + 2)
                or epoch["state"] == "closed" and closed is None or epoch["state"] == "open" and closed is not None):
            raise ValueError("invalid epoch")
        seen.add(epoch["ref"])
    usage = coverage["usage"]
    _observation_fields(usage, {"source", "billing", "items", "earlier"})
    if (usage["source"] != "pi.usage" or usage["billing"] != "unverified" or usage["earlier"] not in {"none", "omitted"}
            or not isinstance(usage["items"], list) or len(usage["items"]) > 16):
        raise ValueError("invalid usage coverage")
    seen = set()
    for row in usage["items"]:
        _observation_fields(row, {"conversation_ref", "scope", "attribution", "start", "end", "delta"})
        _observation_reference(row["conversation_ref"])
        if (row["conversation_ref"] in seen or row["scope"] not in {"root", "owned_child"}
                or row["attribution"] not in {"owned_revision", "conversation_only", "unknown"}):
            raise ValueError("invalid usage ownership")
        seen.add(row["conversation_ref"])
        for key in ("start", "end"):
            if row[key] is not None:
                _observation_usage_values(row[key], bound=True)
        if row["delta"] is not None:
            _observation_usage_values(row["delta"])
            if row["attribution"] != "owned_revision" or row["start"] is None or row["end"] is None:
                raise ValueError("invalid usage attribution")
            for key in USAGE_COUNTERS:
                start, end = row["start"][key], row["end"][key]
                expected = None if start is None or end is None else end - start
                if expected is not None and expected < 0 or row["delta"][key] != expected:
                    raise ValueError("invalid usage delta")


def spirit_snapshot_facts_v2(control_id, revision, snapshot):
    validate_spirit_snapshot_v2(snapshot, revision=revision)
    if not isinstance(control_id, str) or not CONTROL.fullmatch(control_id):
        raise ValueError("invalid intent control")
    events = snapshot["events"]
    return {
        "schema": "egregore.spirit-session-facts/v2", "harness": "pi-durable", "subject_kind": "durable-intent",
        "control_id": control_id, "intents": 1, "current_revision": revision,
        "projection_revision": snapshot["coverage"]["projection_revision"], "state": snapshot["state"],
        "observed_event_count": len(events), "observed_event_counts": {
            "source": dict(sorted(Counter(item["source"] for item in events).items())),
            "kind": dict(sorted(Counter(item["kind"] for item in events).items()))},
        "events": events, "coverage": snapshot["coverage"],
        "observed_through": max((item["observed_at"] for item in events), key=_observation_stamp, default=None),
        "captured_at": snapshot["captured_at"], "cost": None, "duration": None,
        "canonical_transcript": False, "complete_history": False,
    }


# Public integrity checks only. These closed historical facts neither authenticate
# their producer nor confer permission to obtain the underlying private sources.
EVIDENCE_REASONS = {"not_recorded", "source_unavailable", "source_limit", "identity_conflict",
    "stale_revision", "stale_attempt", "pending_capture", "capture_failed", "historical_retention", "unknown_schema"}
EVIDENCE_DOMAINS = {"generation", "recipe", "capability_lock", "authority", "artifacts", "outcome", "repair", "capture"}
EVIDENCE_EXTRA = ("evidence", "evidence_history", "observation_fingerprint", "pair_digest")


def _ev_enum(*values):
    return lambda value: isinstance(value, str) and value in values


def _ev_nullable(check):
    return lambda value: value is None or check(value)


def _ev_hash(value):
    return isinstance(value, str) and HASH.fullmatch(value) is not None


def _ev_object(shape):
    return lambda value: (isinstance(value, dict) and set(value) == set(shape)
                          and all(check(value[key]) for key, check in shape.items()))


def _ev_array(check, limit, key=lambda value: value, *, ordered=True):
    def valid(value):
        if not isinstance(value, list) or len(value) > limit or not all(check(item) for item in value):
            return False
        identities = [key(item) for item in value]
        return len(set(identities)) == len(identities) and (not ordered or identities == sorted(identities))
    return valid


_EV_REF = _ev_nullable(_ev_hash)
_EV_DOMAIN = {"status": _ev_enum("retained", "missing", "conflicting", "truncated", "not_applicable"),
              "reason": _ev_nullable(_ev_enum(*EVIDENCE_REASONS))}
_EV_ERROR = _ev_nullable(_ev_enum("cancelled", "deadline", "lease_lost", "verification_failed", "output_limit", "execution_failed", "unknown"))
_EV_GENERATION_REFS = ("generation_digest", "descriptor_digest", "source_binding_digest", "source_digest", "registry_digest",
                       "policy_digest", "persona_digest", "model_ref", "dependency_digest")
_EV_RECIPE_REFS = ("binding_digest", "recipe_ref", "recipe_digest", "candidate_subject", "candidate_envelope", "catalog_snapshot",
                   "generation_digest", "registry_digest", "policy_digest", "profile_ref", "scope_digest")
_EV_AUTHORITY_REFS = ("actor_ref", "caller_ref", "grant_ref", "audience_ref", "profile_ref", "origin_ref", "parent_request_ref", "admission_digest", "validator_ref")
_EV_CHECK = {"check_ref": _ev_hash, "evaluator_ref": _ev_hash, "evaluator_code_digest": _EV_REF,
             "status": _ev_enum("passed", "failed", "inconclusive"), "scope": _ev_enum("artifact_ownership", "artifact_retention", "repair_preparation", "unknown"),
             "basis": _ev_enum("retained_host_check"), "evidence_refs": _ev_array(_ev_hash, 30)}
_EV_CAPABILITY = {**{key: _ev_hash for key in ("capability_ref", "definition_digest", "package_digest", "recipe_digest", "generation_digest")},
                  "adapter_refs": _ev_array(_ev_hash, 16), "tool_refs": _ev_array(_ev_hash, 32), "binding": _ev_enum("admitted_definition")}
_EV_REPAIR_CHECK = {"check_ref": _ev_hash, **{key: _EV_REF for key in ("command_ref", "manifest_digest", "verifier_digest")},
                    "status": _ev_enum("passed", "failed", "inconclusive"), "identity_scope": _ev_enum("declared_files", "configuration_only", "unknown")}
_EV_REPAIR = {**_EV_DOMAIN, **{key: _EV_REF for key in ("receipt_digest", "task_ref", "accepted_event_ref", "accepted_result_ref",
              "accepted_source_ref", "source_revision_ref", "base_revision_ref", "configuration_digest", "patch_digest")},
              "repair_attempt": _ev_nullable(_int), "lease_epoch": _ev_nullable(_int),
              "accepted_state": _ev_nullable(_ev_enum("review_ready", "failed", "needs_attention")),
              "result_state": _ev_nullable(_ev_enum("ready_for_review", "cancelled", "timed_out", "failed", "needs_attention", "unknown")),
              "verification": _ev_array(_ev_object(_EV_REPAIR_CHECK), 20, lambda row: row["check_ref"], ordered=False),
              "error_class": _EV_ERROR, "evidence_scope": _ev_enum("none", "accepted_repair_preparation"),
              "verification_identity": _ev_enum("retained_declared_files", "configuration_only", "unknown")}
_EV_ARTIFACT = {"artifact_ref": _ev_hash, "kind": _ev_enum("finding", "proposal", "issue_registration"), "request_ref": _ev_hash,
                **{key: _EV_REF for key in ("source_fingerprint", "task_ref", "capability_ref", "result_ref")},
                "retention": _ev_enum("retained", "missing", "conflicting"), "external_result": _ev_enum("unknown", "accepted_preparation"),
                "check_refs": _ev_array(_ev_hash, 32)}
_EV_OUTCOME = {**_EV_DOMAIN, "execution": _ev_enum(*STATE["execution"]), "current_state": _ev_enum(*STATE["outcome"]),
               **{key: _EV_REF for key in ("report_ref", "acceptance_contract_digest", "validator_ref")},
               "reported_state": _ev_nullable(_ev_enum("fulfilled", "partial", "needs_input", "blocked", "failed")),
               "reported_evidence_refs": _ev_array(_ev_hash, 30), "resolved_state": _ev_nullable(_ev_enum(*STATE["outcome"])),
               "verification": _ev_enum(*STATE["verification"]),
               "basis": _ev_nullable(_ev_enum("host_registered_checks", "reported_with_bounded_host_checks", "host_execution_or_missing_report")),
               "checks": _ev_array(_ev_object(_EV_CHECK), 32, lambda row: row["check_ref"]),
               "limitation_refs": _ev_array(_ev_hash, 20), "unmet_requirement_refs": _ev_array(_ev_hash, 20), "error_class": _EV_ERROR}
_EV_COVERAGE = {"state": _ev_enum("complete", "partial"),
                **{key: _ev_array(_ev_enum(*EVIDENCE_DOMAINS), 8) for key in ("missing", "truncated", "conflicting")},
                "reasons": _ev_array(_ev_enum(*EVIDENCE_REASONS), 10)}
_EV_BODY = {"app_attempt": _int,
            "generation": _ev_object({**_EV_DOMAIN, **{key: _EV_REF for key in _EV_GENERATION_REFS},
                "provider_evidence": _ev_enum("host_built", "simulated_host", "unknown"),
                "dependency_evidence": _ev_enum("lock_and_installed_metadata", "unknown"), "external_adapter_evidence": _ev_enum("unavailable")}),
            "recipe": _ev_object({**_EV_DOMAIN, **{key: _EV_REF for key in _EV_RECIPE_REFS}, "selection_evidence": _ev_enum("retained_selection", "unknown"),
                "capability_lock": _ev_object({**_EV_DOMAIN, "lock_digest": _EV_REF,
                    "entries": _ev_array(_ev_object(_EV_CAPABILITY), 32, lambda row: row["capability_ref"])})}),
            "authority": _ev_object({**_EV_DOMAIN, "owner_ref": _ev_hash, **{key: _EV_REF for key in _EV_AUTHORITY_REFS},
                "basis": _ev_enum("retained_admission", "retained_mapping", "partial_legacy", "unknown")}),
            "artifacts": _ev_array(_ev_object(_EV_ARTIFACT), 64, lambda row: row["artifact_ref"]),
            "outcome": _ev_object(_EV_OUTCOME), "repair": _ev_object(_EV_REPAIR), "coverage": _ev_object(_EV_COVERAGE)}
_EV_ROOT = {"schema": _ev_enum("egregore.spirit-evidence/v1"),
            **{key: _ev_hash for key in ("owner_ref", "job_ref", "request_ref", "evidence_digest")},
            "revision": _int, "evidence_revision": lambda value: _int(value) and value > 0, "evidence": _ev_object(_EV_BODY)}


def _evidence_hash(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True).encode()).hexdigest()


def validate_spirit_evidence(value):
    if not _ev_object(_EV_ROOT)(value) or len(json.dumps(value, separators=(",", ":")).encode()) > 64 * 1024:
        raise ValueError("invalid spirit evidence")
    body = value["evidence"]
    covered = {key: body[key] for key in ("generation", "recipe", "authority", "outcome", "repair")}
    covered["capability_lock"] = body["recipe"]["capability_lock"]
    coverage = body["coverage"]
    for name, domain in covered.items():
        if (domain["reason"] is None) != (domain["status"] in {"retained", "not_applicable"}):
            raise ValueError("invalid evidence coverage")
        if domain["status"] in {"missing", "truncated", "conflicting"} and (name not in coverage[domain["status"]] or domain["reason"] not in coverage["reasons"]):
            raise ValueError("invalid evidence coverage")
    if coverage["state"] != ("partial" if any(coverage[key] for key in ("missing", "truncated", "conflicting", "reasons")) else "complete"):
        raise ValueError("invalid evidence coverage")
    for name, required in (("generation", tuple(key for key in _EV_GENERATION_REFS if key != "source_binding_digest")),
                           ("recipe", _EV_RECIPE_REFS), ("authority", tuple(key for key in _EV_AUTHORITY_REFS if key != "parent_request_ref"))):
        if body[name]["status"] == "retained" and any(body[name][key] is None for key in required):
            raise ValueError("invalid retained provenance")
    if body["authority"]["owner_ref"] != value["owner_ref"]:
        raise ValueError("invalid evidence owner")
    recipe, repair = body["recipe"], body["repair"]
    lock = recipe["capability_lock"]
    if (lock["status"] != "retained" and lock["entries"]
            or lock["status"] == "retained" and (lock["lock_digest"] is None or recipe["status"] != "retained")
            or any(row["recipe_digest"] != recipe["recipe_digest"] or row["generation_digest"] != recipe["generation_digest"] for row in lock["entries"])):
        raise ValueError("invalid capability evidence")
    artifacts = {row["artifact_ref"] for row in body["artifacts"]}
    checks = {row["check_ref"] for row in body["outcome"]["checks"]}
    capabilities = {row["capability_ref"] for row in lock["entries"]}
    for row in body["artifacts"]:
        if (row["request_ref"] != value["request_ref"] or not set(row["check_refs"]) <= checks
                or row["capability_ref"] is not None and (row["capability_ref"] not in capabilities or row["task_ref"] is None)
                or row["retention"] in {"missing", "conflicting"} and "artifacts" not in coverage[row["retention"]]
                or row["external_result"] == "unknown" and row["result_ref"] is not None
                or row["external_result"] == "accepted_preparation" and (row["result_ref"] is None or repair["evidence_scope"] != "accepted_repair_preparation")):
            raise ValueError("invalid artifact attribution")
    if (not set(body["outcome"]["reported_evidence_refs"]) <= artifacts
            or any(not set(row["evidence_refs"]) <= artifacts for row in body["outcome"]["checks"])):
        raise ValueError("invalid outcome attribution")
    if repair["status"] == "retained" and any(repair[key] is None for key in ("task_ref", "repair_attempt", "lease_epoch", "accepted_event_ref", "accepted_result_ref", "accepted_state", "result_state", "accepted_source_ref")):
        raise ValueError("invalid repair acceptance")
    if (repair["evidence_scope"] == "accepted_repair_preparation" and (repair["status"] != "retained" or repair["accepted_state"] != "review_ready"
            or repair["result_state"] != "ready_for_review" or repair["patch_digest"] is None or not repair["verification"]
            or any(row["status"] != "passed" for row in repair["verification"]))
            or any(row["identity_scope"] == "declared_files" and any(row[key] is None for key in ("command_ref", "manifest_digest", "verifier_digest")) for row in repair["verification"])):
        raise ValueError("invalid repair verification")
    if value["evidence_digest"] != _evidence_hash({key: value[key] for key in ("schema", "owner_ref", "job_ref", "revision", "request_ref", "evidence")}):
        raise ValueError("invalid evidence digest")
    return value


def spirit_evidence_pair_digest(projection_revision, observation_fingerprint, evidence, history):
    validate_spirit_evidence(evidence)
    if (not _int(projection_revision) or not _ev_hash(observation_fingerprint)
            or not _ev_object({"retained": lambda value: _int(value, 32) and value > 0, "dropped": _int})(history)
            or history["retained"] + history["dropped"] != evidence["evidence_revision"]):
        raise ValueError("invalid evidence pair")
    return _evidence_hash([evidence["owner_ref"], evidence["job_ref"], evidence["revision"], projection_revision,
                           observation_fingerprint, evidence["evidence_revision"], evidence["evidence_digest"], history])


def validate_spirit_snapshot_v3(snapshot, *, revision):
    _observation_fields(snapshot, {"state", "events", "coverage", "captured_at", *EVIDENCE_EXTRA})
    if len(json.dumps(snapshot, separators=(",", ":")).encode()) > 256 * 1024:
        raise ValueError("evidence snapshot exceeds byte limit")
    validate_spirit_snapshot_v2({key: snapshot[key] for key in ("state", "events", "coverage", "captured_at")}, revision=revision)
    evidence, state = snapshot["evidence"], snapshot["state"]
    paired = spirit_evidence_pair_digest(snapshot["coverage"]["projection_revision"], snapshot["observation_fingerprint"], evidence, snapshot["evidence_history"])
    recorded = evidence["evidence"]
    if (paired != snapshot["pair_digest"] or evidence["revision"] != revision or recorded["app_attempt"] != state["attempt"]
            or any(recorded["outcome"][key] != state[target] for key, target in (("execution", "execution"), ("current_state", "outcome"), ("verification", "verification")))):
        raise ValueError("evidence pair differs from observation")


def spirit_snapshot_facts_v3(control_id, revision, snapshot):
    validate_spirit_snapshot_v3(snapshot, revision=revision)
    core = {key: snapshot[key] for key in ("state", "events", "coverage", "captured_at")}
    return {**spirit_snapshot_facts_v2(control_id, revision, core), "schema": "egregore.spirit-session-facts/v3",
            **{key: snapshot[key] for key in EVIDENCE_EXTRA}}



def _marker_key(key):
    return key.strip().strip("\"'").casefold() if isinstance(key, str) else ""


def native_marked(meta):
    return isinstance(meta, dict) and any(_marker_key(key) in MARKERS
        and (key != "subject_kind" or value != "human-session") for key, value in meta.items())


def classify_record(meta, text=""):
    if not isinstance(meta, dict):
        return "unsupported-native"
    # Some generic Markdown readers discard indented header lines. Preserve
    # malformed marker detection without treating that spelling as an identity.
    if isinstance(text, str) and text.startswith("---\n"):
        for line in text[4:].partition("\n---")[0].splitlines():
            key, sep, _ = line.partition(":")
            if sep and _marker_key(key) in MARKERS and key != _marker_key(key):
                return "unsupported-native"
    if not native_marked(meta):
        return "human-session"
    if any(_marker_key(key) in MARKERS and key != _marker_key(key) for key in meta):
        return "unsupported-native"
    if (meta.get("kind") != "session-record" or meta.get("producer") != PRODUCER
            or meta.get("subject_kind") != "durable-intent" or not CONTROL.fullmatch(str(meta.get("session", "")))
            or not PRINCIPAL.fullmatch(str(meta.get("producer_principal_id", "")))
            or meta.get("from") != meta.get("producer_principal_id")
            or not ACTOR.fullmatch(str(meta.get("record_owner_actor_id", "")))
            or meta.get("requester_actor_id") != meta.get("record_owner_actor_id")
            or not isinstance(meta.get("producer_identity"), str) or not 1 <= len(meta["producer_identity"]) <= 160
            or not _int(meta.get("record_revision")) or meta["record_revision"] < 1
            or not isinstance(meta.get("detail"), str) or meta["detail"] not in {"metadata", "stub"}):
        return "unsupported-native"
    if meta["detail"] != "stub" and (not _int(meta.get("source_revision"))
            or not HASH.fullmatch(str(meta.get("source_snapshot_digest", "")))
            or not _int(meta.get("observed_event_count"), 512)
            or meta.get("through") is not None and not _stamp(meta["through"])):
        return "unsupported-native"
    if meta["detail"] != "stub" and any(key in meta for key in ("source_projection_version", "source_projection_revision", "source_evidence_revision")):
        if (type(meta.get("source_projection_version")) is not int or meta["source_projection_version"] not in {2, 3}
                or not _int(meta.get("source_projection_revision")) or not _int(meta["observed_event_count"], 256)):
            return "unsupported-native"
        if meta["source_projection_version"] == 3:
            if not _int(meta.get("source_evidence_revision")) or meta["source_evidence_revision"] < 1:
                return "unsupported-native"
        elif "source_evidence_revision" in meta:
            return "unsupported-native"
    return "durable-intent"


def _object(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate metadata field")
        value[key] = item
    return value


def decode_spirit_json(raw):
    """Reject ambiguous keys and non-JSON numbers at private/public boundaries."""
    def invalid_constant(_value):
        raise ValueError("invalid metadata number")
    return json.loads(raw, object_pairs_hook=_object, parse_constant=invalid_constant)


def _facts(meta, text):
    if not isinstance(text, str) or len(text.encode()) > 256 * 1024:
        return None
    sections = re.findall(r"^## Observed metadata\n\n```json\n(.*?)\n```\s*(?=\Z)", text, re.M | re.S)
    if len(sections) != 1:
        return None
    try:
        value = decode_spirit_json(sections[0])
        if isinstance(value, dict) and value.get("schema") in {"egregore.spirit-session-facts/v2", "egregore.spirit-session-facts/v3"}:
            version = 3 if value["schema"].endswith("/v3") else 2
            if (meta.get("source_projection_version") != version or type(meta.get("source_projection_version")) is not int
                    or not _int(meta.get("source_projection_revision"))):
                return None
            snapshot = {key: value[key] for key in ("state", "events", "coverage", "captured_at", *(EVIDENCE_EXTRA if version == 3 else ()))}
            builder = spirit_snapshot_facts_v3 if version == 3 else spirit_snapshot_facts_v2
            expected = builder(meta["session"], meta["source_revision"], snapshot)
            if (version == 3 and (not _int(meta.get("source_evidence_revision"))
                    or meta["source_evidence_revision"] != expected["evidence"]["evidence_revision"])
                    or version == 2 and "source_evidence_revision" in meta):
                return None
            if (expected["projection_revision"] != meta["source_projection_revision"]
                    or expected["observed_event_count"] != meta["observed_event_count"]
                    or expected["observed_through"] != meta.get("through")
                    or json.dumps(expected, sort_keys=True, separators=(",", ":")) != json.dumps(value, sort_keys=True, separators=(",", ":"))):
                return None
            return expected
        if any(key in meta for key in ("source_projection_version", "source_projection_revision", "source_evidence_revision")):
            return None
        keys = {"schema", "harness", "subject_kind", "control_id", "intents", "current_revision",
                "observed_revision_count", "state", "observed_event_count", "terminal_tool_results", "gap_counts",
                "coverage", "observed_through", "captured_at", "native_event_through", "cost", "duration",
                "generation_count", "compactions", "canonical_transcript", "complete_history"}
        if (not isinstance(value, dict) or set(value) != keys or value["schema"] != "egregore.spirit-session-facts/v1"
                or value["harness"] != "pi-durable" or value["subject_kind"] != "durable-intent"
                or value["control_id"] != meta["session"] or type(value["intents"]) is not int or value["intents"] != 1
                or not _int(value["current_revision"]) or value["current_revision"] != meta["source_revision"]
                or not _int(value["observed_revision_count"], 512) or not _int(value["observed_event_count"], 512)
                or value["observed_event_count"] != meta["observed_event_count"]
                or value["observed_through"] != meta.get("through") or not _stamp(value["captured_at"])
                or any(value[key] is not None for key in ("native_event_through", "cost", "duration", "generation_count", "compactions"))
                or value["canonical_transcript"] is not False or value["complete_history"] is not False):
            return None
        state, coverage, tools, gaps = (value[key] for key in ("state", "coverage", "terminal_tool_results", "gap_counts"))
        if (not isinstance(state, dict) or set(state) != {*STATE, "revision", "attempt"}
                or not _int(state["revision"]) or state["revision"] != meta["source_revision"] or not _int(state["attempt"])
                or any(not isinstance(state[key], str) or state[key] not in allowed for key, allowed in STATE.items())
                or not isinstance(coverage, dict) or set(coverage) != {"historical", "pi_transient", "bounded", "write_failures"}
                or coverage["historical"] != "unknown" or coverage["pi_transient"] != "unknown"
                or type(coverage["bounded"]) is not bool or not _int(coverage["write_failures"])
                or not isinstance(tools, dict) or set(tools) != {"observed", "success", "error", "unknown"}
                or any(not _int(number, 512) for number in tools.values())
                or tools["observed"] != sum(tools[key] for key in ("success", "error", "unknown"))
                or tools["observed"] > value["observed_event_count"]
                or not isinstance(gaps, dict) or not set(gaps) <= GAPS or any(not _int(number, 512) for number in gaps.values())):
            return None
        return value
    except (ValueError, KeyError, TypeError, OverflowError, RecursionError):
        return None


def record_subject(meta, text=""):
    kind = classify_record(meta, text)
    if kind != "durable-intent":
        return {"subject_kind": kind}
    if meta["detail"] == "stub":
        return {"subject_kind": kind, "held": True}
    facts = _facts(meta, text)
    result = {"subject_kind": kind, "held": False, "control_id": meta["session"], "producer": PRODUCER,
            "producer_principal_id": meta["producer_principal_id"], "record_owner_actor_id": meta["record_owner_actor_id"],
            "record_revision": meta["record_revision"], "source_revision": meta["source_revision"], "through": meta.get("through"),
            "state": facts["state"] if facts else None, "coverage": facts["coverage"] if facts else None,
            "observed_event_count": facts["observed_event_count"] if facts else None,
            "metadata_status": "validated" if facts else "unavailable", "cost": None, "duration": None,
            "complete_history": False}
    if facts and facts["schema"] in {"egregore.spirit-session-facts/v2", "egregore.spirit-session-facts/v3"}:
        result.update(projection_version=3 if facts["schema"].endswith("/v3") else 2, projection_revision=facts["projection_revision"],
                      observed_event_counts=facts["observed_event_counts"])
        if result["projection_version"] == 3:
            evidence = facts["evidence"]
            result.update(evidence_revision=evidence["evidence_revision"], evidence_coverage=evidence["evidence"]["coverage"],
                          evidence_history=facts["evidence_history"])
    return result
