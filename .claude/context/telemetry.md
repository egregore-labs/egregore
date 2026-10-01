# Telemetry Spec

Telemetry makes runtime behavior inspectable without turning organizational
content into an analytics feed. Rich events are local-first, content-free,
user-controlled, and excluded from canonical memory and Git.

## How it works

`bin/telemetry.sh` provides the shell compatibility and inspection interface;
Runtime callers use `LocalTelemetrySink` for the same local event envelope:

```bash
# Emit an event (O(1) local append, no network)
bash bin/telemetry.sh emit "command" '{"command":"save"}'

# Check status
bash bin/telemetry.sh status

# Inspect or export locally
bash bin/telemetry.sh inspect 10
bash bin/telemetry.sh export ~/.egregore/exports/telemetry.jsonl

# Prepare an explicit share proposal (does not send)
bash bin/telemetry.sh share
```

Events buffer on-device at `~/.egregore/telemetry/<instance-hash>/telemetry.jsonl`,
outside the project, canonical memory, and Git. The namespace is derived from
the resolved memory root, so worktrees share the same instance buffer. `flush` remains a compatibility no-op for old
lifecycle callers and never uploads. Sharing is a separate two-step operation:
the CLI discloses the exact target, event count, bytes, dataset hash, and fields,
then requires a fresh short-lived token against the unchanged dataset.

## Consent (opt-out)

Telemetry is on by default. Users can opt out via:
- `/telemetry off` — persistent opt-out in `.egregore-state.json`
- `EGREGORE_NO_TELEMETRY=1` in `.env`
- `DO_NOT_TRACK=1` — standard environment variable

## What is collected

Structured identifiers and scalar metrics: event/task/actor/org/session IDs,
timestamps, command enums, retrieval type, privacy-safe lexical/vector
fingerprints when configured, returned/opened artifact IDs (ordered for rank),
tool-call counts, latency, token counts, writeback/action outcome,
success/failure codes, and index-spec/version. Metric names are allowlisted and
string values must be bounded identifiers/enums rather than prose.

## What is NEVER collected

Raw prompts/queries, passages, file paths, file contents, code, env var values,
secrets, conversation content, prose error messages, or command arguments that
might contain user content.

## Command instrumentation

**After executing any slash command**, emit a `command` event (fire-and-forget, must not delay response):

```bash
bash bin/telemetry.sh emit "command" '{"command":"save"}' 2>/dev/null &
```

Optional extended payload example: `{"command":"save","model":"haiku-4-5","tier":"haiku","routed":true,"escalated":false,"override":false,"duration_ms":1240}`

All extended fields are optional, and `duration_ms` is measured by the emitting
wrapper (executor spawn wall-time or script time). Harness adapters may include
content-free aggregate token counts when they are available.

Replace `"save"` with the actual command name. Do this for every slash command execution.


## Operation observation pilot

The shared search query command and `bin/agent.sh save` transaction emit
`operation.start` and `operation.result` through
`egregore_runtime.operation_cli` and the existing `LocalTelemetrySink`.
Selection and logical skill completion remain unobserved. A successful search
process does not establish answer quality; a successful save process does not
establish that every broader user goal was achieved.

The bounded payload contains `operation` (`search` or `save`), `layer`
(`operation`), a timestamped UUID `invocation_id`, and an allowlisted `harness`
(or `unknown`). Results add `outcome` (`success`, `error`, or `cancelled`),
wall-clock `duration_ms`, and the observed ordinary `exit_status` when present.
It carries no command arguments, query text, error prose, task/artifact IDs,
model costs, or inferred token counts. Identity comes from configured org and
actor IDs plus session state; missing attribution is `unknown`.

Each shell invocation gets a new ID. An evaluator may supply
`EGREGORE_OPERATION_ID=op_<10-digit-unix-seconds>_<32-hex-uuid>` to correlate an
independent invocation ledger. That override is consumed by the operation and
must not be inherited by nested operations. Reusing the ID means replaying the
same observation, including across a process retry; it cannot replace an
initial terminal error with a later success. A new logical invocation requires
a new ID. This pilot does not infer attempt lifecycles from arbitrary shell
commands.

Normal zero exits are success; ordinary nonzero exits are error. Signal-shaped
statuses (`128` and above), interruption, and abrupt process loss leave the
result unknown. Only a caller that directly observes cancellation may invoke
`finish --outcome cancelled`; an absent terminal event is never counted as
cancellation or success. Durations cover the entire operation boundary,
including any human wait, and are not model execution latency.

The private `operation-observations.json` ledger reserves observations before
append. This guarantees at-most-once publication for a reused ID while allowing
an explicit missing-observation gap after storage failure or a crash. Terminal
reservations survive JSONL truncation. Dedup retains at most 2,048 invocations
for seven days; a full ledger declines new observations, and expired IDs are
rejected after cleanup rather than emitted again. Corrupt or contended storage
fails open without changing workflow output or exit status. Shell observation
is skipped when pre-existing exit/signal traps would be overwritten. Collection respects
state, environment, and `.env` opt-out; it never contacts a network sink.

Inspect pilot accounting locally with:

```bash
PYTHONSAFEPATH=1 PYTHONPATH="$PWD${PYTHONPATH:+:$PYTHONPATH}" \
  python3 -m egregore_runtime.operation_cli coverage --root "$PWD"
```

The report separates recorded starts/results, unresolved retained observations,
replays, capacity refusals, and append failures. `telemetry-retention.json`
tracks Python-writer appends and observed evictions, including operation rows,
since its own recorded start time. Python writes enforce both event and byte
caps. Existing shell writers are explicitly untracked: their appends and
truncations can change the buffer independently. These counters do not measure
all skill invocations or all historical losses. Compare pilot rows against an
independent evaluator ledger, report retained/lost/unknown coverage, and never
use a truncated buffer alone as a usage or completion denominator.

Both Python and shell inspection/export accept the new bounded metrics. Share
consent remains separate. Clearing telemetry removes the buffer, pilot ledger,
and retention metadata and starts a new observation window; dedup guarantees
do not span an explicit privacy clear. Default instance namespaces stay
separate. If an explicit storage override points two instances at the same
pilot ledger, the second instance declines to record rather than mixing data.

## Onboarding instrumentation

When completing an onboarding step, emit:

```bash
bash bin/telemetry.sh emit "onboarding_step" '{"step":"workspace_setup","duration_ms":1200}' 2>/dev/null &
```

## First-session telemetry notice

On the first session where telemetry events are emitted, if `telemetry_noticed` is not set in `.egregore-state.json`, mention once:

> Egregore records content-free runtime telemetry locally (structured identifiers and metrics — never prompts, code, or content). Nothing is shared automatically. Run `/telemetry` to inspect it or `/telemetry off` to disable collection.

Then set `telemetry_noticed: true` in the state file. Never repeat this notice.

## Session Reports

Separate from telemetry. Users can optionally share session reports during `/wrap` or via `/issue egregore:`. Reports are **opt-in per session** — the user is asked each time and must explicitly agree.

### How it works

`bin/session-report.sh` handles report submission. It POSTs directly to Supabase via the anon key (no API server needed). The agent generates a structured report from the session context inline — no separate LLM call.

```bash
# Submit a report (reads JSON from stdin)
echo '{"topic":"...","summary":"..."}' | bash bin/session-report.sh submit

# Check reporting status
bash bin/session-report.sh status
```

### What is sent

- AI-analyzed topic + summary (same as what's written to memory)
- Gap analysis: `{type, detail}` where type is `missing_skill`, `missing_tool`, `repeated_failure`, `wrong_info`, or `confusing_ux`
- User's own description (if provided)
- System info: mode, platform, shell, framework version
- Session duration and message count

### What is NEVER sent

- Code, file contents, or file paths
- Conversation transcript or user prompts
- Environment variables or secrets
- Org-specific data (sanitized before sending — org names, person names, tokens replaced)

### Opt-out

- `EGREGORE_NO_REPORTS=1` in `.env`
- `.egregore-state.json` → `"session_reports": false`
- Simply answer "No thanks" when prompted during `/wrap`
- `DO_NOT_TRACK=1` also disables reports

### Transport

- Direct to Supabase via anon key (INSERT-only RLS policy)
- If network fails: saved locally to `~/.egregore/reports/` as fallback
- Telegram notification to maintainers fires server-side via Supabase DB webhook
- Optional: GitHub issue creation on `egregore-labs/egregore` (user chooses each time)

### Configuration

Reports require `report_url` and `report_key` in `egregore.json`. New OSS installations get these automatically via `create-egregore`. If missing, the report prompt is skipped entirely.
