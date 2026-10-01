---
name: review-pr
description: "Use when the user says 'review PR', 'is this PR safe to merge', or 'audit PR' — runs a CTO-level 10-point review checklist on one or more pull requests. Not creating a PR (/pr) or validating local changes (/test)."
---

Review a pull request with CTO-level scrutiny. Designed for vibe-coded PRs.

Arguments: $ARGUMENTS

## When to invoke

User says: "review PR", "check this PR", "review #123", "is this PR safe to merge", "audit PR", "review cem's PRs"
Not this: "/pr" (create a PR), "/test" (validate local changes)

## Execution rules

**CRITICAL: Suppress raw output.** Never show raw JSON, raw diffs, or unformatted gh output. All output should be structured assessment.

**For diff review, delegate to a subagent when available and permitted in this session; otherwise do it inline.** When delegation is available and permitted in this session, each PR gets its own background subagent for parallel analysis. In either case, fetch the diff, analyze it, and return a structured verdict.

**Auth:** Run every `gh` command through `bash bin/gh-run.sh`; the helper reads and trims `GITHUB_TOKEN` from the project's `.env` and passes it directly to the child environment when nonempty, otherwise preserving the existing login. Never read, print, or type the secret.

## Step 0: Determine scope

Parse `$ARGUMENTS`:
- **PR number** (e.g. `123`, `#123`) → review that single PR
- **Author** (e.g. `alice`, `bob`) → list all open PRs from that author
- **`--all`** → list all open PRs
- **Empty** → list all open PRs targeting develop

Get org/repo:
```bash
bash bin/config-get.sh github_org
```

Read the configured repository name:

```bash
bash bin/config-get.sh repo_name
```

Use each printed value as `{github_org}` or `{repo_name}` below; quote it in single quotes when you use it in a command, and write any single quote inside the value as `'\''`.

## Step 1: Fetch PR metadata

### Single PR
Use `{pr_number}` from the command's arguments or the selected PR metadata, and `{github_org}` and `{repo_name}` from configuration:
```bash
bash bin/gh-run.sh pr view '{pr_number}' --json title,author,additions,deletions,changedFiles,headRefName,body,createdAt,state --repo '{github_org}/{repo_name}'
```

### Multiple PRs (author or --all)
Use `{github_org}` and `{repo_name}` from configuration with the credential helper:
```bash
bash bin/gh-run.sh pr list --state open --json number,title,author,additions,deletions,changedFiles,headRefName,createdAt --limit 50 --repo '{github_org}/{repo_name}'
```

Filter by author login if specified.

## Step 2: For each PR, run the 10-point checklist

Delegate each PR to a subagent when available and permitted in this session, using general-purpose subagents and running reviews in parallel when available and permitted in this session; otherwise review each PR inline. Use this same review context for each PR:
1. The PR number
2. The repo
3. The requirement to invoke `gh` through `bash bin/gh-run.sh` from this checkout
4. The full checklist below

### The 10-Point CTO Checklist

Each review must fetch the diff through `bash bin/gh-run.sh pr diff '{pr_number}'`, using the selected PR number, and evaluate:

#### 1. Does it actually work?
- Check that all imports reference functions/modules that exist
- Check that Cypher syntax is valid (balanced parentheses, proper MATCH/RETURN/WHERE structure)
- Check that shell scripts use correct flags for the target platform (e.g. `base64 -d` vs `-D` on macOS)
- Check that referenced files/scripts actually exist in the codebase (e.g. `bin/graph-batch.sh`, `bin/graph-op.sh`)

For an Egregore framework PR, inspect affected skill instructions as part of
this check. Use an isolated checkout at the PR's exact head SHA with its base
ref available; do not switch the user's working branch or mix their unsaved
changes into the review. Run the existing development engine against that
checkout, using `{pr_checkout}` for its absolute path and `{pr_base_ref}` for that PR's available base ref:

```bash
bash bin/node-run.sh bin/capability-distribution.mjs skill-references \
  --root '{pr_checkout}' --changed --base '{pr_base_ref}' --branch-only --review
```

The receipt names consuming skills and their maintained instruction paths,
including native runtime resources. Open the relevant instructions and check
whether they still describe the changed behavior. This is direct-reference
coverage, not proof of transitive dependency completeness. Report a missing
base or unavailable engine as a coverage gap. The receipt is advisory and
adds no approval checkpoint; include actual findings in the existing verdict.

#### 2. Side effects on shared state
- Does it modify `.claude/settings.json`? (hook changes affect every session)
- Does it modify `CLAUDE.md`? (behavioral changes affect every session)
- Does it modify `bin/graph-op.sh`? (new operations must not break existing ones)
- Does it modify `bin/session-start.sh`? (startup changes affect every session)
- Does it modify `.env`, `egregore.json`, or auth flows?

#### 3. Overlap detection
- Are there other open PRs touching the same files?
- Is this PR a subset of a larger mega-PR? (common with vibe coding — person keeps working, creates multiple PRs from evolving branch)
- Would merging this and another PR cause conflicts?

#### 4. Destructive operations
- Graph: Any `DELETE`, `DETACH DELETE` that could remove data?
- Files: Any file deletions that could break other commands? Check if deleted files are referenced elsewhere.
- Endpoints: Any API endpoint removals that could break the website or other consumers?
- Schema: Any node/relationship type removals?

#### 5. Security regression
- Does it remove boundary rules, permission checks, or security guards?
- Does it remove `.syncignore` entries (controls what gets synced to public repo)?
- Does it weaken auth flows or token validation?
- Does it expose secrets (hardcoded tokens, API keys, credentials)?
- Does it add world-readable temp files with sensitive content?

#### 6. Schema consistency
- New node types or relationships must be declared in CLAUDE.md schema line
- Property naming must follow existing conventions (camelCase, not snake_case)
- Relationships must use UPPER_SNAKE_CASE

#### 7. Idempotency
- Graph writes must use `MERGE` not `CREATE` for edges/nodes that could be created twice
- Scripts that run on schedule or can be retried must produce the same result on re-run
- Exception: `CREATE` is OK for truly unique entities (e.g. new Session per session)

#### 8. Error handling in critical path
- Does `set -euo pipefail` at script top risk killing the script before essential output?
- Are graph queries guarded with `|| true` or fallback values?
- Do hooks always `exit 0` (observe/report hooks must never block)?

#### 9. Convention violations
- `.env` must never be sourced (`source .env` breaks on spaces) — use `grep '^KEY=' .env | cut -d'=' -f2-`
- Hardcoded absolute paths from developer's machine (e.g. `/Users/cemdagdelen/...`)
- Committed lock files, `.DS_Store`, or session-specific state
- Dead code (unreachable cases, unused imports)

#### 10. Stale base
- How far behind `develop` is the branch?
- Are there guaranteed merge conflicts with current develop?
- Has the same file been modified on develop since the PR was created?

### Agent output format

Each review must return a structured assessment:

```
PR: #NNN — Title
Author: name
Branch: branch-name
Size: +X/-Y, N files
Created: date

CHECKLIST:
1. Works:          PASS/FAIL/WARN — details
2. Side effects:   PASS/FAIL/WARN — details
3. Overlap:        PASS/FAIL/WARN — details
4. Destructive:    PASS/FAIL/WARN — details
5. Security:       PASS/FAIL/WARN — details
6. Schema:         PASS/FAIL/WARN — details
7. Idempotency:    PASS/FAIL/WARN — details
8. Error handling: PASS/FAIL/WARN — details
9. Conventions:    PASS/FAIL/WARN — details
10. Stale base:    PASS/FAIL/WARN — details

BLOCKING ISSUES:
- [list or "None"]

RISK: LOW / MEDIUM / HIGH
VERDICT: MERGE / FIX THEN MERGE / NEEDS WORK / REJECT
```

## Step 3: Compile results

Wait for all delegated or inline reviews to complete. Sort PRs into tiers:

### Tier classification

| Tier | Criteria | Action |
|------|----------|--------|
| **Tier 1: Easy merge** | 0 FAILs, 0-2 WARNs, LOW risk | Merge immediately |
| **Tier 2: Fix then merge** | 1-2 FAILs (minor), MEDIUM risk | Fix specific issues, then merge |
| **Tier 3: Needs work** | 3+ FAILs or HIGH risk | Send back with fix list |
| **Tier 4: Reject** | Security regression, broken imports, or fundamentally wrong approach | Close with explanation |

### Overlap resolution

If multiple PRs touch the same files:
1. Identify which is the "superset" (mega-PR)
2. Recommend merge order to minimize conflicts
3. Flag PRs that should be closed as superseded

## Step 4: Render summary

### Single PR review
```
┌──────────────────────────────────────────────────────────────────────┐
│  ✧ REVIEW                                         oz · Mar 11      │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  PR #241 — Fix session date sort                                     │
│  Author: cem · Branch: dev/cem/identity-fragmentation-fix            │
│  Size: +11/-11 · 4 files · Created: Mar 6                           │
│                                                                      │
│  CHECKLIST                                                           │
│    ✓ Works              Correct Cypher pattern                       │
│    ✓ Side effects       API files only                               │
│    ✓ Overlap            None                                         │
│    ✓ Destructive        No deletes                                   │
│    ✓ Security           No regression                                │
│    ✓ Schema             No changes                                   │
│    ✓ Idempotency        N/A (read queries)                           │
│    ✓ Error handling     Existing guards preserved                    │
│    ✓ Conventions        Clean                                        │
│    ⚠ Stale base         5 days old, low conflict risk                │
│                                                                      │
│  BLOCKING: None                                                      │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  Risk: LOW · Verdict: MERGE                                         │
└──────────────────────────────────────────────────────────────────────┘
```

### Multi-PR review (sorted by tier)
```
┌──────────────────────────────────────────────────────────────────────┐
│  ✧ REVIEW                                         oz · Mar 11      │
│  14 open PRs from cem · 10 unique (4 superseded)                    │
├──────────────────────────────────────────────────────────────────────┤
│                                                                      │
│  TIER 1 — EASY MERGE                                                │
│    #241  Fix session date sort              +11/-11    LOW    MERGE  │
│    #267  Handoff claiming                   +58/-2     LOW    MERGE  │
│    #185  Rewrite /meeting                   +586/-734  LOW    MERGE  │
│                                                                      │
│  TIER 2 — FIX THEN MERGE                                            │
│    #266  PR linkage                         +167/-7    MED    FIX    │
│          → Cypher bug: LIMIT before SKIP                             │
│    #265  /summon command                    +207/-0    LOW    FIX    │
│          → Missing schema declaration                                │
│                                                                      │
│  TIER 3 — NEEDS WORK                                                │
│    #244  Deep-reflect redesign              +604/-711  MED-HI WORK  │
│          → Non-idempotent edges, bash YAML parsing                   │
│    #269  Granola API upgrade                +1096/-228 MED    WORK  │
│          → Bundled unrelated changes, User-Agent spoof               │
│                                                                      │
│  TIER 4 — REJECT / CLOSE                                            │
│    #202  Extract CLAUDE.md into skills      +299/-247  HIGH   REJCT │
│          → Security rules deleted, not extracted                     │
│    #268  Coder workspace cleanup            +179/-488  HIGH   REJCT │
│          → .syncignore deleted, missing import, role overwrite       │
│                                                                      │
│  SUPERSEDED (close)                                                  │
│    #264  → by #256                                                   │
│    #265  → by #256                                                   │
│    #272  → by #256                                                   │
│                                                                      │
├──────────────────────────────────────────────────────────────────────┤
│  Merge order: #241 → #267 → #185 → #266 → #265                     │
│  3 ready · 2 fixable · 2 need work · 2 reject · 3 superseded        │
└──────────────────────────────────────────────────────────────────────┘
```

## Step 5: Offer next actions

After showing the summary, offer:
- **"Start merging Tier 1?"** — if there are easy merges
- **"Show details for #NNN?"** — deep dive on a specific PR
- **"Fix #NNN?"** — checkout the branch, apply fixes, push

## Merge execution (when user confirms)

For each PR the user confirmed for merging, use its metadata number as `{pr_number}` and the configured `{github_org}` and `{repo_name}`:
```bash
bash bin/gh-run.sh pr merge '{pr_number}' --merge --repo '{github_org}/{repo_name}'
```

After merge, update local develop:
```bash
git fetch origin develop --quiet
```

For PRs confirmed for closure as superseded, use their metadata number as `{pr_number}`, the superseding PR number as `{superseding_pr_number}`, and the configured `{github_org}` and `{repo_name}`:
```bash
bash bin/gh-run.sh pr close '{pr_number}' --comment 'Superseded by #{superseding_pr_number}' --repo '{github_org}/{repo_name}'
```

## Edge cases

| Scenario | Handling |
|----------|----------|
| PR already merged | Skip, note in output |
| PR has merge conflicts | Flag in stale-base check, cannot auto-merge |
| PR targets main (not develop) | Warning — all PRs should target develop |
| Author is maintainer (oz) | Still run full checklist, but note trusted author |
| Mega-PR detected | Identify sub-PRs, recommend close superseded |
| No open PRs | "No open PRs found." |
| Graph offline | Skip Cypher validation checks, note limitation |
