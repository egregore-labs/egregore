---
name: commit
description: "Stage changes and create a commit with a properly formatted message. Use for /commit, or saving work locally — not sharing it (/push) or opening a pull request (/pr)."
---

Stage changes and commit with a message.

## When to invoke

User says: "/commit", "commit this", "stage and commit", "save this change locally"
Not this: sharing your commit with others → `/push` · opening a pull request → `/pr`

Message (optional): $ARGUMENTS

## Execution boundary

This is a deterministic Git operation. Run it inline through the shared Git
mechanics; do not spend a Loom/model-routing call or delegate it to another
agent. Judgment is limited to selecting relevant files and composing the
message.

## Before anything else

Resolve the base with `bash bin/base-branch.sh` (add the managed repo name when
applicable); it prints `{base}` or fails, in which case stop.
Check `git branch --show-current`. If on a protected branch (`{base}`, `develop`,
`main`, or `master`):
  → Use the resolved base branch (default `"develop"`)
  → Create a working branch: `git fetch origin "{base}" --quiet`, then
    `git checkout --no-track -b dev/{author}/{topic-slug} "origin/{base}"`
  → Tell the user: "Creating a working branch for this..." — never mention git commands to the user.
  → Then proceed with the commit.

## What to do

1. Show modified and untracked files
2. Stage relevant files (ignore build artifacts)
3. Compose the message per the convention below — suggest one derived
   from the diff, or take the user's and align it to the convention
4. Create the commit

## Message convention

Full spec: `.claude/context/commit-format.md`. Wording:
`.claude/context/git-language.md`. The short form:

- Subject `type(scope): imperative summary` — ≤ 72 chars (aim ≤ 50),
  lowercase, no trailing period. Same grammar and type set as PR
  titles. It completes "if applied, this commit will ___".
- Body (when the diff cannot explain its own motivation): blank line
  after the subject, wrapped at 72, what and why — never how.
- Agent-authored commits end with a trailer block as the final
  paragraph:

  ```bash
  cat .egregore-session-id
  git commit -m "feat(mcp): add API key authentication" -m "Egregore-Session: {session-id}
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
  ```

  Read the id with the first command (a plain command) and paste it as
  `{session-id}`. When the file is absent, omit the `Egregore-Session` line;
  use your harness's own identity line. Humans committing by hand skip trailers.
- One logical change per commit — split when the parts are
  independently revertable.

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
> feat(mcp): add API key authentication

  git commit -m "feat(mcp): add API key authentication"  # + trailer block
  ✓ Committed (abc1234)

Changes committed locally. Run /push to share, or /pr when ready for review.
```

## With message argument

```
> /commit docs(readme): fix typo

Staging and committing...
  git add -A
  git commit -m "docs(readme): fix typo"
  ✓ Committed (def5678)
```

## Next

Run `/push` to share, or keep working and commit again.
