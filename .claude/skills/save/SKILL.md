---
name: save
description: "Save current Egregore work: validate distribution, commit the task branch, push it, and create or reuse a PR against the configured integration branch."
---

Save work without asking the user to manage Git mechanics.

## When to invoke

Use for “save”, “commit and push”, “push this work”, or `$save`. When the user
is ending a session and needs a durable continuation record, use `handoff` or
`wrap` first; their canonical writes are already independently durable.

## Contract

- `bin/agent.sh save` is the one runtime-neutral Git transaction for Claude,
  Codex, Pi, and Prime.
- Resolve the integration branch from `egregore.json`; never hardcode
  `develop` or `main`.
- Do not scan or mutate the graph before/after saving. Canonical lifecycle and
  projection repair are separate Runtime operations.
- Do not repeat canonical artifact writeback. Save only outstanding repository
  changes and already-created memory records.
- The current Git/GitHub transport remains valid but is behind the sync
  boundary; GitHub identity is not ActorIdentity.

## Flow

1. Inspect branch, working-tree changes, memory changes, ahead count, and an
   existing PR. A clean tree can still need a push/PR when the branch is ahead.
2. Resolve the configured integration branch first:

```bash
bash bin/base-branch.sh
```
It prints the branch name; for a managed repo run `bash bin/base-branch.sh <repo-name>`.
A non-zero exit means the configuration could not be resolved: stop before any
Git change. Use the printed name wherever `{base}` appears below.

Stop before mutation if it cannot be resolved.

3. The shared `bin/agent.sh save` preflight runs distribution validation,
   the change report, and the strict Runtime-skill audit before any memory or
   project mutation. Both engine and registry must exist; installed public
   instances intentionally omit the development engine.

   It also prints an advisory affected-skill receipt from the branch diff,
   staged/unstaged edits, and relevant untracked files. Read the named
   instructions for drift and include material findings in PR verification;
   ordinary edits require no new approval. A missing base is reported as an
   unavailable review, never as zero affected skills. Set
   `EGREGORE_SKILL_REVIEW=0` only to explicitly disable this advisory receipt.

Ask one placement question only for a genuinely new/unclassified component or
an explicit placement change. Ordinary edits to an existing component do not
prompt.

For that question, show `artifacts/capability-pipeline.html` and offer:

1. OSS + Connect — part of the open runtime; Connect inherits it.
2. Connect only — delivered only to authenticated Connect users.
3. Curve Labs / Egregore — used only in this development instance.

Record each new component as `queued` under the selected placement with all
its governed source paths. Availability changes separately after review.
Group components in one checkpoint only when they share a placement. Apply
the decision to `capability-distribution.json`, regenerate
`skill-distribution.json` and both artifacts, then validate again. Rebuild
runtime packs when an available runtime component changes placement. Reuse
an explicit placement decision from the current work; do not ask twice.

4. Derive:

- a short topic;
- a commit subject/body under `.claude/context/commit-format.md`;
- a PR body under `.claude/context/pr-format.md`, including honest
  verification for non-Markdown changes.

If unrelated changes make the save scope ambiguous, show one Save all / Narrow
scope checkpoint. Otherwise continue without ritual confirmation.

5. Choose readiness from the work's actual state, without a permission ritual:

- While implementation or review continues, use `--draft`. New code PRs are
  drafts by default; passing `--draft` also converts an existing ready PR
  before pushing, avoiding paid checks on unfinished iterations.
- When the requested work is complete and local QA/review has passed, use
  `--ready`. For an existing draft, the bridge pushes the final head before
  marking it ready, so CI checks the saved version. If checks fail or another
  edit is needed, use `--draft` for the next in-progress save.
- Non-coding saves keep their existing ready/auto-merge behavior. Omit the
  readiness flag unless the work should deliberately remain a draft.
- Without a flag, existing PRs retain their current readiness. `--draft` and
  `--ready` are mutually exclusive and cannot be combined with `--no-pr`.

6. Execute exactly once:

Use `{message}`, `{topic}`, and `{pr_body}` for the commit subject/body, topic, and PR body derived in Step 4; single-quote each value, writing an embedded single quote as `'\''`. Append `--draft` or `--ready` as selected above; omit both for the normal non-coding path.

```bash
bin/agent.sh save \
  --message '{message}' \
  --topic '{topic}' \
  --pr-body '{pr_body}'
```

The bridge owns branch safety, exact commits, push, PR create/reuse, and memory
sync. Do not run manual Git commands around it or trigger a graph scan.

7. Report only the branch, commit/push outcome, PR URL/reuse and draft/ready
state, memory sync, and any failed step. Local commits remain safe if transport fails.

## Rules

- Never push directly to a protected integration/stable branch.
- Never use destructive Git commands.
- Never auto-close handoffs or todos during save.
- Never publish or notify as an implied side effect.
- Do not spend a Loom/model-routing turn on deterministic save mechanics.

Emit content-free command telemetry after the bridge returns:

```bash
bash bin/telemetry.sh emit "command" '{"command":"save"}' 2>/dev/null &
```
