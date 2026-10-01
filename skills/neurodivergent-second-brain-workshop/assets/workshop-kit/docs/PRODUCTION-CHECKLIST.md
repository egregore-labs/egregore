# Production checklist

## One week before

- [ ] Confirm four participants, two sessions of 90 minutes, venue, written directions, and quiet zone.
- [ ] Send the agenda, setup expectations, access needs form, privacy boundary, and “no disclosure required” statement.
- [ ] Confirm participant laptops and prepare resettable loaners.
- [ ] Select two Responses-compatible providers and one model mapping.
- [ ] Set a total inference budget and per-person request/input/output/concurrency quotas.
- [ ] Put the gateway behind HTTPS; confirm participant laptops can reach `/healthz`.
- [ ] Run `npm test` and record the passing output.
- [ ] Run `npm run rehearse` and record the passing gateway and participant-lifecycle checks.
- [ ] Rehearse provisioning and the participant launcher with the configured workshop model, then export and delete that fake participant.

## Day before

- [ ] Start the gateway and confirm both provider credentials without displaying them.
- [ ] Provision exactly four workspaces and inspect `npm run status`.
- [ ] Verify each token has the intended expiry and quota.
- [ ] Open each vault in Obsidian and run each `start-workshop.sh` once.
- [ ] Put participant pseudonyms—not legal names, emails, or diagnoses—on devices/workspaces.
- [ ] Prepare visible timers, printed re-entry cards, power, network fallback, and the manual exercise.
- [ ] Reset loaner browser history, terminal history, Obsidian recent vaults, and Codex state before assignment.

## During each session

- [ ] State: pass, pause, move, leave, and re-enter are always available.
- [ ] Offer spoken, written, or private responses; never require group sharing.
- [ ] Keep timing visible and announce transitions before they happen.
- [ ] Record only pseudonymous operational metrics.
- [ ] Watch inference usage and facilitator support load; do not read note contents to debug.
- [ ] If both providers fail, switch to the manual vault path.

## Participant exit

- [ ] Participant reviews their `.second-brain/configuration-profile.json`.
- [ ] Export the vault and verify the checksum manifest.
- [ ] Participant opens the export or copies it to their chosen storage.
- [ ] Generate the private person-directed emissary draft.
- [ ] Show the legible layer and mandate; publish only after **Go**.
- [ ] Give the participant the emissary page link, not `/raw` plumbing.
- [ ] Revoke the token and delete the runtime using the exact participant confirmation.
- [ ] Retain export and deletion receipts without copying private notes into facilitator records.
- [ ] Reset any loaner device after deletion.

## After the cohort

- [ ] Score the pilot rubric without linking outcomes to diagnoses.
- [ ] Reconcile provider usage with pseudonymous gateway usage.
- [ ] Record unresolved safety or privacy incidents and their resolution.
- [ ] Decide whether to repeat, revise, or stop before building self-service infrastructure.
