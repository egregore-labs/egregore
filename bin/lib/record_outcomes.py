"""Append-only outcome attribution and comparable intervention checkpoints.

All monetary observations come from canonical records. Manifests supply intent,
verification references and allocation, never prices or an inferred acceptance.
"""
import argparse
from collections import defaultdict
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat


OUTCOMES = "outcomes.jsonl"
INTERVENTIONS = "interventions.jsonl"
SCHEMAS = {OUTCOMES: "record-outcome/v1", INTERVENTIONS: "record-intervention/v1"}
IDENT = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\Z")
EVENT = re.compile(r"[a-f0-9]{64}\Z")
ROLES = {"driver", "worker", "retry", "review"}
STATUSES = {"open", "accepted", "rejected"}
QUALITY = {"pass", "fail", "unknown"}
LIMIT = 65536


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def money(value):
    """Keep arithmetic overflow as unavailable, never JSON Infinity."""
    try:
        result = float(value)
    except (TypeError, ValueError, OverflowError):
        return None
    return round(result, 6) if math.isfinite(result) else None


def label(value, field, limit=512):
    if (not isinstance(value, str) or not value.strip() or len(value) > limit
            or re.search(r"[\x00-\x1f\x7f]", value)):
        raise ValueError(f"{field} needs a nonempty, single-line value of at most {limit} characters")
    return value.strip()


def ident(value, field="id"):
    if not isinstance(value, str) or not IDENT.fullmatch(value):
        raise ValueError(f"{field} must be a stable identifier of 1–128 letters, digits, dots, colons, underscores or hyphens")
    return value


def references(value):
    if not isinstance(value, list) or len(value) > 32:
        raise ValueError("evidence must be a list of at most 32 verification references")
    return list(dict.fromkeys(label(ref, "evidence reference", 2048) for ref in value))


def share(value):
    if isinstance(value, bool):
        raise ValueError("share must be greater than zero and at most one")
    try:
        number = Decimal(str(value))
    except (InvalidOperation, ValueError):
        raise ValueError("share must be greater than zero and at most one") from None
    if not number.is_finite() or not 0 < number <= 1 or number.as_tuple().exponent < -9:
        raise ValueError("share must be greater than zero and at most one, with at most 9 decimal places")
    return format(number.normalize(), "f")


def outcome_body(value):
    fields = {"id", "cohort", "status", "evidence", "attribution_complete", "quality", "sessions"}
    if (not isinstance(value, dict) or not fields <= set(value)
            or set(value) - fields - {"findings", "thread"}):
        raise ValueError("outcome manifest requires exactly id, cohort, status, evidence, attribution_complete, quality and sessions")
    body = dict(value)
    body["id"] = ident(body["id"])
    body["cohort"] = label(body["cohort"], "cohort", 160)
    if (not isinstance(body["status"], str) or not isinstance(body["quality"], str)
            or body["status"] not in STATUSES or body["quality"] not in QUALITY):
        raise ValueError("status is open|accepted|rejected and quality is pass|fail|unknown")
    if type(body["attribution_complete"]) is not bool:
        raise ValueError("attribution_complete must be true or false")
    body["evidence"] = references(body["evidence"])
    if body["status"] != "open":
        if not body["evidence"]:
            raise ValueError("accepted and rejected outcomes require verification evidence")
        if body["quality"] != ("pass" if body["status"] == "accepted" else "fail"):
            raise ValueError("accepted outcomes require passing quality; rejected outcomes require failing quality")
    sessions, seen = body["sessions"], set()
    if not isinstance(sessions, list) or len(sessions) > 128:
        raise ValueError("sessions must be a list of at most 128 contributing cost scopes")
    normalized = []
    for scope in sessions:
        if not isinstance(scope, dict) or set(scope) != {"session", "role", "share"}:
            raise ValueError("each cost scope requires exactly session, role and share")
        session = ident(scope["session"], "session")
        if session in seen or not isinstance(scope["role"], str) or scope["role"] not in ROLES:
            raise ValueError("each session occurs once per outcome, with role driver|worker|retry|review")
        seen.add(session)
        normalized.append({"session": session, "role": scope["role"], "share": share(scope["share"])})
    if body["attribution_complete"] and not normalized:
        raise ValueError("complete attribution requires at least one contributing cost scope")
    body["sessions"] = sorted(normalized, key=lambda row: row["session"])
    findings = body.get("findings", [])
    if not isinstance(findings, list) or len(findings) > 32:
        raise ValueError("findings must contain at most 32 stable failure-class identifiers")
    body["findings"] = sorted(set(ident(item, "finding") for item in findings))
    thread = body.get("thread")
    if thread is not None:
        if not isinstance(thread, dict) or set(thread) != {"id", "revision"}:
            raise ValueError("thread requires exactly id and revision")
        if not isinstance(thread["id"], str) or not re.fullmatch(r"thread:[a-z0-9]+(?:-[a-z0-9]+)*", thread["id"]):
            raise ValueError("thread id must be thread:<slug>")
        body["thread"] = {"id": ident(thread["id"], "thread"),
                          "revision": label(thread["revision"], "thread revision", 256)}
    # Omit the absent extension so legacy event digests remain valid.
    return body


def intervention_body(value, internal=False):
    fields = {"id", "cohort", "finding", "change", "baseline", "post", "decision", "evidence"}
    if internal:
        fields |= {"baseline_events", "baseline_records"}
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError("intervention manifest requires exactly id, cohort, finding, change, baseline, post, decision and evidence")
    body = dict(value)
    body["id"] = ident(body["id"])
    for field in ("cohort", "finding", "change"):
        body[field] = label(body[field], field, 160 if field == "cohort" else 2048)
    for field in ("baseline", "post"):
        values = body[field]
        if not isinstance(values, list) or len(values) > 1000:
            raise ValueError(f"{field} must contain at most 1000 outcome identifiers")
        body[field] = [ident(item, field) for item in values]
        if len(set(body[field])) != len(body[field]):
            raise ValueError(f"{field} cannot repeat an outcome")
    if not body["baseline"]:
        raise ValueError("an intervention needs at least one comparable baseline outcome")
    if set(body["baseline"]) & set(body["post"]):
        raise ValueError("baseline and post outcomes must be disjoint")
    if not isinstance(body["decision"], str) or body["decision"] not in {"observe", "keep", "revise", "revert"}:
        raise ValueError("decision is observe|keep|revise|revert")
    body["evidence"] = references(body["evidence"])
    if body["decision"] != "observe" and not body["evidence"]:
        raise ValueError("an intervention decision requires verification evidence")
    if internal:
        snapshots = body["baseline_events"]
        if (not isinstance(snapshots, dict) or set(snapshots) != set(body["baseline"])
                or any(not isinstance(event, str) or not EVENT.fullmatch(event) for event in snapshots.values())):
            raise ValueError("baseline event references are incomplete")
        records = body["baseline_records"]
        if (not isinstance(records, dict)
                or any(not isinstance(sid, str) or not IDENT.fullmatch(sid)
                       or (digest is not None and (not isinstance(digest, str) or not EVENT.fullmatch(digest)))
                       for sid, digest in records.items())):
            raise ValueError("baseline record references are invalid")
    return body


def read_history(sr, memory, ledger):
    """Read the whole append-only ledger with bounded rows and fail-closed coverage."""
    sessions = sr.sessions_directory(memory)
    result = {"coverage": "missing", "latest": {}, "events": {}, "conflicts": []}
    if sessions is None:
        return result
    try:
        fd = os.open(sessions / ledger, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        return result
    except OSError:
        result["coverage"] = "unavailable"
        return result
    grouped = defaultdict(dict)
    result["coverage"] = "complete"
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            result["coverage"] = "unavailable"
            return result
        while True:
            raw = stream.readline(LIMIT + 1)
            if not raw:
                break
            if len(raw) > LIMIT:
                while raw and not raw.endswith(b"\n"):
                    raw = stream.readline(LIMIT + 1)
                result["coverage"] = "partial"
                continue
            if not raw.strip():
                continue
            if not raw.endswith(b"\n"):
                result["coverage"] = "partial"
            try:
                event = json.loads(raw)
                if (not isinstance(event, dict)
                        or set(event) != {"schema", "event_id", "previous", "at", "by", "session", "body"}
                        or event["schema"] != SCHEMAS[ledger]
                        or not isinstance(event["event_id"], str) or not EVENT.fullmatch(event["event_id"])
                        or (event["previous"] is not None and
                            (not isinstance(event["previous"], str) or not EVENT.fullmatch(event["previous"])))):
                    raise ValueError("invalid event")
                label(event["by"], "actor")
                ident(event["session"], "native session")
                stamp = datetime.fromisoformat(event["at"])
                if stamp.tzinfo is None:
                    raise ValueError("event time needs timezone")
                body = outcome_body(event["body"]) if ledger == OUTCOMES else intervention_body(event["body"], True)
                if body != event["body"]:
                    raise ValueError("noncanonical event")
                hashed = dict(event)
                hashed.pop("event_id")
                if hashlib.sha256(canonical(hashed).encode()).hexdigest() != event["event_id"]:
                    raise ValueError("event digest mismatch")
                event_id, entity = event["event_id"], body["id"]
                if event_id in result["events"] and event != result["events"][event_id]:
                    raise ValueError("conflicting duplicate event")
                grouped[entity][event_id] = event
                result["events"][event_id] = event
            except (ValueError, TypeError, KeyError, RecursionError, OverflowError):
                result["coverage"] = "partial"
    for entity, events in grouped.items():
        children = defaultdict(list)
        for event in events.values():
            children[event["previous"]].append(event)
        current, visited = None, set()
        invalid_chain = False
        while len(children[current["event_id"] if current else None]) == 1:
            next_event = children[current["event_id"] if current else None][0]
            if current:
                old, new = current["body"], next_event["body"]
                immutable = ("cohort",) if ledger == OUTCOMES else (
                    "cohort", "finding", "change", "baseline", "baseline_events", "baseline_records")
                if (any(old[field] != new[field] for field in immutable)
                        or (ledger == INTERVENTIONS and not set(old["post"]) <= set(new["post"]))):
                    invalid_chain = True
                    break
            current = next_event
            if current["event_id"] in visited:
                break
            visited.add(current["event_id"])
        if invalid_chain or current is None or len(visited) != len(events):
            result["conflicts"].append(entity)
            result["coverage"] = "partial"
        else:
            result["latest"][entity] = current
    return result


def record_index(sr, memory):
    index, conflicts, withheld = {}, set(), set()
    for _, meta, _ in sr.record_files(memory):
        sid = meta.get("session")
        if meta.get("kind") != "session-record" or not isinstance(sid, str):
            continue
        if meta.get("detail") == "stub":
            withheld.add(sid)
        try:
            revision = int(meta.get("record_revision", 0))
        except (TypeError, ValueError):
            revision = 0
        old = index.get(sid)
        if old is None or revision > old[0]:
            index[sid] = (revision, meta)
            conflicts.discard(sid)
        elif revision == old[0] and meta != old[1]:
            conflicts.add(sid)
    return {sid: dict(meta, detail="stub") if sid in withheld else meta
            for sid, (_, meta) in index.items()}, conflicts


def record_digest(meta):
    if meta is None:
        return None
    fields = ("session", "status", "detail", "record_revision", "cost_usd", "cost_source",
              "cost_coverage", "cost_sessions", "cost_basis")
    return hashlib.sha256(canonical({key: meta.get(key) for key in fields}).encode()).hexdigest()


def join_outcomes(sr, history, records, conflicts, ctx=None):
    """Allocate aggregate record scopes, retaining incomplete observations."""
    rows, allocations, components, scope_users = {}, defaultdict(Decimal), {}, defaultdict(set)
    # Correcting an attribution changes the projection, not the accounting
    # universe. A formerly linked source remains visibly unallocated at zero.
    for event in history["events"].values():
        for scope in event["body"]["sessions"]:
            allocations[scope["session"]] += 0
    for entity, event in history["latest"].items():
        body = event["body"]
        reasons, priced, amount, roles, withheld = [], 0, Decimal(0), defaultdict(Decimal), False
        joined_sessions = set()
        if not body["attribution_complete"]:
            reasons.append("attribution-not-closed")
        if not body["sessions"]:
            reasons.append("no-contributing-sessions")
        for scope in body["sessions"]:
            sid, fraction = scope["session"], Decimal(scope["share"])
            allocations[sid] += fraction
            scope_users[sid].add(entity)
            meta = records.get(sid)
            if (ctx is not None and ctx.held(sid)) or (meta and meta.get("detail") == "stub"):
                withheld = True
                reasons.append("withheld-record")
                continue
            if meta is None:
                reasons.append("missing-record")
                continue
            joined_sessions.add(sid)
            included = meta.get("cost_sessions")
            if (not isinstance(included, list) or not included or sid not in included
                    or any(not isinstance(item, str) or not IDENT.fullmatch(item) for item in included)
                    or len(set(included)) != len(included)):
                reasons.append("cost-scope-unknown")
            else:
                components[sid] = set(included)
                if any(records.get(item, {}).get("detail") == "stub"
                       or (ctx is not None and ctx.held(item)) for item in included):
                    withheld = True
                    reasons.append("withheld-record")
                    continue
            if sid in conflicts:
                reasons.append("conflicting-session-records")
            if meta.get("status") != "final":
                reasons.append("session-in-progress")
            if meta.get("cost_coverage") != "complete":
                reasons.append("cost-coverage-incomplete")
            value = sr.vitals_cost(meta.get("cost_usd"))
            if value is None or meta.get("cost_source") == "unavailable" or sid in conflicts:
                reasons.append("cost-unavailable")
            else:
                allocated = Decimal(str(value)) * fraction
                amount += allocated
                roles[scope["role"]] += allocated
                priced += 1
        observed = money(amount) if priced else None
        if priced and observed is None:
            reasons.append("cost-arithmetic-overflow")
        rows[entity] = {"id": entity, "cohort": body["cohort"], "status": body["status"],
                        "quality": body["quality"], "evidence": body["evidence"], "event_id": event["event_id"],
                        "findings": body["findings"],
                        "thread": body.get("thread"),
                        "observed_cost_usd": observed,
                        "cost_by_scope_role_usd": {role: money(cost) for role, cost in roles.items()
                                                   if money(cost) is not None},
                        "priced_scopes": priced, "total_scopes": len(body["sessions"]),
                        "reasons": reasons, "_withheld": withheld, "_joined_sessions": joined_sessions}
    unallocated = Decimal(0)
    unallocated_known = False
    for sid, fraction in allocations.items():
        if fraction != 1:
            reason = "overallocated-session" if fraction > 1 else "unallocated-session-share"
            for entity in scope_users[sid]:
                rows[entity]["reasons"].append(reason)
                if fraction > 1:
                    rows[entity]["observed_cost_usd"] = None
                    rows[entity]["cost_by_scope_role_usd"] = {}
            if fraction == 0:
                for row in rows.values():
                    row["reasons"].append("unallocated-historical-session")
            meta = records.get(sid, {})
            value = sr.vitals_cost(meta.get("cost_usd"))
            included = meta.get("cost_sessions")
            private = (meta.get("detail") == "stub" or (ctx is not None and ctx.held(sid))
                       or (isinstance(included, list) and any(isinstance(item, str)
                           and (records.get(item, {}).get("detail") == "stub"
                                or (ctx is not None and ctx.held(item))) for item in included)))
            if (fraction < 1 and value is not None and meta.get("cost_source") != "unavailable"
                    and not private and not any(rows[entity]["_withheld"] for entity in scope_users[sid])):
                unallocated += Decimal(str(value)) * (1 - fraction)
                unallocated_known = True
    overlapping = set()
    by_component = defaultdict(set)
    for sid, members in components.items():
        for member in members:
            by_component[member].add(sid)
    for aggregate_ids in by_component.values():
        if len(aggregate_ids) > 1:
            overlapping.update(aggregate_ids)
    for sid in overlapping:
        for entity in scope_users[sid]:
            rows[entity]["reasons"].append("overlapping-parent-worker-cost")
            # Neither total nor per-role spend may double count this scope.
            rows[entity]["observed_cost_usd"] = None
            rows[entity]["cost_by_scope_role_usd"] = {}
    for row in rows.values():
        if history["coverage"] != "complete":
            row["reasons"].append("ledger-coverage-incomplete")
        row["reasons"] = sorted(set(row["reasons"]))
        row["cost_complete"] = not row["reasons"] and not row["_withheld"]
        row["cost_usd"] = row["observed_cost_usd"] if row["cost_complete"] else None
        if row["_withheld"]:
            row["observed_cost_usd"] = None
            row["cost_by_scope_role_usd"] = {}
    return rows, money(unallocated) if unallocated_known else None


def economics(rows, coverage="complete"):
    values = list(rows)
    visible = [row for row in values if not row["_withheld"]]
    accepted = sum(row["status"] == "accepted" for row in visible)
    costs = [row["observed_cost_usd"] for row in visible if row["observed_cost_usd"] is not None]
    complete = bool(values) and coverage == "complete" and all(row["cost_complete"] for row in values)
    total = money(sum(Decimal(str(value)) for value in costs)) if costs else None
    complete = complete and total is not None
    statuses = {}
    for status in sorted(STATUSES):
        selected = [row for row in visible if row["status"] == status]
        observed = [row["observed_cost_usd"] for row in selected if row["observed_cost_usd"] is not None]
        statuses[status] = {"outcomes": len(selected), "observed_cost_usd": money(sum(observed)) if observed else None}
    terminal = [row for row in visible if row["status"] != "open"]
    failed = sum(row["quality"] == "fail" for row in terminal)
    return {"status": "complete" if complete else "unavailable" if not values else "partial",
            "cost_per_accepted_outcome_usd": money(total / accepted) if complete and accepted else None,
            "observed_cost_usd": total,
            "accepted_outcomes": accepted if values else None,
            "joined_sessions": len({sid for row in visible for sid in row["_joined_sessions"]}) if values else None,
            "outcomes": len(visible), "withheld_outcomes": len(values) - len(visible),
            "complete_outcomes": sum(row["cost_complete"] for row in visible),
            "by_status": statuses, "terminal_outcomes": len(terminal), "failed_outcomes": failed,
            "failure_rate": failed / len(terminal) if terminal else None,
            "cost_basis": "canonical-record estimates; all allocated accepted, rejected and open spend",
            "scope": "declared outcomes only; undeclared organizational work is not inferred"}


def intervention_rows(history, outcome_history, joined, sr, records, conflicts, ctx):
    result = []
    for event in history["latest"].values():
        body = event["body"]
        selected = body["baseline"] + body["post"]
        if any(joined.get(item, {}).get("_withheld") for item in selected):
            result.append({"status": "withheld"})
            continue
        reasons = []
        if history["coverage"] != "complete" or outcome_history["coverage"] != "complete":
            reasons.append("ledger-coverage-incomplete")
        if any(record_digest(records.get(sid)) != digest for sid, digest in body["baseline_records"].items()):
            reasons.append("baseline-cost-record-revised")
        if any(joined.get(item, {}).get("event_id") != ref for item, ref in body["baseline_events"].items()):
            reasons.append("baseline-outcome-revised")
        baseline_events = {item: outcome_history["events"].get(ref) for item, ref in body["baseline_events"].items()}
        if any(event is None or event["body"]["id"] != item for item, event in baseline_events.items()):
            reasons.append("missing-baseline-snapshot")
        snapshots = {item: event for item, event in baseline_events.items() if event is not None}
        baseline_joined, _ = join_outcomes(sr, {**outcome_history, "latest": snapshots,
                                               "events": {event["event_id"]: event for event in snapshots.values()}},
                                           records, conflicts, ctx)
        if any(row["_withheld"] for row in baseline_joined.values()):
            result.append({"status": "withheld"})
            continue
        # Allocation completeness is assessed against the whole outcome ledger,
        # not the subset. A source can legitimately be shared across cohorts.
        for item, row in baseline_joined.items():
            if joined.get(item, {}).get("cost_complete"):
                row["reasons"] = [reason for reason in row["reasons"] if reason != "unallocated-session-share"]
                row["cost_complete"] = not row["reasons"]
                row["cost_usd"] = row["observed_cost_usd"] if row["cost_complete"] else None
        post = [joined[item] for item in body["post"] if item in joined]
        if any(item not in joined for item in selected):
            reasons.append("missing-outcome")
        if any(joined[item]["cohort"] != body["cohort"] for item in selected if item in joined):
            reasons.append("cohort-changed")
        before, after = economics(baseline_joined.values(), outcome_history["coverage"]), economics(post, outcome_history["coverage"])
        if before["status"] != "complete" or after["status"] != "complete":
            reasons.append("cost-coverage-incomplete")
        if before["terminal_outcomes"] < 5:
            reasons.append("baseline-below-five")
        observed = after["terminal_outcomes"]
        regression = (after["failure_rate"] is not None and before["failure_rate"] is not None
                      and after["failure_rate"] > before["failure_rate"])
        # Reopened previously terminal outcomes are also a direct quality signal.
        reopened = any(joined[item]["status"] == "open"
                       and any(old["body"]["id"] == item and old["body"]["status"] != "open"
                               for old in outcome_history["events"].values())
                       for item in body["post"] if item in joined)
        regression = regression or reopened
        checkpoint = ("quality-review-now" if regression else "decide-at-ten" if observed >= 10
                      else "inspect-at-five" if observed >= 5 else "collect")
        prior, current = before["cost_per_accepted_outcome_usd"], after["cost_per_accepted_outcome_usd"]
        delta = round(current - prior, 6) if not reasons and prior is not None and current is not None else None
        result.append({"id": body["id"], "cohort": body["cohort"], "finding": body["finding"],
                       "change": body["change"], "decision": body["decision"], "checkpoint": checkpoint,
                       "quality_regression": regression, "baseline": before, "post": after,
                       "unit_cost_delta_usd": delta, "reasons": sorted(set(reasons)),
                       "recommendation": ("Revisit the change now; verify the failed or reopened outcome before continuing."
                                          if regression else "Choose keep, revise or revert using cost coverage and the same quality rubric."
                                          if observed >= 10 else "Inspect the leading recurring expense and verify one focused repair."
                                          if observed >= 5 else "Continue capturing comparable outcomes and complete cost scopes."),
                       "limitation": "Small observational cohorts guide decisions; a cost change does not establish causation."})
    return result


def scorecard(sr, memory, ctx=None):
    outcome_history = read_history(sr, memory, OUTCOMES)
    intervention_history = read_history(sr, memory, INTERVENTIONS)
    records, conflicts = record_index(sr, memory) if outcome_history["latest"] else ({}, set())
    joined, unallocated = join_outcomes(sr, outcome_history, records, conflicts, ctx)
    total = economics(joined.values(), outcome_history["coverage"])
    total["unallocated_observed_cost_usd"] = unallocated
    visible = [row for row in joined.values() if not row["_withheld"]]
    public_rows = [{key: value for key, value in row.items() if not key.startswith("_")} for row in visible]
    cohorts = {cohort: economics((row for row in joined.values() if row["cohort"] == cohort), outcome_history["coverage"])
               for cohort in sorted({row["cohort"] for row in visible})}
    by_thread = {
        thread_id: {
            "reference_basis": "explicit outcome attribution; source revision is not revalidated by this report",
            "revisions": sorted({row["thread"]["revision"] for row in visible
                                 if row["thread"] and row["thread"]["id"] == thread_id}),
            **economics((row for row in joined.values() if row["thread"]
                         and row["thread"]["id"] == thread_id), outcome_history["coverage"]),
        }
        for thread_id in sorted({row["thread"]["id"] for row in visible if row["thread"]})
    }
    findings = []
    def add(code, observation, action, verification, cost=None, affected=None):
        affected = visible if affected is None else affected
        refs = list(dict.fromkeys(ref for row in affected for ref in row["evidence"]))
        findings.append({"code": code, "severity": "warning", "observation": observation,
                         "observed_cost_usd": cost,
                         "outcome_ids": [row["id"] for row in affected][:32], "evidence": refs[:32],
                         "coverage": {"outcome_ledger": outcome_history["coverage"],
                                      "complete": total["complete_outcomes"], "declared": total["outcomes"],
                                      "limitation": "Declared scope only; missing or withheld costs remain unknown."},
                         "action": action, "verification": verification})
    if total["status"] != "complete":
        add("accepted_outcome_link_missing" if not joined else "outcome_attribution_gap",
            "Accepted-outcome unit cost is unavailable until all declared contributing scopes are complete.",
            "Close contributor attribution, finish eligible records, repair missing cost coverage and allocate each aggregate scope exactly once.",
            "Every declared outcome has complete final costs; parent and worker scopes do not overlap.")
    for status, code in (("rejected", "rejected_outcome_spend"), ("open", "unfinished_outcome_spend")):
        row = total["by_status"][status]
        if row["outcomes"]:
            add(code, f"{row['outcomes']} {status} outcomes have ${row['observed_cost_usd']:.2f} observed spend."
                if row["observed_cost_usd"] is not None else f"Spend for {row['outcomes']} {status} outcomes is unknown.",
                "Inspect the linked verification evidence; fix a recurring failure or explicitly resolve obsolete work.",
                "The failure is reproduced and repaired, or the outcome receives an explicit terminal disposition.",
                row["observed_cost_usd"], [item for item in visible if item["status"] == status])
    for role in ("retry", "review"):
        affected = [row for row in visible if role in row["cost_by_scope_role_usd"]]
        role_cost = money(sum(row["cost_by_scope_role_usd"][role] for row in affected)) if affected else None
        if role_cost is not None:
            add(role + "_scope_spend", f"Explicit {role} scopes account for ${role_cost:.2f} observed spend.",
                "Inspect the most expensive retry scope and repair its repeatable cause before broadening reruns."
                if role == "retry" else "Inspect repeated review scope and the regressions it catches before changing review depth.",
                "The targeted failure passes and subsequent comparable outcomes need less retry spend."
                if role == "retry" else "The same quality checks pass and no verified regression follows a narrower review.",
                role_cost, affected)
    for finding in sorted({tag for row in visible for tag in row["findings"]}):
        affected = [row for row in visible if finding in row["findings"]]
        observed = [row["observed_cost_usd"] for row in affected if row["observed_cost_usd"] is not None]
        if len(affected) < 2:
            continue
        cost = money(sum(observed)) if observed else None
        add("recurring:" + finding,
            f"{finding} appears in {len(affected)} declared outcomes"
            + (f" associated with ${cost:.2f} observed spend." if cost is not None else "; associated spend is unknown."),
            "Open the linked verification evidence, reproduce the shared failure and implement one focused repair.",
            "The original failure passes and the next comparable cohort shows its recurrence and unit cost.",
            cost, affected)
        findings[-1]["coverage"].update(affected_outcomes=len(affected), priced_outcomes=len(observed),
                                       limitation="Associated spend is not causal or recoverable waste; finding classes overlap and are not additive.")
    interventions = intervention_rows(intervention_history, outcome_history, joined, sr, records, conflicts, ctx)
    for intervention in interventions:
        if intervention.get("quality_regression"):
            add("intervention_quality:" + intervention["id"],
                f"{intervention['id']} has a failed-outcome rate increase or a reopened outcome.",
                intervention["recommendation"],
                "Reproduce the failed quality check; record keep, revise or revert only with explicit verification evidence.",
                affected=[row for row in visible if row["id"] in intervention_history["latest"][intervention["id"]]["body"]["post"]])
    findings.sort(key=lambda item: (not item["code"].startswith("intervention_quality:"),
                                   item["observed_cost_usd"] is None, -(item["observed_cost_usd"] or 0), item["code"]))
    return {"outcome_coverage": outcome_history["coverage"], "intervention_coverage": intervention_history["coverage"],
            "unit_economics": total, "cohorts": cohorts, "outcomes": sorted(public_rows, key=lambda row: row["id"]),
            "threads": by_thread,
            "thread_attribution": {"linked": sum(bool(row["thread"]) for row in visible),
                                   "unlinked": sum(not row["thread"] for row in visible),
                                   "rule": "one primary Thread per outcome; no inferred joins or lineage cost rollups"},
            "interventions": interventions,
            "findings": findings}


def read_manifest(path):
    try:
        fd = os.open(Path(path), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, "rb") as stream:
            if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
                raise ValueError("manifest must be a regular file")
            raw = stream.read(LIMIT + 1)
            if len(raw) > LIMIT:
                raise ValueError("manifest exceeds 64 KiB")
            return json.loads(raw)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ValueError("manifest could not be read as a bounded JSON file") from exc


def record(sr, ctx, manifest, kind):
    ledger = OUTCOMES if kind == "outcome" else INTERVENTIONS
    body = outcome_body(manifest) if kind == "outcome" else intervention_body(manifest)
    current_session = sr.gate_session(ctx.root)
    if not current_session or not ctx.actor_id:
        raise ValueError("native session and Runtime actor identity are required")
    event = {}
    def validate():
        if not ctx.enabled() or not ctx.actor_id or ctx.held(current_session):
            raise ValueError("record controls withhold this event")
        history = read_history(sr, ctx.memory, ledger)
        if history["coverage"] not in {"complete", "missing"}:
            raise ValueError("ledger coverage is incomplete; repair it before appending")
        previous = history["latest"].get(body["id"])
        stored = dict(body)
        if kind == "outcome":
            if any(ctx.held(row["session"]) for row in body["sessions"]):
                raise ValueError("record controls withhold a contributing session")
            records, _ = record_index(sr, ctx.memory)
            for scope in body["sessions"]:
                meta = records.get(scope["session"], {})
                if meta.get("detail") == "stub":
                    raise ValueError("record controls withhold a contributing session")
                included = meta.get("cost_sessions")
                if isinstance(included, list) and any(isinstance(sid, str)
                        and (ctx.held(sid) or records.get(sid, {}).get("detail") == "stub") for sid in included):
                    raise ValueError("record controls withhold a contributing session")
            if previous and previous["body"]["cohort"] != body["cohort"]:
                raise ValueError("an outcome's cohort is immutable; use a successor outcome for changed scope")
            totals = defaultdict(Decimal)
            for old in history["latest"].values():
                if old["body"]["id"] != body["id"]:
                    for scope in old["body"]["sessions"]:
                        totals[scope["session"]] += Decimal(scope["share"])
            for scope in body["sessions"]:
                totals[scope["session"]] += Decimal(scope["share"])
            if any(value > 1 for value in totals.values()):
                raise ValueError("session shares would exceed one; append explicit corrected allocations first")
        else:
            outcomes = read_history(sr, ctx.memory, OUTCOMES)
            if outcomes["coverage"] != "complete":
                raise ValueError("complete outcome history is required for an intervention")
            records, _ = record_index(sr, ctx.memory)
            for item in body["baseline"] + body["post"]:
                outcome = outcomes["latest"].get(item)
                if outcome is None or outcome["body"]["cohort"] != body["cohort"]:
                    raise ValueError("every baseline and post outcome must exist in the same cohort")
                if any(ctx.held(scope["session"]) for scope in outcome["body"]["sessions"]):
                    raise ValueError("record controls withhold a contributing outcome")
                for scope in outcome["body"]["sessions"]:
                    meta = records.get(scope["session"], {})
                    included = meta.get("cost_sessions")
                    if (meta.get("detail") == "stub"
                            or (isinstance(included, list)
                                and any(isinstance(sid, str) and (ctx.held(sid) or records.get(sid, {}).get("detail") == "stub")
                                        for sid in included))):
                        raise ValueError("record controls withhold a contributing outcome")
            if any(outcomes["latest"][item]["body"]["status"] == "open" for item in body["baseline"]):
                raise ValueError("baseline outcomes must have a verified terminal disposition")
            if previous:
                old = previous["body"]
                for sid in old["baseline_records"]:
                    meta = records.get(sid, {})
                    included = meta.get("cost_sessions")
                    if (ctx.held(sid) or meta.get("detail") == "stub"
                            or (isinstance(included, list) and any(isinstance(item, str)
                                and (ctx.held(item) or records.get(item, {}).get("detail") == "stub") for item in included))):
                        raise ValueError("record controls withhold a frozen baseline")
                if any(old[field] != body[field] for field in ("cohort", "finding", "change", "baseline")):
                    raise ValueError("intervention cohort, finding, change and baseline are immutable")
                if not set(old["post"]) <= set(body["post"]):
                    raise ValueError("post outcomes cannot be removed from an intervention")
                started = min(event["at"] for event in history["events"].values()
                              if event["body"]["id"] == body["id"])
                for item in body["post"]:
                    declared = min(event["at"] for event in outcomes["events"].values()
                                   if event["body"]["id"] == item)
                    if datetime.fromisoformat(declared) <= datetime.fromisoformat(started):
                        raise ValueError("post outcomes must first be declared after intervention registration")
                stored["baseline_events"] = old["baseline_events"]
                stored["baseline_records"] = old["baseline_records"]
            else:
                if body["post"]:
                    raise ValueError("register the baseline before linking post-change outcomes")
                stored["baseline_events"] = {item: outcomes["latest"][item]["event_id"] for item in body["baseline"]}
                included = {scope["session"] for item in body["baseline"]
                            for scope in outcomes["latest"][item]["body"]["sessions"]}
                stored["baseline_records"] = {sid: record_digest(records.get(sid)) for sid in sorted(included)}
        if previous and previous["body"] == stored:
            event.update(previous)
            return False
        event.update(schema=SCHEMAS[ledger], previous=previous["event_id"] if previous else None,
                     at=datetime.now(timezone.utc).isoformat(timespec="microseconds"), by=ctx.actor_id,
                     session=current_session, body=stored)
        event["event_id"] = hashlib.sha256(canonical(event).encode()).hexdigest()
        return True
    sr.append_ledger(ctx, ledger, event, f"chore(sessions): record {kind} {body['id']}", validate=validate)
    return {"id": body["id"], "event_id": event["event_id"], "status": "recorded"}


def command(sr, ctx, argv, kind="outcome"):
    parser = argparse.ArgumentParser(prog=f"records.sh {kind}")
    sub = parser.add_subparsers(dest="action", required=True)
    write = sub.add_parser("record")
    write.add_argument("--file", required=True)
    report = sub.add_parser("report")
    report.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if not ctx.enabled():
        print(json.dumps({"status": "disabled", "reason": "session-records-off"}))
        return 0
    if args.action == "record":
        print(json.dumps(record(sr, ctx, read_manifest(args.file), kind)))
        return 0
    data = scorecard(sr, ctx.memory, ctx)
    selected = data if kind == "outcome" else {"coverage": data["intervention_coverage"], "interventions": data["interventions"]}
    if args.json:
        print(json.dumps(selected))
    elif kind == "intervention":
        for row in selected["interventions"]:
            print("withheld intervention" if row.get("status") == "withheld"
                  else f"{row['id']}: {row['checkpoint']} · {row['recommendation']}")
        if not selected["interventions"]:
            print("No interventions recorded.")
    else:
        economics_data = data["unit_economics"]
        cost = economics_data["cost_per_accepted_outcome_usd"]
        print(f"Declared outcomes: {economics_data['outcomes']} · accepted: {economics_data['accepted_outcomes']}")
        print("Cost per accepted outcome: " + (f"${cost:.2f}" if cost is not None else "unavailable"))
        print(f"Cost coverage: {economics_data['complete_outcomes']}/{economics_data['outcomes']} complete")
        for finding in data["findings"]:
            print(f"{finding['observation']}\n→ {finding['action']}")
    return 0
