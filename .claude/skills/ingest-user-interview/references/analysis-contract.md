# User-interview analysis contract

## Analysis topology

Start with a compact scaffold of evidence-bearing moments:

- friction;
- aha;
- feature gap;
- mental-model mismatch;
- feature discovery;
- suggestion;
- unresolved reference.

For short interviews, analyze inline. For long or complex interviews, three
parallel lenses may help:

1. Journey: tasks, stages, critical path, friction, aha moments, stuck points,
   completion, abandonment, and drop-off risk.
2. Sentiment: emotional arc, engagement, confusion, delight, frustration,
   hesitation, confidence, energy, and what went unsaid. Read this lens fresh,
   without letting the scaffold predetermine it.
3. Product: feature discovery, mental models, unmet needs, workarounds,
   comparisons, suggestions, feasibility, priority, and relevant quests.

Synthesize rather than concatenate. Treat disagreements between lenses as
signal: completion plus frustration, abandonment plus curiosity, discovery
plus a missed step, delight plus mental-model mismatch, or blocker severity
plus only mild emotion.

## Briefing

Write `# Interview Analysis: {participant} — {type} Interview` with date,
participant, researcher, source, emotional arc, and engagement. Include:

- opinionated meta-analysis: heart, journey reality versus intended design,
  emotional read, and specific product implications;
- journey map, critical path, and drop-off risks;
- friction and aha moments;
- feature discovery and mental-model mismatches;
- unmet needs and suggestions;
- internal analytical tensions;
- extracted insights with confidence/priority/quest links;
- open questions and a concise participant journey note.

Do not generalize one participant into all users. Prefer “this participant
experienced X.” Every durable insight needs source evidence; excerpts are at
most 120 characters.

## Insight mapping

- friction, aha, feature gap, feature discovery, suggestion -> `finding`
- mental model or cross-participant recurrence -> `pattern`
- an explicit accepted product choice -> `decision`

Preserve category, confidence, severity, emotional context, journey stage,
priority, speaker, topics, quest relationships, and whether cross-participant
evidence exists in `metadata` and the Markdown body. Researcher commitments
remain actions, not knowledge artifacts.

## Proposal

Show the emotional arc, engagement, 2-3 sentence reading, proposed insights
with evidence and confidence, tensions, and actions. Ask `Save`, `Edit`, or
`Skip`. Only `Save` authorizes canonical writeback; publication and
notification require later, separate approvals.

## Runtime package

Create one temporary JSON package:

```json
{
  "schema_version": "egregore-research-ingest/v1",
  "kind": "interview",
  "source": {
    "type": "granola|file|paste",
    "id": "stable source identity",
    "revision": "source revision or content hash",
    "content_hash": "required SHA-256 of the acquired source"
  },
  "documents": [
    {
      "artifact_type": "interview",
      "title": "Interview: Sarah — onboarding",
      "canonical_path": "research/interviews/2026-08-27-sarah.md",
      "body_path": "/temporary/egregore-interview-briefing.md",
      "metadata": {
        "participant": "Sarah",
        "researcher": "oz",
        "interview_type": "onboarding",
        "engagement": "high"
      }
    },
    {
      "artifact_type": "participant",
      "title": "Sarah",
      "canonical_path": "research/participants/sarah.md",
      "body_path": "/temporary/egregore-interview-participant.md"
    },
    {
      "artifact_type": "finding",
      "title": "Setup concealed the API-key step",
      "canonical_path": "knowledge/findings/2026-08-27-api-key-step.md",
      "body_path": "/temporary/egregore-interview-finding.md",
      "metadata": {
        "category": "friction",
        "confidence": 0.9,
        "priority": "p0_blocker",
        "severity": "blocker",
        "speaker": "participant"
      },
      "relationships": [
        {"relation": "from_interview", "target_id": "artifact id of briefing"}
      ]
    }
  ]
}
```

Body paths point to temporary analysis output, never directly to canonical
memory. The package may contain at most 40 Markdown documents. Runtime
authorizes all artifact identities before reading bodies, validates allowed research paths,
writes the package in one Git provenance commit, refreshes the derived index
once, starts one changed-hash embedding job, and emits content-free telemetry.
