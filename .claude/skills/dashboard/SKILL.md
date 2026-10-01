---
name: dashboard
description: "Explicit personal-status surface for /dashboard or a direct request for the whole personal overview. Do not use it to find or resume one specific prior handoff, project, or work thread; that is semantic organizational recall through Runtime/QMD."
---

# Dashboard

Use this bounded status card only when the user explicitly asks for Dashboard
or the whole personal overview. A request to return to one earlier piece of
work must use attached `EGREGORE_ORG_CONTEXT_V1` evidence or exactly one Search
workflow query when that evidence is absent. Never use Dashboard as discovery
fallback.

Render the personal view immediately. The renderer's stdout IS the product
card: it is fully visible the moment rendering finishes, and it must appear
exactly once in the conversation. Never copy, regenerate, summarize, or
repeat the card — or any of its rows — in your reply; add nothing beyond an
answer to something the user separately asked.

Map the requested range to `P1D`, `P7D`, `P30D`, or `P365D` as `{time-range}`,
then fetch and render exactly one authorized Runtime snapshot:

```bash
bash bin/dashboard-data.sh '{time-range}' 2>/dev/null \
  | bash bin/node-run.sh bin/codex-skill-render.mjs dashboard-card -
```

Do not sync repositories, query memory again, or call implementation
infrastructure directly. The snapshot owns actor resolution,
authorization, bounds, canonical lifecycle state, and presentation data.

Connected enrichment is separate and explicit. Set
`EGREGORE_STATUS_CONNECTED_ENRICH=1` only when the user requests projected
Connected status. It is capability/permission gated and cannot replace
canonical handoffs, questions, quests, todos, sessions, or lifecycle metadata.

Never print raw JSON or narrate routine commands. Preserve the shared
72-column card, omit graph/setup messaging in Local mode, end with `What's
next?`, and act on the reply in the next turn.

## When to invoke

Explicit personal-status surface for /dashboard or a direct request for the whole personal overview. Do not use it to find or resume one specific prior handoff, project, or work thread; that is semantic organizational recall through Runtime/QMD.
