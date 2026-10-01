---
name: harvest
description: "Run an adaptive harvest — directed elicitation that extracts, deepens, and synthesizes what people think about a topic. Use for 'harvest', 'run a harvest', 'align the team on', or a structured interview; not for a casual question or fixed survey."
---

# Harvest

Elicit tacit preferences, positions, constraints, and knowledge, then preserve
an attributed synthesis. A harvest maps choices; it does not force convergence.

## When to invoke

Run an adaptive harvest — directed elicitation that extracts, deepens, and synthesizes what people think about a topic. Use for 'harvest', 'run a harvest', 'align the team on', or a structured interview; not for a casual question or fixed survey.

## Load the cognitive contracts

Read these completely before questioning:

- `.claude/skills/harvest/PROCESS.md` — adaptive elicitation rhythm
- `.claude/skills/harvest/QUESTION_PALETTE.md` — intent, move, answer shape
- `.claude/skills/harvest/FORMAT.md` — evidence-bound synthesis grammar

Use `AUDIT.md` §14 only when a pasted decision-surface return requires its
review grammar. Its historical graph/file persistence recipes are not an
execution contract; Runtime adapters below own persistence.

## Seed

Parse topic plus optional `--respondents`, `--seed`, `--resume`, and
`--mode blind|disclosed|comparative`. Reuse attached
`EGREGORE_ORG_CONTEXT_V1`; do not repeat retrieval or reopen supplied sources.
If a named gap remains, make one `bin/search.sh query` episode and open only
the missing canonical evidence. Do not query infrastructure directly.

Make low-confidence RoleSheet assumptions visible. In blind mode, other
respondents' answer content neither appears nor shapes their questions. For a
blind shared-artifact round, dispatch the frozen question set unchanged.

## Elicit

Apply PROCESS.md's seed → generate → evaluate → checkpoint → cascade →
synthesize rhythm:

- Ask one interaction at a time and always allow freeform correction.
- Record a `questionIntent` and evidence-bound evaluation for each answer.
- Watch for satisficing and sycophancy; name real tensions.
- Offer checkpoints at natural transitions and respect “I'm done.”
- Attribute disclosed positions. Never turn a majority into anonymous team
  alignment.
- While collection is open, a respondent may correct their answer. After the
  declared completion condition seals the evidence, a changed position starts
  a new round; there is no automatic second pass.

For an absent respondent, create one authorized canonical question per turn:

```bash
bash bin/question.sh create \
  --from "{initiator}" --to "{respondent}" \
  --topic "{topic}" --question "{question}" \
  --harvest-id "{harvest_id}" \
  --harvest-session-id "{harvest_session_id}" \
  --turn "{turn}" --question-intent "{intent}" \
  --context-mode "{blind|disclosed|comparative}"
```

This records the pending question; it does not notify anyone. Delivery requires
a separate action permission and exact recipient/message consent.

## Decision-shaped rounds

For three or more genuine interrelated forks, use the existing Meridian
decision-surface renderer and QUESTION_PALETTE modes. Self surfaces may remain
local. Do not publish, share, or deliver a directed surface implicitly. A
separate permitted, explicitly consented action is required. Absorb returned
answers into the evidence set; keep `UNDECIDED` open. Do not write graph or
event-log projections directly.

## Synthesize and write once

Build the attributed layered synthesis from FORMAT.md. Every assertion must
trace to a recorded answer or marked seed. Show the synthesis and wait for
acceptance or edits. Then render one complete Markdown body to a temporary file under
`tmp/` and make exactly one canonical synthesis write; `{synthesis-file}` is that file,
`{synthesis-title}` is the accepted topic followed by ` — harvest synthesis`, and
`{topic}` and `{workstream}` come from the accepted synthesis:

```bash
bash bin/knowledge.sh create \
  --type finding --subtype harvest-synthesis \
  --title '{synthesis-title}' \
  --input '{synthesis-file}' \
  --topic harvest --topic '{topic}' \
  --workstream '{workstream}'
```

The Runtime owns ActorContext authorization, stable provenance, Markdown/Git,
retrieval refresh, background embedding, and content-free telemetry. Do not
run a second save, index, graph, publish, share, or notification action.

Render the compact `⊙ HARVEST` completion with topic, respondents, disclosure
mode, canonical path, and writeback status. Canonical Markdown wins over every
optional projection.
