# Meeting analysis contract

Use only the lenses that serve the user's intent and the material:

- Substance: decisions, findings, patterns, actions, dependencies, evidence,
  tradeoffs, confidence, and open questions.
- Dynamics: tone arc, conviction, alignment, divergence, and energy shifts.
- Continuity: what changed, repeated, resolved, superseded, or disappeared.
- Criticality: unnamed risks and gaps between stated confidence, behavior, and
  organizational reality.

Inline analysis is the fast default. Parallel analysts are justified only for
long or genuinely complex material.

## Briefing and extracted knowledge

Write `# Meeting Intelligence: {title}` with source/date/attendees, approach,
and user intent. Include only useful analysis: the heart and genuinely new
information; actuality against current canonical context; dynamics and
convictions when applied; priorities/dependencies; evolution and tensions;
actions; and unresolved threads.

Persist only durable `decision`, `finding`, or `pattern` documents. Preserve
context, rationale, tradeoffs, calibrated confidence, speaker, an evidence
excerpt of at most 120 characters, topics, open questions, urgency, and
explicit supersession/relationships. Actions stay separate. Never preserve
small talk, logistics, or unsupported claims.

Show a compact evidence-bound preview and ask `Save / Edit / Skip`. Save is
canonical writeback consent only, never publication or notification consent.

## Runtime package

Create one temporary `egregore-research-ingest/v1` JSON package with:

- `kind: meeting`;
- `source.type`, stable `source.id`, `source.revision`, required source
  `content_hash`, and optional `source.uri`;
- 1–40 documents with `artifact_type`, title, allowed canonical Markdown path,
  temporary `body_path`, status/metadata, relationships, and supersedes.

The meeting briefing belongs under `meetings/`; durable extracted knowledge
belongs under `knowledge/decisions/`, `knowledge/findings/`, or
`knowledge/patterns/`. Body paths are temporary analysis outputs, never direct
canonical writes. Runtime authorizes every artifact and path before reading
bodies, validates the complete package, writes one Git provenance commit,
updates retrieval once, starts one changed-hash embedding job, and emits
content-free telemetry.
