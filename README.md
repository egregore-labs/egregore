```
  ███████╗ ██████╗ ██████╗ ███████╗ ██████╗  ██████╗ ██████╗ ███████╗
  ██╔════╝██╔════╝ ██╔══██╗██╔════╝██╔════╝ ██╔═══██╗██╔══██╗██╔════╝
  █████╗  ██║  ███╗██████╔╝█████╗  ██║  ███╗██║   ██║██████╔╝█████╗
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║   ██║██║   ██║██╔══██╗██╔══╝
  ███████╗╚██████╔╝██║  ██║███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗
  ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝
```

A shared intelligence layer for teams using Claude Code. Persistent memory, async handoffs, and accumulated knowledge across sessions and people.

## Prerequisites

- [git](https://git-scm.com)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `npm install -g @anthropic-ai/claude-code`

## Install

```bash
npx create-egregore@latest --local
```

This walks you through:

1. **Sign in with GitHub** — OAuth device flow, no tokens to copy
2. **Pick your account** — Personal or organization
3. **Name your project** — Creates an Egregore instance and shared memory repo
4. **Optionally create a project repo** — For your actual code
5. **Done** — Everything cloned and linked locally

## Start

Setup adds a shell command to your profile. Open a new terminal and type:

```bash
egregore
```

This opens Claude Code in your Egregore directory, syncs memory, and picks up where you left off.

## Commands

| Command | What it does |
|---------|-------------|
| `/reflect` | Capture a decision, pattern, or insight |
| `/handoff` | Leave notes for others (or future you) |
| `/quest` | Start or contribute to an exploration |
| `/ask` | Ask questions, routed to self or others |
| `/activity` | See what's happening across your team |
| `/dashboard` | Your personal status and recent work |
| `/todo` | Manage personal tasks |
| `/save` | Commit and push your contributions |
| `/invite` | Invite someone to your Egregore |

## Invite others

```
/invite <github-username>
```

Adds them as a collaborator on GitHub. They join with:

```bash
npx create-egregore@latest join <your-github-org>/<repo-name>
```

## How it works

Egregore gives your team a shared brain that persists across Claude Code sessions:

- **Memory** — Git-based shared knowledge repo (decisions, patterns, handoffs)
- **Commands** — Slash commands for common workflows, no git knowledge needed
- **Repos** — Managed repos are cloned alongside your instance for shared context
- **Sessions** — Each person works independently; knowledge flows through handoffs and memory

Everything runs locally. No servers, no accounts, no API keys.

## Managed hosting

Want the knowledge graph, real-time dashboard, and Telegram notifications? Visit [egregore.xyz](https://egregore.xyz).

## Built by

[Curve Labs](https://curvelabs.eu)
