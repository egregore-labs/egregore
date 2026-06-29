# Harvest — Synthesis Format

> Format is a grammar, not a template.
>
> The model chooses **which layers exist, which sections within them
> exist, and which evidence modalities to use** based on what the
> harvest produced. Two harvests with different intents and different
> respondents should not produce the same shape.

This document is the **synthesis runtime contract** for `/harvest`. It
is the companion to [`PROCESS.md`](./PROCESS.md). Where `PROCESS.md`
defines how the model conducts the conversation, this defines how the
model formats what was elicited so it becomes organizationally usable
context.

For the protocol's invariants, anti-conflation fixtures, and cognitive
moves, see `PROCESS.md`. This document does not re-state them.

---

## 1. What synthesis is and isn't

Synthesis is a **deliberate act** of reading the running interpretive
state, all turns across all sessions, and emitting a layered artifact
that:

- **Interprets with evidence.** Every assertion ties to a recorded turn
  or marked seed. Quotes are verbatim and attributed. Patterns name the
  turns they're extracted from.
- **Layers disclosure.** Readable at multiple depths. The shortest read
  is one sentence. The longest read is the full transcript.
- **Stays in harvest's register.** Surfaces what was elicited;
  organizes it for legibility. Carries no obligation to converge,
  recommend, or pick a winner. Divergence is information.

Synthesis is **not** a report card, a recommendation memo, a meeting
minutes file, or a verdict. The boundary stated in `PROCESS.md` §1
applies here: a harvest produces a *decision surface, not necessarily
a decision*.

---

## 2. The four layers

Synthesis is structured as a progressive disclosure stack. A reader
should be able to stop at any layer and have learned something
complete at that depth.

### L0 — Portrait

**Always present.** One sentence (sometimes two) that holds the most.
The sharpest finding, preference, or position the harvest produced.

L0 carries no obligation to recommend or pick a winner. For different harvest shapes:

- Preference harvest → the strongest preference, with the load-bearing
  reason in a clause: *"Cem prefers card-first L0 expanding to
  narrative+rail because the rail keeps decision surfaces visible
  while the narrative does the work."*
- Alignment scan → the central pattern across respondents: *"All
  three converge on free-tier-as-conversion; they diverge on the
  ceiling — and the divergence tracks how each models acquisition
  cost."*
- Knowledge extraction → the single most load-bearing thing the
  respondent knew that wasn't documented: *"Renc has been carrying
  three GTM constraints not yet on the canvas, and one of them
  (legal-coupling) gates the launch sequence."*
- Decision crystallization → the decision and its rationale: *"Split
  Hermes into harness + runtime; the harness is vendor-replaceable,
  the runtime is the differentiator we own."*
- Tacit position → what the person was carrying: *"Oz reads the moat
  as substrate-as-convention, not feature ownership — a position the
  product language hasn't picked up yet."*

L0 is read first. If a reader reads only L0, they have learned
something true and useful.

### L1 — Surface

**Optional. Emit when the harvest produced anything decision-shaped or
divergence-shaped.**

L1 organizes findings at the harvest level (not per-respondent,
not per-question). Sections that may appear, in any combination:

| Section | When it appears |
|---|---|
| **Convergence** | Multi-respondent harvests where positions aligned on something worth naming |
| **Divergence** | Multi-respondent harvests where positions split — presented as information, with each side's reasoning, not as a problem to resolve |
| **Open questions** | Harvests that surfaced more questions than they answered (this is a valid outcome) |
| **Action surface** | Optional and only when warranted; harvests with no proposition to act on may have no action surface. Records actions a respondent named or that a divergence implies — not actions the synthesizer invents. |
| **Tensions** | Internal contradictions a single respondent surfaced — useful for self-harvests and deep elicitations |

A pure preference harvest typically has no L1. A taste elicitation
typically has no L1. An alignment scan usually has a thick L1 of
convergence + divergence. An async multi-respondent harvest usually
has an open-questions section. **The model picks which sections fit.**

### L2 — Per-unit detail

**Optional. Emit when there is per-unit content worth standing alone.**

L2 is where the substance lives. The model chooses **which unit to
slice on**:

- **Per-respondent (position-unit)** — one section per person, each
  containing their positions across the harvest's dimensions. Use
  when the harvest produced person-distinctive positions. Olivier's
  harvest is the canonical example: `Olivier on scaling`, `Olivier on
  transmission`, `Olivier on bootstrapping`.
- **Per-question (question-unit)** — one section per question, each
  containing what was elicited about that question (one or many
  respondents). Use when the harvest was structured around concrete
  asks with concrete answers per question. The Oz canvas harvest is
  the canonical example: `Q1 — Hermes framing`, `Q2 — sovereign brain
  cards`, etc.
- **Per-dimension (theme-unit)** — one section per theme/dimension
  that emerged across questions and respondents. Use when the harvest
  surfaced cross-cutting themes the questions didn't directly target.
  Common in retrospectives.

The model picks one slicing. Mixing slicings within one harvest is
allowed only when the structure genuinely requires it (e.g.,
dimension-unit for thematic findings + question-unit for concrete
decisions). Default to one.

Inside each L2 section, content is built from the **modality palette**
(§3). Section structure is generative, not templated.

### L3 — Transcript

**Always present (appendix).** The full turn log.

For each turn:

- Question (verbatim)
- `questionIntent` — the model's articulable purpose
- Answer (verbatim, or pointer to async file)
- `evaluation` — the model's read (novel framing, unresolved tension,
  tacit content, shallow signal, strong conviction, surprising
  connection, diminishing returns)

L3 is the auditability layer. Anyone reading L0–L2 can drop to L3 to
verify the chain: which assertion came from which turn, what the
model intended when it asked, how the model read the answer. This is
also what makes the synthesis reproducible in fixtures (see §6).

---

## 3. The modality palette

Within L2 (and sometimes L1), content is built from these six
modalities. They compose; sections pick whichever fit.

| Modality | What it is | When it carries weight |
|---|---|---|
| **quote** | Verbatim words from a respondent, attributed by handle | Distinctive framing, strong conviction, language worth carrying as-is |
| **context** | What the synthesizer brings to make the quote legible — background, what was happening before, what assumption the respondent was responding to | When the quote is sharp but its meaning depends on context the reader may not have |
| **reflection** | Interpretation: what this position *does* to the broader picture; what mental model it implies | When a position has implications beyond what the respondent said directly |
| **decision surface** | A concrete choice or commitment a respondent named, or a choice a divergence implies. **Has a rendered form**: when decisions are forks with 2–4 distinct options, `/harvest` emits them as an interactive Meridian *decision surface* the respondent decides *on* and pastes back, rather than prose to read | When the harvest produced something actionable; *not* the same as a recommendation — it surfaces the choice without forcing its resolution |
| **open question** | An unresolved tension, ambiguity, or follow-up worth a future harvest | When the harvest opened more than it closed; explicitly named so it doesn't get lost |
| **pattern** | A knowledge / action / antipattern the harvest extracted, ready for `/reflect` to consume | When a finding generalizes — not just *"Oz said X"*, but *"the pattern is Y, evidenced by X"* |

**Composition rule**: for each L2 section, a strong default sequence
is `quote → context → reflection → pattern` (the Olivier shape). The
Oz shape (`decision → quote → reflection → action`) is also strong.
The model chooses what the content needs. **Skip what doesn't apply.**
A section with no `decision surface` and no `pattern` is fine — the
modalities are a palette, not a checklist.

**Modality usage rules**:

- `quote` — verbatim only. No paraphrasing dressed as quotation.
  Block-quote format, attributed by handle.
- `context` — clearly distinct from interpretation. Describe what
  was, not what it implies.
- `reflection` — owned by the synthesizer, not the respondent. Use
  *"this implies..."*, *"the move underneath this is..."* — never
  attribute interpretation back to the respondent.
- `decision surface` — describe the choice, not which side to pick
  (unless a respondent named the side themselves). **Rendered form:**
  when ≥3 interrelated forks each have 2–4 distinct options, `/harvest`
  renders them as an interactive *decision surface* instead of prose.
  Each option carries a structural *visual*, honest `+/−` tradeoffs,
  and at most one recommendation; the respondent's pasted choices
  (`#{slug}-decisions:v1`) are absorbed on `--resume`. Shape + render:
  harvest's rendered-surface section (SKILL.md) and
  `packages/egregore-artifacts` (`decision-surface` type).
- `open question` — phrase as a question or as *"unresolved: …"*.
- `pattern` — name the pattern type (knowledge / action /
  antipattern) and cite the turn(s) it was extracted from.

---

## 4. Generative emission — how the model picks shape

Synthesis shape is decided once the harvest is done, not in advance.
The model reads the running interpretive state and answers four
questions:

1. **Did the harvest produce decision-shaped or divergence-shaped
   findings?** If yes → emit L1. If no → skip L1.
2. **What's the natural unit?** Respondent? Question? Theme? → that's
   how L2 slices.
3. **For each L2 section, which modalities does the content need?**
   Pull only those.
4. **Where would a reader want to go next?** That's where to put
   `open question` modalities and `decision surface` modalities — at
   the points the document hands off to action.

A cleanly emitted harvest:

- L0 always.
- L1 if and only if the harvest produced something decision- or
  divergence-shaped that's worth surfacing at the harvest level.
- L2 if and only if there's per-unit content that stands alone.
- L3 always.

A bad emission emits all four layers regardless of content. Empty L1
sections, padded L2 sections, and L0 sentences that don't actually
hold the most are the failure mode.

---

## 5. Orientations by harvest shape

These are orientations, not templates. The model adapts.

### Preference / taste

Likely shape: **L0 (the strongest preference + reason) · no L1 · L2
per-respondent or per-question with `quote → context → reflection`,
no `decision surface`, no `pattern` for the harvest itself (patterns
emerge later when many preferences accumulate) · L3.**

Example L0: *"Cem prefers card-first L0 expanding to a narrative+rail
workspace, because the rail keeps decision surfaces visible while the
narrative does the work."*

### Alignment scan (multi-respondent)

Likely shape: **L0 (the central pattern across respondents) · L1
(convergence + divergence, divergence presented as information) · L2
per-respondent showing each position's reasoning · L3.**

Divergence sections in L1 lay positions side-by-side. Each position
gets its own load-bearing reason. The synthesis does not pick a
winner — but it can name what each position is optimizing for, which
is often the most useful read.

### Knowledge extraction

Likely shape: **L0 (the most load-bearing undocumented thing) · L1
optional (often emits as `open questions` if extraction surfaced
gaps) · L2 per-dimension with `quote → context → pattern` heavy ·
L3.**

`pattern` modality earns its keep here. Knowledge extraction's whole
point is producing reusable knowledge nodes.

### Decision crystallization (the one shape that may end with an action surface or commitment)

Likely shape: **L0 (the decision + load-bearing rationale) · L1
(considerations weighed, commitments) · L2 per-question with
`decision → quote → reflection → action` (the Oz shape) · L3.**

This is the shape whose intent was to crystallize a decision, so an
action surface or named commitment is appropriate. Even here, the
model records the choice as the respondent(s) made it — it does not
manufacture an action the respondents didn't name.

### Tacit position elicitation

Likely shape: **L0 (what the person is carrying that the org hasn't
articulated) · no L1 · L2 per-dimension with `quote → context →
reflection → pattern` · L3.**

The Olivier harvest is the canonical example. The output is a portrait
of someone's position, not a verdict on whether they're right.

### Retrospective

Likely shape: **L0 (the shared narrative or its absence) · L1 (shared
narrative section, divergent interpretations section, lessons,
commitments) · L2 per-theme · L3.**

Useful pattern: when respondents agree on what happened but diverge
on what it meant, L1 names this shape directly — *"shared event,
divergent reading"* — and L2 explores each reading.

---

## 6. Fixtures

Two harvests in the repo are gold examples. The rebuild's synthesis
must reproduce their shapes (within minor variation) given the same
intent + RoleSheets + seed.

### Olivier harvest — position-unit slicing

`memory/knowledge/harvests/2026-03-23-olivier-harvest-analysis.md`

What it demonstrates:
- L0 *"It makes it possible to embody the overall organization in a
  variety of personal ways, while sharing a common ground with
  others"* — single sentence that holds the most.
- L2 sliced per-position: 7 positions, each as `Context → Olivier's
  Position (with quotes) → Reflection → Pattern Extraction`.
- Patterns named explicitly with type prefix (*Knowledge pattern —
  Junction Primacy*, *Action — Reframe positioning language*).
- L3 as `Full Exchange` with 7 turns, question + answer per turn.
- No `decision surface` modality used — this was a tacit-position
  harvest, no decisions were on the table.

### Oz canvas harvest — question-unit slicing

`memory/handoffs/2026-05/06-cem-harvest-oz-canvas-tech-and-capabilities.md`

What it demonstrates:
- L2 sliced per-question: 7 questions, each as `1. Decision · 2.
  Positions (block quotes) · 3. Why · 4. Action space`.
- The L2 section's own internal table of contents (lines 142–159
  describe how to read the document) is a generative move worth
  copying when the harvest has many questions and a synthesis-ready
  summary section.
- `decision surface` modality is heavy here — this was a
  decision-crystallization harvest with concrete asks.
- Cross-question consolidation in a `Canvas Changes & Additions`
  section is a domain-specific L1 emission. Generalizable: when L2
  produces many small actions, an L1 consolidation section that
  collects them is a useful surface.

**Both are valid synthesis shapes.** The model picks the slicing that
fits what the harvest produced.

---

## 7. Evidence binding (mandatory)

Every assertion in synthesis traces back. The mechanism:

- **Quotes** carry the respondent handle: `> "..." — oz` or block-quote
  with attribution line.
- **Patterns** name the turn(s) they were extracted from. Either inline
  (*"extracted from turn 3"*) or implicit when the L2 section's quote
  block is the source.
- **Reflections** that draw on multiple turns name the turns they
  synthesize.
- **Seed-context references** are marked: *"per `whitepaper-v0.1.md`
  §3"* — so a reader can distinguish between *what the harvest
  produced* and *what was already known going in*.
- **Async answers** are quoted with their source noted: *"from
  `memory/knowledge/questions/2026-05-07-pricing.md`, answered
  2026-05-08"*.

If an assertion in synthesis cannot be traced, it does not belong in
the artifact. (`PROCESS.md` §2 invariant 4.)

---

## 8. Linkability — `/reflect`-able output

Synthesis is not a leaf. Patterns, preferences, positions, and
(where present) decisions emit in shapes the org's pattern/decision
graph can ingest:

| Modality | Becomes a |
|---|---|
| `pattern` (knowledge type) | Knowledge pattern node, linkable to topics + people |
| `pattern` (action type) | Action node, linkable to quests / decisions |
| `pattern` (antipattern type) | Antipattern node |
| `decision surface` (where a respondent named a choice) | Decision node, attributed to the respondent |
| Synthesized position from L2 (e.g., *"cem prefers X because Y"*) | Position / Preference node, attributed to the respondent, with quote-block(s) attached as `Evidence` nodes — never the quote alone as the position |
| `quote` block (verbatim, attributed) | `Evidence` node — raw, uninterpreted, links into the Position / Preference / Pattern it supports |
| `open question` | Open-question node, surfacable in `/activity` and seedable for follow-up harvests |

**The quote-vs-position distinction is load-bearing.** A quote is
evidence; the synthesized position is the node `/reflect` consumes.
This keeps the pattern/decision graph from treating every verbatim
utterance as already-interpreted knowledge, and it makes the
synthesizer's interpretive work explicit (and contestable) rather
than disguising it as the respondent's own words.

Concretely: when the synthesis is written, a `/reflect` pass can read
the artifact and emit graph/memory nodes from each load-bearing
section without re-interpreting. The artifact's structure carries the
graph's structure.

For a pure preference harvest, this means the org gains a
tacit-knowledge node (*"cem prefers X because Y"*) other agents can
reason from. For an alignment scan, it gains a divergence-map node.
The shape varies; the legibility doesn't.

---

## 9. Negative examples — what synthesis does not do

| Anti-pattern | Why it's banned |
|---|---|
| L1 with empty `Action surface` because the template said so | Forces an action the harvest didn't produce; violates §1 |
| L2 sections with all six modalities padded in regardless of content | Modality palette is a palette, not a checklist |
| L0 that summarizes the dimensions covered (*"this harvest explored A, B, and C"*) | L0 is the sharpest finding, not a table of contents |
| Paraphrased "quotes" | Quote modality is verbatim only |
| Reflections attributed back to the respondent | Reflections are owned by the synthesizer; respondents own quotes |
| Divergence framed as "the team disagrees" | Divergence is information, not failure; name what each side is optimizing for |
| "Recommended direction: X" when no respondent named X | Synthesis surfaces what was elicited; it does not invent direction |
| Synthesis without L3 | Removes auditability; breaks `PROCESS.md` §2 invariant 4 |
| Mixing per-respondent and per-question slicing in L2 without reason | Pick one; mix only when structure genuinely requires it |

---

## 10. What this document does not cover

- **Cognitive protocol** — how the model conducts the conversation,
  evaluates answers, runs cascades: see `PROCESS.md`.
- **Persistence** — graph schema, ID conventions, async question
  metadata, local-mode markdown contract: see `AUDIT.md` §9–§11.
- **Orchestration** — argument parsing, mode detection, ID minting,
  file writes: belongs in `SKILL.md` once it's rewritten as a thin
  entry point.

The synthesis runtime contract is complete here. The model has what
it needs to produce a layered, evidence-bound, generative artifact
that preserves what the harvest elicited without forcing it into a
shape the harvest didn't produce.
