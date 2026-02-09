Create a feature or bugfix branch with consistent naming.

Description: $ARGUMENTS

## What to do

1. Fetch latest develop
2. Determine branch type (feature/bugfix) from description
3. Create branch from develop with date-prefixed name
4. Switch to the new branch

## Naming convention

```
feature/YYYY-MM-DD-short-description
bugfix/YYYY-MM-DD-short-description
```

## Example

```
> /branch mcp authentication

Creating branch...

Convention: feature/YYYY-MM-DD-short-description
            bugfix/YYYY-MM-DD-short-description

This looks like a feature.

  git fetch origin develop --quiet
  git checkout -b feature/2026-01-20-mcp-authentication origin/develop
  ✓ Created and switched to feature/2026-01-20-mcp-authentication (from develop)

You're now on a feature branch. When ready:
- /commit to save your work
- /pr when ready for review
```

## Next

Make your changes, then `/commit` when ready.
