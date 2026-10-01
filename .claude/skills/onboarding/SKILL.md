---
name: onboarding
description: "Use for /onboarding, or when a new member's onboarding is incomplete — runs the resumable VERIFY, ORIENT, INVITE, FIRST_HANDOFF welcome flow through Egregore Runtime."
---

# Egregore onboarding

Welcome a new member through the deterministic VERIFY → ORIENT → INVITE →
FIRST_HANDOFF flow. This is a conversation, not setup narration.

The Runtime adapter owns state migration, ActorContext authorization,
Local/Connected detection, profile-witness verification, and identity
reconciliation. AccountIdentity, ActorIdentity, and OrgMembership remain
separate; GitHub fields are linked-provider aliases only. Never edit state or
people files, call APIs/graph, or run Git from this skill.

## When to invoke

Use for /onboarding, or when a new member's onboarding is incomplete — runs the resumable VERIFY, ORIENT, INVITE, FIRST_HANDOFF welcome flow through Egregore Runtime.

## Start or resume

Run one bounded status command and suppress raw output:

```bash
mkdir -p tmp
```

```bash
bash bin/onboarding.sh status > tmp/onboarding-status.json
```

Read the fields for the flow below from the saved receipt:

```bash
jq -r '{phase, complete, usage_type, display_name, member_role, profile_fields_collected, installer_captured, invite_handled_by, profile_witness, ready, blockers} | to_entries[] | "\(.key): \(.value)"' tmp/onboarding-status.json
```

Use each printed field as its correspondingly named placeholder, such as
`{phase}`; quote placeholders in single quotes when you use them in a command,
and write any single quote inside a value as `'\''`.

The receipt reports the phase, completion state, user type, collected fields,
installer handoff, and canonical profile witness. It also migrates legacy
phase names safely. Do not inspect `.egregore-state.json` yourself.

- Complete with both `name` and `role` collected: say, "You're already set
  up. What are you working on?" and stop.
- Complete with role missing: ask only their role, run
  `bash bin/onboarding.sh set-role "$ROLE"`, then ask what they are working on.
- Installer-captured name: do not ask for it again.
- Invite handled by installer: do not offer another invite.
- Returning creator in `invite`: explain that their previous work should be
  captured, then enter FIRST_HANDOFF.

VERIFY is otherwise invisible. Adapter failures are rendered as one useful
fix (GitHub authentication, missing Connected authentication, or missing
memory), without exposing configuration fields or infrastructure details.

## ORIENT

Output exactly, with no preamble:

```text
✱ Insight ────────────────────────────────────────

Every session leaves traces — decisions, patterns, context.
Egregore makes those traces persistent and shared.

You do your work. When you're done, you hand off what you
learned. The next session — yours or someone else's — starts
smarter.

──────────────────────────────────────────────────
```

Then:

```text
It works best with someone on the other end.
```

Ask what they should be called, offering their returned provider display name
and a free-form alternative. Validate through the Runtime command, not in
skill-side state:

Use `{chosen-name}` for the name the user chose, writing any single quote
inside the name as `'\''`.

```bash
bash bin/onboarding.sh set-name '{chosen-name}'
```

Do not continue unless the receipt returns the chosen `display_name`.

## INVITE

The status receipt's `usage_type` is authoritative:

- `founder_group`: unless the installer handled it, ask whether to invite
  someone now or work solo. For a username, invoke the `invite` skill, then
  run `bash bin/onboarding.sh record-invite invited`. On skip, run
  `bash bin/onboarding.sh record-invite skipped`. Invite failure never blocks
  onboarding; record the answer and continue.
- `joiner_group`: never offer the invite question. Run
  `bash bin/onboarding.sh record-invite skipped` and use the joiner fast-track
  completion below.

Teach only:

```text
Two things to know when you're done:
  /save    — pushes your branch and opens a PR
  /handoff — captures what you learned for next time
```

Then ask:

```text
What are you working on?
```

When they request project changes, use the ordinary branch skill and show the
configured integration branch and actual working branch. Read-only questions
and memory lookups stay in the current workspace and use Runtime retrieval.
Do not implement branch mechanics here.

For a joiner, complete immediately after their intent answer:

```bash
bash bin/onboarding.sh complete
```

Only a receipt with `complete: true` unlocks normal work.

## FIRST_HANDOFF — creators only

Trigger when a creator clearly ends the session, runs save/wrap/handoff, or
returns in the `invite` phase. If "done" could mean a subtask, ask which.

Say:

> Before you close out — this is the part that makes the system work. A
> handoff captures what you did so the organization remembers it. Not a
> summary for a manager — a briefing for the next session, or the next person.

Run the ordinary handoff skill. After it succeeds, complete onboarding once:

```bash
bash bin/onboarding.sh complete
```

The adapter upgrades an invite stub through the identity service, verifies the
canonical profile witness, records canonical Git provenance, and only then
sets completion. If the witness is absent, keep the phase resumable and say:
"Almost done, but your profile didn't save. Try /handoff again next session."

For creators who skipped inviting, add:

```text
This is what someone would see if you invited them —
your handoff in /activity, ready to pick up. Run /invite
anytime to bring someone in.
```

On success say: **"You're in."** Add the launcher alias only if the Runtime
receipt returns one; do not mutate shell configuration from the skill.

## Rules

- Joiners never pass through FIRST_HANDOFF and are never prompted to recruit.
- Creators prove the handoff loop before completion.
- Local onboarding performs no graph, API, notification, or hosted-service
  work. Connected reconciliation remains behind the identity adapter.
- Inviting and notifying are separately authorized and separately consented.
- Never ask more than one progressive profile question in a later session.
- Raw command JSON is internal; render the user-facing flow above.
