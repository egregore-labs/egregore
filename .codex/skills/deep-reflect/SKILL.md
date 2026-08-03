---
name: deep-reflect
description: Deep research over the Egregore org memory — multi-hop, evidence-verified synthesis of what the org collectively knows — when the user invokes /deep-reflect or $deep-reflect.
---

# Egregore Deep Reflect (v4)

Native Codex Egregore skill. Ask the org's memory a question and return a
verified, cited synthesis of what it collectively knows — including what it
doesn't. `/reflect` captures user thought; `/deep-reflect` researches what the
org already knows.

Full contracts live in `.claude/skills/deep-reflect/` (`SKILL.md` entry,
`RESEARCH.md` engine, `ROLES.md` agent roles, `REPORT.md` output). Follow them;
this file is the Codex-runtime adapter.

## Modes

- Question (default): interrogative or bare-topic arguments → "what does the
  org know about X?"
- Cross-ref: "cross-reference this" / a declarative insight → "how does this
  insight sit against existing memory?"
- Depth: `--brief` (1 hop wave), standard (≤3), `--deep` (≤5). Default is
  dynamic from the corpus probe.

## Flow

1. Check `egregore.json` mode FIRST. Local mode: full engine over files; never
   call graph, batch-graph, or notification scripts; zero graph vocabulary in
   output. Connected: graph adds hop rails and writeback, every graph call
   non-fatal (`2>/dev/null || true`).
2. FRAME: corpus probe — 2× `bin/agent.sh search "$TOPIC" --fast -n 20` with
   different wordings + `bin/artifacts.sh find "$TOPIC"` +
   `grep -ril "$TOPIC" memory/knowledge/ memory/handoffs/ memory/artifacts/`.
   N = the union of unique paths; set the wave budget from N per
   `RESEARCH.md` §Budget; decompose the question into 2-4 sub-questions;
   print a plan line (`Researching: … · ~N relevant docs · budget M waves ·
   est ~X min`). Under ~5 relevant docs: say memory is too thin and offer
   `/reflect` or `/harvest` instead of faking research. If search errors or
   returns nothing while grep hits, rely on grep and note "recall degraded".
3. SEED: check `memory/knowledge/research/` for prior runs on the topic —
   their cited artifacts (frontmatter `artifacts_cited`, older reports use
   `artifacts_consulted`; resolve filename stems with `find`) are pre-warmed
   leads, and their `null_regions` gaps get re-audited. Build a frontier of
   ≤12 docs from search probes, frontmatter topic/quest greps, and index
   ledgers.
4. HOP WAVES: the Codex runtime has no Workflow tool — run the foreground
   staged path from `ROLES.md`: per wave, read 8-12 docs (subagents if the
   session offers them, otherwise staged single-model passes), extract
   claims-with-verbatim-excerpts and typed leads (doc links, quests, people,
   sessions, topic terms, named absences). Dedup against the seen-set, score
   leads, hop until saturation per `RESEARCH.md` (coverage on every
   sub-question plus low novelty or zero yield; or budget).
5. PATTERN: two de-correlated passes. Without subagents true blindness is
   impossible — degrade deliberately: run the TENSION pass FIRST (grouped by
   topic), then the convergence pass (chronological), so tension-finding is
   never anchored by an existing convergence story. Disagreement between
   passes is a finding, never averaged away.
6. VERIFY: for every claim, whitespace-normalize the excerpt and re-find it in
   the cited file (miss = miscite = kill; supported paraphrase = correct the
   excerpt). The mechanical re-check survives self-verification — it is a
   grep, not a judgment. Re-attack every gap claim with one extra probe; a
   found doc refutes the gap and joins the ledger. Evidence older than ~90
   days gets one `--fast` newer-artifact probe. Report the kill count. When
   the verifying context is the same one that made the claims, mark the
   report's provenance `verification: self-checked`.
7. SYNTHESIZE + PRESENT: stance, not summary — answer first, then ◆ primary /
   ◇ secondary findings with `memory/...` path citations, tensions, and "what
   memory doesn't hold" (gaps + the probes that prove them). Confidence is
   derived from evidence structure (verified + ≥3 independent sources = high;
   single-source always labeled). Register: analyst, not critic.
8. CAPTURE (user-gated): Save (default) / Edit first / File follow-ups /
   Skip. On Save write `memory/knowledge/research/YYYY-MM-DD-author-slug.md`
   with frontmatter (question, mode, stop_reason, waves, docs_read,
   claims_killed, builds_on, artifacts_consulted, artifacts_cited,
   null_regions), then connected-mode best-effort graph writes per the main
   `REPORT.md` §Writeback (MERGE with filePath — do NOT use
   `graph-op.sh register-artifact`; `RELATES_TO`/`TENSION_WITH` for verified
   cross-ref claims only), then
   `bin/agent.sh save --message "Deep research: $TOPIC" --topic "$TOPIC"`.
   On Skip: nothing is written except the local run ledger under
   `.egregore/research-runs/`. Render the TUI box AFTER the gate, reflecting
   the actual outcome.

## Output

Render the Egregore deep-reflect confirmation TUI after the capture gate:

- 72-column outer box, standard top/separator/content/bottom lines only.
- Header: `◈ DEEP REFLECT`, author, date.
- Body: question, ◆/◇ finding counts, confidence, waves · docs read · cited ·
  claims cut in verification.
- Footer: actual saved/pushed state; say "graphed" only if the graph write
  succeeded; in local mode omit graph language entirely.
- Structured UX parity is required: preserve the rendered deep-reflect TUI
  box, no preamble, no prose-only replacement, and no raw search or graph
  output.
- Never show raw graph JSON; never replace the box with prose.

## Rules

- Search budget: at most ONE non-`--fast` search probe per run (seed only);
  `--fast` everywhere else. Count result blocks, never the banner hit count.
- No claim without a verbatim excerpt that survives re-finding in the file.
- Absence is a first-class finding — cite the probes that prove it.
- Don't manufacture significance: "memory holds nothing structural on this"
  is a valid report.
- At most ONE clarifying question before the run, plus the capture gate.
- Do not use Claude Code commands.
