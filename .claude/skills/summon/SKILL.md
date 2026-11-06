---
name: summon
description: "Reuse, design, and launch Egregore spirits. Review available recipes and current host permissions, then start authorized on-demand work or design a scheduled process for an available scheduler."
---

# Summon an Egregore spirit

A spirit is an Egregore agent with a durable purpose and execution history.
Begin with what the user wants done and reuse an available recipe when it fits.
A recipe is a portable design; an admitted run and a running schedule each need
their own host receipt. Saving a design does not launch a spirit.

## When to invoke

Use for “summon,” “I want a spirit that,” reusing a spirit recipe, or designing
recurring work, monitoring, and condition-triggered work. Ordinary one-off work
needs no new recipe unless the user wants a reusable spirit. A fully specified
schedule can go straight to an available scheduler.

## 1. Restore intent and discover what exists

Use the conversation first. Do not ask again for purpose, constraints, or
authorization already supplied. Ask only for missing information that affects
the next action; use structured questions when available.

For organizational context, follow the Runtime retrieval contract: reuse
supplied evidence, otherwise use `bash bin/search.sh find` and `open`. Show the
required retrieval beat. Do not scan raw memory or query relationships merely
because the request concerns a spirit. Existing `.spirits/` designs are project
files and can be inspected normally.

Check the tools actually exposed by the current host:

- If `discover_capabilities` is available, use it to find visible recipes and
  their limitations. A catalog entry alone does not establish readiness.
- If `review_spirit_recipe` is available, review the selected recipe. Show its
  purpose, profile, **effective tools**, on-demand trigger, and admission result.
  Required capability IDs describe workflow features; they do not limit the
  profile to only those tools. A review digest grants no permissions.
- If these tools are absent, continue with design using available evidence.
  Do not invent a recipe review, host binding, installed capability, or launch.

Never infer availability from this skill's examples. Source recipes such as
`egregore/researcher` and `egregore/pm` must still pass the current host review.
Local candidates are not reviewed releases or evidence of deployment adoption.

## 2. Reuse a recipe for authorized work

With the host tools available, the sequence is:

1. `review_spirit_recipe({"recipe_id":"<selected ID>"})`.
2. Present the current scope and effective permissions. Proceed if the user's
   existing request authorizes the concrete task and admission is allowed.
3. Call `delegate_work` with `recipe_id`, the returned
   `expected_binding_digest`, and the user's `task`. Include
   `source_message_ids` only for selected messages in the authorized direct
   conversation. Do not also supply `profile` or construct a binding yourself.
4. Report the returned job or clarification and how to inspect or cancel it.

Recipe discussion or a deferred source link is not a request to start work.
Preserve the user's original constraints, source selection, and “do not
implement” limits. On a stale review, re-review; changed permissions or scope
need to be made visible before continuing. A denied admission is not a reason
to bypass the recipe through a broader profile.

The Telegram host also supports direct commands in an authorized DM:

```text
/summon <recipe ID>                 Review only
/summon <recipe ID> <task>          Request one run
```

The task form obtains a fresh host review and admits against that binding. It
uses the same queue, current actor grants, source clarification, and result
delivery as other spirit work. It creates no schedule. Group commands do not
expose recipe details or start recipe work.
This is an explicit command form: every trailing task is submitted as work.
Use the review-only form to inspect a recipe; use ordinary conversation to
discuss a future task or retain a link without starting a run.

If launch tools are unavailable, report that no work was started. Say a design
was saved only after actually writing it. Do not present a source file or a
model promise as an active spirit.

## 3. Design a new reusable spirit when needed

Resolve the consequential unknowns: purpose and source scope; actions and
boundaries; outcome evidence; budget and stop conditions; delivery; and whether
the trigger is on-demand, scheduled, or event-based. Stop questioning when
these are concrete. Reuse known capabilities instead of creating a parallel
implementation because a spirit has a new name.

For a Pi Durable on-demand design, write `.spirits/{name}.json` using the
portable v2 shape. This example is illustrative, not an installed recipe:

```json
{
  "schema": "egregore.spirit-recipe/v2",
  "id": "example/researcher",
  "purpose": "Investigate selected sources and retain evidence-backed findings",
  "runtime": "pi-durable",
  "capabilities": ["egregore/contextual-delegation", "egregore/task-outcome"],
  "skills": [],
  "trigger": {"kind": "on-demand"},
  "outcome_contract": "egregore.task-outcome/v1",
  "budget_policy_ref": "local/bounded-work",
  "binding_ref": "local/researcher",
  "delivery": {"kind": "request-origin"}
}
```

Keep this schema exact. No credentials, actor grants, machine paths, current
status, or ad hoc scheduler fields belong in it. References still need a host
binding; saving this file does not install it into the host's selected catalog.
Review the design with the user. Continue authorized preparation without an
extra permission round; resolve any new consequential choice before acting.

Existing `version: 1` designs remain readable as **legacy-unknown**. They do not
prove grants, outcome acceptance, generation binding, or current activity.
Preserve them and their history; draft a migration separately rather than
silently converting or starting them.

## 4. Scheduled and condition-triggered spirits

Pi Durable's current recipe admission supports on-demand work. Scheduling is a
separate host capability. Use a native scheduler only when it is actually
available and authorized in the session. Otherwise save a design describing
the trigger, observed sources, action, budget, stop conditions, and delivery,
and explicitly report that no schedule was created.

Keep a scheduled design separate from the strict on-demand v2 JSON. For a
watcher, define an observable condition and its source; do not assume a
relationship query or introduce polling without explaining the cadence.

When creating a schedule, retain the real scheduler ID, scope, trigger,
expiry/restart behavior, and cancellation instructions returned by that host.
Verify actual registration before saying it is running. Suspend/resume through
the scheduler and report its receipt; editing a status field is insufficient.

## 5. Observe outcomes and accumulate improvements

Distinguish execution state, the spirit's outcome claim, verified acceptance,
and delivery. A completed model run is not proof the task was fulfilled.
Report evidence and unresolved requirements; ask a bounded question when a
source or decision is missing. Do not require a speculative insight every run.

Use owned work history where exposed and Runtime retrieval for canonical
records. Local history does not require Connected services. Metadata-only
records are not transcripts or proof of subjective experience. Recording,
publication, and outgoing notifications each follow their own current policy;
this workflow does not enable them implicitly. Agent-authored external
notifications follow `.claude/context/notification-consent.md`.

When a run reveals a reusable improvement, retain a candidate with source
evidence, its limitation, and a proposed evaluation. Reuse the existing
library/contribution tools if available. Keep observation, proposed change,
tested capability, release, and receiving-host adoption distinct. A success
claim alone must not update other spirits or grant new permissions.

## Managing existing spirits

Show designs from `.spirits/`, admitted work from the host's owned job surface,
and active schedules from the scheduler. Label missing or stale evidence.
Use actual job or scheduler handles for inspect/cancel/resume actions.
Do not claim a design is active from its file name or a legacy status field.

Emit the standard command telemetry when the project adapter is available:

```bash
bash bin/telemetry.sh emit "command" '{"command":"summon"}' 2>/dev/null &
```
