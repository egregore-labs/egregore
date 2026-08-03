# Harvest — Question Palette

> Ask for the kind of judgment the harvest actually needs.

This document is the single canonical home for choosing a question move
and answer shape from `questionIntent`. `PROCESS.md` owns the conversational
rhythm and evaluation; `SKILL.md` owns rendered-surface wiring; scrolls
consume this palette directly. They point here instead of restating it.
The byte-identical `.codex/skills/harvest/QUESTION_PALETTE.md` file is a
packaging mirror for Codex and Pi; tests reject drift from this source.

The palette is a decision aid, not a checklist. It never requires a mix or
minimum number of shapes. An all-`single` surface is correct when every
question is truly an enumerable fork; it is wrong when rankings, subsets,
graded positions, or unmapped spaces were flattened into option cards.

## Selection rule

For every question:

1. State the `questionIntent`: what the answer must reveal or change.
2. Choose the closest intent row below.
3. Use its move and answer shape when available.
4. If another shape fits better, record one sentence explaining why.
5. In a new rendered surface, declare `mode` explicitly. An absent mode
   falls back to `single` only for backward compatibility.

The author must be able to explain both why the question is being asked
and why its answer shape fits. There is no shape quota or preset flow.

## Intent → move → answer shape

| Elicitation intent | Question move / answer shape | Guard |
|---|---|---|
| Decide among enumerable, mutually exclusive alternatives | Run the **enumerability test**: the author can state the full space. Use option cards, mode `single`, with 2–4 options, an “other, in your own words” escape, honest ± tradeoffs, and at most one argued lean. | If the full space cannot be stated, it is not a single-pick fork. |
| Place a graded position or intensity between two honest poles | Name the evaluated dimension and both poles concretely. Use mode `spectrum` with 5–7 discrete, fully labeled stops; follow a midpoint with a clarifying probe. | Nothing is preselected. Untouched, midpoint, and UNDECIDED remain distinct. Never use a continuous slider. |
| Set priority or sequence over a small set | Use mode `rank`; allow ties or top-k when a total order would invent precision. | Keep to at most 5 items. |
| Compare importance across a longer list | Run **best-worst** as dialogue: show 3–4 items, ask most and least, then rotate subsets. | Do not turn a long list into a rating battery. |
| Choose a non-exclusive subset | In an artifact, use mode `multi` with an explicit `max`. In live dialogue, walk items one at a time as explicit include / leave-out judgments. | Cap the subset and keep the candidate set small enough to inspect. “Select all that apply” without a cap invites shallow selection. |
| Allocate relative magnitude or resources | Use mode `weight` with coarse 5–10% steps and an explicit untouched state. | Use at most 5 buckets; do not imply false precision or prefill an even split. |
| Weight decision dimensions with different ranges | Ask a **swing question**: with every dimension at its worst, which swing to best would the respondent buy first? Continue against the concrete ranges. | Do not substitute context-free importance ratings. |
| Elicit a quantity plus confidence | Ask, in order: lowest plausible, highest plausible, best guess, then sureness. Prefer frequency framing. | This needs the four-field interval card; until that renderer addition exists, run it conversationally. |
| Explore an unmapped answer space, rationale, or discovery question | Use an open prompt anchored in the respondent’s own words. Acknowledge the answer, then probe only when it is insufficient. | Ask at most 1–2 probes per question; do not use a bare “why?” when a specific clarifier is available. |
| Discover tacit taste dimensions before minting a fork | Run a **triad**: present three concrete elements and ask which two are alike and how the third differs. The named difference becomes a candidate axis. | Do not supply the taste taxonomy in advance. |
| Reach tacit expertise behind a general claim | Run a **critical-incident sequence**: one concrete incident, a co-built timeline, deepening probes, then “what if X had been absent?” | Generalities are elicited through a real case, not requested directly. |
| Deepen a thin why-note | **Ladder up** with “why does that matter to you?” or **ladder down** with “give me a concrete example.” | Stop after at most 3 consecutive ladder steps. |
| Verify the interviewer’s interpretation | Run a **mirrored-inference check**: “My read of your position is X — what is wrong in that?” End a harvest with a member check of each respondent’s own synthesis when useful. | Mirror the sharpest reading, including tensions; do not smooth disagreement into affirmation. |
| Get concrete feedback after abstract forks run dry, or when the respondent asks to see the work | Show only the relevant draft or excerpt in the decisions view and ask an open prompt naming what the answer will change. | This is selective authoring, not a mode: no default per-section controls, no generic ready/not-ready verdict, and no interaction added to the readable face. |
| Elicit multi-respondent preferences, positions, or estimates | Default to blind independent collection. Freeze one shared artifact and question set when everyone should answer the same inquiry; otherwise adapt only from the seed, RoleSheet, and that respondent’s own prior turns. | Attribute every position and preserve its reasoning. Append pre-seal corrections and let the latest supersede; after sealing, a changed position starts a new round. Never report an anonymous aggregate such as “most of the team thinks.” |
| Preserve honest nonresponse | Offer explicit `UNDECIDED`, distinct from untouched. | Never force an answer. A scroll may carry it once, then must reframe or demote the question. |
| Handle an escape-hatch answer that names a missing option | At review, treat it as a candidate option or fork for the next version. | The creator decides whether it enters the pool; never silently coerce it into an existing option. |

## Conversational moves

These moves need no widget. They run inside PROCESS’s generate → evaluate
rhythm:

- **Ladder up / down** moves between value and concrete example.
- **Critical incident** reconstructs one real episode before generalizing.
- **Triad** lets the respondent name the comparison axis.
- **Best-worst** extracts discrimination from rotating small subsets.
- **Swing question** ties importance to the actual range of change.
- **Mirrored-inference check** asks the respondent to correct the model’s
  strongest interpretation.
- **One-at-a-time forced choice** replaces an unbounded check-all with
  inspectable include / leave-out judgments.

## Hard bans

These are lintable rules:

- No agree/disagree, true/false, or yes/no stems — rewrite as explicit alternatives or an item-specific scale.
- No draggable sliders with a preset thumb; no numbers-only or endpoint-only scales.
- No batteries of stacked identical gauges; one question per fold-point, adjacent to its motivating prose.
- Nothing pre-selected, ever — including spectrum position and weight splits; the lean argues, it never pre-picks.
- No dropdowns in surfaces; >4 genuine options means an unsplit fork — split it.
