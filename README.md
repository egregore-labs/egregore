<p align="center">
  <img src="banner.jpg" alt="Egregore — towards shared minds" />
</p>

<p align="center">
  A shared intelligence layer for teams using Claude Code.
</p>

<p align="center">
  <a href="https://egregore.xyz">Website</a> ·
  <a href="https://github.com/egregore-labs/egregore/discussions">Community</a> ·
  <a href="LICENSE">MIT License</a>
</p>

---

Egregore is a shared cognition layer for AI-native collaboration. It turns Claude Code into an inhabitable production environment where every session, handoff, and decision accumulates into a living memory owned by your organization.
With use, the deep context that accumulates enables seamless continuity across multi-agent workflows, visibility into organizational patterns and decision-making, and persistence of collective intelligence across people, sessions, and time.

## Install

```bash
npx create-egregore@latest --open
```

This walks you through GitHub auth, names your egregore, creates the repos
(instance + shared memory), clones everything locally, and adds a shell
command to your profile.

To join an existing egregore:

```bash
npx create-egregore join <github-org>
```

(You will need an invitation from the instance owner. See `/invite` below.)

## Start

Open a new terminal:

```bash
egregore
```

or, if configured:

```bash
<instance-alias>
```

Memory syncs. Identity resolves. The session picks up the accumulated context
from every session before it.

## The substrate

Three structural pieces. Everything else is built on them.

**`egregore.md`** — The identity document. What the group is, what it values,
how it works. Every session reads it. It evolves with use.

**`memory/`** — Git-based shared knowledge. Handoffs, decisions, patterns,
quests, people. A separate repo, symlinked into the instance. Version-controlled
provenance on everything.

**Slash commands** — Coordination primitives that encode the session protocol.
Hand off context, capture decisions, invite people, save work. Nobody needs
to learn git workflows or remember conventions.

## Commands

| Command | What it does |
|---------|-------------|
| `/handoff` | Structured context for the next session — decisions, trade-offs, open threads |
| `/activity` | What's happening across the team |
| `/invite` | Bring someone into the egregore |
| `/save` | Stage, commit, push, PR — one command |
| `/dashboard` | Your personal status and recent work |
| `/quest` | Start or contribute to an open-ended exploration |
| `/ask` `/harvest` | Route a question to a teammate or the group |
| `/todo` | Personal task tracking |
| `/reflect` | Capture a decision, pattern, or finding |
| `/deep-reflect` | Cross-reference an insight against accumulated knowledge |

## Invite

```
/invite <github-username>
```

Adds them as a collaborator on your repos. They join with:

```bash
npx create-egregore join <your-github-org>
```

New members inherit the full shared context from session one. The egregore
onboards them.

## What runs

Egregore uses [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)
— shell scripts that fire on session events. All source is in `bin/` and
`.claude/hooks/`. Read them directly.

| Hook | What it does |
|------|-------------|
| **SessionStart** | Syncs memory, resolves identity, renders greeting |
| **PreToolUse** | Boundary isolation + branch protection |
| **PostToolUse** | Local activity tracking |
| **WorktreeCreate** | Isolated git worktrees per topic |
| **PreCompact** | Saves context before memory compression |
| **Stop** | Reminds you to save unsaved work |

No background processes. No daemons. No network calls you don't see.

## Telemetry

Anonymous usage data — command names and timestamps only. Never code, file
contents, or conversation. Opt out anytime:

```bash
EGREGORE_NO_TELEMETRY=1  # in your .env
DO_NOT_TRACK=1           # or the standard flag
```

## Egregore Native: Managed hosting (coming soon)

The open-source Egregore was built as a self-hosted, sovereign architecture without dependencies. Egregore's true capabilities, functionalities and scale are greatly enhanced with managed services.
For teams that want the knowledge graph, live notifications, organizational agents, and persistent GUI: native@egregore.xyz.

## Contributing

Egregore is built by its users. If you already run an egregore:

```
/contribute
```

Forks the repo, creates a branch, and opens a PR to `egregore-labs/egregore`
when you're done.

For manual setup, see [CONTRIBUTING.md](CONTRIBUTING.md).

## From the lab

Built by [Egregore Labs](https://egregore.xyz).

<p align="center">
  <em>Find the others.</em>
</p>
