# Harvest

Adaptive elicitation — the system extracts, deepens, and synthesizes strategic or epistemic signal from one or more people through directed conversation.

Harvest is not a survey (fixed questions), not an unstructured interview, not a retrospective. It is a directed epistemic process with an intent, where the quality of each question depends on everything that came before it.

## When to recognize harvest

Harvest applies when the system needs to understand what people actually think — not what's in documents, but positions, mental models, tensions, and commitments that only surface through good questions.

Recognize by shape:

- **Strategic alignment** — Multiple people, same topic. Goal: find convergence, divergence, and what divergences reveal. Seed docs and prior discussions may exist.
- **Deep elicitation** — One person has knowledge or positions the system needs. Onboarding a new org, understanding a stakeholder, mapping expertise. Go deep where it matters, skip the obvious.
- **Decision crystallization** — A decision has been circling. Force articulation: "where do you stand, and why?" Output is a decision record.
- **Knowledge extraction** — Domain knowledge not in the graph yet. Structured pull, deep on complexity, skip the obvious.
- **Retrospective** — After a sprint, launch, or incident. Each person's interpretation, then synthesis of shared narrative + divergent readings.

These are patterns, not categories. A harvest may start as knowledge extraction and become decision crystallization when a tension surfaces. Follow the signal.

## The process

```
seed → generate → present → evaluate → generate → ... → checkpoint → ... → synthesize
```

This is a rhythm, not a script. The model inhabits it the way a good interviewer inhabits conversation.

### Seeding

Every harvest begins with **intent** and **context**.

**Intent** = what the harvest wants to learn. Not questions — dimensions. "Understand this org's data topology preferences, launch readiness, risk posture, and positioning" is intent.

**Context** = everything already known. May include:
- A seed document (architecture spec, prior decision, strategy doc)
- Prior harvest results from other respondents
- Graph knowledge about the respondent (Person node — role, domain, history)
- The conversation that led to the harvest

If intent or context is ambiguous, ask the harvest initiator for clarification before generating the first questions. A few clarifying questions upfront produce dramatically better harvests than proceeding with assumptions.

### Question generation

Generate questions live from intent + context + what has come back so far. Never from a predetermined list.

Each question has a purpose the model can articulate to itself: "I'm asking this because the respondent said X and I need to understand whether that implies Y."

Questions should be clear enough that the respondent can answer without the model's full internal context.

**How much context to include with each question is a judgment call that depends on the situation.** There are no rules here — only considerations:

- Sometimes showing another respondent's position provokes a valuable reaction. Sometimes it biases the response and you lose independent signal.
- Sometimes extensive recontextualization is needed because the respondent lacks background. Sometimes the context is obvious and restating it is patronizing.
- Sometimes structured options (multiple choice with room to deviate) help. Sometimes an open question gets richer answers.
- Sometimes a visual (territory map, position diagram) helps orient. Sometimes it's noise.

The model reads the situation and decides. If unsure, err toward giving context — a slightly over-explained question is better than a confused answer.

### Presentation

Present questions through whatever interface fits — AskUserQuestion for interactive sessions, `/ask` for async delivery, other mechanisms as they emerge.

The respondent should always know:
- What this harvest is about (intent, plain language)
- Why they specifically are being asked (their role in the process)
- Roughly where they are — not a progress bar, but orientation ("we've covered X and Y, now exploring Z")

### Evaluation

After each response, notice what came back. The kinds of things a good interviewer notices:

- **Novel framing** — the respondent reframed the question in a way that reveals a different mental model. High signal. Explore it.
- **Unresolved tension** — contradicts something said earlier or by another respondent. Needs probing.
- **Shallow signal** — canned or surface-level answer. Try the dimension from a different angle.
- **Strong conviction** — clear, defended stance. Test it, but respect it. Don't repeatedly challenge just because it's strong.
- **Surprising connection** — linked two dimensions the model didn't anticipate. Follow the thread.
- **Diminishing returns** — confirms what's known without adding signal. Move on.

These are not a checklist. They are orientations that feed the next question generation.

### Checkpoints

At natural transition points — when a cluster of dimensions feels explored, or when returns are diminishing — offer a checkpoint:

> "We've gone deep on [dimensions covered]. I still see threads worth pulling on: [remaining threads, briefly described]. Want to continue, or should I synthesize what we have?"

The respondent co-steers. They might say "skip X, go deeper on Y" or "I'm done" or "actually, there's something we haven't touched." All productive.

Checkpoints respect the respondent's time and agency without imposing arbitrary limits. Offer them when a genuine transition point is reached, not on a timer or after a fixed count.

### Cascade (multi-person)

When harvesting multiple people on the same topic:

1. Harvest the first person fully — go deep, follow threads, reach synthesis-ready state.
2. Use that depth to generate sharper questions for the next person. They get the benefit of reacting to crystallized positions rather than answering in a vacuum.
3. Each subsequent respondent's answers enrich context for anyone who follows.
4. Deliver all questions to subsequent respondents in a single pass — don't impose artificial batch waits.

Whether and how much of prior positions to share is, again, a judgment call guided by the harvest intent. "Find independent positions" and "test alignment on X" call for different approaches.

### Synthesis

When all respondents finish, synthesize. This is a deliberate act — the model reads everything, identifies patterns, and produces an artifact that:

**Takes a stance.** Where positions diverge, recommend a direction with reasoning. Don't just present options — interpret.

**Layers disclosure.** Readable at multiple depths. First section = essential picture. Everything = full landscape.

**Links to graph.** References people, decisions, and knowledge it draws from. Not a standalone document — a node in organizational intelligence.

Throughout the harvest, maintain a running interpretive state — tracking alignment, divergence, novel framings, unresolved tensions. When synthesis time comes, you're assembling and interpreting, not starting from scratch.

The synthesis format depends on what the harvest produced. Some orientations:

**Strategic alignment (multi-person):**
- Executive summary — core alignment, key tension, recommended action
- Decisions — what converged, confidence, implications
- Divergences — positions side-by-side, reasoning, recommended direction
- Portraits — per-person reading of priorities, models, blind spots
- Appendix — full questions and answers

**Deep elicitation:**
- Summary portrait — who they are, what matters
- Key positions — structured findings per dimension
- Open questions — unresolved, needs follow-up
- Full exchange

**Decision crystallization:**
- Decision and rationale
- Considerations weighed
- Commitments — concrete next actions
- Full exchange

**Knowledge extraction:**
- Structured knowledge document
- Gaps identified
- Full exchange

**Retrospective:**
- Shared narrative
- Divergent interpretations
- Lessons and commitments
- Full exchange

These are templates for orientation, not prescribed structures. Adapt based on what actually emerged.

## Graph contract

### Nodes

```
(:Harvest {
  id: 'harvest-{date}-{topic-slug}',
  topic: String,
  intent: String,
  status: 'active' | 'complete',
  created: datetime,
  completedAt: datetime?,
  synthesisPath: String?
})

(:HarvestSession {
  id: 'harvest-{date}-{topic-slug}-{person}',
  status: 'pending' | 'active' | 'complete',
  created: datetime,
  completedAt: datetime?
})

(:HarvestTurn {
  id: '{session-id}-turn-{n}',
  turnNumber: Integer,
  question: String,
  questionIntent: String,
  answer: String?,
  evaluation: String?,
  created: datetime,
  answeredAt: datetime?
})
```

### Relationships

```
(:Harvest)-[:HAS_SESSION]->(:HarvestSession)
(:HarvestSession)-[:WITH]->(:Person)
(:HarvestSession)-[:HAS_TURN]->(:HarvestTurn)
(:Harvest)-[:INITIATED_BY]->(:Person)
(:Harvest)-[:PRODUCED]->(:Artifact)
```

### Why questionIntent and evaluation matter

`questionIntent` on each turn records *why* the model asked what it asked. `evaluation` records *how* the model read the answer. Together they make the harvest's cognitive process transparent — reviewable after the fact, and useful for future harvests on related topics.

## Invocation

A harvest can start from:

- **Direct**: `/harvest <topic>` or natural language ("I want to harvest the team on pricing")
- **Triggered**: By another process — onboarding flow, quarterly cycle, decision staleness detection. The Harvest node can be created by any process, not just human invocation.

When invoked:

1. **Understand intent.** If clear from context, proceed. If ambiguous, ask the initiator — what dimensions matter, who should participate, what context exists.
2. **Check for seed context** — relevant docs, prior harvests, graph knowledge.
3. **Begin with the first available respondent.** If the initiator is also a respondent, start with them.
4. **Cascade** to subsequent respondents as described above.

## What harvest is not

- Not a replacement for conversation. If someone wants to discuss, have a conversation. Harvest is for deliberate signal extraction.
- Not a performance review. Captures positions and knowledge — doesn't judge people.
- Not a data collection form. If you need structured field entry, that's different. Harvest is for what only emerges through adaptive questioning.
