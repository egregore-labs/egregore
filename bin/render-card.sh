#!/usr/bin/env bash
set -euo pipefail

# Deterministic renderer for the /handoff result card.
# Input: handoff-run-result.json plus the Step 2 briefing on stdin or a file.

choose_utf8_locale() {
  local current candidate
  current="${LC_ALL:-${LC_CTYPE:-${LANG:-}}}"
  case "$current" in
    *UTF-8*|*utf-8*|*utf8*) return 0 ;;
  esac

  for candidate in C.UTF-8 en_US.UTF-8; do
    if locale -a 2>/dev/null | awk -v want="$candidate" 'tolower($0) == tolower(want) { found = 1 } END { exit found ? 0 : 1 }'; then
      export LC_ALL="$candidate"
      return 0
    fi
  done

  export LC_ALL="${LANG:-en_US.UTF-8}"
}

choose_utf8_locale

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RESULT_FILE="${TMPDIR:-/tmp}/handoff-run-result.json"
BRIEFING_FILE=""

usage() {
  echo "usage: bash bin/render-card.sh --result <path-to-result-json> [--briefing-file <path>]" >&2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --result)
      [ $# -ge 2 ] || { usage; exit 2; }
      RESULT_FILE="$2"
      shift 2
      ;;
    --briefing-file)
      [ $# -ge 2 ] || { usage; exit 2; }
      BRIEFING_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage
      exit 2
      ;;
  esac
done

[ -f "$RESULT_FILE" ] || { echo "missing result JSON: $RESULT_FILE" >&2; exit 1; }

BRIEFING_FILE_TEXT=""
STDIN_BRIEFING=""
BRIEFING=""
if [ -n "$BRIEFING_FILE" ]; then
  [ -f "$BRIEFING_FILE" ] || { echo "missing briefing file: $BRIEFING_FILE" >&2; exit 1; }
  BRIEFING_FILE_TEXT="$(< "$BRIEFING_FILE")"
fi
if [ ! -t 0 ]; then
  STDIN_BRIEFING="$(< /dev/stdin)"
fi

# ─── box constants ──────────────────────────────────────────────────────

repeat_char() {
  local char="$1"
  local count="$2"
  local out=""
  local i=0
  while [ "$i" -lt "$count" ]; do
    out="${out}${char}"
    i=$((i + 1))
  done
  printf '%s' "$out"
}

spaces() {
  local count="$1"
  [ "$count" -le 0 ] && return 0
  printf "%${count}s" ""
}

TOP="┌$(repeat_char "─" 70)┐"
SEP="├$(repeat_char "─" 70)┤"
BOTTOM="└$(repeat_char "─" 70)┘"

# ─── text helpers ───────────────────────────────────────────────────────

trim() {
  local s="${1-}"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

clean_inline() {
  local s="${1-}"
  local collapsed
  s="${s//$'\r'/ }"
  s="${s//$'\n'/ }"
  s="${s//$'\t'/ }"
  while :; do
    collapsed="${s//  / }"
    [ "$collapsed" = "$s" ] && break
    s="$collapsed"
  done
  trim "$s"
}

lowercase() {
  awk -v s="${1-}" 'BEGIN { print tolower(s) }'
}

char_len() {
  printf '%s' "${1-}" | jq -Rs 'length'
}

char_slice() {
  local text="${1-}"
  local end="$2"
  printf '%s' "$text" | jq -Rs -r --argjson end "$end" '.[0:$end]'
}

char_range() {
  local text="${1-}"
  local start="$2"
  local end="$3"
  printf '%s' "$text" | jq -Rs -r --argjson start "$start" --argjson end "$end" '.[$start:$end]'
}

capitalize_handle() {
  awk -v s="${1-}" 'BEGIN {
    gsub(/[-_]+/, " ", s)
    if (s == "") { print "Unknown"; exit }
    print toupper(substr(s, 1, 1)) substr(s, 2)
  }'
}

title_case() {
  awk -v s="${1-}" 'BEGIN {
    gsub(/[-_]+/, " ", s)
    n = split(s, parts, /[[:space:]]+/)
    out = ""
    for (i = 1; i <= n; i++) {
      if (parts[i] == "") continue
      word = toupper(substr(parts[i], 1, 1)) tolower(substr(parts[i], 2))
      out = out (out == "" ? "" : " ") word
    }
    print out
  }'
}

fit_text() {
  local text="${1-}"
  local max="$2"
  text="${text//$'\r'/ }"
  text="${text//$'\n'/ }"
  text="${text//$'\t'/ }"
  if [ "$(char_len "$text")" -le "$max" ]; then
    printf '%s' "$text"
    return 0
  fi
  if [ "$max" -le 1 ]; then
    printf '…'
  else
    printf '%s…' "$(char_slice "$text" "$((max - 1))")"
  fi
}

content_line() {
  local text
  local pad
  text="$(fit_text "${1-}" 68)"
  pad=$((68 - $(char_len "$text")))
  printf '│  %s' "$text"
  spaces "$pad"
  printf '│\n'
}

header_line() {
  local left="⇌ HANDOFF SENT"
  local right="$1"
  local max_right gap
  max_right=$((68 - $(char_len "$left") - 1))
  right="$(fit_text "$right" "$max_right")"
  gap=$((68 - $(char_len "$left") - $(char_len "$right")))
  [ "$gap" -lt 1 ] && gap=1
  content_line "${left}$(spaces "$gap")${right}"
}

wrap_briefing() {
  local text="$1"
  local max=64
  local line=""
  local word
  local word_len offset
  local words=()

  text="${text//$'\r'/ }"
  text="${text//$'\n'/ }"
  text="${text//$'\t'/ }"
  read -r -a words <<< "$text"
  for word in "${words[@]}"; do
    word_len="$(char_len "$word")"
    if [ "$word_len" -gt "$max" ]; then
      if [ -n "$line" ]; then
        printf '%s\n' "$line"
        line=""
      fi
      offset=0
      while [ "$offset" -lt "$word_len" ]; do
        printf '%s\n' "$(char_range "$word" "$offset" "$((offset + max))")"
        offset=$((offset + max))
      done
    elif [ -z "$line" ]; then
      line="$word"
    elif [ $(( $(char_len "$line") + 1 + word_len )) -le "$max" ]; then
      line="${line} ${word}"
    else
      printf '%s\n' "$line"
      line="$word"
    fi
  done
  [ -n "$line" ] && printf '%s\n' "$line"
}

display_author() {
  local handle="$1"
  local people_file="$SCRIPT_DIR/memory/people/${handle}.md"
  local first_line name
  if [ -f "$people_file" ]; then
    IFS= read -r first_line < "$people_file" || true
    case "$first_line" in
      "# "*)
        name="$(clean_inline "${first_line#"# "}")"
        if [ -n "$name" ]; then
          printf '%s' "$name"
          return 0
        fi
        ;;
    esac
  fi
  capitalize_handle "$handle"
}

extract_briefing_from_file() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk '
    /^## Briefing[[:space:]]*$/ { in_section = 1; next }
    in_section && /^## / { exit }
    in_section { lines[++n] = $0 }
    END {
      start = 1
      while (start <= n && lines[start] ~ /^[[:space:]]*$/) start++
      end = n
      while (end >= start && lines[end] ~ /^[[:space:]]*$/) end--
      for (i = start; i <= end; i++) print lines[i]
    }
  ' "$file"
}

abs_file_for_briefing="$(jq -r '.absFile // ""' "$RESULT_FILE")"
if [ -n "$(trim "$BRIEFING_FILE_TEXT")" ]; then
  BRIEFING="$BRIEFING_FILE_TEXT"
elif [ -n "$(trim "$STDIN_BRIEFING")" ]; then
  BRIEFING="$STDIN_BRIEFING"
else
  BRIEFING="$(extract_briefing_from_file "$abs_file_for_briefing")"
fi

if [ -z "$(trim "$BRIEFING")" ]; then
  echo "briefing input is empty; pass --briefing-file, stdin, or include a ## Briefing section in absFile" >&2
  exit 1
fi

slug_from_file() {
  local file="$1"
  local author="$2"
  local base stem slug
  base="${file##*/}"
  stem="${base%.md}"
  slug="$stem"
  case "$slug" in
    [0-9][0-9]-"$author"-*) slug="${slug#??-$author-}" ;;
    [0-9][0-9]-*) slug="${slug#??-}"; slug="${slug#*-}" ;;
  esac
  printf '%s' "$slug"
}

# ─── repo table parser ──────────────────────────────────────────────────

TABLE_CELLS=()

parse_table_cells() {
  local line="$1"
  local parts=()
  local i start end
  TABLE_CELLS=()
  IFS='|' read -r -a parts <<< "$line"
  start=0
  end="${#parts[@]}"
  [ "${parts[0]-}" = "" ] && start=1
  [ "$end" -gt "$start" ] && [ "${parts[$((end - 1))]-}" = "" ] && end=$((end - 1))
  for (( i = start; i < end; i++ )); do
    TABLE_CELLS+=("$(trim "${parts[$i]}")")
  done
}

is_separator_row() {
  local cell stripped
  [ "${#TABLE_CELLS[@]}" -gt 0 ] || return 1
  for cell in "${TABLE_CELLS[@]}"; do
    stripped="${cell//-/}"
    stripped="${stripped//:/}"
    stripped="$(trim "$stripped")"
    [ -z "$stripped" ] || return 1
  done
  return 0
}

cell_at() {
  local idx="$1"
  if [ "$idx" -ge 0 ] && [ "$idx" -lt "${#TABLE_CELLS[@]}" ]; then
    printf '%s' "${TABLE_CELLS[$idx]}"
  fi
}

repo_rows() {
  local file="$1"
  local in_section=0
  local header_seen=0
  local repo_idx=0
  local branch_idx=1
  local pr_idx=2
  local base_idx=3
  local line i header repo branch pr base pr_num row

  [ -f "$file" ] || return 0

  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$in_section" -eq 0 ]; then
      [ "$line" = "## Repo State" ] && in_section=1
      continue
    fi

    case "$line" in
      \|*) ;;
      "")
        [ "$header_seen" -eq 1 ] && break
        continue
        ;;
      "## "*) break ;;
      *)
        [ "$header_seen" -eq 1 ] && break
        continue
        ;;
    esac

    parse_table_cells "$line"
    if is_separator_row; then
      continue
    fi

    if [ "$header_seen" -eq 0 ]; then
      repo_idx=0
      branch_idx=1
      pr_idx=2
      base_idx=3
      for (( i = 0; i < ${#TABLE_CELLS[@]}; i++ )); do
        header="$(lowercase "$(clean_inline "${TABLE_CELLS[$i]}")")"
        case "$header" in
          repo|repository) repo_idx="$i" ;;
          branch) branch_idx="$i" ;;
          pr|pull-request|pull\ request) pr_idx="$i" ;;
          base|target) base_idx="$i" ;;
        esac
      done
      header_seen=1
      continue
    fi

    repo="$(clean_inline "$(cell_at "$repo_idx")")"
    branch="$(clean_inline "$(cell_at "$branch_idx")")"
    pr="$(clean_inline "$(cell_at "$pr_idx")")"
    base="$(clean_inline "$(cell_at "$base_idx")")"
    [ -n "$repo" ] && [ -n "$branch" ] || continue

    case "$pr" in
      ""|"—"|"-"|"--"|"n/a"|"N/A")
        row="◈ ${repo}: ${branch} → ${base}"
        ;;
      *)
        pr_num="${pr#PR }"
        pr_num="${pr_num#pr }"
        pr_num="${pr_num#\#}"
        row="◈ ${repo}: ${branch} → PR #${pr_num} to ${base}"
        ;;
    esac
    printf '%s\n' "$row"
  done < "$file"
}

# ─── JSON fields ────────────────────────────────────────────────────────

json_string() {
  jq -r "$1 // \"\"" "$RESULT_FILE"
}

mode="$(json_string '.mode')"
file="$(json_string '.file')"
abs_file="$(json_string '.absFile')"
graph_status="$(json_string '.graphStatus')"
memory_status="$(json_string '.memoryStatus')"
notify_status="$(json_string '.notifyStatus')"
artifact_url="$(json_string '.artifactUrl')"
publish_status="$(json_string '.publishStatus')"
recipient="$(clean_inline "$(json_string '.recipient')")"
topic="$(clean_inline "$(json_string '.topic')")"
author="$(clean_inline "$(json_string '.author')")"

author_display="$(display_author "$author")"
today="$(date '+%b %d')"
topic="$(fit_text "$topic" 58)"
recipient_display="$(title_case "$recipient")"
slug="$(slug_from_file "$file" "$author")"

REPO_ROWS=()
while IFS= read -r row; do
  [ -n "$row" ] && REPO_ROWS+=("$row")
done <<EOF
$(repo_rows "$abs_file")
EOF

ARTIFACT_ROWS=()
while IFS=$'\t' read -r artifact_type artifact_title; do
  artifact_type="$(clean_inline "$artifact_type")"
  artifact_title="$(clean_inline "$artifact_title")"
  [ -n "$artifact_type" ] || artifact_type="Artifact"
  [ -n "$artifact_title" ] || continue
  ARTIFACT_ROWS+=("◉ ${artifact_type}: ${artifact_title}")
done < <(jq -r '(.artifacts // []) | .[]? | [((.type // "Artifact") | tostring | gsub("[\t\r\n]+"; " ")), ((.title // "") | tostring | gsub("[\t\r\n]+"; " "))] | @tsv' "$RESULT_FILE")

STATUS_BITS=("saved")
[ "$graph_status" = "ok" ] && STATUS_BITS+=("graphed")
[ "$memory_status" = "ok" ] && STATUS_BITS+=("pushed")
[ "$notify_status" = "approval_required" ] && STATUS_BITS+=("notify approval pending")
[ -n "$artifact_url" ] && STATUS_BITS+=("published")
[ "$publish_status" = "relay-off" ] && STATUS_BITS+=("not published")
[ "$publish_status" = "fidelity-failed" ] && STATUS_BITS+=("not published")

status_text=""
for bit in "${STATUS_BITS[@]}"; do
  if [ -z "$status_text" ]; then
    status_text="$bit"
  else
    status_text="${status_text} · ${bit}"
  fi
done

# ─── render ─────────────────────────────────────────────────────────────

if [ "$mode" = "connected" ] && [ "$graph_status" = "offline" ]; then
  echo "⚠ graph indexing failed — will sync on next /save"
fi
if [ "$memory_status" = "failed" ]; then
  echo "⚠ memory push failed — commits are local"
fi
if [ "$publish_status" = "fidelity-failed" ]; then
  echo "Artifact not published — restore missing source content and preview it again."
fi
if [ "$notify_status" = "unavailable" ]; then
  echo "Notification unavailable — no message was sent."
fi

printf '```\n'
printf '%s\n' "$TOP"
header_line "${author_display} · ${today}"
printf '%s\n' "$SEP"
content_line ""
content_line "Topic: ${topic}"
if [ -n "$recipient_display" ]; then
  content_line "To:    ${recipient_display}"
fi
content_line ""
while IFS= read -r briefing_line; do
  [ -n "$briefing_line" ] && content_line "$briefing_line"
done <<EOF
$(wrap_briefing "$BRIEFING")
EOF
content_line ""

if [ "${#REPO_ROWS[@]}" -gt 0 ]; then
  printf '%s\n' "$SEP"
  content_line "REPOS"
  for row in "${REPO_ROWS[@]}"; do
    content_line "$row"
  done
fi

if [ "${#ARTIFACT_ROWS[@]}" -gt 0 ]; then
  printf '%s\n' "$SEP"
  for row in "${ARTIFACT_ROWS[@]}"; do
    content_line "$row"
  done
fi

printf '%s\n' "$SEP"
content_line "✓ ${status_text}"
printf '%s\n' "$BOTTOM"
printf '```\n'

if [ -n "$artifact_url" ]; then
  printf '[view this handoff →](%s)  ·  `/view handoff %s` (open locally)\n' "$artifact_url" "$slug"
else
  printf '`/view handoff %s` (open locally)\n' "$slug"
fi

if [ "$publish_status" = "relay-off" ]; then
  printf 'Not published — this handoff stayed on your machine. Sharing links need the public relay (unauthenticated, expires in 7 days): `bin/settings.sh relay on`.\n'
elif [ "$publish_status" = "hosting-off" ]; then
  printf 'Not published — artifact hosting is off for this egregore: `bin/settings.sh hosting on`.\n'
fi
