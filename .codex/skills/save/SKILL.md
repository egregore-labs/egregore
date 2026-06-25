---
name: save
description: Save Egregore work when the user invokes /save or $save, or asks to commit, push, sync, or save current changes from a Codex Egregore session.
---

# Egregore Save

Native Codex Egregore skill. This is the user-facing abstraction for the git
and memory workflow: users should be able to say "save this" without knowing
which branch, commit, push, pull request, or memory sync steps are required.

## Flow

1. Confirm this is an Egregore checkout by checking for `bin/agent.sh`.
2. Inspect state silently:

```bash
git status --short
git status --short memory 2>/dev/null || true
git branch --show-current
```

3. If there are no repo or memory changes, say everything is already saved and
   stop.
4. Synthesize:
   - a short topic from the work,
   - a clear commit message,
   - a one-line user-facing scope summary.
5. If the scope is ambiguous or includes unrelated changes, ask for one compact
   confirmation. Use structured Codex question tooling when available;
   otherwise render:

```text
Save these changes?
1. Save all
2. Narrow scope
Other:
```

6. Run the bridge command:

```bash
bin/agent.sh save --message "$MESSAGE" --topic "$TOPIC"
```

The bridge owns the mechanical workflow: sync memory, ensure a task branch,
commit repo changes, push, and create or reuse a pull request when available.

7. Parse the output and report only useful user information:
   - branch name,
   - whether a commit was created,
   - whether push succeeded,
   - pull request URL if present,
   - memory sync status.

## Rules

- Do not ask the user to run git commands.
- Do not expose implementation detail unless save fails.
- If save fails, say which step failed and leave the branch/path clear.
- Never run destructive git commands.
- Do not use Claude Code commands.
