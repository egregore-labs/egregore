---
name: wrap
description: "Close the current Egregore session with a personal, canonical summary. Use for /wrap or when the user says they are done, wrapping up, or at a stopping point. Route work assigned to another person to /handoff and save-without-closing to /save."
---

# Personal session wrap

Record what this actor finished, what was verified, and what remains. A wrap is
personal session closure, not a handoff, notification, publication, or claim
that an organizational obligation is complete.

Canonical Markdown and Git provenance are authoritative. The Egregore Runtime
owns authorization, stable ActorContext resolution, persistence, provenance,
retrieval refresh, background embedding, and content-free telemetry through
one writeback transaction.

## When to invoke

Close the current Egregore session with a personal, canonical summary. Use for /wrap or when the user says they are done, wrapping up, or at a stopping point. Route work assigned to another person to /handoff and save-without-closing to /save.

## Prepare

1. Reuse the current conversation and relevant `EGREGORE_ORG_CONTEXT_V1`
   evidence. Do not search organizational memory again merely to summarize the
   session.
2. Derive a short topic, a two-to-four sentence summary, verified outcomes,
   and concise open threads. Separate completed work from unverified work.
3. If the proposed summary is materially ambiguous, show it once and ask for
   correction. Skip confirmation when the user already supplied exact wrap
   wording.
4. If project changes need delivery, invoke `/save` once before the wrap. That
   is a separate project-delivery action; do not reproduce Git commands in this
   skill and do not run a second save after canonical wrap succeeds.

Use this body shape, omitting empty sections:

```markdown
## Summary

<what changed and the current state>

## Completed

- <completed outcome>

## Verification

- <test or check and its result>

## Open Threads

- [ ] <unfinished item or next step>
```

## Write once

Write this body to the file `tmp/wrap-body.md`, then pass it to
the Runtime-neutral wrap adapter in one command:

```markdown
<body markdown>
```

Use `{topic}` for the short topic and `{summary}` for the two-to-four sentence summary
derived from the session during preparation:

```bash
bash bin/agent.sh wrap \
  --topic '{topic}' \
  --summary '{summary}' --body-file tmp/wrap-body.md
```

Do not call `artifact-writeback.sh`, `capture-run.sh`, Git, QMD, graph,
telemetry, publication, or notification mechanics directly. The adapter enters
one personal canonical writeback transaction:

`authorize → persist Markdown → Git provenance → retrieval update → background embed → telemetry`

On success, report the returned `memory/wraps/...` path and the project save
status. If the adapter fails, show the concise error and stop; never fall back
to writing the file or updating projections directly.

## Lifecycle boundary

- A personal wrap never creates a recipient obligation; use `/handoff` for
  work another person must receive or continue.
- A wrap never silently completes, expires, or supersedes a handoff, quest,
  todo, or thread. Age is not completion evidence.
- The canonical wrap receipt may support a later, explicitly authorized
  lifecycle transition. That lifecycle service must verify the target,
  expected revision, actor membership, and typed evidence separately.
- Keep open threads in the wrap even when they are also promoted through their
  own quest/todo/thread Runtime action.

## Output

The adapter renders the wrap result card — actor, topic, summary,
open-thread count, canonical path, and save/writeback status — as its
stdout. The card is already fully visible there and must appear exactly once
in the conversation. Never copy, re-render, summarize, or repeat it in your
reply; add nothing beyond an answer to something the user separately asked.
Do not claim `graphed`, `published`, `notified`, or `shared` unless a
separate explicit action actually occurred.
