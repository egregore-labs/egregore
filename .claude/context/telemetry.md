# Telemetry Spec

Product telemetry helps us understand usage patterns and improve Egregore. It is privacy-respecting, opt-out, and transparent.

## How it works

`bin/telemetry.sh` handles all telemetry — mirrors `bin/graph.sh` and `bin/notify.sh` patterns:

```bash
# Emit an event (O(1) local append, no network)
bash bin/telemetry.sh emit "command" '{"command":"save"}'

# Check status
bash bin/telemetry.sh status

# Flush buffer to API (happens automatically at session end)
bash bin/telemetry.sh flush
```

Events buffer locally to `~/.egregore/telemetry.jsonl`. Flush happens at session end via `transcript-archive.sh`. Zero user-facing latency.

## Consent (opt-out)

Telemetry is on by default. Users can opt out via:
- `/telemetry off` — persistent opt-out in `.egregore-state.json`
- `EGREGORE_NO_TELEMETRY=1` in `.env`
- `DO_NOT_TRACK=1` — standard environment variable

## What is collected

Command names, timestamps, session durations, per-command durations, model names/tiers, routing flags (routed/escalated/override), error codes, branch names, query latencies, and content-free per-command outcome counters/enums (e.g. deep-reflect wave counts, docs-read counts, stop reasons).

## What is NEVER collected

File paths, file contents, code, env var values, conversation content, command arguments that might contain user content.

## Command instrumentation

**After executing any slash command**, emit a `command` event (fire-and-forget, must not delay response):

```bash
bash bin/telemetry.sh emit "command" '{"command":"save"}' 2>/dev/null &
```

Optional extended payload example: `{"command":"save","model":"haiku-4-5","tier":"haiku","routed":true,"escalated":false,"override":false,"duration_ms":1240}`

All extended fields are optional, and `duration_ms` is measured by the emitting wrapper (executor spawn wall-time or script time). Per-command token counts are deferred to Claude Code's OTEL metrics (a loom-optimizer data source), not per-emit fields.

Replace `"save"` with the actual command name. Do this for every slash command execution.

## Onboarding instrumentation

When completing an onboarding step, emit:

```bash
bash bin/telemetry.sh emit "onboarding_step" '{"step":"workspace_setup","duration_ms":1200}' 2>/dev/null &
```

## First-session telemetry notice

On the first session where telemetry events are emitted, if `telemetry_noticed` is not set in `.egregore-state.json`, mention once:

> Egregore collects anonymous usage telemetry (command names, session durations, error codes — never code or content). Run `/telemetry` to see details or `/telemetry off` to disable.

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
