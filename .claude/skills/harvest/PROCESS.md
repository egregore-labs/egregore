# Harvest — Cognitive Protocol

> Harvest elicits latent human or agent context — preferences, positions,
> tacit knowledge, taste, constraints, role-shaped judgment — and turns
> the answers into organizationally usable context.

This document is the **cognitive protocol** for `/harvest`. It defines how
the model conducts the conversation: how it seeds, generates, evaluates,
checkpoints, cascades, and synthesizes. It is authored fresh from
[`AUDIT.md`](./AUDIT.md).

For persistence (graph schema, async metadata, local-mode markdown
contracts), see `AUDIT.md` §9–§11. This document references those
contracts but does not re-specify them.

For format (synthesis layers, modality palette), see `FORMAT.md`. This
document points to it but does not duplicate it.

---

## 0. What the model is doing

Harvest is **model-led, not flowchart-led**:

> The model owns the next question. The protocol only requires that it
> can explain why the question is being asked, preserve the answer, and
> update its interpretation.

There is no fixed round count, no fixed question count per round, no
required dimensions. The model reads the situation, generates the next
question with an articulable purpose, evaluates the answer, and decides
whether to deepen, pivot, checkpoint, cascade, or synthesize.

---

## 1. Boundary (read once, then never again in this doc)

**Harvest** elicits latent context. **Spiral** stress-tests claims. They
share craft (good questions, careful evaluation, evidence-bound
synthesis) but their objectives differ.

Harvest does not pick winners. Harvest does not converge by obligation.
Divergence between respondents is information, not a problem to resolve.
A harvest produces a **decision surface, not necessarily a decision** —
for some harvests the output is *"Cem prefers X because…"*, *"Oz sees the
boundary this way…"*, *"Renc is carrying a constraint we haven't
documented…"* — useful context even when no recommendation is appropriate.

That's the boundary. The rest of this document stays in harvest's own
register: *elicit, preserve, situate, surface, interpret-with-evidence*.

The six elicitation moves in §3 (seed, generate, evaluate, checkpoint,
cascade, synthesize) are the durable craft. They were extracted from the
prior spiral-context harvest draft; the objectives that drifted toward
claim-stress-testing are not. After this section, that prior draft is
not referenced again.

---

## 2. Invariants

Every harvest must hold these. They are non-negotiable and apply
regardless of harvest shape (single / multi, present / async, preference
/ alignment / extraction).

1. **No hidden role stereotyping.** Every implicit role inference is
   inspectable in the manifest *and* surfaced into the interaction when
   confidence is below threshold.
2. **No survey collapse.** AUQ options never exhaust the answer space.
   Every question carries a freeform escape hatch. Options are drawn
   from context, not prefab taxonomies.
3. **No unmarked cascade contamination.** When prior respondents'
   positions are disclosed to a later respondent, that disclosure is
   explicit, recorded on the manifest, and visible to the respondent.
4. **No synthesis without evidence.** Every assertion in synthesis
   traces to a recorded turn or to seed context, marked as such.
5. **The model can articulate `questionIntent` for every question.** If
   it can't, the question is not ready to ask.

---

## 3. The six moves

### 3.1 Seed

Every harvest begins with **intent** and **context**.

- **Intent** = what the harvest wants to learn — dimensions, not
  questions. *"Understand each respondent's preferences, constraints,
  and tensions around pricing"* is intent. *"What price should we
  charge?"* is a decision, not a harvest intent.
- **Context** = what is already known: seed documents, prior harvests,
  RoleSheets for sender and receiver(s), recent sessions/handoffs/quests
  on the topic.

If intent or context is ambiguous, ask the harvest **initiator** for
clarification before generating the first questions. A handful of
clarifying questions upfront produces a dramatically better harvest than
proceeding on assumption.

**Resolve RoleSheets before the first question.** See `AUDIT.md` §6 for
the schema. Two sheets per turn: `SenderSheet` (who is asking — usually
the initiator) and `ReceiverSheet` (who is being asked). The asymmetry
matters: *cem-asks-renc-about-pricing* differs from
*renc-asks-cem-about-pricing*.

### 3.2 Generate (situated questions)

Generate questions live from intent + context + RoleSheets + what has
come back so far. Never from a predetermined list.

Each question carries:
- An articulable **`questionIntent`** the model can state to itself.
- A short **header** (≤12 chars) for the AUQ chip.
- 2–3 **options** drawn from the actual context (seed quotes, prior
  answers, role-likely lenses) — never prefab taxonomies.
- A **freeform escape hatch** (always; AUQ provides "Other" by default).

**Round shape (affordance, not script)**:
- One AUQ call per round.
- 1–3 questions per round (model decides; usually 2).
- Round count is not fixed. End when returns diminish or the respondent
  signals.

**How much context to include with each question is judgment.**
Considerations the model weighs:

- Showing another respondent's position can provoke valuable reaction —
  or bias the answer. Cascade disclosure mode (§3.5) settles this per
  harvest.
- Extensive recontextualization helps a respondent who lacks
  background. It patronizes one who has it.
- Structured options scaffold a low-stakes decision. They flatten a
  high-stakes preference. Use freeform when nuance matters.
- A diagram or position map can orient. It can also frame the answer.

**Forbidden in round 1**:
- Leading questions that presuppose a position.
- Disclosing other respondents' answers (unless cascade disclosure mode
  explicitly permits it; see §3.5).
- Asking what the seed already answers.

**Always permitted**:
- Asking the respondent to reframe the harvest's intent.
- Asking what the model *should* be asking that it isn't.
- Ending early at any checkpoint.

**Anti-calcification handling.** When a `ReceiverSheet` field is
inferred at low/medium confidence, surface the inference into the
question itself: *"I'm reading you as approaching this from the eng-lead
lens — push back if that's wrong."* The respondent can correct in one
turn, before the inference shapes a chain of questions.

### 3.3 Evaluate

After each response, the model notices what came back and records an
**`evaluation`** alongside the answer. The kinds of things a good
interviewer notices:

- **Novel framing** — the respondent reframed the question in a way
  that reveals a different mental model. High signal. Explore it.
- **Unresolved tension** — the answer contradicts something said
  earlier or something in the seed. Worth probing — but probing is
  *understanding the tension*, not pressing the respondent toward
  resolution.
- **Tacit content** — a preference, taste, or constraint surfaced that
  the respondent treats as obvious but isn't documented anywhere. High
  signal for a context/preference harvest.
- **Shallow signal** — canned or surface-level answer. Try the
  dimension from a different angle, or accept that the respondent
  doesn't have more to give on it.
- **Strong conviction** — clear, defended position. Clarify once if
  useful; respect it. Strong preferences are data, not resistance.
- **Surprising connection** — the respondent linked two dimensions the
  model didn't anticipate. Follow the thread.
- **Diminishing returns** — confirms what's known. Move on.

These are orientations, not a checklist. They feed the next question
generation and they accumulate into a **running interpretive state** —
the model's evolving read of what this harvest is producing. By
synthesis time, the model is assembling and interpreting from the
running state, not starting from scratch.

### 3.4 Checkpoint

At natural transition points — when a cluster of dimensions feels
explored, when returns diminish, when the respondent signals — offer a
checkpoint:

> "We've covered [dimensions]. Threads still worth pulling on:
> [remaining]. Continue, or synthesize what we have?"

The respondent co-steers. They might say *"skip X, go deeper on Y"* or
*"I'm done"* or *"actually, there's something we haven't touched."* All
productive responses.

Checkpoints respect the respondent's time and agency. **Do not impose
arbitrary limits** — no fixed round count, no fixed turn count. Offer
checkpoints when a genuine transition arrives.

### 3.5 Cascade (multi-respondent)

When harvesting more than one person on the same topic, the harvest
declares a **disclosure mode** at seed time and records it on the
manifest:

| Mode | Behavior | Use when |
|---|---|---|
| **blind** | Each respondent answers without seeing prior respondents' answers | Independent positions matter; you want uncontaminated signal (e.g., separate elicitations of design taste) |
| **disclosed** | Later respondents see crystallized prior positions | Reaction is the point; later respondents add value by responding to what already surfaced |
| **comparative** | Later respondents are explicitly asked to compare/contrast their position with priors | Alignment scans; mapping where the team agrees and diverges |

The mode is **explicit on the manifest, visible to respondents**, and
shapes what context the model includes per question (§3.2). An unmarked
cascade is an invariant violation (§2 invariant 3).

In **disclosed** and **comparative** modes, attribute prior positions
when surfacing them: *"Oz said X. Where does that land for you?"* —
never *"Some on the team think X."* Anonymized contamination is worse
than disclosed contamination.

In **blind** mode, the model still uses prior answers to **sharpen its
own questions** (asking better, more specific things) without
disclosing the source. The respondent gets a sharper question; they
don't get someone else's framing.

### 3.6 Synthesize

Synthesis is a deliberate act when all respondents finish (or a solo
harvest reaches diminishing returns). The model reads everything
through the running interpretive state and produces a layered artifact
per `FORMAT.md`.

**Two principles bind synthesis**:

1. **Interpret with evidence.** Every assertion ties to a recorded turn
   or marked seed (§2 invariant 4). Quotes are verbatim and attributed.
   Patterns name the turns they're extracted from.
2. **Generative emission.** Which layers and which sections within them
   exist depends on what the harvest produced. A pure preference harvest
   may emit L0 + L2 + L3 with no L1; an alignment scan may emit a thick
   L1 with thin per-person L2; a knowledge extraction may emit L0 +
   structured-knowledge L2 + L3. The model chooses based on what's
   present, not what the template "expects."

Synthesis carries **no obligation to converge or pick a winner**. It
surfaces what was elicited, organized for legibility. For some
harvests, *"Cem prefers X because Y; Oz prefers Z because W; they don't
disagree, they're optimizing for different constraints"* is the entire
output.

The synthesis artifact is `/reflect`-able: patterns, preferences, and
positions emit in shapes the org's pattern/decision graph can ingest.
See `AUDIT.md` §8.3.

---

## 4. The full rhythm

```
seed → generate → present → evaluate → ((generate → ...))* → checkpoint
     → ((continue / pivot / cascade / end))* → synthesize
```

This is a rhythm, not a script. The model inhabits it the way a good
interviewer inhabits conversation — alert, present, willing to follow
signal, willing to end early, willing to be surprised.

---

## 5. Self-harvest (degenerate case)

When `sender == receiver` — *"I want to think through my own position
on X"* — cascade is moot, disclosure mode is moot, RoleSheet asymmetry
collapses. Everything else applies: seed, generate situated questions,
evaluate, checkpoint, synthesize. The model interviews the user and
produces the same layered artifact. No special path; just the empty
case of the multi-respondent flow.

---

## 6. Async harvest (respondent not in session)

When a respondent isn't present:

1. The model generates the next round's questions for that respondent
   based on intent + context + that respondent's RoleSheet + prior
   sessions (subject to disclosure mode).
2. Questions are emitted into a question file with **harvest metadata
   in the frontmatter** — see `AUDIT.md` §9 for the schema. The async
   bridge extends `/ask`'s existing markdown shape with `harvest_id`,
   `harvest_session_id`, `turn`, `question_intent`, `context_mode`, and
   `status`.
3. The session's `HarvestSession` status is `pending` until the
   respondent engages.
4. When the respondent answers via `/ask`, status moves *pending →
   answered*. The next time `/harvest --resume` runs, it incorporates
   the answers, evaluates them under the running interpretive state,
   and continues toward the next round or synthesis.

The model treats async answers the same way as in-session answers for
evaluation purposes. The latency is operational, not cognitive.

---

## 7. Resume

Harvests span days. Re-entry is first-class.

- `/harvest --resume {harvest_id}` — explicit resume.
- Implicit resume: a `/harvest <topic>` that matches an active harvest
  surfaces it and asks: *continuation or fresh start?*
- On resume, the model reloads the manifest, all sessions, and the
  running interpretive state from recorded `evaluation` fields. It does
  **not** re-do already-answered turns. It picks up where it left off
  or, if all sessions are `complete` / `incorporated`, proceeds to
  synthesize.

---

## 8. The four anti-conflation fixtures

Before adding any new rule to this protocol, run it through these
fixtures. If a rule does not apply cleanly to all four, it has drifted
into forced-adjudication territory and does not belong here.

1. *"What's Cem's design taste for the artifact viewer?"* — pure
   preference, no proposition being evaluated, no alignment target.
2. *"What is Oz carrying about the moat question?"* — tacit position,
   no decision being forced.
3. *"What does Renc know about go-to-market constraints we haven't
   documented?"* — knowledge extraction, nothing to recommend.
4. *"What do cem, renc, and oz each prefer for pricing?"* — alignment
   scan; divergence is information, not a problem to resolve.

This is the test the protocol must pass.

---

## 9. What this document does not cover

- **Persistence** — graph schema, ID conventions, async question
  metadata, local-mode markdown contract: see `AUDIT.md` §9–§11.
- **Format** — synthesis layers, modality palette, layered disclosure
  rules: see `FORMAT.md`.
- **Orchestration** — argument parsing, mode detection, file
  read/write, ID minting: belongs in `SKILL.md` once it's rewritten as
  a thin entry point.
