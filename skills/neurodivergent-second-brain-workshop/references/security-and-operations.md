# Security and operations

## Trust boundary

The facilitator controls provider accounts, the gateway host, registry, audit log, exports, and deletion receipts. A participant controls their temporary workspace and can read their workshop token. Treat that token as an intentionally visible limited capability, not as a hidden provider secret.

Provider secrets must exist only in the gateway process environment. Never write them to `egregore.json`, Codex project config, participant directories, Obsidian notes, emissaries, logs, or committed files.

## Gateway invariants

- Accept only `POST /v1/responses` plus the non-sensitive `/healthz` check.
- Hash high-entropy workshop tokens at rest.
- Check status, expiry, request quota, estimated input quota, reserved output quota, and concurrency before forwarding.
- Override the model, output ceiling, `store`, `background`, metadata, deprecated `user`, cache identity, and safety identity at the gateway boundary.
- Attribute use through a salted pseudonymous identifier; do not send legal names, emails, or diagnoses as provider identifiers.
- Log request id, participant pseudonym, provider, status, latency, attempts, and token counts. Never log authorization headers, prompts, outputs, or provider error bodies.
- Retry another provider only before response bytes reach the participant. Never replay an interrupted stream automatically.
- Run one gateway process per JSON registry. The bundled registry lock coordinates provisioning, accounting, and revocation across separate CLI processes; it is not a clustered database.

## Network and provider requirements

Use HTTPS whenever tokens cross machines. A raw HTTP gateway may bind behind a TLS reverse proxy; loopback HTTP is acceptable only for same-machine rehearsal.

Every provider must implement the OpenAI Responses API fields used by the selected model and SSE when `stream: true`. Use provider-specific model overrides when names differ. Rehearse `429`, `5xx`, timeout, and both-provider failure paths.

If both providers fail, continue through the manual Obsidian workflow. Never distribute a provider key as an outage workaround.

## Data lifecycle

Participant notes remain local to the participant workspace and verified vault export. The relay receives only a private configuration-profile emissary after preview and consent.

At exit:

1. Validate required vault files and reject symbolic links.
2. Copy the vault and compare SHA-256 manifests.
3. Let the participant open or copy the export.
4. Revoke the token.
5. Write a deletion-started receipt outside the participant runtime.
6. Delete only the exact `participant-NN` directory under the configured runtime root.
7. Finalize the deletion receipt and reset loaner state.

Retain operational receipts without duplicating private notes into facilitator records.

## Accessibility and consent

The included materials are starting points, not clinical, legal, or accessibility certification. Invite participants to adapt language, pacing, labels, modalities, breaks, and re-entry cues. Consent is ongoing and can be withdrawn. The agent must not infer or request diagnosis and must ask before accessing personal notes.
