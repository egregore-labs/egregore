# Git Language — how commits and PRs are worded

Ten rules for the prose inside commit messages and PR bodies. Distilled
from Simplified Technical English (ASD-STE100) and the Google developer
documentation style guide, tuned for Egregore's actual reader: a
teammate or an agent months from now, holding only the message and the
diff.

Structure (sections, subjects, lengths) lives in
`.claude/context/commit-format.md` and `.claude/context/pr-format.md`.
This file governs wording only — specifically, prose that *describes
the change*. Subjects follow the format specs' imperative grammar, and
procedure belongs where the format specs ask for it: verification
commands, manual steps, migration and rollback notes are welcome in
`## Verification` and `## Risk`, and rules 5 and 10 do not apply to
them.

1. **Active voice, named actor.** "The gate skips drafts" — not
   "drafts are skipped."
2. **Present tense for the change; past tense only for old behavior.**
   "Routes /commit to the executor tier. Previously every call went to
   the frontier model."
3. **One fact per sentence.** Two facts are two sentences. Aim for
   20 words or fewer.
4. **One name per thing.** Use the org's established term every time,
   never a synonym for variety. If the org says "handoff", then
   "session summary" is a different thing or a mistake.
   (`.claude/rules/voice-bedrock.md` lists banned vocabulary.)
5. **What and why, never how.** The diff is the how. Spend words on
   prior behavior, the problem, and why this solution.
6. **Concrete over abstract.** Name the file, the command, the error
   string, the number. "Cuts session start 24s → 4s" beats
   "significantly improves performance."
7. **Front-load.** Strongest fact first — in the subject, in each
   bullet, in each paragraph. Readers scan.
8. **Self-contained.** No session-local shorthand, no "as discussed",
   no bare "it" pointing outside the message. Every reference resolves
   from the message alone; link what you cite.
9. **No filler.** Delete intensifiers and hedges: simply, just, very,
   significantly, comprehensive, robust, might potentially.
10. **Describe the change, not your process.** "Validate input before
    parsing" — not "addressed review feedback" or "updated per
    discussion."

The test for any sentence: could an agent with no memory of this
session act on it correctly? If not, add the missing name or number.
