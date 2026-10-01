---
name: neurodivergent-second-brain-workshop
description: Scaffold, configure, rehearse, and operate an accessible two-session Egregore and Obsidian second-brain workshop with facilitator-funded shared inference. Use when participants lack API credits or paid AI subscriptions; when Codex needs to create isolated quota-bound workshop workspaces; when designing neurodivergent-accessible capture, resurfacing, and re-entry practices; or when managing the verified export, private configuration emissary, credential revocation, and teardown lifecycle.
---

# Neurodivergent Second-Brain Workshop

Build a manual-first Obsidian system that Egregore can configure and assist without becoming required infrastructure. Keep provider secrets on a facilitator-controlled gateway and give participants temporary limited capabilities.

## Scaffold

1. Choose a destination inside the active Egregore checkout. Default to `workshops/neurodivergent-second-brain` when the user gives no path.
2. Refuse to overwrite a non-empty destination.
3. Run:

```bash
node "<skill-directory>/scripts/scaffold.mjs" \
  --output <destination>
```

Resolve `<skill-directory>` from this loaded `SKILL.md`; do not assume the skill is installed inside the active repository.

The scaffold creates an ignored live config and blank `.env`, preserves the example files, and sets `.env` permissions to owner-only where supported.

## Configure and verify

Read [security-and-operations.md](references/security-and-operations.md) before configuring providers or launching participant workspaces.

1. Edit `<destination>/config/workshop.json`; keep secrets out of it.
2. Put provider keys only in `<destination>/.env` on the facilitator-controlled gateway host.
3. Require an HTTPS `gateway.publicUrl` for participant laptops. Permit loopback HTTP only for same-machine rehearsal.
4. Select Responses-compatible providers and model mappings. Keep two providers when failover is part of the workshop promise.
5. Run `npm test` from the destination. Fix every failure before provisioning.
6. Run `npm run rehearse` to exercise a fake participant through streaming inference, failover, export, revocation, and deletion before creating the cohort.

Do not launch real inference or publish an emissary until the user has supplied or confirmed live provider, budget, host, and recipient choices.

## Provision and facilitate

Use the bundled CLI from the generated destination:

```bash
npm run gateway -- --config ./config/workshop.json
npm run provision -- --config ./config/workshop.json --count 4
npm run status -- --config ./config/workshop.json
```

Run the gateway and administrative commands from separate terminals. Keep one gateway process per registry file.

Treat these as hard facilitation constraints:

- Give the agenda and setup information in advance.
- Offer spoken, written, private, and pass options.
- Never require diagnosis disclosure or group sharing.
- Allow pause, movement, leaving, and re-entry without explanation.
- Keep timing and transitions visible; provide a quiet zone and written re-entry cues.
- Preserve the no-AI pathway through `Home`, `Inbox`, `Now`, and `Re-entry`.
- Ask before reading or modifying personal notes.

Use the generated `docs/PRODUCTION-CHECKLIST.md`, `SESSION-1.md`, `SESSION-2.md`, `CONSENT-AND-ACCESS.md`, and `PILOT-RUBRIC.md` as editable facilitator assets. Adapt their language with participants rather than treating them as medical or legal advice.

## Export, emissary, and teardown

1. Export while the participant is present:

```bash
npm run export -- participant-01 \
  --recipient <email-or-handle> \
  --config ./config/workshop.json
```

2. Verify that the vault export opens and that its checksum manifest matches.
3. Inspect `emissary-answers.json`. It may contain configuration preferences, but never note contents, diagnoses, provider keys, or workshop tokens.
4. Use the Egregore emissary workflow to show the two-layer preview. Publish only after the participant explicitly chooses **Go**; give them the page link, not `/raw` plumbing.
5. Revoke and delete only after the participant confirms the export:

```bash
npm run destroy -- participant-01 \
  --confirm participant-01 \
  --config ./config/workshop.json
```

Never bypass the export receipt for convenience. Use `--allow-without-export` only for an explicitly authorized emergency teardown and record why.

## Completion check

Report:

- destination and generated files;
- test and rehearsal results;
- provider/model/HTTPS/budget choices still unresolved;
- participant count and token expiry;
- export and deletion receipt locations;
- whether any emissary was previewed or published.

Do not claim the workshop is production-ready when credentials, TLS, real-provider smoke testing, venue/access preparation, or recipient consent remain unresolved.
