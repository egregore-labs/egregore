#!/usr/bin/env bash
# Behavioral PostgreSQL 16 proof for the Emissary data-plane hardening.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pg_container="egregore-emissary-security-pg16-$$"
pg_password="emissary-security-proof-only"
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
  if docker exec "$pg_container" \
    psql -X -U postgres -d postgres -Atqc 'SELECT 1' \
    >/dev/null 2>&1; then
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

# Model an existing Supabase project whose public-schema objects inherited
# broad PostgREST-role grants before migrations 005–012 were applied.
psql_stdin >/dev/null <<'SQL'
CREATE DATABASE fresh_absent_roles;
\connect fresh_absent_roles
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SET search_path = public;
\i /repo/api/migrations/005_emissary.sql
\i /repo/api/migrations/006_emissary_donations.sql
\i /repo/api/migrations/008_platform.sql
\i /repo/api/migrations/009_quota_rpc.sql
\i /repo/api/migrations/010_dataroom_gate_visits.sql
\i /repo/api/migrations/011_web_sessions.sql
\i /repo/api/migrations/012_oauth.sql
\i /repo/api/migrations/033_emissary_data_plane_hardening.sql

-- Model recovery migration 030 landing after 033, then replay 033. The real
-- migration owns behavior; this fixture models only its privilege boundary
-- and exact routine signatures.
CREATE TABLE public.emissary_publish_operations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
CREATE TABLE public.emissary_notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
CREATE FUNCTION public.emissary_commit_publish_v1(
  uuid, text, text, jsonb, text, jsonb, jsonb, jsonb, jsonb,
  integer, integer, integer
) RETURNS jsonb LANGUAGE sql AS 'SELECT ''{}''::jsonb';
CREATE FUNCTION public.emissary_claim_notification_v1(
  uuid, text, integer
) RETURNS jsonb LANGUAGE sql AS 'SELECT ''{}''::jsonb';
CREATE FUNCTION public.emissary_finish_notification_v1(
  uuid, text, text, text
) RETURNS jsonb LANGUAGE sql AS 'SELECT ''{}''::jsonb';
CREATE FUNCTION public.emissary_finalize_publish_v1(
  uuid
) RETURNS jsonb LANGUAGE sql AS 'SELECT ''{}''::jsonb';

\i /repo/api/migrations/033_emissary_data_plane_hardening.sql

DO $fresh_verify$
BEGIN
  IF NOT (
    SELECT relrowsecurity
    FROM pg_catalog.pg_class
    WHERE oid = 'public.emissary_auth_tokens'::regclass
  ) OR (
    SELECT count(*)
    FROM public.emissary_security_epochs
    WHERE id = '033-data-plane-credential-reset'
  ) <> 1 THEN
    RAISE EXCEPTION 'fresh role-absent hardening or replay failed';
  END IF;
  IF NOT (
    SELECT relrowsecurity
    FROM pg_catalog.pg_class
    WHERE oid = 'public.emissary_publish_operations'::regclass
  ) OR NOT (
    SELECT relrowsecurity
    FROM pg_catalog.pg_class
    WHERE oid = 'public.emissary_notification_outbox'::regclass
  ) THEN
    RAISE EXCEPTION '033 replay did not harden recovery objects';
  END IF;
  IF (
    SELECT count(*) <> 4
    FROM pg_catalog.pg_proc
    WHERE oid IN (
      'public.emissary_commit_publish_v1(uuid,text,text,jsonb,text,jsonb,jsonb,jsonb,jsonb,integer,integer,integer)'::regprocedure,
      'public.emissary_claim_notification_v1(uuid,text,integer)'::regprocedure,
      'public.emissary_finish_notification_v1(uuid,text,text,text)'::regprocedure,
      'public.emissary_finalize_publish_v1(uuid)'::regprocedure
    )
      AND proconfig @> ARRAY['search_path=pg_catalog, public, pg_temp']
  ) THEN
    RAISE EXCEPTION '033 replay did not pin recovery RPC search paths';
  END IF;
END
$fresh_verify$;

\connect postgres
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN;
CREATE ROLE service_role NOLOGIN;
CREATE SCHEMA shadow;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL PRIVILEGES ON TABLES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  GRANT ALL PRIVILEGES ON SEQUENCES TO anon, authenticated, service_role;

SET search_path = public;
\i /repo/api/migrations/005_emissary.sql
\i /repo/api/migrations/006_emissary_donations.sql
\i /repo/api/migrations/008_platform.sql
\i /repo/api/migrations/009_quota_rpc.sql
\i /repo/api/migrations/010_dataroom_gate_visits.sql
\i /repo/api/migrations/011_web_sessions.sql
\i /repo/api/migrations/012_oauth.sql

-- Model recovery migration 030 already being present before 033.
CREATE TABLE public.emissary_publish_operations (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
CREATE TABLE public.emissary_notification_outbox (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid()
);
CREATE FUNCTION public.emissary_commit_publish_v1(
  uuid, text, text, jsonb, text, jsonb, jsonb, jsonb, jsonb,
  integer, integer, integer
) RETURNS jsonb LANGUAGE sql AS 'SELECT ''{}''::jsonb';
CREATE FUNCTION public.emissary_claim_notification_v1(
  uuid, text, integer
) RETURNS jsonb LANGUAGE sql AS 'SELECT ''{}''::jsonb';
CREATE FUNCTION public.emissary_finish_notification_v1(
  uuid, text, text, text
) RETURNS jsonb LANGUAGE sql AS 'SELECT ''{}''::jsonb';
CREATE FUNCTION public.emissary_finalize_publish_v1(
  uuid
) RETURNS jsonb LANGUAGE sql AS 'SELECT ''{}''::jsonb';

INSERT INTO public.emissary_users (
  id, email, name, email_verified, verification_token
) VALUES (
  '00000000-0000-0000-0000-000000000001',
  'victim@example.test',
  'Victim',
  true,
  'forged-verification'
);

SET ROLE anon;
INSERT INTO public.emissary_auth_tokens (
  user_id, token_hash, harness
) VALUES (
  '00000000-0000-0000-0000-000000000001',
  'forged-auth-token-hash',
  'attacker'
);
INSERT INTO public.emissary_install_tokens (
  token_hash, expires_at
) VALUES (
  'forged-install-token-hash',
  now() + interval '1 day'
);
INSERT INTO public.emissary_web_sessions (
  user_id, token_hash, expires_at
) VALUES (
  '00000000-0000-0000-0000-000000000001',
  'forged-session-hash',
  now() + interval '30 days'
);
INSERT INTO public.emissary_login_tokens (
  user_id, token_hash, expires_at
) VALUES (
  '00000000-0000-0000-0000-000000000001',
  'forged-login-hash',
  now() + interval '15 minutes'
);
INSERT INTO public.emissary_device_codes (
  device_code_hash, user_code, expires_at, approved_user_id
) VALUES (
  'forged-device-hash',
  'EVIL-22',
  now() + interval '10 minutes',
  '00000000-0000-0000-0000-000000000001'
);
INSERT INTO public.oauth_clients (
  client_id, client_name, redirect_uris
) VALUES (
  'attacker-client',
  'Trusted-looking client',
  '["https://attacker.example.test/callback"]'::jsonb
);
INSERT INTO public.oauth_codes (
  code_hash,
  client_id,
  user_id,
  redirect_uri,
  code_challenge,
  expires_at
) VALUES (
  'forged-oauth-code-hash',
  'attacker-client',
  '00000000-0000-0000-0000-000000000001',
  'https://attacker.example.test/callback',
  'known-challenge',
  now() + interval '10 minutes'
);
RESET ROLE;
SQL

# Prove the legacy shape before applying 033: a browser-facing role can mint
# credentials for a victim and can execute the quota RPCs directly.
legacy_shape="$(
  psql_command -At -c \
    "SELECT has_table_privilege('anon', 'public.emissary_auth_tokens', 'INSERT') AND has_table_privilege('anon', 'public.oauth_codes', 'INSERT') AND has_function_privilege('anon', 'public.emissary_record_publish(uuid,int)', 'EXECUTE');"
)"
if [[ "$legacy_shape" != "t" ]]; then
  echo "proof fixture did not reproduce the legacy Supabase grant shape" >&2
  exit 1
fi

# Apply from a hostile search_path. The migration owns its public targets and
# must be safe when executed outside a public-first session.
psql_stdin >/dev/null <<'SQL'
SET search_path = shadow, public;
\i /repo/api/migrations/033_emissary_data_plane_hardening.sql

CREATE TABLE public.emissary_future_probe (id bigint);
CREATE SEQUENCE public.emissary_future_probe_seq;
CREATE FUNCTION public.emissary_future_probe_fn()
RETURNS boolean
LANGUAGE sql
AS 'SELECT true';
SQL

# Verify complete client denial, RLS, exact credential reset, and minimum
# service-role access.
psql_stdin >/dev/null <<'SQL'
DO $verify$
DECLARE
  role_name text;
  table_name text;
  privilege_name text;
  expected_privileges text[];
  actual_privilege boolean;
  should_have_privilege boolean;
  expected_tables text[] := ARRAY[
    'emissary_users',
    'emissary_auth_tokens',
    'emissary_install_tokens',
    'emissary_emissaries',
    'emissary_receipts',
    'emissary_audit_events',
    'emissary_donations',
    'emissary_profiles',
    'emissary_slugs',
    'emissary_stars',
    'emissary_categories',
    'emissary_tags',
    'emissary_quota_counters',
    'emissary_gate_visits',
    'emissary_web_sessions',
    'emissary_login_tokens',
    'emissary_device_codes',
    'oauth_clients',
    'oauth_codes',
    'emissary_security_epochs',
    'emissary_publish_operations',
    'emissary_notification_outbox'
  ];
BEGIN
  FOREACH role_name IN ARRAY ARRAY['anon', 'authenticated']
  LOOP
    FOREACH table_name IN ARRAY expected_tables
    LOOP
      FOREACH privilege_name IN ARRAY ARRAY[
        'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE',
        'REFERENCES', 'TRIGGER'
      ]
      LOOP
        IF pg_catalog.has_table_privilege(
          role_name,
          pg_catalog.format('public.%I', table_name),
          privilege_name
        ) THEN
          RAISE EXCEPTION '% retains % on %',
            role_name, privilege_name, table_name;
        END IF;
      END LOOP;
    END LOOP;

    IF pg_catalog.has_sequence_privilege(
      role_name,
      'public.emissary_audit_events_id_seq',
      'USAGE'
    ) THEN
      RAISE EXCEPTION '% retains audit sequence access', role_name;
    END IF;

    IF pg_catalog.has_function_privilege(
      role_name,
      'public.emissary_record_publish(uuid,int)',
      'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
      role_name,
      'public.emissary_record_email(uuid,int,int)',
      'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
      role_name,
      'public.emissary_release_hosted(uuid)',
      'EXECUTE'
    ) THEN
      RAISE EXCEPTION '% retains quota RPC execution', role_name;
    END IF;

    IF pg_catalog.has_function_privilege(
      role_name,
      'public.emissary_exchange_oauth_code(text,text,text,text,text,text,text,timestamp with time zone)',
      'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
      role_name,
      'public.emissary_commit_publish_v1(uuid,text,text,jsonb,text,jsonb,jsonb,jsonb,jsonb,integer,integer,integer)',
      'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
      role_name,
      'public.emissary_claim_notification_v1(uuid,text,integer)',
      'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
      role_name,
      'public.emissary_finish_notification_v1(uuid,text,text,text)',
      'EXECUTE'
    ) OR pg_catalog.has_function_privilege(
      role_name,
      'public.emissary_finalize_publish_v1(uuid)',
      'EXECUTE'
    ) THEN
      RAISE EXCEPTION '% retains a protected exchange/recovery RPC', role_name;
    END IF;

    IF pg_catalog.has_table_privilege(
      role_name,
      'public.emissary_future_probe',
      'SELECT'
    ) OR pg_catalog.has_sequence_privilege(
      role_name,
      'public.emissary_future_probe_seq',
      'USAGE'
    ) OR pg_catalog.has_function_privilege(
      role_name,
      'public.emissary_future_probe_fn()',
      'EXECUTE'
    ) THEN
      RAISE EXCEPTION '% inherited access to a future object', role_name;
    END IF;
  END LOOP;

  IF pg_catalog.has_function_privilege(
    'public',
    'public.emissary_future_probe_fn()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PUBLIC inherited execution on a future function';
  END IF;
  IF pg_catalog.has_function_privilege(
    'public',
    'public.emissary_exchange_oauth_code(text,text,text,text,text,text,text,timestamp with time zone)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'public',
    'public.emissary_commit_publish_v1(uuid,text,text,jsonb,text,jsonb,jsonb,jsonb,jsonb,integer,integer,integer)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'public',
    'public.emissary_claim_notification_v1(uuid,text,integer)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'public',
    'public.emissary_finish_notification_v1(uuid,text,text,text)',
    'EXECUTE'
  ) OR pg_catalog.has_function_privilege(
    'public',
    'public.emissary_finalize_publish_v1(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'PUBLIC retains a protected exchange/recovery RPC';
  END IF;
  IF pg_catalog.has_table_privilege(
    'service_role',
    'public.emissary_future_probe',
    'SELECT'
  ) OR pg_catalog.has_sequence_privilege(
    'service_role',
    'public.emissary_future_probe_seq',
    'USAGE'
  ) OR pg_catalog.has_function_privilege(
    'service_role',
    'public.emissary_future_probe_fn()',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'service_role inherited broad future-object access';
  END IF;

  FOREACH table_name IN ARRAY expected_tables
  LOOP
    IF NOT (
      SELECT relrowsecurity
      FROM pg_catalog.pg_class
      WHERE oid = pg_catalog.to_regclass(
        pg_catalog.format('public.%I', table_name)
      )
    ) THEN
      RAISE EXCEPTION 'RLS is not enabled on %', table_name;
    END IF;
  END LOOP;

  IF (
    SELECT count(*)
    FROM pg_catalog.pg_policy
    WHERE polrelid = 'public.emissary_publish_operations'::regclass
      AND polname = 'emissary_service_role_select'
      AND polcmd = 'r'
  ) <> 1 OR EXISTS (
    SELECT 1
    FROM pg_catalog.pg_policy
    WHERE polrelid = 'public.emissary_notification_outbox'::regclass
  ) THEN
    RAISE EXCEPTION 'recovery table policies are not least-privilege';
  END IF;

  IF (
    SELECT count(*)
    FROM public.emissary_security_epochs
    WHERE id = '033-data-plane-credential-reset'
  ) <> 1 THEN
    RAISE EXCEPTION 'credential-reset epoch was not recorded exactly once';
  END IF;

  IF (
    SELECT verification_token IS NOT NULL OR email_verified
    FROM public.emissary_users
    WHERE id = '00000000-0000-0000-0000-000000000001'
  ) THEN
    RAISE EXCEPTION 'legacy email-verification state survived';
  END IF;
  IF (
    SELECT revoked_at IS NULL
    FROM public.emissary_auth_tokens
    WHERE token_hash = 'forged-auth-token-hash'
  ) THEN
    RAISE EXCEPTION 'legacy bearer credential survived';
  END IF;
  IF (
    SELECT used_at IS NULL OR expires_at > now()
    FROM public.emissary_install_tokens
    WHERE token_hash = 'forged-install-token-hash'
  ) THEN
    RAISE EXCEPTION 'legacy install credential survived';
  END IF;
  IF (
    SELECT revoked_at IS NULL
    FROM public.emissary_web_sessions
    WHERE token_hash = 'forged-session-hash'
  ) THEN
    RAISE EXCEPTION 'legacy web session survived';
  END IF;
  IF (
    SELECT consumed_at IS NULL OR expires_at > now()
    FROM public.emissary_login_tokens
    WHERE token_hash = 'forged-login-hash'
  ) THEN
    RAISE EXCEPTION 'legacy login credential survived';
  END IF;
  IF (
    SELECT consumed_at IS NULL OR denied_at IS NULL OR expires_at > now()
    FROM public.emissary_device_codes
    WHERE device_code_hash = 'forged-device-hash'
  ) THEN
    RAISE EXCEPTION 'legacy device credential survived';
  END IF;
  IF (
    SELECT revoked_at IS NULL
    FROM public.oauth_clients
    WHERE client_id = 'attacker-client'
  ) THEN
    RAISE EXCEPTION 'legacy OAuth client survived';
  END IF;
  IF (
    SELECT consumed_at IS NULL OR expires_at > now()
    FROM public.oauth_codes
    WHERE code_hash = 'forged-oauth-code-hash'
  ) THEN
    RAISE EXCEPTION 'legacy OAuth code survived';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM information_schema.columns AS c
    WHERE c.table_schema = 'public'
      AND c.table_name = 'emissary_auth_tokens'
      AND c.column_name = 'expires_at'
      AND c.is_nullable = 'YES'
  ) THEN
    RAISE EXCEPTION 'auth-token expiry column is absent or not nullable';
  END IF;

  FOR table_name, expected_privileges IN
    SELECT *
    FROM (
      VALUES
        ('emissary_users', ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]),
        ('emissary_auth_tokens', ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]),
        ('emissary_install_tokens', ARRAY['SELECT', 'UPDATE']::text[]),
        ('emissary_emissaries', ARRAY['SELECT', 'INSERT']::text[]),
        ('emissary_receipts', ARRAY['SELECT', 'INSERT']::text[]),
        ('emissary_audit_events', ARRAY['SELECT', 'INSERT']::text[]),
        ('emissary_donations', ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]),
        ('emissary_profiles', ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]),
        ('emissary_slugs', ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]),
        (
          'emissary_stars',
          ARRAY['SELECT', 'INSERT', 'UPDATE', 'DELETE']::text[]
        ),
        ('emissary_categories', ARRAY['SELECT']::text[]),
        ('emissary_tags', ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]),
        (
          'emissary_quota_counters',
          ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]
        ),
        ('emissary_gate_visits', ARRAY['SELECT', 'INSERT']::text[]),
        (
          'emissary_web_sessions',
          ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]
        ),
        (
          'emissary_login_tokens',
          ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]
        ),
        (
          'emissary_device_codes',
          ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]
        ),
        ('oauth_clients', ARRAY['SELECT', 'INSERT']::text[]),
        ('oauth_codes', ARRAY['SELECT', 'INSERT', 'UPDATE']::text[]),
        ('emissary_security_epochs', ARRAY[]::text[]),
        ('emissary_publish_operations', ARRAY['SELECT']::text[]),
        ('emissary_notification_outbox', ARRAY[]::text[])
    ) AS grants(table_name, expected_privileges)
  LOOP
    FOREACH privilege_name IN ARRAY ARRAY[
      'SELECT', 'INSERT', 'UPDATE', 'DELETE', 'TRUNCATE',
      'REFERENCES', 'TRIGGER'
    ]
    LOOP
      actual_privilege := pg_catalog.has_table_privilege(
        'service_role',
        pg_catalog.format('public.%I', table_name),
        privilege_name
      );
      should_have_privilege := privilege_name = ANY(expected_privileges);
      IF actual_privilege <> should_have_privilege THEN
        RAISE EXCEPTION
          'service_role privilege mismatch on %: % is %, expected %',
          table_name,
          privilege_name,
          actual_privilege,
          should_have_privilege;
      END IF;
    END LOOP;
  END LOOP;

  IF NOT pg_catalog.has_sequence_privilege(
    'service_role',
    'public.emissary_audit_events_id_seq',
    'USAGE'
  ) OR pg_catalog.has_sequence_privilege(
    'service_role',
    'public.emissary_audit_events_id_seq',
    'SELECT'
  ) OR pg_catalog.has_sequence_privilege(
    'service_role',
    'public.emissary_audit_events_id_seq',
    'UPDATE'
  ) THEN
    RAISE EXCEPTION 'service_role audit-sequence privileges are not minimal';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'service_role',
    'public.emissary_record_publish(uuid,int)',
    'EXECUTE'
  ) OR NOT pg_catalog.has_function_privilege(
    'service_role',
    'public.emissary_record_email(uuid,int,int)',
    'EXECUTE'
  ) OR NOT pg_catalog.has_function_privilege(
    'service_role',
    'public.emissary_release_hosted(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'service_role lacks a required quota RPC';
  END IF;

  IF NOT pg_catalog.has_function_privilege(
    'service_role',
    'public.emissary_exchange_oauth_code(text,text,text,text,text,text,text,timestamp with time zone)',
    'EXECUTE'
  ) OR NOT pg_catalog.has_function_privilege(
    'service_role',
    'public.emissary_commit_publish_v1(uuid,text,text,jsonb,text,jsonb,jsonb,jsonb,jsonb,integer,integer,integer)',
    'EXECUTE'
  ) OR NOT pg_catalog.has_function_privilege(
    'service_role',
    'public.emissary_claim_notification_v1(uuid,text,integer)',
    'EXECUTE'
  ) OR NOT pg_catalog.has_function_privilege(
    'service_role',
    'public.emissary_finish_notification_v1(uuid,text,text,text)',
    'EXECUTE'
  ) OR NOT pg_catalog.has_function_privilege(
    'service_role',
    'public.emissary_finalize_publish_v1(uuid)',
    'EXECUTE'
  ) THEN
    RAISE EXCEPTION 'service_role lacks a required exchange/recovery RPC';
  END IF;

  IF (
    SELECT count(*) <> 8
    FROM pg_catalog.pg_proc
    WHERE oid IN (
      'public.emissary_record_publish(uuid,int)'::regprocedure,
      'public.emissary_record_email(uuid,int,int)'::regprocedure,
      'public.emissary_release_hosted(uuid)'::regprocedure,
      'public.emissary_exchange_oauth_code(text,text,text,text,text,text,text,timestamp with time zone)'::regprocedure,
      'public.emissary_commit_publish_v1(uuid,text,text,jsonb,text,jsonb,jsonb,jsonb,jsonb,integer,integer,integer)'::regprocedure,
      'public.emissary_claim_notification_v1(uuid,text,integer)'::regprocedure,
      'public.emissary_finish_notification_v1(uuid,text,text,text)'::regprocedure,
      'public.emissary_finalize_publish_v1(uuid)'::regprocedure
    )
      AND proconfig @> ARRAY['search_path=pg_catalog, public, pg_temp']
  ) THEN
    RAISE EXCEPTION 'protected RPC search_path is not pinned safely';
  END IF;
END
$verify$;
SQL

# Even after an accidental later re-grant, deny-by-default RLS must stop both
# direct credential planting and quota RPC execution.
for hostile_role in anon authenticated; do
  psql_command -c \
    "GRANT SELECT ON public.emissary_users TO $hostile_role; GRANT INSERT ON public.emissary_auth_tokens TO $hostile_role;" \
    >/dev/null
  if psql_command -c \
    "SET ROLE $hostile_role; INSERT INTO public.emissary_auth_tokens (user_id, token_hash) VALUES ('00000000-0000-0000-0000-000000000001', 'post-hardening-$hostile_role');" \
    >/dev/null 2>&1; then
    echo "$hostile_role planted a bearer credential through RLS" >&2
    exit 1
  fi
  psql_command -c \
    "GRANT INSERT, SELECT, UPDATE ON public.emissary_quota_counters TO $hostile_role; GRANT EXECUTE ON FUNCTION public.emissary_record_publish(uuid,int) TO $hostile_role;" \
    >/dev/null
  if psql_command -c \
    "SET ROLE $hostile_role; SELECT public.emissary_record_publish('00000000-0000-0000-0000-000000000001', 86400);" \
    >/dev/null 2>&1; then
    echo "$hostile_role invoked the quota RPC through RLS" >&2
    exit 1
  fi
  psql_command -c \
    "REVOKE ALL PRIVILEGES ON public.emissary_users, public.emissary_auth_tokens, public.emissary_quota_counters FROM $hostile_role; REVOKE ALL PRIVILEGES ON FUNCTION public.emissary_record_publish(uuid,int) FROM $hostile_role;" \
    >/dev/null
done

# A live authorization code issued after hardening is consumed only if its
# bearer-token hash is inserted in the same transaction. Force the insert to
# fail and prove the claim rolls back without any application-side "unclaim".
code_id="$(
  psql_command -qAt -c \
    "SET ROLE service_role; INSERT INTO public.oauth_codes (code_hash, client_id, user_id, redirect_uri, code_challenge, expires_at) VALUES ('legitimate', 'mcp-client', '00000000-0000-0000-0000-000000000001', 'https://client.example.test/callback', 'challenge', now() + interval '10 minutes') RETURNING id;"
)"
if [[ ! "$code_id" =~ ^[0-9a-f-]{36}$ ]]; then
  echo "service_role could not create a legitimate OAuth code" >&2
  exit 1
fi

psql_stdin >/dev/null <<'SQL'
CREATE FUNCTION public.emissary_force_oauth_insert_failure()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF NEW.token_hash = repeat('f', 64) THEN
    RAISE EXCEPTION 'forced token insert failure';
  END IF;
  RETURN NEW;
END;
$$;
CREATE TRIGGER emissary_force_oauth_insert_failure
BEFORE INSERT ON public.emissary_auth_tokens
FOR EACH ROW
EXECUTE FUNCTION public.emissary_force_oauth_insert_failure();
SQL

if psql_command -qAt -c \
  "SET ROLE service_role; SELECT public.emissary_exchange_oauth_code('legitimate', 'mcp-client', 'https://client.example.test/callback', 'challenge', 'S256', repeat('f', 64), 'mcp-oauth', now() + interval '1 year');" \
  >/dev/null 2>&1; then
  echo "forced OAuth token insert unexpectedly succeeded" >&2
  exit 1
fi

rollback_state="$(
  psql_command -At -c \
    "SELECT consumed_at IS NULL AND NOT EXISTS (SELECT 1 FROM public.emissary_auth_tokens WHERE token_hash = repeat('f', 64)) FROM public.oauth_codes WHERE id = '$code_id';"
)"
if [[ "$rollback_state" != "t" ]]; then
  echo "failed OAuth token insert consumed the code or retained a token" >&2
  exit 1
fi

psql_stdin >/dev/null <<'SQL'
DROP TRIGGER emissary_force_oauth_insert_failure
  ON public.emissary_auth_tokens;
DROP FUNCTION public.emissary_force_oauth_insert_failure();
SQL

# The same code remains exchangeable exactly once under a forced concurrent
# race, and exactly one corresponding bearer hash is committed.
(
  psql_command -qAt -c \
    "SET ROLE service_role; SELECT public.emissary_exchange_oauth_code('legitimate', 'mcp-client', 'https://client.example.test/callback', 'challenge', 'S256', repeat('a', 64), 'mcp-oauth', now() + interval '1 year');" \
    >"$proof_tmp/one"
) &
claim_one_pid=$!
(
  psql_command -qAt -c \
    "SET ROLE service_role; SELECT public.emissary_exchange_oauth_code('legitimate', 'mcp-client', 'https://client.example.test/callback', 'challenge', 'S256', repeat('b', 64), 'mcp-oauth', now() + interval '1 year');" \
    >"$proof_tmp/two"
) &
claim_two_pid=$!
wait "$claim_one_pid"
wait "$claim_two_pid"

claimed_count="$(
  awk \
    'length($0) > 0 { count += 1 } END { print count + 0 }' \
    "$proof_tmp"/one "$proof_tmp"/two
)"
if [[ "$claimed_count" != "1" ]]; then
  echo "authorization code exchange succeeded $claimed_count times, expected once" >&2
  exit 1
fi

exchange_state="$(
  psql_command -At -c \
    "SELECT consumed_at IS NOT NULL AND (SELECT count(*) = 1 FROM public.emissary_auth_tokens WHERE token_hash IN (repeat('a', 64), repeat('b', 64))) FROM public.oauth_codes WHERE id = '$code_id';"
)"
if [[ "$exchange_state" != "t" ]]; then
  echo "OAuth exchange did not commit exactly one code and token hash" >&2
  exit 1
fi

# Replaying 033 must preserve credentials issued after the one-time reset.
psql_command -c \
  "SET ROLE service_role; INSERT INTO public.emissary_auth_tokens (user_id, token_hash, harness, expires_at) VALUES ('00000000-0000-0000-0000-000000000001', 'post-reset-live-token', 'mcp-oauth', now() + interval '1 year'); INSERT INTO public.emissary_web_sessions (user_id, token_hash, expires_at) VALUES ('00000000-0000-0000-0000-000000000001', 'post-reset-live-session', now() + interval '30 days');" \
  >/dev/null

psql_stdin >/dev/null <<'SQL'
SET search_path = shadow, public;
\i /repo/api/migrations/033_emissary_data_plane_hardening.sql
SQL

replay_state="$(
  psql_command -At -c \
    "SELECT (SELECT revoked_at IS NULL FROM public.emissary_auth_tokens WHERE token_hash = 'post-reset-live-token') AND (SELECT revoked_at IS NULL FROM public.emissary_web_sessions WHERE token_hash = 'post-reset-live-session') AND (SELECT count(*) = 1 FROM public.emissary_security_epochs WHERE id = '033-data-plane-credential-reset');"
)"
if [[ "$replay_state" != "t" ]]; then
  echo "migration replay invalidated post-reset credentials or duplicated epoch" >&2
  exit 1
fi

echo "PostgreSQL 16 Emissary data-plane hardening proof passed"
