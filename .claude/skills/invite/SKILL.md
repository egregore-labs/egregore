Invite someone to this Egregore. Handles GitHub org invitation + Egregore setup link.

Arguments: $ARGUMENTS (Required: GitHub username of the person to invite)

## Execution rules

**Neo4j-first (connected mode only).** In connected mode, all queries via `bash bin/graph.sh query "..."`. No MCP. No direct curl to Neo4j. In local mode, Step 1b routes to Step 2L (GitHub API only) — Steps 2–4b (graph + notify) are skipped entirely. Do NOT show any graph-related messaging in local mode (no "Person node created", no "recorded in graph", no Neo4j references).
**Notifications via `bash bin/notify.sh send` (connected mode only)**. No direct curl to Telegram.
**CRITICAL: Suppress raw output.** Never show raw JSON to the user. All `bin/graph.sh` and `bin/notify.sh` calls MUST capture output in a variable and only show formatted status lines.

**CRITICAL: Never expose credentials in tool output.**
- Never read tokens in a separate bash call — always inline.
- Never pass tokens as visible arguments — read from `.env` inside the script.
- All credential handling happens inside a single bash call that only outputs the formatted result.

## Step 1: Validate

If `$ARGUMENTS` is empty, show usage and stop:
```
Usage: /invite <github-username>

Example: /invite newuser
```

## Step 1b: Local mode detection

Check `api_url` from `egregore.json`:
```bash
API_URL=$(jq -r '.api_url // empty' egregore.json 2>/dev/null)
```

**If `api_url` is empty → use LOCAL INVITE FLOW (Step 2L below). Skip Steps 2-4b entirely.**
**If `api_url` is set → use CONNECTED INVITE FLOW (Step 2 below).**

---

## Step 2L: Local mode invite (GitHub API only)

Run ONE bash call with description "Inviting {username} via GitHub":

```bash
bash -c '
USERNAME="$1"
GH_TOKEN=$(grep "^GITHUB_TOKEN=" .env | cut -d"=" -f2-)
GITHUB_ORG=$(jq -r ".github_org" egregore.json)
REPO_NAME=$(jq -r ".repo_name // empty" egregore.json)
MEMORY_REPO=$(jq -r ".memory_repo // empty" egregore.json)
MEMORY_NAME=$(basename "$MEMORY_REPO" .git)
REPOS=$(jq -r ".repos[]? // empty" egregore.json)

if [ -z "$GH_TOKEN" ]; then
  echo "ERROR: No GitHub token. Run: bash bin/github-auth.sh"
  exit 1
fi
if [ -z "$REPO_NAME" ]; then
  echo "ERROR: repo_name not set in egregore.json"
  exit 1
fi

# Add collaborator to core repo
CORE=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_ORG/$REPO_NAME/collaborators/$USERNAME" \
  -d "{\"permission\":\"push\"}")

# Add collaborator to memory repo
MEM=$(curl -s -o /dev/null -w "%{http_code}" -X PUT \
  -H "Authorization: Bearer $GH_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  "https://api.github.com/repos/$GITHUB_ORG/$MEMORY_NAME/collaborators/$USERNAME" \
  -d "{\"permission\":\"push\"}")

# Add to managed repos
for REPO in $REPOS; do
  curl -s -o /dev/null -X PUT \
    -H "Authorization: Bearer $GH_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    "https://api.github.com/repos/$GITHUB_ORG/$REPO/collaborators/$USERNAME" \
    -d "{\"permission\":\"push\"}" 2>/dev/null || true
done

echo "{\"core\":\"$CORE\",\"memory\":\"$MEM\",\"username\":\"$USERNAME\",\"org\":\"$GITHUB_ORG\",\"repo\":\"$REPO_NAME\"}"
' -- "$ARGUMENTS"
```

**Create person file in memory:**
```bash
INVITE_USER="$ARGUMENTS"
INVITER=$(jq -r '.display_name // .github_username' .egregore-state.json 2>/dev/null)
TODAY=$(date -u +%Y-%m-%d)
cat > "memory/people/${INVITE_USER}.md" << EOF
---
name: ${INVITE_USER}
github: ${INVITE_USER}
invited_by: ${INVITER}
joined: ${TODAY}
---
EOF
cd memory && git add -A && git commit -m "Invite ${INVITE_USER}" && git push 2>/dev/null && cd -
```

**Display result:**

If core HTTP status is 201 or 204:
```
Invited {username} to {org_name}.

  Core repo access:    ✓ added
  Memory repo access:  ✓ added
  Person file:         ✓ created

Tell them to run:

  npx create-egregore@latest join {github_org}/{repo_name}
```

**Telegram group link:** After the join command, check `egregore.json` for `telegram_group_link`. If present, append:
```
Telegram group: {telegram_group_link}
```

If core HTTP status is 422: user was already a collaborator — show "already has access."

If core HTTP status is 403 or other error:
```
Could not add {username} as a collaborator.
You may need org admin permissions. Add them manually:
  https://github.com/{github_org}/{repo_name}/settings/access
```

**After local invite, STOP.** Do not proceed to Steps 3-5 (they require the API).

---

## Step 2: Send invite (single call — credentials stay hidden)

Run ONE bash call with description "Sending invite to {username}":

```bash
bash -c '
USERNAME="$1"
GH_TOKEN=$(grep "^GITHUB_TOKEN=" .env | cut -d"=" -f2-)
API_KEY=$(grep "^EGREGORE_API_KEY=" .env | cut -d"=" -f2-)
GITHUB_ORG=$(jq -r ".github_org" egregore.json)
API_URL=$(jq -r ".api_url" egregore.json)
ORG_NAME=$(jq -r ".org_name" egregore.json)
REPO_NAME=$(jq -r ".repo_name // empty" egregore.json)
if [ -z "$REPO_NAME" ]; then echo "ERROR: repo_name not set in egregore.json"; exit 1; fi
SLUG=$(jq -r ".slug" egregore.json)

if [ -z "$GH_TOKEN" ]; then
  echo "ERROR: No GitHub token found. Run: bash bin/github-auth.sh"
  exit 1
fi

if [ -z "$API_KEY" ]; then
  echo "ERROR: No Egregore API key found. Check .env for EGREGORE_API_KEY"
  exit 1
fi

RESP=$(curl -s -X POST "$API_URL/api/org/invite" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $API_KEY" \
  -d "{\"github_org\": \"$GITHUB_ORG\", \"github_username\": \"$USERNAME\", \"repo_name\": \"$REPO_NAME\", \"slug\": \"$SLUG\", \"github_token\": \"$GH_TOKEN\"}")

# Output structured JSON for parsing
echo "$RESP" | jq -c "{
  ok: (if .invite_url then true else false end),
  invite_url: .invite_url,
  invite_token: .invite_token,
  github_invite: .github_invite,
  memory_access: .memory_access,
  org_name: \"$ORG_NAME\",
  github_org: \"$GITHUB_ORG\",
  username: \"$USERNAME\",
  error: .detail
}"
' -- "$ARGUMENTS"
```

## Step 3: Display result

Parse the JSON output from Step 2. **Never show raw JSON to the user.**

**Success** (ok=true):
```
Inviting {username} to {org_name}...

  GitHub org invitation: sent
  Memory repo access:    added
  Invite link:           created

Share this link with {username}:

  {invite_url}

They'll authenticate with GitHub, accept the org invite,
and get a one-line install command.
```

**Telegram group link:** After the invite link block, check `egregore.json` for `telegram_group_link`. If present, append:
```
Telegram group: {telegram_group_link}
```

**GitHub invite failed** (github_invite contains an error):
```
Inviting {username} to {org_name}...

  GitHub org invitation: failed ({reason})
  Invite link:           created

You'll need to invite {username} to the GitHub org manually:
  https://github.com/orgs/{github_org}/people

Then share this link:

  {invite_url}
```

**API error** (ok=false):
```
Failed to invite {username}: {error}
```

## Step 4: Record in graph + notify (parallel)

Run these two in parallel. Use description "Recording invite in graph" and "Checking notification channel":

**Create Person node + sync to Supabase:**
```bash
bash bin/graph.sh query "MERGE (p:Person {github: \$github}) ON CREATE SET p.name = \$github, p.invited = date(), p.invitedBy = \$inviter RETURN p.name" '{"github": "USERNAME", "inviter": "INVITER"}'
```

Then sync to Supabase (non-fatal):
```bash
API_URL=$(jq -r '.api_url // empty' egregore.json)
API_KEY=$(grep '^EGREGORE_API_KEY=' .env | cut -d'=' -f2-)
curl -sf "${API_URL}/api/user/ensure" \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"github_username":"USERNAME"}' \
  --max-time 5 >/dev/null 2>&1 || true
```

Get the inviter name from `git config user.name` (derive short handle: lowercase first word).

**Check Telegram + notify:**
```bash
bash bin/graph.sh query "MATCH (p:Person) WHERE p.github = \$username OR p.name = \$username RETURN p.telegramId" '{"username": "USERNAME"}'
```

If they have a telegramId, send the invite:
```bash
bash bin/notify.sh send "USERNAME" "You've been invited to ORG_NAME on Egregore! Join here: INVITE_URL"
```

If not, skip silently — the link was already shown in Step 3.

## Step 4b: Provision Coder user (if remote hosting enabled)

Check if the org has remote hosting enabled. Run ONE bash call (fire-and-forget, must not delay response):

```bash
bash -c '
API_URL=$(jq -r ".api_url" egregore.json)
API_KEY=$(grep "^EGREGORE_API_KEY=" .env | cut -d"=" -f2-)
ORG_SLUG=$(jq -r ".slug" egregore.json)
USERNAME="$1"

# Check if hosting is enabled for this org
HOSTING=$(curl -sf "${API_URL}/api/hosting/info/${ORG_SLUG}" \
  -H "Authorization: Bearer $(grep "^GITHUB_TOKEN=" .env | cut -d"=" -f2-)" \
  --max-time 5 2>/dev/null || echo "{}")
ENABLED=$(echo "$HOSTING" | jq -r ".hosting_enabled // false")

if [ "$ENABLED" = "true" ]; then
  # Create Coder user (non-fatal, fire-and-forget)
  curl -sf -X POST "${API_URL}/api/hosting/user/${ORG_SLUG}" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"username\": \"$USERNAME\"}" \
    --max-time 10 >/dev/null 2>&1 || true
  echo "coder_user_created"
else
  echo "no_hosting"
fi
' -- "USERNAME"
```

If the output is `coder_user_created`, include in the summary:
```
  Coder workspace:     user created
```

## Step 5: Summary line

After all steps complete, show one final status:
```
  Notified via Telegram
```
or
```
  No Telegram — share the link manually
```

## Example

```
> /invite newuser

Inviting newuser to Acme Org...

  GitHub org invitation: sent
  Memory repo access:    added
  Invite link:           created

Share this link with newuser:

  https://egregore.xyz/join?invite=inv_a1b2c3d4e5f6

They'll authenticate with GitHub, accept the org invite,
and get a one-line install command.

  Notified via Telegram
```

## If already a member

```
> /invite newuser

newuser is already a member of acme-org.
They can join Egregore directly at: https://egregore.xyz/setup
```

## Rules

- **Only org admins can invite** — the API verifies this
- **GitHub invitation + Egregore invite are bundled** — one command does both
- **Invite links expire in 7 days** — if expired, just run `/invite` again
- **Memory repo access is granted automatically** — invitee gets push access
- **Never expose tokens** — all credential reads happen inside bash scripts, never as separate tool calls
- Always use `bin/graph.sh` for Neo4j — never MCP
- Always use `bin/notify.sh` for Telegram — never construct API calls directly
