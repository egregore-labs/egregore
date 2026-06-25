"""In-memory Supabase stub for platform smokes (stages 2–4 of the
platform PoC).

Implements just enough of the supabase-py query-builder surface that the
REAL service code in api/services/{emissary,platform}.py runs unmodified
against dict-backed tables: select/eq/gte/order/limit/insert/update/
delete/upsert/execute with count="exact".

Used by tests/test_platform_namespace.py, tests/test_platform_router.py,
and the stage-4 runtime-addressability smoke (scripts/smoke_star_runtime.py
serves api.main:app with this stub installed).
"""

import uuid
from datetime import datetime, timezone


class _Result:
    def __init__(self, data, count=None):
        self.data = data
        self.count = count


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

    def gte(self, column, value):
        self._filters.append(("gte", column, value))
        return self

    def order(self, column, desc=False):
        self._order = (column, desc)
        return self

    def limit(self, n):
        self._limit = n
        return self

    # ── execution ──
    def _matches(self, row):
        for op, col, val in self._filters:
            have = row.get(col)
            if op == "eq" and have != val:
                return False
            if op == "gte" and (have is None or str(have) < str(val)):
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
                    row.update(payload)
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
        if self.name == "emissary_slugs":
            row.setdefault("updated_at", row["created_at"])


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
