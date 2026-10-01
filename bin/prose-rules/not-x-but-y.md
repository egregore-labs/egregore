---
name: not-x-but-y
description: The correlative "not just X, but Y" and its split form "isn't just X. It's Y."
tier: mechanical
severity: block
surfaces: all
fix: State Y. If the distinction from X matters, name who holds X and why they are wrong, in its own sentence.
patterns:
  - '\bnot\s+(?:just|only|merely|simply)\s+[^.;:!?]{1,80}?\bbut\b'
  - '\b(?:isn''t|is not|aren''t|are not|wasn''t|was not)\s+(?:just|only|merely|simply)\s+[^.;:!?]{1,80}\.\s+(?:it''s|it is|they''re|they are|but)\b'
---

The correlative "not just X, but Y" and its split form "isn't just X. It's Y." manufacture contrast: they set up a claim nobody made in order to knock it down, and the reader gets the sound of insight without a new fact. The communications rulebook calls this synthetic contrast and lists its cousins, "Not X. Y." and "X is changing, but Y shouldn't." The patterns here catch the forms with a hedge word; the bare "Not X. Y." shape needs judgment. State Y. If the distinction from X matters, name who holds X and why they are wrong, in a sentence of its own.

## Fails

- Egregore is not just a tool, but a participant
- This isn't just memory. It's cognition.

## Passes

- Egregore is a participant in the work
- The result is not verified, but the build passed
