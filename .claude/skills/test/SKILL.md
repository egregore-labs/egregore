---
name: test
description: "Run Egregore's fast static, Runtime-contract, and targeted automated test gate before save. Optional relationship index validation requires an explicit request."
---

Run the fast automated gate for the current change.

## When to invoke

Use for `$test`, “test my changes”, or a quick pre-save validation. Use `qa`
for broader behavioral proof and adversarial fixtures.

Arguments: `$ARGUMENTS` — optional paths, `--all`, or explicit `--graph`.

## Default gate

1. Run `bash bin/base-branch.sh` to print the configured integration branch.
   Scope to supplied paths, `--all`, or changed files against that branch.
2. Run static analysis once:

```bash
bash bin/test-changes.sh <scope>
```

`--all` scans source skills plus Runtime-neutral shell adapters. Do not treat a
missing historical `.claude/commands` directory as test coverage.

3. Run the architectural ratchet once (source instances only — installed
   instances do not ship the distribution engine and skip this step):

```bash
if [ -f bin/capability-distribution.mjs ] && [ -f capability-distribution.json ]; then
  bash bin/node-run.sh bin/capability-distribution.mjs runtime-skill-audit \
    --root . --strict-contract
fi
```

This checks the complete skill denominator, QMD/graph/control-plane/write
coupling ceilings, and migrated-skill contracts.

4. Select the smallest relevant existing test suites from the changed paths
and `skill-references.json`. Run independent suites in parallel where the
harness supports it. Do not rerun the same suite through multiple rituals.
5. For changes to cross-harness Runtime sources or skills, run Codex/Pi/Prime
bundle parity checks.

## Optional graph validation

Only when the user explicitly passed `--graph` or changed the graph projection
adapter itself:

- require Connected graph capability;
- extract bounded read-only Cypher fixtures from the named graph files only;
- reject `CREATE`, `MERGE`, `SET`, `DELETE`, `REMOVE`, or `DROP`;
- validate through the optional graph projection adapter;
- report graph unavailable as an optional-check gap, not a Local test failure.

Never scan every skill for Cypher and execute it against a live database.

## Result

Render one compact pass/fail report with:

- static checks;
- Runtime architecture audit;
- targeted suites and counts;
- bundle parity when applicable;
- optional graph check only when requested;
- exact failures and the safe next action.

Warnings do not block unless they represent a privacy, authorization,
canonical-order, or destructive-action risk.

## Rules

- No default Neo4j, API, or network dependency.
- Tests must not modify production/live QMD, graph, control-plane, or canonical
  memory state.
- Use isolated fixtures for writes and destructive/failure behavior.
- Never call graph functionality the correct default Runtime boundary.
- Do not claim “safe to save” when required suites were skipped.

Emit content-free telemetry after the gate:

```bash
bash bin/telemetry.sh emit "command" '{"command":"test"}' 2>/dev/null &
```
