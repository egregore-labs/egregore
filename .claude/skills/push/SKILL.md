---
name: push
description: "Use for /push, or 'push my branch' — pushes the current branch to origin, setting upstream on first push, before opening a PR with /pr."
---

Push current branch to remote.

## When to invoke

User says: "/push", "push my branch", "push this up", "get my branch onto GitHub", or needs the current branch pushed to origin before opening a PR.
Not this: ready to open the PR itself → `/pr` (run after push).

## Execution boundary

This is a deterministic Git transport operation. Run it inline; do not spend a
Loom/model-routing call or delegate it to another agent.

## Before anything else

Resolve the base with `bash bin/base-branch.sh` (add the managed repo name when
applicable); it prints `{base}` or fails, in which case stop.
Check `git branch --show-current`. If on a protected branch (`{base}`, `develop`,
`main`, or `master`):
  → Use the resolved base branch (default `"develop"`)
  → Create a working branch: `git fetch origin "{base}" --quiet`, then
    `git checkout --no-track -b dev/{author}/{topic-slug} "origin/{base}"`
  → Tell the user: "Creating a working branch for this..." — never mention git commands to the user.
  → Then proceed with the push.

## What to do

1. Push current branch to origin
2. Set upstream if first push

## Example

```
> /push

Pushing feature/2026-01-20-mcp-authentication...

  git push -u origin feature/2026-01-20-mcp-authentication
  ✓ Pushed

Branch is now on GitHub.
Run /pr when ready for review.
```

## Next

Run `/pr` when ready for review.
