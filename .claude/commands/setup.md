First-time setup for Egregore. Sets up shared memory first, projects are optional.

Arguments: $ARGUMENTS

## Usage

- `/setup` — Full setup (memory + optional projects)
- `/setup [project]` — Add a specific project later

## CRITICAL: Always use SSH

Repos are private. Always use SSH:
```bash
git clone git@github.com:Curve-Labs/[repo].git
```

**If clone fails:**
```
Can't access repo. Check your SSH keys: ssh -T git@github.com
```

## Full setup flow (no arguments)

```
Setting up Egregore...

[1/3] Setting up shared memory repo...
      This stores handoffs, decisions, and research notes across the team.

      Checking for curve-labs-memory...

      IF not exists (as sibling ../curve-labs-memory):
        git clone git@github.com:Curve-Labs/curve-labs-memory.git ../curve-labs-memory
        ✓ Cloned

      IF already exists:
        cd ../curve-labs-memory && git pull
        ✓ Already have it, pulled latest

      Creating symlink so Claude can access it from here...
      ln -s ../curve-labs-memory ./memory
      ✓ Linked as ./memory

[2/3] Registering you in the knowledge graph...
      Getting your identity: git config user.name → "Oz Broccoli"

      What should we call you? (short name for the team)
      > oz

      MERGE (p:Person {name: 'oz'}) ...
      ✓ Registered as "oz" (Oz Broccoli)

[3/3] Project codebases

      Memory is ready. Now, do you want to work on any project code?

      • tristero — Coordination infrastructure (Python)
      • lace — Knowledge graph system (Python + Node)

      Type project names (comma-separated), 'all', or 'none'

      'none' = Just collaborative research, no code repos
```

## Neo4j registration

When completing setup, register the person in the knowledge graph:

1. Get full name from git: `git config user.name` → "Oguzhan Broccoli"
2. Ask for short name: "What should we call you?" → "oz"
3. Create/update Person node via Neo4j MCP

```cypher
MERGE (p:Person {name: $name})
ON CREATE SET p.joined = date(), p.fullName = $fullName
RETURN p.name AS name, p.joined AS joined
```

**Existing team members:** oz, cem, ali — already registered, no changes needed.

## Adding a specific project later

When `/setup [repo]` is used to add a repo, also update `egregore.json` repos array:
```bash
# After cloning, add to managed repos list
jq --arg repo "$REPO" '.repos += [$repo] | .repos |= unique' egregore.json > tmp.$$.json && mv tmp.$$.json egregore.json
```

```
> /setup tristero

Setting up Tristero...

[1/4] Getting the repo...
      Checking for ../tristero...

      IF not exists:
        git clone git@github.com:Curve-Labs/tristero.git ../tristero
        ✓ Cloned to ../tristero

      IF already exists:
        cd ../tristero && git pull
        ✓ Already have it, pulled latest

[2/4] Loading shared configuration...
      cd ../tristero && git submodule update --init --recursive
      ✓ egregore submodule loaded

[3/4] Linking shared memory...
      Checking if memory symlink exists...

      IF not linked:
        ln -s ../curve-labs-memory ../tristero/memory
        ✓ Linked as ./memory

      IF already linked:
        ✓ Already linked

[4/4] Setting up Python environment...
      Creating virtual environment and installing dependencies...
      cd ../tristero && uv venv && source .venv/bin/activate && uv pip install -r requirements.txt
      ✓ Environment ready

Setup complete.

⚠ Missing .env file. Run /env to configure API keys.
```

## Completion message

```
✓ Setup complete.

You now have collaborative Claude with shared memory.

What you can do now:
  /activity     — See what the team has been working on
  /handoff      — Leave notes for others (or future you)
  /reflect      — Save a decision or finding
  /pull         — Get latest from team

To add a project later: /setup tristero
```

## Next

Run `/env` to configure environment variables, or `/activity` to see what's happening.
