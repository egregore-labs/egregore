---
name: passive-enthusiasm
description: Launch theater that announces the writer's feelings instead of the thing.
tier: mechanical
severity: block
surfaces: all
fix: Publish the capability: what exists, what someone can do with it now, how to verify it.
patterns:
  - '\b(?:excited|thrilled|delighted|proud|happy|pleased|stoked)\s+to\s+(?:announce|share|introduce|unveil|launch|present|reveal)\b'
  - '\bwe(?:''re| are)\s+(?:so\s+)?(?:excited|thrilled|delighted|proud)\b'
  - '\bthe future of\s+\w+(?:\s+\w+)?\s+is\b'
---

Launch theater announces the writer's feelings about the thing instead of the thing. "We're excited to announce," "thrilled to share," "the future of work is here" are sentences any company could publish and none can be held to; the communications rulebook lists them as the first thing to cut. Publish the capability: what exists, what someone can do with it now, and how to verify it. Enthusiasm the reader can see for themselves needs no announcing.

## Fails

- We're excited to announce the new runtime.
- Thrilled to share what we built this week.
- The future of collaboration is multiplayer.

## Passes

- The runtime ships today; run egregore update to get it.
- Two people can now edit one handoff and see each other's changes.
