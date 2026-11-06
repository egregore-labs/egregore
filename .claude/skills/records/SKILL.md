---
name: records
description: View or change your session records, hold the current session, redact a past record, record past sessions from this machine, and close or file the open items records carry.
---

# /records — your session records

Session records put asked, decided, left open, touched and cost in shared
memory. Organization policy sets the default; each person controls their own
records. The full trail stays on this machine as a file under
`~/.egregore/trails/<folder>/<session>.md`. Your own Claude
account reads it once to write an outline. The model
call can be disabled. See [Session records](../../../docs/session-records.md)
for the exact content checks and their limits.

Claude Code, Codex CLI, Pi and Prime share the same record and hold controls.
Pi and Prime record at session end; an idle sweep also covers Codex and
continued sessions. `/records sweep` requests that sweep after the first
offer has been answered. Codex reports tokens and price coverage; Pi and
Prime use their usage ledger. Working-directory checks exclude other projects.

## When to invoke

Use for `/records`, session record settings, the greeting's past-session
offer, "off the record", a request to hold or redact a session record, or
the open items the records carry: listing them, closing one, or filing one as
an issue.

## Commands

Use `bin/records.sh`; do not edit personal state directly.

| Intent | Command |
|---|---|
| Show settings and unrecorded count | `bash bin/records.sh status` |
| Read recent decisions and open items | `bash bin/records.sh digest` |
| Read the organization's vitals, the last seven days beside the seven before | `bash bin/records.sh vitals` (`--json` for measurements and findings; `--findings` for actions and verification) |
| Record a concrete outcome and its contributing sessions | `bash bin/records.sh outcome record --file <manifest.json>` |
| Inspect accepted-outcome costs and coverage | `bash bin/records.sh outcome report --json` |
| Register or update a measured correction | `bash bin/records.sh intervention record --file <manifest.json>` |
| Inspect the five/ten-outcome checkpoints | `bash bin/records.sh intervention report --json` |
| Retry a waiting records push | `bash bin/records.sh status --push` |
| Turn your records on or off | `bash bin/records.sh on` or `off` |
| Choose the detail | `bash bin/records.sh detail outline` or `detail full` |
| Hold this session | `bash bin/records.sh hold` |
| Hold a past session of yours | `bash bin/records.sh redact <id-or-prefix>` |
| Review past sessions before recording | `bash bin/records.sh backfill --dry-run` |
| Record the listed past sessions | `bash bin/records.sh backfill --yes` |
| Sweep idle sessions and refresh continued ones | `bash bin/records.sh sweep` |
| Limit the past-session window | `bash bin/records.sh backfill --days 30 --dry-run` |
| Read one local trail | `bash bin/records.sh show <id-or-prefix>` |
| Mark the greeting offer answered | `bash bin/records.sh noticed` |
| List active open items | `bash bin/records.sh open` |
| Review retained stale items | `bash bin/records.sh open --stale` |
| Renew the relevance of a verified existing outcome | `bash bin/records.sh reactivate <item-id>` |
| Remove an item from current relevance | `bash bin/records.sh stale <item-id>` |
| Mark an open item done | `bash bin/records.sh close <item-id>` |
| Prepare an issue draft for an open item | `bash bin/records.sh file <item-id>` |
| File that draft after the person confirms it | `bash bin/records.sh file <item-id> --confirm <request-id>` |

For "off the record", run `hold` immediately and confirm the returned result
in one line. The durable hold applies across checkpoints, resumes and
backfill. An existing record becomes a stub by default; a person who has
turned off hold stubs gets a removal. Revisions already pushed remain in
memory repository history. Purging history is a separate future command.
Do not imply that hold removes earlier published revisions.

When the greeting offer is answered: yes runs `backfill --yes`; no keeps
past sessions unpublished, and only sessions from now on are recorded; an
explicit request to turn recording off runs `off`. Then run `noticed`. Only a
later `backfill --yes` publishes the earlier sessions. For "show one", first
run `backfill --dry-run`, choose one listed session, and use `show` to
display its local trail. Return
to the offer after the preview. Do not record the batch until the person says
yes. A direct request to backfill is already that instruction.

`full` includes prompt excerpts and selected assistant text. Explain that
before changing from outline when the person's intent is unclear. Outline
asks are paraphrased with mechanical checks, while deterministic sections
retain paths, command names, commit subjects and counts. The checks do not
guarantee removal of every sensitive detail or outside name. Hold or redact
is the person's remedy when something should stay out of shared memory.

If `hold` cannot identify the invoking session, report its one-line result.
Never guess a session id from a shared file or apply another person's id.
A past-session redaction is restricted to this person's records.

## Digest

`/records digest` shows what the day's sessions decided and left open,
including yesterday and today across all authors, and under Carried the open
items still carried from earlier days. Each open item starts with its id. Use
`--days N` or `--since YYYY-MM-DD` for a longer window. The digest reads
records only and writes nothing. To keep a decision or finding in
organizational knowledge, hand the line to `/reflect`.

## Open items

An open item has two independent properties: **resolution** (open until an
explicit close or filing) and **relevance** (active or stale). Its id remains
the first six hex digits of the normalized line's SHA-256, without attribution.
Its original age never resets. Similar wording is not proof of the same task.

After fourteen days without an explicit reactivation, an unresolved item is
**open but stale**. This is a read-time projection; no timer rewrites records or
appends expiry noise. Repeating the line does not renew relevance, and a
mention cannot reopen a closed or filed item. Existing expired ledger events
remain terminal for backward compatibility; no new expiry events are created.

`/records open` shows active work; `open --stale` shows the retained stale
backlog; `open --all --json` exposes both with their original and relevance
ages. The greeting shows the active count and a bounded stale count/link,
without expanding stale text into the working context or demanding an owner.

`/records stale <id>` removes an item from current relevance immediately.
`/records reactivate <id>` appends an explicit relevance renewal, retaining its
original age and record. Reactivate only after checking that the same concrete
outcome is still needed. If the goal or scope changed, close the old item with
a successor reference in the next record and start a new concrete item. Never
attach new work to a stale item merely because its broad topic sounds similar.
Filed items continue in their linked issue, preventing duplicate carry work.

`close`, `stale`, `reactivate` and successful `file` append events to
`memory/sessions/open-items.jsonl`. Events contain the item id, state, Runtime
actor id, timestamp and optional issue URL, never item text. The latest valid
event by time wins; the union merge rule preserves concurrent histories.

`file` without `--confirm` prepares a draft through the issue flow and files
nothing. Show the person the draft it prints. Only after they confirm that
exact draft, run `file <item-id> --confirm <request-id>` with the printed
request id. The event is written only when the filing succeeds, with the
issue link. Filing needs the configured GitHub issue tracker
(`issues.backend: github` in `egregore.json`); without one, `file` says so
and writes nothing.

## Outcomes and measured corrections

Use the [outcome economics workflow](../../../docs/plans/outcome-economics-workflow.md)
when implementing findings from the scorecard. The agent prepares manifests and
records the work; no additional roles or approval queues are needed. Register a
concrete outcome as open, link native aggregate session scopes, and append its
verified disposition when the agreed acceptance condition is met. Do not infer
acceptance from a merge, topic similarity or an open item. Do not invent a human
verification. Keep attribution incomplete until driver, worker, retry and review
costs are accounted for.

The explicit scorecard joins canonical final costs. Missing prices or records,
held work and overlapping parent/worker scopes cannot become measured zero or
complete unit cost. Repeated finding tags rank associated spend, not recoverable
waste. Register an intervention's baseline before post-change work; inspect five
comparable terminal outcomes, decide at ten, and revisit quality regressions
immediately. These checkpoints never require delaying an already justified fix.

## Telemetry

```bash
bash bin/telemetry.sh emit "command" '{"command":"records"}' 2>/dev/null &
```
