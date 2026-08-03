# PR Format — one convention, every harness

Every pull request in an Egregore — from Claude Code, Codex, any other
harness, a script, or a human — carries the same description shape. Domain
knowledge encoded as infrastructure, not as per-harness habit. It is
enforced in four layers: authoring instructions (this spec, referenced by
`/pr`, `/save`, and AGENTS.md), a fallback generator (`bin/agent.sh save`
builds a compliant body when the caller supplies none), a web-UI template
for humans, and a CI gate (`.github/workflows/pr-format.yml`) that fails
non-compliant PRs with a fix-it comment.

## Title

`type(scope): imperative summary` — ≤ 72 chars, no trailing period.
Types: `feat` `fix` `docs` `refactor` `chore` `test` `perf` `ci` `build`
`release`. Scope = subsystem (`loom`, `minion`, `emissary`, `api`, `site`,
`launcher`, …). Title style is advisory — reported by the gate, not failed.

## Body

Three sections are gated, two are optional. In this order:

| Section | Required | Contents |
|---|---|---|
| `## What` | always | 1–4 bullets, the change itself, most important first. A reader should know what merged from this section alone. |
| `## Why` | always | 1–3 sentences. The motivation or problem — context the diff cannot show. Link the decision/quest/issue that spawned it. |
| `## Verification` | when the diff touches non-markdown files | How this was checked: test command + result, manual steps, or an honest `Not verified — <reason>`. Never omit; never fake. |
| `## Risk` | when real | Breaking changes, blast radius (does merging publish or deploy?), rollback note. |
| `## Links` | when they exist | Issues, quests, handoffs, superseded PRs. |

Footer: the generating harness's attribution line (e.g. `🤖 Generated with
[Claude Code](https://claude.com/claude-code)`). Humans skip it.

## Rules of thumb

- **Compact beats complete.** Drop a detail if it doesn't change what the
  reviewer does next. Hierarchy beats prose: lead each section with its
  strongest line.
- **Never create a PR with an empty body** or `--fill`. A harness that
  cannot write the body routes through `bin/agent.sh save`, which generates
  a compliant skeleton from the commit log and diff.
- **Auto-merged markdown-only PRs still need What + Why** — two lines
  suffice.

## Enforcement map

| Layer | Path | Covers |
|---|---|---|
| Authoring | `.claude/skills/pr`, `.claude/skills/save`, `AGENTS.md` § Pull request format | Claude Code, Codex, shell agents |
| Fallback generator | `bin/agent.sh save` (`--pr-body` / auto-skeleton) | any bridge caller |
| Template | `.github/pull_request_template.md` | humans in the web UI |
| Gate | `.github/workflows/pr-format.yml` | everything — fails the check and posts a fix-it comment |

Gate exemptions: draft PRs, `release:`-titled PRs, bot-authored PRs.
The gate blocks auto-merge only if `pr-format` is marked a required status
check in branch protection — an admin, per-repo setting.
