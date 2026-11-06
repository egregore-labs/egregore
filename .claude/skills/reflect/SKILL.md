---
name: reflect
description: "Use when the user says 'we decided', 'I realized', or 'that's a pattern' — captures a share-ready decision, finding, or pattern in canonical organizational memory. Use /note for private or half-baked thoughts and /archive for reusable AI-steering techniques."
---

# Reflect

Turn a settled insight into one to three typed, share-ready knowledge artifacts.

## When to invoke

Use when the user says 'we decided', 'I realized', or 'that's a pattern' — captures a share-ready decision, finding, or pattern in canonical organizational memory. Use /note for private or half-baked thoughts and /archive for reusable AI-steering techniques.

## Modes

- No arguments: use a short Socratic flow grounded in this session.
- `about <topic>`: focus the flow on that topic.
- `[decision|finding|pattern]: <content>`: honor the explicit type.
- Other arguments: quick capture; infer the type, defaulting to `finding`.

## Context

Reuse attached `EGREGORE_ORG_CONTEXT_V1` evidence. When it is sufficient, do
not reopen sources. If a named gap remains, make one
`bash bin/search.sh find "<concept>" --kind hybrid -n 6` call and open only the
missing canonical source through `bash bin/search.sh open`. Never query
implementation infrastructure or storage directly.

## Two layers

Knowledge is saved as a **pattern** (a general motif) and **evidence** (the
specific, dated, sourced case, a `finding` with subtype `evidence`) linked by
`instance-of`. Before classifying, search existing motifs once:
`bash bin/search.sh find "<motif in general words>" --kind hybrid --prefix memory/knowledge/patterns -n 5`.

- A pattern fits: create only the evidence, linked to that pattern's id (or
  canonical path). `bash bin/knowledge.sh instances <pattern-id>` lists what
  already instances it.
- No pattern fits and the insight recurs or generalizes: create the pattern
  first, then the evidence linked to the `artifact_id` in its receipt.
- A one-off fact or a decision needs no pattern.

A pattern reads as a general motif: no organization or people names and no
dates in the motif sentence; the evidence keeps the specifics. Pattern body
sections: Motif, Where it lives, When it shows up, How to recognise it, The
move, When it doesn't apply, Situations (for discovery). Name the first case in
one line under Instances; the live list is the `instances` command. Situations
go in as repeatable flags: `--situation-domain` (a field such as meta-harness
design), `--situation-path` (repository-relative glob), `--situation-activity`
(what someone is doing). A matching later session gets one offer line,
`Patterns that may apply: …`; `knowledge.sh situated` runs it on demand.

Relationships: `instance-of` (evidence → pattern), `responds-to` (decision →
the evidence it answers), `applies` (decision → the pattern it acts on),
`supersedes`, `relates-to`. Other relations are kept with a warning.

## Flow

1. Extract the title, exact insight, context, rationale, two to four topics,
   workstream, explicit relationships, and superseded artifact IDs when known.
2. Classify each distinct insight as `decision`, `finding`, or `pattern` and
   place it in the two layers above. Create at most three artifacts. Do not
   infer supersession or authority from recency.
3. Use returned evidence for dedupe. If a likely duplicate exists, open it
   through the Runtime boundary and ask whether to supersede it or create a
   distinct artifact.
4. Preview every proposed artifact, the pattern and its evidence together, and
   wait for `y`, edits, or `skip`. Nothing is canonical before this acceptance.
5. For each accepted artifact, render its complete Markdown body to a temporary
   file under `tmp/` and call exactly one domain command; `{artifact-file}` is
   that file and the other values come from the accepted artifact:

```bash
bash bin/knowledge.sh create \
  --type '{artifact-type}' \
  --title '{title}' \
  --input '{artifact-file}' \
  --topic '{topic}' \
  --workstream '{workstream}'
```

Add repeated `--topic`, `--subtype evidence`, `--relationship "RELATION:TARGET"`,
`--situation-*`, or `--supersedes "ARTIFACT_ID"` arguments only when they apply.
The Runtime resolves ActorContext, authorizes, assigns stable
identity/provenance, persists canonical Markdown, records Git provenance,
refreshes retrieval, starts background embedding, and emits content-free
telemetry. Report receipt `warnings` and `partial` projection honestly; the
canonical artifact remains authoritative.

## Boundaries

- Reflection is share-ready organizational knowledge, not a private note.
- Do not run `/save`, Git, index, embedding, graph, telemetry, publish, share,
  or notification mechanics separately.
- A graph is an optional downstream projection and cannot override Markdown.
- Publishing, external sharing, and notification each require their own action
  permission and explicit consent; reflection never implies them.

Report the artifact type, title, canonical path, and writeback status. Keep the
existing compact `◎ REFLECTION` confirmation style when rendering rich output.
