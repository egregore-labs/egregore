---
description: Turn the current working session into an expressive, self-contained HTML view of how it evolved — steady work as a quiet spine, decisions as forks showing the road taken beside the roads not taken. Use for "/session-view", "make sense of this session", "turn this session into an artifact", "show how this session evolved".
---

Topic: $ARGUMENTS

> **Placement note:** this skill lives under `.claude/skills/`, which Egregore syncs from
> upstream on `/update` — a downstream-only skill here can be clobbered. Durable home is
> `/contribute` (upstream framework) or encoding it as an emissary (last section). It is
> live and invocable on this branch now.

## When to invoke

User says: "/session-view", "make sense of this session", "turn this session into an
artifact", "show how today evolved", "what did we actually decide here", or asks for an
HTML record of the session.

Not this:
- **`/handoff`** — team recap addressed to a teammate, indexed in the graph, pinged to Telegram. Internal continuity, not a self-contained artifact.
- **`/wrap`** — personal session closure, no artifact.
- **`/emissary`** — hand a runnable process to someone else. (This skill is a candidate to *become* one — see below — but invoking it just renders the current session.)

## What it produces

One self-contained HTML file: a reading of the session as a **path** — steady stretches
you can scan, punctuated by the **forks** where it could have gone another way. The forks
are the point; that is where "how it evolved" lives. No build step, no dependencies,
dark-mode safe, hostable as-is. It is an *interpretation*, not a transcript dump or a flat
summary.

## The session data model (the contract)

Everything session-specific is one JSON object. The render function (in the bundled
`template.html`) knows nothing else. This same object is what an emissary's `intake` would
gather — the abstraction is shared across skill and emissary.

```jsonc
{
  "meta":  { "kicker", "title", "standfirst", "context" },   // context allows inline <b>…</b>
  "stats": [ { "n": "22", "label": "harvest agents", "accent": true } ],   // 4–8 items
  "spineIntro": "…",
  "spine": [ <move>, <move>, … ],          // ordered; the heart of the artifact
  "artifactsIntro": "…",
  "artifacts": [ { "file", "tag", "desc", "url?" } ],
  "note": "<b>On the shape of the work.</b> …",
  "foot": [ "left text", "right text" ]
}
```

A **move** is one of two shapes — this binary is the entire structural idea:

```jsonc
// steady work — quiet dot, collapsed to its lede
{ "type":"step", "phase":"Build", "title":"…", "lede":"…",
  "detail":"<p>html ok</p>", "chips":[ { "text":"…", "ext":true } ] }

// a decision or recovery — diamond node, branch always shown, renders expanded
{ "type":"fork", "phase":"The Gate",
  "decidedBy":"human",          // "human" | "agent"  (optional)
  "kind":"recovery",            // omit for a normal decision; "recovery" = snag-and-fix; "pivot" = change of direction
  "title":"…", "lede":"…",
  "taken":    { "label":"…", "meta":"2 wins · w4", "why":"why this path" },
  "notTaken": [ { "label":"…", "meta":"…", "why":"why not / what it would have cost" } ],
  "detail":"<p>optional collapsible prose</p>" }
```

The minimap, theme toggle, scroll-spy and progress bar are all generated from this object —
do not hand-author them.

## Procedure

### 1. Gather the session's evidence
Cheapest first:
- **The conversation itself** — primary source. The arc, the decisions, the dead ends, the snags are all here.
- **Git** — `git log --oneline` on the branch, `git diff --stat` vs base: what was produced.
- **Activity / graph** (connected mode only) — artifacts/handoffs/sessions this run created via `bin/graph.sh`. Skip in local mode.
- **Files written** — source of the `artifacts` list.

### 2. Extract into the data model — find the forks first
The skill's real work, and it is interpretive:
- **Identify the forks.** Every point the path could have gone another way: a choice between options, a pivot, a wrong turn reverted, a snag recovered. For each, name the **taken** path and the **road(s) not taken** with an honest *why*. A session with zero forks is suspicious — look harder. "I considered X, did Y" is a fork.
- **Everything between forks is a `step`.** One `lede` line; push specifics into `detail`/`chips`.
- **Order chronologically.** The shape should read at a glance — a clean run (mostly steps) and a debugging slog (mostly forks) should *look* different.
- **Stats** = honest scope, 4–8 items, 1–2 accented.
- **Artifacts** = what it left behind, with hosted URLs where they exist.

### 3. Render
Copy the bundled `template.html` (in this skill's directory) to an output path and replace
its `<script id="session-data" type="application/json">…</script>` block with the new
object. The render function + CSS never change. A helper exists in the project work:
`python3 vision-work/build_session_view.py <data.json> <out.html>` (it swaps that block);
inline substitution is equally fine. Output to the repo root as `session-view.html` (or a
session-named file).

### 4. Hand it over
`open <out.html>`. Then **offer — do not assume** — to host it
(`bin/publish-artifact.sh <type> <file> --raw-html --id <slug>`) and/or fold it into the
working branch / PR. Hosting is outbound; confirm first. Emit telemetry:
`bash bin/telemetry.sh emit "command" '{"command":"session-view"}' 2>/dev/null &`.

## The expressive contract (the taste, not just the data)

What separates this from a generated report. Hold these:
1. **Forks carry the meaning.** A flat list of steps has failed. The road not taken, with an honest reason, is the expressive payload.
2. **Steady work recedes.** Steps are quiet so forks stand out. Don't narrate every tool call.
3. **One authorial voice.** Write the prose; never paste tool output. Plain, exact, no business-document tone, no enumeration for its own sake.
4. **Honesty is texture.** Snags, reverts, wrong turns make the record *more* credible — render them as `recovery` forks, named plainly.
5. **Restraint.** Two move types are the whole vocabulary. Do not invent new card types per session.

## Relationship to the emissary (how this becomes portable)

The data model above *is* an emissary's payload (`docs/specs/emissary-architecture.md`). To
package this skill as an emissary, the `executable_spec` is:
- **`intake`** — the questions that fill `meta` and seed fork-finding: *what was this session about? where did you have to choose? what did you choose over what, and why?* (A receiver whose agent can read their own transcript/git reduces intake to confirmation.)
- **`action`** — the procedure above; the template shell travels inside the action so the receiver needs no build step.
- **`output`** — `{ "target": "receiver_artifact" }`: a self-contained `session-view.html` in their repo, in this hand.

This SKILL.md is the interpreter-side process; the emissary is the same process encoded as
data so another person's AI runs it on *their* session. Build the emissary only after this
skill is proven live — one component at a time.
