"""Shared retrieval contract attached by all harness entry points."""

RECALL_WORKFLOW_GUIDANCE = """Read-only recall stays in the current workspace; do not create a branch or worktree.
Before the first recall tool call, emit exactly once as an assistant message:
⌕ Egregore · searching your organization’s memory
Use find for discovery (query is compatibility-only). Use search.sh open for source
reads; never use raw file tools or shell reads on memory. Answer from sufficient
excerpts without opening again."""

INVESTIGATION_GUIDANCE = RECALL_WORKFLOW_GUIDANCE + "\n" + """Search organizational memory through Runtime; reuse evidence already in context.
For exact handoff status/order, use `bash bin/search.sh handoffs --mine --status open --order newest --limit 1 --open`; adjust filters to the question.
Choose a lookup and call `bash bin/search.sh find "<query>" --kind <kind>`:
filename for known path fragments; literal for exact wording; dates for dated
inventories; keyword for distinctive terms/names; semantic for paraphrases;
hybrid for combined ranking. No mode must run first; keyword is the default.
Add --recent-days N or --after/--before YYYY-MM-DD to preserve the requested period.
For current work choose --recent-days (normally 30) and state that period.
Keep the user's subject and known identity; never append the organization roster or unrelated names.
Keep the date boundary across refinements. Empty results are an evidence gap:
change the lookup rather than silently broadening it.
Other filters: --prefix memory/... and --artifact-type TYPE; -n N limits results
(default 8, maximum 20). Dates query matches literal text in paths/content;
an exact active-actor ID/name/alias includes its known identity variants. A mention
is not proof of authorship. Omit query only for an inventory of all subjects.
Find returns canonical paths and excerpts. Answer from them when sufficient.
When several sources need more context, open them together in ONE call:
`bash bin/search.sh open memory/path-a.md memory/path-b.md memory/path-c.md`.
Up to 10 sources per call; --offset N is a nonnegative character offset and
--length N is 1–16000 characters per source. A batch shares a 16,000-byte
result budget, so windows may be shorter. Follow the printed per-source
continuation only when that source needs more context; do not assume a partial
window is the complete document. Keep each source batch in its own tool result.
In Codex, set the outer functions.exec output budget with
`// @exec: {"max_output_tokens": 20000}` and exec_command.max_output_tokens to
20000 for source reads; a larger inner limit alone cannot prevent outer truncation.
Known paths may be opened directly. Use find --cursor TOKEN only when another
page is needed. Do not fetch or reread this contract when it is already attached.
Runtime retains date bounds and resolves the native session automatically.
Do not supply episode IDs, request IDs, or gap explanations in normal calls.
If native binding is unavailable, use this prompt's supplied --episode reference;
never borrow another prompt's reference. A new prompt resets retrieval limits.
Use a normal completion wait (at least 10 seconds for yield_time_ms); do not
create polling turns with one-second waits. Batch independent work in the harness.
Stop when the question is supported. Ranked matches are not exhaustive; verify
coverage before claiming something is newest or absent. Document dates need not
be event dates. Distinguish proposals/conditions from completed work and cite sources.
For evolving plans, open directly relevant later records in the requested period
before treating an earlier scope as current; a search excerpt may omit revisions.
Reconcile material differences using record/event dates; cite unresolved alternatives.
When an answer depends on not finding evidence, carry any material retrieval
failure or index-coverage warning into the final answer. Say what could not be
verified and how the gap limits that conclusion; do not turn a search gap into a fact.
Authorization, source checks, retained evidence and budgets remain inside Runtime:
8 discoveries, 20 source windows, 50 calls and 120,000 result characters per prompt.
Never bypass Runtime with raw memory filesystem or direct QMD access. Code search
and tests use ordinary tools. Emit the memory retrieval beat once per question.
On Claude append --context-packet; never reproduce internal JSON or ranking traces.
"""
