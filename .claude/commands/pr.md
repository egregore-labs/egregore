Create a pull request for current branch targeting develop.

## What to do

1. Summarize branch changes vs develop
2. Prompt for title and description
3. Create PR via GitHub CLI targeting develop: `gh pr create --base develop`
4. Return PR URL
5. Do NOT auto-merge — explicit `/pr` means "please review this"

## Example

```
> /pr

Creating pull request...

Branch: feature/2026-01-20-mcp-authentication
Base: develop
Commits: 3 commits ahead of develop
Changes: +78 lines, -5 lines, 3 files

Title: Add MCP authentication with API key validation
       (from your last commit — edit? y/n)
> n

Description — summarize what this PR does:
> Adds API key validation to MCP server. Keys are checked against env var. Includes tests.

  Creating PR via GitHub CLI...
  gh pr create --base develop --title "..."
  ✓ PR #42 created: https://github.com/Curve-Labs/egregore/pull/42

PR targeting develop — ready for review.
When merged, oz can /release to main.
```

## Next

Share the PR link. Run `/handoff` if ending your session.
