# Harvest — Audit & Rebuild Spec

> Harvest is a general elicitation primitive. It helps an agent ask better
> situated questions and turn the answers into organizationally usable context.
> It is not a survey engine, not a Spiral subroutine, and not a fixed
> interview template.

This document is the persistent design contract for `/harvest`. It was
written as the input that drove the rebuild of `.claude/skills/harvest/SKILL.md`
and the authoring of the sibling docs `PROCESS.md` and `FORMAT.md` — and now
continues to serve as the spec they implement. §13 is the historical record
of the rollout that landed this layout; the rest of the document is current.

---

## 1. Status before the rebuild

(Snapshot of the pre-rebuild state, kept here as the audit findings this
document was written to address. The rebuild — split into PROCESS.md /
FORMAT.md / a thin SKILL.md — landed alongside this audit.)

**Pre-rebuild file**: `.claude/skills/harvest/SKILL.md` (145 lines).
- Procedural Steps 0–6 with graph plumbing
- Connected-mode ops wired: `create-harvest`, `create-harvest-session`,
  `record-harvest-turn`, `complete-harvest` (`bin/graph-op.sh:285–365`)
- Step 4 said "Apply `skills/harvest/SKILL.md` from here" — but that path
  resolved back to the same file. There was no separate cognitive layer; the
  reference was recursive/self-referential. The file existed; the intended
  layer did not. PROCESS.md / FORMAT.md now provide that layer.

**Reference material (not a port target)**:
The prior harvest spec drafted in the spiral-skill workspace (215 lines)
had drifted toward claim-stress-testing objectives that don't belong in
harvest. We do **not** port it wholesale. We extract only the six reusable
elicitation moves it documents well:

- seed context
- generate situated questions
- evaluate answers
- checkpoint
- cascade carefully
- synthesize with evidence

Everything else — including any framing about "taking a stance,"
"recommending a direction," or treating divergence as something to be
resolved — belongs to Spiral, not Harvest. `PROCESS.md` is authored fresh
from this `AUDIT.md`, with the old spec consulted only as a craft library
for the six moves above.

**Aspirational outputs (gold fixtures)**:
- `memory/knowledge/harvests/2026-03-23-olivier-harvest-analysis.md`
- `memory/knowledge/harvests/2026-03-23-egregore-collective-intelligence-uniqueness.md`
- `memory/handoffs/2026-05/06-cem-harvest-oz-canvas-tech-and-capabilities.md`

These already exemplify the layered output shape (quote ▸ context ▸ reflection
▸ pattern ▸ action). The product knows what good looks like; the work is
making the command reliably reproduce it without the operator carrying the
form.

---

## 2. Primitive boundary

| Primitive | Core move | Input | Output |
|---|---|---|---|
| **Harvest** | Elicit latent human/agent context | task + roles + seed context | positions, preferences, tensions, quotes, decision surfaces |
| **Spiral** | Stress-test a claim | claim + context | refined claim, objections, surviving structure |

Spiral can consume harvest output or trigger a harvest. Harvest is broader:
context, preference, position, domain knowledge, alignment, stakeholder
needs, design taste, team memory. Spiral is pressure-testing claims. Harvest
is eliciting what people know, prefer, feel tension around, or are implicitly
carrying.

**Term hygiene.** Outside this section, `PROCESS.md`, `FORMAT.md`, and
`SKILL.md` should not use Spiral vocabulary — *claim*, *stress-test*,
*objection*, *survives critique*, *recommend a direction*, *take a stance*.
A short boundary section in `PROCESS.md` may name Spiral once to mark the
boundary; everywhere else, harvest stays in its own register: elicit,
preserve, situate, surface, interpret-with-evidence.

**What harvest is not**: a survey, a retrospective form, a performance
review, a structured-field data collector, a replacement for conversation,
a Spiral subroutine.

---

## 3. First-class design constraints

### 3.1 Model-led, not flowchart-led

> The model owns the next question. The protocol only requires that it can
> explain why the question is being asked, preserve the answer, and update
> its interpretation.

The spec defines invariants, affordances, and failure modes — not a rigid
interview script. There is no fixed round count, no fixed question count
per round, no required dimensions to cover. The model reads the situation,
generates the next question with an articulable purpose, evaluates the
answer, and decides whether to deepen, pivot, checkpoint, cascade, or
synthesize.

### 3.2 Primitive-level, not Spiral-specific

Harvest is the elicitation primitive. Anything that needs latent human or
agent context — onboarding, alignment, decision crystallization, knowledge
extraction, retrospective — can call harvest. Spiral, `/quest`, `/reflect`,
and `/onboarding` may consume harvest output. Harvest does not depend on any
of them.

### 3.3 Invariants (must hold for every harvest)

1. **No hidden role stereotyping.** Every implicit role inference is
   inspectable in the manifest *and* surfaced into the interaction when
   confidence is below threshold.
2. **No survey collapse.** AUQ options never exhaust the answer space.
   Every question carries a freeform escape hatch. Options are drawn from
   context, not prefab taxonomies.
3. **No unmarked cascade contamination.** When prior respondents' positions
   are disclosed to a later respondent, that disclosure is explicit. Blind
   vs. disclosed vs. comparative cascade is a deliberate choice per harvest.
4. **No synthesis without evidence.** Every assertion in synthesis traces
   to a recorded turn (or to seed context, marked as such). No
   interpolation the transcript can't support. (Here "assertion" means any
   factual statement in the artifact — preference, position, pattern,
   tension — not the Spiral sense of "claim under test.")

### 3.4 Anti-conflation test

Every protocol rule, invariant, and synthesis convention must make sense
for a **preference / context / taste** harvest — not just for a
claim-critique harvest. If a rule only justifies itself when there is a
proposition under attack, it belongs to Spiral, not Harvest.

Use these as scratch fixtures while drafting `PROCESS.md`:

- *"What's Cem's design taste for the artifact viewer?"* — pure preference,
  no claim, no convergence target.
- *"What is Oz carrying about the moat question?"* — tacit position, no
  decision being forced.
- *"What does Renc know about go-to-market constraints we haven't
  documented?"* — knowledge extraction, no stance to recommend.
- *"What do cem, renc, and oz each prefer for pricing?"* — alignment
  scan; divergence is information, not a problem to resolve.

If any rule fails to apply cleanly to all four, it's drifted into Spiral
territory and needs reworking.

### 3.5 Failure modes to design against

| Failure mode | What it looks like | Mitigation |
|---|---|---|
| **Survey collapse** | AUQ options bias answers; nuance flattens to picked labels | Options drawn from context; freeform escape hatch always; questions can be open-ended where AUQ would constrain |
| **Role calcification** | Inferred role becomes stereotype; respondent can't see or correct it | RoleSheet shows evidence + confidence; low-confidence inferences are surfaced into the question itself |
| **Cascade contamination** | Later respondents over-shaped by earlier ones | Disclosure mode (blind/disclosed/comparative) is chosen per harvest, recorded on the manifest, and visible to respondents |
| **Script drift** | Protocol becomes a flowchart the model rotely executes | Invariants over procedure; `questionIntent` is mandatory and reviewed; round count and shape are model decisions |

---

## 4. Architecture

Four artifacts under `.claude/skills/harvest/`:

1. **`SKILL.md`** — entry point. Orchestration only: parse args, detect
   mode, create IDs, load `PROCESS.md` and `FORMAT.md`, persist state, exit.
   No cognitive logic.
2. **`PROCESS.md`** — the cognitive protocol. Authored fresh from
   `AUDIT.md`; consult the old harvest spec only for the six reusable
   elicitation moves (seed, generate, evaluate, checkpoint, cascade,
   synthesize). Covers role asymmetry, AUQ round protocol, async bridge,
   and resume.
3. **`FORMAT.md`** — the synthesis grammar. Layered disclosure rules, modality
   palette, generative emission policy.
4. **Memory contract** — documented markdown shape for manifest, session,
   turn, async question, and synthesis files. Lives as a section in
   `PROCESS.md`; not a separate doc.

The current SKILL.md's recursive self-reference ("intelligence lives in
skills/harvest/SKILL.md") is the first thing to remove.

---

## 5. Three-column model: Guidance · Tooling · Discretion

Frame the rebuild not as procedure but as the relationship between what the
spec *prescribes*, what the system *provides*, and what the model *decides*.

| Guidance (model reads, qualitative) | Tooling (system provides, concrete) | Discretion (model decides) |
|---|---|---|
| Role asymmetry — sender vs. receiver | RoleSheet schema and resolution helpers | How much context to include with each question |
| Anti-bias — when to disclose, when to withhold | AUQ rounds (1 call/round, headers ≤12 chars) | Round count; question count per round |
| Cascade disclosure choices | `questionIntent` + `evaluation` recorded per turn | Disclosure mode for cascade (blind/disclosed/comparative) |
| Synthesis grammar (layers + modalities) | Async question metadata (`harvest_id`, `harvest_session_id`, `turn`, `context_mode`, `status`) | Which synthesis layers and modalities to emit |
| Failure mode awareness | Markdown/session state (local mode), graph nodes (connected mode) | When to checkpoint, deepen, pivot, synthesize |

---

## 6. RoleSheet — sender/receiver asymmetry

Question generation takes both sheets as input, not just the receiver's.
Self-harvest is the degenerate case where sender == receiver.

```
RoleSheet {
  handle:           string         # e.g. "renc"
  explicit_role:    string?        # from memory/people/{handle}.md frontmatter
  explicit_focus:   string?        # declared current focus / domain
  recent_threads:   [string]       # last-N session topics, quest names
  likely_lenses:    [string]       # inferred analytical orientations
  evidence:         [string]       # paths/quotes that justify each inference
  confidence:       low|med|high   # per implicit field
}
```

**Resolution**:
- *Explicit*: read `memory/people/{handle}.md` frontmatter and prose.
- *Implicit*: read recent handoffs/sessions/quests where this person
  appears. Local mode reads files; connected mode queries the graph.

**Surfacing into the interaction (anti-calcification)**:
- High confidence: the inference shapes the question silently.
- Low/medium confidence: surface the inference into the question itself —
  *"I'm reading you as approaching this from the eng-lead lens — push back
  if that's wrong."* Respondent can correct in one turn.

**Generation input** (per turn):
```
generate_question({
  sender:        SenderSheet,
  receiver:      ReceiverSheet,
  task:          string,
  intent:        string,
  seed:          [Document],
  prior_turns:   [Turn],
  open_threads:  [string],
})
```

The vector matters. `cem-asks-renc-about-pricing` ≠
`renc-asks-cem-about-pricing`. The asymmetry is what lets harvest produce
*situated* questions instead of generic ones.

---

## 7. AUQ round protocol

The protocol is an affordance, not a script.

**Per round (mandatory)**:
- One AUQ call.
- 1–3 questions (model decides; usually 2).
- Each question: short header (≤12 chars), 2–3 generated options drawn from
  context, freeform escape hatch always available.
- Internally record per question: `questionIntent`, `expectedSignal`.
- After the call: record `evaluation` per answer (novel framing /
  unresolved tension / shallow / strong conviction / surprising connection /
  diminishing returns).
- Decide next: continue · deepen · pivot · checkpoint · cascade · synthesize.

**Forbidden in round 1**:
- Leading questions that presuppose a position.
- Disclosing other respondents' answers (unless the harvest's disclosure mode
  explicitly permits it).
- Asking what the seed already answers.

**Always permitted**:
- Asking the respondent to reframe the harvest's intent.
- Asking what the model *should* be asking that it isn't.
- Ending early ("I'm done") at any checkpoint.

The graph already supports `questionIntent` and `evaluation` on
`HarvestTurn` (`bin/graph-op.sh:320`). We use what's there.

---

## 8. Synthesis — layered disclosure + modality palette

> **Harvest produces a decision surface, not necessarily a decision.**

For some harvests the output is *"Cem prefers X because…"*, *"Oz sees the
boundary this way…"*, *"Renc is carrying a go-to-market constraint we
haven't documented…"* — useful organizational context even when no
proposition is being tested and no recommendation is appropriate.
Synthesis interprets-with-evidence; it does not have to converge,
recommend, or pick a winner.

### 8.1 Layers (progressive disclosure)

| Layer | Required? | Contents |
|---|---|---|
| **L0 — Portrait** | Always | One sentence that holds the most: the sharpest finding, preference, or position the harvest produced. No "stance" obligation — for a preference harvest, this is the strongest preference; for an alignment scan, it's the central pattern. |
| **L1 — Surface** | If the harvest produced anything decision-shaped | Convergence, divergence, open questions, *and* — only where relevant — recommended action. Divergence is presented as information, not a problem to resolve. |
| **L2 — Person-position** | If multi-respondent or deep elicitation | Per-position section using the modality palette below |
| **L3 — Transcript** | Always (appendix) | Full turn log with `questionIntent` and `evaluation` per turn |

L0 and L3 are mandatory. L1 and L2 emit only when supported. "Generative"
means *which layers and which sections within them exist* depends on what
was harvested.

### 8.2 Modality palette (within L2 sections)

Each position can mix any of:

- **quote** — verbatim, attributed
- **context** — what the operator/model brings to make the quote legible
- **reflection** — interpretation; what this position *does* to the broader
  picture
- **decision surface** — concrete choice or commitment
- **open question** — unresolved tension worth a follow-up harvest
- **pattern** — knowledge / action / antipattern extracted, ready for
  `/reflect` to consume

The Olivier and Oz fixtures already use this palette. Codify it; don't
prescribe order.

### 8.3 Synthesis output is `/reflect`-able

Patterns, preferences, positions, and (where present) decisions emit in a
shape the org's pattern/decision graph can ingest. The harvest is not a
leaf artifact — it is an entry into organizational reasoning. For a pure
preference harvest, this means the output node is *"cem prefers X because
Y, evidence: turn-3 quote"* — a tacit-knowledge artifact other agents can
reason from. For an alignment scan, it's a divergence-map node. The shape
varies; the legibility doesn't.

This is also the answer to *"why harvest"* for the receiver: their tacit
context became something the org can now hold.

---

## 9. Async bridge — extending `/ask` for harvest re-entry

Async harvest doesn't just "deliver via `/ask`." When a respondent isn't
present, harvest emits a question file using `/ask`'s existing markdown
shape, *plus* harvest metadata so the answer re-enters the right harvest:

```yaml
---
from:                cem
to:                  renc
topic:               pricing
status:              pending      # pending | answered | incorporated
date:                2026-05-07

harvest_id:          harvest-2026-05-07-pricing
harvest_session_id:  harvest-2026-05-07-pricing-renc
turn:                3
question_intent:     "Renc's stance on free-tier ceiling vs. wedge"
context_mode:        disclosed    # blind | disclosed | comparative
---

## Questions

1. [Wedge] {generated text}
2. [Ceiling] {generated text}
```

`bin/agent.sh ask` currently writes only `from / to / topic / status /
created` (`bin/agent.sh:241`). Extend it (or have `/harvest` write
harvest-flavored question files directly) so the async bridge is
re-entrant.

When the respondent answers via `/ask`, the answers append to the file and
status moves `pending → answered`. The next time `/harvest` runs and finds
its session has `answered` files, it incorporates them, sets status to
`incorporated`, and continues toward synthesis.

**Async initial state**: `create-harvest-session` (`bin/graph-op.sh:307`)
accepts an optional 4th `[status]` argument validated against
`pending|active|answered|complete|incorporated`. Async respondents are
created with `pending` and transition to `active` when they engage; default
remains `active` for back-compat with synchronous callers.

---

## 10. Local-mode contract

Local mode never references graph failures. It writes durable markdown.

```
memory/knowledge/harvests/{date}-{slug}/
  manifest.md             # harvest-level: id, topic, intent, initiator,
                          # respondents, disclosure_mode, status
  sessions/
    {handle}.md           # per-respondent: turns inline, frontmatter status
  synthesis.md            # the layered output (L0..L3)
```

For single-session harvests (the common case), the existing flat file at
`memory/knowledge/harvests/{date}-{slug}.md` remains valid — it collapses
manifest + session + synthesis into one. The directory shape is opt-in for
multi-respondent harvests.

`/ask`'s local-mode pattern (`.claude/skills/ask/SKILL.md:36`) is the model
to follow: clear local/connected split, no graph-failure messaging in local
mode, durable markdown is the source of truth.

---

## 11. Resume protocol

Harvests span days. Re-entry is a first-class flow.

- `/harvest --resume {harvest_id}` — explicit resume.
- Implicit resume: `/harvest <topic>` matches an existing active harvest →
  surface it and ask whether this is continuation or fresh start.
- Per session: `pending` (not yet engaged) · `active` (in progress) ·
  `answered` (async answers received, not yet incorporated) · `complete`.
- The harvest is `complete` only when synthesis is written and linked.

---

## 12. Eval fixtures

Pin two harvests as gold:

1. `memory/knowledge/harvests/2026-03-23-olivier-harvest-analysis.md`
2. `memory/handoffs/2026-05/06-cem-harvest-oz-canvas-tech-and-capabilities.md`

Regeneration must reproduce, given the same intent + RoleSheets + seed:

- L0 portrait present, single sentence, names the sharpest finding
- ≥3 named patterns (knowledge / action / antipattern) where the source
  fixture has them
- Direct quotes attributed by handle
- L1 surface populated when divergence or convergence existed; absent
  cleanly when the harvest was pure preference / context
- No leading questions in round 1 (check `questionIntent` log)
- Every L2 assertion traces to a recorded turn or marked seed

These are not unit tests. They are reference outputs the rebuild is judged
against. If the regenerated artifact fails any of these, the rebuild isn't
done.

---

## 13. Rollout (historical record)

The order in which the rebuild landed. Steps 1–7 shipped together; step 8
remains as the empirical proof the rebuild reproduces the gold fixtures.

1. ✓ Land this `AUDIT.md`.
2. ✓ Rewrite `.claude/skills/harvest/SKILL.md` as a real entry point. Move
   cognitive content out.
3. ✓ **Author `PROCESS.md` fresh from this `AUDIT.md`.** Did not port the
   prior spiral-context harvest spec wholesale. Used it only as a craft
   library for the six reusable moves (seed, generate, evaluate,
   checkpoint, cascade, synthesize). Every protocol rule was run through
   the §3.4 anti-conflation test before keeping it. Spiral vocabulary
   stripped except in a short boundary section.
4. ✓ Write `FORMAT.md` from §8 using Olivier + Oz harvests as fixtures.
5. ✓ Document the local-mode markdown contract (§10) inside `PROCESS.md`.
6. ✓ `bin/graph-op.sh create-harvest-session` accepts an optional
   `[status]` argument with enum validation (§9).
7. ✓ `bin/agent.sh ask` extended with harvest-flavored frontmatter
   fields per §9 (`--harvest-id`, `--harvest-session-id`, `--turn`,
   `--question-intent`, `--context-mode`).
8. Run regeneration against fixtures (§12). Iterate until all pass.

The Olivier and Oz harvests are the bar. The product already knows what
good looks like; the rebuild is making the command reliably reproduce it
without the operator carrying the form.

---

## 14. Decision surface — rendered mode + round-trip

The `decision surface` modality (§8, FORMAT.md) gained a **rendered, fillable
form**. `/harvest` is the only command: when its findings are decision-shaped, it
renders them as a *decision surface* — the rendered format/artifact the respondent
decides on and pastes back. *Decision surface* names the **format**, not a command;
there is no `/decision-surface` command (everything merges into `/harvest` — one
verb, one grammar).

**Resolution** — matches the original directed-vs-self intent:
- Invoked on yourself (no `--to`) → **self-harvest**, rendered: surface your own
  decisions, fill, paste back into the session.
- Sent to someone (`--to <name>`) → **directed harvest**: render + deliver; their
  filled-in choices return as the answer.

### Renderer

`decision-surface` is a first-class artifact type in `packages/egregore-artifacts`
(`lib/parsers/decision-surface.js`, `lib/templates/decision-surface.js`, registered
in `lib/index.js`; `decision-surface` added to `bin/cli.js` known types). It renders
the data model — `decisions[] → {id, title, context, options[{key, label, visual,
tradeoffs[{t,text}], recommended}]}` — as an interactive surface: option cards, a
structural visual per option, honest `+/−` tradeoffs, at most one recommendation,
selection state, a progress bar, and a copy-back button. Locked to the **meridian**
palette by the design-system route. Styled with **role tokens only** (`--t1` decided,
`--t2` plus, `--t3` minus, `--ink/--paper/--line/--card`) — dark-mode-safe, no
resolved hex. The output is fully self-contained (CSS + behavior inlined): fillable
from a file, a published URL, or embedded in an emissary, with **no egregore runtime
needed to fill it** — only to absorb.

### Round-trip — the return contract

The paste-back block is the **transport-agnostic return contract**:

```
#{slug}-decisions:v1
surface: {surface_id}
harvest: {harvest_id}      # directed surfaces only — re-keys to the HarvestSession
source: {source}
date: {YYYY-MM-DD}

Q1 {decision-id}: {option-key}  ("{label}")
   note: {reasoning}
Q2 {decision-id}: UNDECIDED
```

This is the same shape already in field use (`#…-decisions:v1`). It self-identifies
the surface/harvest it answers, so it re-keys deterministically over *any* channel.
On `--resume`: re-key, record each choice as a `HarvestTurn` answer (`note` = the
rationale), apply resolved decisions to `source`, log to
`memory/knowledge/decisions/` if others will build on them, synthesize. `UNDECIDED`
stays open — never forced.

### Two transports — one payload

| Transport | For | Status |
|---|---|---|
| **Copy-back → harvest channel** | egregore users, local-first | **Built.** Block returns via `/ask`→`/answer`→`/harvest --resume`. Works offline; no server. |
| **Emissary respond (`kind: decision`)** | people **without** egregore who want to pass surfaces back and forth | **Designed, not built.** Carries the *identical* paste-back payload as an emissary response (`packages/egregore-emissary` `respond`, threaded via `parents`). Because the surface and the return contract are transport-agnostic, this is a delivery/return swap — **no renderer rework**. |

**Invariant — transport-neutral:** the renderer and the return contract must stay
transport-neutral. A change that couples the surface or the paste-back block to the
harvest channel specifically (rather than to the abstract "selections + notes,
re-keyed by surface/harvest") breaks the deferred emissary path and must be rejected.

**Invariant — no author markup:** a directed surface is published and sent to other
people, so the renderer must never inject author-supplied HTML/SVG. Visuals use a
closed, structured schema (`mono` token spans, `badges`, `diagram` primitives)
rendered as escaped React elements with allowlisted tones — no `dangerouslySetInnerHTML`
for any data-derived content. The only `dangerouslySetInnerHTML` permitted is the
static CSS/behavior strings and the config object (`JSON.stringify`, with every
`<` escaped to its unicode form so a malicious value can't break out of the
`</script>` tag), whose values are only ever written back via `textContent`.
Re-introducing a raw-HTML/SVG visual path is a security regression and must be
rejected.

### Rollout (this change)

1. ✓ `decision-surface` renderer added to `packages/egregore-artifacts` (parser,
   template, index + CLI registration), role-token / dark-mode-safe, meridian-locked.
2. ✓ Verified end-to-end (object + JSON-file + markdown-embedded paths) and
   screenshotted in light + dark.
3. ✓ Rendered-surface mode folded into `/harvest` SKILL.md (the only command;
   `decision surface` is the rendered format, not a command — no
   `/decision-surface` command).
4. ✓ `SKILL.md` + `FORMAT.md` updated: rendered mode, absorb-on-resume,
   strategic surface-design guidance, promoted modality.
5. ◻ **Deferred:** emissary `kind: decision` + `respond` extension for the
   non-egregore transport.
6. ◻ **Deferred:** publish `egregore-artifacts` with the new type so
   `npx egregore-artifacts decision-surface` resolves (prototype renders via the
   local package). This is a framework change — land it via `/contribute`, not a
   local edit, before relying on the published path.
