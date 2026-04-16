# Install via `gh` CLI — no GitHub App

This path installs Egregore using [GitHub CLI (`gh`)](https://cli.github.com) as the credential. No third-party GitHub App is installed on your account or org. The token comes from GitHub's own first-party device flow — the same one `gh auth login` uses for every other command.

If your security policy blocks third-party GitHub Apps **but allows `gh`** (common — `gh` is a GitHub-owned tool), this is the path for you.

If even `gh` is blocked, see [INSTALL.md](./INSTALL.md) for the pure-PAT path.

## Prerequisites

- **`git`** (any recent version)
- **`gh`** — [install](https://cli.github.com/)
- **`jq`** — `brew install jq` / `apt-get install jq`
- **Claude Code** — installed locally

Authenticate `gh` once:

```bash
gh auth login
```

Pick **GitHub.com → HTTPS → Login with a web browser**. This is a first-party device flow — no third-party App gets installed.

## Install

Run from any directory (e.g. `~/dev`). Download first, inspect if you want, then run — so you always see the code before it executes:

```bash
curl -sLO https://raw.githubusercontent.com/egregore-labs/egregore/main/bin/init-gh.sh
less init-gh.sh          # optional — read what it will do
bash init-gh.sh
```

The installer will:

1. **Preflight** — check `git`, `gh`, `jq`, and `gh` auth
2. **Detect context** — if you're inside a git repo, offer to install in the parent directory and auto-adopt the current repo as managed
3. **Pick owner** — your personal account or any org you're a member of
4. **New vs existing project** — either create a fresh project repo, or pick existing repos to manage
5. **Create repos on GitHub** — `gh repo create` for the Egregore repo (from the public template) + memory repo (+ optional new project repo)
6. **Clone as siblings** — everything lives next to each other under your chosen base directory
7. **Scaffold memory** — `people/`, `handoffs/`, `knowledge/…`, pushed as the first commit
8. **Symlink `memory/`** from the Egregore repo to the memory repo clone
9. **Write `.env`** — uses `gh auth token` so skills like `/save` and `/invite` just work
10. **Write `egregore.json`** locally and push to the remote so joiners can read it before cloning
11. **Write `.egregore-state.json`** — `onboarding_complete: false` so the first session runs `/onboarding`
12. **Create your person file** at `memory/people/<your-login>.md`
13. **Optional** — invite a teammate (adds them as a collaborator to every repo + creates their person file)

## First session

```bash
cd <your-egregore-dir>
claude
```

The SessionStart hook syncs memory + `develop` and runs `/onboarding` because `.egregore-state.json` says you haven't onboarded yet.

## Inviting teammates later

```bash
/invite <github-username>
```

Works the same as the App flow — adds them as a collaborator on every repo (`repo`, `memory`, managed ones) and creates a person file. Tell them to run either path:

```bash
# gh path (no third-party App, no PAT — same as founder install)
curl -sLO https://raw.githubusercontent.com/egregore-labs/egregore/main/bin/join-gh.sh
bash join-gh.sh <org>/<egregore-repo>

# or npx path (requires running code from npm)
npx create-egregore join <org>/<egregore-repo>
```

Both paths:
- Accept pending GitHub invitations automatically
- Clone core + memory repos as siblings
- Clone every managed repo (skipping any the joiner isn't invited to)
- Symlink `memory/`, write `.env` from `gh auth token`, write `.egregore-state.json`
- Install a shell alias (`egregore` by default; slug fallback if taken)
- Show any welcome note the inviter left
- First session runs `/onboarding`

## Why `gh` over a GitHub App

`gh` authenticates through an OAuth app **owned by GitHub itself** (not a third-party). Most enterprise orgs that block third-party Apps explicitly allow `gh` because it's the same auth path GitHub's own tools use. The token it mints lives only on your machine, in `~/.config/gh/hosts.yml`, with whatever scopes you granted at `gh auth login` time. You can revoke it anytime in GitHub Settings → Applications → Authorized OAuth Apps.

## Why this over the manual PAT path

- **Automated repo creation** — `gh` can create repos without needing an "All repositories" PAT (the hard constraint that forces the manual path to have the user create repos by hand first)
- **No token to paste** — `gh` handles the credential
- **Matches `npx` UX** — picker, multi-select, auto-adopt, invite at the end
- **Fallback** — if `gh` is blocked too, `bin/init.sh` + [INSTALL.md](./INSTALL.md) still works

## Troubleshooting

### `gh auth login` failed or org is not visible

If you're a member of an org but it doesn't show up in the owner picker, your org may restrict OAuth apps. Go to **Settings → Applications → Authorized OAuth Apps → GitHub CLI** and request access from an org admin. This is usually a quick approval (it's GitHub's own tool).

### Template generation lagged

The script waits up to 30s for a template-generated repo to become queryable. If it times out, re-run — the repo exists; the second run will skip creation and continue.

### `gh repo clone` fails inside the installer

Usually a transient network issue. The installer keeps going with warnings; finish it, then `cd` into the target directory and run `gh repo clone <owner>/<name>` manually.

### I want to redo the install

```bash
# Revoke the repos on GitHub (or keep them, your choice)
gh repo delete <owner>/<egregore-repo>
gh repo delete <owner>/<memory-repo>
# Remove the local clones
rm -rf <egregore-dir> <memory-dir>
# Re-run
bash init-gh.sh
```

## What the installer does NOT do

- Does **not** install a GitHub App
- Does **not** write to `~/.gitconfig` or any global state beyond what `gh auth login` already did
- Does **not** send telemetry, analytics, or any data to Curve-Labs / Anthropic / third parties
- Does **not** require `npx` or any code from npm
- Does **not** need a manually-generated PAT

The only network calls are `gh api` / `gh repo create` / `gh repo clone` (all first-party GitHub) and `git push` to your memory repo for the scaffold. Read `bin/init-gh.sh` — every call is there.
