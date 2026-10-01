---
name: archive
description: "Capture an effective prompting or steering technique as a reusable canonical pattern. Use when a prompt chain worked especially well; use /reflect for insight about the work and /note for a private thought."
---

# Archive

Capture a reusable human-to-agent steering technique as a typed `pattern` with
subtype `prompt-chain`.

## When to invoke

Capture an effective prompting or steering technique as a reusable canonical pattern. Use when a prompt chain worked especially well; use /reflect for insight about the work and /note for a private thought.

## Modes

- No arguments: inspect this session for a meaningful steering chain. If the
  session is too short or no chain exists, ask the user to describe one.
- Arguments: treat them as the technique; a single principle is a one-move
  chain.

Each move records its type, trigger, intervention, effect, and distilled
principle. Useful initial move types include inversion, calibration, scoping,
elevation, reframing, grounding, sequencing, contradiction, analogy, and
provocation; extend the vocabulary when needed.

## Context and dedupe

Reuse attached `EGREGORE_ORG_CONTEXT_V1` evidence. Do not repeat retrieval when
it already contains sufficient related patterns. If a named gap remains, make
one `bash bin/search.sh query "<technique concept>" -n 6` call and open only a
likely duplicate through `bash bin/search.sh open`. Never query implementation
infrastructure or storage directly.

## Flow

1. Extract a chain name, when-to-use guidance, ordered moves, outcome, topics,
   workstream, and explicit relations.
2. For a three-or-more move chain, show the complete breakdown. For shorter
   chains, show the compact proposal. Wait for `y`, edits, or `skip`.
3. Render the accepted pattern body to a temporary file under `tmp/` and invoke exactly
   one canonical command; `{artifact-file}` is that file, and `{chain-name}`, `{topic}`,
   and `{workstream}` come from the accepted chain proposal:

```bash
bash bin/knowledge.sh create \
  --type pattern \
  --subtype prompt-chain \
  --title '{chain-name}' \
  --input '{artifact-file}' \
  --topic prompt-chain \
  --topic '{topic}' \
  --workstream '{workstream}'
```

Add `--relationship "RELATION:TARGET"` only for explicit links. The Runtime
resolves ActorContext, authorizes, assigns stable identity/provenance, persists
canonical Markdown, records Git provenance, refreshes retrieval, starts
background embedding, and emits content-free telemetry.

## Boundaries

- Archive captures an AI-steering technique, not a work decision or private
  scratch thought.
- Do not separately run `/save`, Git, QMD, graph, telemetry, publishing,
  sharing, or notifications.
- Graph projection is optional and advisory. Canonical Markdown wins.
- Publishing, external sharing, or notification requires a separate permitted,
  explicitly consented action.

Report the canonical path and writeback status. Preserve the compact
`◇ ARCHIVE` confirmation style for rich output.
