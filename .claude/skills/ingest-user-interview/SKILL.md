---
name: ingest-user-interview
description: "Analyze a user interview from Granola, pasted text, or a file into an evidence-backed briefing, journey insights, product findings, patterns, and actions. Use for /ingest user-interview, onboarding interviews, research calls, or requests to process user feedback."
---

# Ingest user interview

Acquire the transcript, understand the research intent, analyze it with
appropriate lenses, preview the result, then persist one approved typed package
through Egregore Runtime.

Read [references/analysis-contract.md](references/analysis-contract.md) before
analysis or package construction.

## When to invoke

Analyze a user interview from Granola, pasted text, or a file into an evidence-backed briefing, journey insights, product findings, patterns, and actions. Use for /ingest user-interview, onboarding interviews, research calls, or requests to process user feedback.

Use the `meeting` skill for a general team meeting.

## Source

Accept one of:

- Granola connector: search/select, then fetch transcript and stable metadata;
- pasted transcript;
- a user-authorized `.txt`, `.md`, or `.json` file.

Infer participant, researcher, interview type, date, and source revision when
reliable; otherwise ask compact questions. Do not put connector credentials or
the raw transcript into canonical memory merely to analyze it.

## Context and analysis

Reuse sufficient `EGREGORE_ORG_CONTEXT_V1`. Open selected canonical evidence
through Runtime when verification is necessary. If cross-interview comparison
is requested and context is insufficient, make at most one Egregore retrieval
request. Never query graph/QMD directly; canonical Markdown/Git wins.

Start with a compact scaffold. Analyze inline for short interviews. For long or
complex material, parallel Journey, Sentiment, and Product lenses may run once,
then synthesize their evidence and disagreements. Do not force multi-agent work
when it adds latency without analytical value.

Show the emotional arc, evidence-backed product reading, proposed durable
insights, confidence, priority, tensions, and researcher actions. Ask `Save`,
`Edit`, or `Skip`. Do not write before `Save`.

## Canonical writeback

Build one temporary `egregore-research-ingest/v1` package under `tmp/` containing the
approved interview briefing, participant journey document where needed, and
typed findings/patterns/decisions. Then make exactly one deterministic call, using
`{package-json}` for the package file just written:

```bash
bash bin/research-ingest.sh interview --input '{package-json}'
```

Runtime owns authorization, schema/path validation, stable identity,
provenance, canonical Markdown, Git provenance, derived-index refresh,
background embedding, and telemetry. Do not separately create directories,
append indexes, write files, run `/save`, or manage graph projection.

Report accepted/partial/rejected status and canonical paths. Cross-interview
synthesis reads canonical artifacts; graph is optional enrichment only.
Publication and notifications are separate later effects and require their own
explicit approval.
