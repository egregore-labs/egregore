# REPORT.md — synthesis, presentation, capture

What the user sees, what gets saved, and how. The engine (`RESEARCH.md`) produces a verified claims table + patterns + gaps; this contract turns them into a report.

## Pattern pruning (before synthesis)

PATTERN ran on pending claims; VERIFY then changed some verdicts. Prune before synthesizing:
- A pattern whose supporting claims are ALL `killed` → dropped.
- Some support survives → the pattern's weight caps at the best surviving claim's weight.
- Support consists only of `downgraded`/`dated` claims → the pattern caps at `secondary`.
- Bonus-wave claims join a pattern's support only if `verified`/`corrected`.

## Synthesis register

**Stance, not summary.** 2-4 paragraphs that tell the user something they don't already know — this justifies the compute. If it could have been written from the finding list alone, rewrite it.

Address, in whatever order the material demands:
- **What the answer actually is.** Answer the question first. In cross-ref mode, say plainly how the insight sits: confirmed, contradicted, already known, or genuinely new.
- **Where the evidence is strong and where it's thin.** Dismiss weak findings explicitly rather than giving everything equal weight.
- **What's missing.** The insufficiency map is a headline deliverable, not an apology — what the org doesn't know, with the probes that prove it.
- **One thing to do.** One action that matters most. Everything else is context.

**Register: analyst, not critic.** "The memory shows X" — never "the team is failing to Y." No manufactured drama; positive patterns matter as much as tensions. Never adversarial, never patronizing, never coaching verbs ("crystallizing", "emerging", "sensing").

Anti-patterns: "This is an interesting question…" (you have nothing to say) · "The findings cluster around…" (describing data, not interpreting it) · "worth watching" (demands action or doesn't).

## Derived confidence

Never self-reported. Per finding:
- **high** — verified + ≥3 independent sources (distinct authors OR distinct top-level dirs) + no `dated` demotion
- **medium** — verified + 2 sources, or any source `dated`/`corrected`
- **single-source** — always labeled as such, regardless of how convincing the one source is

Overall confidence (TUI + frontmatter): **high** = every primary finding is high · **mixed** = findings span levels, or an analyst disagreement survived · **medium** = otherwise.

Analyst disagreement is never averaged into a middle confidence — it ships as a finding under Tensions.

## Chat presentation (in order)

1. **ANSWER** — the synthesis paragraphs.
2. **FINDINGS** — `◆` primary / `◇` secondary, each with inline `path` citations. Ambient findings go to the report file only.
3. **TENSIONS & DISAGREEMENTS** — contradictions, drift, supersession; analyst disagreement preserved and named.
4. **WHAT MEMORY DOESN'T HOLD** — verified gaps + the probes that prove them + nearest adjacent work.
5. **Provenance footer** — one line: `{N} waves · {N} docs read · {N} cited · {N} claims cut in verification · stopped: {stop_reason}`. `claims cut` counts claim verdicts `killed` only; gap refutations are reported separately (they ADD a doc, they don't cut a claim). Docs found by refuted gaps count in docs read.

The **evidence appendix** (per-finding path + excerpt table) goes in the report FILE only — on a deep run it is exactly the terminal wall progressive disclosure forbids.

Then the capture gate fires, writeback runs per the verdict, and the **TUI box renders LAST, reflecting the actual outcome**.

## TUI box

72-char width, exactly 4 line patterns (top `┌`+70×`─`+`┐` · separator `├`+70×`─`+`┤` · content `│`+2 spaces+text padded to 68+`│` · bottom `└`+70×`─`+`┘`). No sub-boxes. Sigil: `◈ DEEP REFLECT` (the faceted eye — looking inward with structure); header right: `{author} · {Mon DD}`.

Body lines: `Q: {question truncated ~55 chars}` · `◆ N primary · ◇ N secondary findings · confidence: {overall}` · `{N} waves · {N} docs read · {N} cited · {N} claims cut in verification`.

Footer after a separator — pick by ACTUAL outcome:
- Saved, connected, graph writes succeeded: `✓ Saved · graphed · pushed`
- Saved, local mode — or connected with a failed/offline graph write (add one line: `graph write failed — file is canonical` on capture-time failure): `✓ Saved · pushed`
- Skipped: `◦ Not saved — ledger at .egregore/research-runs/`

Then `Visible in /activity.` (saved runs only). The word "graphed" appears ONLY when the artifact upsert call actually returned success.

**Output the TUI box directly as a code block. Do not narrate or explain it. DO NOT count characters — approximate padding is fine.**

## Capture gate

One AskUserQuestion, always (unless `--no-capture`, which implies Skip):

- **Save** (default) — write the report, graph it (connected), push
- **Edit first** — apply the user's edits, then Save
- **File follow-ups** — for each verified gap: append a 2-3 line stub (`### Open: {gap}` / `Probes that came up empty: {probes}` / `From research run {run-id}`) to the matched quest file — matched = the `--quest` slug if given, else the quest lead most cited in the gap's source claims; no match → offer creating a quest. Gaps about what people think → draft a `/harvest` brief instead. Then re-offer Save/Skip for the report itself (this follow-up branch lives INSIDE the capture gate's dialogue budget)
- **Skip** — nothing touches `memory/` or the graph; the local ledger is the only residue

`--brief` and probe-collapsed sparse runs default to terminal-only output with a two-option **Save / Skip** gate; Save writes the standard file. This keeps `memory/knowledge/research/` from silting with one-hop lookups.

## Report file

Path: `memory/knowledge/research/{YYYY-MM-DD}-{author}-{slug}.md` (slug ≤50 chars; collision → append 4-char hex). Write via Bash heredoc (`cat > memory/... << 'EOF'`) — memory/ is a symlink outside the project.

```markdown
---
title: {question, statement-cased}
date: {YYYY-MM-DD}
author: {author}
type: research
question: "{the question as researched}"
mode: {question|crossref}
band: {brief|standard|deep}
stop_reason: {answered|saturated|dry|budget|sparse}
confidence: {high|medium|mixed}
waves: {N}
docs_read: {N}
claims_killed: {N}
run_id: {dr-...}
builds_on: [{prior research report paths, if compounding fired}]
artifacts_consulted: [{every path read}]
artifacts_cited: [{paths that survived into findings}]
null_regions:
  - gap: "{verified gap}"
    probes: ["{probe}", "{probe}"]
quests: [{--quest slug or dominant quest leads}]
topics: [{3-5 topics}]
---

{ANSWER — the synthesis, verbatim from chat}

## Findings
{findings with citations, including ambient}

## Tensions
## What memory doesn't hold
## Evidence appendix
| Finding | Source | Excerpt |
{every surviving claim}

## Provenance
{waves, probes run, agents spawned, kill/correction counts, stop reason, run id}
```

`null_regions` is the machine-readable face of "What memory doesn't hold" — future runs' compounding step re-audits it (`RESEARCH.md` §Compounding).

## Writeback (Save path)

1. **Dedupe probe**: `grep -ril "{question terms}" memory/knowledge/research/ | head -3` (same mechanism as compounding) — a near-duplicate prior report surfaces as "extends {path}?"; on confirm, stamp `builds_on` and continue.
2. **Write the file** (heredoc, above). Progress: `[1/3] ✓ Writing knowledge/research/{date}-{slug}.md`.
3. **Graph writes — CONNECTED MODE ONLY, all non-fatal** (`2>/dev/null || true`; the file is the canonical record). Do NOT use `bin/graph-op.sh register-artifact` — that op is for published hosted artifacts (requires a URL, sets `published: true`, never sets `filePath`). Instead MERGE the artifact the way `bin/sync-graph.sh` does for knowledge files:

   ```bash
   bash bin/graph.sh query "MERGE (a:Artifact {id: \$id}) SET a.title = \$title, a.type = 'research', a.topics = \$topics, a.filePath = \$filePath, a.created = coalesce(a.created, datetime()) WITH a MATCH (p:Person {name: \$author}) MERGE (a)-[:CONTRIBUTED_BY]->(p) RETURN a.id" '{"id": "{filename stem}", "title": "...", "topics": [...], "filePath": "knowledge/research/{filename}", "author": "{author}"}' 2>/dev/null || true
   ```

   `id` = filename stem; `filePath` makes the node reachable by search enrichment and future hop rails. (`sync-graph.sh` also scans `knowledge/research/` on `/save`, so a failed write self-heals on the next save.) Then, same non-fatality:
   - `PART_OF` → Quest when `--quest` given or quest leads dominated the ledger
   - `BUILDS_ON` → each prior report in `builds_on`
   - **Cross-ref mode, verified claims only**: edges from the new report's Artifact node to each cited artifact — `RELATES_TO {signal_type: relation, confidence, weight, run_id}` for `supports`/`duplicates`/`depends-on`, `TENSION_WITH {signal_type: relation, confidence, weight, run_id}` for `contradicts`/`supersedes` — skeptic-surviving edges only, so the cross-reference web grows with quality control
   - Progress: `[2/3] ✓ Indexed in knowledge graph ({N} edges)` on success; on failure print nothing here and use the local footer + failure note (omit this line entirely in local mode)
4. **Auto-save**: full `/save` flow — commit memory repo, push to main (pull-rebase-push with retry); commit any egregore-repo changes, push working branch + PR to develop. Progress: `[3/3] ✓ Auto-saved`.
5. **Telemetry** per `SKILL.md` §Telemetry.

Optional follow-up offer after save: "Render as a `/view` artifact?" — reuses the existing artifact pipeline; never build a bespoke one here.
