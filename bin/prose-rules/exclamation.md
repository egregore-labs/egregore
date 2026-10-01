---
name: exclamation
description: An exclamation mark outside quoted speech or code.
tier: mechanical
severity: block
surfaces: all
fix: End the sentence with a period; if it needs the mark to sound alive, rewrite the sentence.
patterns:
  - '(?<=\S)!(?=\s|$)'
---

An exclamation mark performs enthusiasm the sentence should carry on its own. In every Egregore register it reads as forced, and in product copy it reads as an assistant congratulating itself. Quoted user speech keeps its punctuation, which is why blockquotes are exempt, and code is never prose. Everything else ends in a period. If the sentence needs the mark to sound alive, the problem is the sentence.

## Fails

- Saved and pushed!
- Great question! Here is the answer.

## Passes

- Saved. Pushed. PR #47 created.
- > "Ship it!"
- run `git status` and check `!=` in the diff
- ![greeting](banner.png)
