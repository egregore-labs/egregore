---
name: self-contained
description: A reference that only resolves inside the session that wrote it.
tier: judgment
severity: warn
surfaces: [git, memory, harness]
fix: Name the file, command, person, or decision; introduce a concept before using it; link what you cite.
---

Text that leaves the session must resolve on its own. "Fixed the thing from earlier," "went with the second option," "see above" point at a conversation the reader never saw, and a bare "it" pointing outside the message has no referent at all. Introduce every concept before using it, name the file, command, person, or decision, and link what you cite. The test for any sentence: an agent with no memory of this session could act on it correctly. If not, add the missing name or number.

## Fails

- went with the second option, see above
- fixed the thing from earlier so it works now

## Passes

- chose log-only mode for the first cycle, per the harness-evolution spec §5.6
- fixed the exclamation pattern so image syntax no longer matches
