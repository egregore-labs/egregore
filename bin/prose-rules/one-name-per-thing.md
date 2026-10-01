---
name: one-name-per-thing
description: A synonym introduced for variety that reads as a second thing.
tier: judgment
severity: warn
surfaces: [git, memory, harness, product]
fix: Pick the recorded name and repeat it every time the thing appears.
---

Use the organization's established term for a thing every time it appears. A synonym introduced for variety reads as a second thing: if the org says handoff, then "session summary" is either a different artifact or a mistake, and the reader has to find out which. Instructions, commits, and documentation repeat; variety is for essays. Pick the recorded name and use it in the heading, the body, and the code.

## Fails

- the handoff is saved; the session summary is then indexed
- open the task board, then update the plate

## Passes

- the handoff is saved; the handoff is then indexed
- open the plate, then update the plate
