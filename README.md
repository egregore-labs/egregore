<p align="center">
  <img src="banner.jpg" alt="Egregore — towards shared minds" />
</p>

<p align="center">
  Shared memory for people and their AI agents.
</p>

<p align="center">
  <a href="https://egregore.xyz">Website</a> ·
  <a href="https://x.com/egregore_xyz">Community</a> ·
  <a href="LICENSE">MIT License</a>
</p>

---

Egregore gives people and their AI agents a shared organizational memory.
Decisions, discoveries, and handoffs accumulate across sessions, so each person
can build on what the others have learned. Your organization owns the memory.
**Claude Code, Codex, Pi, and Prime Agent** can all work with it.

One person works through a design decision in Claude Code and leaves a handoff.
A teammate using Codex picks it up, asks why that approach was chosen, and
retrieves the decision with its sources. The work continues from the reasoning
that produced it.

An earlier workflow demo:

https://github.com/user-attachments/assets/71a690fb-8a4e-4d0b-9a61-e6cdc7595430

## Start an Egregore

Recommended setup: [Node.js 22 or later](https://nodejs.org/) with npm,
[Git](https://git-scm.com/), [jq](https://jqlang.org/), Bash, and Python 3.11 or later. Local setup uses the
[GitHub CLI](https://cli.github.com/) for authentication and offers to install it
if needed. Install and authenticate your chosen agent before starting a session.

```bash
npx create-egregore@latest
```

The installer guides you through GitHub authentication, naming your Egregore,
and choosing an agent. It creates your instance and shared-memory repositories,
sets up the local workspace, and prepares memory search. Keyword search is
available first; semantic indexing can finish in the background.

Open a new terminal and run:

```bash
egregore
```

The launcher lets you choose your Egregore and agent, syncs shared memory, and
starts a session with your identity and pending work. You can return to the
same memory through any supported agent.

**Join an existing Egregore.** Ask its owner to invite your GitHub username,
then use the repository's owner and name:

```bash
npx create-egregore@latest join <owner>/<egregore-repo>
```

Setup brings in the shared memory and managed project repositories. Onboarding
introduces you to the organization and its working conventions.

**Update an existing installation.** In the launcher, select your Egregore,
press **s** for **Settings**, then choose **Runtime update**. Review and activate
the available update. Each person updates their own installation.

## Work from shared memory

Memory lives in Markdown files in a separate Git repository, linked into your
workspace as `memory/`. Decisions, handoffs, patterns, questions, and ongoing
explorations retain their history. The organization's identity and conventions
give that memory a shared frame of reference.

Local keyword and semantic search help your agent find relevant work and cite
the records behind an answer. Ask “What did we decide about onboarding, and
why?” or “Find the handoff about the redesign.” Egregore retrieves the relevant
sources as you work.

The same workflows are available across supported agents. Use natural language,
or `/handoff`, `/reflect`, and other commands in Claude Code, Pi, and Prime
Agent. In Codex, use `$handoff`, `$reflect`, and the corresponding skills.

| Workflow | What it does |
|----------|--------------|
| `handoff` | Carry decisions, reasoning, and open threads into another person's session |
| `reflect` | Preserve a decision, pattern, or finding |
| `deep-reflect` | Investigate a question across accumulated knowledge |
| `quest` | Start or contribute to an open-ended exploration |
| `ask` | Leave a question for a teammate |
| `activity` | See recent work across the team |
| `dashboard` | See your personal status and pending work |
| `todo` | Keep track of personal tasks |
| `save` | Commit and push your changes, then create or update a pull request |
| `invite` | Give a teammate access to your Egregore |

For example, ask “Invite octocat to this Egregore.” Egregore handles the access
workflow and returns the joining instructions. Each person works in their own
session; shared memory carries the context between them.

## Your installation

The open-source runtime includes memory, local search, coordination workflows,
and adapters for all four agents. Once dependencies and search models are
provisioned, local memory and search can operate offline. GitHub synchronization
and hosted model providers need their own connections.

Session startup, memory synchronization, search indexing, and worktree support
are implemented through shared scripts and agent-specific hooks or extensions.
Background work can keep repository references and search indexes current.
The source is available in [`bin/`](bin/), [`.claude/`](.claude/),
[`.codex/`](.codex/), [`.pi/`](.pi/), and [`.prime/`](.prime/).

**Telemetry.** Egregore records local diagnostic identifiers and metrics to
help inspect runtime behavior. Collection is on by default and easy to turn
off. These diagnostics exclude prompts, code, file contents, and conversations.
Nothing is uploaded automatically. Ask Egregore to show, clear, or turn off
telemetry, or set `EGREGORE_NO_TELEMETRY=1` in your `.env`. Your chosen agent's
own telemetry settings are separate. See the [telemetry specification](.claude/context/telemetry.md)
for the recorded fields and controls.

**Egregore Connect.** Optional hosted services add membership administration,
managed integrations, and notifications. Local memory and search remain on your
machine. Run `egregore connect` to explore the setup, or see
[egregore.xyz](https://egregore.xyz) for availability.

## Contribute

Egregore is built by its users. From an existing installation, ask “Help me
contribute this improvement upstream,” or use `/contribute` (`$contribute` in
Codex). The workflow prepares a fork, branch, and pull request to this repository.

For direct contributions, see [CONTRIBUTING.md](CONTRIBUTING.md). Egregore is
[MIT-licensed](LICENSE).

Built by [Egregore Labs](https://egregore.xyz).

<p align="center">
  <em>Find the others.</em>
</p>
