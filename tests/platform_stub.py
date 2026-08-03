"""In-memory Supabase stub for platform smokes (stages 2–4 of the
platform PoC).

Implements just enough of the supabase-py query-builder surface that the
REAL service code in api/services/{emissary,platform}.py runs unmodified
against dict-backed tables: select/eq/gte/in_/or_/order/limit/insert/
update/delete/upsert/execute with count="exact".

Used by tests/test_platform_namespace.py, tests/test_platform_router.py,
and the stage-4 runtime-addressability smoke (scripts/smoke_star_runtime.py
serves api.main:app with this stub installed).
"""

import hashlib
import json
import uuid
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace


class _Result:
    def __init__(self, data, count=None):
        self.data = data
        self.count = count


class _UniqueViolation(Exception):
    """PostgREST-shaped PostgreSQL unique violation for race tests."""

    code = "23505"

    def __init__(self, constraint):
        message = (
            f'duplicate key value violates unique constraint "{constraint}"'
        )
        super().__init__(message)
        self.message = message
        self.details = message
        self.diag = SimpleNamespace(constraint_name=constraint)


class _Query:
    def __init__(self, table):
        self._table = table
        self._filters = []       # (op, column, value)
        self._order = None       # (column, desc)
        self._limit = None
        self._count = None
        self._action = ("select", None)

    # ── builders ──
    def select(self, _cols="*", count=None):
        self._count = count
        return self

    def insert(self, rows):
        self._action = ("insert", rows)
        return self

    def update(self, fields):
        self._action = ("update", fields)
        return self

    def delete(self):
        self._action = ("delete", None)
        return self

    def upsert(self, rows, on_conflict=""):
        self._action = ("upsert", (rows, on_conflict))
        return self

    def eq(self, column, value):
        self._filters.append(("eq", column, value))
        return self

    def ilike(self, column, value):
        self._filters.append(("ilike", column, value))
        return self

    def contains(self, column, value):
        self._filters.append(("contains", column, value))
        return self

    def gte(self, column, value):
        self._filters.append(("gte", column, value))
        return self

    def in_(self, column, values):
        self._filters.append(("in", column, tuple(values)))
        return self

    def or_(self, expression):
        clauses = []
        for raw_clause in expression.split(","):
            column, operator, value = raw_clause.split(".", 2)
            clauses.append((operator, column, value))
        self._filters.append(("or", None, tuple(clauses)))
        return self

    def order(self, column, desc=False):
        self._order = (column, desc)
        return self

    def limit(self, n):
        self._limit = n
        return self

    # ── execution ──
    @staticmethod
    def _value(row, column):
        if "->" not in column:
            return row.get(column)
        parts = column.replace("->>", "->").split("->")
        value = row.get(parts[0])
        for part in parts[1:]:
            if not isinstance(value, dict):
                return None
            value = value.get(part)
        if column.count("->>"):
            if isinstance(value, (dict, list)):
                return json.dumps(value, separators=(",", ":"))
            return None if value is None else str(value)
        return value

    @classmethod
    def _clause_matches(cls, row, op, col, val):
        have = cls._value(row, col)
        if op == "eq":
            return have == val
        if op == "ilike":
            return str(have or "").lower() == str(val).lower()
        if op == "contains":
            return all(item in (have or []) for item in val)
        if op == "gte":
            return have is not None and str(have) >= str(val)
        if op == "gt":
            return have is not None and str(have) > str(val)
        if op == "in":
            return have in val
        if op == "is" and val == "null":
            return have is None
        raise AssertionError(f"unsupported platform stub filter: {op}")

    def _matches(self, row):
        for op, col, val in self._filters:
            if op == "or":
                if not any(
                    self._clause_matches(row, *clause)
                    for clause in val
                ):
                    return False
            elif not self._clause_matches(row, op, col, val):
                return False
        return True

    def execute(self):
        rows = self._table.rows
        action, payload = self._action

        if action == "insert":
            new = payload if isinstance(payload, list) else [payload]
            stored = []
            for r in new:
                r = dict(r)
                self._table.apply_defaults(r)
                self._table.check_unique(r)
                rows.append(r)
                stored.append(r)
            return _Result(stored)

        if action == "upsert":
            new, on_conflict = payload
            new = new if isinstance(new, list) else [new]
            keys = [k.strip() for k in on_conflict.split(",") if k.strip()]
            stored = []
            for r in new:
                r = dict(r)
                hit = None
                if keys:
                    for existing in rows:
                        if all(existing.get(k) == r.get(k) for k in keys):
                            hit = existing
                            break
                if hit:
                    hit.update(r)
                    stored.append(hit)
                else:
                    self._table.apply_defaults(r)
                    rows.append(r)
                    stored.append(r)
            return _Result(stored)

        if action == "update":
            updated = []
            for row in rows:
                if self._matches(row):
                    candidate = dict(row)
                    candidate.update(payload)
                    self._table.check_unique(candidate, ignore=row)
                    row.update(candidate)
                    updated.append(row)
            return _Result(updated)

        if action == "delete":
            keep, dropped = [], []
            for row in rows:
                (dropped if self._matches(row) else keep).append(row)
            self._table.rows[:] = keep
            return _Result(dropped)

        # select
        out = [dict(r) for r in rows if self._matches(r)]
        if self._order:
            col, desc = self._order
            out.sort(key=lambda r: str(r.get(col) or ""), reverse=desc)
        if self._limit is not None:
            out = out[: self._limit]
        count = len(out) if self._count == "exact" else None
        return _Result(out, count=count)


class _Table:
    def __init__(self, name):
        self.name = name
        self.rows = []

    def apply_defaults(self, row):
        if self.name in ("emissary_users", "emissary_emissaries",
                         "emissary_auth_tokens") and "id" not in row:
            row["id"] = str(uuid.uuid4())
        row.setdefault("created_at", datetime.now(timezone.utc).isoformat())
        if self.name == "emissary_profiles":
            row.setdefault("handle_rename_used", False)
        if self.name == "emissary_slugs":
            row.setdefault("updated_at", row["created_at"])

    def check_unique(self, candidate, ignore=None):
        if self.name != "emissary_profiles":
            return
        for row in self.rows:
            if row is ignore:
                continue
            if row.get("user_id") == candidate.get("user_id"):
                raise _UniqueViolation("emissary_profiles_pkey")
            if row.get("handle") == candidate.get("handle"):
                raise _UniqueViolation("emissary_profiles_handle_key")


class _Rpc:
    def __init__(self, fake, fn, params):
        self._fake = fake
        self._fn = fn
        self._params = params

    def execute(self):
        return _Result(self._fake.call_rpc(self._fn, self._params))


def _parse_ts(value):
    if isinstance(value, datetime):
        return value
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except (TypeError, ValueError):
        return None


class FakeSupabase:
    def __init__(self):
        self.tables = {}

    def table(self, name):
        if name not in self.tables:
            self.tables[name] = _Table(name)
        return _Query(self.tables[name])

    # ── RPC emulation (migration 009 quota functions) ──
    # Mirrors the plpgsql in api/migrations/009_quota_rpc.sql so the
    # services' durable-first paths execute in tests. Single-threaded —
    # atomicity itself is Postgres's job; semantics are what's under test.

    def rpc(self, fn, params=None):
        return _Rpc(self, fn, params or {})

    def _quota_row(self, user_id):
        table = self.tables.setdefault(
            "emissary_quota_counters", _Table("emissary_quota_counters"))
        for row in table.rows:
            if row.get("user_id") == user_id:
                return row
        row = {"user_id": user_id,
               "window_start": datetime.now(timezone.utc).isoformat(),
               "publishes": 0, "active_hosted": 0,
               "publish_exempt": False,
               "emails_sent": 0,
               "email_window_start": datetime.now(timezone.utc).isoformat()}
        table.rows.append(row)
        return row

    def call_rpc(self, fn, params):
        now = datetime.now(timezone.utc)

        if fn == "emissary_commit_publish_v1":
            operations = self.tables.setdefault(
                "emissary_publish_operations",
                _Table("emissary_publish_operations"),
            )
            existing = next(
                (
                    row for row in operations.rows
                    if row.get("author_user_id") == params["p_author_user_id"]
                    and row.get("key_hash") == params["p_key_hash"]
                ),
                None,
            )
            if existing:
                if existing["request_hash"] != params["p_request_hash"]:
                    return {
                        "status": "conflict",
                        "operation_id": existing["id"],
                        "emissary_id": existing.get("emissary_id"),
                    }
                return {
                    "status": "replay",
                    "operation_id": existing["id"],
                    "emissary_id": existing["emissary_id"],
                    "response_core": existing["response_core"],
                    "operation_state": existing["state"],
                }

            row = dict(params["p_emissary"])
            slug = params.get("p_slug")
            owner_handle = None
            version = 1
            parent_version = None
            if slug:
                profiles = self.tables.setdefault(
                    "emissary_profiles", _Table("emissary_profiles")
                ).rows
                profile = next(
                    p for p in profiles
                    if p.get("user_id") == params["p_author_user_id"]
                )
                owner_handle = profile["handle"]
                slugs = self.tables.setdefault(
                    "emissary_slugs", _Table("emissary_slugs")
                ).rows
                if row.get("auto_slug") and any(
                    s.get("owner_handle") == owner_handle
                    and s.get("slug") == slug
                    for s in slugs
                ):
                    root = slug[:60].rstrip("-") or "emissary"
                    suffix = 2
                    while any(
                        s.get("owner_handle") == owner_handle
                        and s.get("slug") == f"{root}-{suffix}"
                        for s in slugs
                    ):
                        suffix += 1
                    slug = f"{root}-{suffix}"
                slug_row = next(
                    (
                        s for s in slugs
                        if s.get("owner_handle") == owner_handle
                        and s.get("slug") == slug
                    ),
                    None,
                )
                if slug_row:
                    head = next(
                        item for item in self.tables["emissary_emissaries"].rows
                        if item["id"] == slug_row["head_id"]
                    )
                    version = int(head.get("version") or 1) + 1
                    parent_version = head["id"]

            row["version"] = version
            row["parent_version"] = parent_version
            row.pop("auto_slug", None)
            self.table("emissary_emissaries").insert(row).execute()
            if slug:
                self.table("emissary_slugs").upsert(
                    {
                        "owner_handle": owner_handle,
                        "slug": slug,
                        "head_id": row["id"],
                        "updated_at": now.isoformat(),
                    },
                    on_conflict="owner_handle,slug",
                ).execute()
            for tag in dict.fromkeys(params.get("p_tags") or []):
                self.table("emissary_tags").insert(
                    {"emissary_id": row["id"], "tag": tag}
                ).execute()
            self.call_rpc(
                "emissary_record_publish",
                {"p_user_id": params["p_author_user_id"], "p_window_seconds": 86400},
            )
            self.table("emissary_audit_events").insert(
                {
                    "event_type": "emissary_create",
                    "user_id": params["p_author_user_id"],
                    "payload": {"emissary_id": row["id"]},
                }
            ).execute()

            operation_id = str(uuid.uuid4())
            initial_skipped = list(params.get("p_initial_skipped") or [])
            outbox = self.tables.setdefault(
                "emissary_notification_outbox",
                _Table("emissary_notification_outbox"),
            )
            seen = set()
            for position, intent in enumerate(params.get("p_notifications") or []):
                recipient = intent["recipient_email"].lower()
                if recipient in seen:
                    continue
                seen.add(recipient)
                payload_hash = hashlib.sha256(
                    json.dumps(
                        {
                            "recipient_email": recipient,
                            "subject": intent["subject"],
                            "html": intent["html"],
                        },
                        sort_keys=True,
                    ).encode()
                ).hexdigest()
                outbox.rows.append(
                    {
                        "id": str(uuid.uuid4()),
                        "operation_id": operation_id,
                        "emissary_id": row["id"],
                        "position": position,
                        "intent_kind": intent.get("kind", "directed"),
                        "recipient_email": recipient,
                        "subject": intent["subject"],
                        "html": intent["html"],
                        "provider_key": hashlib.sha256(
                            f"{operation_id}:{position}:{payload_hash}".encode()
                        ).hexdigest(),
                        "report_to_client": intent.get("report_to_client", True),
                        "state": "pending",
                        "last_error": None,
                    }
                )
            response_core = {
                **params["p_response_core"],
                "emissary_id": row["id"],
                "version": version,
            }
            if slug:
                address = f"@{owner_handle}/{slug}"
                response_core["address"] = address
                response_core["address_url"] = f"https://egregore.xyz/{address}"
            operation = {
                "id": operation_id,
                "author_user_id": params["p_author_user_id"],
                "key_hash": params["p_key_hash"],
                "request_hash": params["p_request_hash"],
                "emissary_id": row["id"],
                "state": "notifications_pending" if outbox.rows else "completed",
                "response_core": response_core,
                "initial_skipped": initial_skipped,
                "created_at": now.isoformat(),
                "updated_at": now.isoformat(),
            }
            operations.rows.append(operation)
            return {
                "status": "committed",
                "operation_id": operation_id,
                "emissary_id": row["id"],
                "response_core": response_core,
                "initial_skipped": initial_skipped,
                "operation_state": operation["state"],
            }

        if fn == "emissary_claim_notification_v1":
            outbox = self.tables.setdefault(
                "emissary_notification_outbox",
                _Table("emissary_notification_outbox"),
            )
            intent = next(
                (
                    row for row in sorted(
                        outbox.rows, key=lambda item: item.get("position", 0)
                    )
                    if row.get("operation_id") == params["p_operation_id"]
                    and row.get("state") == "pending"
                ),
                None,
            )
            if not intent:
                return {"status": "none", "intent": None}
            intent["state"] = "sending"
            intent["claimed_by"] = params["p_worker_id"]
            return {"status": "claimed", "intent": dict(intent)}

        if fn == "emissary_finish_notification_v1":
            outbox = self.tables.setdefault(
                "emissary_notification_outbox",
                _Table("emissary_notification_outbox"),
            )
            intent = next(
                (row for row in outbox.rows if row["id"] == params["p_intent_id"]),
                None,
            )
            if not intent:
                return {"status": "none", "intent": None}
            if params.get("p_provider_message_id") and not params.get("p_error"):
                intent["state"] = "sent"
                intent["provider_message_id"] = params["p_provider_message_id"]
                return {"status": "sent", "intent": dict(intent)}
            intent["state"] = "pending"
            intent["last_error"] = params.get("p_error")
            return {"status": "retry", "intent": dict(intent)}

        if fn == "emissary_finalize_publish_v1":
            operation = next(
                row for row in self.tables["emissary_publish_operations"].rows
                if row["id"] == params["p_operation_id"]
            )
            all_intents = [
                row for row in self.tables.setdefault(
                    "emissary_notification_outbox",
                    _Table("emissary_notification_outbox"),
                ).rows
                if row.get("operation_id") == operation["id"]
            ]
            intents = [
                row for row in all_intents if row.get("report_to_client")
            ]
            pending = [
                row["recipient_email"] for row in intents
                if row["state"] in ("pending", "sending")
            ]
            all_pending = [
                row for row in all_intents
                if row["state"] in ("pending", "sending")
            ]
            if not all_pending:
                operation["state"] = "completed"
            return {
                "status": "pending" if all_pending else "completed",
                "operation_id": operation["id"],
                "emissary_id": operation["emissary_id"],
                "response_core": operation["response_core"],
                "notified": [
                    row["recipient_email"] for row in intents
                    if row["state"] == "sent"
                ],
                "notification_failed": [
                    row["recipient_email"] for row in intents
                    if row["state"] in ("pending", "sending")
                    and row.get("last_error")
                ],
                "notification_skipped": operation["initial_skipped"],
                "notification_skipped_count": (
                    len(operation["initial_skipped"])
                    + sum(row["state"] == "skipped" for row in all_intents)
                ),
                "notification_pending": pending,
                "notification_unknown": [
                    row["recipient_email"] for row in intents
                    if row["state"] == "unknown"
                ],
                "notification_unknown_count": sum(
                    row["state"] == "unknown" for row in all_intents
                ),
                "recovery_required": bool(all_pending),
            }
        if fn == "emissary_rename_handle":
            profiles = self.tables.setdefault(
                "emissary_profiles", _Table("emissary_profiles")
            ).rows
            profile = next(
                (
                    row for row in profiles
                    if row.get("user_id") == params["p_user_id"]
                ),
                None,
            )
            if not profile:
                return [{"status": "profile_missing", "profile": None}]
            expected = params["p_expected_handle"]
            new_handle = params["p_new_handle"]
            if profile.get("handle") != expected or new_handle == expected:
                return [{"status": "stale_handle", "profile": None}]
            if profile.get("handle_rename_used"):
                return [{"status": "rename_used", "profile": None}]
            claimed_at = _parse_ts(profile.get("created_at"))
            if not claimed_at or claimed_at < now - timedelta(days=7):
                return [{"status": "window_closed", "profile": None}]
            stars = self.tables.setdefault(
                "emissary_stars", _Table("emissary_stars")
            ).rows
            if any(row.get("owner_handle") == expected for row in stars):
                return [{"status": "has_stars", "profile": None}]
            slugs = self.tables.setdefault(
                "emissary_slugs", _Table("emissary_slugs")
            ).rows
            if any(row.get("owner_handle") == expected for row in slugs):
                return [{"status": "has_slugs", "profile": None}]
            if any(
                row is not profile and row.get("handle") == new_handle
                for row in profiles
            ):
                return [{"status": "handle_taken", "profile": None}]

            profile["handle"] = new_handle
            profile["handle_rename_used"] = True
            profile.update(params.get("p_fields") or {})
            return [{"status": "renamed", "profile": dict(profile)}]
        if fn == "emissary_record_publish":
            row = self._quota_row(params["p_user_id"])
            ws = _parse_ts(row.get("window_start"))
            lapsed = (not ws) or (now - ws).total_seconds() > params.get(
                "p_window_seconds", 86400)
            row["publishes"] = 1 if lapsed else row.get("publishes", 0) + 1
            if lapsed:
                row["window_start"] = now.isoformat()
            row["active_hosted"] = row.get("active_hosted", 0) + 1
            row["updated_at"] = now.isoformat()
            return None

        if fn == "emissary_record_email":
            row = self._quota_row(params["p_user_id"])
            ws = _parse_ts(row.get("email_window_start"))
            lapsed = (not ws) or (now - ws).total_seconds() > params.get(
                "p_window_seconds", 86400)
            if (not row.get("publish_exempt") and not lapsed
                    and row.get("emails_sent", 0) >= params.get("p_limit", 20)):
                return False
            row["emails_sent"] = 1 if lapsed else row.get("emails_sent", 0) + 1
            if lapsed:
                row["email_window_start"] = now.isoformat()
            row["updated_at"] = now.isoformat()
            return True

        if fn == "emissary_release_hosted":
            row = self._quota_row(params["p_user_id"])
            row["active_hosted"] = max(0, row.get("active_hosted", 0) - 1)
            row["updated_at"] = now.isoformat()
            return None

        raise RuntimeError(f"FakeSupabase: unknown RPC {fn}")

    # convenience for seeding
    def seed(self, name, rows):
        for r in rows:
            self.table(name).insert(r).execute()


def install(monkeypatch) -> FakeSupabase:
    """Patch get_client across the service modules; returns the fake."""
    fake = FakeSupabase()
    monkeypatch.setattr("api.services.emissary.get_client", lambda: fake)
    monkeypatch.setattr("api.services.platform.get_client", lambda: fake)
    return fake


def seed_user_with_token(fake: FakeSupabase, email="oz@example.com",
                         name="oz", token="tok-" + "a" * 28,
                         verified=True) -> tuple[dict, str]:
    """Seed a verified user + auth token; returns (user_row, token)."""
    from api.services.emissary import hash_token
    res = fake.table("emissary_users").insert(
        {"email": email, "name": name, "email_verified": verified}
    ).execute()
    user = res.data[0]
    fake.table("emissary_auth_tokens").insert(
        {"user_id": user["id"], "token_hash": hash_token(token)}
    ).execute()
    return user, token
