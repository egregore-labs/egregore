---
name: deep-reflect
description: "Run deep, multi-hop research over org memory to answer a question or cross-reference an insight, with a cited synthesis. Use for /deep-reflect — not one-shot recall (/search) or capturing an insight (/reflect)."
---

Deep research over org memory — ask a question, get a verified, cited synthesis of what the org collectively knows, including what it doesn't.

Multi-hop, multi-agent research over `memory/` (plus the graph, when connected). Waves of parallel readers hop a lead ledger until saturation; a skeptic pass kills every claim it cannot re-find in the cited file. `/reflect` captures user thought; `/deep-reflect` researches what the org already knows.

Pipeline: deep-reflect v4 · 2026-07-11 · thin entry + sibling contracts (`RESEARCH.md`, `ROLES.md`, `REPORT.md`).

## When to invoke

User says: "deep dive on X", "what do we know about X", "what does the knowledge base say about X", "research what we know about X", "what's the org's position on X", "cross-reference this", "analyze this against what we know", "connect the dots between X and Y"
Not this: web sources → out of scope (this skill researches memory, not the web) · one-shot recall ("what did we decide about X") → `/search` · capture a new insight → `/reflect` · ask people, not documents → `/harvest` · private thought → `/note` · track the open question itself → `/quest`

Arguments: $ARGUMENTS (Optional: [question or insight] [--brief|--deep] [--quest <slug>] [--no-capture] [--resume <run-id>])

**Saves through the capture gate.** A Save verdict runs the full `/save` flow — no separate `/save` after.

## Modes

| Mode | Job | Extra output |
|---|---|---|
| **question** (default) | Answer a research question from memory | — |
| **cross-ref** | v2's job: situate one insight against the corpus | verified `RELATES_TO`/`TENSION_WITH` edge proposals (connected) |

Both modes write reports to `memory/knowledge/research/` — except `--brief` and probe-collapsed sparse runs, which default to terminal-only output with a two-option Save/Skip gate (Save writes the standard file). Depth bands are orthogonal; the default is dynamic, set by the Stage-0 corpus probe:

| Band | Waves | Docs read | Wall clock |
|---|---|---|---|
| `--brief` | 1 | ~8 | ~1-2 min |
| standard | ≤3 | ~24 | ~3-5 min |
| `--deep` | ≤5 | ~45 | ~6-10 min |

**Detection order (Stage 0):** 1) strip flags; 2) interrogative form ("what/how/why/have we/do we…") → question mode; 3) "cross-reference" / "this" / a pronoun pointing at conversation content, or a declarative insight statement → cross-ref mode (the research question becomes *"how does {insight} sit against existing memory?"*); 4) bare topic noun-phrase → question mode with *"what does the org know about {topic}?"*; 5) empty and no session context → one AskUserQuestion offering 2-3 candidate questions mined from the current session, or stop cleanly on skip.

## Mode detection

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

**IMPORTANT**: Check mode FIRST, before any other step.

**Local mode** (`mode === "local"`): run the FULL engine over files. `bin/search.sh` is fully local; frontmatter topics/quests, `index.md` ledgers, and filename conventions are the hop rails. Skip ALL `bin/graph.sh` / `bin/graph-op.sh` calls — do NOT run them. Zero graph vocabulary in any output (no "graph offline", no Neo4j, no connected-mode upsell). Cross-references persist as markdown links in the report. TUI footer: `✓ Saved · pushed`.

**Connected mode**: adds one graph orientation query at seed (`RESEARCH.md` §Graph orientation), graph-edge lead extraction, search enrichment annotations, and capture-gate graph writes. Footer: `✓ Saved · graphed · pushed` — but only when the graph writes actually succeeded (`REPORT.md` §TUI box).

**Connected but graph offline**: DOES message, once — `Graph offline — researching over files only.` — then runs the local-shaped plan. Every graph call throughout is non-fatal (`2>/dev/null || true`); the file is the canonical record.

## Execution rules

- **Dialogue budget (hard rule):** at most ONE AskUserQuestion before the run — fired only when the question is underspecified (combine scope confirmation + depth choice in that single call). A long estimate alone never requires confirmation — the plan line is the notice. Plus the capture gate at the end, including any user-initiated follow-up branches inside it. Never more.
- **Plan line before any work:** `Researching: {question} · ~{N} relevant docs · budget {M} waves · est ~{X} min` — N per `RESEARCH.md` §Budget's counting rule. Pre-announce any single long operation (`semantic search ~30s…`).
- **Wave ticker while running:** `[wave 2/3] read 11 · claims 9 · new leads 6 (2 quests, 1 person, 3 files)`.
- **Search budget:** at most ONE best-available-tier `bin/search.sh` probe per run (seed stage, scout #1 only); `--fast` everywhere else — frame probes, lead resolution, decay checks, dedupe. Never trust the banner hit count — count result blocks.
- **CRITICAL: Suppress raw output.** Never show raw JSON or file dumps. Bulk payloads go to `"${TMPDIR:-/tmp}/egregore-research-$$.json"` and get jq-sliced.
- Call inventory: 1 `git config user.name` · 2 corpus probes + greps (frame) + ≤6 scout probes (seed) + per-wave topic-lead and per-claim decay `--fast` probes as the contracts allow · 4-26 subagents depending on band (scouts, readers, analysts, skeptics) · 0-1 pre-run AskUserQuestion · 1 capture-gate AskUserQuestion · capture writes + auto-save · telemetry.
- Run ID: `dr-$(date +%Y-%m-%d)-$(openssl rand -hex 2)`. Ledger persists at `.egregore/research-runs/{run-id}.json` (local only, never pushed) — including for skipped runs. The log IS the provenance, not a byproduct.

## Orchestration

Invoking this skill IS the user's opt-in to Workflow orchestration for this run. Compose workflow scripts at runtime from `RESEARCH.md` (stages, ledger, saturation) and `ROLES.md` (agent contracts + schemas). Do NOT ship or reuse a stored `.js` — the prose contracts are the single source of truth.

**The seam:** one Workflow invocation per stage fan-out — the scouts, each wave's readers, the analysts, the skeptics. The main conversation performs lead resolution, ledger merge/mirror, and saturation checks BETWEEN invocations. Readers read their assigned files in their own contexts — never pipe file contents through the main loop.

**Workflow tool unavailable** (older harness, org policy): run the SAME stages as standard foreground parallel Task calls (NOT `run_in_background`) binding the same `ROLES.md` contracts — JSON by prompt discipline, one repair attempt, then continue with whatever agents succeeded. This fallback is a first-class path with the identical seam structure. Runtimes with no subagents at all (some Codex sessions) degrade further per the Codex adapter: staged single-model passes, provenance marked `verification: self-checked`.

Spawns pass NO model override — subagents inherit the session tier (`loom/routes.json` carries the delegation note; Loom Phase 1 does not let skills pin models). Framing, synthesis, and the capture gate stay in the main loop.

## Stages

Engine contract: `RESEARCH.md`. Agent prompts + schemas: `ROLES.md`. Report, TUI, capture: `REPORT.md`.

0. **FRAME** (main loop) — parse per detection order; mode check; corpus probe per `RESEARCH.md` §Budget (grep + 2× `search.sh --fast` + `bin/artifacts.sh find`, unioned) sets N and the wave budget; decompose the question into 2-4 sub-questions that define coverage; print the plan line.
1. **SEED** (2 scouts, parallel) — build the initial frontier (≤12 docs): search probes, frontmatter/index greps, prior-research compounding (`RESEARCH.md` §Compounding), one graph orientation query (connected only). Scout #1 holds the run's single best-available-tier search probe; scout #2 is `--fast`-only.
2. **HOP WAVES** (2-4 readers per wave, loop) — readers read their assigned files in their own contexts and return claims-with-verbatim-excerpts + typed leads. Main loop merges into the ledger (assigning stable claim/gap ids), dedupes, scores, resolves top leads to files, probes uncovered sub-questions (`RESEARCH.md` §Gaps), checks saturation, schedules next wave or stops.
3. **PATTERN** (2 analysts, de-correlated) — convergence lens and tension lens over the id-carrying claims table; the tension analyst never sees convergence output. Disagreement between analysts is preserved as a finding, never averaged.
4. **VERIFY** (1-2 skeptics) — mechanical excerpt check (kill on fabrication), semantic support check (downgrade on overreach), adversarial gap re-search (a found doc refutes the gap and enters the ledger), decay probe on evidence older than ~90 days. A refuted gap may reopen ONE bonus wave; bonus-wave claims get a scoped second skeptic pass (`RESEARCH.md` §Saturation). The kill count is reported.
5. **SYNTHESIZE** (main loop) — prune patterns whose support died (`REPORT.md` §Pattern pruning); stance, not summary: 2-4 paragraphs that tell the user something they don't already know. Confidence is derived from evidence structure, never self-reported. Insufficiency map assembled from surviving gap claims. Register: analyst, not critic — "the memory shows X", never "the team is failing to Y".
6. **PRESENT** (main loop) — answer → findings (◆/◇ with inline path citations) → tensions & disagreements → what memory doesn't hold → provenance footer. The evidence appendix goes in the report file, NOT chat. No TUI box yet.
7. **CAPTURE?** (main loop) — one AskUserQuestion: **Save** (default) / **Edit first** / **File follow-ups** (gaps → `/quest` or `/harvest` stubs) / **Skip**. Writeback per `REPORT.md`, then render the ◈ TUI box reflecting the ACTUAL outcome. Skip leaves only the local ledger — no memory writes, no graph writes.

## Telemetry

Fire-and-forget after the run completes or exits early (single emit — not at frame):

```bash
bash bin/telemetry.sh emit "command" '{"command":"deep-reflect","mode":"question","waves":3,"docs_read":24,"stop_reason":"saturated","duration_ms":210000}' 2>/dev/null &
```

All extended fields optional; never include the question text or file paths.

## Edge cases

| Scenario | Handling |
|---|---|
| Topic-sparse probe (<~20 relevant docs) | Collapse to 1 scout + 1 wave + inline synthesis; announce "memory is thin here"; ship an insufficiency-forward report — sparse IS a finding |
| Ultra-sparse (<~5 relevant docs) | Say so; offer `/reflect` (capture what you know) or `/harvest` (ask people) instead of faking research |
| `search.sh` errors, warns `index update FAILED`, or returns zero blocks while grep/`artifacts.sh` find hits | Fall back to the grep-based corpus probe before classifying the corpus as sparse; note "recall degraded" in the plan line |
| Workflow tool unavailable | Foreground parallel Task fan-out per §Orchestration |
| Hybrid search models not on disk | `--fast` everywhere; zero inline downloads |
| Graph down (connected) | One-line note, local-shaped plan, non-fatal calls |
| Reader/analyst fails mid-wave | Log to provenance, continue partial; both analysts fail → main loop synthesizes from the verified claims table at capped confidence |
| Skeptic fails | Rerun once; else every unchecked claim ships marked `unverified` in the report and say so — never skip verification silently |
| No findings survive | "Memory holds nothing structural on this" is a valid report. Don't manufacture significance |
| Memory symlink missing | Error: "Run /setup first" |
| File collision on save | Append 4-char hex to slug |
| User skips capture | Ledger remains at `.egregore/research-runs/` — nothing else is written |

## Example

```
> /deep-reflect what do we actually know about onboarding drop-off?

Researching: onboarding drop-off · ~34 relevant docs · budget 3 waves · est ~4 min
[wave 1/3] read 10 · claims 8 · new leads 9 (3 files, 2 quests, 1 person)
[wave 2/3] read 9 · claims 6 · new leads 4 (2 files, 1 session)
[wave 3/3] skipped — saturated (novelty 0.18, all sub-questions covered)
Verifying 14 claims + 3 gaps… 1 claim cut (miscite) · 1 gap refuted (doc found → read)

[ANSWER — 3 paragraphs of stance]
[FINDINGS — ◆ primary / ◇ secondary with path citations]
[TENSIONS — including one analyst disagreement, preserved]
[WHAT MEMORY DOESN'T HOLD — 2 verified gaps + the probes that prove them]
3 waves · 20 docs read · 11 cited · 1 claim cut in verification · stopped: saturated

[AskUserQuestion: Save (default) / Edit first / File follow-ups / Skip]
> Save

[1/3] ✓ Writing knowledge/research/2026-07-11-cem-onboarding-drop-off.md
[2/3] ✓ Indexed in knowledge graph (4 edges)
[3/3] ✓ Auto-saved

┌──────────────────────────────────────────────────────────────────────┐
│  ◈ DEEP REFLECT                                       cem · Jul 11   │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Q: what do we know about onboarding drop-off?                       │
│  ◆ 3 primary · ◇ 4 secondary findings · confidence: high             │
│  3 waves · 20 docs read · 11 cited · 1 claim cut in verification     │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Saved · graphed · pushed                                          │
│  Visible in /activity.                                               │
└──────────────────────────────────────────────────────────────────────┘
```

## Backwards compatibility

- Report artifacts use `type: research` and land in `memory/knowledge/research/` (established by the Mar 7 redesign; `findings/` remains `/reflect`'s lane).
- Prior v2 `RELATES_TO`/`TENSION_WITH` edges are read as hop rails and extended (cross-ref mode, verified claims only). Old edges keep working.
- The v2 invocation phrases all still route here; `quick|focused|deep` keyword syntax is retired in favor of `--brief`/`--deep` + dynamic default.
