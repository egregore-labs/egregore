#!/usr/bin/env bash
# Reflex, show then propose: the runs of ci.yml on develop, the push run
# each merge starts and the workflow_dispatch run the nightly dispatcher
# requests. A run cancelled because a newer merge superseded it is no verdict
# and is skipped.
#
# Silent while the latest finished run is green, or red once. Two or more red
# runs running name the failing jobs of the latest run; three end with a
# proposal to give the failure an owner.
#
# The answer is cached for six hours in tmp/reflexes/nightly.json, so a warm
# card makes no gh call. A cold one makes one request, and a second for the
# failing jobs only when the line will print; both go through gh's own
# six-hour response cache, which outlives the sweep of tmp/ at session end.
# Silent when gh or jq is missing, gh is signed out or offline, or the
# request outlasts the runner's one-second budget.
set -uo pipefail

ROOT="${EGREGORE_ROOT:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)}"
[ -n "$ROOT" ] && [ -d "$ROOT" ] || exit 0
CACHE="$ROOT/tmp/reflexes/nightly.json"
TTL=21600
BRANCH=develop

command -v jq >/dev/null 2>&1 || exit 0
now="$(date +%s)"

fresh() {
  local at
  at="$(jq -r '.fetched_at // 0 | floor' "$CACHE" 2>/dev/null)" || return 1
  case "$at" in ''|*[!0-9]*) return 1 ;; esac
  [ $((at + TTL)) -gt "$now" ]
}

# Reads run conclusions, latest first; prints how many in a row are red.
red_streak() {
  local conclusion count=0 open=1
  while IFS= read -r conclusion; do
    [ "$open" -eq 1 ] || continue
    case "$conclusion" in
      failure|timed_out|action_required|startup_failure) count=$((count + 1)) ;;
      *) open=0 ;;
    esac
  done
  printf '%s\n' "$count"
}

refresh() {
  local runs jobs='[]' streak latest tmp
  command -v gh >/dev/null 2>&1 || return 1
  [ -f "$ROOT/.github/workflows/ci.yml" ] || return 1
  runs="$(cd "$ROOT" && gh api --cache 6h \
      "repos/{owner}/{repo}/actions/workflows/ci.yml/runs?branch=$BRANCH&per_page=10" 2>/dev/null \
    | jq -c '[.workflow_runs[]? | select(.status == "completed" and .conclusion != "cancelled")
              | {conclusion, createdAt: .created_at, databaseId: .id}] | .[:3]')" || return 1
  streak="$(jq -r '.[].conclusion' <<<"$runs" | red_streak)"
  if [ "$streak" -ge 2 ]; then
    latest="$(jq -r '.[0].databaseId' <<<"$runs")"
    case "$latest" in ''|*[!0-9]*) return 1 ;; esac
    jobs="$(cd "$ROOT" && gh api --cache 6h "repos/{owner}/{repo}/actions/runs/$latest/jobs?per_page=100" 2>/dev/null \
      | jq -c '[.jobs[]? | select(.conclusion == "failure" or .conclusion == "timed_out"
                                  or .conclusion == "startup_failure" or .conclusion == "action_required")
                | .name | gsub("\\s*[—–-]*\\s*[0-9a-f]{40}"; "")]')" || return 1
  fi
  mkdir -p "${CACHE%/*}" 2>/dev/null || return 1
  tmp="$(mktemp "${CACHE%/*}/.nightly.XXXXXX" 2>/dev/null)" || return 1
  if jq -n --argjson at "$now" --arg branch "$BRANCH" --argjson runs "$runs" --argjson jobs "$jobs" \
       '{fetched_at: $at, branch: $branch, runs: $runs, failing_jobs: $jobs}' >"$tmp" 2>/dev/null; then
    mv -f "$tmp" "$CACHE" || { rm -f "$tmp"; return 1; }
  else
    rm -f "$tmp"
    return 1
  fi
}

render() {
  local streak prefix suffix="" names="" name budget extra=0
  streak="$(jq -r '.runs[]?.conclusion' "$CACHE" 2>/dev/null | red_streak)"
  [ "$streak" -ge 2 ] || return 0
  [ "$streak" -lt 3 ] || suffix=" · propose an owner: /issue"
  prefix="$(jq -r '.branch // "develop"' "$CACHE") red $streak runs running: "
  # The runner cuts a line at 160 characters; keep the proposal inside it.
  budget=$((160 - ${#prefix} - ${#suffix} - 12))
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if [ -z "$names" ]; then
      names="$name"
    elif [ $((${#names} + 2 + ${#name})) -le "$budget" ]; then
      names="$names, $name"
    else
      extra=$((extra + 1))
    fi
  done < <(jq -r '.failing_jobs[]?' "$CACHE" 2>/dev/null)
  [ "$extra" -eq 0 ] || names="$names and $extra more"
  [ -n "$names" ] || names="$(jq -r '.runs[0].conclusion // "failure"' "$CACHE")"
  printf '%s%s%s\n' "$prefix" "$names" "$suffix"
}

fresh || refresh || exit 0
render
