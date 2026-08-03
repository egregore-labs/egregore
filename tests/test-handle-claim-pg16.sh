#!/usr/bin/env bash
# Behavioral PostgreSQL 16 proof for migration 030.
#
# This intentionally starts from overly permissive legacy grants. The
# migration must remove direct API-role mutation and the default PUBLIC
# function grant while keeping the trusted service role operational.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pg_container="egregore-handle-pg16-$$"
pg_password="handle-proof-only"
proof_tmp="$(mktemp -d)"

cleanup() {
  docker rm -f "$pg_container" >/dev/null 2>&1 || true
  rm -rf "$proof_tmp"
}
trap cleanup EXIT

docker run --detach --name "$pg_container" \
  --env "POSTGRES_PASSWORD=$pg_password" \
  --mount "type=bind,source=$repo_root,target=/repo,readonly" \
  postgres:16-alpine >/dev/null

# The image briefly accepts connections while initdb is finishing, then
# restarts PostgreSQL. Require consecutive successful probes so the proof does
# not race that expected restart (especially on a freshly pulled image).
ready_streak=0
for _attempt in $(seq 1 80); do
  if docker exec "$pg_container" pg_isready -U postgres >/dev/null 2>&1; then
    ready_streak=$((ready_streak + 1))
    if [ "$ready_streak" -ge 3 ]; then
      break
    fi
  else
    ready_streak=0
  fi
  sleep 0.25
done
if [ "$ready_streak" -lt 3 ]; then
  echo "PostgreSQL 16 did not become stably ready" >&2
  exit 1
fi

psql_stdin() {
  docker exec -i "$pg_container" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres
}

psql_command() {
  docker exec "$pg_container" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d postgres "$@"
}

# Fresh-install shape: 008 has already supplied handle_rename_used=false.
# Broad grants model a legacy Supabase setup so 030 must actively close them.
psql_stdin >/dev/null <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA shadow;

CREATE TABLE public.emissary_users (
  id uuid PRIMARY KEY,
  email_verified boolean NOT NULL DEFAULT false
);
CREATE TABLE public.emissary_profiles (
  user_id uuid PRIMARY KEY REFERENCES public.emissary_users(id),
  handle text UNIQUE NOT NULL,
  display text,
  bio text,
  links jsonb NOT NULL DEFAULT '[]'::jsonb,
  featured uuid[] NOT NULL DEFAULT '{}',
  handle_rename_used boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.emissary_slugs (
  owner_handle text NOT NULL REFERENCES public.emissary_profiles(handle)
    ON UPDATE CASCADE,
  slug text NOT NULL,
  PRIMARY KEY (owner_handle, slug)
);
CREATE TABLE public.emissary_stars (
  user_id uuid NOT NULL,
  owner_handle text NOT NULL,
  slug text NOT NULL,
  PRIMARY KEY (user_id, owner_handle, slug)
);

GRANT ALL ON TABLE public.emissary_profiles,
  public.emissary_slugs, public.emissary_stars
  TO PUBLIC, anon, authenticated, service_role;

INSERT INTO public.emissary_users (id, email_verified)
VALUES ('00000000-0000-0000-0000-000000000001', true);
INSERT INTO public.emissary_profiles (user_id, handle)
VALUES ('00000000-0000-0000-0000-000000000001', 'victim');

SET search_path = shadow, public;
\i /repo/api/migrations/031_handle_claim_hardening.sql
SQL

psql_stdin >/dev/null <<'SQL'
DO $verify$
DECLARE
  role_name text;
BEGIN
  FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated']
  LOOP
    IF pg_catalog.has_function_privilege(
      role_name,
      'public.emissary_rename_handle(uuid,text,text,jsonb)',
      'EXECUTE'
    ) THEN
      RAISE EXCEPTION '% can still execute the rename RPC', role_name;
    END IF;
    IF pg_catalog.has_table_privilege(
      role_name, 'public.emissary_profiles', 'INSERT'
    ) OR pg_catalog.has_table_privilege(
      role_name, 'public.emissary_profiles', 'UPDATE'
    ) OR pg_catalog.has_table_privilege(
      role_name, 'public.emissary_profiles', 'DELETE'
    ) OR pg_catalog.has_table_privilege(
      role_name, 'public.emissary_slugs', 'UPDATE'
    ) OR pg_catalog.has_table_privilege(
      role_name, 'public.emissary_stars', 'UPDATE'
    ) THEN
      RAISE EXCEPTION '% retains direct platform DML', role_name;
    END IF;
  END LOOP;

  IF NOT pg_catalog.has_function_privilege(
    'service_role',
    'public.emissary_rename_handle(uuid,text,text,jsonb)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'service_role cannot execute the rename RPC';
  END IF;
  IF NOT pg_catalog.has_table_privilege(
    'service_role', 'public.emissary_profiles', 'UPDATE'
  ) THEN
    RAISE EXCEPTION 'service_role cannot update profiles';
  END IF;
END
$verify$;
SQL

# A verified-email victim id is not an authorization capability. Neither
# client-facing role may supply it to the RPC or mutate the profile directly.
for hostile_role in anon authenticated; do
  if psql_command -c \
    "SET ROLE $hostile_role; SELECT * FROM public.emissary_rename_handle('00000000-0000-0000-0000-000000000001', 'victim', 'stolen', '{}'::jsonb);" \
    >/dev/null 2>&1; then
    echo "$hostile_role unexpectedly executed the rename RPC" >&2
    exit 1
  fi
  if psql_command -c \
    "SET ROLE $hostile_role; UPDATE public.emissary_profiles SET handle = 'stolen' WHERE user_id = '00000000-0000-0000-0000-000000000001';" \
    >/dev/null 2>&1; then
    echo "$hostile_role unexpectedly updated the victim profile" >&2
    exit 1
  fi
done

fresh_status="$(
  psql_command -At -c \
    "SET ROLE service_role; SELECT status FROM public.emissary_rename_handle('00000000-0000-0000-0000-000000000001', 'victim', 'owner', '{}'::jsonb);"
)"
[[ "$fresh_status" == *"renamed"* ]]

# Replay from a non-public-first search_path must preserve the spent rename.
psql_stdin >/dev/null <<'SQL'
SET search_path = shadow, public;
\i /repo/api/migrations/031_handle_claim_hardening.sql
DO $verify$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM public.emissary_profiles
    WHERE handle = 'owner' AND handle_rename_used
  ) THEN
    RAISE EXCEPTION 'fresh replay changed the renamed profile';
  END IF;
END
$verify$;
SQL

# Legacy shape: no handle_rename_used column. Existing rows fail closed when
# the column is introduced; rows inserted afterward retain the false default,
# including across replay.
psql_stdin >/dev/null <<'SQL'
DROP FUNCTION public.emissary_rename_handle(uuid, text, text, jsonb);
DROP TABLE public.emissary_stars;
DROP TABLE public.emissary_slugs;
DROP TABLE public.emissary_profiles;

CREATE TABLE public.emissary_profiles (
  user_id uuid PRIMARY KEY REFERENCES public.emissary_users(id),
  handle text UNIQUE NOT NULL,
  display text,
  bio text,
  links jsonb NOT NULL DEFAULT '[]'::jsonb,
  featured uuid[] NOT NULL DEFAULT '{}',
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.emissary_slugs (
  owner_handle text NOT NULL REFERENCES public.emissary_profiles(handle)
    ON UPDATE CASCADE,
  slug text NOT NULL,
  PRIMARY KEY (owner_handle, slug)
);
CREATE TABLE public.emissary_stars (
  user_id uuid NOT NULL,
  owner_handle text NOT NULL,
  slug text NOT NULL,
  PRIMARY KEY (user_id, owner_handle, slug)
);
GRANT ALL ON TABLE public.emissary_profiles,
  public.emissary_slugs, public.emissary_stars
  TO PUBLIC, anon, authenticated, service_role;

INSERT INTO public.emissary_users (id, email_verified)
VALUES
  ('00000000-0000-0000-0000-000000000002', true),
  ('00000000-0000-0000-0000-000000000003', true);
INSERT INTO public.emissary_profiles (user_id, handle)
VALUES ('00000000-0000-0000-0000-000000000002', 'legacy');

SET search_path = shadow, public;
\i /repo/api/migrations/031_handle_claim_hardening.sql

INSERT INTO public.emissary_profiles (user_id, handle)
VALUES ('00000000-0000-0000-0000-000000000003', 'new-profile');

SET search_path = shadow, public;
\i /repo/api/migrations/031_handle_claim_hardening.sql

DO $verify$
BEGIN
  IF NOT (
    SELECT handle_rename_used
    FROM public.emissary_profiles
    WHERE handle = 'legacy'
  ) THEN
    RAISE EXCEPTION 'legacy profile did not fail closed';
  END IF;
  IF (
    SELECT handle_rename_used
    FROM public.emissary_profiles
    WHERE handle = 'new-profile'
  ) THEN
    RAISE EXCEPTION 'replay spent a post-migration rename';
  END IF;
END
$verify$;
SQL

# Two callers racing for the same rename serialize under FOR UPDATE. Exactly
# one spends the rename; the other observes a stale expected handle.
(
  psql_command -At -c \
    "SET ROLE service_role; SELECT status FROM public.emissary_rename_handle('00000000-0000-0000-0000-000000000003', 'new-profile', 'race-one', '{}'::jsonb);" \
    >"$proof_tmp/race-one"
) &
race_one_pid=$!
(
  psql_command -At -c \
    "SET ROLE service_role; SELECT status FROM public.emissary_rename_handle('00000000-0000-0000-0000-000000000003', 'new-profile', 'race-two', '{}'::jsonb);" \
    >"$proof_tmp/race-two"
) &
race_two_pid=$!
wait "$race_one_pid"
wait "$race_two_pid"

renamed_count="$(
  awk '$0 == "renamed" { count += 1 } END { print count + 0 }' \
    "$proof_tmp"/race-*
)"
stale_count="$(
  awk '$0 == "stale_handle" { count += 1 } END { print count + 0 }' \
    "$proof_tmp"/race-*
)"
if [[ "$renamed_count" != "1" || "$stale_count" != "1" ]]; then
  echo \
    "handle race returned $renamed_count renamed and $stale_count stale_handle statuses; expected one each" \
    >&2
  exit 1
fi

echo "PostgreSQL 16 handle hardening proof passed"
