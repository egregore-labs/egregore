# External notification consent

This protocol applies to every Telegram, Teams, or other external notification
in every harness, except the configured issue system-event feed below. It applies even when the user asked to announce, notify,
handoff, invite, or message someone, and even when the harness is running with
broad tool permissions.

## Configured issue system events

The hosted Archive feed is an approved automatic system-event channel only for
repositories explicitly listed in an org's `PR_FEED_CONFIG.issue_repos` with
`issue_feed_policy: "issue-feed/v1"`. It reuses that feed's bot and archive
channel. Allowed events: issue opened/reopened/closed, assignment changes,
severity label changes, and newly created strict v1 observation comments.
Only bounded sanitized metadata and validated links may leave; never report
bodies, comment text, transcripts or logs. HMAC authentication, repository
allowlisting and service-role transport receipts are required. Known rejected
sends can be retried; uncertain sends require operator Archive reconciliation.
Disabling the configuration revokes this exception. No other repository,
destination, authored message, DM, announcement or background agent is approved.
The remaining protocol applies unchanged to all agent-composed notifications.

## Invariant

Outside the configured issue-feed exception, never dispatch an external notification until the human has approved that one
exact delivery in a dedicated checkpoint. The checkpoint must show:

- the organization;
- the final recipient or group;
- every channel that will receive it;
- the exact final message, including links.

A workflow request, plan approval, batch approval, prior approval, broad
permission mode, or approval of a related action is not notification consent.
There is no standing "always allow" choice. One approval authorizes one attempt
to send one immutable message.

## Required flow

1. Finish the message first. Publish any artifact and insert its real URL
   before planning; never change the message after preview.
2. Resolve the exact delivery without sending:

   ```bash
   PLAN_JSON=$(bash bin/notify.sh plan send "$RECIPIENT" "$MESSAGE")
   # or
   PLAN_JSON=$(bash bin/notify.sh plan group "$MESSAGE")
   ```

3. Read `plan_id` and `digest` from `PLAN_JSON`. Show the organization,
   recipient, all `channels`/`deliveries`, and exact `message` in a dedicated
   Send / Edit / Cancel question. Use the harness's structured question UI
   when available. Otherwise show the same fields in plain text and stop for
   the user's answer.
4. Only if the user selects Send for that exact preview:

   ```bash
   APPROVAL_JSON=$(bash bin/notify.sh approve \
     "$PLAN_ID" "$DIGEST" APPROVE_EXACT_NOTIFICATION)
   APPROVAL_TOKEN=$(printf '%s' "$APPROVAL_JSON" | jq -r '.approval_token')
   bash bin/notify.sh dispatch "$PLAN_ID" "$APPROVAL_TOKEN"
   ```

5. If the user chooses Edit, cancel the old plan, edit, create a new plan, and
   preview again. If they choose Cancel, cancel it and do not send. If the plan
   expires or dispatch fails, create a new plan and obtain new consent; never
   retry from the old approval.

## Hard rules

- Never call notification API endpoints directly. Use `bin/notify.sh`.
- Never use legacy `notify.sh send` or `notify.sh group`; they only create a
  proposal and intentionally cannot dispatch.
- Never substitute a group when a direct message cannot be delivered.
- Never add a channel after preview.
- Never approve or dispatch from a detached/background process, hook, cron
  job, batch execution, or unattended agent. Those paths may create a plan and
  report that human approval is pending.
- Multiple direct recipients require a separate preview and approval for each
  exact message. A group fanout may use one approval only when every receiving
  channel is listed in the preview.
