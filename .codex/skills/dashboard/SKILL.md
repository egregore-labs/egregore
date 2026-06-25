---
name: dashboard
description: Show the current user's Egregore dashboard, recent sessions, open threads, and current work from Codex when the user invokes /dashboard or $dashboard, or asks for their dashboard.
---

# Egregore Dashboard

Native Codex Egregore skill. Render the personal dashboard immediately from
`bin/dashboard-data.sh` and the shared renderer.

## Flow

1. Map user range words to ISO-ish ranges:
   - empty or `week` -> `P7D`
   - `today` -> `P1D`
   - `month` -> `P30D`
   - `all` -> `P365D`
2. Run `bash bin/dashboard-data.sh "" "$TIME_RANGE"` with network escalation
   and capture stdout as JSON. This command performs the graph API call
   internally; a normal sandboxed Codex shell can make a healthy graph look
   unreachable.
3. Classify graph status:

```bash
node bin/codex-skill-render.mjs classify-graph --mode connected
```

If the network-enabled command still returns `retry` because the reason is
`unreachable`, render the filesystem fallback and mention that the graph service
was unreachable after a network-enabled attempt. If network escalation is denied
or unavailable, run the command without escalation, render the fallback, and
say Codex graph network access was not granted; do not claim the graph itself
was unreachable.

4. Render:

```bash
node bin/codex-skill-render.mjs dashboard-card <json-file>
```

Paste the rendered card exactly in the visible response, preferably in a
`text` fenced block. Do not paraphrase the card into bullets unless the user
asks for a summary.

5. End with a compact next-action prompt. Use structured Codex question
   tooling when available; otherwise render numbered choices plus `Other:`.

## Rules

- Never show raw JSON.
- Do not narrate each command step unless something blocks the workflow; the
  final visible response should lead with the rendered card.
- Structured UX parity is required: preserve the rendered dashboard TUI card,
  no preamble, no prose-only replacement, and no raw collector output.
- Do not call `bin/graph.sh` directly; `bin/dashboard-data.sh` is the data
  boundary.
- In local mode, do not mention graph setup; memory files are the source of
  truth.
- Do not use Claude Code commands.
