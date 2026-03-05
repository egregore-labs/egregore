Push current branch to remote.

## Before anything else

Check `git branch --show-current`. If on `develop`, `main`, or `master`:
  → Create a working branch first: derive a topic slug from the changes or conversation context, then `git fetch origin develop --quiet && git checkout -b dev/{author}/{topic-slug} origin/develop`
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
