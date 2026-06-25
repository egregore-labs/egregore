---
name: harvest
description: Run an adaptive Egregore harvest from Codex when the user invokes /harvest or $harvest to elicit tacit context, preferences, positions, and team judgment.
---

# Egregore Harvest

Native Codex Egregore skill. A harvest is a structured elicitation process that
turns tacit context into durable organizational memory.

## Parse

Accept a topic plus optional flags:

- `--respondents a,b`
- `--seed path`
- `--resume id`
- `--mode blind|disclosed|comparative`

Resolve the initiator from `.egregore-state.json`, then git config. Mint IDs as
`harvest-YYYY-MM-DD-topic-slug` and
`harvest-YYYY-MM-DD-topic-slug-respondent`.

## State

Markdown is canonical. Persist under:

```text
memory/knowledge/harvests/{date}-{slug}/
  manifest.md
  sessions/{handle}.md
  synthesis.md
```

Single-respondent harvests may use one flat markdown file when that is simpler.
Every manifest records topic, intent, initiator, respondents, disclosure mode,
status, seed paths, and role-sheet assumptions.

Connected mode may also call `bin/graph-op.sh` helpers, but graph writes are
best-effort and must never block markdown state.

## Process

1. Sync memory with `bin/agent.sh sync`.
2. If `--resume` is present, reload the manifest, sessions, and prior
   evaluations before asking anything new.
3. Build a role sheet for each respondent from `memory/people/*.md`, recent
   handoffs, wraps, quests, and optionally graph context.
4. Clarify the harvest intent when topic, respondents, dimensions, or
   disclosure mode are under-specified. Use structured Codex question tooling
   when available; otherwise ask one numbered question at a time with `Other:`.
5. Ask situated questions. Each question must have an explicit
   `question_intent` and must be grounded in the role sheet, seed, or prior
   answers.
6. Persist every turn immediately with turn number, question, intent, answer,
   and evaluation. For absent respondents, create async questions with:

```bash
bin/agent.sh ask --from "$INITIATOR" --to "$RESPONDENT" --topic "$TOPIC" --question "$QUESTION" --harvest-id "$HARVEST_ID" --harvest-session-id "$HARVEST_SESSION_ID" --turn "$TURN" --question-intent "$QUESTION_INTENT" --context-mode "$DISCLOSURE_MODE"
```

7. In connected mode, notify async respondents best-effort with
   `bin/notify.sh send`.
8. Continue until present respondents reach diminishing returns and async
   respondents are either answered, pending, or explicitly skipped.

## Synthesis

Write `synthesis.md` with:

- L0: compact portrait of the harvest.
- L1: useful patterns, preferences, constraints, and positions.
- L2: respondent or theme slices, chosen based on the material.
- L3: decisions, open questions, follow-ups, and reusable context.

Evidence should be attributed. Quotes support synthesized positions; they do
not replace them.

After synthesis, mark the manifest complete, commit and push memory:

```bash
git -C memory add knowledge/harvests
git -C memory commit -m "harvest: $TOPIC" --quiet
git -C memory push origin main --quiet
```

Emit telemetry best-effort in the background.

## Output

Structured UX parity is required. When a harvest completes or checkpoints,
render the Egregore harvest TUI instead of a prose-only recap:

- Use a 72-column outer box with standard top/separator/content/bottom lines.
- Header: `HARVEST`, initiator, and date.
- Body: topic, respondents, disclosure mode, synthesis path, and a one-line
  layer summary when available.
- Footer: harvested/synthesized/saved/pushed state and `Visible in /activity.`
- If graph writes are skipped or unavailable, reflect that in the footer
  without saying the harvest failed when markdown was saved.

## Rules

- Ask one question at a time for present respondents.
- Make low-confidence role assumptions visible when they shape questions.
- Local mode skips graph and notification calls.
- Do not use Claude Code commands.
