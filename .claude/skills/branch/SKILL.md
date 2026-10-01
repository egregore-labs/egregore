---
name: branch
description: "Create a working branch from what you are about to work on. Use for /branch, or any request to start a new branch before making changes."
---

Create a working branch from what you're working on.

## When to invoke

User says: "/branch", "create a branch", "start a new branch", or any request to begin a working branch for what they're about to do

Description: $ARGUMENTS

## What to do

Resolve the configured integration branch first:
```bash
bash bin/base-branch.sh
```
It prints the branch name; for a managed repo run `bash bin/base-branch.sh <repo-name>`.
A non-zero exit means the configuration could not be resolved: stop before any
Git change. Use the printed name wherever `{base}` appears below.

1. Derive a topic slug from the description (lowercase, hyphens, no special chars, max 40 chars)
2. Determine branch type from description:
   - `dev/{author}/{topic-slug}` — default for session work
   - `feature/{topic-slug}` — explicit feature work
   - `bugfix/{topic-slug}` — bug fixes
3. Create the task workspace (a worktree when available and permitted in this session; otherwise a branch from the integration branch), using the topic slug as its name

**Claude Code:** The WorktreeCreate hook handles everything: fetches the configured base branch, creates the branch, creates the worktree, sets up symlinks.

**Fallback:** If worktree creation is unavailable, not permitted in this session, or fails, fall back to: `git checkout --no-track -b {branch-name} "origin/{base}"`

The task branch must not inherit `origin/{base}` as its upstream. The
first `/push` sets upstream with `-u origin "$BRANCH"`, creating and tracking
the same-name remote task branch.

## Deriving the topic slug

Extract the essence of what the user said into a short, meaningful slug:
- "auth flow in frontend" → `auth-flow`
- "fix the payment endpoint bug" → `fix-payment-endpoint`
- "refactoring the token store" → `refactor-token-store`
- "working on oauth implementation" → `oauth-implementation`

If no description is given, use today's date: `YYYY-MM-DD`

## Branch type detection

- Description mentions "fix", "bug", "broken", "crash" → `bugfix/`
- Description mentions "feature", "add", "implement", "new" → `feature/`
- Otherwise → `dev/{author}/` (general session work)

## Resuming existing branches

Before creating, use `{author}` for the active actor's GitHub login from the resolved identity and `{topic_slug}` from the description above to check for a matching branch; single-quote supplied values and write embedded single quotes as `'\''`:
```bash
git branch --list 'dev/{author}/*{topic_slug}*' 'feature/*{topic_slug}*' 'bugfix/*{topic_slug}*'
```

If a match is found, offer to resume it instead of creating a new one.

## Reusing current worktree

If already in a worktree and the user needs a new branch (e.g., after their PR was merged):
1. Do NOT exit the worktree or create a new one
2. Fetch `{base}`, the integration branch printed above:
   ```bash
   git fetch origin '{base}' --quiet
   ```
   Use `{author}` for the active actor's GitHub login from the resolved identity and `{new_slug}` from the new topic description to create the new branch in this worktree:
   ```bash
   git checkout --no-track -b 'dev/{author}/{new_slug}' 'origin/{base}'
   ```
3. The worktree directory stays the same — only the branch changes
4. Confirm: `Switched to dev/{author}/{new_slug} (same worktree).`

## Example

```
> /branch auth flow

Creating branch...

  git fetch origin "{base}" --quiet
  git branch dev/alice/auth-flow "origin/{base}"
  Task workspace → .claude/worktrees/auth-flow/
  git checkout dev/alice/auth-flow
  bash '<main-dir>/bin/worktree.sh' setup . '<main-dir>'
  ✓ Created dev/alice/auth-flow (worktree, from configured base)

Ready to work. /save when done.
```

```
> /branch fix payment endpoint bug

Creating branch...

  git fetch origin "{base}" --quiet
  git branch bugfix/fix-payment-endpoint "origin/{base}"
  Task workspace → .claude/worktrees/fix-payment-endpoint/
  git checkout bugfix/fix-payment-endpoint
  ✓ Created bugfix/fix-payment-endpoint (worktree, from configured base)

Ready to work. /save when done.
```

```
> /branch

No description given. Using today's date.

  git branch dev/alice/2026-02-12 "origin/{base}"
  Task workspace → .claude/worktrees/2026-02-12/
  git checkout dev/alice/2026-02-12
  ✓ Created dev/alice/2026-02-12 (worktree, from configured base)

Ready to work. /save when done.
```

## Managed repos

If the user's description references a managed repo (listed in `egregore.json` → `repos[]`), create the branch in that repo's sibling directory instead of the hub.

The managed repo lives beside the main checkout. Resolve its base, then locate
the main checkout with `git rev-parse` below. The printed common Git directory's
parent is the main checkout; the managed repo is that directory's sibling
`<repo-name>`.
```bash
bash bin/base-branch.sh <repo-name>
git rev-parse --path-format=absolute --git-common-dir
git -C "<main-checkout-parent>/<repo-name>" fetch origin "{base}" --quiet
git -C "<main-checkout-parent>/<repo-name>" checkout --no-track -b dev/{author}/{topic-slug} "origin/{base}"
```

Use `git -C` with absolute paths — never `cd` into the repo.

```
> /branch auth flow in frontend

Creating branch in frontend...

  git -C ../frontend fetch origin main --quiet
  git -C ../frontend checkout --no-track -b dev/alice/auth-flow origin/main
  ✓ Created dev/alice/auth-flow in frontend (from main)

Ready to work. /save when done.
```

## Next

Make your changes, then `/commit` or `/save` when ready.
