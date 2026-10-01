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

## Runtime source boundary

Resolve deictic requests from the current conversation before organizational
retrieval. When `this`, `that`, `it`, or `the above` unambiguously refers to
the single artifact just created, accepted, or shown, reuse its full content
already in context and stage it verbatim. If that content is collapsed or the
prior receipt supplies only a canonical path, open that exact path once through
`bin/search.sh open`; do not run `bin/search.sh query` to rediscover a known
artifact.

Resolve organizational sources from the attached authorized
`EGREGORE_ORG_CONTEXT_V1` block first. Do not repeat its retrieval or reopen
its already opened sources. When the requested source is absent, run one
Runtime query and open the selected canonical file through
`bin/search.sh open`; do not use raw `ls`, `find`, or graph traversal as an
authorization bypass. Local rendering is the default. Publishing or replacing
a stable hosted view requires an explicit `SHARE` request and checkpoint.
Never publish from an ordinary view request.

## Loom routing

Claude Code: use this Loom routing section. Other harnesses continue with
Rendering mode below.

Skip this section when the prompt contains `LOOM-EXECUTOR`; execute the
authorized render directly and never re-delegate.

Explicit `--compose`, designed/flagship, or client-facing requests remain
main-loop-only: render inline, then print
`bash bin/loom.sh footer view --override` and mark telemetry as an override.
For the deterministic renderer:

1. Resolve `ROUTE=$(bash bin/loom.sh route view)`. When `bin/loom.sh` is not
   present (Loom is internal-only and does not ship in the OSS distribution),
   skip route resolution and the footer entirely and follow the script route
   below — it is the framework default and needs no Loom.
2. **Script route (`"mode": "script"` — the framework default).** Judgment
   stays in the main loop: resolve what the user means into a type and source
   (the Resolution logic below). Then run the mechanics with no model in the
   loop — one call, which stages the source through the Runtime read boundary,
   serves repeat views from a content-addressed cache, renders, and opens:
   `bash bin/view-render.sh <type> <memory/...-or-file> [-- --brief <path>]`.
   Print its output verbatim, then `bash bin/loom.sh footer view`. Do not
   spawn a subagent, re-open the source yourself, or re-run retrieval for the
   render. If the script exits non-zero, report its error; only a composition
   or interaction need justifies taking over inline.
3. For an inline route, continue below in the main loop.
4. For a delegate route (org override), delegate only when available and
   permitted in this session; otherwise continue inline. When delegating,
   spawn `loom-executor` at the returned tier with `LOOM-DECISION-ID`, `LOOM-EXECUTOR: Execute
   .claude/skills/view/SKILL.md`, the user's exact arguments, and the attached
   `EGREGORE_ORG_CONTEXT_V1` block verbatim; print its final output, then
   `bash bin/loom.sh footer view`. On `LOW_CONFIDENCE:` take over inline.
5. Emit telemetry best-effort from the driver:
   `bash bin/telemetry.sh emit "command" '{"command":"view","routed":true}' 2>/dev/null &`.

Loom transports the authorized context; it never grants new read or SHARE
authority. The minion workflow is unrelated to this render route.

## Rendering mode

Use the packaged deterministic renderer by default, driven through
`bin/view-render.sh` — rendering is mechanical, so no model belongs in that
path. Run inline composition only when the user explicitly requests it. A
normal “view/open/render this” uses the script route without duplicate
retrieval. A repeat view of unchanged content reports
`(served from render cache)` — that is expected, not staleness: the cache key
is the content bytes, the renderer, and the arguments.

## Supported artifact types

- `quest` — renders quest markdown from `memory/quests/`
- `handoff` — renders handoff markdown from `memory/handoffs/`
- `activity` — renders live team activity dashboard (no file needed)
- `board` — renders the typed live project-board surface (interactive editor with 5 tabs: Activity / Priority / Person / Timeline / Done). Publishing the stable hosted board is a separate explicit action.
- `network` — renders people/relationship network (no file needed)
- `document` — renders any markdown file with branded styling (auto-detected fallback)

## Resolution logic

The key job of `/view` is resolving what the user wants to see into a file path. This must work without a graph.

### 1. Parse the arguments

- `/view quest artifact-generation` → type=quest, name=artifact-generation
- `/view handoff oss-security-audit` → type=handoff, name=oss-security-audit
- `/view activity` → type=activity, no file needed
- `/view board` → type=board, typed live surface; no source path resolution
- `/view network` → type=network, no file needed
- `/view artifact-generation` → no type specified, search all types
- `/view memory/knowledge/decisions/some-decision.md` → direct file path
- `show me the security audit visually` → extract keywords, search

### 2. Resolve the file

**Direct canonical file path**: If the argument names `memory/...`, open it
through `bash bin/search.sh open "memory/..."` into a temporary render source.
A denied or missing source stops resolution; never pass the raw canonical path
to the renderer or fall through to an unchecked filesystem read. An explicit
non-memory path inside the current repository may be rendered as a repository
document, but it is never treated as organizational memory.

**Quest, handoff, document, or auto-detected name**: Prefer the best matching
canonical source and opened content already present in
`EGREGORE_ORG_CONTEXT_V1`; stage that content as a temporary render source
without reopening it. Otherwise run one ranked call, optionally including the
requested type in the concept, then open only the selected result into the
temporary render source:

```bash
bash bin/search.sh query "<artifact name and optional type>" -n 6 --compact --context-packet
bash bin/search.sh open "<selected memory/... path>"
```

Claude Code: `--compact --context-packet` keeps the ranked evidence out of the
visible transcript — the resolution query must never print result blocks
before the render. Pass the selected source to the renderer script as its
`memory/...` canonical path, never as an absolute filesystem path.

Infer the renderer type from the selected canonical path. If several results
are genuinely ambiguous, show the short choices rather than scanning the
repository again.

**Activity**: No file resolution needed — runs `bin/activity-data.sh` live.

**Board / Network**: Use only the renderer's typed Runtime-backed live surface;
do not pre-scan or pre-open memory files.

**Auto-detect type** (no type specified): infer `quest` or `handoff` from the
authorized result path; everything else is `document`.

### 3. Generate and open

**On the script route, `bin/view-render.sh` owns everything in this section**:
it resolves the packaged renderer locally (checked-out
`packages/egregore-artifacts` first, then the installed `egregore-artifacts`;
never `npx`, never a registry fetch), stages complete `memory/...` documents
through the existing authorized `Runtime.open_source` adapter (ordinary model
evidence reads remain bounded), serves unchanged content from the content-addressed
render cache, invokes the renderer exactly once with `--output`, and opens the
browser. Call it once with the resolved type and source; do not re-implement
these steps inline. The commands below describe what the script does and are
the inline fallback only when the resolved route is `inline`.

**Design trace (documents).** A `document` render should follow the design
trace, not ship bare: auto-walk the UGI synthesis graph from the document's
substance (five stage ids — objective · audience · register · palette ·
grammar; option ids and auto-walk rules in
`packages/design-system/generative-ui/skill/SKILL.md`), resolve the brief, and
pass it to the renderer:

```bash
bash bin/node-run.sh --input-type=module -e "
import { resolveBrief } from './packages/design-system/generative-ui/resolve-brief.js';
import fs from 'node:fs';
fs.mkdirSync('tmp', { recursive: true });
fs.writeFileSync('tmp/view-brief-{slug}.json',
  JSON.stringify(resolveBrief(['{objective}','{audience}','{register}','{palette}','{grammar}'])));
"
bash bin/view-render.sh document <memory/...-or-file> -- --brief tmp/view-brief-{slug}.json
```

Picking the five ids is judgment and stays in the main loop; the brief file
rides into the render through `--` and participates in the cache key.

Pick the five ids from the substance, one line of judgment each (e.g. a
strategy prep doc → decide · operators · editorial · vellum · decisive; a
public explainer → persuade · newcomer · marketing · loam · quiet). The brief
drives palette + grammar treatment; the designed layout (nav · hero · anchored
sections) renders regardless. If the checked-out generative-ui layer is
unavailable, render without `--brief`; never fetch it or block on the trace.

The deterministic renderer already owns its light/dark theme contract. Do not
invoke or reread a separate visual-theme skill for an ordinary render. Apply
the Dark Mode contract only while authoring composed HTML or changing renderer
code.

### Composition path (`--compose`) — band 5, main-loop only

The template above is the **floor**. `--compose` is the **ceiling**: the design
trace at full depth means COMPOSITION, not pass-through (D6 free-generative band
— how the reference pages were made). The template renderer can never reach it;
composition is the frontier model authoring the page from the substance. This
path is what makes that reachable from the command instead of only by accident.

This path fires only on explicit cues: `--compose`, "compose / make it
presentable / client-facing / flagship / with the design trace / use the design
trace / designed artifact / band 5". **When the user names "the design trace,"
they mean this composed ceiling — never the floor.** Otherwise use the local
deterministic renderer.

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
bash bin/view-render.sh <type> <memory/...-or-file>
```

For auto-detected (just a file path):
```bash
bash bin/view-render.sh document <memory/...-or-file>
```

For activity (no file — live surfaces are never cached):
```bash
bash bin/view-render.sh activity
```

**For an explicitly requested publish:** local render/open is already complete.
Authorize `SHARE` for the exact staged artifact and show a Publish / Cancel
checkpoint containing the organization, destination, title, source, and
whether a stable URL will be replaced. After approval, invoke the Runtime
publication adapter once. `/view` does not inspect hosting configuration or
manage publication transport itself. If no Runtime publication adapter is
available, keep the local artifact and say publishing is unavailable rather
than falling back to a legacy script. Notification consent remains separate.

### 4. Report

Report the exact HTML path returned by the renderer or written by composition;
do not infer a filename from the examples below.

```
✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/{type}-{name}-{ts}.html
```

Only after an approved SHARE action returns a URL, append:
```
◆ https://egregore.xyz/view/{org_slug}/board   (stable — refresh for latest)
```
Read `org_slug` from `egregore.json`.

## Fallback

If the local renderer is unavailable, report that the instance renderer needs
installation or repair. Do not install or fetch software implicitly.

## Ambiguity handling

If the name matches multiple files, ask with a structured question when available and permitted in this session; otherwise ask in plain text:
```
Found multiple matches for "security":
1. handoffs/2026-03/31-cem-oss-security-audit.md
2. quests/oss-security-review.md
Which one?
```

If no matches found, **fall through to synthesis mode** (see below).

## Synthesis mode

When the input is a prompt or topic rather than a file name — or when file resolution finds nothing — synthesize an artifact from multiple sources.

1. **Reuse authorized evidence** — start from `EGREGORE_ORG_CONTEXT_V1`. If it
   is absent or insufficient, run Runtime Observe once through
   `bin/search.sh query`; open only a selected returned canonical source through
   `bin/search.sh open`. Never scan `memory/`. Read repository files only when
   the user explicitly asked to synthesize codebase material.
2. **Write a temporary markdown file** — synthesize only the authorized
   evidence into `tmp/view-synthesized-{slug}.md`. When the
   attached context already contains opened content, stage that content without
   reopening its canonical source.
3. **Render it** — `bash bin/view-render.sh document tmp/view-synthesized-{slug}.md`
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
  Reading: api/main.py, api/auth.py, api/services/storage.py, ...

✓ Artifact opened in browser
  File: /tmp/egregore-artifacts/document-auth-architecture.html
```
