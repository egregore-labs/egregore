Invite someone to this Egregore. Handles GitHub org invitation + Egregore setup link.

Arguments: $ARGUMENTS (Required: GitHub username of the person to invite)

## What to do

1. **Validate input**: `$ARGUMENTS` must be a GitHub username
2. **Get inviter's token**: Read `GITHUB_TOKEN` from `.env`
3. **Get org info**: Read `github_org` from `egregore.json`
4. **Call the invite API**
5. **Share the invite link** (via Telegram if possible, otherwise show it)

## Step 1: Validate

If `$ARGUMENTS` is empty:
```
Usage: /invite <github-username>

Example: /invite rencburra
```
Stop here.

## Step 2: Get credentials

```bash
TOKEN=$(grep '^GITHUB_TOKEN=' .env | cut -d'=' -f2-)
GITHUB_ORG=$(jq -r '.github_org' egregore.json)
API_URL=$(jq -r '.api_url' egregore.json)
ORG_NAME=$(jq -r '.org_name' egregore.json)
USERNAME="$ARGUMENTS"
```

If TOKEN is empty: **"No GitHub token found. Run `bash bin/github-auth.sh` first."** Stop.

## Step 3: Call invite API

```bash
curl -s -X POST "$API_URL/api/org/invite" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN" \
  -d "{\"github_org\": \"$GITHUB_ORG\", \"github_username\": \"$USERNAME\"}"
```

## Step 4: Handle response

**Success** (has `invite_url`):
```
Inviting {username} to {org_name}...

  GitHub org invitation: sent
  Memory repo access:    added
  Invite link:           created

Share this link with {username}:

  {invite_url}

They'll authenticate with GitHub, accept the org invite, and get a one-line install command.
```

**GitHub invite failed** (e.g., not an admin):
```
Inviting {username} to {org_name}...

  GitHub org invitation: {reason}
  Invite link:           created

You'll need to invite {username} to the GitHub org manually:
  https://github.com/orgs/{github_org}/people

Then share this link:

  {invite_url}
```

## Step 5: Notify (optional)

Check if the invitee has a Telegram ID in Neo4j:
```bash
bash bin/graph.sh query "MATCH (p:Person {name: \$name}) RETURN p.telegramId" '{"name": "USERNAME"}'
```

If they have a telegramId, send the invite link via Telegram:
```bash
bash bin/notify.sh send "USERNAME" "You've been invited to $ORG_NAME on Egregore! Join here: $INVITE_URL"
```

If not, just show the link for the inviter to share manually.

## Step 6: Create Person node in Neo4j

```bash
bash bin/graph.sh query "MERGE (p:Person {name: \$name}) ON CREATE SET p.invited = date(), p.invitedBy = \$inviter RETURN p.name" '{"name": "USERNAME", "inviter": "INVITER"}'
```

## Example

```
> /invite rencburra

Inviting rencburra to Curve Labs...

  GitHub org invitation: sent
  Memory repo access:    added
  Invite link:           created

Share this link with rencburra:

  https://egregore-core.netlify.app/join?invite=inv_a1b2c3d4e5f6

They'll authenticate with GitHub, accept the org invite,
and get a one-line install command.
```

## If already a member

```
> /invite rencburra

rencburra is already a member of Curve-Labs.
They can join Egregore directly at: https://egregore-core.netlify.app/setup
```

## Rules

- **Only org admins can invite** — the API verifies this
- **GitHub invitation + Egregore invite are bundled** — one command does both
- **Invite links expire in 7 days** — if expired, just run `/invite` again
- **Memory repo access is granted automatically** — invitee gets push access
- Always use `bin/graph.sh` for Neo4j — never MCP
- Always use `bin/notify.sh` for Telegram — never construct API calls directly
