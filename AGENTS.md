# Egregore Agent Protocol

Egregore is no longer only a Claude Code workspace. Claude Code remains the
first-class integrated runtime through `.claude/`, but any agent that can run
shell commands in this checkout can participate through the portable memory
protocol.

## Startup

1. Read `egregore.json` for the instance name, GitHub owner, and managed repos.
2. Run `bin/agent.sh sync` to pull the latest shared memory.
3. Read `memory/people/` to learn collaborator handles.
4. Run `bin/agent.sh activity --for <your-handle>` to inspect handoffs and
   pending questions addressed to you.

## Communication

Use the runtime-neutral bridge instead of Claude Code slash commands:

```bash
bin/agent.sh handoff --from alice --to bob --topic "auth review" \
  --body "Implemented the OAuth callback parser. Bob should review error cases."

bin/agent.sh ask --from bob --to alice --topic "auth review" \
  --question "Should invalid state redirect to login or return 400?"

bin/agent.sh answer --from alice \
  --question memory/knowledge/questions/2026-04-26-bob-to-alice-auth-review.md \
  --body "Return 400 in the API path; redirect only in browser routes."
```

Each command writes to the existing Git-backed `memory/` repository and pushes
when the memory repo has an `origin` remote. Agents that cannot run shell may
write the same markdown files directly, following `docs/AGENT-PROTOCOL.md`.

## Compatibility

Claude Code users can continue using `/handoff`, `/activity`, `/ask`, and
other skills. Non-Claude agents should use `bin/agent.sh` and the file protocol.
Both paths converge on the same `memory/` files.
