Turn a folder of documents into a knowledge base that answers questions with its sources.

## When to invoke

`/ingest` routes here when the user brings **a body of documents to be asked questions of** —
a research archive, a contract set, a manual library, a regulatory corpus. Signals: hundreds
or thousands of files, subject folders, "make this searchable", "build a knowledge base",
"I want to ask these questions".

Not this: a handful of files to keep for reference → the plain `/ingest` path · a meeting
recording → `ingest-meeting` · a Notion or Google source → those connectors.

## Step 0 — Connected mode only

```bash
MODE=$(jq -r '.mode // "connected"' egregore.json 2>/dev/null)
```

If `mode` is `local`, stop and tell the user:

> Building a knowledge base needs Egregore Connect. The statements it produces
> are shared through the graph, so your team asks one archive rather than each
> keeping a private copy. This configuration has no graph.
>
> Plain `/ingest` still works — it stores your documents and makes them
> searchable on this machine.

Then stop. Do not run the survey, and do not offer a way to turn Connect on.

## What makes this different from plain ingest

Plain ingest stores documents and makes them searchable. This additionally works out **which
document may answer which question**, extracts the sentences that carry advice, and checks
each one against the sentence it came from.

That needs a profile: which folder means which region or client, which source outranks which,
and what a sentence carrying advice looks like in the language the documents are written in.
Nobody can write that file cold. So it is generated from a survey plus two answers.

## Step 1 — Look before asking

```bash
python3 bin/corpus_survey.py  # or: python3 -c "import sys;sys.path.append('bin');import corpus_survey as cs;print(cs.summarise(cs.survey('<path>')))"
```

Show the user what was found, verbatim — document count, folders with counts, file types,
detected language, and every note. **Do not summarise away the notes.** They carry the things
that will otherwise be discovered from an empty result: a language with no grammar, files that
cannot be read, a spreadsheet sitting beside the documents.

## Step 2 — Ask what must be kept apart

Only if the survey reports more than one group. One group means there is nothing to separate,
so ask nothing.

Use `AskUserQuestion` with the question `corpus_survey.boundary_question()` returns. It already
carries the user's own folder names and states the consequence. Keep both options in the order
given: **keeping them together is first**, because most folder structures are subjects, and
separating subjects removes real answers.

If the user separates them, ask what the groups are — clients, regions, products, versions —
and use that word as the boundary key.

## Step 3 — Ask which source wins

Use `corpus_survey.trust_question()`. The user ranks the groups, or picks "Don't know".

"Don't know" is a real answer and must stay on offer. It leaves every source equal, so a
disagreement is shown rather than resolved — which is honest, and better than a ranking nobody
chose.

## Step 4 — Write the profile

```python
import corpus_profile as cp
profile = cp.build(survey, separate_groups=<bool>, trust_order=[...], boundary_key="<word>")
cp.write(profile, "memory/knowledge/tools/<name>-ontology/publisher-profile.json")
```

Show `cp.summarise(profile)` to the user. Read out every line under `open` — those are the
things this profile will **not** do. A language with no grammar means those documents yield no
advice at all, and that must be said now rather than found later.

## Step 5 — Ingest

```bash
python3 bin/ingest.py add <path> --source <id> --boundary <key>=<value>
```

The profile is found automatically once it is under `memory/knowledge/tools/*/`. If ingest
warns that no profile was found, stop — every document will carry no region, and every later
question will be refused.

Expect roughly two hours per thousand documents. Run it in the background.

## Correcting the profile after ingest

A profile is usually wrong the first time in a way nothing reveals until questions
are asked of it — a publisher classed regional that is national, a tier too low. Fix
the profile, then apply it:

```bash
python3 bin/ingest.py reresolve --source <id> --dry-run   # what would change
python3 bin/ingest.py reresolve --source <id>             # apply it
```

**Do not re-run `add` to apply a profile change.** It skips on the content hash and
returns before it consults the profile, so it reports every document unchanged and
applies nothing — which reads as the correction not working.

`reresolve` re-runs the resolver against each document's stored path. No file is
reopened and no text is re-extracted, so a corpus that took hours to ingest is
corrected in seconds. A boundary the operator stated with `--boundary`, or one the
catalogue recorded, is reported as `protected` and never overwritten.

Report `placed` (documents that had no zone and now have one) first. Those were
invisible: a zoneless passage is dropped before ranking, so they could not be
retrieved at all, however well they matched.

## Step 6 — Check it before handing it over

```bash
python3 bin/retrieval_eval.py --fixture <questions.json> --manifest <meta>/sources/<id>/manifest.json \
  --data-root <root> --vocabulary <ontology>/*.json
```

Report **boundary violations** first — the target is zero and anything else is a failure
regardless of how good the answers look.

Report the citation hit rate as **unavailable** unless someone who knows the subject has
confirmed which documents should answer each question. A hit rate computed from unconfirmed
expectations measures agreement with whoever wrote the fixture, not with the domain.

## What to tell the user at the end

- how many documents went in, and how many were skipped and why
- that answers carry their source and trust level, and that questions outside the boundary are refused
- what the profile will not do, from its `open` list
- that nobody has checked the answers yet, if nobody has

## Rules

- **Never write the profile without showing its `open` list.** Those are the silent failures.
- **Never present an unconfirmed accuracy figure.** Withhold it and say why.
- **A survey note is not noise.** Files that could not be read, an undetected language, and a
  found spreadsheet all change what the knowledge base can do.
- The user answers questions about their own folders, by name. Never ask them to describe their
  corpus in the abstract.
