# Runtime-Agnostic Agent Protocol

Egregore's durable collaboration layer is the Git-backed `memory/` repository.
Claude Code adds hooks, slash commands, and onboarding UX on top of that layer.
This protocol exposes the same shared substrate to Codex, terminal agents,
editor agents, CI agents, or any other runtime that can read and write files.

## Goals

- Preserve existing Claude Code behavior.
- Let multiple people use different agent runtimes in the same Egregore.
- Avoid requiring hosted Egregore services for basic collaboration.
- Keep handoffs, questions, answers, and activity inspectable as markdown.

## Required Local Shape

An agent needs an Egregore checkout with:

```text
egregore/
  egregore.json
  bin/agent.sh
  memory -> ../<egregore-memory>/

<egregore-memory>/
  people/
  handoffs/
  knowledge/questions/
```

The existing installers already create the core checkout and symlinked memory
repo. Non-Claude runtimes can join with the same GitHub access and then use
`bin/agent.sh` directly.

## Command Surface

```bash
bin/agent.sh sync
bin/agent.sh people
bin/agent.sh activity --for <person>
bin/agent.sh handoff --from <person> --to <person> --topic <topic> --body <text>
bin/agent.sh ask --from <person> --to <person> --topic <topic> --question <text>
bin/agent.sh answer --from <person> --question <path> --body <text>
```

`handoff` reuses the existing `bin/handoff-run.sh` writer, so generic agents
create the same `memory/handoffs/YYYY-MM/DD-author-topic.md` records that
Claude Code sessions create. `ask` and `answer` use
`memory/knowledge/questions/` for asynchronous questions when graph services
are unavailable.

## Two-Agent Exchange

Agent A:

```bash
bin/agent.sh sync
bin/agent.sh handoff --from codex-a --to codex-b --topic "relay smoke" \
  --body "I created the first shared handoff from a non-Claude runtime."
```

Agent B:

```bash
bin/agent.sh sync
bin/agent.sh activity --for codex-b
bin/agent.sh ask --from codex-b --to codex-a --topic "relay smoke" \
  --question "What should I verify next?"
```

Agent A:

```bash
bin/agent.sh sync
bin/agent.sh activity --for codex-a
bin/agent.sh answer --from codex-a \
  --question memory/knowledge/questions/<question-file>.md \
  --body "Verify that the handoff and question survive a fresh clone."
```

Both agents communicate through Git and markdown. Their runtimes do not need to
share a process, model provider, hook system, or hosted graph connection.

## File Contracts

### Handoffs

Handoffs are stored under `memory/handoffs/YYYY-MM/` and indexed in
`memory/handoffs/index.md`. A portable handoff should include:

```markdown
# Handoff: <topic>

**Date**: YYYY-MM-DD
**Author**: <person>
**To**: <person>

## Briefing

<what changed, why it matters, and what the next agent should do>
```

### Questions

Questions are stored under `memory/knowledge/questions/`:

```markdown
---
from: codex-b
to: codex-a
topic: relay smoke
status: pending
created: 2026-04-26T00:00:00Z
---

## Questions

- What should I verify next?
```

Answers update `status: answered`, add `answered_by` and `answered_at`, and
append a `## Answer` section.

## Runtime Requirements

The protocol assumes:

- `bash`
- `git`
- `jq`
- write access to the shared memory repo

Hosted graph, Telegram, Claude Code hooks, and artifact publishing are optional
layers.
