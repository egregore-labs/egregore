Set up Slack as a notification channel for your Egregore.

Arguments: $ARGUMENTS (none expected)

## When to invoke

**Trigger phrases:**
- "set up slack", "connect slack", "slack-connect"
- "add slack notifications", "slack channel", "notify us on slack"

**Disambiguation:**
- "set up telegram" → `/telegram-connect`
- "set up teams" → `/teams-connect`
- "send a message to slack" → NOT this — use the separate notification
  consent protocol in `.claude/context/notification-consent.md`

## What this does

Connects one Slack channel to Egregore notifications using an app the org
creates in its own workspace. After this, everything that plans a group
notification may also resolve Slack as a receiving channel; all resolved
channels are shown before separate dispatch approval.

The privacy contract, stated plainly to the user: **the install screen will
say only "Send messages as @Egregore." The app cannot read messages — the
manifest requests one scope, `chat:write`.** The workspace owns the app and
the token; revoking either cuts Egregore off instantly.

**Works in both modes.** Check which one first:
```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```
- **local** — the token stays in the gitignored `.env` on this machine and
  messages go straight from here to Slack. No Egregore server is in the path.
- **connected** — the token is stored on the org's row so the hosted service
  can deliver group notifications from any member's session.

Only Step 5 differs between the modes.

## Step 0: Prerequisites

1. A Slack workspace where this person can install apps. Some workspaces
   require admin approval for new apps — if theirs does, the install in
   Step 2 turns into a request the admin must approve first.
2. Nothing to install locally. No CLI, no cloud account.

## Step 1: Create the app from the manifest (human, ~1 min)

Show the manifest:
```bash
cat slack-app/manifest.yml
```
(If this instance doesn't carry `slack-app/`, fetch it from the framework repo.)

Guide them: **https://api.slack.com/apps** → **Create New App** →
**From a manifest** → pick their workspace → paste the manifest → **Create**.

## Step 2: Install and copy the bot token (human, 2 clicks + 1 paste)

**Settings → Install App → Install to Workspace** → **Allow**.

Then copy the **Bot User OAuth Token** from the same page. It starts with
`xoxb-`. Validate the prefix when they paste it:
- `xoxb-` — correct.
- `xoxp-` (user token) or `xapp-` (app-level token) — wrong item on the
  page; point them back to **Install App → Bot User OAuth Token**.

Do not store it anywhere yet.

## Step 3: Invite the bot to the channel (human, 1 line)

In the target channel: `/invite @Egregore` (or channel name → **Integrations**
→ **Add apps**). With only `chat:write`, the bot can post solely in channels
it is a member of — skipping this yields `not_in_channel` at send time.

## Step 4: Channel ID (human pastes, agent validates)

Ask for the channel ID: channel name → **About** tab → **Channel ID** at the
bottom (or the `/archives/C…` segment of a channel link).

Validate: must match `^[CG][A-Z0-9]{6,}$`. A `D…` id is a DM — not supported;
ask for a channel.

Smoke-test the token before persisting anything (no message is sent):
```bash
curl -sS https://slack.com/api/auth.test -H "Authorization: Bearer <TOKEN>"
```
`"ok":true` proves the token and names the workspace — confirm it is the one
they expect. `invalid_auth` here means a mispasted or revoked token; fix now,
not at send time.

## Step 5: Persist

**Local mode** — token to `.env` (gitignored — never commit), channel to
`.egregore-state.json` (NOT `egregore.json` — the state file is untracked and
shared across worktrees):
```bash
printf 'SLACK_BOT_TOKEN=%s\n' '<TOKEN>' >> .env
jq '.slack_channel_id = "<CHANNEL_ID>" | .slack_channel_name = "<#channel-name>"' \
  .egregore-state.json > .egregore-state.json.tmp && mv .egregore-state.json.tmp .egregore-state.json
```

**Connected mode** — store on the org so any member's session can deliver:
```bash
API_URL=$(jq -r '.api_url' egregore.json)
KEY=$(grep '^EGREGORE_API_KEY=' .env | cut -d= -f2-)
curl -sS -X POST "$API_URL/api/org/slack" \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"channel_id":"<CHANNEL_ID>","bot_token":"<TOKEN>","channel_name":"<#channel-name>"}'
```
Expect `{"status":"connected", …}`.

## Step 6: Verify with separate exact notification consent

Follow `.claude/context/notification-consent.md`. Connecting Slack is not
consent to send a test message. Prepare after configuration is final:
```bash
PLAN_JSON=$(bash bin/notify.sh plan group "Slack channel connected — this message reached you through Egregore.")
```

Show every resolved receiving channel—potentially Telegram, Teams, and
Slack—and the exact message in a dedicated Send / Edit / Cancel checkpoint.
Only dispatch after Send is selected for that preview.

## Troubleshooting quick table

| Symptom | Cause → fix |
|---|---|
| `invalid_auth` | Wrong, revoked, or other-workspace token → Step 2, re-copy from Install App |
| `not_in_channel` | Bot not invited to the channel → Step 3 |
| `channel_not_found` | Wrong channel ID, or a private channel the bot isn't in → Step 4 / invite it |
| `missing_scope` | App not created from the manifest → recreate from Step 1, reinstall |
| `account_inactive` | App was uninstalled from the workspace → reinstall |
| `ratelimited` | Transient — retried automatically |
| Install becomes an approval request | Workspace requires admin approval → the admin approves, then continue |
| Local plan omits slack from channels | Half-configured: `SLACK_BOT_TOKEN` missing from `.env` or `slack_channel_id` missing from `.egregore-state.json` |

## After

Emit telemetry (fire-and-forget):
```bash
bash bin/telemetry.sh emit "slack-connect" '{"command":"slack-connect"}' 2>/dev/null &
```
