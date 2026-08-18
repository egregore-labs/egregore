---
name: onboarding
description: "Use for /onboarding, or when a new member's onboarding is not yet complete — runs the deterministic VERIFY, ORIENT, INVITE, FIRST_HANDOFF welcome flow."
---

Welcome a new user to this Egregore.

Deterministic state machine: VERIFY → ORIENT → INVITE → FIRST_HANDOFF. Orient first, invite early — show what Egregore is, then show it works best with others. Profile data collected progressively during real work.

## When to invoke

User says: "/onboarding", or is a new user whose `onboarding_complete` is false and needs to be verified, oriented, offered an invite, and walked through their first handoff.

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
2. "It works best when there's someone on the other end."
3. Name question (one AskUserQuestion)
4. **Creators only:** Invite offer → invite someone or skip. **Joiners skip this step entirely** — they just got here; they shouldn't be bringing more people in before they've done any work.
5. Save/handoff one-liner explanation
6. "What are you working on?" → creates branch
7. User works normally
8. On session end: first handoff. Plus a gentle nudge about inviting others, **creators only, if they skipped the invite offer**.
9. "You're in."

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

**Installer short-circuit contract:** Before asking name or offering invites, read these state keys:
- `.onboarding_complete`
- `.onboarding.installer_captured`
- `.onboarding.invite_handled_by`
- `.profile_fields_collected`
- `.display_name`
- `.member_role`

If `.onboarding_complete` is true and `.profile_fields_collected` contains both `name` and `role`, do not run onboarding and do not ask setup questions again. Say: "You're already set up. What are you working on?"

If `.onboarding_complete` is true but `role` is missing from `.profile_fields_collected`, ask only the role question, write `.member_role`, append `role` to `.profile_fields_collected`, update `memory/people/{github_username}.md`, then continue to "What are you working on?" Do not ask name, invite, Telegram, runtime, or workspace setup again.

If `.onboarding.installer_captured` is true, `.display_name` is non-empty, and `.profile_fields_collected` contains `name`, do not ask for the user's name again. If `.onboarding.invite_handled_by` is `installer`, do not offer the invite step again; continue with save/handoff teaching.

**Migration from old state machines:** If phase is `welcome`, `harvest_identity`, `harvest_connection`, `consent`, or `first_todo`:
```bash
PHASE=$(jq -r '.onboarding.phase // empty' .egregore-state.json 2>/dev/null)
case "$PHASE" in
  welcome|harvest_identity|harvest_connection|consent|first_todo)
    # Migrate: preserve existing data, reset to new flow
    # If name already collected, skip to invite; otherwise orient
    HAS_NAME=$(jq -r '.display_name // empty' .egregore-state.json 2>/dev/null)
    if [ -n "$HAS_NAME" ]; then
      NEW_PHASE="invite"
    else
      NEW_PHASE="orient"
    fi
    jq --arg p "$NEW_PHASE" '.onboarding.phase = $p' .egregore-state.json > .egregore-state.tmp && mv .egregore-state.tmp .egregore-state.json
    # Build profile_fields_collected from existing state
    FIELDS="[]"
    [ -n "$HAS_NAME" ] && FIELDS=$(echo "$FIELDS" | jq '. + ["name"]')
    jq --argjson f "$FIELDS" '.profile_fields_collected = $f' .egregore-state.json > .egregore-state.tmp && mv .egregore-state.tmp .egregore-state.json
    ;;
esac
```
Preserved from state: `display_name`, `name`, `github_username`, `github_name` — never re-asked.

**If `onboarding_complete` is true:** Validate the people file:
```bash
USERNAME=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
PEOPLE_FILE="memory/people/${USERNAME}.md"
HAS_PROFILE=$(grep -c '^Onboarded:' "$PEOPLE_FILE" 2>/dev/null || echo 0)
```
- `HAS_PROFILE > 0` → "You're already set up. Run `/me` to update your profile." Stop.
- `HAS_PROFILE = 0` → reset `onboarding.phase = "invite"`, resume.

The `^Onboarded:` check matches the verification gate (step 1 below) and `bin/session-start.sh` auto-heal — all three checks share one witness.

**If phase = `invite` (returning from dropped session):**
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

Display an **Insight** block wrapping the framing. Use this exact format — the `✱ Insight` header with a horizontal rule above and below the body. Do NOT add any preamble. No improvised explanations of how the egregore works, no references to internal configuration (field names, modes, services, infrastructure), no synthesis of what the state machine is doing. The Insight contains **only** the two framing paragraphs below — render them as-is.

```
✱ Insight ────────────────────────────────────────

Every session leaves traces — decisions, patterns, context.
Egregore makes those traces persistent and shared.

You do your work. When you're done, you hand off what you
learned. The next session — yours or someone else's — starts
smarter.

──────────────────────────────────────────────────
```

Then, outside the Insight block:

```
It works best with someone on the other end.
```

Then **ask name** via AskUserQuestion:
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

**State update — MANDATORY**, run immediately after collecting the name:
```bash
CHOSEN_NAME="<the name the user chose or typed>"
jq --arg dn "$CHOSEN_NAME" --arg n "$(echo "$CHOSEN_NAME" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')" \
  '.display_name = $dn | .name = $n | .onboarding.phase = "orient" | .onboarding.started_at = "'$(date -u +%Y-%m-%dT%H:%M:%SZ)'" | .profile_fields_collected = ["name"]' \
  .egregore-state.json > .egregore-state.tmp && mv .egregore-state.tmp .egregore-state.json
```
**Verification:** Confirm the write:
```bash
jq -r '.display_name' .egregore-state.json 2>/dev/null
```
Must return the chosen name. If not, retry.

**Identity sync — MANDATORY:** run `bash bin/person.sh sync`. This writes the
preferred name to the canonical person profile and, in connected mode, projects
the same identity to Supabase and the graph. Do not call `/api/user/ensure` or
write Person Cypher separately.

**Exit:** → INVITE

---

## State: INVITE

**Entry:** Name collected in ORIENT

**Actions:**

**Detect user type first — this gates steps 1-3 below.**
```bash
USAGE_TYPE=$(jq -r '.usage_type // "joiner_group"' .egregore-state.json 2>/dev/null)
```

- **`usage_type == "founder_group"` (creator flow)** — the user just set up a fresh egregore. They're the first person here. Run steps 1-3 to offer them an invite, then continue to step 4.
- **`usage_type == "joiner_group"` (invited user)** — the user was invited and is joining an existing group. **Skip steps 1-3 entirely.** A brand-new joiner should not be inviting others before they've done any work — they don't know the group dynamics yet, and the UX implies they're expected to bring people in. Jump directly to step 4. They can always run `/invite` later.

1. **Offer invite** via AskUserQuestion *(creator flow only)*:
```
header: "Invite"
question: "Anyone you'd want to bring in? If you have their GitHub username, we can send them access right now."
options:
  - label: "Invite someone"
    description: "I have a GitHub username to invite"
  - label: "I'll work solo for now"
    description: "Skip — I can always /invite later"
```

2. **If "Invite someone"** *(creator flow only)*:
   - Ask for the GitHub username (freeform via "Other" on next AskUserQuestion, or just ask as text)
   - Run the full `/invite` flow (invoke the invite skill with the username)
   - After invite completes, continue to step 4

3. **If "I'll work solo for now"** *(creator flow only)*: continue to step 4

4. **Teach save/handoff** (minimal — one sentence each):
```
Two things to know when you're done:
  /save    — pushes your branch and opens a PR
  /handoff — captures what you learned for next time
```

5. **Ask what they're working on:**
```
What are you working on?
```

6. **When user describes work** → create working branch: `dev/{name}/{topic-slug}`

7. **Show technical orientation** (onboarding only — dotted frame, real paths):
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

8. **Set consent defaults** in `.egregore-state.json`:
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

**State update:**
```bash
# For joiners (skipped the invite offer entirely), set invite_skipped = true.
# For creators who answered the question, set invite_skipped = true/false per their answer.
INVITE_SKIPPED="<true if joiner, or creator chose 'I'll work solo for now'; false if creator chose 'Invite someone'>"
jq --argjson skip "$INVITE_SKIPPED" \
  '.onboarding.phase = "invite" | .onboarding.invite_skipped = $skip' \
  .egregore-state.json > .egregore-state.tmp && mv .egregore-state.tmp .egregore-state.json
```

**Joiner fast-track:** If `usage_type == "joiner_group"`, run the Completion Actions below in FIRST_HANDOFF **now**, with these adaptations:

- Skip the FIRST_HANDOFF interception message (no session-end narrative — the joiner hasn't done work yet; we're just establishing their profile).
- **Step 1:** `bin/person.sh onboard` upgrades an invite stub into the canonical
  identity profile while preserving its earlier joined date and any body.
- **Step 4 (flip flag):** write `onboarding_complete = true`,
  `phase = "complete"`, `completed_at`.
- All other steps are unchanged.

Rationale: joiners don't need to "prove the loop" — the Egregore is already established and the inviter already did. Making joiners run `/handoff` before they can Edit/Write traps every first-time invitee (hook blocks all Edit/Write/EnterWorktree while `onboarding_complete` is false). The joiner's `intent answer` above is their onboarding signal; that's enough.

**Exit:**
- Creators: → User works normally. FIRST_HANDOFF triggers when they end the session.
- Joiners (after fast-track above): → `onboarding_complete: true` is now set. User works normally; no FIRST_HANDOFF gate.

---

## State: FIRST_HANDOFF

**Entry:** Creator (`usage_type == "founder_group"`) signals session-end intent while `onboarding_complete` is false and `phase` is `invite`.

Joiners never reach this state — they complete in the INVITE state's joiner fast-track. FIRST_HANDOFF is exclusively a creator flow (it teaches the handoff loop before work unlocks — redundant for joiners, whose Egregore already has proven the loop).

**Trigger detection:**
1. User runs `/wrap`, `/handoff`, or `/save` — always triggers
2. Session-end phrases: "I'm done", "wrapping up", "gotta go", "signing off"
3. **Disambiguation:** "I'm done with this file" = subtask, NOT session end. Only trigger on clear session-end intent. When ambiguous, ask: "Done for the session, or just this task?"
4. `/save` during onboarding runs normal save flow AND triggers FIRST_HANDOFF

**If terminal closes without triggering:** State stays at `phase = "invite"`. Next session detects this in Resumption and runs FIRST_HANDOFF for previous session's work.

**Actions:**

1. Intercept with context:
> Before you close out — this is the part that makes the system work. A handoff captures what you did so the organization remembers it. Not a summary for a manager — a briefing for the next session, or the next person.

2. Run the handoff flow (same as `/handoff`).

3. Show technical orientation:
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

4. **Gentle nudge (creator flow only, if invite was skipped):**

Check both `usage_type` and `onboarding.invite_skipped` in `.egregore-state.json`. Only show this nudge if `usage_type == "founder_group"` **and** `invite_skipped == true`. Skip entirely for joiners — they didn't decline an invite, they were never offered one.

```
This is what someone would see if you invited them —
your handoff in /activity, ready to pick up. Run /invite
anytime to bring someone in.
```

**Completion actions (steps 1-3, gate on verification before 4-6):**

**Completion witness:** The `Onboarded:` line in step 1 is what `bin/session-start.sh` auto-heal greps for if a state write is ever dropped. Write it exactly once, only here, as part of the person file template. Case-sensitive — do not rename, lowercase, or move into frontmatter.

Auto-heal also accepts a back-compat witness: any person file whose first line starts with `# ` (markdown H1). This grandfathers pre-PR-544 users whose person files predate the explicit witness. Invite stubs (which use `---` YAML frontmatter) do not match either witness, so they cannot accidentally short-circuit onboarding.

### 1. Complete and reconcile the person identity
```bash
bash bin/person.sh onboard
```

This is the only identity write. It creates or updates
`memory/people/{github_username}.md`, records the immutable GitHub numeric id
when available, preferred name, GitHub login/aliases, explicitly supplied
emails, and the `Onboarded:` witness. In connected mode it reconciles the same
person into Supabase and Neo4j and moves known relationships off duplicate
Person nodes.

### 2. Update egregore.md Members section
Append after `## Members`:
```markdown
### {display_name}
Joined {YYYY-MM-DD}.
```

### 3. Commit + push memory
```bash
cd memory && git add -A && git commit -m "Add {github_username}" && git push origin main && cd -
```

**Verification gate (after steps 1-3):**
```bash
USERNAME=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
PEOPLE_FILE="memory/people/${USERNAME}.md"
if [ -f "$PEOPLE_FILE" ] && grep -q '^Onboarded:' "$PEOPLE_FILE" 2>/dev/null; then
  echo "people_file:ok"
else
  echo "people_file:missing"
fi
```
The gate checks the `Onboarded:` witness specifically — not `GitHub:` — because the witness is what auto-heal also depends on. If this gate passes, auto-heal will work; if it fails, neither path is safe.
- `people_file:ok` → proceed to steps 6-8
- `people_file:missing` → set `phase = "invite"`. Tell user: "Almost done, but your profile didn't save. Try `/handoff` again next session."

### 4. Update state
```bash
jq --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '.onboarding_complete = true
   | .onboarding.phase = "complete"
   | .onboarding.completed_at = $ts
   | .profile_fields_collected = ["name"]' \
  .egregore-state.json > .egregore-state.tmp && mv .egregore-state.tmp .egregore-state.json
```
Do NOT set `usage_type` — already set by installer.

**Verification — MANDATORY:** Immediately after the write, confirm it persisted:
```bash
jq -r '.onboarding_complete' .egregore-state.json 2>/dev/null
```
Must return `true`. If not, retry the write.

### 5. Shell alias
```bash
ALIAS_NAME=$(bash bin/ensure-shell-function.sh)
```

### 6. Telemetry
```bash
TYPE=$(jq -r '.usage_type // "joiner_group"' .egregore-state.json 2>/dev/null)
bash bin/telemetry.sh emit "onboarding_complete" "{\"type\":\"$TYPE\"}" 2>/dev/null &
```

Display: **"You're in. From now on, just type `{ALIAS_NAME}` in any terminal to launch."**

---

## Progressive Profile Collection (follow-up sessions)

Everything beyond name is collected inline during the first few sessions:

| Data | Collected when | How |
|------|---------------|-----|
| **Name** | ORIENT | AskUserQuestion |
| **Focus** | First `/quest` or `/activity` (2nd+ session) | Derive from egregore.md Collaboration section |
| **Work style** | First `/ask` (2nd+ session) | Async / Collaborative / Both |
| **Consent** | Second session startup | "Egregore tracks sessions by default. Change via `/telemetry`. All good?" |

Track in `.egregore-state.json`:
```json
{ "profile_fields_collected": ["name"] }
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
| People file already exists (invite stub) | `bin/person.sh onboard` upgrades it and preserves the earlier `Joined` date/body. |
| `/save` during INVITE phase | Run normal save, then check if session-end → trigger FIRST_HANDOFF. If continuing → stay in INVITE. |
| Invite fails (permissions, network) | Show error, continue to save/handoff teaching. Don't block onboarding on invite failure. |
| User invites multiple people | Allow — run `/invite` for each username. No limit during onboarding. |
