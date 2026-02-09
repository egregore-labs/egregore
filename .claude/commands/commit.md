Stage changes and commit with a message.

Message (optional): $ARGUMENTS

## What to do

1. Show modified and untracked files
2. Stage relevant files (ignore build artifacts)
3. Prompt for or suggest commit message
4. Create the commit

## Example

```
> /commit

Checking changes...

Modified files:
  src/mcp/auth.py        (+42, -3)
  src/mcp/server.py      (+8, -2)
  tests/test_auth.py     (+28, new file)

Untracked:
  src/mcp/__pycache__/   (ignored ✓)

Staging modified files...
  git add src/mcp/auth.py src/mcp/server.py tests/test_auth.py

Enter commit message (or I can suggest one):
> Add MCP authentication with API key validation

  git commit -m "Add MCP authentication with API key validation"
  ✓ Committed (abc1234)

Changes committed locally. Run /push to share, or /pr when ready for review.
```

## With message argument

```
> /commit fix typo in readme

Staging and committing...
  git add -A
  git commit -m "fix typo in readme"
  ✓ Committed (def5678)
```

## Next

Run `/push` to share, or keep working and commit again.
