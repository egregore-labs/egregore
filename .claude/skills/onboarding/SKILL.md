Welcome a new user to this Egregore.

Deterministic state machine: VERIFY → ORIENT → FIRST_TODO → FIRST_HANDOFF. Orient first, collect later — show what Egregore is before asking questions. Profile data collected progressively during real work.

## Output discipline — CRITICAL

This is a conversation with a new user, not a CI pipeline.

**Rules:**
- **Batch all reads at once.** Before each state, read ALL files you'll need in a single parallel tool call.
- **Batch all writes at once.** State file update + API call = one parallel tool call group.
- **Suppress all command output.** Every bash call must use `2>/dev/null` or capture output.
- **No narration of internal steps.** Never say "Let me read the config" or "Saving to state."
- **VERIFY should be invisible.** All checks in one bash call. If everything passes, say nothing.

**What the user should experience:**
1. A framing of what Egregore is (2-3 sentences from egregore.md)
2. "What are you working on?" → creates first todo + branch
3. Name question (one AskUserQuestion)
4. User works normally
5. On session end: first handoff + role question
6. "You're in."

## Local mode gate (applies to ALL states)

During VERIFY, check `api_url` from `egregore.json`. Store for entire flow.

**If `api_url` is empty — local mode:**
- DO NOT call `bin/graph.sh` under any circumstances.
- DO NOT call `curl` or any HTTP endpoint.
- ONLY `git` operations are allowed.

**If `api_url` is set — connected mode.** All API calls proceed normally.

---

## Resumption

Read `.egregore-state.json`. If `onboarding.phase` exists and `onboarding_complete` is false, resume from that phase. Do NOT restart from VERIFY.

**Migration from old 7-state machine:** If phase is `welcome`, `harvest_identity`, `harvest_connection`, or `consent`:
```bash
PHASE=$(jq -r '.onboarding.phase // empty' .egregore-state.json 2>/dev/null)
case "$PHASE" in
  welcome|harvest_identity|harvest_connection|consent)
    # Migrate: preserve existing data, reset to new flow
    jq '.onboarding.phase = "orient"' .egregore-state.json > .egregore-state.tmp && mv .egregore-state.tmp .egregore-state.json
    # Build profile_fields_collected from existing state
    FIELDS="[]"
    [ "$(jq -r '.display_name // empty' .egregore-state.json)" ] && FIELDS=$(echo "$FIELDS" | jq '. + ["name"]')
    jq --argjson f "$FIELDS" '.profile_fields_collected = $f' .egregore-state.json > .egregore-state.tmp && mv .egregore-state.tmp .egregore-state.json
    ;;
esac
```
Preserved from state: `display_name`, `name`, `github_username`, `github_name` — never re-asked.

**If `onboarding_complete` is true:** Validate the people file:
```bash
USERNAME=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
PEOPLE_FILE="memory/people/${USERNAME}.md"
HAS_ROLE=$(grep -c '^Role:' "$PEOPLE_FILE" 2>/dev/null || echo 0)
```
- `HAS_ROLE > 0` → "You're already set up. Run `/me` to update your profile." Stop.
- `HAS_ROLE = 0` → reset `onboarding.phase = "first_todo"`, resume.

**If phase = `first_todo` (returning from dropped session):**
Say: "Welcome back! Last time you were working on {context from git log/branch}. Before we continue — let's capture what you did last session." Then run FIRST_HANDOFF for the previous session's work.

---

## State: VERIFY

**Entry:** `onboarding_complete` is false (or missing)

**Actions:** Run all checks in a single bash call — invisible if everything passes:
```bash
TOKEN=$(grep '^GITHUB_TOKEN=' .env 2>/dev/null | cut -d'=' -f2-) && \
APIKEY=$(grep '^EGREGORE_API_KEY=' .env 2>/dev/null | cut -d'=' -f2-) && \
API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null) && \
SYMLINK=$(test -L memory && echo "ok" || echo "") && \
ORG=$(jq -r '.org_name' egregore.json 2>/dev/null) && \
echo "token:${TOKEN:+ok} apikey:${APIKEY:+ok} apiurl:${API_URL:+ok} memory:${SYMLINK} org:${ORG}"
```

Also read `egregore.md` and `.egregore-state.json` in parallel (needed for ORIENT).

**Exit conditions:**
- All checks pass → ORIENT
- `GITHUB_TOKEN` missing → run `bash bin/github-auth.sh`, re-check. Still missing → HALT.
- `EGREGORE_API_KEY` missing AND `api_url` set → HALT: "Missing API key."
- `EGREGORE_API_KEY` missing AND `api_url` empty → skip (local mode)
- `memory/` missing → clone from `egregore.json → memory_repo`, create symlink. Clone fails → HALT.

---

## State: ORIENT

**Entry:** VERIFY passed

**Actions:**

Read `egregore.md` Identity and Culture sections (already loaded from VERIFY).

Display:

```
An organization should be able to think across sessions, across
people, across time. Egregore is how {org_name} does that.

{First 2 sentences from Identity section}

The way it works: you declare what you're working on (/todo),
do the work, then capture what you learned (/handoff).
That's the core loop — everything else builds on it.

What are you working on right now?
```

No questions. No choices. Context, then action.

**State update:** `onboarding.phase = "orient"`, `onboarding.started_at = {ISO timestamp}`

**Exit:** → FIRST_TODO (user describes their work)

---

## State: FIRST_TODO

**Entry:** User described their work in response to ORIENT

**Actions:**

1. **Create the todo** — use `/todo` flow if graph is connected, local note if not. The todo is the vehicle — what matters is the user declared work.

2. **Ask name** via AskUserQuestion:
```
header: "Name"
question: "What should we call you here? Your GitHub name is {github_name}."
options:
  - label: "{github_name}"
    description: "Use my GitHub name"
  - label: "Something else"
    description: "I go by a different name"
```
If "Something else" → user provides name via freeform. Validate: 1-30 chars, alphanumeric + spaces + hyphens.

3. **Create working branch:** `dev/{name}/{topic-slug}`

4. **Show technical orientation** (onboarding only — dotted frame, real paths):
```
  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
  What just happened:

  main ← stable releases
    └─ develop ← where work integrates
         └─ dev/{name}/{slug} ← your branch

  Your changes live on your branch. When you /save,
  it creates a PR to develop.
  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
```

5. **Set consent defaults** in `.egregore-state.json`:
```json
{
  "session_tracking": true,
  "transcript_sharing": false,
  "telemetry": true,
  "contact_preference": "all",
  "consent_collected": false
}
```
Note: `transcript_sharing` defaults to `false` (opt-in). Other flags default on. `consent_collected: false` signals these are defaults — explicit consent collected in a later session.

**State update — MANDATORY**, run immediately after collecting the name:
```bash
CHOSEN_NAME="<the name the user chose or typed>"
jq --arg dn "$CHOSEN_NAME" --arg n "$(echo "$CHOSEN_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')" \
  '.display_name = $dn | .name = $n | .onboarding.phase = "first_todo" | .profile_fields_collected = ["name"]' \
  .egregore-state.json > .egregore-state.tmp && mv .egregore-state.tmp .egregore-state.json
```
**Verification:** Confirm the write:
```bash
jq -r '.display_name' .egregore-state.json 2>/dev/null
```
Must return the chosen name. If not, retry.

**API calls (connected mode only):** `POST /api/user/ensure` with github_username, display_name

**Exit:** → User works normally. Claude assists as usual. FIRST_HANDOFF triggers when the user ends the session.

---

## State: FIRST_HANDOFF

**Entry:** User signals session-end intent while `onboarding_complete` is false and `phase` is `first_todo`.

**Trigger detection:**
1. User runs `/wrap`, `/handoff`, or `/save` — always triggers
2. Session-end phrases: "I'm done", "wrapping up", "gotta go", "signing off"
3. **Disambiguation:** "I'm done with this file" = subtask, NOT session end. Only trigger on clear session-end intent. When ambiguous, ask: "Done for the session, or just this task?"
4. `/save` during onboarding runs normal save flow AND triggers FIRST_HANDOFF

**If terminal closes without triggering:** State stays at `phase = "first_todo"`. Next session detects this in Resumption and runs FIRST_HANDOFF for previous session's work.

**Actions:**

1. Intercept with context:
> Before you close out — this is the part that makes the system work. A handoff captures what you did so the organization remembers it. Not a summary for a manager — a briefing for the next session, or the next person.

2. Run the handoff flow (same as `/handoff`).

3. During the handoff, collect role:
```
header: "Role"
question: "One thing that helps route handoffs — what's your role?"
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

4. Show technical orientation:
```
  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
  What just happened:

  memory/handoffs/
    └─ {date}-{slug}.md      ← your handoff

  memory/people/
    └─ {username}.md          ← your profile

  This lives in the shared memory repo. Anyone who
  starts a session sees your handoff in /activity.
  ┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄┄
```

**Completion actions (steps 1-5 in parallel, gate on verification before 6-8):**

### 1. Create person file in memory
```bash
cat > "memory/people/{github_username}.md" << EOF
# {display_name}
GitHub: {github_username}
Role: {role}
Focus: (not yet collected)
Work style: (not yet collected)
Joined: {YYYY-MM-DD}
EOF
```

### 2. Update egregore.md Members section
Append after `## Members`:
```markdown
### {display_name}
{role_label}. Joined {YYYY-MM-DD}.
```

### 3. Commit + push memory
```bash
cd memory && git add -A && git commit -m "Add {github_username}" && git push origin main && cd -
```

### 4. MERGE Person node (connected mode only)

Two-step to handle name uniqueness across orgs:
```bash
# Step 1: Check if name is taken by a different person
bash bin/graph.sh query \
  "OPTIONAL MATCH (existing:Person {name: \$name})
   WHERE existing.github <> \$github
   RETURN existing IS NOT NULL AS taken" \
  '{"name":"...","github":"..."}'
```
If `taken` → append github username: `"{display_name} ({github_username})"`

```bash
# Step 2: MERGE the person node
bash bin/graph.sh query \
  "MERGE (p:Person {github: \$github})
   ON CREATE SET p.name = \$name, p.fullName = \$fullName, p.role = \$role, p.joined = date()
   ON MATCH SET p.name = \$name, p.role = \$role
   WITH p MATCH (o:Org {id: \$_org}) MERGE (p)-[:MEMBER_OF]->(o)
   RETURN p.name" \
  '{"github":"...","name":"...","fullName":"...","role":"..."}'
```
Note: `$_org` is auto-injected by the API from the API key — do NOT pass it as a parameter.

### 5. Sync to Supabase (connected mode only)
```bash
API_URL="$(jq -r '.api_url // empty' egregore.json)"
API_KEY="$(grep '^EGREGORE_API_KEY=' .env | cut -d'=' -f2-)"
curl -sf "${API_URL}/api/user/ensure" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"github_username":"...","display_name":"...","member_role":"..."}' 2>/dev/null
```

**Verification gate (after steps 1-3):**
```bash
USERNAME=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
PEOPLE_FILE="memory/people/${USERNAME}.md"
if [ -f "$PEOPLE_FILE" ] && grep -q '^Role:' "$PEOPLE_FILE" 2>/dev/null; then
  echo "people_file:ok"
else
  echo "people_file:missing"
fi
```
- `people_file:ok` → proceed to steps 6-8
- `people_file:missing` → set `phase = "first_todo"`. Tell user: "Almost done, but your profile didn't save. Try `/handoff` again next session."

### 6. Update state
```bash
jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.onboarding_complete = true
   | .onboarding.phase = "complete"
   | .onboarding.completed_at = $ts
   | .profile_fields_collected = ["name", "role"]' \
  .egregore-state.json > .egregore-state.tmp && mv .egregore-state.tmp .egregore-state.json
```
Do NOT set `usage_type` — already set by installer.

**Verification — MANDATORY:** Immediately after the write, confirm it persisted:
```bash
jq -r '.onboarding_complete' .egregore-state.json 2>/dev/null
```
Must return `true`. If not, retry the write.

### 7. Shell alias
```bash
ALIAS_NAME=$(bash bin/ensure-shell-function.sh)
```

### 8. Telemetry
```bash
TYPE=$(jq -r '.usage_type // "joiner_group"' .egregore-state.json 2>/dev/null)
bash bin/telemetry.sh emit "onboarding_complete" "{\"type\":\"$TYPE\"}" 2>/dev/null &
```

Display: **"You're in. From now on, just type `{ALIAS_NAME}` in any terminal to launch."**

---

## Progressive Profile Collection (follow-up sessions)

Everything beyond name and role is collected inline during the first few sessions:

| Data | Collected when | How |
|------|---------------|-----|
| **Name** | FIRST_TODO | AskUserQuestion |
| **Role** | FIRST_HANDOFF | AskUserQuestion |
| **Focus** | First `/quest` or `/activity` (2nd+ session) | Derive from egregore.md Collaboration section |
| **Work style** | First `/ask` (2nd+ session) | Async / Collaborative / Both |
| **Consent** | Second session startup | "Egregore tracks sessions by default. Change via `/telemetry`. All good?" |

Track in `.egregore-state.json`:
```json
{ "profile_fields_collected": ["name", "role"] }
```

Commands check before asking:
```bash
COLLECTED=$(jq -r '.profile_fields_collected // [] | join(",")' .egregore-state.json 2>/dev/null)
```
If field not in list → ask inline. After collecting → append to array, update people file.

**Rule:** Never more than one profile question per session.

---

## Edge cases

| Scenario | Handling |
|----------|----------|
| Neo4j unavailable (connected mode) | Create person file in memory. Show: "Graph offline — profile saved locally." |
| Local mode | Skip all graph/API silently. Memory files are the canonical record. |
| Terminal closes mid-onboarding | Resume from saved phase on next session. Collected data preserved. |
| `egregore.md` missing | Use generic text: "Welcome to {org_name}." Skip narration. |
| People file already exists (invite stub) | Overwrite with full profile. Preserve `Joined` date from stub if earlier. |
| `/save` during FIRST_TODO | Run normal save, then check if session-end → trigger FIRST_HANDOFF. If continuing → stay in FIRST_TODO. |
