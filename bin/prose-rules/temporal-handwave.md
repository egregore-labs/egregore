---
name: temporal-handwave
description: Urgency borrowed from the calendar because the sentence has none of its own.
tier: mechanical
severity: block
surfaces: all
fix: Cut it and start with the specific change or fact; if timing matters, give the date or the release.
patterns:
  - '\bin today''s\s+(?:fast[- ]paced|rapidly|ever[- ]changing|digital|modern|competitive|world)\b'
  - '\bin (?:an|the) (?:era|age) (?:of|where)\b'
  - '\bin a world where\b'
  - '\bnow more than ever\b'
  - '\bin (?:these|this) (?:uncertain|unprecedented|challenging) times?\b'
  - '\bas (?:ai|technology) (?:continues to )?(?:evolve|advance|transform)s?\b'
---

Temporal hand-waving, "in today's fast-paced world," "in the age of AI," "now more than ever," borrows urgency from the calendar because the sentence has none of its own. It is true of every year and so says nothing about this one, and the reader has learned that the real claim starts after the comma. Cut it and start with the specific change or fact. If timing matters, give the date or the release.

## Fails

- In today's fast-paced world, teams lose context between sessions.
- Now more than ever, memory matters.

## Passes

- Teams lose context between sessions.
- Since the September runtime release, memory syncs on session start.
