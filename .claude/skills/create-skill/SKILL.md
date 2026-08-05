---
name: create-skill
description: Create a skill your org owns — scaffolded in this Egregore, protected from framework updates, shared with teammates via /save.
---

Create an org-owned skill. Owned skills live in `.claude/skills/<name>/` like
framework skills, but they belong to the org: `/update` never overwrites them,
and if upstream ever ships a skill with the same name, the org's version wins
and the collision is reported.

Arguments: an optional skill name and/or a description of what the skill
should do.

## When to invoke

User says: "create a skill", "make a skill for X", "I want a /foo command for
our team", "turn this workflow into a skill", `/create-skill <name>`
Not this: installing someone else's published skill → `find-skills` · changing
a framework skill's behavior → `/contribute` (upstream owns it)

## Step 1: Name and scope

Derive a kebab-case name from the request. Rules:

- Lowercase letters, digits, hyphens only. No slashes, no leading dot.
- **Must not collide with a framework skill.** Check both the local tree and
  upstream when available:

```bash
NAME="<kebab-name>"
if [ -d ".claude/skills/$NAME" ]; then
  echo "exists locally"
fi
git fetch upstream main --quiet 2>/dev/null || true
git ls-tree -d upstream/main ".claude/skills/$NAME" 2>/dev/null | grep -q . && echo "exists upstream"
```

If the name exists locally or upstream, propose 2–3 alternatives via
AskUserQuestion instead of silently picking one. An org CAN deliberately own a
name upstream also uses (their version then always wins), but that is an
explicit choice — never a default.

If the user gave only a name and no behavior, ask what the skill should do
before scaffolding — a skill with an empty body helps nobody.

## Step 2: Scaffold

Write `.claude/skills/$NAME/SKILL.md`:

```markdown
---
name: <name>
description: <one line — what it does and when an agent should reach for it>
---

<What this skill does, in 1–3 sentences.>

## When to invoke

User says: <trigger phrases>
Not this: <adjacent intents that route elsewhere>

## Steps

1. <concrete step — commands in fenced bash blocks>
2. <...>
```

Fill it with real content derived from the user's description — trigger
phrases an agent can match, concrete steps, actual commands. Follow
`product-voice` for any user-facing copy the skill emits.

**Cross-runtime adapter (mandatory).** Codex invokes skills as `$<name>` from
`.codex/skills/`, and Pi consumes the same tree — one adapter serves both.
Write `.codex/skills/$NAME/SKILL.md`:

```markdown
---
name: <name>
description: '<same one line>'
---

<!-- org-owned skill adapter — created by /create-skill -->

# <name> (org skill)

This org-owned skill is defined once in `.claude/skills/<name>/SKILL.md`.

1. Read `.claude/skills/<name>/SKILL.md` for the full workflow.
2. Run any referenced `bin/` scripts directly from this shell.
3. Translate interactive choices to this runtime's question tooling when
   available; otherwise render compact numbered choices with an `Other:`
   option and wait for the user.
```

The runtime installer only removes files it installed itself (hash-tracked),
so this adapter survives Codex/Pi runtime upgrades. Without it, the skill
exists for Claude Code teammates only — always write both files.

## Step 3: Register ownership

Add the name to `owned_skills` in `egregore.json` (create the array if
absent):

```bash
jq --arg n "$NAME" '.owned_skills = ((.owned_skills // []) + [$n] | unique)' \
  egregore.json > egregore.json.tmp && mv egregore.json.tmp egregore.json
```

This is what makes the skill org-owned: `/update` runs
`bin/restore-owned-skills.sh` after every framework sync, which keeps every
listed skill at the org's committed version.

## Step 4: Share it

Tell the user the skill is ready to try now (`/<name>` in Claude Code,
`$<name>` in Codex, `/<name>` in Pi), then run `/save` so it reaches the team —
teammates get it on `/pull` or their next session start. The skill directory,
the `.codex/skills/` adapter, and the `egregore.json` change must all land in
the same PR, or the ownership guarantee ships half-finished.

Telemetry (fire-and-forget):

```bash
bash bin/telemetry.sh emit "command" '{"command":"create-skill"}' 2>/dev/null &
```

## Edge cases

| Scenario | Handling |
|---|---|
| Name collides with a framework skill | Propose alternatives; owning a colliding name is explicit opt-in only. |
| User wants to modify a framework skill | Route to `/contribute` — or, if they explicitly want an org-local fork, copy it under a NEW name, register ownership, and note the fork won't receive upstream improvements. |
| Skill already in `owned_skills` | Editing an existing owned skill needs no re-registration — just edit and `/save`. |
| No `jq` | Tell the user to add the name to `owned_skills` in `egregore.json` manually. |
