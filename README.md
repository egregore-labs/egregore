```
  ███████╗ ██████╗ ██████╗ ███████╗ ██████╗  ██████╗ ██████╗ ███████╗
  ██╔════╝██╔════╝ ██╔══██╗██╔════╝██╔════╝ ██╔═══██╗██╔══██╗██╔════╝
  █████╗  ██║  ███╗██████╔╝█████╗  ██║  ███╗██║   ██║██████╔╝█████╗
  ██╔══╝  ██║   ██║██╔══██╗██╔══╝  ██║   ██║██║   ██║██╔══██╗██╔══╝
  ███████╗╚██████╔╝██║  ██║███████╗╚██████╔╝╚██████╔╝██║  ██║███████╗
  ╚══════╝ ╚═════╝ ╚═╝  ╚═╝╚══════╝ ╚═════╝  ╚═════╝ ╚═╝  ╚═╝╚══════╝
```

A shared intelligence layer for organizations using Claude Code. Persistent memory, async handoffs, and accumulated knowledge across sessions and people.

## Prerequisites

- [git](https://git-scm.com)
- [Claude Code](https://docs.anthropic.com/en/docs/claude-code) — `npm install -g @anthropic-ai/claude-code`

## Install

### From the website (recommended)

Visit [egregore.xyz](https://egregore.xyz), sign in with GitHub, pick your org and repos, then run the one-liner it gives you:

```bash
npx create-egregore@latest --token st_xxx
```

Or without Node.js:

```bash
curl -fsSL https://egregore.xyz/api/org/install/st_xxx | bash
```

### From an invite

Got an invite link? Open it, sign in with GitHub, and you'll get the same one-liner.

### Interactive (no website)

```bash
npx create-egregore@latest
```

Walks you through GitHub auth, org selection, and repo setup in the terminal.

### Local mode (no server needed)

Set up Egregore using only GitHub — no API server, no account required:

```bash
npx create-egregore@latest --local
```

This creates repos under your GitHub org, sets up shared memory, and configures everything locally. Uses GitHub device flow for auth.

To invite someone:

```bash
/invite <github-username>
```

They join with:

```bash
npx create-egregore@latest join <your-github-org>
```

Local mode works entirely on the filesystem — no knowledge graph, no Telegram, no dashboard. Run `/connect` later to enable those features.

## What happens

1. **Authenticate** — Sign in with GitHub (OAuth, no tokens to copy)
2. **Pick your org** — Choose a GitHub org or personal account
3. **Pick repos** — Select which org repos Egregore should manage (or skip for collaboration-only)
4. **Generate** — Creates your org's egregore instance, shared memory repo, and knowledge graph
5. **Connect Telegram** — Optionally add the bot to a group for async notifications

Each org can have multiple egregore instances with separate graphs and Telegram groups.

## After setup

During setup, Egregore adds a shell function to your profile (`.zshrc`, `.bash_profile`, or fish `config.fish`). From any terminal:

```bash
egregore
```

This opens Claude Code in your egregore directory, syncs everything, and shows you where you are. If you have multiple egregore instances, additional ones get named `egregore-{org}`.

Some commands to get started:

| Command | What it does |
|---------|-------------|
| `/activity` | See what's happening across your org |
| `/handoff` | Leave notes for others (or future you) |
| `/invite` | Invite someone to your org |
| `/quest` | Start or contribute to an exploration |
| `/ask` | Ask questions, routed to self or others |
| `/save` | Commit and push your contributions |

See all commands and docs at [egregore.xyz/docs](https://egregore.xyz/docs).

## Invite others

```
/invite <github-username>
```

Sends a GitHub org invitation and generates an invite link. They click, authenticate, and get a one-liner to install.

## How it works

Egregore gives your team a shared brain that persists across Claude Code sessions:

- **Memory** — Git-based shared knowledge repo (decisions, patterns, handoffs)
- **Local mode** — Works fully offline with filesystem-based memory
- **Knowledge graph** — Optional: query across sessions, people, and artifacts
- **Notifications** — Optional: Telegram for async handoffs and questions
- **Commands** — Slash commands for common workflows, no git knowledge needed
- **Repos** — Managed repos are cloned alongside your instance for shared context

Built by [Curve Labs](https://curvelabs.eu).
