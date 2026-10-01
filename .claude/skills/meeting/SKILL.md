---
name: meeting
description: "Analyze a Granola meeting into an evidence-backed briefing, decisions, findings, patterns, actions, and continuity. Use for /meeting, /meeting sync, /meeting backfill, or requests to process a meeting."
---

# Meeting

Acquire meeting material, adapt the analysis to the user's intent, preview the
result, then persist one approved typed package through Egregore Runtime.

Read [references/analysis-contract.md](references/analysis-contract.md) before
analysis or package construction.

## When to invoke

Analyze a Granola meeting or supplied transcript into an evidence-backed briefing, decisions, findings, patterns, actions, and continuity. Use for /meeting, /meeting sync, /meeting backfill, or requests to process a meeting.

## Source

When the user supplies a transcript as pasted text or a file path, analyze it
directly. Take title, date, and attendees from the user or the file; ask only
for missing metadata needed for analysis or writeback. In the Runtime package,
use source type `transcript` and preserve a supplied stable source ID when
available; otherwise derive the ID as `transcript:<sha256>` from the acquired
transcript. Use its SHA-256 for `content_hash` and, when no source revision is
supplied, for `revision`. This path does not require Granola.

### Granola acquisition

The Granola connector is required only to list, search, or fetch meeting material.
Use the configured Granola connector to list/search meetings and fetch the
selected transcript plus title, date, attendees, source ID, and source
revision. Do not copy connector credentials or raw transcripts into canonical
memory.

- `/meeting`: list recent candidates and let the user choose.
- `/meeting <search>`: select an exact result or ask when ambiguous.
- `/meeting sync`: process selected new candidates with balanced defaults.
- `/meeting backfill`: re-analyze selected canonical meeting sources; never
  overwrite newer claims without explicit supersession.

If Granola is unavailable, explain the connection issue and stop. Connector
access is source acquisition, not organizational authorization or canonical
writeback.

## Context and intent

Reuse sufficient `EGREGORE_ORG_CONTEXT_V1`. Open already-selected canonical
evidence through the Runtime source-open boundary when exact verification is
needed. Do not repeat Observe/search merely because this skill loaded.

If compiled context is insufficient and continuity materially matters, make at
most one Egregore retrieval call, then open only relevant canonical sources.
Never query graph/QMD directly. Canonical Markdown/Git wins on disagreement.

For one interactive meeting, ask briefly what matters and whether the user
wants quick extraction or deeper dynamics/continuity. Skip questions when the
request already specifies intent, and in sync/backfill mode.

## Analyze and approve

Choose only useful lenses from the reference. Inline analysis is the fast
default; parallel analysts are optional for long or complex transcripts.
Actions remain separate from durable decisions/findings/patterns.

Show a concise preview with the heart of the meeting, evidence, confidence,
relationships, tensions, and actions. Ask `Save`, `Edit`, or `Skip`. Do not
write before `Save`.

## Canonical writeback

Build one temporary `egregore-research-ingest/v1` package under `tmp/` from the approved
briefing and extracted artifacts, then make exactly one deterministic call, using
`{package-json}` for the package file just written:

```bash
bash bin/research-ingest.sh meeting --input '{package-json}'
```

Runtime owns authorization, schema/path validation, stable identity,
provenance, canonical Markdown, Git provenance, derived-index refresh,
background embedding, and telemetry. Do not separately write files, mutate a
processed-meetings cache, run `/save`, or manage graph projection.

Report accepted/partial/rejected status and canonical paths from the receipt.
Graph projection, publication, and notifications are optional later effects.
Each requires its own capability/permission boundary; publication and every
notification also require a separate exact user approval.
