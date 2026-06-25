---
name: the-spiral
description: Run a Codex-native structured Socratic dialogue when the user invokes /the-spiral or $the-spiral to turn an intuition into rigorous, communicable output.
---

# The Spiral

Native Codex Egregore skill. The Spiral is a stateful Socratic process for
developing, pressure-testing, and compressing a complex thesis.

## Setup

Gather three inputs, using structured Codex question tooling when available and
plain one-at-a-time questions otherwise:

1. Domain: what are we spiraling on?
2. Purpose: what should the process produce?
3. Known areas: what domains must be covered, if any?

Create state files:

```text
spiral_state.json
spiral_artifacts/ring1
spiral_artifacts/ring2
spiral_artifacts/ring3
spiral_artifacts/ring4
spiral_artifacts/ring5
```

State includes domain, purpose, addressable space, current ring, current loop,
artifacts, emerged domains, parked threads, descents, and ring history.

## Rings

1. Seed: find the irreducible claim. Artifact:
   `spiral_artifacts/ring1/seed.md`.
2. Territory: map implications, tensions, contradictions, and open questions.
   Artifact: `spiral_artifacts/ring2/territory.md`.
3. Encounter: ground claims in reality. Research facts when needed and write
   domain artifacts under `spiral_artifacts/ring3/`.
4. Crucible: test objections and disconfirming evidence. Artifact:
   `spiral_artifacts/ring4/crucible.md`.
5. Compression: produce the final deliverables under
   `spiral_artifacts/ring5/`.

Ask one question at a time. After each alignment check, update
`spiral_state.json`. Render a compact text progress view only at setup,
alignment checks, ring transitions, descents, resume, and completion.

## TUI Rendering

Structured UX parity is required. The Spiral must present state as a structured
terminal view at phase boundaries, not as loose paragraphs:

- Show rings 1-5 with current/completed/parked status.
- Show current thesis, emerged domains, parked threads, descents, and next
  question or alignment check.
- Render only at setup, alignment checks, ring transitions, descents, resume,
  and completion.
- On completion, render a final structured view with rings completed, loop
  count, deliverable paths, emerged domains, and parked threads.
- Do not render mid-flow while asking a Socratic question.

## Flow Rules

- If the user gives a marketing-like answer in Ring 1, push toward the real
  conviction.
- If an objection breaks an earlier assumption, offer a descent to the right
  ring and record the reason.
- Research is active only when factual claims need grounding or pressure.
- Never force a domain that has not emerged from the user's answers.
- If the user is tired or wants to pause, crystallize the current state and
  stop at an alignment boundary.

## Resume

If `spiral_state.json` exists, summarize domain, ring, loop, and current
artifacts, then ask whether to continue or start fresh.

## Completion

The process ends when Ring 5 deliverables satisfy the user. Report artifact
paths, rings completed, loop count, emerged domains, and any parked threads.
