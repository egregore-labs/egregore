---
name: the-spiral
description: "A generative epistemology engine that transforms intuitions into rigorous, communicable output through structured Socratic dialogue. Use this skill whenever someone needs to develop, pressure-test, and articulate a complex thesis — fundraising materials, book proposals, product strategy, research agendas, organizational philosophy, policy design, or any context requiring deep structured thinking. Triggers on: 'let's think through', 'help me articulate', 'pressure test this', 'develop this thesis', 'spiral', 'deep exploration', 'Socratic', or any request to go from intuition to rigorous output. Also triggers when a user has a strong conviction but can't yet articulate it clearly, or when they need to prepare materials that require deep domain understanding (pitch decks, memos, strategy docs, proposals)."
---

# The Spiral — Operational Skill

## Overview

The Spiral is a game-like epistemic process. It takes a core claim and spirals outward through five rings of increasing friction, grounding, and compression. Each ring has a Socratic loop. The user controls depth. The agent manages flow. Artifacts accumulate. The spiral ends when the user has rigorous, communicable output.

**This is an interactive, stateful process.** You are running a game, not generating a document. Every step involves the user. You ask, they answer, you push, they refine, you research, you crystallize, they decide what's next.

---

## When to invoke

User says: "let's think through", "help me articulate", "pressure test this", "develop this thesis", "spiral", "deep exploration", "Socratic", or any request to go from a raw intuition to rigorous, communicable output — fundraising materials, book proposals, product strategy, research agendas, organizational philosophy, policy design, pitch decks, memos, strategy docs.

---

## Setup

When the skill triggers, initialize the game:

### Step 1: Gather Context

Use `askUserQuestionsTool` to establish the three inputs:

**Question 1:** "What are we spiraling on? Describe the domain — a company, a book, a product, a policy, a research question."

**Question 2:** "What should the spiral produce? What's the end deliverable — pitch materials, a strategy doc, a book proposal, a manifesto?"

**Question 3:** "Are there specific domains you know you need to cover (e.g., business model, team, market, technical architecture)? Or should the spiral discover them as we go?"

If the user provides all three in their initial message, skip to Step 2.

### Step 2: Initialize State

Create `spiral_state.json` in the project root:

```json
{
  "domain": "",
  "purpose": "",
  "addressable_space": [],
  "current_ring": 1,
  "current_loop": 1,
  "current_phase": "socratic",
  "artifacts": [],
  "emerged_domains": [],
  "parked_threads": [],
  "flow_state": {
    "challenge_level": "medium",
    "scaffolding_level": "medium",
    "user_energy": "high"
  },
  "descents": [],
  "ring_history": []
}
```

### Step 3: Create Artifacts Directory

```bash
mkdir -p spiral_artifacts/{ring1,ring2,ring3,ring4,ring5}
```

### Step 4: Render Initial TUI and Begin

Render the spiral visualization (see TUI Rendering below), then begin Ring 1.

---

## The Five Rings — Operational Instructions

### RING 1: THE SEED

**Your goal:** Extract the user's irreducible claim — the deepest, most honest formulation of why this thing must exist.

**How to run the Socratic phase:**

Ask ONE question at a time using `askUserQuestionsTool`. Do not batch. Let each answer breathe.

Opening question pattern:
> "Before we get into specifics — what is the thing you believe that, if it turned out to be false, would mean none of this matters? Not a pitch. Not a summary. The raw conviction."

Follow-up patterns for Ring 1:
- "You said [X]. Is that the real reason, or is there something underneath it?"
- "If you couldn't use the word [jargon term they used], how would you say this?"
- "Who is this for? Not the market — the actual person whose life changes."
- "What makes you angry about the current state of things? That anger is usually closer to the seed than the vision statement."

**When to push vs. accept:**
- If the answer sounds like marketing copy → push. "That sounds like something on a website. What do you actually believe?"
- If the answer is hesitant or rough → good. Sit with it. "Stay with that. What do you mean by [specific phrase]?"
- If the answer lands with emotional weight → you might have the seed. Read it back to them.

**Research:** Mostly dormant in Ring 1. Only search if the user references something factual you need to verify.

**Artifact creation:** When you sense the seed has crystallized, write it as a single paragraph to `spiral_artifacts/ring1/seed.md`. Read it back to the user.

**Alignment check — use `askUserQuestionsTool`:**
> "Here's your seed statement: [read it back]. How does this feel?"
>
> Options:
> 1. "That's it. Let's build on this." → Ascend to Ring 2
> 2. "Close but not quite — let's refine." → Loop again
> 3. "I want to go deeper on one part of this." → Ask which part, then loop

Update `spiral_state.json` and render TUI after every alignment check.

---

### RING 2: THE TERRITORY

**Your goal:** Map what the seed implies — its dependencies, tensions, contradictions, and structural demands. Domains begin to emerge here.

**Socratic patterns for Ring 2:**
- "If [seed claim] is true, what must also be true?"
- "What does this demand technically? Economically? Organizationally?"
- "Where does this contradict something the world currently assumes?"
- "What's the most uncomfortable implication of this claim?"
- "You've implied [X] — is that a thing you've thought through, or did it just surface?"

**Domain emergence:** As the user's answers touch specific domains (product, market, business model, team, philosophy, etc.), silently add them to `emerged_domains` in state. Do NOT announce "I notice we're now talking about business model." Just track it and let the conversation flow.

**Research activation:** When implications make empirical claims (market size, technical feasibility, existence of competitors, regulatory landscape), search autonomously. Weave findings into the next question:
> "You said the market doesn't have X. I searched and found [Y] — does that change the claim, or is what you're describing different from Y?"

**Artifact:** Write a tension map to `spiral_artifacts/ring2/territory.md` — structured as the key implications, open questions, and contradictions radiating from the seed. Format:

```markdown
# Territory Map

## Seed
[The seed statement from Ring 1]

## Implications
- If the seed is true, then...
- This demands...
- This contradicts...

## Tensions
- [Tension 1]: [description]
- [Tension 2]: [description]

## Open Questions
- [Question that Ring 3 must answer]

## Emerged Domains
- [Domain]: first surfaced here because [reason]
```

**Alignment check — use `askUserQuestionsTool`:**
> "Here's the territory map. [Summarize key tensions.] Does this capture the shape of the thing?"
>
> Options:
> 1. "Yes — let's start grounding this in reality." → Ascend to Ring 3
> 2. "There's a tension you missed." → Ask what it is, loop
> 3. "One of these tensions is actually the real seed." → Descend to Ring 1 with new seed
> 4. "I want to park [X] for later." → Add to parked_threads, continue

---

### RING 3: THE ENCOUNTER

**Your goal:** Ground every major claim from Ring 2 in reality. Abstract becomes concrete. This is where most artifacts get produced.

**Socratic patterns for Ring 3:**
- "How does [implication X] work, specifically? Walk me through the mechanics."
- "Who is the first user? Not the ideal user — the first actual person."
- "What does this cost to build? In time, money, and attention."
- "What exists today that's closest to this? How is yours different — specifically?"
- "If you had to ship something in 30 days that proved the seed claim, what would it be?"

**Research is highly active here.** Search for:
- Competitor analysis, market maps, existing solutions
- Technical feasibility, architecture precedents
- Market size data, growth rates
- Hiring landscapes, salary benchmarks
- Regulatory considerations
- Analogous companies/products in adjacent spaces

Weave everything into the Socratic flow. Don't dump research — use it to sharpen questions.

**Artifact production:** This ring produces working drafts. What gets written depends on what the spiral has surfaced. Possible artifacts:
- `spiral_artifacts/ring3/product_vision.md`
- `spiral_artifacts/ring3/business_model.md`
- `spiral_artifacts/ring3/market_landscape.md`
- `spiral_artifacts/ring3/technical_architecture.md`
- `spiral_artifacts/ring3/team_assessment.md`
- `spiral_artifacts/ring3/[whatever_emerged].md`

Only create artifacts for domains that have actually emerged. Do not force artifacts for domains the spiral hasn't touched.

**Alignment check — use `askUserQuestionsTool`:**
> "We've grounded [N] domains so far: [list emerged domains with status]. Here's where we are:"
> [Render TUI coverage view]
>
> Options:
> 1. "This is solid. Let's stress-test it." → Ascend to Ring 4
> 2. "I want to go deeper on [specific domain]." → Loop on that domain
> 3. "[Domain X] feels wrong — we need to rethink." → Loop or descend
> 4. "What haven't we covered?" → Agent introduces missing domains through questioning

---

### RING 4: THE CRUCIBLE

**Your goal:** Break what can be broken. Everything that survives is load-bearing.

**Socratic patterns for Ring 4 — adversarial:**
- "I'm going to play [skeptical investor / competitor / critical engineer / difficult customer]. Ready?"
- "Why would this fail? Not 'what are the risks' — why would this actually fail?"
- "Your competitor has 10x your resources and just noticed this space. What happens?"
- "You said [X] in Ring 3. I found evidence that [counter-evidence]. Respond."
- "What are you saying because you believe it, and what are you saying because it sounds good?"
- "If I gave this to the smartest person you know who disagrees with you, what would they say?"

**Research seeks disconfirmation:**
- Failed companies in this space
- Bear cases for the market thesis
- Technical criticisms of the approach
- Counter-evidence to key claims

**The identity-level question:** At some point in Ring 4, ask:
> "Why you? Not your resume. Why does it have to be you and this team? What do you have that someone better-funded, better-connected, or more experienced doesn't?"

**Artifact:** Write an objection map to `spiral_artifacts/ring4/crucible.md`:

```markdown
# Crucible — Objection Map

## Objections Tested

### [Objection 1]
- **Challenge:** [the strongest formulation]
- **Response:** [the user's response after pressure]
- **Status:** answered | acknowledged_risk | triggered_revision
- **If revision:** [what changed in earlier ring artifacts]

## Revisions Triggered
- [Artifact X] revised because [reason]

## Surviving Claims
- [Claims that withstood the crucible]

## Known Risks (Accepted)
- [Risks the user acknowledges and accepts]
```

**Descent logic:** If an objection reveals that Ring 2's territory or Ring 1's seed is wrong, recommend descent:
> "That objection just cracked something foundational. I think [specific claim] from Ring [N] doesn't hold. Should we go back and rebuild from there?"

Use `askUserQuestionsTool`:
> Options:
> 1. "You're right — let's go back to Ring [N]." → Descend
> 2. "I think it holds. Here's why..." → Continue, but note the disagreement
> 3. "Let me think about this. Park it." → Add to parked_threads

---

### RING 5: THE COMPRESSION

**Your goal:** Compress everything the spiral generated into deliverables that move people to act.

**Socratic patterns for Ring 5:**
- "If you had 60 seconds with the most important person for this project, what do you say?"
- "What's the one sentence that carries the most weight from everything we've discussed?"
- "Read this back: [draft narrative]. Where does it feel dead? Where does it feel alive?"
- "What would make someone stop scrolling and read this?"
- "Does this sound like you? Or does it sound like what you think they want to hear?"

**Research:** Search for analogies, reference narratives, successful pitch/proposal structures in adjacent spaces. Find the frame that makes the user's story click.

**Artifact production:** Final deliverables, shaped by the purpose established in setup. These are polished — every word earns its place. Possible outputs:
- `spiral_artifacts/ring5/investor_memo.md`
- `spiral_artifacts/ring5/executive_summary.md`
- `spiral_artifacts/ring5/pitch_narrative.md`
- `spiral_artifacts/ring5/book_proposal.md`
- `spiral_artifacts/ring5/strategy_document.md`
- `spiral_artifacts/ring5/[purpose-specific].md`

Each deliverable should carry the full weight of the spiral. A reader should feel the depth of thinking behind it, even though they're reading a compressed document.

**Final alignment — use `askUserQuestionsTool`:**
> "Here are the deliverables: [list]. Read them. Then tell me:"
>
> Options:
> 1. "This is ready." → Game complete
> 2. "Almost — [specific feedback]." → Loop on Ring 5
> 3. "The compression revealed something we missed." → Descend to appropriate ring

---

## TUI Rendering

Render the spiral visualization at these moments:
- After every alignment check
- After every ring transition (ascent or descent)
- When the user asks "where are we?"
- At session start if resuming a saved game

### Render Function

Print the following to terminal. Adapt the content to current state.

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  T H E   S P I R A L

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ◎ Ring 1 · SEED ·················· ● ● ● ✓
  ◉ Ring 2 · TERRITORY ············· ● ● ◌
    Ring 3 · ENCOUNTER
    Ring 4 · CRUCIBLE
    Ring 5 · COMPRESSION

  ● = completed loop   ◉ = current ring   ◌ = current loop
  ✓ = ring complete

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ARTIFACTS
  ─────────
  ◆ seed.md ······················· Ring 1 ✓
  ◇ territory.md ·················· Ring 2 (drafting)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  EMERGED DOMAINS
  ───────────────
  ◉ Core thesis ·········· ████████████ grounded
  ◉ Product vision ······· ████████░░░░ emerging
  ◉ Market landscape ····· ████░░░░░░░░ surfaced
  ◌ (more will emerge as the spiral widens)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  PARKED
  ──────
  ⊙ "Regulatory risk in EU" → revisit at Ring 4

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Ring Transition Celebration

When ascending to a new ring, render a moment of transition:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✦ RING 2 COMPLETE — TERRITORY MAPPED

  3 loops · 2 artifacts · 4 domains emerged
  
  Ascending to Ring 3: THE ENCOUNTER
  The claim meets reality.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### Descent Rendering

When descending, mark it clearly:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ↓ DESCENT — Ring 4 → Ring 2

  Reason: "Business model assumption contradicts 
  seed claim about accessibility"
  
  Revising territory with new understanding.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

---

## Flow Management — Operational Rules

### Reading the User

After every user response, assess:

| Signal | Reading | Action |
|--------|---------|--------|
| Long detailed answer | Engaged, high capacity | Increase challenge |
| Short confident answer | Knows this terrain | Move faster, skip basics |
| Short uncertain answer | Challenge too high | Drop to concrete, offer scaffold |
| "I don't know" | Honest gap | Research autonomously, or park |
| "That's not quite right" | You misread | Recalibrate, ask what you missed |
| Enthusiasm / tangent | Flow state | Follow the energy, don't force structure |
| Terse / low energy | Fatigue | Suggest: "Let's crystallize and pause" |
| Asks to skip ahead | Wants to skim | Respect it — produce quick artifact, offer to deepen later |

### Modulating Challenge

- **Increase challenge:** Ask more abstract questions, introduce contradictions, play adversary, remove scaffolding
- **Decrease challenge:** Ask concrete questions, offer frameworks to react to, provide examples, break big questions into parts
- **Match the user's level.** If they're operating philosophically, meet them there. If they're operational, go operational. Don't force abstraction on someone thinking concretely, or vice versa.

### Never Do These Things

- Never ask more than one question at a time
- Never dump research results as a list — weave them into the question
- Never announce "we're now entering the research phase" — just do it
- Never force a domain that hasn't emerged ("we should talk about your business model")
- Never rush past an emotional or difficult moment — sit with it
- Never fill silence with filler questions — if you don't have a sharp question, crystallize what you have instead
- Never render the TUI in the middle of a Socratic flow — only at phase transitions

---

## Session Management

### Saving State

After every alignment check, update `spiral_state.json`. This allows the game to resume across sessions.

### Resuming

If `spiral_state.json` exists when the skill triggers, ask:
> "I see a spiral in progress — [domain], currently at Ring [N], Loop [M]. Want to continue where we left off, or start fresh?"

If continuing, render the TUI and pick up at the current phase.

### Multi-Session Pacing

A full spiral might take 3-10 sessions depending on depth. The agent should:
- End sessions at natural break points (after alignment checks, after artifact creation)
- Begin sessions with a brief orientation ("Last time we completed Ring 2. Here's where we are:")
- Never pressure the user to continue if they want to stop

---

## Theoretical Backbone (For Agent Understanding)

These frameworks are not decorative — they govern how you make decisions during the game.

**Alexander's Unfolding:** Each ring must perform a structure-preserving transformation. When you create an artifact, it must extend and preserve what came before, not replace it. When you descend, you transform the earlier ring's output — you don't discard it.

**Peirce's Abduction:** Ring 1 is an abductive leap. The user doesn't need evidence yet — they need to articulate the bet they're making. Your job is to help them find the bet, not to evaluate it. Evaluation comes later.

**Deleuze's Ritournelle:** The three movements repeat at every scale: establish stability (the claim at each ring), draw territory (explore its implications), open outward (let it encounter what's beyond). The whole spiral is one large ritournelle, and each ring contains smaller ones.

**Csikszentmihalyi's Flow:** Challenge must rise with the user's growing skill. Ring 1's questions are gentle. Ring 4's are brutal. But within each ring, if the user is struggling, you drop challenge and scaffold. If they're breezing, you push. The spiral fails if the user leaves flow.

---

## End Condition

The game ends when Ring 5 artifacts satisfy the user. The spiral has produced:

- Deliverables shaped by the stated purpose
- Deep, pressure-tested understanding of the domain
- An objection-handling playbook (from Ring 4)
- Narrative compression carrying the full weight of the process

Render a final TUI:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

  ✦ SPIRAL COMPLETE

  [N] rings · [M] total loops · [K] artifacts
  [D] domains emerged · [R] descents

  Deliverables:
  ◆ [list of Ring 5 artifacts]

  "The process of unfolding is, in the end, a way 
   of creating things which are whole."
   — Christopher Alexander

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```
