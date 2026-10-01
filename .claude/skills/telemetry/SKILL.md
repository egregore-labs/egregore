---
name: telemetry
description: "Manage local-first telemetry — status, inspect, export, opt in/out, clear, or explicitly share a disclosed dataset. Use for /telemetry, 'turn off telemetry', or 'what data do you collect'."
---

Manage telemetry settings. Shows status by default.

## When to invoke

User says: "/telemetry", "telemetry status", "turn off telemetry", "disable telemetry", "what data do you collect", "inspect/export/share my telemetry events", "clear telemetry buffer"
Not this: viewing telemetry across all registered orgs (internal, admin only) → `/telemetry-admin`

## Arguments

- `status` (default) — show whether telemetry is enabled, buffer size, opt-out method
- `off` or `disable` — disable telemetry (sets `telemetry: false` in state file)
- `on` or `enable` — re-enable telemetry
- `inspect [N]` or legacy `show [N]` — show last N buffered events (default 10)
- `export <path>` — validate and copy the local JSONL dataset; never uploads
- `share` — disclose the exact local dataset and prepare a short-lived confirmation token
- `share --confirm <token>` — send only the unchanged, previously disclosed dataset to the same target
- `clear` — delete local telemetry buffer

## What to do

Parse the argument (default to `status` if none given).

### status (default)

```bash
bash bin/telemetry.sh status
```

Show the output to the user.

### off / disable

```bash
bash bin/telemetry.sh disable
```

Confirm: **"Telemetry disabled. No events will be collected until you run `/telemetry on`."**

### on / enable

```bash
bash bin/telemetry.sh enable
```

Confirm: **"Telemetry re-enabled."**

### inspect [N]

Use `{count}` for the number after `inspect` or `show` in the command's arguments, or `10` when omitted, escaping embedded single quotes as `'\''`:

```bash
bash bin/telemetry.sh inspect '{count}'
```

Show the output. If empty, say **"No buffered events."**

### export <path>

```bash
bash bin/telemetry.sh export "<path>"
```

Report the resulting local path. Export validates the same content-free event
envelope used by sharing. It does not grant permission to upload the file.

### share

First prepare the proposal. This performs no network I/O:

```bash
bash bin/telemetry.sh share
```

Show the complete output: target, event count, bytes, dataset hash, field list,
exclusions, expiry, and exact confirmation command. Then stop. Do not infer
confirmation from the request to share, a prior share, notification consent, or
any unattended workflow.

Only after the user freshly confirms this exact proposal, run the printed
command containing its one-time token. A changed target, changed buffer,
expired token, or bad token requires a new proposal. Local events remain after
a successful share.

Local instances have no default outbound sink. They may export, name an
explicit endpoint, or explicitly opt into the legacy public relay with
`--legacy-public-relay`; never select that relay automatically.

### clear

```bash
bash bin/telemetry.sh clear
```

Confirm: **"Local telemetry buffer cleared."**

## What is collected

Structured identifiers and metrics: event/task/actor/org/session identifiers,
timestamps, retrieval type, privacy-safe lexical/vector fingerprints when
configured, returned/opened artifact identifiers, ranks/order, tool-call count,
latency, token counts, writeback outcome, success/failure, and index-spec
version. Metric strings are bounded identifiers/enums, not prose.

## What is NEVER collected

Raw prompts/queries, passages, file paths, file contents, code, env var values,
secrets, conversation content, prose error messages, or command arguments that
might contain user content.

## Opt-out methods

1. `/telemetry off` — persistent opt-out via state file
2. `EGREGORE_NO_TELEMETRY=1` in `.env` — env var opt-out
3. `DO_NOT_TRACK=1` — standard env var opt-out
