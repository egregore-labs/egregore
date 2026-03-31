View or register infrastructure services. Reads from the shared service registry so any session can find service names, URLs, and credential locations.

## When to invoke

User says: "what's the netlify site name", "where's the API deployed", "infrastructure", "what services do we have", "register a service", "add infra", "infra", "where do we deploy", "what's the preview URL", "service registry"
Not this: environment variables -> `/env` . health check -> `/checkup`

Arguments: $ARGUMENTS (optional: "add" to register a new service, or a service name/type to look up)

## What to do

### Step 0: Load registry

```bash
cat memory/infrastructure/services.yml 2>/dev/null
```

If file doesn't exist or `memory/infrastructure/` doesn't exist:
```bash
mkdir -p memory/infrastructure
```
Then create a minimal seed file with the header comment and `services: []`. Inform the user: "No services registered yet. Let's add one."

Parse the YAML contents. Extract the `services` list.

### Step 1: Route by arguments

- `$ARGUMENTS` is empty -> **Display mode** (Step 2)
- `$ARGUMENTS` is "add" or starts with "add " -> **Add mode** (Step 3)
- `$ARGUMENTS` matches a service name or type -> **Lookup mode** (Step 4)

### Step 2: Display all services (default)

Render a TUI box showing all registered services, grouped by `type`:

```
┌──────────────────────────────────────────────────────────────────────┐
│  ⊕ INFRASTRUCTURE                                     {N} services  │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  NETLIFY                                                             │
│  Egregore Site · egregore.xyz                                        │
│    preview: preview--egregore-core.netlify.app                       │
│    repo: Curve-Labs/egregore-site                                    │
│                                                                      │
│  RAILWAY                                                             │
│  Egregore API · egregore-production-55f2.up.railway.app              │
│    repo: Curve-Labs/egregore                                         │
│                                                                      │
│  NEO4J                                                               │
│  CL Instance · access via bin/graph.sh                               │
│  Core Instance · access via bin/graph.sh                             │
│                                                                      │
│  SUPABASE                                                            │
│  Telemetry/Reports · xgksfrirtdumacvmfkzj.supabase.co               │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  /infra {name} for details · /infra add to register new             │
└──────────────────────────────────────────────────────────────────────┘
```

Rules:
- Group services by `type` (uppercase label)
- Show name, primary URL, and one key detail from `notes`
- Omit full credential details in overview
- Output the TUI box directly as a code block — no narration

### Step 3: Add a new service

Use AskUserQuestion to gather the entry:

```
header: "Register Service"
question: "What type of service are you registering?"
options:
  - label: "Netlify site"
  - label: "Railway service"
  - label: "Supabase project"
  - label: "Neo4j instance"
  - label: "Vercel deployment"
  - label: "Docker registry"
  - label: "Other"
```

Then use AskUserQuestion for each required field:
- **Name**: free text
- **URL**: free text
- **Credentials location**: free text (remind: never actual secrets, just where to find them)
- **Notes**: free text (anything future sessions should know)

Optional fields (dashboard, repo) — ask only if relevant to the type.

Derive `added_by` from `git config user.name` (lowercase first word).
Set `added_date` to today's date.

Append the new entry to `memory/infrastructure/services.yml` under the `services:` list. Use consistent YAML indentation (2 spaces for list items, 4 spaces for fields).

Commit and push memory:
```bash
cd memory && git add infrastructure/services.yml && git commit -m "infra: register {service-name}" && git push origin main && cd -
```

Confirm: `Registered: {name} ({type}). Other sessions will see this on next sync.`

### Step 4: Lookup a specific service

Search the `services` list for entries matching `$ARGUMENTS` by name (case-insensitive substring) or by type.

Display matching entries with full detail:

```
┌──────────────────────────────────────────────────────────────────────┐
│  Egregore Site                                          netlify      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  URL:         https://egregore.xyz                                   │
│  Dashboard:   https://app.netlify.com/sites/egregore-core            │
│  Repo:        Curve-Labs/egregore-site                               │
│  Credentials: Netlify account — Oz's login                           │
│                                                                      │
│  Netlify site name: egregore-core                                    │
│  Preview: https://preview--egregore-core.netlify.app                 │
│  Production auto-deploys from main branch.                           │
│  Build: Next.js static export, publish dir: out                      │
│                                                                      │
│  registered by oz on 2026-03-31                                      │
└──────────────────────────────────────────────────────────────────────┘
```

Show the full `notes` field — this is where the tribal knowledge lives.

If no match: "No service matching '{query}' found. Run `/infra add` to register it."

## Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"infra"}' 2>/dev/null &
```
