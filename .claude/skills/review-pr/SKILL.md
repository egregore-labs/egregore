Review a pull request with CTO-level scrutiny. Designed for vibe-coded PRs.

Arguments: $ARGUMENTS

## When to invoke

User says: "review PR", "check this PR", "review #123", "is this PR safe to merge", "audit PR", "review cem's PRs"
Not this: "/pr" (create a PR), "/test" (validate local changes)

## Execution rules

**CRITICAL: Suppress raw output.** Never show raw JSON, raw diffs, or unformatted gh output. All output should be structured assessment.

**Use Agent tool for diff review.** Each PR gets its own background agent for parallel analysis. The agent fetches the diff, analyzes it, and returns a structured verdict.

**Auth:** All `gh` commands need: `GITHUB_TOKEN=$(grep '^GITHUB_TOKEN=' .env | cut -d'=' -f2-)`

## Step 0: Determine scope

Parse `$ARGUMENTS`:
- **PR number** (e.g. `123`, `#123`) → review that single PR
- **Author** (e.g. `alice`, `bob`) → list all open PRs from that author
- **`--all`** → list all open PRs
- **Empty** → list all open PRs targeting develop

Get org/repo:
```bash
GITHUB_ORG=$(jq -r '.github_org' egregore.json)
REPO_NAME=$(jq -r '.repo_name // "egregore"' egregore.json)
```

## Step 1: Fetch PR metadata

### Single PR
```bash
GITHUB_TOKEN=$TOKEN gh pr view $PR_NUM --json title,author,additions,deletions,changedFiles,headRefName,body,createdAt,state --repo $GITHUB_ORG/$REPO_NAME
```

### Multiple PRs (author or --all)
```bash
GITHUB_TOKEN=$TOKEN gh pr list --state open --json number,title,author,additions,deletions,changedFiles,headRefName,createdAt --limit 50 --repo $GITHUB_ORG/$REPO_NAME
```

Filter by author login if specified.

## Step 2: For each PR, run the 10-point checklist

Launch an Agent (subagent_type: general-purpose) per PR for parallel review. Give each agent:
1. The PR number
2. The repo
3. The GITHUB_TOKEN retrieval command
4. The full checklist below

### The 10-Point CTO Checklist

Each agent must fetch the diff (`gh pr diff $PR_NUM`) and evaluate:

#### 1. Does it actually work?
- Check that all imports reference functions/modules that exist
- Check that Cypher syntax is valid (balanced parentheses, proper MATCH/RETURN/WHERE structure)
- Check that shell scripts use correct flags for the target platform (e.g. `base64 -d` vs `-D` on macOS)
- Check that referenced files/scripts actually exist in the codebase (e.g. `bin/graph-batch.sh`, `bin/graph-op.sh`)

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

Each agent must return a structured assessment:

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

Wait for all agents to complete. Sort PRs into tiers:

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
│    #266  PR graph nodes                     +167/-7    MED    FIX    │
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

For each PR to merge:
```bash
GITHUB_TOKEN=$TOKEN gh pr merge $PR_NUM --merge --repo $GITHUB_ORG/$REPO_NAME
```

After merge, update local develop:
```bash
git fetch origin develop --quiet
```

For PRs to close (superseded):
```bash
GITHUB_TOKEN=$TOKEN gh pr close $PR_NUM --comment "Superseded by #NNN" --repo $GITHUB_ORG/$REPO_NAME
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
