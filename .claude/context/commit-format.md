# Commit Format — one convention, every harness

Every commit in an Egregore — from Claude Code, Codex, Pi, a background
script, or a human — carries the same message shape. Commits are the
finest-grained record the org keeps: agents reconstruct context from
`git log` before they read anything else, and a message that cannot be
understood without its session is context lost.

This spec covers newly authored, non-merge commits. Git-generated
messages — merges, `git revert`'s native `Revert "…"` form, autosquash
fixups — keep their native shape, and the advisory lint skips them.

Sibling spec: `.claude/context/pr-format.md`. Wording rules for both:
`.claude/context/git-language.md`.

## Subject

`type(scope): imperative summary` — the same grammar as PR titles
(`pr-format.md` § Title is the authoritative statement; restated here).

- ≤ 72 characters (git tooling truncates beyond that), aim for ≤ 50.
  No trailing period.
- Types: `feat` `fix` `docs` `refactor` `chore` `test` `perf` `ci`
  `build` `release` — the same set as PR titles.
- Scope = subsystem (`loom`, `emissary`, `handoff`, `api`, `site`,
  `launcher`, …), the same vocabulary as PR titles. Omit it when the
  summary already names the subsystem, when the change spans several,
  or when none fits.
- Imperative, lowercase summary. It completes "if applied, this commit
  will ___": `fix(emissary): stop smokes emailing recipients` — not
  `Fixed smokes` or `fixes smokes`.
- A breaking change appends `!` after the scope
  (`feat(api)!: drop v1 handoff routes`) and explains the break in the
  body.
- One logical change per commit — split when the parts are
  independently revertable. A summary that needs "and" is the usual
  smell, not the law.

## Body

Blank line after the subject, then prose wrapped at 72 columns. Never
break a URL, command, or quoted error string to satisfy the wrap.

- Optional when the subject says everything (typo fixes, mechanical
  renames). Required when the diff cannot explain its own motivation.
- What changed and why. State prior behavior, what was wrong with it,
  and why this solution. Skip implementation narration the diff
  already shows; do include mechanism that affects review, operation,
  or compatibility.
- Wording follows `.claude/context/git-language.md`.

## Trailers

Agent-authored commits end with machine-readable git trailers,
blank-line separated from the body:

```
Egregore-Session: <session id>
Co-Authored-By: <harness identity>
```

- `Egregore-Session` is the id from `.egregore-session-id`. It links
  the commit to its session in the graph — commit → session → handoff
  lineage becomes queryable:
  `git log --format='%(trailers:key=Egregore-Session,valueonly)'`.
  Omit only when no session id exists (bare scripts, CI). A commit
  carrying work from several sessions repeats the trailer, one per
  session; squashes keep every contributing session's trailer, and a
  cherry-pick keeps the source commit's.
- `Co-Authored-By` is the harness's standing identity line — e.g.
  `Claude Fable 5 <noreply@anthropic.com>`, the Codex worker identity,
  or `Egregore Attendant <noreply@egregore.xyz>`. It states that an
  agent co-authored the commit; GitHub rendering it as a co-author is
  the point, not a side effect.
- Issue references are trailers (`Refs: #123`), never subject text.
  `Refs:` is non-closing metadata; use `owner/repo#123` across repos.
  GitHub closing keywords belong in the PR body, not in commits.
- Humans committing by hand skip trailers.

## Automation

Background scripts use the same grammar — imperative, and
`chore(<subsystem>)` unless a more specific type applies:

| Legacy style | Convention |
|---|---|
| `Handoff: <topic> (to <who>)` | `chore(handoff): record <topic> (to <who>)` |
| `Auto-save: session content` | `chore(autosave): save session work` |
| `Archive session <id>` | `chore(transcripts): archive session <id>` |
| `Auto-update Egregore framework` | `chore(sync): update framework from upstream` |

Workflow scopes name workflow artifacts only. A commit that carries
real work derives its type and scope from the diff — `/save` of a loom
feature is `feat(loom): …`, never `chore(save): …`. The transport must
not mask the work.

## Relationship to PRs

The PR title always describes the whole PR. When the PR holds a single
commit whose subject already does that, reuse the subject verbatim —
this is the common case for agent PRs.

## Enforcement map

| Layer | Path | Covers |
|---|---|---|
| Authoring | `.claude/skills/commit`, `/save`, `/pr`, AGENTS.md § Commit format | Claude Code, Codex, Pi, shell agents |
| Composers | `bin/agent.sh`, `bin/handoff-*.sh`, `bin/lib/git-sync.sh`, `bin/session-autosave.sh`, … | every scripted commit |
| Advisory CI | `.github/workflows/pr-format.yml` commit-subject report | every PR branch |
| Parity | convention parity test (`tests/`) | spec copies across runtimes, and the grammar shared by this spec and `pr-format.md` |
