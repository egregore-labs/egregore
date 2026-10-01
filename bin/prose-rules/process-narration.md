---
name: process-narration
description: A commit or handoff that records that a conversation happened instead of what it decided.
tier: mechanical
severity: block
surfaces: [git, memory]
fix: Describe the change and the reason; the message carries the conversation's conclusion, not its existence.
patterns:
  - '\bas (?:we )?(?:discussed|mentioned|agreed)\b(?!\s+in\b)'
  - '\bas requested\b'
  - '\bper (?:our|the|your) (?:discussion|conversation|chat|call|request)\b'
  - '\baddressed (?:the )?(?:review )?(?:feedback|comments)\b'
  - '\bupdated per (?:discussion|feedback|review)\b'
  - '\bbased on (?:the )?feedback\b'
  - '\bper review\b'
---

A commit or handoff that says "addressed review feedback" or "updated per discussion" records that a conversation happened and nothing of what it decided. The reader months from now holds only the message and the diff, and the git-language rules ask for what and why, never process. Describe the change and the reason: "validate input before parsing; the old order crashed on empty bodies." The conversation is the source; the message carries its conclusion. A pointer into a document, "as mentioned in the spec," and a rate, "updated per request," are facts and pass.

## Fails

- addressed review feedback
- updated per our discussion with the reviewer

## Passes

- validate input before parsing; the old order crashed on empty bodies
- counters are updated per request; the index is updated per tenant
- as mentioned in docs/specs/prose-rule-v1.md, judgment rules warn only
- route /commit to the executor tier; every call went to the frontier model before
