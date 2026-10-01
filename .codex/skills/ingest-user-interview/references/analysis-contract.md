# User-interview analysis contract

Start with evidence-bearing moments: friction, aha, feature gap, mental-model
mismatch, feature discovery, suggestion, and unresolved reference. Analyze
short interviews inline. For long or complex material, Journey, Sentiment, and
Product lenses may run in parallel once, then synthesize their disagreements.

## Briefing and insight mapping

Write `# Interview Analysis: {participant} — {type} Interview` with date,
participant, researcher, source, emotional arc, and engagement. Include the
opinionated product reading, journey/critical path, friction and aha moments,
discovery and mental-model mismatches, unmet needs, analytical tensions,
evidence-backed insights, actions, and a concise participant journey note.

Do not generalize one participant to all users. Every durable insight needs an
excerpt of at most 120 characters:

- friction, aha, feature gap, discovery, suggestion → `finding`;
- mental model or cross-participant recurrence → `pattern`;
- explicit accepted product choice → `decision`.

Keep researcher commitments as actions. Show the evidence-bound preview and
ask `Save / Edit / Skip`; Save never authorizes publication or notification.

## Runtime package

Create one temporary `egregore-research-ingest/v1` JSON package with:

- `kind: interview`;
- `source.type` (`granola`, `file`, or `paste`), stable `source.id`,
  `source.revision`, and required source `content_hash`;
- 1–40 documents with `artifact_type`, title, allowed canonical Markdown path,
  temporary `body_path`, status/metadata, relationships, and supersedes.

The briefing belongs under `research/interviews/`; optional participant
journey material belongs under `research/participants/`; durable knowledge
belongs under `knowledge/findings/`, `knowledge/patterns/`, or
`knowledge/decisions/`. Runtime authorizes every artifact and path before
reading bodies, validates the whole package, writes one Git provenance commit,
updates retrieval once, starts one changed-hash embedding job, and emits
content-free telemetry.
