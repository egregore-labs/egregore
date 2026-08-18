---
name: view
description: "Generate a branded HTML artifact from Egregore data (quest, handoff, activity, board, network, or any document) and open it in the browser. Use for /view, 'render this', or 'show me visually'."
---

Generate a branded HTML artifact from Egregore data and open it in the browser.

Works in both connected and local mode — resolves data from memory files, not the graph.

## When to invoke

User says: "show me visually", "render this", "view as artifact", "open in browser",
"make this readable", "generate artifact", "show me [quest/handoff/plan]", "/view"

Not this: terminal formatting → just format in markdown · dashboard → `/dashboard`

Arguments: $ARGUMENTS (Optional: artifact type and/or name, or a file path)

## Loom routing

**Skip this section if your prompt contains `LOOM-EXECUTOR`** — you are the executor; run the skill as specced below. Full protocol: `.claude/context/loom.md`.

**Composition is the default for flagship documents — and it is main-loop-only.** Compose (do **NOT** delegate; run the **Composition path** below inline, print `bash bin/loom.sh footer view --override`, set `"override":true,"class":"composition"` in telemetry, skip the rest of this routing section) whenever **either**:

- **the doc is flagship** — a `document` render that reads as a strategy / prep / board / briefing / explainer / analysis / decision doc, i.e. something meant to be *read or presented*, with multiple `##` sections. This is now the DEFAULT for such docs (the floor disappointed too many times); OR
- an explicit cue is present — `--compose`, "compose this", "make it presentable / client-facing / flagship", "with the design trace / use the design trace / designed artifact / band 5".

**Opt DOWN to the fast template floor** (which may route to the cheap tier) ONLY when: the invocation carries `--floor` / `--fast`, or the ask is a quick/utility look ("just show me", "quick look", "rough render"), or the target is short/non-flagship (a stub, a single-section note), or it's a **typed** artifact (quest / handoff / activity / board / network — those keep their own templates and are not affected by this default). Composition is a frontier-authoring act; a cheap executor can only produce the floor.

1. Resolve: `ROUTE=$(bash bin/loom.sh route view)`, then `DECISION_ID=$(printf '%s\n' "$ROUTE" | jq -r '.decision_id // empty')`.
2. If `mode` ≠ `delegate`, or the user signalled depth ("deep", "think hard", `--deep`) → run this skill inline as normal. On a depth override, print `bash bin/loom.sh footer view --override` after the output and set `"override":true` in telemetry.
3. Otherwise delegate: spawn the Agent tool with `subagent_type:
   "loom-executor"`, `model` = the route's `tier`, prompt =
   `LOOM-DECISION-ID: $DECISION_ID` on its own first line, then
   `LOOM-EXECUTOR: Execute .claude/skills/view/SKILL.md`, plus the user's
   arguments and any context the spec needs from the session. Print the
   executor's final output **verbatim**, then print the output of
   `bash bin/loom.sh footer view`.
4. If the spawn fails or the executor's first line is `LOW_CONFIDENCE:` —
   triage the reason: needs-user-interaction or a main-loop-only tool → take
   over and finish this skill inline (no escalation); genuine uncertainty or
   failure → reassign `ROUTE=$(bash bin/loom.sh escalate view "<reason>")`,
   refresh `DECISION_ID` from `ROUTE`, then re-spawn once on the new tier
   carrying the returned decision ID
   (sticky for this session).
5. Telemetry (fire-and-forget):
   `bash bin/telemetry.sh emit "command" '{"command":"view","routed":true,"mode":"delegate","model":"<actual>","route_tier":"<table tier>","class":"<class>","escalated":<bool>,"override":<bool>,"source":"<source>"}' 2>/dev/null &`

## Supported artifact types

- `quest` — renders quest markdown from `memory/quests/`
- `handoff` — renders handoff markdown from `memory/handoffs/`
- `activity` — renders live team activity dashboard (no file needed)
- `board` — renders project board from `memory/board/board.json` (no file needed; interactive editor with paste-back loop, 5 tabs: Activity / Priority / Person / Timeline / Done). In connected mode, also publishes to a stable URL at `egregore.xyz/view/{org}/board` on every invocation — bookmark it and refresh to see the latest.
- `network` — renders people/relationship network (no file needed)
- `document` — renders any markdown file with branded styling (auto-detected fallback)

## Resolution logic

The key job of `/view` is resolving what the user wants to see into a file path. This must work without a graph.

### 1. Parse the arguments

- `/view quest artifact-generation` → type=quest, name=artifact-generation
- `/view handoff oss-security-audit` → type=handoff, name=oss-security-audit
- `/view activity` → type=activity, no file needed
- `/view board` → type=board, reads `memory/board/board.json`, no file argument needed
- `/view network` → type=network, no file needed
- `/view artifact-generation` → no type specified, search all types
- `/view memory/knowledge/decisions/some-decision.md` → direct file path
- `show me the security audit visually` → extract keywords, search

### 2. Resolve the file

**Direct file path**: If the argument looks like a file path (contains `/` or ends in `.md`), resolve it directly. If it exists, use it — type is auto-detected from location or falls back to `document`.

**Quest**: Search `memory/quests/` for `{name}.md` or partial match:
```bash
# Exact match
FILE="memory/quests/${name}.md"
# Partial match — find files containing the name
ls memory/quests/*.md | grep -i "$name" | head -1
```

**Handoff**: Search `memory/handoffs/` recursively (files are in date subdirectories):
```bash
# Search all subdirectories
find memory/handoffs/ -name "*.md" -not -name "index*" | grep -i "$name" | head -1
# If multiple matches, prefer most recent (sorted by path which includes date)
find memory/handoffs/ -name "*.md" -not -name "index*" | grep -i "$name" | sort -r | head -1
```

**Activity**: No file resolution needed — runs `bin/activity-data.sh` live.

**Board / Network**: No file resolution needed. `board` reads `memory/board/board.json` automatically (via git root). `network` is generated from people data.

**Auto-detect type** (no type specified):
1. Search `memory/quests/` first
2. Then `memory/handoffs/` recursively
3. Then `memory/knowledge/` recursively
4. If found, infer type from location (`quest` or `handoff`) — everything else is `document`

### 3. Generate and open

**Resolve the renderer first — prefer the in-repo CLI.** Running repo code avoids
fetching an external npm package (which permission classifiers flag) and exercises
local edits to `packages/egregore-artifacts` without waiting for an npm release:

```bash
RENDER="npx egregore-artifacts@latest"
if [ -f packages/egregore-artifacts/bin/cli.js ] && [ -d packages/egregore-artifacts/node_modules/react ]; then
  RENDER="node packages/egregore-artifacts/bin/cli.js"
fi
```

(If the local package exists but deps are missing, either run
`npm install --prefix packages/egregore-artifacts` or fall back to npx.)

**Design trace (documents).** A `document` render should follow the design
trace, not ship bare: auto-walk the UGI synthesis graph from the document's
substance (five stage ids — objective · audience · register · palette ·
grammar; option ids and auto-walk rules in
`packages/design-system/generative-ui/skill/SKILL.md`), resolve the brief, and
pass it to the renderer:

```bash
node --input-type=module -e "
import { resolveBrief } from './packages/design-system/generative-ui/resolve-brief.js';
import fs from 'node:fs';
fs.mkdirSync('/tmp/egregore-artifacts', { recursive: true });
fs.writeFileSync('/tmp/egregore-artifacts/brief-{slug}.json',
  JSON.stringify(resolveBrief(['{objective}','{audience}','{register}','{palette}','{grammar}'])));
"
$RENDER document <file> --brief /tmp/egregore-artifacts/brief-{slug}.json
```

Pick the five ids from the substance, one line of judgment each (e.g. a
strategy prep doc → decide · operators · editorial · vellum · decisive; a
public explainer → persuade · newcomer · marketing · loam · quiet). The brief
drives palette + grammar treatment; the designed layout (nav · hero · anchored
sections) renders regardless. If the generative-ui layer is unavailable
(pure-npx environment, no repo checkout), render without `--brief` — never
block on the trace.

### Composition path (`--compose`) — band 5, main-loop only

The template above is the **floor**. `--compose` is the **ceiling**: the design
trace at full depth means COMPOSITION, not pass-through (D6 free-generative band
— how the reference pages were made). The template renderer can never reach it;
composition is the frontier model authoring the page from the substance. This
path is what makes that reachable from the command instead of only by accident.

**This is the DEFAULT for flagship documents** (strategy / prep / board /
briefing / explainer / analysis / decision docs — see the Loom-routing rule
above). It also fires on explicit cues: `--compose`, "compose / make it
presentable / client-facing / flagship / with the design trace / use the design
trace / designed artifact / band 5". **When the user names "the design trace,"
they mean this composed ceiling — never the floor.** Opt DOWN to the fast
template floor below only for quick/utility looks or `--floor`/`--fast` (again,
see the routing rule). The floor is what disappoints when someone wanted the
trace — so when unsure whether a document is flagship, compose.

**Technical documents compose too — in a different register.** A spec, RFC,
protocol, architecture doc, API reference, evaluation report, or postmortem is
flagship and gets the full chrome, but it does **not** get editorial voice. See
step 4 below: the register decision comes before any content is written, and
picking wrong is the single most common way a composed render lands badly.

**Procedure (run inline — never delegate; see the compose note in Loom routing):**

1. Read the source document in full.
2. Start from the scaffold: `.claude/skills/view/compose-scaffold.html` (copy it;
   it carries the complete Meridian chrome — vellum/nocturne/loam tokens, fonts,
   sticky nav, theme toggle, contours — and a documented component kit). You fill
   content; you do **not** rebuild the chrome or re-pick colors.
3. Walk the UGI graph for the register/palette/grammar (as above) and stamp the
   manifest `register`/`grammar` + the footer trail. Pick the palette by
   substance: vellum (strategy/decision), loam (warm/instructional), etc.
4. **Decide the register FIRST — editorial or technical.** This governs every
   sentence you then write, and it is not a style preference; it is what the
   document *is*. Ask: does a reader come here to be *persuaded of a view*, or
   to *look something up and implement it*?

   | | **Editorial** | **Technical** |
   |---|---|---|
   | Documents | strategy · prep · briefing · explainer · analysis · narrative recap · pitch | spec · RFC · protocol · architecture · API reference · evaluation report · runbook · postmortem |
   | Headings | **statement titles** — the section's *finding* as display copy ("Most of the zoom-out is already decided.") | **descriptive, numbered** — the section's *name* ("3.3 Toponym and cultivar collision") |
   | Hero | two-tone `Lead. <em>accent phrase</em>` + italic standfirst | plain title + a `.meta` grid (version · date · author · depends-on) |
   | Prose | argues, lands a point, carries voice | states, qualifies, cites; declarative and neutral |
   | Opens with | the claim | Abstract, then Scope |
   | Decisions | `.hl` / `.readout` — the thing to land | explicit `Decision:` blocks, individually citable |
   | Tables | `.sumtable`, status matrices | numbered with `<caption>` ("Table 2 — …") so prose can reference them |
   | Never | bury the finding in a neutral heading | editorialize a heading, or assert without the measurement behind it |

   Signals for technical: numbered sections, a version field, "spec"/"protocol"/
   "requirements" in the title, code blocks carrying invocations, tables of
   measurements, a References section. **When the document is something someone
   will implement from, choose technical.** Editorial voice on a spec reads as
   unserious and buries the lookup value — that is the failure mode this table
   exists to prevent.

   Stamp the choice into the manifest `register` and the footer trail
   (`editorial` / `technical`, with a matching grammar such as `decisive` or
   `specification`).

5. **Transform, don't mirror** — in the chosen register. Never reproduce the
   markdown structure verbatim; pick a component per section from the kit by
   what the content *is*:
   - `.ledger` for Q→A pairs · `.tagcard` for named claims · `.claims` for
     numbers/stats · `.panels`+`.verdict-band` for option sets · `.hl` for the
     one thing to land · `.steps` for sequences · `.feat` for capability+status
     rows · `.threads` for decision lists · `.gap` for negatives · `.sumtable`
     with `.dot`s for a status matrix · `.readout` for the honest bottom line
   - technical renders lean on captioned tables, `Decision:` blocks, numbered
     rationale lists, and `.note`/`.note.caution` for limitations and hazards;
     they use `.hl`/`.readout` sparingly and never as a substitute for a heading
   - **transformation in technical register means structure, not voice** — split
     prose into tables, number the rationale, surface the decisions; do not
     rewrite the author's claims into slogans
   - nav links: one per composed section, to its `id` anchor
6. **Never inline a hex in content** — every theme-sensitive color is a
   `var(--token)`, or the toggle breaks dark mode. The kit already obeys this.
   Verify before opening: every `var(--x)` used must be defined in **both**
   `[data-theme="vellum"]` and `[data-theme="nocturne"]`, or dark mode breaks
   silently on that element.
7. Write to `/tmp/egregore-artifacts/composed-{slug}.html` and open directly
   (`open <path>`), then report the path + `Renderer: composed (band 5, inline)`.

Composition is judgment, not a script — the scaffold is the vocabulary, the
substance decides the sentence. When `--compose` is absent, use the fast
template path below.

For typed artifacts with a file:
```bash
$RENDER <type> <resolved-file-path>
```

For auto-detected (just a file path):
```bash
$RENDER <resolved-file-path>
```

For activity (no file):
```bash
$RENDER activity
```

**For board (connected mode only — publish to stable URL):**

After opening locally, fire-and-forget a publish with a stable `--id` so the URL `egregore.xyz/view/{org}/board` always shows the latest board:

```bash
_API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
_MODE=$(jq -r '.mode // empty' egregore.json 2>/dev/null)
if [ -n "$_API_URL" ] && [ "$_MODE" != "local" ]; then
  ORG_NAME=$(jq -r '.org_name // .slug' egregore.json)
  bash bin/publish-artifact.sh board memory/board/board.json \
    --id board \
    --title "Project Board — $ORG_NAME" \
    --author "$ORG_NAME" \
    --description "Latest board for $ORG_NAME" 2>/dev/null &
fi
```

The publish script exits silently on failure, so the local open always succeeds regardless of API state. OSS/local mode skips this step entirely — the board stays local unless the user publishes explicitly.

**Auto-linked references (connected mode).** When `publish-artifact.sh` publishes a markdown file, any backtick-wrapped `memory/**/*.{md,html}` paths inside it are re-published in parallel at deterministic URLs (`egregore.xyz/view/{slug}/{m|h}-{12 hex}`) so the rendered parent view contains clickable links to each referenced file. See `bin/publish-references.sh`. No-op in OSS mode (the relay assigns random slugs, so the renderer falls back to plain `<code>`).

### 4. Report

```
✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/{type}-{name}-{ts}.html
```

For `/view board` in connected mode, append:
```
◆ https://egregore.xyz/view/{org_slug}/board   (stable — refresh for latest)
```
Read `org_slug` from `egregore.json`.

## Fallback

If the local CLI is unavailable and `npx egregore-artifacts` fails (not installed),
install it first:
```bash
npm install -g egregore-artifacts
```

## Ambiguity handling

If the name matches multiple files, use AskUserQuestion:
```
Found multiple matches for "security":
1. handoffs/2026-03/31-cem-oss-security-audit.md
2. quests/oss-security-review.md
Which one?
```

If no matches found, **fall through to synthesis mode** (see below).

## Synthesis mode

When the input is a prompt or topic rather than a file name — or when file resolution finds nothing — synthesize an artifact from multiple sources.

1. **Read relevant files** — search memory/, codebase, and conversation context for material matching the prompt. Read as many files as needed.
2. **Write a temporary markdown file** — synthesize the findings into a well-structured document at `/tmp/egregore-artifacts/synthesized-{slug}.md`. Use headings, lists, code blocks — the renderer handles all standard markdown.
3. **Render it** — `$RENDER document /tmp/egregore-artifacts/synthesized-{slug}.md` (renderer resolved as in §3)
4. **Report** — same as normal: `✓ Artifact opened in browser`

This is the default fallback — don't ask the user if they want synthesis. If `/view auth architecture` doesn't match a file, just do the research and render it.

**When to synthesize vs. when to say "not found":**
- Prompt is a topic/question ("auth architecture", "how does onboarding work") → synthesize
- Prompt looks like a filename that should exist but doesn't ("my-missing-doc") → say not found
- Use judgment — if the user clearly expects a specific file, don't synthesize a guess

## Examples

```
> /view quest artifact-generation

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/quest-artifact-generation.html
```

```
> show me the security audit visually

Resolving "security audit"...
  Found: memory/handoffs/2026-03/31-cem-oss-security-audit.md

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/handoff-31-cem-oss-security-audit.html
```

```
> /view memory/knowledge/decisions/auth-redirect.md

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/document-auth-redirect.html
```

```
> /view activity

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/activity-2026-04-06.html
```

```
> /view auth architecture

No file match — synthesizing from codebase...
  Reading: api/main.py, api/auth.py, api/services/supabase.py, ...

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/document-auth-architecture.html
```
