---
name: filler-intensifiers
description: Intensifiers and filler adjectives that add emphasis without information.
tier: mechanical
severity: block
surfaces: [git, memory, harness, product]
fix: Delete the word, or replace it with the number or fact it stood in for.
patterns:
  - '\b(?:simply|truly|really|very|quite|incredibly|extremely|significantly)\b'
  - '\bcomprehensive(?:ly)?\b'
  - '\brobust(?:ly|ness)?\b'
---

Intensifiers and filler adjectives add emphasis without information: very, really, truly, quite, incredibly, extremely, significantly, simply, comprehensive, robust. Delete the word and the sentence says the same thing; if it now says less, the intensifier was standing in for a number or a fact, so write that instead. "Cuts session start from 24s to 4s" carries what "significantly faster" only gestures at. In essays and encounters an intensifier can be deliberate, so this rule covers commits, memory, harness files, and product copy.

## Fails

- this is a really robust and comprehensive fix
- session start is significantly faster now

## Passes

- this fix covers both runtimes
- session start drops from 24s to 4s
