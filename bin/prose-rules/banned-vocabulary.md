---
name: banned-vocabulary
description: Words from the voice-bedrock banned list, in any register.
tier: mechanical
severity: block
surfaces: all
fix: Replace with the plain word (examine, use, together, simplify) or rewrite around it.
patterns:
  - '\bdelv(?:e|es|ed|ing)\b'
  - '\bleverag(?:es|ed|ing)\b'
  - '\bleverage\s+(?:the|our|your|its|their|a|an|this|that|these|those|existing)\b'
  - '\butili[sz](?:e|es|ed|ing)\b'
  - '\bsynerg(?:y|ies|istic|ize|ise)\b'
  - '\bholistic(?:ally)?\b'
  - '\bstreamlin(?:e|es|ed|ing)\b'
  - '\bseamless(?:ly)?\b'
  - '\beffortless(?:ly)?\b'
  - '\bgame[- ]chang(?:er|ers|ing)\b'
  - '\bdeep[- ]dive\b'
  - '\bcutting[- ]edge\b'
  - '\bstate[- ]of[- ]the[- ]art\b'
  - '\btouch base\b'
  - '\bcircle back\b'
  - '\bunlock(?:s|ed|ing)?\s+(?:\w+\s+)?potential\b'
  - '\bempower(?:s|ed|ing|ment)?\b'
---

These words appear in AI-written and brochure prose far more often than in speech, and each has a plainer replacement: examine for delve, use for leverage and utilize, together for synergy, simplify for streamline, without manual steps for seamlessly. A reader who meets one stops trusting the rest of the paragraph. The list is fixed by voice-bedrock. The noun "leverage" in its literal sense, as in the audit skill's leverage function, is allowed; the verb is not. If a banned word is needed in its literal sense, quote the source or rewrite around it.

## Fails

- we should leverage the graph to delve into the handoff
- a seamless, cutting-edge onboarding that empowers teams
- let's circle back and touch base after the deep dive

## Passes

- we should use the graph to examine the handoff
- the leverage function ranks findings by blast radius
- the tests pass without manual steps
