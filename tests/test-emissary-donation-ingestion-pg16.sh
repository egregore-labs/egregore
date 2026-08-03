#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
migration_root="${EMISSARY_MIGRATION_ROOT:-$repo_root/api/migrations}"
container_name="eg-donation-ingestion-pg16-${RANDOM}-${RANDOM}"
proof_tmp="$(mktemp -d)"

required_migrations=(
  005_emissary.sql
  006_emissary_donations.sql
  007_emissary_render_html.sql
  008_platform.sql
  009_quota_rpc.sql
  010_dataroom_gate_visits.sql
  011_web_sessions.sql
  012_oauth.sql
  030_emissary_publish_idempotency.sql
  031_handle_claim_hardening.sql
  032_public_slug_head_guard.sql
  033_emissary_data_plane_hardening.sql
)
for migration in "${required_migrations[@]}"; do
  if [[ ! -f "$migration_root/$migration" ]]; then
    echo "Required migration is missing: $migration_root/$migration" >&2
    exit 1
  fi
done

cleanup() {
  docker stop "$container_name" >/dev/null 2>&1 || true
  rm -rf -- "$proof_tmp"
}
trap cleanup EXIT

docker run --rm -d \
  --name "$container_name" \
  -e POSTGRES_PASSWORD=proof \
  -e POSTGRES_DB=proof \
  postgres:16-alpine >/dev/null

ready=false
for _attempt in 1 2 3 4 5 6 7 8 9 10; do
  if docker exec "$container_name" \
    pg_isready -U postgres -d proof >/dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 1
done
if [[ "$ready" != true ]]; then
  echo "PostgreSQL 16 did not become ready" >&2
  exit 1
fi

psql_proof() {
  docker exec -i "$container_name" \
    psql -X -v ON_ERROR_STOP=1 -U postgres -d proof
}

expect_service_mutation_denied() {
  local statement="$1"
  if docker exec "$container_name" \
    psql -X -q -v ON_ERROR_STOP=1 -U postgres -d proof \
    -c "SET ROLE service_role; $statement" \
    >"$proof_tmp/denied.out" 2>"$proof_tmp/denied.err"; then
    echo "service_role mutation unexpectedly succeeded: $statement" >&2
    exit 1
  fi
  if ! grep -q 'permission denied' "$proof_tmp/denied.err"; then
    echo "service_role mutation failed for the wrong reason: $statement" >&2
    cat "$proof_tmp/denied.err" >&2
    exit 1
  fi
}

expect_check_rejected() {
  local statement="$1"
  if docker exec "$container_name" \
    psql -X -q -v ON_ERROR_STOP=1 -U postgres -d proof \
    -c "$statement" \
    >"$proof_tmp/check.out" 2>"$proof_tmp/check.err"; then
    echo "digestless row unexpectedly satisfied CHECK: $statement" >&2
    exit 1
  fi
  if ! grep -q 'violates check constraint' "$proof_tmp/check.err"; then
    echo "digestless row failed for the wrong reason: $statement" >&2
    cat "$proof_tmp/check.err" >&2
    exit 1
  fi
}

psql_proof <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN BYPASSRLS;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SQL

for migration in "${required_migrations[@]}"; do
  psql_proof < "$migration_root/$migration" >/dev/null
done

# One pre-033 row proves migration-time quarantine. The exact 032 migration
# above installs its permissive service policy and direct mutation grants;
# 033 must remove both rather than relying on BYPASSRLS.
psql_proof <<'SQL'
DO $proof$
BEGIN
  IF NOT has_table_privilege(
       'service_role', 'public.emissary_donations', 'INSERT'
     )
     OR NOT has_table_privilege(
       'service_role', 'public.emissary_donations', 'UPDATE'
     )
     OR NOT EXISTS (
       SELECT 1
         FROM pg_policy
        WHERE polrelid = 'public.emissary_donations'::regclass
          AND polname = 'emissary_service_role'
     ) THEN
    RAISE EXCEPTION '032 donation access was not installed before 033';
  END IF;
END
$proof$;

INSERT INTO public.emissary_users(id, email, name)
VALUES
  ('10000000-0000-0000-0000-000000000001', 'quota@example.com', 'Quota'),
  ('10000000-0000-0000-0000-000000000002', 'other@example.com', 'Other'),
  ('10000000-0000-0000-0000-000000000003', 'same@example.com', 'Same');

INSERT INTO public.emissary_donations(
  id, donor_user_id, dir_name, storage_path, github_status, meta
) VALUES (
  '20000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'legacy-run',
  '20000000-0000-0000-0000-000000000001.tar.gz',
  'committed',
  '{"schema":"donation/v1"}'::jsonb
);

UPDATE public.emissary_donations
   SET github_commit_sha = repeat('d', 40)
 WHERE dir_name = 'legacy-run';
SQL

psql_proof < "$repo_root/api/migrations/034_emissary_donation_ingestion.sql" \
  >/dev/null
psql_proof < "$repo_root/api/migrations/034_emissary_donation_ingestion.sql" \
  >/dev/null

expect_service_mutation_denied \
  "INSERT INTO public.emissary_donations DEFAULT VALUES"
expect_service_mutation_denied \
  "UPDATE public.emissary_donations SET github_status = 'failed' WHERE false"
expect_service_mutation_denied \
  "DELETE FROM public.emissary_donations WHERE false"

expect_check_rejected \
  "UPDATE public.emissary_donations
      SET ingestion_state = 'reserved',
          github_target_prefix = 'loose/legacy-run/'
    WHERE dir_name = 'legacy-run'"
expect_check_rejected \
  "UPDATE public.emissary_donations
      SET ingestion_state = 'legacy_verified',
          github_target_prefix = 'loose/legacy-run/',
          bundle_sha256 = NULL,
          storage_sha256 = repeat('b', 64)
    WHERE dir_name = 'legacy-run'"
expect_check_rejected \
  "UPDATE public.emissary_donations
      SET ingestion_state = 'legacy_verified',
          github_target_prefix = 'loose/legacy-run/',
          bundle_sha256 = repeat('a', 64),
          storage_sha256 = NULL
    WHERE dir_name = 'legacy-run'"

psql_proof <<'SQL'
CREATE OR REPLACE FUNCTION public.proof_reserve(
  p_id uuid,
  p_user uuid,
  p_dir text,
  p_digest text
) RETURNS text
LANGUAGE sql
AS $$
  SELECT public.emissary_reserve_donation(
    p_id,
    NULL,
    p_user,
    'response',
    right(p_dir, 8),
    p_dir,
    p_id::text || '.tar.gz',
    'loose/' || p_dir || '/',
    'proof',
    'quota@example.com',
    'Quota',
    'none',
    123,
    jsonb_build_object('schema', 'donation/v1', 'dir_name', p_dir),
    p_digest
  )->>'decision'
$$;
GRANT EXECUTE ON FUNCTION public.proof_reserve(uuid, uuid, text, text)
  TO service_role;

DO $proof$
DECLARE
  reserve_sig regprocedure := (
    'public.emissary_reserve_donation('
    'uuid,uuid,uuid,text,text,text,text,text,text,text,text,text,'
    'bigint,jsonb,text)'
  )::regprocedure;
  bind_sig regprocedure := (
    'public.emissary_bind_legacy_donation('
    'uuid,text,text,text,uuid,text,text)'
  )::regprocedure;
  app_sig regprocedure;
  app_sigs regprocedure[] := ARRAY[
    reserve_sig,
    'public.emissary_claim_donation_github(uuid,text,uuid,integer)'::regprocedure,
    'public.emissary_fail_donation_github_claim(uuid,uuid)'::regprocedure,
    'public.emissary_expire_donation_github_claim(uuid,uuid)'::regprocedure,
    (
      'public.emissary_record_donation_github_candidate('
      'uuid,uuid,text,text,text)'
    )::regprocedure,
    (
      'public.emissary_record_donation_github_target('
      'uuid,uuid,text,text,text)'
    )::regprocedure,
    'public.emissary_finalize_donation_github(uuid,uuid,text)'::regprocedure,
    (
      'public.emissary_mark_donation_github_unknown('
      'uuid,uuid,text)'
    )::regprocedure,
    (
      'public.emissary_reconcile_donation_github('
      'uuid,uuid,text,boolean,boolean)'
    )::regprocedure
  ];
  row public.emissary_donations%ROWTYPE;
  decision text;
BEGIN
  SELECT * INTO row
    FROM public.emissary_donations WHERE dir_name = 'legacy-run';
  IF row.ingestion_state <> 'legacy_unverified'
     OR row.bundle_sha256 IS NOT NULL
     OR row.github_target_prefix IS NOT NULL THEN
    RAISE EXCEPTION 'legacy row was not quarantined';
  END IF;

  IF has_table_privilege('anon', 'public.emissary_donations', 'SELECT')
     OR has_table_privilege('authenticated', 'public.emissary_donations', 'SELECT')
     OR has_table_privilege('service_role', 'public.emissary_donations', 'INSERT')
     OR has_table_privilege('service_role', 'public.emissary_donations', 'UPDATE')
     OR has_table_privilege('service_role', 'public.emissary_donations', 'DELETE')
     OR NOT has_table_privilege(
       'service_role', 'public.emissary_donations', 'SELECT'
     ) THEN
    RAISE EXCEPTION 'donation table privilege surface is not exact';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM pg_class
     WHERE oid = 'public.emissary_donations'::regclass
       AND relrowsecurity
  ) OR EXISTS (
    SELECT 1 FROM pg_policy
     WHERE polrelid = 'public.emissary_donations'::regclass
  ) THEN
    RAISE EXCEPTION 'RLS must be enabled with no client-visible policy';
  END IF;

  FOREACH app_sig IN ARRAY app_sigs LOOP
    IF has_function_privilege('anon', app_sig, 'EXECUTE')
       OR has_function_privilege('authenticated', app_sig, 'EXECUTE')
       OR NOT has_function_privilege('service_role', app_sig, 'EXECUTE') THEN
      RAISE EXCEPTION 'donation RPC privilege surface is not exact: %', app_sig;
    END IF;
    IF NOT EXISTS (
      SELECT 1 FROM pg_proc
       WHERE oid = app_sig
         AND prosecdef
         AND proconfig @> ARRAY['search_path=pg_catalog, public, pg_temp']
    ) THEN
      RAISE EXCEPTION 'RPC lacks definer/safe search_path: %', app_sig;
    END IF;
  END LOOP;

  IF has_function_privilege('anon', bind_sig, 'EXECUTE')
     OR has_function_privilege('authenticated', bind_sig, 'EXECUTE')
     OR has_function_privilege('service_role', bind_sig, 'EXECUTE') THEN
    RAISE EXCEPTION 'owner-only legacy bind leaked EXECUTE';
  END IF;

  SET LOCAL ROLE service_role;
  decision := public.proof_reserve(
    '20000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    'legacy-run',
    repeat('a', 64)
  );
  RESET ROLE;
  IF decision <> 'legacy_unverified' THEN
    RAISE EXCEPTION 'legacy natural key did not fail closed: %', decision;
  END IF;
END
$proof$;

CREATE SCHEMA trap;
CREATE FUNCTION trap.clock_timestamp() RETURNS timestamptz
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'unsafe search_path clock_timestamp resolved';
END
$$;
CREATE FUNCTION trap.hashtextextended(text, bigint) RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'unsafe search_path hashtextextended resolved';
END
$$;
GRANT USAGE ON SCHEMA trap TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA trap TO service_role;

SET ROLE service_role;
SET search_path = pg_temp, trap, public;
CREATE TEMP TABLE emissary_donations(marker text);
SELECT public.proof_reserve(
  '21000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'search-path-proof',
  repeat('9', 64)
);
RESET ROLE;

DO $proof$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM public.emissary_donations
     WHERE id = '21000000-0000-0000-0000-000000000001'
       AND ingestion_state = 'reserved'
  ) THEN
    RAISE EXCEPTION 'safe-search-path call did not reach the public table';
  END IF;
END
$proof$;

-- Owner/admin-only evidence binding. It changes classification/digests only;
-- the historic id/path/bytes remain untouched and all unverified GitHub
-- bookkeeping is cleared into terminal unknown.
UPDATE public.emissary_donations
   SET github_status = 'committed',
       github_commit_sha = repeat('d', 40),
       github_attempt_id = '40000000-0000-0000-0000-000000000001',
       github_base_sha = repeat('b', 40),
       github_candidate_sha = repeat('c', 40),
       github_claimed_at = now(),
       github_claim_expires_at = now() + interval '10 minutes'
 WHERE dir_name = 'legacy-run';

SELECT public.emissary_bind_legacy_donation(
  '20000000-0000-0000-0000-000000000001',
  'legacy-run',
  '20000000-0000-0000-0000-000000000001.tar.gz',
  'loose/legacy-run/',
  '10000000-0000-0000-0000-000000000001',
  repeat('b', 64),
  repeat('a', 64)
);

DO $proof$
DECLARE
  row public.emissary_donations%ROWTYPE;
  decision text;
BEGIN
  SELECT * INTO row
    FROM public.emissary_donations WHERE dir_name = 'legacy-run';
  IF row.ingestion_state <> 'legacy_verified'
     OR row.storage_sha256 <> repeat('b', 64)
     OR row.bundle_sha256 <> repeat('a', 64)
     OR row.github_status <> 'unknown'
     OR row.github_commit_sha IS NOT NULL
     OR row.github_attempt_id IS NOT NULL
     OR row.github_base_sha IS NOT NULL
     OR row.github_candidate_sha IS NOT NULL
     OR row.github_claimed_at IS NOT NULL
     OR row.github_claim_expires_at IS NOT NULL
     OR row.storage_path <>
       '20000000-0000-0000-0000-000000000001.tar.gz' THEN
    RAISE EXCEPTION 'legacy evidence binding changed the wrong state';
  END IF;

  decision := public.proof_reserve(
    '29999999-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    'legacy-run',
    repeat('a', 64)
  );
  IF decision <> 'existing' THEN
    RAISE EXCEPTION 'verified legacy same digest was not reusable: %', decision;
  END IF;
  decision := public.proof_reserve(
    '29999999-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    'legacy-run',
    repeat('c', 64)
  );
  IF decision <> 'conflict' THEN
    RAISE EXCEPTION 'verified legacy different digest did not conflict: %', decision;
  END IF;
END
$proof$;

-- Rows outside the current UTC month must not consume this month's exact cap.
INSERT INTO public.emissary_donations(
  id, donor_user_id, dir_name, storage_path, github_target_prefix,
  github_status, harness, bundle_bytes, meta, ingestion_state,
  bundle_sha256, created_at
) VALUES
(
  '30000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'prior-month',
  '30000000-0000-0000-0000-000000000001.tar.gz',
  'loose/prior-month/',
  'pending', 'proof', 123, '{}'::jsonb, 'reserved', repeat('1', 64),
  date_trunc('month', now()) - interval '1 second'
),
(
  '30000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000001',
  'next-month',
  '30000000-0000-0000-0000-000000000002.tar.gz',
  'loose/next-month/',
  'pending', 'proof', 123, '{}'::jsonb, 'reserved', repeat('2', 64),
  date_trunc('month', now()) + interval '1 month'
);

-- Simulate a legacy_verified row produced by the earlier draft that trusted
-- historic committed bookkeeping. Replaying corrected 033 must repair it.
UPDATE public.emissary_donations
   SET github_status = 'committed',
       github_commit_sha = repeat('e', 40),
       github_attempt_id = '40000000-0000-0000-0000-000000000002',
       github_base_sha = repeat('f', 40),
       github_candidate_sha = repeat('a', 40),
       github_claimed_at = now(),
       github_claim_expires_at = now() + interval '10 minutes'
 WHERE dir_name = 'legacy-run';
SQL

psql_proof < "$repo_root/api/migrations/034_emissary_donation_ingestion.sql" \
  >/dev/null
psql_proof <<'SQL'
DO $proof$
DECLARE
  row public.emissary_donations%ROWTYPE;
BEGIN
  SELECT * INTO row
    FROM public.emissary_donations
   WHERE dir_name = 'legacy-run';
  IF row.github_status <> 'unknown'
     OR row.github_commit_sha IS NOT NULL
     OR row.github_attempt_id IS NOT NULL
     OR row.github_base_sha IS NOT NULL
     OR row.github_candidate_sha IS NOT NULL
     OR row.github_claimed_at IS NOT NULL
     OR row.github_claim_expires_at IS NOT NULL THEN
    RAISE EXCEPTION '033 replay did not repair legacy GitHub bookkeeping';
  END IF;
  IF EXISTS (
    SELECT 1
      FROM pg_policy
     WHERE polrelid = 'public.emissary_donations'::regclass
  ) THEN
    RAISE EXCEPTION '033 replay restored a donation policy';
  END IF;
END
$proof$;
SQL

# 21 simultaneous natural keys for one donor: advisory locking must admit
# exactly 20 in the current UTC month and reject one, never 21/20.
for index in $(seq 1 21); do
  donation_id="$(printf '40000000-0000-0000-0000-%012d' "$index")"
  dir_name="$(printf 'quota-run-%02d' "$index")"
  docker exec "$container_name" \
    psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d proof \
    -c "SELECT public.proof_reserve(
      '$donation_id',
      '10000000-0000-0000-0000-000000000002',
      '$dir_name',
      repeat('d', 64)
    )" >"$proof_tmp/quota-$index" &
done
wait

reserved_count="$(grep -l '^reserved$' "$proof_tmp"/quota-* | wc -l | tr -d ' ')"
quota_count="$(grep -l '^quota$' "$proof_tmp"/quota-* | wc -l | tr -d ' ')"
if [[ "$reserved_count" != 20 || "$quota_count" != 1 ]]; then
  echo "quota race admitted reserved=$reserved_count quota=$quota_count" >&2
  exit 1
fi

psql_proof <<'SQL'
DO $proof$
DECLARE
  count_now int;
  decision text;
BEGIN
  SELECT count(*) INTO count_now
    FROM public.emissary_donations
   WHERE donor_user_id = '10000000-0000-0000-0000-000000000002'
     AND created_at >= date_trunc('month', now())
     AND created_at < date_trunc('month', now()) + interval '1 month';
  IF count_now <> 20 THEN
    RAISE EXCEPTION 'database has % current-month quota rows, expected 20',
      count_now;
  END IF;

  -- Exact replay is free even after the cap is full.
  decision := public.proof_reserve(
    '40000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000002',
    'quota-run-01',
    repeat('d', 64)
  );
  IF decision <> 'existing' THEN
    RAISE EXCEPTION 'same-digest replay at cap was not free: %', decision;
  END IF;
END
$proof$;
SQL

# 32 concurrent exact retries consume one row and one quota slot. A later
# different digest from the same donor conflicts and cannot overwrite either.
for index in $(seq 1 32); do
  docker exec "$container_name" \
    psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d proof \
    -c "SELECT public.proof_reserve(
      '45000000-0000-0000-0000-000000000001',
      '10000000-0000-0000-0000-000000000003',
      'same-key-retry',
      repeat('4', 64)
    )" >"$proof_tmp/same-$index" &
done
wait

same_reserved="$(grep -l '^reserved$' "$proof_tmp"/same-* | wc -l | tr -d ' ')"
same_existing="$(grep -l '^existing$' "$proof_tmp"/same-* | wc -l | tr -d ' ')"
if [[ "$same_reserved" != 1 || "$same_existing" != 31 ]]; then
  echo "same-key race produced reserved=$same_reserved existing=$same_existing" >&2
  exit 1
fi

psql_proof <<'SQL'
DO $proof$
DECLARE
  row public.emissary_donations%ROWTYPE;
  decision text;
  donor_rows int;
BEGIN
  SELECT count(*) INTO donor_rows
    FROM public.emissary_donations
   WHERE donor_user_id = '10000000-0000-0000-0000-000000000003';
  IF donor_rows <> 1 THEN
    RAISE EXCEPTION '32 exact retries created % rows', donor_rows;
  END IF;

  SELECT * INTO row FROM public.emissary_donations
   WHERE dir_name = 'same-key-retry';
  IF row.id <> '45000000-0000-0000-0000-000000000001'::uuid
     OR row.bundle_sha256 <> repeat('4', 64) THEN
    RAISE EXCEPTION 'same-key winner identity/digest drifted';
  END IF;

  decision := public.proof_reserve(
    '45000000-0000-0000-0000-000000000099',
    '10000000-0000-0000-0000-000000000003',
    'same-key-retry',
    repeat('5', 64)
  );
  IF decision <> 'conflict' THEN
    RAISE EXCEPTION 'same-donor different digest did not conflict: %', decision;
  END IF;

  SELECT * INTO row FROM public.emissary_donations
   WHERE dir_name = 'same-key-retry';
  IF row.id <> '45000000-0000-0000-0000-000000000001'::uuid
     OR row.bundle_sha256 <> repeat('4', 64) THEN
    RAISE EXCEPTION 'different-digest loser overwrote the winner';
  END IF;
END
$proof$;
SQL

# Two donors racing the same natural key still produce one global winner.
docker exec "$container_name" psql -X -qAt -v ON_ERROR_STOP=1 \
  -U postgres -d proof -c "SELECT public.proof_reserve(
    '50000000-0000-0000-0000-000000000001',
    '10000000-0000-0000-0000-000000000001',
    'shared-natural-key',
    repeat('e', 64)
  )" >"$proof_tmp/natural-a" &
docker exec "$container_name" psql -X -qAt -v ON_ERROR_STOP=1 \
  -U postgres -d proof -c "SELECT public.proof_reserve(
    '50000000-0000-0000-0000-000000000002',
    '10000000-0000-0000-0000-000000000003',
    'shared-natural-key',
    repeat('f', 64)
  )" >"$proof_tmp/natural-b" &
wait
if [[ "$(grep -hE '^(reserved|conflict)$' "$proof_tmp"/natural-* | sort | tr '\n' ' ')" != \
      "conflict reserved " ]]; then
  echo "natural-key race did not produce exactly reserved+conflict" >&2
  exit 1
fi

# Reserve a fresh row for GitHub claim/candidate state-machine races.
psql_proof <<'SQL'
SELECT public.proof_reserve(
  '60000000-0000-0000-0000-000000000001',
  '10000000-0000-0000-0000-000000000001',
  'github-race',
  repeat('6', 64)
);
SQL

for index in $(seq 1 16); do
  attempt_id="$(printf '70000000-0000-0000-0000-%012d' "$index")"
  docker exec "$container_name" \
    psql -X -qAt -v ON_ERROR_STOP=1 -U postgres -d proof \
    -c "SELECT public.emissary_claim_donation_github(
      '60000000-0000-0000-0000-000000000001',
      repeat('6', 64),
      '$attempt_id',
      900
    )->>'decision'" >"$proof_tmp/claim-$index" &
done
wait

claimed_count="$(grep -l '^claimed$' "$proof_tmp"/claim-* | wc -l | tr -d ' ')"
terminal_count="$(grep -l '^terminal$' "$proof_tmp"/claim-* | wc -l | tr -d ' ')"
if [[ "$claimed_count" != 1 || "$terminal_count" != 15 ]]; then
  echo "claim race produced claimed=$claimed_count terminal=$terminal_count" >&2
  exit 1
fi

psql_proof <<'SQL'
DO $proof$
DECLARE
  attempt uuid;
  decision text;
BEGIN
  SELECT github_attempt_id INTO attempt
    FROM public.emissary_donations WHERE dir_name = 'github-race';

  decision := public.emissary_record_donation_github_candidate(
    '60000000-0000-0000-0000-000000000001',
    attempt,
    repeat('a', 40),
    repeat('b', 40),
    NULL
  )->>'decision';
  IF decision <> 'candidate' THEN
    RAISE EXCEPTION 'candidate CAS failed: %', decision;
  END IF;

  -- Candidate-bearing attempts are never released by fail/expiry.
  decision := public.emissary_fail_donation_github_claim(
    '60000000-0000-0000-0000-000000000001', attempt
  )->>'decision';
  IF decision <> 'lost' THEN
    RAISE EXCEPTION 'candidate was incorrectly released: %', decision;
  END IF;

  decision := public.emissary_mark_donation_github_unknown(
    '60000000-0000-0000-0000-000000000001',
    attempt,
    repeat('b', 40)
  )->>'decision';
  IF decision <> 'unknown' THEN
    RAISE EXCEPTION 'unknown transition failed: %', decision;
  END IF;

  decision := public.emissary_reconcile_donation_github(
    '60000000-0000-0000-0000-000000000001',
    attempt,
    repeat('b', 40),
    false,
    true
  )->>'decision';
  IF decision <> 'unknown' THEN
    RAISE EXCEPTION 'negative reachability reopened unknown: %', decision;
  END IF;

  decision := public.emissary_reconcile_donation_github(
    '60000000-0000-0000-0000-000000000001',
    attempt,
    repeat('b', 40),
    true,
    false
  )->>'decision';
  IF decision <> 'unknown' THEN
    RAISE EXCEPTION 'digest mismatch reopened unknown: %', decision;
  END IF;

  decision := public.emissary_reconcile_donation_github(
    '60000000-0000-0000-0000-000000000001',
    attempt,
    repeat('b', 40),
    true,
    true
  )->>'decision';
  IF decision <> 'committed' THEN
    RAISE EXCEPTION 'positive content-bound reachability did not commit: %',
      decision;
  END IF;

  decision := public.emissary_mark_donation_github_unknown(
    '60000000-0000-0000-0000-000000000001',
    attempt,
    repeat('b', 40)
  )->>'decision';
  IF decision <> 'lost' THEN
    RAISE EXCEPTION 'committed row was downgraded: %', decision;
  END IF;
END
$proof$;

-- Definitive pre-candidate failure is retryable and fences the old attempt.
SELECT public.proof_reserve(
  '60000000-0000-0000-0000-000000000002',
  '10000000-0000-0000-0000-000000000001',
  'github-prepatch-fail',
  repeat('7', 64)
);
SELECT public.emissary_claim_donation_github(
  '60000000-0000-0000-0000-000000000002',
  repeat('7', 64),
  '70000000-0000-0000-0000-000000000101',
  900
);
SELECT public.emissary_fail_donation_github_claim(
  '60000000-0000-0000-0000-000000000002',
  '70000000-0000-0000-0000-000000000101'
);
SELECT public.emissary_claim_donation_github(
  '60000000-0000-0000-0000-000000000002',
  repeat('7', 64),
  '70000000-0000-0000-0000-000000000102',
  900
);

DO $proof$
DECLARE
  decision text;
BEGIN
  decision := public.emissary_record_donation_github_candidate(
    '60000000-0000-0000-0000-000000000002',
    '70000000-0000-0000-0000-000000000101',
    repeat('c', 40),
    repeat('d', 40),
    NULL
  )->>'decision';
  IF decision <> 'lost' THEN
    RAISE EXCEPTION 'old failed attempt was not fenced: %', decision;
  END IF;
END
$proof$;

-- Expired no-candidate claim is also retryable, with the same token fence.
SELECT public.proof_reserve(
  '60000000-0000-0000-0000-000000000003',
  '10000000-0000-0000-0000-000000000001',
  'github-expired-claim',
  repeat('8', 64)
);
SELECT public.emissary_claim_donation_github(
  '60000000-0000-0000-0000-000000000003',
  repeat('8', 64),
  '70000000-0000-0000-0000-000000000201',
  60
);
UPDATE public.emissary_donations
   SET github_claim_expires_at = now() - interval '1 second'
 WHERE id = '60000000-0000-0000-0000-000000000003';
SELECT public.emissary_expire_donation_github_claim(
  '60000000-0000-0000-0000-000000000003',
  '70000000-0000-0000-0000-000000000201'
);
SELECT public.emissary_claim_donation_github(
  '60000000-0000-0000-0000-000000000003',
  repeat('8', 64),
  '70000000-0000-0000-0000-000000000202',
  900
);

DO $proof$
DECLARE
  row public.emissary_donations%ROWTYPE;
BEGIN
  SELECT * INTO row FROM public.emissary_donations
   WHERE id = '60000000-0000-0000-0000-000000000003';
  IF row.github_status <> 'claimed'
     OR row.github_attempt_id <>
       '70000000-0000-0000-0000-000000000202'::uuid THEN
    RAISE EXCEPTION 'expired claim did not fence/reclaim';
  END IF;
END
$proof$;
SQL

echo "PostgreSQL 16 Emissary donation ingestion proof passed"
