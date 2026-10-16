# Egregore × Obsidian second-brain workshop

This directory is a runnable thin pilot for four neurodivergent participants who do not have API credits or paid AI subscriptions. The facilitator pays for inference through one gateway; participants receive isolated workspaces and short-lived, quota-bound access tokens instead of provider keys.

The durable participant artifact is an ordinary Obsidian vault. Egregore helps configure and use it, but the manual workflow—capture → context → resurface → re-enter—continues after workshop access expires.

## What this builds

- An OpenAI-compatible `POST /v1/responses` gateway with streaming support.
- Central provider secrets, pseudonymous attribution, per-participant expiry, quotas, and concurrency limits.
- Ordered two-provider failover for network failures, timeouts, `429`, and `5xx` responses.
- Four isolated Egregore workspaces, each with its own `CODEX_HOME`, workshop token, and Obsidian vault.
- A private configuration-profile emissary draft that contains preferences but never note contents or credentials.
- Verified vault exports, token revocation, deletion receipts, and a facilitator runbook.

There is deliberately no self-service signup, admin dashboard, or permanent secret distribution in this pilot. `npm run status` is the facilitator’s operational view.

## Security boundary

Provider API keys live only in the gateway process environment. A participant can read their own workshop token; that is intentional. The token is a limited capability, protected by a pseudonymous identity, expiry, request/input/output quotas, and revocation. It is not a substitute for a provider key and cannot bypass the gateway’s model or output limits.

Run one gateway process per registry file. Provisioning, usage accounting, and revocation coordinate through an atomic file lock; process clustering should use separate registries or a future transactional database adapter.

Run the gateway only on a facilitator-controlled host. For multiple laptops, put it behind an HTTPS reverse proxy and set `gateway.publicUrl` to that HTTPS `/v1` URL. Never send workshop tokens over an untrusted plaintext network. The gateway logs request metadata and token counts—not prompts, outputs, access tokens, or provider keys.

Both configured providers must implement the OpenAI Responses API, including SSE when `stream: true`. Provider failover happens before a response starts; an interrupted stream is not replayed automatically because that could duplicate cost or agent actions.

## Prepare the pilot

Requirements: Node.js 20+, Codex CLI on participant machines, Obsidian, and a facilitator host reachable through HTTPS.

The skill scaffold creates `config/workshop.json` and `.env` from their committed examples. From the generated workshop directory, run:

```bash
npm test
npm run rehearse
```

Edit `config/workshop.json`:

- Choose one model supported by both providers, or set a provider-specific `model` field.
- Set the HTTPS gateway URL, token lifetime, and budget quotas.
- Set provider `baseUrl`, `apiKeyEnv`, and timeouts.
- Review the runtime, export, and receipt directories.

Put only provider secrets in the facilitator’s `.env`. Do not put them in `egregore.json`, Codex project config, participant directories, or the Obsidian vault.

```bash
chmod 600 .env
```

Start the gateway, then provision the four workspaces:

```bash
npm run gateway -- --config ./config/workshop.json
npm run provision -- --config ./config/workshop.json --count 4
npm run status -- --config ./config/workshop.json
```

Provisioning discovers the surrounding Egregore checkout, copies its framework into each isolated runtime workspace, creates a fresh local memory directory, and links the participant-owned vault as its only managed repository. It does not copy organizational memory or provider secrets. If the generated workshop is outside an Egregore checkout, pass `--egregore-source <path>` to `provision`.

On each laptop, place one participant directory, open its `vault/` in Obsidian, and run:

```bash
./start-workshop.sh
```

On Windows, run `node start-workshop.mjs` instead.

The launcher points Codex at the workshop gateway through a command-backed token helper inside an isolated `CODEX_HOME`. It does not change the participant’s normal Codex configuration.

## End-of-workshop lifecycle

Export while the participant is present. The recipient is required because the configuration packet is private and person-directed:

```bash
npm run export -- participant-01 \
  --recipient participant@example.com \
  --config ./config/workshop.json
```

The export contains:

- the complete local vault, including the participant’s notes;
- a SHA-256 manifest and export receipt;
- `emissary-answers.json`, containing only the portable configuration profile.

Review the two-layer emissary preview with the participant before publishing it. After they choose **Go**, publish the generated answers with the installed Egregore emissary workflow. Give them only the resulting `egregore.xyz/emissary/e/...` page link. Their notes remain in the local vault export and are never put into the relay.

Only after the participant has opened or copied the export, revoke and delete the workshop workspace:

```bash
npm run destroy -- participant-01 \
  --confirm participant-01 \
  --config ./config/workshop.json
```

Deletion refuses to run without an export receipt unless the facilitator explicitly supplies `--allow-without-export`. The receipt survives under `receipts/`; the participant runtime does not.

## Rehearsal and failure modes

Run `npm test` before every cohort. Then run `npm run rehearse` for the focused gateway and participant-lifecycle rehearsal. Together they exercise authentication, secret/prompt redaction, quota enforcement, provider failover, SSE usage accounting, export integrity, revocation, and deletion without contacting live providers.

If the primary provider fails, the gateway tries the secondary. If both fail, move to the manual Obsidian pathway and record the outage; never solve an outage by placing a provider key on participant machines. If the gateway is unavailable between sessions, the vault remains usable and all core exercises still work manually.

The facilitator sequence is in [PRODUCTION-CHECKLIST.md](docs/PRODUCTION-CHECKLIST.md). Session scripts and participant safeguards live beside it.

## Current pilot decisions still requiring names or numbers

- Dates, venue, and quiet-zone layout.
- Provider accounts, exact model mapping, total budget, and per-person quota.
- Gateway hostname and TLS termination.
- Participant invite list, loaner count, and loaner operating systems.
- Emissary recipient for each participant.
- Deletion timing and who witnesses each export.
- Local-language adaptation of consent and workshop materials.

These are configuration and facilitation decisions; they do not require new product features.
