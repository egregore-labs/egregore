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

Command names, timestamps, session durations, error codes, branch names, query latencies.

## What is NEVER collected

File paths, file contents, code, env var values, conversation content, command arguments that might contain user content.

## Command instrumentation

**After executing any slash command**, emit a `command` event (fire-and-forget, must not delay response):

```bash
bash bin/telemetry.sh emit "command" '{"command":"save"}' 2>/dev/null &
```

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
