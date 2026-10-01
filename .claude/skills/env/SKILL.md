---
name: env
description: Install or rotate a secret privately into a .env file or a Railway service; never asks for the value in chat. Use for missing keys, replacement tokens, password changes, or environment setup.
---

## When to invoke

Use this for private credential installation, environment setup, missing API
keys, and requests such as “cycle the Neo4j password” or “install this token on
the API service.” Inspect names and presence without displaying values.

INSTALL puts a replacement value at a destination. ROTATE changes the
credential at its authority. This command implements installation only; a
rotation request includes a separate, user-confirmed authority step.

## Workflow

Use the shared helper and [credential-entry reference](../../../docs/credential-entry.md).
These steps apply to Claude Code, Codex, Pi, and Prime. Ask only for missing
non-secret information or destination selection. Never request the value in
chat or a structured question, pass it in command arguments, read the clipboard,
or offer visible input. Values stay in the private prompt and helper process.
Replace the single-quoted placeholders below before executing a command; escape
embedded single quotes as `'\''`.

### 1. Classify: install or rotate first

For INSTALL, establish the key name and whether the user already has the
replacement. For ROTATE, name the credential authority and the exact account,
resource, and rotation page or action. Resolve that location from the user's
context or the authority's current documentation; do not infer an authority
from a variable name alone. Examples include the selected Aura instance's
password-reset action, the selected bot in BotFather, or a provider's token
management page. Tell the user to rotate there and keep the replacement private.
Stop until the user confirms that authority step is complete. Confirmation is
about completion only, never the replacement value.

### 2. Probe private input

This command takes no plan or user-supplied value and opens no window:

```bash
python3 bin/secret-entry.py probe
```

Retain `mode`, `verified`, and any `reason` or sanitized `code`. A `dialog`
result has `verified: false`: compilation checks that the scripting addition
loads, but does not prove a window can appear. A positive probe may still be
followed by a dialog failure. For an explicitly requested terminal path, use
the same command with `--input terminal`.

### 3. Locate and select destinations

When the user names a key without an exact destination, locate eligible files
and signed-in Railway targets. Here `key` comes from the request or confirmed
consumer, and `root` is the canonical owning repository inside the boundary:

```bash
python3 bin/secret-entry.py locate --key '{key}' --root '{root}'
```

If the user supplied a Railway project or service name or ID, add the matching
`--project` or `--service` argument using that non-secret information. The
helper resolves names through provider metadata, including selected targets
where the key does not exist. A project or service name that spans several
environments is not one exact destination. For an exact Railway destination
given by names, use locate to resolve its IDs without repeating the selection
question.

Show one receipt listing each destination, whether the key exists, the consumer
files, and every failed scope. State **incomplete** when `complete` is false;
an empty list with failures means unknown, not absent. Ask the user to select
destinations before any `prepare`. Skip the selection question only if the user
already named one exact destination. Locate never authorizes a write. Treat
matching key names in different projects or environments as different
credentials until the user explicitly identifies them as the same credential.
If complete discovery finds no suitable file, ask for an exact new dotenv path
inside the owning repository; `prepare` still checks its eligibility before input.

### 4. Prepare each selected destination

Create one plan per selected destination. For dotenv, `root` and `file` come
from the selected candidate or exact user destination; `key` is the confirmed
variable name:

```bash
python3 bin/secret-entry.py prepare --provider dotenv --root '{root}' --file '{file}' --key '{key}'
```

For Railway, `root` is the owning repository, `key` is the confirmed variable,
and all three IDs come from verified provider metadata for the selected target:

```bash
python3 bin/secret-entry.py prepare --provider railway --root '{root}' --key '{key}' --project '{project_id}' --environment '{environment_id}' --service '{service_id}'
```

Show each non-secret plan receipt: destination, key, and **replace** or
**create** from `existing_key`. Preserve the returned plan path under
`.egregore/secret-entry/`. A symlink is not an eligible dotenv destination:
resolve its actual file and owning repository within the boundary, then select
that destination explicitly. Never replace a shared symlink.

### 5. Apply through an available private path

When the probe reports `dialog`, use the plan path returned by `prepare` as `plan`:

```bash
python3 bin/secret-entry.py apply --plan '{plan}' --input dialog
```

Keep the command alive while the user enters the value in the private dialog.
When the probe reports `terminal` and this execution context really has the
interactive terminal, use the returned plan path as `plan`:

```bash
python3 bin/secret-entry.py apply --plan '{plan}' --input terminal
```

**Harness-specific escalation:** if the sandbox cannot display the dialog and
the active harness supports escalation, request to run only that exact `apply`
command outside the sandbox through its own approval flow. Follow the harness's
permissions; availability is a session capability, not a property of its name.

If private input is unavailable and escalation is unavailable or declined,
give the user the exact terminal command above with their returned plan path.
It must run **on the host that holds the plan, the workspace, and the provider
login**, from that workspace. Report this step as **PENDING** until its receipt
can be read. A local terminal on a different machine cannot apply a remote
host's plan. Never ask the user to send terminal input or credential-bearing
output back in chat; read only the helper's non-secret receipt.

If that host has no user terminal either, end with `not_written` and the known
reason. Name the remaining private paths: run the command on a host with the
workspace and provider login after preparing a plan there, or set the value in
the provider's own console. Do not leave an impossible terminal step as PENDING.

Fallback to another input path is allowed only for `hidden_input_unavailable`
before any write, including a positive probe followed by a dialog that fails
to open. Its receipt has `status: not_written` with `reason` equal to `sandbox`,
`no_display`, `not_darwin`, `no_tty`, or `unknown`; preserve any sanitized `code`.
`cancelled` stops the command. `write_attempted_unverified` keeps its
uncertain status and must never trigger an automatic retry or input fallback.

### 6. Report the receipt exactly

Read the non-secret receipt and name the key and destination with its outcome:
`saved`, `not_written` with its reason, or `write_attempted_unverified`.
Use **PENDING** for a handed-off terminal step without a completed receipt;
PENDING is a workflow state, not a saved receipt. A dialog appearing, a plan
being created, or a command being handed to the user is never evidence of
`saved`. For uncertain writes, report that a write may have happened and stop
before any new write until the destination has been checked privately.

### 7. Report rotation and installation separately

For rotation requests, finish with both halves: “rotated at the authority:
user-confirmed; installed at N of M destinations,” followed by any pending,
not-written, or unverified destinations. If authority confirmation has not
arrived, report that step as pending and stop. A successful destination write
is never a rotation. Installation does not deploy code, activate an integration,
or send a test message; continue other steps only within the requested scope.
