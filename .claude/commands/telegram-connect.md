Set up Telegram as a notification center for your Egregore.

Arguments: $ARGUMENTS (none expected)

## When to invoke

**Trigger phrases:**
- "set up telegram", "connect telegram", "add notifications", "telegram-connect"
- "telegram group", "add telegram", "enable telegram", "link telegram"
- "notification setup", "set up notifications"

**Disambiguation:**
- "send a message on telegram" → NOT this — use `bin/notify.sh send`
- "announce something" → NOT this — use `/announce`

## Step 1: Check current state

Read `egregore.json` and check for existing `telegram_group_link`:

```bash
jq -r '.telegram_group_link // empty' egregore.json 2>/dev/null
```

If already set, show:
```
Telegram is already connected.

  Group link: {link}

To update it, remove `telegram_group_link` from egregore.json and run `/telegram-connect` again.
```
And stop.

## Step 2: Guide setup

Show:
```
To set up Telegram notifications:

  1. Create a Telegram group for your team
  2. Add the bot: https://t.me/Egregore_clbot?startgroup=true
  3. Paste the group invite link below
```

Then use AskUserQuestion to ask for the group invite link:
```
Group invite link:
```

Validate: must start with `https://t.me/` — reject anything else with "That doesn't look like a Telegram invite link."

## Step 3: Store the link

Read `egregore.json`, add `telegram_group_link` field with the user's link, write it back.

Read mode from `egregore.json`:
```bash
MODE=$(jq -r '.mode // "connected"' egregore.json)
API_URL=$(jq -r '.api_url // empty' egregore.json)
```

### Connected mode (mode === "connected" and api_url is set):

1. Store locally in `egregore.json`
2. Commit and push to remote so joiners get it:
```bash
git add egregore.json && git commit -m "Add Telegram group link" && git push 2>/dev/null
```
3. Sync to API if available (fire-and-forget):
```bash
bash -c '
API_URL=$(jq -r ".api_url" egregore.json)
API_KEY=$(grep "^EGREGORE_API_KEY=" .env | cut -d"=" -f2-)
SLUG=$(jq -r ".slug" egregore.json)
LINK="$1"
if [ -n "$API_KEY" ] && [ -n "$API_URL" ]; then
  curl -sf -X POST "${API_URL}/api/org/telegram/group-link" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -d "{\"slug\": \"$SLUG\", \"telegram_group_link\": \"$LINK\"}" \
    --max-time 5 >/dev/null 2>&1 || true
fi
' -- "LINK_VALUE"
```
4. Confirm: "Telegram connected. Notifications are live."

### Local mode (mode === "local" or no api_url):

1. Store locally in `egregore.json`
2. Commit and push to remote so joiners get it:
```bash
git add egregore.json && git commit -m "Add Telegram group link" && git push 2>/dev/null
```
3. Show: "Telegram group linked. Your team will see the join link when invited."
4. Show: "Note: Live notifications require a connected Egregore."

## Step 4: Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"telegram-connect"}' 2>/dev/null &
```

## Rules

- Never expose credentials in tool output
- The bot username is `@Egregore_clbot` — NOT `@egregore_bot`
- Only store the group invite link, not chat IDs or bot tokens (those live on the API server)
- Always push to remote after updating egregore.json so joiners see the link
