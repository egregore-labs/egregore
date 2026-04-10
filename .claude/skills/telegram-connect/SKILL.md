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

Check for existing `telegram_chat_id` — it lives in `.egregore-state.json` (preferred) or `egregore.json` (legacy):

```bash
jq -r '.telegram_chat_id // empty' .egregore-state.json 2>/dev/null || jq -r '.telegram_chat_id // empty' egregore.json 2>/dev/null
```

If already set, show:
```
Telegram is already connected.

  Chat ID: {chat_id}
  Group link: {group_link}

To update it, remove `telegram_chat_id` from .egregore-state.json and run `/telegram-connect` again.
```
And stop.

## Step 2: Guide setup

Read the org slug from `egregore.json`:
```bash
jq -r '.slug // empty' egregore.json 2>/dev/null
```

If slug is set, generate the deep link with it: `https://t.me/Egregore_clbot?startgroup=org_{slug}`
If slug is empty, fall back to: `https://t.me/Egregore_clbot?startgroup=true`

Show:
```
To set up Telegram notifications:

  1. Create a Telegram group for your team
  2. Add the bot: {deep_link}
  3. The bot will respond with your Chat ID — copy it
  4. Get the invite link: group name → Edit → Invite Links → Copy
  5. Paste both below
```

Then use AskUserQuestion to ask for the chat ID:
```
Chat ID (from the bot's message in your group):
```

Validate: must be a negative number (e.g., `-1001234567890`) — reject anything else with "That doesn't look like a Telegram chat ID. It should be a negative number like -1001234567890."

Then use AskUserQuestion to ask for the group invite link:
```
Group invite link:
```

Validate: must start with `https://t.me/` — reject anything else with "That doesn't look like a Telegram invite link."

## Step 3: Store and test

Read `.egregore-state.json`, add `telegram_chat_id` and `telegram_group_link` fields, write it back.

**Important:** Write to `.egregore-state.json`, NOT `egregore.json`. The state file is symlinked across worktrees so the config propagates everywhere. No branch, commit, or push is needed — it's an untracked local file.

Test the connection:
```bash
bash bin/notify.sh group "Telegram connected! 🎉" 2>/dev/null
```

If successful, show:
```
Telegram connected — test message sent to your group.
```

If failed, show the error and suggest checking the chat ID.

## Step 4: Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"telegram-connect"}' 2>/dev/null &
```

## Rules

- Never expose credentials in tool output
- The bot username is `@Egregore_clbot` — NOT `@egregore_bot`
- Only store the group invite link and chat ID, not bot tokens (those live on the API server)
- Store in `.egregore-state.json` (symlinked, untracked) — NOT `egregore.json` (tracked, branch-specific)
- No commit/push needed — state file is local and shared via symlinks
