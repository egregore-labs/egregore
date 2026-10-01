---
name: self-praise
description: Adjectives that grade the writer's own work instead of describing it.
tier: mechanical
severity: warn
surfaces: all
fix: Describe the mechanism and the result; let the reader supply the adjective.
patterns:
  - '\b(?:innovative|revolutionary|groundbreaking|world[- ]class|best[- ]in[- ]class|next[- ]gen(?:eration)?|visionary|disruptive)\b'
---

Calling your own work innovative, revolutionary, or world-class asks the reader to take on trust the judgment the work was supposed to earn. The adjectives carry no information about what the thing does, and readers discount everything near them. Describe the mechanism and the result; let the reader supply the adjective. This rule warns rather than blocks because the same words have literal uses in analysis, as in a history of a revolutionary period.

## Fails

- an innovative, world-class memory layer
- a groundbreaking approach to team context

## Passes

- a memory layer that survives across sessions and people
- context that a teammate can enter and continue
