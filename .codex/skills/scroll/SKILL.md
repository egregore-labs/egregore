---
name: scroll
description: 'Compose and tend an Egregore living paper with an explanatory face, embedded decision harvest, stable published URL, and versioned paste-back update loop. Use when the user invokes /scroll or $scroll, asks for a living paper or a spec with questions inside, presents a proposal/architecture/product/feature with open forks, or pastes a versioned scroll decisions return block.'
---

# Egregore Scroll

Native Codex Egregore skill. Use only inside an Egregore checkout.

A scroll is one self-contained Meridian HTML artifact with two linked views:
the readable paper and the open decisions living inside it. Every return block
updates the same artifact at the same stable id.

Use `$view` for a static document with no pending decisions, `$harvest` for
elicitation without a published explaining face, and a concise question for one
small fork. A scroll requires all three legs: face, harvest, and update loop.

## Structured UX parity

The browser artifact is the primary output. Preserve both tabs, deep links from
honest costs into decisions, the versioned copydock fence, stable URL, and local
source path. Do not substitute a prose-only summary or expose raw publish output.

## Route the invocation

- A normal request creates version 1.
- A pasted block matching `#<slug>-decisions:v<N>` runs the update loop.
- If a pasted version is stale, absorb still-applicable answers and state which
  forks moved after that version.

Run inline with shell and filesystem tools. Do not invoke Claude Code commands
or Loom delegation.

## Build a new scroll

1. Read the source design, relevant memory, code, and quest context in full.
2. Derive a stable kebab-case slug of at most 50 characters. Create:
   - surface id `ds-<date>-<slug>`;
   - harvest id `harvest-<date>-<slug>`;
   - a short unique `<prefix>.harvest` browser storage key.
3. Copy `.codex/skills/scroll/assets/shell.html` into `tmp/<slug>/index.html`.
   Keep this build source in the worktree so future turns can tend it.
4. Inject the canonical design-system CSS at build time from
   `packages/egregore-artifacts/lib/vendor/design-system/dist/egregore-design.css`
   into `/*__MERIDIAN_CSS__*/`. If the packages tree is unavailable, extract the
   same path from `egregore-artifacts@latest` rather than freezing tokens.
5. Fill every placeholder and replace the `__FACE__` and `__HARVEST__` slot
   comments using the grammar documented in the shell.

### Write the face

Create a light paper, not a transcript dump:

- A paper header with kicker, title, italic subtitle, grounds, date, and
  `Version vN — updates in place at this URL`.
- The setting: current reality, load-bearing verified numbers, the gap, and a
  thesis reframe.
- Two to four genuinely different mental models that stress-test the design.
- The machine: concrete anatomy and protocol, using layers, steps, and
  tokenized SVG figures. Mark illustrative charts `shapes, not measurements`.
- Consequences for product or practice.
- Honest costs as cards. Every cost must call `goFork('<fork-id>')` and link to
  the harvest decision that prices it.

### Write the harvest

Create two to four bands of decision cards. Each card needs:

- a stable fork id, grounded framing, and a reference back into the face;
- two to four real options, each with one credible advantage and disadvantage;
- at most one starred lean, presented as a position to challenge;
- a why textarea whose note returns with the pick.

Add open prompts for material that is not a fork. Prefer questions grounded in
the work over meta-prompts asking what to ask next. The copydock must emit:

```text
#<slug>-decisions:v<N>
surface: <surface-id>
harvest: <harvest-id>
date: <date>

Q1 <fork-id>: <key>  ("<label>")   | UNDECIDED
   note: <why, verbatim>
O1 <prompt-id>: <text | UNDECIDED>
```

## Theme and asset constraints

Choose the default theme pair from the primary reader's recorded preference
when available: `sovereign`/`bedrock`, `meridian`/`nocturne`, or
`agronomic`/`soil`. Record a newly stated preference in that person's memory
profile.

Keep theme state on `<html data-theme>` and restore it before paint. In authored
body content and SVGs, every theme-sensitive fill, stroke, background, border,
and text color must use `var(--token)`. Do not emit inline hex colors. Preserve
the shell's persisted palette picker and print/mobile behavior.

Before publishing:

1. Confirm no `__[A-Z_]*__` placeholders remain.
2. Check tag balance and that every `goFork()` id has one matching
   `data-decision` card.
3. Grep authored content for raw hex and resolved inline palette values.
4. Capture both `file://...` and `file://...#harvest` views and inspect them.
5. Confirm headings use the intended display face rather than a system serif.

## Publish and record

Publish connected configurations to the permanent slug:

```bash
bash bin/publish-artifact.sh document tmp/<slug>/index.html --raw-html \
  --id <slug> --title "<title>" --author "<author>" \
  --description "<description>"
```

Verify the returned URL, open it, and report it. Every later version must reuse
the same `--id`; never mint a new URL for an update. In local mode, publishing
is unavailable: open the file locally and report the source path without
suggesting configuration changes.

Add the URL or local path, source location, version, and fence tag to the
relevant quest's log/artifacts tables. If no quest is relevant, keep the source
path as the durable record and state it.

## Update loop

On a returned fence:

1. **Absorb.** Parse Q/O lines and notes. Write durable decisions with their
   reasoning to `memory/knowledge/decisions/`, update the underlying spec or
   plan, and add connected HarvestTurn records when available. `UNDECIDED` is a
   valid answer.
2. **Rewrite the face.** Weave settled answers and reasoning into fresh prose,
   mark them `decided v<N> · <date>`, and update linked cost cards to accepted,
   mitigated, or remaining residuals.
3. **Regenerate the harvest.** Retire answered cards. Carry an undecided fork
   once at most; after two undecided returns, reframe it or demote it to an open
   prompt. If its note actually resolves it, absorb the note as the decision.
   Mint new forks from newly unlocked consequences, respondent requests, and
   new ground truth.
4. **Show, then ask.** When abstract forks run dry or the respondent asks for
   something concrete, place the draft under discussion directly in the
   harvest view with in-place reaction prompts.
5. **Version.** Bump every version marker, update the copydock, and append a
   one-line changelog with absorbed and newly opened forks.
6. **Republish.** Publish to the same stable id, update the quest record, open
   the refreshed URL, and state what changed and what the new version asks.

Multiple returns against one version are separate turns. Merge compatible
answers; turn conflicting choices into a new explicit fork instead of silently
resolving them.

## Voice and telemetry

Write the face as external-grade Egregore prose: declarative, precise, grounded
in real numbers, and honest about costs. Put metaphor in visuals rather than
labels; prefer established terms over coinages.

After completion, emit telemetry best-effort:

```bash
bash bin/telemetry.sh emit "command" '{"command":"scroll"}' 2>/dev/null &
```

Never call the deprecated `egregore-handoff` CLI.
