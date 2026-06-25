---
name: wrap
description: Wrap an Egregore session when the user invokes /wrap or $wrap, or says they are done, wrapping up, or at a stopping point in Codex.
---

# Egregore Wrap

Native Codex Egregore skill. Use this inside an Egregore checkout with
`bin/agent.sh`.

## Flow

1. Synthesize a topic, a one to three sentence summary, and concise open notes
   from the current session.
2. If the session has ambiguous or potentially misleading state, confirm with
   the user. Use structured Codex question tooling when available; otherwise
   show numbered choices plus `Other:` and wait.
3. Resolve the author from `.egregore-state.json` `github_username`, then
   `name`, then git config.
4. Write the notes to a temp markdown file.
5. Run:

```bash
bin/agent.sh wrap --from "$AUTHOR" --topic "$TOPIC" --summary "$SUMMARY" --body-file "$BODY_FILE"
```

6. If `git status --porcelain` reports repo changes after the wrap, run:

```bash
bin/agent.sh save --message "Wrap: $TOPIC" --topic "$TOPIC"
```

7. Report the `memory/wraps/...` path and whether code changes were saved.

## Output

Structured UX parity is required. Finish with the standard Egregore wrap
confirmation TUI, not a prose-only summary:

- Use a 72-column outer box with only the four standard line patterns:
  top rule, separator rule, content line, bottom rule.
- Header: `WRAP`, author, and date.
- Body: topic, one compact summary, open threads or "No open threads", and
  the `memory/wraps/...` path.
- Footer: saved/pushed status. If code changes were saved, show that. If the
  wrap only touched memory, say so.
- Output the box directly, preferably in a `text` fenced block, with no
  narration before it.

## Rules

- Do not use Claude Code commands.
- Do not invent finished work. Separate completed work, verification, and open
  follow-ups.
- If save fails, report the failure and leave the local commits untouched.
