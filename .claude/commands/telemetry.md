Manage telemetry settings. Shows status by default.

## Arguments

- `status` (default) — show whether telemetry is enabled, buffer size, opt-out method
- `off` or `disable` — disable telemetry (sets `telemetry: false` in state file)
- `on` or `enable` — re-enable telemetry
- `show [N]` — show last N buffered events (default 10)
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

### show [N]

```bash
bash bin/telemetry.sh show ${N:-10}
```

Show the output. If empty, say **"No buffered events."**

### clear

```bash
bash bin/telemetry.sh clear
```

Confirm: **"Local telemetry buffer cleared."**

## What is collected

Only: command names, timestamps, session durations, error codes, branch names, query latencies.

## What is NEVER collected

File paths, file contents, code, env var values, conversation content, command arguments that might contain user content.

## Opt-out methods

1. `/telemetry off` — persistent opt-out via state file
2. `EGREGORE_NO_TELEMETRY=1` in `.env` — env var opt-out
3. `DO_NOT_TRACK=1` — standard env var opt-out
