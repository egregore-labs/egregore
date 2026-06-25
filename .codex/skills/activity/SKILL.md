---
name: activity
description: Show Egregore team activity, pending handoffs, and open questions when the user invokes /activity or $activity, or asks what is happening in an Egregore checkout.
---

# Egregore Activity

Native Codex Egregore skill. Use this only inside an Egregore checkout.

Show the live team activity view without sending the user through Claude Code.
The graph API is useful when reachable, but the filesystem and memory repo must
remain enough to render a useful answer.

## Flow

1. Verify `bin/agent.sh` exists. If it does not, say this is not an Egregore
   checkout.
2. Run `bin/agent.sh sync`.
3. Resolve the requested handle:
   - If the user named a person, match it against `memory/people/*.md`.
   - Otherwise use `.egregore-state.json` `github_username`, then git user
     fallback.
4. Run `bash bin/activity-data.sh [handle]` with network escalation and capture
   stdout as JSON. This command performs the graph API call internally; a
   normal sandboxed Codex shell can make a healthy graph look unreachable.
5. Classify the graph status:

```bash
node bin/codex-skill-render.mjs classify-graph --mode connected
```

If the network-enabled command still returns `retry` because `graph_reason` is
`unreachable`, render the filesystem fallback and mention that the graph service
was unreachable after a network-enabled attempt. If network escalation is denied
or unavailable, run the command without escalation, render the fallback, and
say Codex graph network access was not granted; do not claim the graph itself
was unreachable. Do not retry for `missing_config`, `auth_error`, or
`server_error`; render the clear reason instead.

6. Render the card with:

```bash
node bin/codex-skill-render.mjs activity-card <json-file>
```

Paste the rendered card exactly in the visible response, preferably in a
`text` fenced block. Do not paraphrase the card into bullets unless the user
asks for a summary.

7. Offer one compact focus prompt:
   - `Handoffs` - open pending handoffs.
   - `Questions` - answer or inspect pending questions.
   - `Recent work` - inspect sessions and wraps.
   - `Dashboard` - switch to the personal dashboard.
   - `Done` - stop.

Use structured Codex question tooling when it is available. Otherwise render a
numbered list plus `Other:` and wait for the user.

## Rules

- Never show raw JSON.
- Do not narrate each command step unless something blocks the workflow; the
  final visible response should lead with the rendered card.
- Structured UX parity is required: preserve the rendered activity TUI card,
  no preamble, no prose-only replacement, and no raw collector output.
- Do not call `egregore-handoff`.
- Do not use Claude Code commands.
- Keep graph, pull request, and publish data best-effort; local memory remains
  the source of truth when connected services are down.
