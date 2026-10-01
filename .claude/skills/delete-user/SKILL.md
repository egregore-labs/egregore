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

**CRITICAL: Suppress raw output.** Save the API response to a file, read it with `jq`, and only show formatted status lines to the user.

**CRITICAL: Never expose credentials in tool output.** All credential handling happens inside `bin/api-call.sh`; never read a token into the conversation or substitute it into a command.

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

For confirmation, ask with a structured question when available and permitted in this session; otherwise ask in plain text:

```
question: "How should {username} be removed from this org?"
header: "Remove mode"
options:
  - label: "Revoke access"
    description: "Remove repository and hosted membership access. Keep their sessions, artifacts, and contributions in shared memory."
  - label: "Full delete"
    description: "Revoke access AND erase their sessions, profile, todos, and telemetry. Artifacts and quests are kept but orphaned."
  - label: "Cancel"
    description: "Don't remove anyone."
```

If "Cancel", stop with: `Cancelled.`

Map "Revoke access" → `mode=revoke`, "Full delete" → `mode=full`.

## Step 3: Remove (credentials stay inside the helper)

Read the non-secret configuration first:

```bash
bash bin/config-get.sh slug
```

Use the printed value as `{slug}`. If `slug` is unset or empty, read the fallback:

```bash
bash bin/config-get.sh org_name
```

Use that printed value as `{slug}` instead. Use the supplied GitHub username as `{username}` and the confirmed mode (`revoke` or `full`) as `{mode}`. Quote substituted values in single quotes, writing any embedded single quote as `'\''`.

Run with description "Removing {username} from org":

```bash
bash bin/api-call.sh DELETE '/api/org/{slug}/members/{username}?mode={mode}' --auth github --out tmp/delete-user-response.json
```

The helper reads the configured API URL and GitHub token internally, falling back to `gh auth token` if the token is absent from `.env`. If it fails, report its error and stop; the helper leaves no response file after a failure.

Read the response:

```bash
jq '.' tmp/delete-user-response.json
```

Treat `.status == "removed"` as success. Use `.mode`, `.username`, and `.actions` for the result, `.errors` for partial failures, and `.detail` for an API error.

## Step 4: Display result

Interpret the response read in Step 3. **Never show raw JSON to the user.**

**Success** (status=removed, mode=revoke):
```
Removing {username} from {org_name}...

  GitHub access:   revoked
  Membership:      deactivated
  Member record:   marked as removed

{username} can no longer access this Egregore.
Their contributions are preserved in shared memory.
```

**Success** (status=removed, mode=full):
```
Removing {username} from {org_name}...

  GitHub access:   revoked
  Membership:      deactivated
  Sessions:        deleted
  Contributions:   orphaned (artifacts kept)
  Member profile:  deleted
  Telemetry:       deleted

{username} has been fully removed from this Egregore.
```

If `errors` array is non-empty, append:
```
Partial failures (non-fatal):
  - {error1}
  - {error2}
```

**API error** (status is not removed):
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
