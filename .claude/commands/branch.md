Create a working branch from what you're working on.

Description: $ARGUMENTS

## What to do

1. Derive a topic slug from the description (lowercase, hyphens, no special chars, max 40 chars)
2. Determine branch type from description:
   - `dev/{author}/{topic-slug}` — default for session work
   - `feature/{topic-slug}` — explicit feature work
   - `bugfix/{topic-slug}` — bug fixes
3. Call `EnterWorktree` with `name` set to the topic slug

The WorktreeCreate hook handles everything: fetches develop, creates the branch, creates the worktree, sets up symlinks.

**Fallback:** If `EnterWorktree` fails, fall back to: `git checkout -b {branch-name} origin/develop`

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

Before creating, check if a matching branch already exists:
```bash
git branch --list "dev/$AUTHOR/*$SLUG*" "feature/*$SLUG*" "bugfix/*$SLUG*"
```

If a match is found, offer to resume it instead of creating a new one.

## Reusing current worktree

If already in a worktree and the user needs a new branch (e.g., after their PR was merged):
1. Do NOT exit the worktree or create a new one
2. Create the new branch and checkout within the existing worktree:
   ```bash
   git fetch origin develop --quiet
   git checkout -b dev/$AUTHOR/$NEW_SLUG origin/develop
   ```
3. The worktree directory stays the same — only the branch changes
4. Confirm: `Switched to dev/$AUTHOR/$NEW_SLUG (same worktree).`

## Example

```
> /branch auth flow

Creating branch...

  git fetch origin develop --quiet
  git branch dev/alice/auth-flow origin/develop
  EnterWorktree → .claude/worktrees/auth-flow/
  git checkout dev/alice/auth-flow
  bash <main-dir>/bin/worktree.sh setup "$(pwd)" "<main-dir>"
  ✓ Created dev/alice/auth-flow (worktree, from develop)

Ready to work. /save when done.
```

```
> /branch fix payment endpoint bug

Creating branch...

  git fetch origin develop --quiet
  git branch bugfix/fix-payment-endpoint origin/develop
  EnterWorktree → .claude/worktrees/fix-payment-endpoint/
  git checkout bugfix/fix-payment-endpoint
  ✓ Created bugfix/fix-payment-endpoint (worktree, from develop)

Ready to work. /save when done.
```

```
> /branch

No description given. Using today's date.

  git branch dev/alice/2026-02-12 origin/develop
  EnterWorktree → .claude/worktrees/2026-02-12/
  git checkout dev/alice/2026-02-12
  ✓ Created dev/alice/2026-02-12 (worktree, from develop)

Ready to work. /save when done.
```

## Managed repos

If the user's description references a managed repo (listed in `egregore.json` → `repos[]`), create the branch in that repo's sibling directory instead of the hub.

```bash
REPO_DIR="$(cd .. && pwd)/$REPO"
git -C "$REPO_DIR" fetch origin develop --quiet
git -C "$REPO_DIR" checkout -b dev/$AUTHOR/$TOPIC_SLUG origin/develop
```

Use `git -C` with absolute paths — never `cd` into the repo.

```
> /branch auth flow in frontend

Creating branch in frontend...

  git -C ../frontend fetch origin develop --quiet
  git -C ../frontend checkout -b dev/alice/auth-flow origin/develop
  ✓ Created dev/alice/auth-flow in frontend (from develop)

Ready to work. /save when done.
```

## Next

Make your changes, then `/commit` or `/save` when ready.
