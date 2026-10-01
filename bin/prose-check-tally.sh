#!/usr/bin/env bash
set -euo pipefail

# Tally the advisory prose-check comments across pull requests.
#
#   bin/prose-check-tally.sh [--repo owner/name] [--since YYYY-MM-DD] [--limit N] [--json]
#   bin/prose-check-tally.sh --from records.jsonl [--json]      # offline: one data block per line
#
# Reads the `<!-- prose-check-data {...} -->` block that .github/workflows/
# prose-check.yml leaves on PRs with findings and sums hits per rule. The
# workflow stays silent on clean PRs, so the denominator comes from the PR
# list: every non-draft, non-bot PR in the window counts as checked, and one
# without a comment counts as clean. PRs opened before the workflow existed
# also read as clean, so start --since at the day the check went live.
# Requires gh and jq.

REPO=""
SINCE=""
LIMIT=100
JSON=0
FROM=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="$2"; shift 2 ;;
    --since) SINCE="$2"; shift 2 ;;
    --limit) LIMIT="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    --from) FROM="$2"; shift 2 ;;
    -h|--help) sed -n '3,12p' "$0"; exit 0 ;;
    *) echo "prose-check-tally: unknown argument $1" >&2; exit 2 ;;
  esac
done

command -v jq >/dev/null || { echo "prose-check-tally: jq is required" >&2; exit 2; }

if [ -n "$FROM" ]; then
  [ -f "$FROM" ] || { echo "prose-check-tally: no such file $FROM" >&2; exit 2; }
  REPO="${REPO:-$FROM}"
  RECORDS="$(grep -v '^[[:space:]]*$' "$FROM" || true)"
else
  command -v gh >/dev/null || { echo "prose-check-tally: gh is required" >&2; exit 2; }
  if [ -z "$REPO" ]; then
    REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
  fi
  [ -n "$REPO" ] || { echo "prose-check-tally: pass --repo owner/name" >&2; exit 2; }

  # PRs the workflow would have checked: in the window, not draft, not a bot.
  PRS="$(gh pr list --repo "$REPO" --state all --limit "$LIMIT" --json number,createdAt,isDraft,author \
    | jq -r --arg since "$SINCE" '.[] | select($since == "" or .createdAt >= $since) | select(.isDraft | not) | select((.author.is_bot // false) | not) | .number')"

  # One JSON line per PR: its latest data block, or a clean record when the
  # workflow had nothing to say.
  RECORDS="$(for n in $PRS; do
    BLOCK="$(gh api "repos/$REPO/issues/$n/comments" --paginate --jq '.[].body' 2>/dev/null \
      | grep -o '<!-- prose-check-data {.*} -->' | tail -1 \
      | sed -e 's/^<!-- prose-check-data //' -e 's/ -->$//' || true)"
    if [ -n "$BLOCK" ]; then printf '%s\n' "$BLOCK"; else printf '{"pr":"%s","inputs":0,"total":0,"blocks":0,"warns":0,"findings":{}}\n' "$n"; fi
  done)"
fi

# Keep only well-formed records; a human-edited comment must not sink the tally.
VALID=""
SKIPPED=0
while IFS= read -r line; do
  [ -n "$line" ] || continue
  if printf '%s' "$line" | jq -e 'type == "object" and has("total") and has("findings")' >/dev/null 2>&1; then
    VALID="${VALID}${line}"$'\n'
  else
    SKIPPED=$((SKIPPED + 1))
  fi
done <<< "$RECORDS"
[ "$SKIPPED" -eq 0 ] || echo "prose-check-tally: skipped $SKIPPED malformed record(s)" >&2
RECORDS="$VALID"

[ -n "${RECORDS//[[:space:]]/}" ] || { echo "prose-check-tally: no prose-check data blocks found in $REPO" >&2; exit 1; }

SUMMARY="$(printf '%s\n' "$RECORDS" | jq -s '{
  repo: "'"$REPO"'",
  prs_checked: length,
  prs_clean: map(select(.total == 0)) | length,
  inputs: map(.inputs) | add,
  findings_total: map(.total) | add,
  blocks: map(.blocks) | add,
  warns: map(.warns) | add,
  by_rule: (map(.findings | to_entries) | flatten | group_by(.key)
            | map({key: .[0].key, value: {hits: (map(.value) | add), prs: length}}) | from_entries)
}')"

if [ "$JSON" -eq 1 ]; then
  printf '%s\n' "$SUMMARY"
  exit 0
fi

printf '%s\n' "$SUMMARY" | jq -r '
  "prose check tally · \(.repo)\(if "'"$SINCE"'" != "" then " · since '"$SINCE"'" else "" end)",
  "  PRs checked   \(.prs_checked)   clean \(.prs_clean)",
  "  inputs        \(.inputs)   findings \(.findings_total) (\(.blocks) would block, \(.warns) warn)",
  "",
  "  rule                          hits   PRs",
  (.by_rule | to_entries | sort_by(-.value.hits) | .[]
    | "  \(.key + "                            " | .[0:28])  \(.value.hits | tostring | ("    " + .) | .[-4:])  \(.value.prs | tostring | ("    " + .) | .[-4:])")
'
