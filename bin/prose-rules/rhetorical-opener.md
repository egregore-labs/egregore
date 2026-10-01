---
name: rhetorical-opener
description: A document that opens with a rhetorical question or an invitation to imagine.
tier: mechanical
severity: block
surfaces: all
position: opening
fix: Open with the fact, the decision, or the thing that exists.
patterns:
  - '^\s*(?:what if|imagine|have you ever|ever wonder(?:ed)?|picture this|why do we|what would happen if|isn''t it time)\b'
---

A document that opens with a rhetorical question or an invitation to imagine delays its first fact to build suspense the reader did not ask for. "What if your team could remember everything?" is a claim wearing a question mark. Open with the fact, the decision, or the thing that exists. The reader who wants the horizon will keep reading; the reader who wants the point has it. This rule reads only the first prose paragraph, so a question later in the text, asked because the writer needs the answer, is untouched.

## Fails

- What if your team never lost context again?
- Imagine a session that remembers you.

## Passes

- Egregore keeps context across sessions and people.
- The hook runs before every write.
