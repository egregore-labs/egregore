---
name: pull
description: "Use for /pull when you need to sync the current branch and shared memory. Activity and dashboard are read-only and never sync repositories."
---

Pull latest for current repo and shared memory.

**Note:** `/activity` and `/dashboard` are read-only. Use `/pull` for explicit
synchronization.

## When to invoke

User says: "/pull", "pull latest", "sync my branch", "get the latest changes", "update memory", or needs to sync without also viewing activity.
Not this: only want to see recent activity → `/activity` (read-only).

## Execution boundary

This is a deterministic sync-transport operation. Run it inline; do not spend
a Loom/model-routing call or delegate it to another agent.

## What to do

Run:

```bash
bash bin/pull.sh
```

The command resolves the base with `bash bin/base-branch.sh`, fetches it, and rebases
a task branch onto `origin/<base>`. It fast-forwards the base branch itself,
merges when a rebase conflicts, and leaves a conflict for you with the tree
restored if both attempts fail. When the memory link is missing, it links the
memory checkout beside the main checkout, then syncs memory through the Runtime.

Show its report to the user as is. Exit 1 means something needs a hand; the
report says what. Managed repositories are not synced by this command.

## Output

Show what arrived — don't leave the user wondering if things synced:

```
Pulling...
  configured base ↓ 3 commits → synced
  dev/oz/...      ✓ rebased onto configured base
  memory         ↓ 2 commits — 4 files updated
                   handoffs/2026-02/12-renckorzay-giza-docs.md (new)
                   handoffs/index.md
                   artifacts/giza-architecture.md (new)
                   artifacts/giza-api-spec.md (new)
```

If memory is already up to date:
```
  memory         ✓ up to date
```
