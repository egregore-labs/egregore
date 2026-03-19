Welcome a new user to this Egregore.

Deterministic joiner state machine. Every state has explicit entry conditions, actions, exit conditions, and API calls. Execute states literally — no improvisation, no skipping, no reordering.

## Output discipline — CRITICAL

This is a conversation with a new user, not a CI pipeline. The user should see a smooth, friendly flow — not a stream of tool calls and logs.

**Rules:**
- **Batch all reads at once.** Before each state, read ALL files you'll need in a single parallel tool call. Never read files one at a time between user-facing messages.
- **Batch all writes at once.** State file update + API call + any other writes = one parallel tool call group. Never interleave writes with user text.
- **Suppress all command output.** Every bash call must use `2>/dev/null` or capture output to a variable. The user should NEVER see raw JSON, curl output, or git logs.
- **No narration of internal steps.** Never say "Let me read the config file" or "Saving to state" or "Calling the API." Just do it silently between user-facing messages.
- **Minimize visible tool calls.** The user sees each tool call as a UI element. Fewer calls = smoother experience. Combine bash commands with `&&`. Read multiple files in one parallel call.
- **VERIFY should be invisible.** Do all 3 checks in one bash call. If everything passes, say nothing — go straight to WELCOME. Only speak if something fails.
- **COMPLETE should feel instant.** Run all 7 sub-steps (egregore.md update, memory commit, graph MERGE, Supabase sync, state update, shell alias, telemetry) in 1-2 parallel bash calls. The user should see one message: "You're in."

**What the user should experience:**
1. Welcome message (2-3 sentences)
2. Name + role question
3. Interest + style question
4. Privacy choices
5. Activity summary + "how do you want to start?"
6. "You're in."

Six moments. Everything else is invisible plumbing.

**State machine:**
```
VERIFY → WELCOME → HARVEST_IDENTITY → HARVEST_CONNECTION → CONSENT → ORIENT → COMPLETE
```

## Resumption

Read `.egregore-state.json`. If `onboarding.phase` exists and `onboarding_complete` is false, resume from that phase. Do NOT restart from VERIFY — jump directly to the saved phase and use any data already in state.

If `onboarding_complete` is true, say: "You're already set up. Run `/me` to update your profile, or just start working." Then stop.

---

## State: VERIFY

**Entry:** `onboarding_complete` is false (or missing) in `.egregore-state.json`

**Actions:**

Run all checks in a single bash call — the user should see nothing if everything passes:
```bash
TOKEN=$(grep '^GITHUB_TOKEN=' .env 2>/dev/null | cut -d'=' -f2-) && \
APIKEY=$(grep '^EGREGORE_API_KEY=' .env 2>/dev/null | cut -d'=' -f2-) && \
API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null) && \
SYMLINK=$(test -L memory && echo "ok" || echo "") && \
ORG=$(jq -r '.org_name' egregore.json 2>/dev/null) && \
echo "token:${TOKEN:+ok} apikey:${APIKEY:+ok} apiurl:${API_URL:+ok} memory:${SYMLINK} org:${ORG}"
```

Read `egregore.json`, `egregore.md`, and `.egregore-state.json` in parallel (needed for WELCOME) — batch this with the check above so VERIFY and WELCOME file reads happen together.

**Exit conditions:**
- IF all three checks pass → WELCOME
- IF `GITHUB_TOKEN` missing → run `bash bin/github-auth.sh`, re-check. IF still missing → HALT: "GitHub auth failed. Run `bash bin/github-auth.sh` manually."
- IF `EGREGORE_API_KEY` missing AND `api_url` is set → HALT: "Missing API key. Ask your team admin for it, then add `EGREGORE_API_KEY=ek_...` to `.env`."
- IF `EGREGORE_API_KEY` missing AND `api_url` is empty → skip (local mode — no API needed)
- IF `memory/` missing → run workspace setup:
  ```bash
  MEMORY_REPO="$(jq -r '.memory_repo' egregore.json)"
  MEMORY_DIR="$(basename "$MEMORY_REPO" .git)"
  ```
  Clone if `../$MEMORY_DIR` doesn't exist: `git clone "$MEMORY_REPO" "../$MEMORY_DIR"`
  Create symlink: `ln -s "../$MEMORY_DIR" memory`
  IF clone fails → HALT with git error.

**API calls:** None (local checks only)

---

## State: WELCOME

**Entry:** VERIFY passed

**Actions:**

Files needed: `egregore.md` and `.egregore-state.json`. These should ALREADY be loaded from VERIFY (batch file reads). Do NOT re-read them.

1. Extract `## Identity` and `## Culture` sections from egregore.md (already in context)
2. Use `github_username`, `github_name` from state (already in context)
3. Display welcome message:

```
Welcome to {org_name}.

{First 2 sentences of Identity section from egregore.md}

{First sentence of Culture section from egregore.md}

Let's get you set up — a few quick questions.
```

4. Save to state: `onboarding.phase = "welcome"`, `onboarding.type = "joiner"`, `onboarding.started_at = {ISO timestamp}`

**Exit:** → HARVEST_IDENTITY (always, unconditional)

**API calls:** None

---

## State: HARVEST_IDENTITY

**Entry:** WELCOME completed

**Actions:**

Build AskUserQuestion call. Questions depend on what's already known:

**IF `github_name` exists in state (install script set it):**

```
questions:
  Q1:
    question: "What should we call you here? Your GitHub name is {github_name}."
    header: "Name"
    options:
      - label: "{github_name}"
        description: "Use my GitHub name"
      - label: "Something else"
        description: "I go by a different name"
  Q2:
    question: "What do you do?"
    header: "Role"
    options:
      - label: "Engineering"
        description: "I write code"
      - label: "Design"
        description: "I design products or experiences"
      - label: "Research"
        description: "I explore ideas and synthesize knowledge"
      - label: "Operations"
        description: "I keep things running and organized"
```

**IF `github_name` NOT in state:**

```
questions:
  Q1:
    question: "What's your name?"
    header: "Name"
    options:
      - label: "{github_username}"
        description: "Use my GitHub username"
      - label: "Something else"
        description: "I go by a different name"
  Q2:
    question: "What do you do?"
    header: "Role"
    options:
      - label: "Engineering"
        description: "I write code"
      - label: "Design"
        description: "I design products or experiences"
      - label: "Research"
        description: "I explore ideas and synthesize knowledge"
      - label: "Operations"
        description: "I keep things running and organized"
```

**Post-processing:**
- IF Q1 = first option → `display_name = github_name` (or `github_username` if no `github_name`)
- IF Q1 = freeform → `display_name = freeform text` (validate: 1-30 chars, alphanumeric + spaces + hyphens)
- `role = Q2 answer` (map to: `engineering` | `design` | `research` | `operations` | `other`)

**Save to state:**
```json
{
  "display_name": "...",
  "name": "...",
  "onboarding": {
    "phase": "harvest_identity",
    "harvest_rounds": [{
      "round": 1,
      "focus": "identity",
      "questions": ["name", "role"],
      "answers": {"name": "...", "role": "..."}
    }]
  }
}
```

**API calls:**

Save state AND call the API in parallel — do NOT do these sequentially.

**Skip this call if `api_url` is empty (local mode).** Only run when connected:
```bash
API_URL="$(jq -r '.api_url // empty' egregore.json)"
if [ -n "$API_URL" ]; then
  API_KEY="$(grep '^EGREGORE_API_KEY=' .env | cut -d'=' -f2-)"
  curl -sf "${API_URL}/api/user/ensure" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d '{"github_username":"...","github_name":"...","display_name":"..."}' 2>/dev/null
fi
```

**Exit:** → HARVEST_CONNECTION (always). Transition immediately — do NOT output anything between states except the next AskUserQuestion.

---

## State: HARVEST_CONNECTION

**Entry:** HARVEST_IDENTITY completed

**Actions:**

Extract `## Collaboration` section from `egregore.md` — this should ALREADY be in context from WELCOME. Do NOT re-read the file.

**Deriving Q1 options from egregore.md:** Read the `## Collaboration` section. The first 3 bullet points or comma-separated items become option labels. If fewer than 2 items found, use these defaults: "Building / Exploring / Participating."

For egregore-0, the Collaboration section yields:
- "Building Egregore" — Contributing to the product — commands, graph, infra
- "Exploring the idea" — Curious about shared intelligence, want to see how it works
- "Using it for my team" — Evaluating Egregore for my own organization

AskUserQuestion:

```
questions:
  Q1:
    question: "What brings you to {org_name}?"
    header: "Interest"
    options:
      - label: "{work_area_1}"
        description: "{description derived from Collaboration section}"
      - label: "{work_area_2}"
        description: "{description derived from Collaboration section}"
      - label: "{work_area_3}"
        description: "{description derived from Collaboration section}"
  Q2:
    question: "How do you like to work?"
    header: "Style"
    options:
      - label: "Async"
        description: "Handoffs and artifacts — I work on my own schedule"
      - label: "Collaborative"
        description: "Pairing, discussions, real-time coordination"
      - label: "Both"
        description: "Depends on the task"
```

**Post-processing:**
- `focus = Q1 answer` (map to slug: `building` | `exploring` | `evaluating` | `other`)
- `work_style = Q2 answer` (map to: `async` | `collaborative` | `both`)

**Save to state:**
```json
{
  "onboarding": {
    "harvest_rounds": [
      "...(existing round 1)...",
      {
        "round": 2,
        "focus": "connection",
        "questions": ["interest", "style"],
        "answers": {"interest": "...", "style": "..."}
      }
    ]
  }
}
```

**API calls:** None yet (batched at COMPLETE)

**Exit:** → CONSENT (always). Transition immediately — do NOT output anything between states except the next AskUserQuestion.

---

## State: CONSENT

**Entry:** HARVEST_CONNECTION completed

**Actions:**

AskUserQuestion with multiSelect.

**Local mode:** Check `api_url` from `egregore.json`. If empty, omit the "Notifications" option (no Telegram without API). Only show Session tracking and Anonymous telemetry.

**Connected mode:** Show all three options.

```
questions:
  Q1:
    question: "A few privacy choices. These are yours to change anytime via /telemetry and /env."
    header: "Privacy"
    multiSelect: true
    options:
      - label: "Session tracking"
        description: "Powers /dashboard and /handoff. Your sessions appear in /activity."
      - label: "Anonymous telemetry"
        description: "Command names, session durations, error codes. Never code or content."
      - label: "Notifications"              ← ONLY in connected mode (api_url set)
        description: "Receive Telegram DMs when someone hands off to you or @mentions you."
```

**Post-processing:**
- Default: ALL selected (if user doesn't deselect)
- Map selections to boolean flags:
  - "Session tracking" selected → `session_tracking: true`
  - "Anonymous telemetry" selected → `telemetry: true` (absence → `telemetry: false`)
  - "Notifications" selected → `contact_preference: "all"` (absence → `contact_preference: "none"`)
- Note: `transcript_sharing` is set during website setup, not here. Inherit from egregore.json or default to the org setting.

**Save to state (nested + flat keys for backward compat):**
```json
{
  "onboarding": {
    "phase": "consent",
    "consent": {
      "session_tracking": true,
      "transcript_sharing": true,
      "telemetry": true,
      "contact_preference": "all"
    }
  },
  "session_tracking": true,
  "transcript_sharing": true,
  "telemetry": true,
  "contact_preference": "all"
}
```

Flat keys are required for backward compatibility — `bin/telemetry.sh` and `bin/transcript-archive.sh` read them directly.

**API calls:** None yet (batched at COMPLETE)

**Exit:** → ORIENT (always). Save state silently, then transition immediately — do NOT output anything between the user's consent answers and the ORIENT activity summary.

---

## State: ORIENT

**Entry:** CONSENT completed

**Actions:**

1. **Check `api_url` from `egregore.json`.** If empty (local mode), skip graph queries entirely — go straight to displaying "It's early — you're one of the first here." and the AskUserQuestion below.

   **If `api_url` is set (connected mode):** Query graph for active quests AND recent handoffs in a single bash call — do NOT make two separate graph queries:
```bash
QUESTS=$(bash bin/graph.sh query "MATCH (q:Quest {status: 'active'}) OPTIONAL MATCH (a:Artifact)-[:PART_OF]->(q) RETURN q.id AS quest, q.title AS title, count(a) AS artifacts ORDER BY count(a) DESC LIMIT 3" 2>/dev/null) && \
HANDOFFS=$(bash bin/graph.sh query "MATCH (s:Session) WHERE s.date IS NOT NULL MATCH (s)-[:BY]->(author:Person) RETURN s.topic AS topic, author.name AS author ORDER BY s.date DESC LIMIT 3" 2>/dev/null) && \
echo "QUESTS:$QUESTS|||HANDOFFS:$HANDOFFS"
```

2. Display activity summary:
   - IF local mode (no `api_url`): "It's early — you're one of the first here."
   - IF quests exist: "Here's what's active:" followed by quest list with artifact counts
   - IF handoffs exist: "Recent sessions:" followed by 2-3 recent sessions with authors
   - IF connected but empty results: "It's early — you're one of the first here."

3. AskUserQuestion:
```
questions:
  Q1:
    question: "How do you want to start?"
    header: "Start"
    options:
      - label: "Jump in"
        description: "I'll explore on my own. Help me as I go."
      - label: "Show me around"
        description: "5-minute walkthrough of the core commands"
```

4. IF "Jump in":
   Show 1-2 specific suggestions based on harvest answers:
   - IF focus = `building` AND quests exist: "Check out the {quest_title} quest — `/quest {slug}`"
   - IF focus = `exploring`: "Try `/activity` to see what's happening, or `/reflect` to capture your first thought."
   - IF focus = `evaluating`: "Run `/dashboard` to see the system from your perspective."
   → COMPLETE

5. IF "Show me around":
   Invoke `/tutorial` — it will read `domain`, `stage`, `usage_type` from state (already set by session-start.sh + harvest) and skip redundant identity/role questions.
   → COMPLETE (after tutorial finishes)

**API calls:** Graph queries via `bin/graph.sh` (routes through API gateway)

**Exit:** → COMPLETE (always)

---

## State: COMPLETE

**Entry:** ORIENT completed

**Actions (steps 1-2 always execute; steps 3-4 are skipped in local mode):**

**Local mode detection:** Check `api_url` from `egregore.json`. If empty, skip steps 3 (Neo4j) and 4 (Supabase) — the person file in memory is sufficient.

**Batching:** In connected mode, run steps 1-4 in parallel (egregore.md update + memory commit + graph MERGE + Supabase sync). In local mode, run steps 1-2 in parallel (egregore.md update + memory commit). Then run steps 5-7 in one parallel call (state update + shell alias + telemetry). The user should see ONE message at the end: "You're in." — not a play-by-play of each step. Suppress ALL output with `2>/dev/null` or variable capture.

### 1. Update `egregore.md` Members section

Read `egregore.md`. Find the `## Members` heading. Append a new member entry after the heading (or after existing member entries):

```markdown
### {display_name}
{role_label}. {focus_label}. Joined {YYYY-MM-DD}.
```

Where `role_label` is the human-readable role (e.g., "Engineering") and `focus_label` is the human-readable focus (e.g., "Building Egregore").

### 2. Create person file in memory

```bash
cat > "memory/people/{github_username}.md" << EOF
# {display_name}
GitHub: {github_username}
Role: {role}
Focus: {focus}
Work style: {work_style}
Joined: {YYYY-MM-DD}
EOF
cd memory && git add -A && git commit -m "Add {github_username}" && git push && cd -
```

### 3. Create/update Person node in Neo4j

**Skip this step entirely if `api_url` is empty (local mode).** The person file in memory (step 2) is sufficient.

**Important:** The graph has a uniqueness constraint on `(Person.name, Person.org)`. The MERGE must match on `github` to find existing nodes, but must handle the case where another Person already has the same display name. Use a two-step approach:

```bash
# Step 1: Check if name is already taken by a different person
bash bin/graph.sh query \
  "OPTIONAL MATCH (existing:Person {name: \$name, org: \$org})
   WHERE existing.github <> \$github
   RETURN existing IS NOT NULL AS taken" \
  '{"name":"...","org":"...","github":"..."}'
```

- IF `taken` is true → append github username to make name unique: `"{display_name} ({github_username})"`
- IF `taken` is false → use display_name as-is

```bash
# Step 2: MERGE the person node
bash bin/graph.sh query \
  "MERGE (p:Person {github: \$github, org: \$org})
   ON CREATE SET p.name = \$name, p.fullName = \$fullName, p.role = \$role,
     p.focus = \$focus, p.workStyle = \$workStyle, p.joined = date(),
     p.sessionTracking = \$sessionTracking, p.transcriptSharing = \$transcriptSharing,
     p.telemetry = \$telemetry, p.contactPreference = \$contactPreference
   ON MATCH SET p.name = \$name, p.role = \$role, p.focus = \$focus,
     p.workStyle = \$workStyle, p.sessionTracking = \$sessionTracking,
     p.transcriptSharing = \$transcriptSharing, p.telemetry = \$telemetry,
     p.contactPreference = \$contactPreference
   RETURN p.name" \
  '{"github":"...","org":"...","name":"...","fullName":"...","role":"...","focus":"...","workStyle":"...","sessionTracking":true,"transcriptSharing":true,"telemetry":true,"contactPreference":"all"}'
```

Read `org_slug` from `egregore.json` → `github_org` field, lowercased and hyphenated (e.g., "Curve-Labs" → use the slug from the API key prefix, or derive from `jq -r '.github_org' egregore.json | tr '[:upper:]' '[:lower:]'`). Fill all parameter values from state — do NOT leave `"..."` placeholders.

### 4. Sync to Supabase

**Skip this step entirely if `api_url` is empty (local mode).**

```bash
API_URL="$(jq -r '.api_url // empty' egregore.json)"
API_KEY="$(grep '^EGREGORE_API_KEY=' .env | cut -d'=' -f2-)"
curl -sf "${API_URL}/api/user/ensure" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"github_username":"...","github_name":"...","display_name":"...","member_role":"...","focus":"...","work_style":"...","consent_session_tracking":true,"consent_transcript_sharing":true,"consent_telemetry":true,"contact_preference":"all"}'
```

Fill all values from state. `member_role` maps to the harvest role answer, `focus` and `work_style` from harvest round 2, consent booleans from the CONSENT state.

### 5. Update state

```json
{
  "onboarding_complete": true,
  "onboarding": {
    "phase": "complete",
    "completed_at": "{ISO timestamp}"
  },
  "display_name": "...",
  "usage_type": "joiner_group"
}
```

### 6. Shell alias

```bash
ALIAS_NAME=$(bash bin/ensure-shell-function.sh)
```

Tell the user: "From now on, just type **`{ALIAS_NAME}`** in any terminal to launch."

### 7. Emit telemetry

```bash
bash bin/telemetry.sh emit "onboarding_complete" '{"type":"joiner","rounds":2}' 2>/dev/null &
```

### 8. Done

Display: **"You're in. Type `/activity` to see what's happening, or just start working."**
