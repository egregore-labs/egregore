---
name: delete-user
description: "Remove a member from this Egregore, revoking access across GitHub, Supabase, and Neo4j. Use for /delete-user, removing or kicking someone — not inviting (/invite) or viewing members (/dashboard)."
---

Remove a member from this Egregore. Revokes access across GitHub, Supabase, and Neo4j.

## When to invoke

User says: "remove user", "delete user", "kick", "revoke access", "remove member", "remove them", "delete member"
Not this: invite someone → `/invite` · view members → `/dashboard`

Arguments: $ARGUMENTS (Required: GitHub username of the person to remove)

## Execution rules

**CRITICAL: Suppress raw output.** Never show raw JSON to the user. All API calls MUST capture output in a variable and only show formatted status lines.

**CRITICAL: Never expose credentials in tool output.**
- Never read tokens in a separate bash call — always inline.
- All credential handling happens inside a single bash call that only outputs the formatted result.

## Step 1: Validate

If `$ARGUMENTS` is empty, show usage and stop:
```
Usage: /delete-user <github-username>

Example: /delete-user someuser

Modes (you'll be asked):
  revoke — Remove access, keep their contributions
  full   — Remove access and erase their data
```

## Step 2: Confirm

Ask the user to confirm via AskUserQuestion:

```
question: "How should {username} be removed from this org?"
header: "Remove mode"
options:
  - label: "Revoke access"
    description: "Remove GitHub + Supabase access. Keep their sessions, artifacts, and contributions in the knowledge graph."
  - label: "Full delete"
    description: "Revoke access AND erase their sessions, profile, todos, and telemetry. Artifacts and quests are kept but orphaned."
  - label: "Cancel"
    description: "Don't remove anyone."
```

If "Cancel", stop with: `Cancelled.`

Map "Revoke access" → `mode=revoke`, "Full delete" → `mode=full`.

## Step 3: Remove (single call — credentials stay hidden)

Run ONE bash call with description "Removing {username} from org":

```bash
bash -c '
USERNAME="$1"
MODE="$2"
TOKEN=$(grep "^GITHUB_TOKEN=" .env | cut -d"=" -f2-)
API_URL=$(jq -r ".api_url" egregore.json)
SLUG=$(jq -r ".slug // .org_name" egregore.json)

if [ -z "$TOKEN" ]; then
  echo "ERROR: No GitHub token found. Run: bash bin/github-auth.sh"
  exit 1
fi

RESP=$(curl -s -X DELETE "$API_URL/api/org/$SLUG/members/$USERNAME?mode=$MODE" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $TOKEN")

echo "$RESP" | jq -c "{
  ok: (if .status == \"removed\" then true else false end),
  status: .status,
  mode: .mode,
  username: .username,
  actions: .actions,
  errors: .errors,
  error: .detail
}"
' -- "$ARGUMENTS" "MODE"
```

Replace `MODE` with the actual mode value (`revoke` or `full`).

## Step 4: Display result

Parse the JSON output from Step 3. **Never show raw JSON to the user.**

**Success** (ok=true, mode=revoke):
```
Removing {username} from {org_name}...

  GitHub access:   revoked
  Membership:      deactivated
  Knowledge graph: marked as removed

{username} can no longer access this Egregore.
Their contributions are preserved in the graph.
```

**Success** (ok=true, mode=full):
```
Removing {username} from {org_name}...

  GitHub access:   revoked
  Membership:      deactivated
  Sessions:        deleted
  Contributions:   orphaned (artifacts kept)
  Person node:     deleted
  Telemetry:       deleted

{username} has been fully removed from this Egregore.
```

If `errors` array is non-empty, append:
```
Partial failures (non-fatal):
  - {error1}
  - {error2}
```

**Auth error** (ok=false):
```
Cannot remove {username}: {error}
```

Common errors:
- "Only org admins or platform admins can remove members" → you need admin role
- "Cannot remove an admin. Change their role first." → target is an admin
- "No active membership found" → user isn't a member or already removed

## Step 5: Telemetry (fire-and-forget)

```bash
bash bin/telemetry.sh emit "command" '{"command":"delete-user"}' 2>/dev/null &
```

## Rules

- **Only org admins or platform admins can remove members** — the API verifies this
- **Cannot remove admins** — they must be demoted first (future feature)
- **Cannot remove yourself**
- **GitHub removal is best-effort** — if the caller's token lacks repo admin scope, GitHub removal may fail but Supabase/Neo4j cleanup still proceeds
- **Never expose tokens** — all credential reads happen inside bash scripts
