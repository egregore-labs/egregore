#!/usr/bin/env bash
set -euo pipefail
# Repository selection belongs to gh and this checkout, never to inherited Git overrides.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# The merge gate: the one door for merging a pull request into the
# integration branch, on every harness (`bash bin/agent.sh merge <pr>`).
# It reads the checks on the PR's head commit and merges only when they
# allow it. A red check merges only under a receipt: a Markdown file that
# names every red check and why it does not matter, posted on the PR as a
# comment headed "Merge receipt" before the merge runs.
#
# Each merge, and each refusal of red checks without a receipt, appends one
# line to the gate ledger, memory/sessions/gate.jsonl, through the records
# module (bin/lib/session_record.py gate-event). The line holds the checks,
# the head's CI attempts and the jobs that passed only on a re-run, flaked
# when an earlier attempt failed them and recovered when it cancelled them;
# writing it never changes the decision or the exit code.
#
# Usage:
#   bash bin/merge-gate.sh <pr-number-or-url>                  # merge when every check is green
#   bash bin/merge-gate.sh <pr-number-or-url> --receipt FILE   # merge past the red checks it names
#   bash bin/merge-gate.sh <pr-number-or-url> --local-receipt FILE # SHA-bound local CI
#   bash bin/merge-gate.sh <pr-number-or-url> --dry-run        # print the classification and decision
#
# A number names a PR in this instance's repository (github_org/repo_name);
# a URL may name a managed repo, which merges into its own integration
# branch (bin/base-branch.sh <name>). Checks: green = success; neutral =
# skipped, neutral; pending = queued, in progress, waiting; red = failure,
# cancelled, timed out, action required and any other result. A workflow
# run on the commit that is still going holds the merge too. A receipt
# names each red check by its exact name, on a line that says why it does
# not matter. --dry-run posts and merges nothing and exits with the code
# the real run would. gh runs through bin/gh-run.sh when it is present.
#
# Exit 0 = merged (with --dry-run: would merge)
# Exit 1 = usage, gh unavailable, or a PR that cannot merge as it stands
# Exit 2 = red checks without a receipt, or a receipt that misses one
# Exit 3 = checks or workflow runs still going, or no checks reported yet
# Exit 4 = the base is not the integration branch of the PR's repository,
#          or the repository is neither this one nor a managed repo

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

die() {
  printf 'merge-gate: %s\n' "$*" >&2
  exit 1
}

pr="" receipt="" local_receipt="" local_base_sha="" dry_run=false number=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --receipt)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "--receipt needs a file"
      receipt="$2"; shift 2 ;;
    --receipt=*)
      receipt="${1#--receipt=}"
      [ -n "$receipt" ] || die "--receipt needs a file"
      shift ;;
    --local-receipt)
      [ "$#" -ge 2 ] && [ -n "$2" ] || die "--local-receipt needs a file"
      local_receipt="$2"; shift 2 ;;
    --dry-run) dry_run=true; shift ;;
    -h|--help) awk 'NR >= 6 { if ($0 == "") exit; sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *)
      [ -z "$pr" ] || die "one pull request at a time"
      pr="${1#\#}"; shift ;;
  esac
done
[ -n "$pr" ] || die "usage: bash bin/merge-gate.sh <pr-number-or-url> [--receipt FILE] [--dry-run]"
case "$pr" in
  *[!0-9]*)
    [[ "$pr" =~ ^https://[^/[:space:]]+/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+(/[^[:space:]]*)?$ ]] \
      || die "not a pull request number or URL: $pr" ;;
esac
if [ -n "$local_receipt" ]; then
  [ -z "$receipt" ] || die "choose --receipt or --local-receipt, not both"
  case "$local_receipt" in /*) ;; *) local_receipt="$PWD/$local_receipt" ;; esac
  [ -f "$local_receipt" ] && [ -r "$local_receipt" ] || die "local receipt not found: $local_receipt"
fi
if [ -n "$receipt" ]; then
  case "$receipt" in /*) ;; *) receipt="$PWD/$receipt" ;; esac
  [ -f "$receipt" ] && [ -r "$receipt" ] || die "receipt not found: $receipt"
  command -v python3 >/dev/null 2>&1 || die "python3 is required to read a receipt"
fi
command -v gh >/dev/null 2>&1 || die "the GitHub CLI is required: install gh, then run gh auth login"
command -v jq >/dev/null 2>&1 || die "jq is required"

# This instance's repository, as the skills name it; base-branch.sh and
# config-get.sh read the same egregore.json.
config="${CONFIG:-$SCRIPT_DIR/egregore.json}"
org="$(jq -r '.github_org | select(type == "string" and length > 0)' "$config" 2>/dev/null || true)"
core_repo=""
[ -z "$org" ] || core_repo="$(bash "$SCRIPT_DIR/bin/config-get.sh" repo 2>/dev/null || true)"
# The gate ledger lives in this checkout's memory, as bin/agent.sh finds it.
memory="${EGREGORE_MEMORY_DIR:-$SCRIPT_DIR/memory}"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/merge-gate.XXXXXX")" || die "could not create a scratch directory"
trap 'rm -rf "$scratch"' EXIT
cd "$SCRIPT_DIR"

# gh with the checkout's token from .env when bin/gh-run.sh is there.
gh_cli() {
  if [ -f "$SCRIPT_DIR/bin/gh-run.sh" ]; then
    bash "$SCRIPT_DIR/bin/gh-run.sh" "$@"
  else
    gh "$@"
  fi
}

lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

first_line() {
  head -n 1 "$1" 2>/dev/null | cut -c1-200
}

plural() {
  if [ "$1" -eq 1 ]; then printf '1 %s' "$2"; else printf '%s %ss' "$1" "$2"; fi
}

# refuse CODE REASON [DETAIL...]: stop without posting or merging. A real run
# writes to stderr; --dry-run prints the decision and its detail on stdout.
# The one refusal the ledger records sets ledger_kind first; its ledger line
# follows the decision on the same stream.
ledger_kind=""
refuse() {
  local code="$1" reason="$2" line
  shift 2
  if $dry_run; then
    printf 'decision: refuse, %s (exit %s)\n' "$reason" "$code"
  else
    printf 'merge-gate: refused #%s: %s\n' "$number" "$reason" >&2
  fi
  for line in "$@"; do
    [ -n "$line" ] || continue
    if $dry_run; then printf '%s\n' "$line"; else printf '%s\n' "$line" >&2; fi
  done
  if [ -n "$ledger_kind" ]; then
    if $dry_run; then ledger "$ledger_kind" false || true; else ledger "$ledger_kind" false >&2 || true; fi
  fi
  exit "$code"
}

# --- The pull request ------------------------------------------------------
# A number is looked up in this repository, never in whichever remote gh
# would pick by default.
view_args=(pr view "$pr")
case "$pr" in
  *[!0-9]*) ;;
  *) [ -z "$core_repo" ] || view_args+=(--repo "$core_repo") ;;
esac
gh_cli "${view_args[@]}" --json number,url,state,isDraft,mergeable,baseRefName,headRefName,headRefOid \
  >"$scratch/pr.json" 2>"$scratch/err" \
  || die "could not read pull request $pr through gh: $(first_line "$scratch/err")"
IFS=$'\t' read -r number url state draft mergeable pr_base head_ref sha < <(
  jq -r '[.number, .url, .state, .isDraft, (.mergeable // "UNKNOWN"), .baseRefName, .headRefName, .headRefOid]
         | map(tostring) | @tsv' "$scratch/pr.json" 2>/dev/null
) || die "gh returned an unreadable pull request for $pr"
[[ "$number" =~ ^[0-9]+$ && "$sha" =~ ^[0-9a-f]{40}$ && "$url" == https://*/*/*/pull/"$number" ]] \
  || die "gh returned an unreadable pull request for $pr"
short="${sha:0:8}"

[ "$state" = "OPEN" ] || die "#$number is not open (state $state)"

# --- The integration branch of the PR's repository --------------------------
# This repository merges into its configured base, a managed repo into its
# own. Without github_org there is nothing to tell apart: the PR is this
# repository's.
pr_repo="${url#https://}"
pr_repo="${pr_repo#*/}"
pr_repo="${pr_repo%/pull/*}"
managed=""
if [ -z "$core_repo" ] || [ "$(lower "$pr_repo")" = "$(lower "$core_repo")" ]; then
  base="$(bash "$SCRIPT_DIR/bin/base-branch.sh")" || die "could not read the integration branch from egregore.json"
else
  if [ "$(lower "${pr_repo%%/*}")" = "$(lower "$org")" ]; then
    managed="$(jq -r --arg repo "$(lower "${pr_repo#*/}")" '
      first(.repos[]? | (if type == "object" then .name else . end)
            | select(type == "string" and ascii_downcase == $repo)) // empty' "$config" 2>/dev/null || true)"
  fi
  [ -n "$managed" ] \
    || refuse 4 "it belongs to $pr_repo, which is neither this instance's repository ($core_repo) nor a managed repo, so it has no integration branch here"
  base="$(bash "$SCRIPT_DIR/bin/base-branch.sh" "$managed")" \
    || die "could not read the integration branch of the managed repo $managed from egregore.json"
fi
if [ "$pr_base" != "$base" ]; then
  if [ -n "$managed" ]; then
    refuse 4 "its base is $pr_base, not $base, the integration branch of $pr_repo; the gate merges only into $base"
  fi
  refuse 4 "its base is $pr_base, not the integration branch $base; the gate merges only into $base, and the release flow owns main"
fi
[ "$draft" = "false" ] || die "#$number is a draft; mark it ready for review first"
[ "$mergeable" != "CONFLICTING" ] || die "#$number conflicts with $base; rebase it, then run the gate again"

# --- The checks on the head commit -----------------------------------------
# gh keeps the latest run of each check, so a superseded run never counts.
# Its exit status says whether checks failed; the JSON is what is read.
gh_cli pr checks "$url" --json name,state,link >"$scratch/checks.json" 2>"$scratch/err" || true
if ! jq -e 'type == "array"' "$scratch/checks.json" >/dev/null 2>&1; then
  grep -q 'no checks reported' "$scratch/err" 2>/dev/null \
    || die "could not read the checks on $short: $(first_line "$scratch/err")"
  printf '[]\n' >"$scratch/checks.json"
fi
jq '
  def class:
    if .state == "SUCCESS" then "green"
    elif .state == "SKIPPED" or .state == "NEUTRAL" then "neutral"
    elif .state == "QUEUED" or .state == "IN_PROGRESS" or .state == "PENDING" or .state == "WAITING"
      or .state == "REQUESTED" or .state == "EXPECTED" then "pending"
    else "red" end;
  map({class: class, name: (.name // ""), state: ((.state // "unknown") | ascii_downcase), link: (.link // "")})
  | sort_by({"red": 0, "pending": 1, "neutral": 2, "green": 3}[.class])
' "$scratch/checks.json" >"$scratch/classified.json" 2>/dev/null || die "could not read the checks on $short"

count() {
  jq --arg class "$1" '[.[] | select(.class == $class)] | length' "$scratch/classified.json"
}
# One line per check: class, name, result, and the link of a red or pending one.
lines() {
  jq -r --arg class "${1:-}" '.[] | select($class == "" or .class == $class)
    | "  " + ((.class + "        ")[:8]) + " " + .name + " (" + .state + ")"
      + (if (.class == "red" or .class == "pending") and .link != "" then "  " + .link else "" end)' \
    "$scratch/classified.json"
}
# The same lines for a refusal, unless --dry-run has already listed every check.
detail() {
  $dry_run || lines "$1"
}
green="$(count green)"; neutral="$(count neutral)"; pending="$(count pending)"; red="$(count red)"
total=$((green + neutral + pending + red))

if $dry_run; then
  printf 'merge-gate: #%s %s into %s at %s\n' "$number" "$head_ref" "$base" "$short"
  [ "$total" -eq 0 ] || lines
  printf 'checks: %s green, %s neutral, %s pending, %s red\n' "$green" "$neutral" "$pending" "$red"
fi

[ "$total" -gt 0 ] || [ -n "$local_receipt" ] || refuse 3 "no checks have reported on $short yet; run the gate again once CI starts"
if [ "$pending" -gt 0 ]; then
  reason="$(plural "$pending" check) of $total still pending on $short"
  [ "$red" -eq 0 ] || reason="$reason, $(plural "$red" "red check") so far"
  refuse 3 "$reason" "$(detail pending)" "Run the gate again when they finish."
fi

# A workflow run still going may not have created every check yet: jobs that
# wait on a planner appear only once it finishes. Such a run holds the merge.
repo_ref="${url#https://}"
repo_ref="${repo_ref%/pull/*}"
gh_cli run list --repo "$repo_ref" --commit "$sha" --json workflowName,status,url --limit 100 \
  >"$scratch/runs.json" 2>"$scratch/err" \
  || die "could not read the workflow runs on $short: $(first_line "$scratch/err")"
unfinished="$(jq -r '.[]? | select(.status != "completed")
  | "  pending  " + (.workflowName // "workflow") + " run (" + ((.status // "unknown") | ascii_downcase) + ")"
    + (if (.url // "") != "" then "  " + .url else "" end)' "$scratch/runs.json" 2>/dev/null)" \
  || die "could not read the workflow runs on $short"
if [ -n "$unfinished" ]; then
  refuse 3 "a workflow run on $short is still going, so not every check has reported" "$unfinished" \
    "Run the gate again when it finishes."
fi

# Explicit local evidence can replace unavailable hosted execution, never pending
# execution. Bind it to the current base as well as the classified PR head.
read_base_sha() {
  gh_cli pr view "$url" --json baseRefOid >"$scratch/base.json" 2>"$scratch/err" || return 1
  jq -er '.baseRefOid | select(test("^[0-9a-f]{40}$"))' "$scratch/base.json"
}
if [ -n "$local_receipt" ]; then
  local_base_sha="$(read_base_sha)" || die "could not resolve the current base for local evidence"
  receipt="$scratch/local-receipt.md"
  python3 "$SCRIPT_DIR/bin/lib/local_ci_receipt.py" validate --receipt "$local_receipt" \
    --repo "$pr_repo" --pr "$number" --head "$sha" --base "$base" --base-sha "$local_base_sha" \
    >"$receipt" 2>"$scratch/err" || die "local evidence rejected: $(first_line "$scratch/err")"
fi

# The merge names the classified commit: a push after the read is refused by GitHub.
merge_head() {
  if [ -n "$local_receipt" ]; then
    local latest_base
    latest_base="$(read_base_sha)" || { echo "cannot recheck integration base" >"$scratch/merge.out"; return 1; }
    [ "$latest_base" = "$local_base_sha" ] || {
      echo "integration base changed; refresh local checks and receipt" >"$scratch/merge.out"; return 1;
    }
  fi
  gh_cli pr merge "$url" --merge --match-head-commit "$sha" >"$scratch/merge.out" 2>&1
}

# --- The ledger ----------------------------------------------------------------
# CI's attempts on the head: the highest run_attempt among its ci.yml runs and,
# past the first, the jobs of every attempt in one listing. A job that failed
# or timed out in an earlier attempt and passes in the last flaked; one that
# was cancelled in an earlier attempt and passes in the last recovered, for a
# cause the listing does not hold (a job killed by its own time limit is
# cancelled like one a person stopped); the aggregate Full CI result job is
# neither. A gh failure leaves attempts unknown and nothing flaked or
# recovered.
attempts=""
ci_attempts() {
  local host="${repo_ref%%/*}" run="" id=""
  attempts=""
  : >"$scratch/reruns"
  gh_cli api "repos/$pr_repo/actions/runs?head_sha=$sha&per_page=20" --hostname "$host" \
    >"$scratch/ci-runs.json" 2>/dev/null || return 0
  run="$(jq -r '[.workflow_runs[]? | select((.path // "" | split("@")[0]) == ".github/workflows/ci.yml")
      | select((.id | type) == "number" and (.run_attempt | type) == "number")]
    | max_by([.run_attempt, .id]) // empty | "\(.id) \(.run_attempt)"' "$scratch/ci-runs.json" 2>/dev/null)" \
    || return 0
  id="${run% *}"
  run="${run#* }"
  [[ "$id" =~ ^[0-9]+$ && "$run" =~ ^[1-9][0-9]*$ ]] || return 0
  if [ "$run" -gt 1 ]; then
    gh_cli api "repos/$pr_repo/actions/runs/$id/jobs?filter=all&per_page=100" --paginate --hostname "$host" \
      >"$scratch/jobs.json" 2>/dev/null || return 0
    jq -rs --argjson last "$run" '
      [.[] | .jobs[]? | select((.name | type) == "string" and (.run_attempt | type) == "number")
         | select(.name | test("^Full CI result( — |$)") | not)]
      | ([.[] | select(.run_attempt == $last and .conclusion == "success") | .name] | unique) as $passed
      | ([.[] | select(.run_attempt < $last and (.conclusion == "failure" or .conclusion == "timed_out")) | .name]
         | unique | map(select(. as $job | any($passed[]; . == $job)))) as $flaked
      | ([.[] | select(.run_attempt < $last and .conclusion == "cancelled") | .name]
         | unique | map(select(. as $job | any($passed[]; . == $job) and (any($flaked[]; . == $job) | not)))) as $recovered
      | ($flaked[] | "flaked\t\(.)"), ($recovered[] | "recovered\t\(.)")' "$scratch/jobs.json" \
      >"$scratch/reruns.read" 2>/dev/null || return 0
    mv "$scratch/reruns.read" "$scratch/reruns" || return 0
  fi
  attempts="$run"
}

# ledger KIND POSTED: append the decision to the gate ledger, or with --dry-run
# print the line it would append. Its callers add `|| true`: a line that cannot
# be written is reported and never changes the decision or the exit code.
ledger() {
  local kind="$1" posted="$2" fate="" job="" flaked="" recovered="" note="" status=0 reason="" by="" session="" line=""
  local args=(gate-event --root "$SCRIPT_DIR" --memory "$memory" --kind "$kind" --pr "$number"
    --head "$sha" --base "$base" --repo "$pr_repo" --green "$green" --neutral "$neutral" --red "$red")
  ci_attempts || true
  [ -z "$attempts" ] || args+=(--attempts "$attempts")
  while IFS=$'\t' read -r fate job; do
    case "$fate" in
      flaked) args+=(--flaked "$job"); flaked="${flaked:+$flaked, }$job" ;;
      recovered) args+=(--recovered "$job"); recovered="${recovered:+$recovered, }$job" ;;
    esac
  done <"$scratch/reruns"
  if $posted; then args+=(--receipt); fi
  if [ -n "$attempts" ] && [ "$attempts" -gt 1 ]; then
    note=" · attempts $attempts, flaked: ${flaked:-none}${recovered:+; recovered: $recovered}"
  fi
  if $dry_run; then
    python3 "$SCRIPT_DIR/bin/lib/session_record.py" "${args[@]}" --dry-run \
      >"$scratch/ledger-preview.json" 2>"$scratch/ledger.err" || status=$?
    if [ "$status" -eq 0 ]; then
      printf 'ledger: would append %s\n' "$(cat "$scratch/ledger-preview.json")"
    else
      printf 'ledger: would withhold (%s)\n' "$(first_line "$scratch/ledger.err")"
    fi
    return 0
  fi
  python3 "$SCRIPT_DIR/bin/lib/session_record.py" "${args[@]}" >/dev/null 2>"$scratch/ledger.err" || status=$?
  if [ "$status" -eq 0 ]; then
    printf 'ledger: gate.jsonl +1%s\n' "$note"
  else
    reason="$(first_line "$scratch/ledger.err")" || reason=""
    printf 'ledger: not written (%s)\n' "${reason:-exit $status}"
  fi
  return 0
}

if [ "$red" -eq 0 ] && [ -z "$local_receipt" ]; then
  result="all $green checks green"
  [ "$neutral" -eq 0 ] || result="$result, $neutral neutral"
  if $dry_run; then
    printf 'decision: merge, %s (exit 0)\n' "$result"
    ledger merge false || true
    exit 0
  fi
  [ -z "$receipt" ] || echo "receipt: not posted, every check is green"
  merge_head || die "gh could not merge #$number: $(first_line "$scratch/merge.out")"
  printf 'merged %s into %s: %s\n' "$sha" "$base" "$result"
  ledger merge false || true
  exit 0
fi

if [ -z "$receipt" ]; then
  ledger_kind=refuse
  refuse 2 "$(plural "$red" "red check") on $short and no receipt" "$(detail red)" \
    "Fix them, or write a receipt that names each red check and why it does not matter, then run: bash bin/agent.sh merge $number --receipt FILE"
fi

# --- The receipt -------------------------------------------------------------
# A red check is named when one line of the receipt holds its exact name
# (whitespace aside, not inside a longer word or a longer check name) and at
# least three words besides the check names on that line: the reason.
if ! python3 - "$receipt" "$scratch/classified.json" "$local_receipt" >"$scratch/missing" 2>"$scratch/err" <<'PY'
import json
import re
import sys


def norm(text):
    return " ".join(text.split())


def pattern(name):
    before = r"(?<![^\W_])" if name[:1].isalnum() else ""
    after = r"(?![^\W_])" if name[-1:].isalnum() else ""
    return re.compile(before + re.escape(name) + after)


# Structured local evidence must explicitly explain each failed job. A job
# named "test" appearing in a recorded command is not its waiver reason.
if sys.argv[3]:
    with open(sys.argv[3], encoding="utf-8") as handle:
        local = json.load(handle)
    with open(sys.argv[2], encoding="utf-8") as handle:
        checks = json.load(handle)
    reasons = {norm(row["name"]): row["reason"] for row in local["failed_checks"]}
    for check in checks:
        if check["class"] == "red" and len(re.findall(r"[^\W_]+", reasons.get(norm(check["name"]), ""))) < 3:
            print(f"  missing  {check['name']} ({check['state']})")
    sys.exit(0)

with open(sys.argv[1], encoding="utf-8", errors="replace") as handle:
    receipt = [norm(line) for line in handle.read().splitlines()]
with open(sys.argv[2], encoding="utf-8") as handle:
    checks = json.load(handle)
# Longest names first, so a check whose name contains another's is taken whole.
names = sorted({norm(check["name"]) for check in checks if norm(check["name"])}, key=len, reverse=True)
patterns = [(name, pattern(name)) for name in names]
named = set()
for line in receipt:
    present = set()
    for name, exact in patterns:
        if exact.search(line):
            present.add(name)
            line = exact.sub(" ", line)
    if len(re.findall(r"[^\W_]+", line)) >= 3:
        named |= present
reported = set()
for check in checks:
    name = norm(check["name"])
    if check["class"] != "red" or name in named or name in reported:
        continue
    reported.add(name)
    link = f"  {check['link']}" if check["link"] else ""
    print(f"  missing  {check['name']} ({check['state']}){link}")
PY
then
  die "could not read the receipt $receipt: $(first_line "$scratch/err")"
fi
if [ -s "$scratch/missing" ]; then
  refuse 2 "the receipt does not name every red check with a reason" "$(cat "$scratch/missing")" \
    "Name each red check exactly as listed, on a line that says why it does not matter."
fi

result="$green green"
[ "$neutral" -eq 0 ] || result="$result, $neutral neutral"
result="$result, $red red under receipt"
[ -z "$local_receipt" ] || result="$result, verified local evidence"
if $dry_run; then
  printf 'decision: merge, %s; the receipt is posted on #%s first (exit 0)\n' "$result" "$number"
  ledger merge true || true
  exit 0
fi

# The comment: the receipt as written under one "Merge receipt" heading, then
# the commit, each red check and the runs, linked. Backticks are Markdown.
# shellcheck disable=SC2016
{
  printf '## Merge receipt\n\n'
  started=false
  while IFS= read -r line || [ -n "$line" ]; do
    if ! $started; then
      [ -n "${line//[[:space:]]/}" ] || continue
      started=true
      if [[ "$line" =~ ^#+[[:space:]]*[Mm]erge[[:space:]]+[Rr]eceipt[[:space:]]*$ ]]; then continue; fi
    fi
    printf '%s\n' "$line"
  done <"$receipt"
  printf '\n---\n\n'
  printf 'Checks on [`%s`](%s/commit/%s) into `%s`: %s green, %s neutral, %s red.\n\n' \
    "$short" "${url%/pull/*}" "$sha" "$base" "$green" "$neutral" "$red"
  jq -r '.[] | select(.class == "red")
    | "- red · " + .name + " (" + .state + ")" + (if .link != "" then " · " + .link else "" end)' \
    "$scratch/classified.json"
  jq -r '[.[] | .link | select(test("/actions/runs/[0-9]+/job/[0-9]+")) | sub("/job/[0-9]+.*$"; "")]
    | unique | .[] | "- run · " + .' "$scratch/classified.json"
  printf '\nMerging on this receipt through `bin/agent.sh merge`.\n'
} >"$scratch/comment.md"

comment_url="$(gh_cli pr comment "$url" --body-file "$scratch/comment.md" 2>"$scratch/err")" \
  || die "could not post the receipt on #$number, so nothing merged: $(first_line "$scratch/err")"
printf 'receipt: %s\n' "${comment_url:-posted on #$number}"
merge_head || die "the receipt is posted, but gh could not merge #$number: $(first_line "$scratch/merge.out")"
printf 'merged %s into %s: %s\n' "$sha" "$base" "$result"
ledger merge true || true
exit 0
