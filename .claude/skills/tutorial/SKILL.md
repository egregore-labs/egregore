---
name: tutorial
description: "Interactive walkthrough of Egregore's Local core loop — activity, reflection, and a quest — using adaptive questions and real Runtime-backed artifacts. Use for 'tutorial', 'walk me through Egregore', or 'show me how this works'; use onboarding for first-time identity or org setup."
---

# Tutorial

Guide the user through one real Local loop: orient → capture → connect → close.
Keep the experience conversational; never lecture or expose raw command output.

## When to invoke

Interactive walkthrough of Egregore's Local core loop — activity, reflection, and a quest — using adaptive questions and real Runtime-backed artifacts. Use for 'tutorial', 'walk me through Egregore', or 'show me how this works'; use onboarding for first-time identity or org setup.

## Resume state

Read only tutorial and onboarding hints from `.egregore-state.json`. Reuse
`onboarding.harvest_rounds` to avoid repeated role/focus questions. `reset`
clears tutorial-only keys. Resume from the stored checkpoint; if already
complete, offer reset or normal work. Tutorial state is local product state,
not organizational memory or telemetry.

Reuse attached `EGREGORE_ORG_CONTEXT_V1`; do not repeat its retrieval or source
opens. The tutorial never calls QMD, graph, Git, control-plane storage,
publishing, sharing, notifications, or telemetry directly.

## 1. Orient

Ask only missing tailoring questions: work domain, then one domain-specific
stage question. Fetch exactly one authorized activity snapshot and render it
using the real activity surface:

```bash
bash bin/activity-data.sh 2>/dev/null \
  | bash bin/node-run.sh bin/codex-skill-render.mjs activity-card -
```

Explain briefly that activity is the starting point for sessions, obligations,
questions, and quests. Use “organizational memory,” never graph language.

## 2. Capture

Use the activity snapshot and onboarding focus to ask two adaptive questions:

1. What throughline or hard problem matters now?
2. What changed, remains blocked, or became clear?

The answer must concern the user's real work, not Egregore. Infer `decision`,
`finding`, or `pattern` (default `finding`), preview it, and explicitly confirm
the practice write. Render one complete body to a temporary file under `tmp/`, then call
exactly once; `{artifact-file}` is that file, and `{artifact-type}`, `{title}`, and
`{topic}` come from the confirmed insight:

```bash
bash bin/knowledge.sh create \
  --type '{artifact-type}' --title '{title}' \
  --input '{artifact-file}' \
  --topic tutorial-generated --topic '{topic}' \
  --workstream "tutorial"
```

Keep the receipt's stable artifact id and canonical path for the next step.

## 3. Connect

Ask for the bigger open question behind the captured insight, what would make
it feel answered, and up to three initial threads. If the user wants a real
quest, make one domain call:

```bash
bash bin/quest.sh new \
  --title "{title}" --question "{open question}" \
  --project tutorial-generated \
  --thread "{thread}" [--thread "{thread}"]...
```

If they decline, explain that the reflection remains useful on its own. Do not
infer participants or send notifications. Adding people or notifying them is a
later action requiring separate permission and explicit consent.

## 4. Close

Show what the Runtime accepted: the activity snapshot, canonical insight, and
optional quest. Ask one short feedback question. Keep feedback local in
tutorial state unless the user separately asks to capture it as organizational
knowledge. Mark the tutorial complete and give one tailored next move:

- group founder: hand off after the next real session
- group joiner: check activity after time away
- personal: reflect whenever something clicks
- agent-focused: add durable project context before delegating

End with exactly: **What are you working on?**

## Invariants

- Add `tutorial-generated` to every tutorial knowledge artifact; mark tutorial
  quests with the same project marker until quest topics are supported.
- One Runtime command per accepted artifact or quest; never repeat save/index.
- Canonical Markdown/Git wins over every derived projection.
- No implicit publication, external sharing, notification, or feedback upload.
