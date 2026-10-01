---
name: hedging-stack
description: Two or more hedges on one claim.
tier: mechanical
severity: block
surfaces: all
fix: Decide. If the claim is uncertain, say how uncertain and why, once.
patterns:
  - '\b(?:might|may|could|would|can)\s+(?:perhaps|possibly|potentially|arguably|conceivably|maybe)\b'
  - '\b(?:perhaps|possibly|potentially|arguably)\s+(?:might|may|could)\b'
  - '\bcould be seen as\b'
  - '\bit could be argued\b'
  - '\bin some sense\b'
---

Stacked hedges, "might potentially," "could perhaps be seen as," protect the writer from every reading and commit to none. One hedge states uncertainty; two state that the writer has not decided what they think. Decide. If the claim is uncertain, say how uncertain and why, once: "likely, because the two measured cases agree" or "unverified; the runner was down."

## Fails

- this might potentially reduce latency
- the gate could perhaps be seen as redundant

## Passes

- this reduces latency in the two cases we measured
- the gate may be redundant; the hook already blocks the same write
