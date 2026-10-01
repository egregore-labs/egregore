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
not search or reopen sources. If a named gap remains, make one
`bash bin/search.sh query "<concept>" -n 6` call and open only the missing
canonical source through `bash bin/search.sh open`. Never query implementation
infrastructure or storage directly.

## Flow

1. Extract the title, exact insight, context, rationale, two to four topics,
   workstream, explicit relationships, and superseded artifact IDs when known.
2. Classify each distinct insight as `decision`, `finding`, or `pattern`.
   Create at most three. Do not infer supersession or authority from recency.
3. Use already-returned evidence for dedupe. If a likely duplicate exists,
   open it through the Runtime boundary and ask whether to supersede it or
   create a distinct artifact.
4. Preview the proposed artifacts and wait for `y`, edits, or `skip`. Nothing
   is canonical before this acceptance.
5. For each accepted artifact, render its complete Markdown body to a temporary file
   under `tmp/` and call exactly one domain command; `{artifact-file}` is that file, and
   `{artifact-type}`, `{title}`, `{topic}`, and `{workstream}` are the accepted
   artifact's type, title, topic, and workstream:

```bash
bash bin/knowledge.sh create \
  --type '{artifact-type}' \
  --title '{title}' \
  --input '{artifact-file}' \
  --topic '{topic}' \
  --workstream '{workstream}'
```

Add repeated `--topic`, `--relationship "RELATION:TARGET"`, or
`--supersedes "ARTIFACT_ID"` arguments only when explicit. The Runtime resolves
ActorContext, authorizes, assigns stable identity/provenance, persists canonical
Markdown, records Git provenance, refreshes retrieval, starts background
embedding, and emits content-free telemetry. Treat `partial` projection
warnings honestly; the canonical artifact remains authoritative.

## Boundaries

- Reflection is share-ready organizational knowledge, not a private note.
- Do not run `/save`, Git, index, embedding, graph, telemetry, publish, share,
  or notification mechanics separately.
- A graph is an optional downstream projection and cannot override Markdown.
- Publishing, external sharing, and notification each require their own action
  permission and explicit consent; reflection never implies them.

Report the artifact type, title, canonical path, and writeback status. Keep the
existing compact `◎ REFLECTION` confirmation style when rendering rich output.
