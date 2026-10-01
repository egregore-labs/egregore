# Meeting analysis contract

Use only the lenses that serve the user's stated intent and the material.

## Lenses

- Substance: decisions, findings, patterns, actions, dependencies, evidence,
  tradeoffs, confidence, and open questions.
- Dynamics: tone arc, conviction, alignment, divergence, and energy shifts.
- Continuity: what changed, repeated, resolved, superseded, or disappeared.
- Criticality: unnamed risks and gaps between stated confidence, behavior, and
  organizational reality.

Do not manufacture depth for a short operational meeting. Inline analysis is
the fast default. Use parallel analysts only for long or genuinely complex
material and only when the harness supports them.

## Briefing

Write `# Meeting Intelligence: {title}` followed by source/date/attendees,
analysis approach, and user intent. Include only useful sections:

1. Meta-analysis: heart of the conversation; genuinely new information;
   actuality against current canonical context; concrete considerations.
2. Tone and energy, dynamics, or convictions when those lenses were applied.
3. Priorities and dependencies.
4. Decision evolution and cross-meeting patterns when canonical evidence
   supports them.
5. Analytical tensions where lenses or evidence disagree.
6. Actions as a separate list, not durable knowledge artifacts.
7. Extracted artifacts and unresolved threads.

Write as a trusted colleague briefing someone who missed the meeting. Lead
with the gravitational center, prioritize ruthlessly, and name who should do
what. An execution meeting with no new ground may say exactly that.

## Extracted knowledge

Persist only `decision`, `finding`, or `pattern` documents. For each preserve:

- title and substantive content;
- context, rationale, and tradeoffs where present;
- confidence calibrated to evidence;
- speaker and an evidence excerpt no longer than 120 characters;
- topics, open questions, urgency, importance, and conviction;
- explicit evolution/supersession and related-artifact links.

Strong agreement or data-backed evidence is about 0.9; a single speaker about
0.7; exploration about 0.5; contentious evidence about 0.6. Do not preserve
small talk, logistics, trivia, or claims absent from the source.

## Proposal

Before writeback, show a compact preview containing the analysis approach,
intent, heart of the conversation, each proposed artifact with confidence and
evidence, tensions, actions, and relationships. Ask `Save`, `Edit`, or `Skip`.
Only `Save` authorizes canonical writeback; it does not authorize publication
or notification.

## Runtime package

Create one temporary JSON package:

```json
{
  "schema_version": "egregore-research-ingest/v1",
  "kind": "meeting",
  "source": {
    "type": "granola",
    "id": "granola-document-id",
    "revision": "source revision or content hash",
    "content_hash": "required SHA-256 of the acquired source",
    "uri": "optional source URI"
  },
  "documents": [
    {
      "artifact_type": "meeting",
      "title": "Weekly Sync",
      "canonical_path": "meetings/2026-08-27-weekly-sync.md",
      "body_path": "/temporary/egregore-meeting-briefing.md",
      "status": "active",
      "metadata": {"attendees": ["alice", "bob"], "intent": "full analysis"}
    },
    {
      "artifact_type": "decision",
      "title": "Use typed hybrid retrieval",
      "canonical_path": "knowledge/decisions/2026-08-27-typed-hybrid.md",
      "body_path": "/temporary/egregore-meeting-decision.md",
      "relationships": [
        {"relation": "from_meeting", "target_id": "artifact id of briefing"}
      ],
      "supersedes": []
    }
  ]
}
```

Body paths point to temporary analysis output, never directly to canonical
memory. The package may contain at most 40 Markdown documents. Runtime
authorizes all artifact identities before reading document bodies, validates paths/schema,
writes the package in one Git provenance commit, updates the derived index once,
starts one changed-hash embedding job, and emits content-free telemetry.
