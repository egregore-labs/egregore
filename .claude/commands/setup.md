First-time setup for Egregore.

Arguments: $ARGUMENTS

## Usage

- `/setup` — Full setup (memory + optional projects)
- `/setup [project]` — Add a specific project later

## CRITICAL: Always use HTTPS

Repos are private. Always use HTTPS (github-auth.sh sets up credential storage):
```bash
git clone https://github.com/{github_org}/[repo].git
```

**If clone fails:**
```
Can't access repo. Re-authenticate: bash bin/github-auth.sh
```

## Dynamic config

**Always read org config from `egregore.json` first** — never hardcode org names, repos, or memory paths:
```bash
GITHUB_ORG=$(jq -r '.github_org' egregore.json)
MEMORY_REPO=$(jq -r '.memory_repo' egregore.json)
MEMORY_DIR=$(basename "$MEMORY_REPO" .git)
```

## Full setup flow (no arguments)

```
Setting up Egregore...

[1/3] Setting up shared memory repo...
      This stores handoffs, decisions, and research notes across the team.

      # Read from egregore.json — NEVER hardcode
      MEMORY_REPO=$(jq -r '.memory_repo' egregore.json)
      MEMORY_DIR=$(basename "$MEMORY_REPO" .git)
      GITHUB_ORG=$(jq -r '.github_org' egregore.json)

      Checking for $MEMORY_DIR...

      IF not exists (as sibling ../$MEMORY_DIR):
        git clone https://github.com/$GITHUB_ORG/$MEMORY_DIR.git ../$MEMORY_DIR
        ✓ Cloned

      IF already exists:
        cd ../$MEMORY_DIR && git pull
        ✓ Already have it, pulled latest

      Creating symlink so Claude can access it from here...
      ln -s ../$MEMORY_DIR ./memory
      ✓ Linked as ./memory

[2/3] Registering you in the knowledge graph...
      Getting your identity: git config user.name → "Alice Smith"

      What should we call you? (short name for the team)
      > alice

      MERGE (p:Person {github: '$github'}) ON CREATE SET p.name = '$shortName' ...
      ✓ Registered as "$shortName" ($fullName)

[3/3] Project codebases

      Memory is ready. Now, do you want to work on any project code?

      • backend — Coordination infrastructure (Python)
      • frontend — Knowledge graph system (Python + Node)

      Type project names (comma-separated), 'all', or 'none'

      'none' = Just collaborative research, no code repos
```

## Neo4j registration

When completing setup, register the person in the knowledge graph:

1. Get full name from git: `git config user.name` → "Alice Smith"
2. Ask for short name: "What should we call you?" → "alice"
3. Create/update Person node via Neo4j MCP

```cypher
MERGE (p:Person {github: $github})
ON CREATE SET p.name = $name, p.joined = date(), p.fullName = $fullName
ON MATCH SET p.name = $name, p.fullName = $fullName
RETURN p.name AS name, p.joined AS joined
```

**Existing team members** are already registered — query `MATCH (p:Person) RETURN p.name` to check before creating duplicates.

## Adding a specific project later

When `/setup [repo]` is used to add a repo, also update `egregore.json` repos array:
```bash
# After cloning, add to managed repos list
jq --arg repo "$REPO" '.repos += [$repo] | .repos |= unique' egregore.json > tmp.$$.json && mv tmp.$$.json egregore.json
```

```
> /setup backend

Setting up Tristero...

[1/4] Getting the repo...
      Checking for ../backend...

      IF not exists:
        git clone https://github.com/$GITHUB_ORG/backend.git ../backend
        ✓ Cloned to ../backend

      IF already exists:
        cd ../backend && git pull
        ✓ Already have it, pulled latest

[2/4] Loading shared configuration...
      cd ../backend && git submodule update --init --recursive
      ✓ egregore submodule loaded

[3/4] Linking shared memory...
      Checking if memory symlink exists...

      IF not linked:
        ln -s ../$MEMORY_DIR ../backend/memory
        ✓ Linked as ./memory

      IF already linked:
        ✓ Already linked

[4/4] Setting up Python environment...
      Creating virtual environment and installing dependencies...
      cd ../backend && uv venv && source .venv/bin/activate && uv pip install -r requirements.txt
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

To add a project later: /setup backend
```

## Next

Run `/env` to configure environment variables, or `/activity` to see what's happening.
