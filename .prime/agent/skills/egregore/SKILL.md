---
name: egregore
description: Egregore mechanics as kernel functions — search shared memory, read team activity, create handoffs, save work, branch, and prepare notification plans without re-deriving bin/ CLI usage. Import and call directly; every function wraps the same runtime-neutral bin/ scripts the other harnesses use.
---

# egregore — kernel bridge to Egregore mechanics

Python-backed skill. The module is installed into the kernel venv; call the
functions directly instead of grepping `bin/` scripts to reconstruct CLI usage:

```python
import egregore

egregore.capabilities_find("research")     # separate installation and host evidence
egregore.system_explain()                  # visible owners and evidence gaps
egregore.search("pricing decision")          # ranked shared-memory recall
egregore.activity()                          # team activity JSON
egregore.handoff(to="renc", topic="...", body="...")
egregore.save(message="fix(runtime): correct behavior", topic="topic", draft=True)
egregore.branch("new topic")                 # task branch + worktree
egregore.notify_plan(recipient="renc", message="...")  # proposal ONLY
```

Use `draft=True` while
implementation or review continues. After local QA and review pass, use
`draft=False` to push the final changes and mark the PR ready for CI; it
first runs the checks CI would select on this machine, and if one fails the
work is pushed, the PR stays a draft and the call raises. Omit
`draft` for normal non-coding auto-merge; omitting it on an existing PR
preserves that PR's readiness. These choices follow the work's state and do
not require a separate permission checkpoint.

Ground rules:

- Every function shells out to the corresponding `bin/` script and returns
  text output. Business rules stay in the shared scripts.
- Normal bridge functions use a generous internal timeout and raise
  `RuntimeError` with the script's stderr on failure — report the single
  relevant line, do not debug the plumbing mid-workflow.
- Discovery functions use the fixed JSON request path through
  `bin/spirit-discovery-prime.sh --json`, with a 15-second wrapper timeout.
  Failures return bounded `egregore.capability-query-error/v1` JSON text
  without stderr diagnostics.
- `notify_plan` only CREATES a notification plan. Approval and dispatch remain
  subject to the explicit human Send / Edit / Cancel checkpoint: show the plan,
  get the user's approval, then run `bin/notify.sh approve` / `dispatch` with
  the plan's one-use approval token. Never call approve or dispatch without a
  fresh human yes in this conversation.
- `help()` on the module or any function shows signatures and semantics.
