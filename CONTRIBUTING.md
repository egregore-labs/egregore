# Contributing to Egregore

Egregore is built with Egregore. The easiest way to contribute is from your own instance.

## From your Egregore

If you already use Egregore, run:

```
/contribute
```

This forks the repo, creates a branch, and lets you work on your improvement. When ready:

```
/contribute submit
```

Creates a PR to `egregore-labs/egregore` from your fork. That's it.

## From scratch

```bash
# 1. Fork egregore-labs/egregore on GitHub
# 2. Clone your fork
git clone git@github.com:YOUR_USERNAME/egregore.git
cd egregore

# 3. Create a branch
git checkout -b improve/your-topic

# 4. Open Claude Code
claude

# 5. Make your changes, then push and PR
git push origin improve/your-topic
gh pr create --base main
```

## What to contribute

- **Commands** (`.claude/commands/`) — improve existing commands or add new ones
- **Scripts** (`bin/`) — fix bugs, improve safety, add features
- **CLAUDE.md** — better instructions, clearer behavior rules
- **Documentation** — README, DEVELOPMENT.md

## Guidelines

- One PR per improvement
- Test your changes in a real Egregore session before submitting
- Shell scripts: use `jq` for JSON (never string concatenation), never `source .env`
- Keep it simple — don't add abstractions for one-time operations

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
