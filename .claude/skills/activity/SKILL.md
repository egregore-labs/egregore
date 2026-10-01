---
name: activity
description: "Explicit Activity card only. Use when the user names /activity or directly asks to show, open, or render the Activity dashboard/card. Never use it to answer or synthesize what the team is focused on, busy with, prioritizing, or doing; analytical organizational questions use Search/Runtime QMD."
---

# Activity

Use this bounded status card only when the user names Activity or directly asks
to display its dashboard/card. "Explicit" means display intent, not merely a
question about the team. Questions asking for explanation or synthesis of
current focus, themes, priorities, or work use attached
`EGREGORE_ORG_CONTEXT_V1` evidence or exactly one Search workflow query when
that evidence is absent. The same applies to returning to earlier work. Never
use Activity as discovery or analysis fallback.

Render the team view immediately. The renderer's stdout IS the product card:
fully visible the moment rendering finishes, appearing exactly once in the
conversation. Never copy, regenerate, summarize, or repeat the
card — or any of its rows — in your reply. The card's own closing question is
the prompt for the next turn; after the command, add nothing beyond an
answer to something the user separately asked.

## When to invoke

Explicit Activity card only. Use when the user names /activity or directly asks to show, open, or render the Activity dashboard/card. Never use it to answer or synthesize what the team is focused on, busy with, prioritizing, or doing; analytical organizational questions use Search/Runtime QMD.

## Read path

Fetch exactly one authorized Runtime snapshot and render it:

```bash
bash bin/activity-data.sh 2>/dev/null \
  | bash bin/node-run.sh bin/codex-skill-render.mjs activity-card -
```

Do not sync repositories, query memory again, or call implementation
infrastructure directly. The snapshot already contains bounded
canonical sessions, questions, quests, todos, and lifecycle-resolved handoffs.
Canonical Markdown/Git wins over every projection.

Connected enrichment is a separate capability-authorized adapter. Use it only
when the user explicitly asks for Connected/projected status by setting
`EGREGORE_STATUS_CONNECTED_ENRICH=1` for the same single data command. Never
replace canonical lifecycle fields with the returned projection payload.

## Handoff actions

For `activity done N`, `activity expire N`, or `activity reopen N`:

1. Fetch one snapshot as above.
2. Map `N` to `handoffs_to_me[N-1]`.
3. Run one typed transition:

```bash
bash bin/activity-action.sh <done|expire|reopen> "<sessionId>" \
  --expected-revision "<lifecycleRevision>"
```

Report the resulting canonical state. Never accept graph state as lifecycle
authority, silently complete work by age, or record focus through graph calls.

## Rendering rules

- Never print raw JSON or narrate routine commands.
- Preserve the shared 72-column activity card.
- Show Local status without graph/setup messaging.
- End the turn after the card; act on the user's reply next turn.
- Use `/activity quests` to show the snapshot's full bounded quest list.
