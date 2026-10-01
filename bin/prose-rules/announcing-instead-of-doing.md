---
name: announcing-instead-of-doing
description: A sentence that promises an explanation instead of giving it.
tier: mechanical
severity: block
surfaces: all
fix: Do the thing: state the mechanism, give the result, list the steps.
patterns:
  - '^\s*(?:let me|i(?:''ll| will) now|i(?:''m| am) going to|i(?:''m| am) about to|allow me to)\b'
  - '\bin this (?:post|section|document|article|guide|handoff),?\s+(?:we|i)(?:''ll| will)?\s*(?:cover|walk|explain|discuss|look at|explore|go over)\b'
  - '\bthis (?:post|document|section|handoff|guide) (?:will|aims to|is going to)\b'
---

Announcing an action instead of performing it, "Let me explain how this works," "In this section we'll cover three things," spends the reader's first sentence on a promise. Written artifacts are read after the fact; the announcement has no one to reassure, and a heading already says what the section covers. Do the thing: state the mechanism, give the result, list the steps. In-session chat has its own rule for saying what happens next; this one covers what gets written down.

## Fails

- Let me explain how the checker works.
- In this handoff, we'll cover three things.

## Passes

- The checker strips code blocks, then runs each pattern per line.
- Three things changed.
