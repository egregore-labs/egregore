Answer questions addressed to you — present each, collect a free-form reply, persist, notify the sender.

## When to invoke

User says: "answer the questions", "let me answer cem's harvest", "respond to cem", "tackle the harvest", "open Q1", "walk me through them", "answer my pending", or any intent indicating they want to engage with pending questions addressed to them.

Not this:
- User wants to ask someone a new question → `/ask`.
- User wants to start a harvest of others → `/harvest`.
- Agent can answer from context — just answer directly, no skill needed.

Arguments: `$ARGUMENTS` — optional `[--from name]` to filter to one sender, `[--file path]` to jump straight to a specific question file.

## What this command is

Thin entry point for the **recipient side** of `/ask` and `/harvest`. Loads the user's pending question files, presents each one conversationally (so the user can answer in free-form prose), persists the answer back, updates the graph for harvest-flavored turns, and notifies the sender.

The model's job: parse args, find pending files, route via `AskUserQuestion` if multiple, then run the per-question loop. Answers are collected in plain conversation — `AskUserQuestion` is for *routing*, not for collecting the answer body itself.

## Step 0 — Identify

```bash
ME=$(jq -r '.github_username // empty' .egregore-state.json 2>/dev/null)
[ -z "$ME" ] && ME=$(git config user.name | awk '{print tolower($1)}')
```

The recipient match needs to handle the same identity variants the greeting uses (display name, github first-name, people-file name) — a question can say `to: oz` even when `$ME=oguzhan`. Check `to:` against `$ME`, `.display_name`, `.github_name | first word`, and `memory/people/$ME.md`'s `# Name` line, all lowercased.

## Step 1 — Detect mode

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

- **Local mode**: skip `bin/notify.sh` and `bin/graph-op.sh` calls. Markdown is canonical.
- **Connected mode**: notify sender on each answer; record harvest turns in graph for harvest-flavored questions.

## Step 2 — Find pending questions

Scan `memory/knowledge/questions/*.md` for files where `to:` matches one of the user's identity variants AND `status: pending`.

For each match, read the frontmatter and capture: `from`, `topic`, `harvest_id` (optional), `harvest_session_id` (optional), `turn` (optional), `question_intent` (optional), `context_mode` (optional). Also read the question body — everything after `## Questions`.

If `--from <name>` was passed, filter to that sender. If `--file <path>` was passed, skip the search and use only that file (verify it's `to: $ME` and `status: pending`).

If no matches: print `No pending questions for you.` Exit.

## Step 3 — Route (when multiple)

If exactly one pending question, skip this step and go straight to Step 4.

If multiple, use `AskUserQuestion`:

> How do you want to work through these {N} questions?
> - One at a time, in order received
> - Show me the list first, I'll pick the order
> - Just one specific question

If "show me the list": print a numbered list (per file: `{N}. from {from}: {topic}` — and if `harvest_id` present, suffix `· harvest`). Then `AskUserQuestion` to pick which one (`multiSelect: false`, options derived from the list, plus a "Done for now" option).

If "just one specific": use `AskUserQuestion` with the same per-file options to pick.

## Step 4 — Per question

For the chosen question:

**Present it conversationally.** Output as plain text (not via `AskUserQuestion` — answers are free-form prose, not multi-choice):

```
From: {from}
Topic: {topic}
{If harvest-flavored:}
What they're reaching for: {question_intent}
Mode: {context_mode}

Q: {question text from the body}
```

**Then end your turn.** The user types their answer as their next message. Multi-line / multi-paragraph is expected.

**When the answer arrives**, persist it:

```bash
bash bin/agent.sh answer \
  --from "$ME" \
  --question "$QUESTION_FILE_PATH" \
  --body "$USER_ANSWER"
```

This updates the file's frontmatter (`status: pending → answered`, adds `answered_by` + `answered_at`), appends an `## Answer` section with the body, and pushes memory. The `bin/agent.sh answer` command handles the markdown-side persistence completely.

**For harvest-flavored questions** (any of `harvest_session_id`, `harvest_id`, `turn`, `question_intent` present), also record the turn in the graph (connected mode only):

```bash
bash bin/graph-op.sh record-harvest-turn \
  "$harvest_session_id" "$turn" "$question_text" "$question_intent" "$user_answer" "" \
  2>/dev/null || true
```

The trailing empty string is `evaluation` — left empty for the initiator to fill on resume per `harvest/PROCESS.md` §7.

**Notify the sender** (connected mode only):

```bash
bash bin/notify.sh send "$from" "$ME answered your question about \"$topic\"" 2>/dev/null || true
```

**Then ask via `AskUserQuestion`:**

> Next, or done for now?
> - Next question (if more pending)
> - Done for now

Loop back to Step 4 if "Next." Continue to Step 5 if "Done."

## Step 5 — Confirm

Sigil: `◐ ANSWER`.

Show how many were answered and how many remain pending (rescan after the loop). Footer:
- All cleared: `✓ Answered · senders notified`
- Some remain: `◐ {N} still pending — /answer when ready`

```
┌──────────────────────────────────────────────────────────────────────┐
│  ◐ ANSWER                                          {me} · {date}    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  Answered {N} {questions} from {senders}.                            │
│  {if harvest-flavored present:}                                      │
│  Harvest turns recorded: {harvest_ids}.                              │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  ✓ Answered · senders notified                                       │
└──────────────────────────────────────────────────────────────────────┘
```

## Edge cases

| Scenario | Handling |
|---|---|
| No pending | `No pending questions for you.` Exit. |
| `bin/agent.sh answer` fails (memory push conflict) | The script retries internally; if it still fails, surface the error and stop the loop. The user's answer is in conversation context — not lost. |
| Connected mode and graph offline | `record-harvest-turn` is non-fatal (`|| true`). The markdown is canonical; the graph will catch up via WAL replay. |
| Sender is unknown to `bin/notify.sh` | Notification is non-fatal; the answer still persists. |
| User says "skip" instead of answering | Leave `status: pending`. Move to next via `AskUserQuestion`. |
| User abandons mid-loop | Answers already persisted are saved. Remaining stay `pending`. |
| Question file's `to:` matches multiple variants | First match wins; doesn't matter which variant matched. |
| `harvest_session_id` set but `turn` missing | Record-harvest-turn requires `turn`; skip the graph call (non-fatal), still persist markdown. |

## Telemetry

Fire-and-forget after Step 5:

```bash
bash bin/telemetry.sh emit "command" '{"command":"answer","count":'"$N"'}' 2>/dev/null &
```

## Rules

- **Answers are free-form prose** — collect via plain conversation, not `AskUserQuestion`.
- **`AskUserQuestion` is for routing only** — picking which question, picking next-vs-done.
- **`bin/agent.sh answer` owns the markdown side** — don't reinvent the frontmatter rewrite.
- **Harvest awareness is opt-in via frontmatter fields** — if `harvest_session_id` is set, record the turn; otherwise it's a plain `/ask` answer.
- **Local mode never references the graph or notifications** — markdown is the source of truth.
