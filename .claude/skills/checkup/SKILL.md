---
name: checkup
description: "Run diagnostics on an Egregore environment and render a health report, repairing safe local Runtime problems when possible. Use for /checkup, a health check, or when something is broken and the root cause is unclear."
---

# Egregore checkup

Diagnose the Egregore Runtime first. Treat canonical Markdown and its
instance-owned Local Retriever as the product baseline. Graph, control-plane,
and notification probes are explicit Connected integrations; their failure
must never make canonical Local Runtime state look unavailable.

## When to invoke

Run diagnostics on an Egregore environment and render a health report, repairing safe local Runtime problems when possible. Use for /checkup, a health check, or when something is broken and the root cause is unclear.

## Procedure

Detect mode without attempting a network call:

```bash
bash bin/config-get.sh mode
```

Use the printed value as `{mode}`; quote it in single quotes when you use it in a command, and write any single quote inside the value as `'\''`. If it prints `local`, skip Connected
integrations; if it prints `connected`, include them after the local checks.

Run three sequential batches. Parallelize only within a batch.

1. Runtime and local configuration.
2. Connected integrations, only when `{mode}` is `connected`.
3. Workspace and Git checks.

Never run Connected network probes beside local checks; a timeout must not
cancel or obscure the Runtime result.

## Batch 1: canonical Runtime

Read the one typed Runtime health surface as JSON:

```bash
EGREGORE_ROOT="$PWD" PYTHONSAFEPATH=1 PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m egregore_runtime.harness_cli status --json
```

Do not invoke `qmd`, inspect QMD process tables, guess ports, or read another
instance's runtime directory. The adapter owns those mechanics. Interpret the
returned fields as follows:

- `canonical_state_ready` — foundational. Fail only when canonical memory is
  unavailable.
- `adapter=qmd-local`, `collection`, and `index_path` — the resolved
  instance-owned Local Retriever. Display these without exposing another
  instance or deriving ownership yourself.
- `runtime_state`, `runtime_pid`, and `runtime_endpoint` — owned worker
  readiness. `semantic_ready` is healthy; `semantic_index_building` is a
  warning with lexical fallback; `runtime_unavailable` is repairable.
- `bm25_ready` — local keyword readiness. Warn when false.
- `semantic_ready` and `embedding_state` — semantic readiness. A warming or
  missing model is degraded, not canonical data loss.
- `index_spec_version`, `index_revision`, and `source_revision` — freshness.
  Report drift; never repair it by editing index files.
- `warnings` — show concise, redacted messages.

Also validate `egregore.json`, the canonical `memory` link/repository, and the
mode-appropriate key names in `.env`. Never print secret values. Local mode
requires no control-plane key.

If the Runtime worker or indexes are unavailable while canonical memory is
ready, run the safe Runtime lifecycle adapter once:

```bash
bash bin/search.sh start
```

Then re-read Runtime health once. This starts or reuses only the worker owned
by this Egregore instance and schedules semantic warming behind the adapter.

## Batch 2: Connected integrations

Skip this batch completely in local mode. In connected mode, label every row
as an integration, keep it outside the foundational Runtime verdict, and run:

```bash
timeout 10 bash bin/graph-projection.sh verify --enable 2>&1; echo "EXIT:$?"
timeout 10 bash bin/notification.sh status 2>&1; echo "EXIT:$?"
```

- **Hosted relationship index** — pass when the gateway accepts the
  configured credentials and the projection is reachable. Offline, auth, or
  stale projection results are Connected warnings; canonical Markdown remains
  authoritative.
- **Notification adapter** — read the sanitized Runtime `status` field. Treat
  `ok` (connected) or `configured` (local) as healthy. Telegram is optional
  and never part of Runtime readiness.

Do not auto-replace API keys, repair graph state, publish, or send a
notification. Report the exact integration boundary that failed.

## Batch 3: workspace

Check locally:

- the configured base branch exists and compare it with `origin/<base>` only
  when an origin is already configured;
- the current worktree and memory repository are clean or clearly report their
  dirty-file counts;
- the framework version is readable locally. Do not fetch merely to render a
  health report;
- the shell launcher points at this instance when a launcher is configured.

Never mutate Git, canonical memory, or framework files during diagnosis.
Offer `$pull`, `$update`, or `$setup` as the next Egregore action when relevant;
do not tell the user to construct repair commands manually.

## Rendering

Render one compact diagnostic box. In connected mode add a separate
`CONNECTED INTEGRATIONS` section after `RUNTIME`; in local mode omit it.

```text
┌──────────────────────────────────────────────────────────────────────┐
│  ⊕ CHECKUP                                          {date}         │
├──────────────────────────────────────────────────────────────────────┤
│  CONFIG                                                              │
│  ✓ Instance — {org} ({mode})                                        │
│                                                                      │
│  RUNTIME                                                             │
│  ✓ Canonical memory — ready · source {source_revision}              │
│  ✓ Local Retriever — qmd-local {adapter_version} · owned            │
│  ⚠ Semantic index — warming · lexical fallback ready                │
│  ✓ Worker — pid {pid} · {endpoint}                                  │
│                                                                      │
│  CONNECTED INTEGRATIONS                                              │
│  ⚠ Hosted relationship index — offline · local memory ready         │
│  ✓ Telegram — connected                                             │
│                                                                      │
│  WORKSPACE                                                           │
│  ✓ Memory repository — clean                                        │
│  ✓ Git — {base} synced                                               │
├──────────────────────────────────────────────────────────────────────┤
│  Runtime ready · {warnings} warnings · integrations {state}         │
└──────────────────────────────────────────────────────────────────────┘
```

Use `✓`, `⚠`, and `✗` for pass, degraded, and unavailable. State the Runtime
verdict independently from Connected integration health. After a safe Runtime
repair, append only the rechecked result.

## Rules

- Never expose raw JSON, tokens, environment values, or unformatted probes.
- Never use Graph or a control-plane response as canonical health authority.
- Never call QMD directly; instance ownership belongs to Egregore Runtime.
- Never send, publish, commit, pull, or push as part of checkup.
- Emit telemetry only through the normal command wrapper, best-effort.
