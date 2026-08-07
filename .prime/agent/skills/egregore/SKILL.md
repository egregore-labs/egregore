---
name: egregore
description: Egregore mechanics as kernel functions — search shared memory, read team activity, create handoffs, save work, branch, and prepare notification plans without re-deriving bin/ CLI usage. Import and call directly; every function wraps the same runtime-neutral bin/ scripts the other harnesses use.
---

# egregore — kernel bridge to Egregore mechanics

Python-backed skill. The module is installed into the kernel venv; call the
functions directly instead of grepping `bin/` scripts to reconstruct CLI usage:

```python
import egregore

egregore.search("pricing decision")          # ranked shared-memory recall
egregore.activity()                          # team activity JSON
egregore.handoff(to="renc", topic="...", body="...")
egregore.save(message="Save: topic", topic="topic")
egregore.branch("new topic")                 # task branch + worktree
egregore.notify_plan(recipient="renc", message="...")  # proposal ONLY
```

Ground rules:

- Every function shells out to the corresponding `bin/` script with a generous
  internal timeout and returns its text output. `bin/` stays the single
  mechanics layer — this module contains no logic of its own.
- `notify_plan` only CREATES a notification plan. Approval and dispatch remain
  subject to the explicit human Send / Edit / Cancel checkpoint: show the plan,
  get the user's approval, then run `bin/notify.sh approve` / `dispatch` with
  the plan's one-use approval token. Never call approve or dispatch without a
  fresh human yes in this conversation.
- Functions raise `RuntimeError` with the script's stderr on failure — report
  the single relevant line, do not debug the plumbing mid-workflow.
- `help()` on the module or any function shows signatures and semantics.
