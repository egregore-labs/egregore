# RESEARCH.md — the engine contract

How multi-hop research actually works: the ledger, leads, waves, saturation, and budgets. `SKILL.md` is the entry point; this file is the mechanism. Agent prompts live in `ROLES.md`.

## The ledger

Main-loop state, mirrored to `.egregore/research-runs/{run-id}.json` after every wave (and on any exit — the ledger survives skipped runs and crashes; it is the provenance):

```json
{
  "run_id": "dr-2026-07-11-a3f2",
  "question": "...",
  "sub_questions": ["..."],
  "mode": "question|crossref",
  "band": "brief|standard|deep",
  "seen": ["memory/knowledge/decisions/2026-03-07-....md"],
  "lead_queue": [{"type": "quest", "ref": "onboarding-validation", "why": "...", "from": "path", "wave": 1, "score": 6}],
  "claims": [{"id": 1, "claim": "...", "sub_question": "...", "path": "...", "excerpt": "...", "date": "...", "author": "...", "weight": "primary|secondary|ambient", "wave": 1, "status": "pending|verified|corrected|downgraded|dated|killed|unverified", "relation": "crossref mode only"}],
  "gaps": [{"id": 1, "gap": "...", "probes": ["..."], "from": "scout|reader|analyst|coverage", "status": "provisional|verified|refuted"}],
  "log": [{"action": "...", "purpose": "...", "result": "..."}],
  "stop_reason": null
}
```

**The main loop assigns a stable integer `id` to every claim and gap when merging agent output into the ledger.** All downstream references (analysts' `claim_ids`, skeptics' verdicts) use these ids — never positional indices, since analysts and skeptics receive differently ordered or partitioned views.

`seen` holds normalized repo-relative paths (plus graph ids when connected). A doc enters `seen` when assigned to a reader, never twice.

## Leads

A **lead** is a typed pointer extracted by a reader from document text or graph neighbors:

```
{type: doc-link | quest | person | session | pr | topic-term | named-absent, ref, why, from, wave}
```

Extraction sources map to real substrate affordances — readers look for:
- explicit `memory/` paths and relative `.md` links in prose
- frontmatter fields, BOTH generations (`ROLES.md` §Frontmatter): YAML `topics:[]` / `quests:[]` / `harvest:` / `synthesis:` / `affects:`, and old-style `**Topics**:` bold-field lines
- author names in filenames (`DD-author-topic.md`) and bylines
- branch names, PR numbers, and hosted URLs in handoff prose
- `handoffs/index.md` and `quests/index.md` ledger rows
- connected mode: graph neighbors via the `filePath` bridge — `PART_OF`, `IMPLEMENTS` chains, `BUILDS_ON`/`SUPERSEDES`/`REFINES`, `RELATES_TO`/`TENSION_WITH` (prior deep-reflect output is a hop rail)

**Lead resolution** (main loop, between waves) converts non-doc leads to files:
- `person` → `ls memory/handoffs/*/ | grep {author}` + `memory/people/{name}.md` (+ graph `CONTRIBUTED_BY` when connected)
- `quest` → `memory/quests/{slug}.md` + frontmatter grep for members
- `session` → handoff filePath via `handoffs/index.md`
- `topic-term` → exactly ONE `search.sh query "{term}" --fast -n 5`. Topic leads may NOT recursively spawn topic leads — fan-out control.
- `named-absent` → never hops. The main loop runs ONE `--fast` resolution probe; on miss, it enters the gap register with that probe attached.

## Graph orientation (connected mode, seed stage only)

One query, non-fatal, results fed to the scouts:

```bash
bash bin/graph.sh query "MATCH (a:Artifact) WHERE any(t IN a.topics WHERE t CONTAINS \$topic) OR toLower(a.title) CONTAINS \$topic OPTIONAL MATCH (a)-[r:RELATES_TO|TENSION_WITH|PART_OF]-(n) RETURN a.title, a.type, a.filePath, type(r), coalesce(n.title, n.id) LIMIT 25" '{"topic": "{lowercased core topic term}"}' 2>/dev/null || true
```

## Gaps

The gap register has three feeders, all routed by the main loop:

1. **Scout `gap_hypotheses`** — paired with that scout's `probes_run` list when entered into the register.
2. **Coverage probes** — after each wave, any sub-question with zero claims gets ≤2 main-loop `--fast` probes; if both miss, a gap entry is written with those probe strings.
3. **Reader `named-absent` leads and analyst `void` patterns** — folded into the register before VERIFY; the main loop attaches originating probes where they exist.

The skeptic receives the FULL gap register. For probe-less gaps it devises ≥2 probes itself. Only gaps that survive the skeptic's absence audit (`ROLES.md` §Skeptic) ship in the report.

## Waves

A **hop = one wave**: pop the top-K leads (K sized so resolved docs ≤ 8-12), resolve to files, batch into 2-4 parallel readers (3-6 files each — readers read their files in their OWN contexts; never pipe file contents through the main loop), merge results into the ledger.

**Lead scoring** for the queue: novelty (unseen: hard filter) × source-strength (citing doc's relevance verdict: high=3 / med=2 / low=1) × type-prior (doc-link, quest = 3 · person, session, pr = 2 · topic-term = 1), recency as tiebreak.

## Saturation

Three tests, checked after every wave:

- **(a) novelty low**: unseen leads / total leads extracted this wave < 0.25
- **(b) coverage met**: every sub-question has ≥2 independent sources (distinct authors OR distinct top-level dirs), OR a gap entry with ≥2 distinct failed probes (**provisional** — VERIFY re-attacks it later)
- **(c) yield zero**: no primary-weight claims this wave

Stop rules, as explicit predicates:

| stop_reason | Fires when |
|---|---|
| `answered` | Self-termination: before the budget, every sub-question has ≥2 sources including ≥1 primary claim, and the main loop judges further waves enrichment, not necessity. Don't spend to budget if strong synthesis is found early |
| `saturated` | (b) holds AND ((a) OR (c)) |
| `dry` | (a) AND (c) hold for two consecutive waves while (b) still fails — the corpus stopped yielding before coverage completed |
| `budget` | Wave cap reached (brief 1 / standard 3 / deep 5) |
| `sparse` | FRAME collapsed the run to the sparse band |

**Bonus wave rule**: if VERIFY refutes a gap claim (the skeptic found the doc), the found doc enters the ledger; if that leaves a sub-question uncovered, reopen ONE budget-exempt bonus wave — at most once per run. Bonus-wave claims go through a scoped second skeptic pass (mechanical + semantic checks only; no further gap re-search or decay audit). Analysts are NOT re-run; bonus-wave claims ship as findings only if verified, and patterns stand as pruned (`REPORT.md` §Pattern pruning).

## Budget

Set in FRAME. **Counting rule for N (relevant docs):** union of unique paths from (1) `grep -ril "{topic terms}" memory/knowledge/ memory/handoffs/ memory/artifacts/`, (2) 2× `search.sh query --fast -n 20` with different wordings (count result blocks, not the banner), (3) `bin/artifacts.sh find "{topic}"`. N = the union's size; it feeds the plan line and this table:

| N | Band | Waves |
|---|---|---|
| ≥ ~35, multi-dir spread | deep-leaning standard | 3 (5 on `--deep`) |
| ~20-35 | standard | 3 |
| ~5-20 | collapsed | 1 scout + 1 wave, insufficiency-forward report |
| < ~5 | none | offer `/reflect` or `/harvest`, stop |

If `search.sh` errors, warns `index update FAILED`, or returns zero blocks while grep/`artifacts.sh` hit: drop it from the union, rely on grep + artifacts.sh, and note "recall degraded" in the plan line — a broken index must not masquerade as a thin corpus.

`--brief`/`--deep` force the band. Search budget holds regardless: ONE best-available-tier probe per run (seed, scout #1), `--fast` elsewhere.

## Compounding

SEED must check prior research before searching cold:

1. `grep -ril "{topic terms}" memory/knowledge/research/ | head -5`
2. For each prior report found: read `artifacts_cited` (falling back to `artifacts_consulted` — the older generation) from its frontmatter. Entries may be filename STEMS rather than paths — resolve with `find memory -name "{stem}.md"` before promoting. Resolved paths become pre-warmed hop-0 leads (source-strength high).
3. Re-audit the prior report's `null_regions` frontmatter (structured gaps + probes): *"was this gap filled since?"* is a standing sub-question.
4. The new report stamps `builds_on: [prior-report-paths]` in frontmatter (+ `BUILDS_ON` edge, connected).

Only user-saved reports exist in `memory/knowledge/research/`, so compounding never seeds from ungated output.

## Decay

During VERIFY: any cited evidence older than ~90 days triggers ONE `--fast` newer-artifact probe (`search.sh query "{claim terms}" --fast -n 3`, or `SUPERSEDES` edge check when connected). A newer contradicting or superseding artifact demotes the claim to `dated` and is cited alongside it. In cross-ref mode this check may also set the claim's `relation` to `supersedes`.

## Resume

`--resume <run-id>`: load `.egregore/research-runs/{run-id}.json` and restore the FULL ledger — `seen`, `lead_queue`, `claims`, `gaps`, `log`. Continue under the original `run_id` and file. "Fresh budget" means the wave counter resets under the original band unless `--brief`/`--deep` is re-passed. The prior `stop_reason` is appended to `log` as `{action: "resumed"}`.

## Cross-ref mode differences

Identical engine. The insight text is decomposed into sub-questions of the form: *what supports this? what contradicts it? what already says it? what does it depend on?* Readers additionally set `relation` on each claim (`supports | contradicts | duplicates | depends-on` — derived from which sub-question the claim answers; `supersedes` is set only by the skeptic's decay check). The skeptic preserves or corrects `relation` alongside its verdict. Verified relations drive the capture stage's edge proposals (`REPORT.md` §Writeback).
