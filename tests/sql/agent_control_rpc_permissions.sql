-- Only for the disposable database created by the companion PG17 runner.
-- Real migration functions, synthetic data, no production connection accepted.
\set ON_ERROR_STOP on
CREATE ROLE anon;
CREATE ROLE authenticated;
CREATE ROLE service_role BYPASSRLS;
CREATE ROLE unrelated_operator;
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role, unrelated_operator;

CREATE TABLE public.orgs (slug text PRIMARY KEY);
CREATE TABLE public.users (id bigint PRIMARY KEY);
-- Supabase-style explicit defaults are distinct from the PUBLIC default grant.
ALTER DEFAULT PRIVILEGES IN SCHEMA public
    GRANT EXECUTE ON FUNCTIONS TO anon, authenticated;
\ir ../../api/migrations/013_agent_task_pipeline.sql

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

CREATE TEMP TABLE target_functions (signature text PRIMARY KEY, function_id oid);
INSERT INTO target_functions(signature, function_id)
SELECT signature, signature::regprocedure::oid FROM (VALUES
    ('public.agent_claim_command(uuid,text)'),
    ('public.agent_acquire_lease(text,text,uuid,integer)'),
    ('public.agent_renew_lease(text,text,uuid,bigint,integer)'),
    ('public.agent_release_lease(text,text,uuid,bigint)'),
    ('public.agent_set_plan(uuid,bigint,jsonb,text,jsonb)')
) AS signatures(signature);

-- Fresh installations must resist explicit default grants too. Approval is
-- included here because 013 defines it; 052 intentionally changes only five RPCs.
SELECT proof.check_true((
    SELECT count(*) = 6 AND bool_and(
        NOT has_function_privilege('anon', p.oid, 'EXECUTE') AND
        NOT has_function_privilege('authenticated', p.oid, 'EXECUTE') AND
        has_function_privilege('service_role', p.oid, 'EXECUTE')
    ) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname IN (
        'agent_claim_command', 'agent_acquire_lease', 'agent_renew_lease',
        'agent_release_lease', 'agent_set_plan', 'agent_approve_plan'
    )
), '013 must remove explicit browser-role defaults for all six RPCs');

-- Reconstruct the confirmed legacy defect without changing any function body.
GRANT EXECUTE ON FUNCTION
    public.agent_claim_command(uuid,text),
    public.agent_acquire_lease(text,text,uuid,integer),
    public.agent_renew_lease(text,text,uuid,bigint,integer),
    public.agent_release_lease(text,text,uuid,bigint),
    public.agent_set_plan(uuid,bigint,jsonb,text,jsonb)
TO anon, authenticated;
REVOKE ALL ON FUNCTION
    public.agent_claim_command(uuid,text),
    public.agent_acquire_lease(text,text,uuid,integer),
    public.agent_renew_lease(text,text,uuid,bigint,integer),
    public.agent_release_lease(text,text,uuid,bigint),
    public.agent_set_plan(uuid,bigint,jsonb,text,jsonb)
FROM PUBLIC;
SELECT proof.check_true((
    SELECT bool_and(has_function_privilege('anon', function_id, 'EXECUTE') AND
                    has_function_privilege('authenticated', function_id, 'EXECUTE'))
    FROM target_functions
), 'PUBLIC revocation alone must leave explicit client grants effective');
GRANT EXECUTE ON FUNCTION public.agent_claim_command(uuid,text) TO unrelated_operator;
CREATE FUNCTION public.agent_permission_fixture_unrelated() RETURNS text
LANGUAGE sql AS $$ SELECT 'unchanged'::text $$;

INSERT INTO public.orgs VALUES ('fixture-org');
INSERT INTO public.users VALUES (1);
INSERT INTO public.agent_tasks(id, org_slug, created_by_user_id, owner_user_id, title, description)
VALUES ('10000000-0000-0000-0000-000000000001', 'fixture-org', 1, 1, 'Fixture task', 'Synthetic permission test');
INSERT INTO public.agent_workers(id, status) VALUES ('fixture-worker', 'healthy');
INSERT INTO public.agent_task_runs(id, task_id, phase, attempt, lane, worker_id)
VALUES ('20000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'implementation', 0, 'fixture-lane', 'fixture-worker');
INSERT INTO public.agent_commands(id, task_id, command_kind, phase, plan_version, attempt, sequence, target_queue, idempotency_key)
VALUES ('30000000-0000-0000-0000-000000000001', '10000000-0000-0000-0000-000000000001', 'plan', 'planning', 0, 0, 0, 'tasks:planner', 'fixture-command');

CREATE FUNCTION proof.exercise_calls() RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
    task_row public.agent_tasks%ROWTYPE;
    command_row public.agent_commands%ROWTYPE;
    lease_row public.agent_leases%ROWTYPE;
BEGIN
    SELECT * INTO task_row FROM public.agent_set_plan(
        '10000000-0000-0000-0000-000000000001', 1,
        '{"summary":"fixture"}', 'fixture-hash',
        '[{"phase":"implementation","title":"Fixture step","weight":1}]'
    );
    PERFORM proof.check_true(task_row.plan_version = 1 AND task_row.row_version = 2
        AND task_row.status = 'awaiting_plan_approval', 'plan RPC must actually update the fixture');
    SELECT * INTO command_row FROM public.agent_claim_command(
        '30000000-0000-0000-0000-000000000001', 'fixture-worker'
    );
    PERFORM proof.check_true(command_row.state = 'in_progress' AND command_row.attempts = 1,
        'claim RPC must actually claim the fixture command');
    SELECT * INTO lease_row FROM public.agent_acquire_lease(
        'fixture-lane', 'fixture-worker', '20000000-0000-0000-0000-000000000001', 120
    );
    PERFORM proof.check_true(lease_row.fencing_token = 1 AND lease_row.holder_worker_id = 'fixture-worker',
        'acquire RPC must actually acquire the fixture lease');
    PERFORM proof.check_true(public.agent_renew_lease(
        'fixture-lane', 'fixture-worker', '20000000-0000-0000-0000-000000000001', 1, 120
    ), 'renew RPC must renew the fixture lease');
    PERFORM proof.check_true(public.agent_release_lease(
        'fixture-lane', 'fixture-worker', '20000000-0000-0000-0000-000000000001', 1
    ), 'release RPC must release the fixture lease');
END $$;
CREATE FUNCTION proof.expect_all_denied() RETURNS void
LANGUAGE plpgsql AS $$ BEGIN
    PERFORM proof.expect_denied($q$SELECT * FROM public.agent_claim_command('30000000-0000-0000-0000-000000000001','fixture-worker')$q$);
    PERFORM proof.expect_denied($q$SELECT * FROM public.agent_acquire_lease('fixture-lane','fixture-worker','20000000-0000-0000-0000-000000000001',120)$q$);
    PERFORM proof.expect_denied($q$SELECT public.agent_renew_lease('fixture-lane','fixture-worker','20000000-0000-0000-0000-000000000001',1,120)$q$);
    PERFORM proof.expect_denied($q$SELECT public.agent_release_lease('fixture-lane','fixture-worker','20000000-0000-0000-0000-000000000001',1)$q$);
    PERFORM proof.expect_denied($q$SELECT * FROM public.agent_set_plan('10000000-0000-0000-0000-000000000001',1,'{"summary":"fixture"}','fixture-hash','[{"title":"Fixture step","weight":1}]')$q$);
END $$;
CREATE FUNCTION proof.task_state() RETURNS jsonb LANGUAGE sql AS $$
    SELECT jsonb_build_object(
        'orgs', (SELECT jsonb_agg(to_jsonb(t) ORDER BY slug) FROM public.orgs t),
        'users', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.users t),
        'tasks', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.agent_tasks t),
        'steps', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.agent_task_steps t),
        'runs', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.agent_task_runs t),
        'events', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.agent_task_events t),
        'questions', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.agent_questions t),
        'approvals', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.agent_approvals t),
        'workers', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.agent_workers t),
        'commands', (SELECT jsonb_agg(to_jsonb(t) ORDER BY id) FROM public.agent_commands t),
        'leases', (SELECT jsonb_agg(to_jsonb(t) ORDER BY lane) FROM public.agent_leases t),
        'dependencies', (SELECT jsonb_agg(to_jsonb(t) ORDER BY task_id, depends_on_task_id) FROM public.agent_task_dependencies t)
    );
$$;
CREATE TEMP TABLE expected_state AS SELECT proof.task_state() AS state;
CREATE TEMP TABLE expected_functions AS
SELECT p.oid, p.proacl, pg_get_functiondef(p.oid) AS definition
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public';

-- Actual unauthorized mutations succeed despite direct table denial; roll back
-- each demonstration so the same fixture can exercise all five calls again.
BEGIN;
SET LOCAL ROLE anon;
SELECT proof.expect_denied('SELECT * FROM public.agent_tasks');
SELECT proof.exercise_calls();
ROLLBACK;
BEGIN;
SET LOCAL ROLE authenticated;
SELECT proof.expect_denied('SELECT * FROM public.agent_tasks');
SELECT proof.exercise_calls();
ROLLBACK;
SELECT proof.check_true((SELECT state = proof.task_state() FROM expected_state), 'legacy demonstrations must roll back');

\ir ../../api/migrations/052_agent_control_rpc_permissions.sql
\ir ../../api/migrations/052_agent_control_rpc_permissions.sql

SELECT proof.check_true((
    SELECT count(*) = 5 AND bool_and(
        NOT has_function_privilege('anon', function_id, 'EXECUTE') AND
        NOT has_function_privilege('authenticated', function_id, 'EXECUTE') AND
        has_function_privilege('service_role', function_id, 'EXECUTE') AND
        NOT EXISTS (
            SELECT 1 FROM pg_proc p,
                LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) a
            WHERE p.oid = function_id AND a.grantee = 0 AND a.privilege_type = 'EXECUTE'
        )
    ) FROM target_functions
), 'all five RPCs must deny browser and PUBLIC execution while allowing the service');
SELECT proof.check_true((
    SELECT bool_and(p.oid IS NOT NULL AND e.definition = pg_get_functiondef(p.oid))
    FROM expected_functions e LEFT JOIN pg_proc p ON p.oid = e.oid
), 'all function identities and bodies must be unchanged');
SELECT proof.check_true((
    SELECT bool_and(e.proacl IS NOT DISTINCT FROM p.proacl)
    FROM expected_functions e JOIN pg_proc p ON p.oid = e.oid
    WHERE e.oid NOT IN (SELECT function_id FROM target_functions)
), 'unrelated function permissions, including approval, must be unchanged');
SELECT proof.check_true(has_function_privilege('unrelated_operator',
    'public.agent_claim_command(uuid,text)', 'EXECUTE'), 'unrelated explicit role grant must be preserved');
SELECT proof.check_true((SELECT state = proof.task_state() FROM expected_state), 'migration must not mutate task data');

SET ROLE anon;
SELECT proof.expect_all_denied();
RESET ROLE;
SET ROLE authenticated;
SELECT proof.expect_all_denied();
RESET ROLE;
BEGIN;
SET LOCAL ROLE service_role;
SELECT proof.exercise_calls();
ROLLBACK;
SELECT proof.check_true((SELECT state = proof.task_state() FROM expected_state), 'service smoke must roll back');
SELECT 'PASS: explicit-grant bypass; both client roles denied; all five service RPCs work; bodies/data/other grants unchanged; replay';
