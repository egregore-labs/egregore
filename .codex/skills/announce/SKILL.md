---
name: announce
description: Draft, confirm, and send an Egregore group announcement from Codex when the user invokes /announce or $announce.
---

# Egregore Announce

Native Codex Egregore skill. Use this to send concise team announcements
through the existing Egregore notification path.

## Flow

1. Draft a message from the user request and current context. Keep it under
   500 characters unless the user provided exact text.
2. If the announcement references a memory artifact, publish it first and add
   the returned URL only when publication succeeds:

```bash
bash bin/publish-artifact.sh document "$FILE_PATH" --title "$TITLE" --author "$AUTHOR" --description "$DESCRIPTION"
```

Use `handoff`, `quest`, or `document` as the artifact type when appropriate.
Never fabricate a URL.

3. Preview the exact message. Confirm with structured Codex question tooling
   when available; otherwise render:

```text
Send this announcement?
1. Send
2. Edit
Other:
```

4. If the user edits, redraft and preview again. If they approve, run:

```bash
bash bin/notify.sh group "$MESSAGE"
```

5. Emit telemetry in the background:

```bash
bash bin/telemetry.sh emit "command" '{"command":"announce"}' >/dev/null 2>&1 &
```

6. Confirm whether the group send succeeded.

## Rules

- Always preview before sending.
- Do not expose notification credentials.
- Use `bin/notify.sh`; do not call Telegram directly.
- Do not use Claude Code commands.
