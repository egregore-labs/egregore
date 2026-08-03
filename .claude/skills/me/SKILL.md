# /me — View or reconcile your identity

Show the current member identity or change how the member wants to be called.
All writes go through one portable identity spine shared by Claude Code, Codex,
and Pi.

## When to invoke

- "who am I", "my profile", "my name", "what's my name"
- "call me Oz", "I go by Cem", "change my name to X"
- "use me@example.com for me", "add/change my email"
- User runs `/me` or `/me <name>`

## Identity contract

`bin/person.sh` is the only writer for person identity. It reconciles:

- `.egregore-state.json` — local runtime identity;
- `memory/people/{github_username}.md` — durable organizational profile;
- Supabase `users` + `memberships` — platform identity and per-org display name;
- Neo4j `Person` — knowledge-graph identity and relationships.

The durable identity is GitHub's numeric user id (`person_id=github:<id>`)
when available. GitHub login, preferred/display name, historical names, and
emails are aliases/addresses of that identity. A login rename or preferred-name
change must update the same person, not create another member.

External people introduced by `$ingest` remain source-scoped external
identities and are never promoted into members by this workflow.

## No arguments

Run:

```bash
bash bin/person.sh show
```

Display the useful fields only:

```text
Name: {display_name}
GitHub: {github_username}
Email: {email or "not shared"}
Aliases: {github_aliases + previous_names, if any}
```

Never expose internal platform ids unless the user asks for diagnostics.

## With a name

Run:

```bash
bash bin/person.sh set-name "$ARGUMENTS"
```

The command validates the name, preserves the old display name as an alias,
updates the canonical markdown profile, reconciles simple duplicate/alias
profiles, syncs Supabase, updates the graph, and moves known relationships from
duplicate Person nodes onto the canonical member.

Report:

- `synced` → `You're now known as **{name}** everywhere in this Egregore.`
- `synced-local` → `You're now known as **{name}** in this Egregore.`
- `partial` → the local state and markdown are durable; say which projection
  (`supabase` or `graph`) is pending and that a later `bin/person.sh sync`
  retries it.

## With an email

When the user explicitly supplies their own email, run:

```bash
bash bin/person.sh set-email "person@example.com"
```

This makes the supplied address primary and retains earlier addresses as
aliases. Never infer an address from git configuration.

## Reconciliation

When onboarding, a GitHub login changes, an email is added, or a profile looks
duplicated, run:

```bash
bash bin/person.sh sync
```

Do not hand-write Person Cypher, call `/api/user/ensure` independently, or edit
only the H1 in a people file. Those partial updates caused the original
cross-surface identity inconsistency.

## Rules

- Preferred/display name is per organization.
- GitHub numeric id is durable; GitHub login is mutable.
- Persist only email addresses already supplied by the authenticated user or
  their public GitHub profile. Never infer an email from git config.
- Markdown remains authoritative and replayable in local mode.
- All graph access goes through `bin/graph.sh`/`bin/graph-op.sh`.
- Suppress raw JSON in the user-facing response.
