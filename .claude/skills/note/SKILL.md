---
name: note
description: "Use when the user says 'jot this down', 'note to self', 'just thinking out loud', or 'park this thought' — saves an actor-owned private draft locally and promotes it to organizational knowledge only on an explicit request."
---

# Note

Capture a half-baked thought for the active actor. Private notes are local draft
state, not canonical organizational truth, and are never committed, indexed,
published, shared, or notified automatically.

## When to invoke

Use when the user says 'jot this down', 'note to self', 'just thinking out loud', or 'park this thought' — saves an actor-owned private draft locally and promotes it to organizational knowledge only on an explicit request.

## Commands

- No arguments: ask what to capture.
- Content: infer a short title and one of `thought`, `session`,
  `retrospective`, or `journal`; write the user's meaning without polishing it
  into a decision.
- `list`: call `bash bin/knowledge.sh note-list` and format the returned notes.
- `share <title>` or `promote <title>`: select the actor's note, preview it,
  choose `decision`, `finding`, or `pattern`, and explicitly confirm promotion.

## Capture

Render only the note body to a temporary file under `tmp/`, then call with `{note-file}`
for that file, `{title}` for the title inferred from the user's words, and `{note-type}`
for the inferred `thought`, `session`, `retrospective`, or `journal` type:

```bash
bash bin/knowledge.sh note-create \
  --title '{title}' \
  --type '{note-type}' \
  --input '{note-file}'
```

The Runtime adapter resolves ActorContext and authorizes the actor before local
private persistence. The resulting envelope carries stable actor identity and
a private policy hint. The hint describes posture; authorization remains the
Runtime policy decision.

## Promotion

Open the selected note through `bash bin/knowledge.sh note-open "{path}"`.
After the user explicitly approves organizational promotion, call:

```bash
bash bin/knowledge.sh note-promote \
  --path "{path}" \
  --type "{decision|finding|pattern}" \
  --title "{title}" \
  --topic "{topic}" \
  --workstream "{workstream}"
```

Promotion uses CanonicalArtifactWriteback: authorize, assign stable typed
identity and source provenance, persist Markdown, record Git provenance, update
retrieval, start background embedding, then emit content-free telemetry. The
private copy remains and records the canonical target.

## Boundaries

- Do not access another actor's note or treat policy hints as authorization.
- Do not call Git, QMD, graph, telemetry, publishing, sharing, notification, or
  control-plane mechanics directly.
- `share` means promotion into authorized organizational Markdown, not external
  publication. External sharing and notification require separate permission
  and exact consent.

Confirm private capture with its local path. Confirm promotion with the new
canonical path and writeback status.
