-- Run only inside the disposable database created by the companion test.
\set ON_ERROR_STOP on
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role BYPASSRLS;
CREATE ROLE limited_reader;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role, limited_reader;

CREATE TABLE public.orgs (
    slug text PRIMARY KEY, name text, github_org text, created_by text,
    created_at timestamptz DEFAULT now()
);
CREATE TABLE public.telemetry_events (
    type text, org_slug text, user_handle text, ts timestamptz, data jsonb
);
CREATE TABLE public.health_checkins (
    org_slug text, github_username text, framework_version text,
    platform text, checked_in_at timestamptz
);
CREATE TABLE public.memberships (org_slug text, user_id bigint, status text);
CREATE TABLE public.users (id bigint, github_username text);
CREATE TABLE public.artifacts (org_slug text);

-- Exercise the real view and all five current view-consuming functions.
\ir ../../api/migrations/028_adoption_metrics.sql
\ir ../../api/migrations/035_org_evidence.sql
\ir ../../api/migrations/036_adoption_activity.sql

INSERT INTO public.orgs (slug, name, github_org, created_by) VALUES
    ('alpha', 'Alpha', 'AlphaOrg', 'external-founder'),
    ('beta', 'Beta', 'BetaOrg', 'fcdagdelen');
INSERT INTO public.telemetry_events VALUES
    ('session_start', 'alpha', 'alice', now(), '{}'),
    ('command', 'alpha', 'alice', now(), '{"command":"handoff"}'),
    ('session_start', 'beta', 'bob', now(), '{}');
INSERT INTO public.users VALUES (1, 'alice');
INSERT INTO public.memberships VALUES ('alpha', 1, 'active');
INSERT INTO public.health_checkins VALUES ('alpha', 'alice', 'fixture', 'fixture', now());
INSERT INTO public.artifacts VALUES ('alpha');

ALTER TABLE public.orgs ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.adoption_exclusions ENABLE ROW LEVEL SECURITY;
CREATE POLICY limited_org ON public.orgs FOR SELECT TO limited_reader
    USING (slug = 'alpha');
CREATE POLICY classification ON public.adoption_exclusions FOR SELECT TO limited_reader
    USING (true);
GRANT SELECT ON ALL TABLES IN SCHEMA public TO service_role;
GRANT SELECT ON public.orgs, public.adoption_exclusions
    TO anon, authenticated, limited_reader;
GRANT ALL PRIVILEGES ON public.adoption_orgs TO PUBLIC, anon, authenticated;
GRANT SELECT (slug), UPDATE (name) ON public.adoption_orgs
    TO PUBLIC, anon, authenticated;

CREATE SCHEMA proof;
GRANT USAGE ON SCHEMA proof TO PUBLIC;
CREATE FUNCTION proof.check_true(ok boolean, label text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%', label; END IF;
END $$;
CREATE FUNCTION proof.expect_denied(statement text) RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    BEGIN
        EXECUTE statement;
    EXCEPTION WHEN insufficient_privilege THEN RETURN;
    END;
    RAISE EXCEPTION 'Unexpectedly permitted: %', statement;
END $$;
CREATE FUNCTION proof.report() RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object(
        'summary', (SELECT jsonb_agg(to_jsonb(x)) FROM public.adoption_summary() x),
        'timeseries', (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.day) FROM public.adoption_timeseries(7) x),
        'orgs', (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.slug) FROM public.adoption_org_table() x),
        'activity', (SELECT jsonb_agg(to_jsonb(x)) FROM public.adoption_activity() x),
        'commands', (SELECT jsonb_agg(to_jsonb(x) ORDER BY x.command) FROM public.adoption_command_ranking() x)
    );
$$;

-- Establish the failing legacy boundary before applying the fix.
SET ROLE anon;
SELECT proof.check_true((SELECT count(*) = 0 FROM public.orgs), 'base RLS must deny anon');
SELECT proof.check_true((SELECT count(*) = 2 FROM public.adoption_orgs), 'legacy view must bypass base RLS');
RESET ROLE;

CREATE TEMP TABLE expected_view AS
SELECT oid, pg_get_viewdef(oid) AS definition
FROM pg_class WHERE oid = 'public.adoption_orgs'::regclass;
SET ROLE service_role;
SELECT proof.check_true((SELECT installs_total = 1 FROM public.adoption_summary()), 'nonempty reporting baseline');
CREATE TEMP TABLE expected_report AS SELECT proof.report() AS result;
RESET ROLE;

\ir ../../api/migrations/051_adoption_view_security.sql
\ir ../../api/migrations/051_adoption_view_security.sql

SELECT proof.check_true(
    (SELECT oid = 'public.adoption_orgs'::regclass AND definition = pg_get_viewdef(oid)
     FROM expected_view), 'view identity and definition must be preserved');
SELECT proof.check_true(
    (SELECT reloptions @> ARRAY['security_invoker=true'] FROM pg_class
     WHERE oid = 'public.adoption_orgs'::regclass), 'invoker mode must be enabled');
SELECT proof.check_true((
    SELECT count(*) = 5 AND bool_and(NOT p.prosecdef)
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
        'adoption_summary', 'adoption_timeseries', 'adoption_org_table',
        'adoption_activity', 'adoption_command_ranking'
    )
), 'reporting consumers must remain invoker functions');

SET ROLE anon;
SELECT proof.expect_denied('SELECT slug FROM public.adoption_orgs');
SELECT proof.expect_denied('INSERT INTO public.adoption_orgs (slug) VALUES (''new-org'')');
SELECT proof.expect_denied('UPDATE public.adoption_orgs SET name = ''changed'' WHERE slug = ''alpha''');
SELECT proof.expect_denied('DELETE FROM public.adoption_orgs WHERE slug = ''alpha''');
SELECT proof.expect_denied('SELECT * FROM public.adoption_summary()');
SELECT proof.expect_denied('SELECT * FROM public.adoption_timeseries(7)');
SELECT proof.expect_denied('SELECT * FROM public.adoption_org_table()');
SELECT proof.expect_denied('SELECT * FROM public.adoption_activity()');
SELECT proof.expect_denied('SELECT * FROM public.adoption_command_ranking()');
RESET ROLE;
SET ROLE authenticated;
SELECT proof.expect_denied('SELECT slug FROM public.adoption_orgs');
SELECT proof.expect_denied('INSERT INTO public.adoption_orgs (slug) VALUES (''new-org'')');
SELECT proof.expect_denied('UPDATE public.adoption_orgs SET name = ''changed'' WHERE slug = ''alpha''');
SELECT proof.expect_denied('DELETE FROM public.adoption_orgs WHERE slug = ''alpha''');
SELECT proof.expect_denied('SELECT * FROM public.adoption_summary()');
SELECT proof.expect_denied('SELECT * FROM public.adoption_timeseries(7)');
SELECT proof.expect_denied('SELECT * FROM public.adoption_org_table()');
SELECT proof.expect_denied('SELECT * FROM public.adoption_activity()');
SELECT proof.expect_denied('SELECT * FROM public.adoption_command_ranking()');
RESET ROLE;
SET ROLE limited_reader;
SELECT proof.expect_denied('SELECT slug FROM public.adoption_orgs');
RESET ROLE;

SET ROLE service_role;
SELECT proof.check_true((SELECT result = proof.report() FROM expected_report), 'all five service reports must be unchanged');
RESET ROLE;

-- Isolate invoker behavior from the ACL fix: a temporary grant may expose
-- only the permitted base-table row, never the owner's broader visibility.
BEGIN;
GRANT SELECT ON public.adoption_orgs TO limited_reader;
SET LOCAL ROLE limited_reader;
SELECT proof.check_true((SELECT array_agg(slug) = ARRAY['alpha'] FROM public.adoption_orgs), 'view must obey caller RLS');
ROLLBACK;

SELECT 'PASS: legacy reproduction; table/column/PUBLIC denial; five unchanged reports; invoker RLS; replay';
