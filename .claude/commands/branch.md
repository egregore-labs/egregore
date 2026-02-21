Create a working branch from what you're working on.

Description: $ARGUMENTS

## What to do

1. Fetch latest develop
2. Derive a topic slug from the description (lowercase, hyphens, no special chars, max 40 chars)
3. Determine branch type from description:
   - `dev/{author}/{topic-slug}` — default for session work
   - `feature/{topic-slug}` — explicit feature work
   - `bugfix/{topic-slug}` — bug fixes
4. Create branch from develop
5. Switch to the new branch

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

## Example

```
> /branch auth flow

Creating branch...

  git fetch origin develop --quiet
  git checkout -b dev/alice/auth-flow origin/develop
  ✓ Created dev/alice/auth-flow (from develop)

Ready to work. /save when done.
```

```
> /branch fix payment endpoint bug

Creating branch...

  git fetch origin develop --quiet
  git checkout -b bugfix/fix-payment-endpoint origin/develop
  ✓ Created bugfix/fix-payment-endpoint (from develop)

Ready to work. /save when done.
```

```
> /branch

No description given. Using today's date.

  git checkout -b dev/alice/2026-02-12 origin/develop
  ✓ Created dev/alice/2026-02-12 (from develop)

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
