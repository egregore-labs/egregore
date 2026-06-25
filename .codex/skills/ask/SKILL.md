---
name: ask
description: Ask an asynchronous Egregore question to a teammate when the user invokes /ask or $ask, or help the current user formulate inward reflection questions.
---

# Egregore Ask

Native Codex Egregore skill. Use this when the user wants to ask a teammate a
question, run a topic by someone, or inspect pending questions for themselves.

## Flow

1. Run `bin/agent.sh sync`.
2. Resolve the current author from `.egregore-state.json`, then git config.
3. Load people from `memory/people/*.md`. Match target names against filename,
   `name:`, `github:`, and heading text, case-insensitively. Strip leading `@`.
4. If the user named a target, draft one to four concrete questions. In
   connected mode, optionally gather context with `bin/graph.sh` queries, but
   suppress raw JSON and continue from memory files if graph access fails.
5. Preview the exact questions and target. Use structured Codex question
   tooling when available; otherwise render:

```text
Send these questions?
1. Send as-is
2. Edit
Other:
```

6. For each approved question, run:

```bash
bin/agent.sh ask --from "$AUTHOR" --to "$TARGET" --topic "$TOPIC" --question "$QUESTION"
```

Add harvest flags only when this ask is part of a harvest:
`--harvest-id`, `--harvest-session-id`, `--turn`, `--question-intent`, and
`--context-mode`.

7. In connected mode, notify best-effort with:

```bash
bash bin/notify.sh send "$TARGET" "$AUTHOR has a question about \"$TOPIC\". Ask for \$activity to answer."
```

8. Report the created `memory/knowledge/questions/...` path.

## Inward Mode

If no target matches, do not create a question file. Generate a small set of
questions for the user to answer in-session, grounded in current conversation
and memory context. Offer to save the result as a reflection only after the user
answers.

## Rules

- Person-targeted asks are asynchronous: store, optionally notify, then stop.
- Local mode is filesystem-only; skip graph and notification calls.
- Do not use Claude Code commands.
