#!/bin/bash
# Runtime-neutral Egregore agent bridge.
#
# This script exposes the Git-backed memory protocol without requiring
# Claude Code hooks or slash-command skills. Any agent runtime that can run
# shell commands inside an Egregore checkout can use it to sync memory,
# create handoffs, ask questions, answer questions, and inspect activity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"
MEMORY_DIR="${EGREGORE_MEMORY_DIR:-$SCRIPT_DIR/memory}"

usage() {
  cat <<'EOF'
Usage: agent.sh <command> [options]

Runtime-neutral commands:
  protocol                         Print the portable agent protocol
  sync                             Pull latest shared memory
  activity [--for <person>]        Show recent handoffs and questions
  people                           List known people from memory/people
  handoff --from A --to B --topic T [--body TEXT|--body-file PATH] [--no-push]
  ask --from A --to B --topic T --question TEXT [--no-push]
  answer --from A --question PATH --body TEXT [--no-push]

The script uses the existing memory/ repository and keeps Claude Code
behavior unchanged.
EOF
}

die() {
  echo "agent.sh: $*" >&2
  exit 1
}

slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g' \
    | sed -E 's/^-+|-+$//g' \
    | cut -c1-60
}

ensure_memory() {
  [ -d "$MEMORY_DIR" ] || die "memory directory not found: $MEMORY_DIR"
}

is_memory_git() {
  git -C "$MEMORY_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1
}

memory_branch() {
  git -C "$MEMORY_DIR" branch --show-current 2>/dev/null || echo "main"
}

sync_memory() {
  ensure_memory
  if is_memory_git && git -C "$MEMORY_DIR" remote get-url origin >/dev/null 2>&1; then
    local branch
    branch="$(memory_branch)"
    [ -z "$branch" ] && branch="main"
    git -C "$MEMORY_DIR" pull --rebase origin "$branch" --quiet 2>/dev/null || true
  fi
}

save_memory() {
  local message="$1"
  shift
  local no_push="${NO_PUSH:-0}"

  ensure_memory
  if ! is_memory_git; then
    return 0
  fi

  git -C "$MEMORY_DIR" add "$@" >/dev/null 2>&1 || true
  if ! git -C "$MEMORY_DIR" diff --cached --quiet 2>/dev/null; then
    git -C "$MEMORY_DIR" commit -m "$message" --quiet 2>/dev/null || true
  fi

  [ "$no_push" = "1" ] && return 0
  git -C "$MEMORY_DIR" remote get-url origin >/dev/null 2>&1 || return 0

  local branch
  branch="$(memory_branch)"
  [ -z "$branch" ] && branch="main"
  for _try in 1 2 3; do
    if git -C "$MEMORY_DIR" pull --rebase origin "$branch" --quiet 2>/dev/null \
       && git -C "$MEMORY_DIR" push origin "$branch" --quiet 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  die "could not push memory after 3 attempts"
}

person_from_state() {
  if [ -f "$SCRIPT_DIR/.egregore-state.json" ]; then
    jq -r '.github_username // .name // empty' "$SCRIPT_DIR/.egregore-state.json" 2>/dev/null || true
  fi
}

cmd_protocol() {
  cat <<'EOF'
Egregore portable agent protocol

1. Work inside an Egregore checkout with a linked memory/ repository.
2. Run `bin/agent.sh sync` before reading shared state.
3. Read `memory/people/` for collaborators.
4. Use `bin/agent.sh handoff` to leave structured context for another agent.
5. Use `bin/agent.sh ask` and `bin/agent.sh answer` for asynchronous questions.
6. Run `bin/agent.sh activity --for <person>` to see pending work.

This protocol is runtime-neutral. Claude Code may still use .claude hooks and
skills, while Codex or another agent can call this script directly.
EOF
}

cmd_people() {
  ensure_memory
  local people_dir="$MEMORY_DIR/people"
  [ -d "$people_dir" ] || return 0
  local f github display
  for f in "$people_dir"/*.md; do
    [ -f "$f" ] || continue
    github="$(basename "$f" .md)"
    display="$(sed -nE 's/^name:[[:space:]]*(.*)$/\1/p; s/^# (.*)$/\1/p' "$f" | head -1)"
    [ -z "$display" ] && display="$github"
    printf '%s\t%s\n' "$github" "$display"
  done
}

cmd_sync() {
  sync_memory
  echo "synced: $MEMORY_DIR"
}

cmd_activity() {
  ensure_memory
  local for_person=""
  local limit=12
  while [ $# -gt 0 ]; do
    case "$1" in
      --for) for_person="${2:-}"; shift 2 ;;
      --limit) limit="${2:-12}"; shift 2 ;;
      *) die "unknown activity option: $1" ;;
    esac
  done

  echo "Handoffs"
  local index="$MEMORY_DIR/handoffs/index.md"
  if [ -f "$index" ]; then
    if [ -n "$for_person" ]; then
      grep -i "handoff to ${for_person}" "$index" 2>/dev/null | head -n "$limit" || true
    else
      grep '^- ' "$index" 2>/dev/null | head -n "$limit" || true
    fi
  fi

  echo
  echo "Questions"
  local qdir="$MEMORY_DIR/knowledge/questions"
  [ -d "$qdir" ] || return 0
  local q from to topic status
  while IFS= read -r q; do
    from="$(sed -nE 's/^from:[[:space:]]*(.*)$/\1/p' "$q" | head -1)"
    to="$(sed -nE 's/^to:[[:space:]]*(.*)$/\1/p' "$q" | head -1)"
    topic="$(sed -nE 's/^topic:[[:space:]]*(.*)$/\1/p' "$q" | head -1)"
    status="$(sed -nE 's/^status:[[:space:]]*(.*)$/\1/p' "$q" | head -1)"
    [ -z "$status" ] && status="pending"
    if [ -n "$for_person" ] && [ "$(echo "$to" | tr '[:upper:]' '[:lower:]')" != "$(echo "$for_person" | tr '[:upper:]' '[:lower:]')" ]; then
      continue
    fi
    printf '%s\n' "- ${from} -> ${to} [${status}]: ${topic} (${q#$MEMORY_DIR/})"
  done < <(find "$qdir" -type f -name '*.md' | sort -r | head -n "$limit")
}

cmd_handoff() {
  ensure_memory
  local from="" to="" topic="" body="" body_file="" project=""
  NO_PUSH=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --to) to="${2:-}"; shift 2 ;;
      --topic) topic="${2:-}"; shift 2 ;;
      --body) body="${2:-}"; shift 2 ;;
      --body-file) body_file="${2:-}"; shift 2 ;;
      --project) project="${2:-}"; shift 2 ;;
      --no-push) NO_PUSH=1; shift ;;
      *) die "unknown handoff option: $1" ;;
    esac
  done

  [ -z "$from" ] && from="$(person_from_state)"
  [ -n "$from" ] || die "handoff requires --from"
  [ -n "$topic" ] || die "handoff requires --topic"
  if [ -n "$body_file" ]; then
    [ -f "$body_file" ] || die "body file not found: $body_file"
    body="$(cat "$body_file")"
  elif [ -z "$body" ] && [ ! -t 0 ]; then
    body="$(cat)"
  fi
  [ -n "$body" ] || body="No briefing provided."

  local today tmpd result rel project_line
  local handoff_args=()
  today="$(date +%Y-%m-%d)"
  tmpd="$(mktemp -d -t egregore-agent-handoff-XXXXXX)"
  trap 'rm -rf "$tmpd"' RETURN

  project_line=""
  [ -n "$project" ] && project_line="**Project**: $project"
  [ -n "$to" ] && handoff_args+=(--recipient "$to")
  [ -n "$project" ] && handoff_args+=(--project "$project")
  [ "$NO_PUSH" = "1" ] && handoff_args+=(--no-push)

  {
    printf '# Handoff: %s\n\n' "$topic"
    printf '**Date**: %s\n' "$today"
    printf '**Author**: %s\n' "$from"
    [ -n "$to" ] && printf '**To**: %s\n' "$to"
    [ -n "$project_line" ] && printf '%s\n' "$project_line"
    printf '\n## Briefing\n\n%s\n\n' "$body"
    printf '## Next Steps\n\n- Continue from this handoff using the shared Egregore memory protocol.\n'
  } | TMPDIR="$tmpd" bash "$SCRIPT_DIR/bin/handoff-run.sh" \
        --author "$from" \
        --topic "$topic" \
        "${handoff_args[@]}" \
        --no-publish \
        --no-notify >/dev/null

  result="$tmpd/handoff-run-result.json"
  rel="$(jq -r '.file // empty' "$result" 2>/dev/null || true)"
  [ -n "$rel" ] || die "handoff was not created"
  echo "handoff: memory/$rel"
}

cmd_ask() {
  ensure_memory
  local from="" to="" topic="" question=""
  NO_PUSH=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --to) to="${2:-}"; shift 2 ;;
      --topic) topic="${2:-}"; shift 2 ;;
      --question) question="${2:-}"; shift 2 ;;
      --no-push) NO_PUSH=1; shift ;;
      *) die "unknown ask option: $1" ;;
    esac
  done

  [ -z "$from" ] && from="$(person_from_state)"
  [ -n "$from" ] || die "ask requires --from"
  [ -n "$to" ] || die "ask requires --to"
  [ -n "$topic" ] || die "ask requires --topic"
  [ -n "$question" ] || die "ask requires --question"

  local now slug rel abs n
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  slug="$(slugify "$topic")"
  mkdir -p "$MEMORY_DIR/knowledge/questions"
  rel="knowledge/questions/$(date +%Y-%m-%d)-${from}-to-${to}-${slug}.md"
  abs="$MEMORY_DIR/$rel"
  n=2
  while [ -e "$abs" ]; do
    rel="knowledge/questions/$(date +%Y-%m-%d)-${from}-to-${to}-${slug}-${n}.md"
    abs="$MEMORY_DIR/$rel"
    n=$((n + 1))
  done

  cat > "$abs" <<EOF
---
from: $from
to: $to
topic: $topic
status: pending
created: $now
---

## Questions

- $question
EOF

  save_memory "Question: ${topic} (to ${to})" "$rel"
  echo "question: memory/$rel"
}

cmd_answer() {
  ensure_memory
  local from="" question_path="" body=""
  NO_PUSH=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --question) question_path="${2:-}"; shift 2 ;;
      --body) body="${2:-}"; shift 2 ;;
      --no-push) NO_PUSH=1; shift ;;
      *) die "unknown answer option: $1" ;;
    esac
  done

  [ -z "$from" ] && from="$(person_from_state)"
  [ -n "$from" ] || die "answer requires --from"
  [ -n "$question_path" ] || die "answer requires --question"
  [ -n "$body" ] || die "answer requires --body"

  local abs rel now tmp
  case "$question_path" in
    "$MEMORY_DIR"/*) abs="$question_path" ;;
    memory/*) abs="$MEMORY_DIR/${question_path#memory/}" ;;
    *) abs="$MEMORY_DIR/$question_path" ;;
  esac
  [ -f "$abs" ] || die "question file not found: $question_path"
  rel="${abs#$MEMORY_DIR/}"
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  tmp="$abs.tmp.$$"

  awk -v from="$from" -v now="$now" '
    BEGIN { in_fm = 0; added = 0; saw_status = 0 }
    NR == 1 && $0 == "---" { in_fm = 1; print; next }
    in_fm && /^status:/ { print "status: answered"; saw_status = 1; next }
    in_fm && $0 == "---" {
      if (!saw_status) print "status: answered"
      if (!added) {
        print "answered_by: " from
        print "answered_at: " now
        added = 1
      }
      in_fm = 0
      print
      next
    }
    { print }
  ' "$abs" > "$tmp" && mv "$tmp" "$abs"

  {
    printf '\n## Answer\n\n'
    printf '**From**: %s\n' "$from"
    printf '**At**: %s\n\n' "$now"
    printf '%s\n' "$body"
  } >> "$abs"

  save_memory "Answer question: ${rel}" "$rel"
  echo "answered: memory/$rel"
}

case "${1:-}" in
  --help|-h|help|"") usage ;;
  protocol) shift; cmd_protocol "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  activity) shift; cmd_activity "$@" ;;
  people) shift; cmd_people "$@" ;;
  handoff) shift; cmd_handoff "$@" ;;
  ask) shift; cmd_ask "$@" ;;
  answer) shift; cmd_answer "$@" ;;
  *) die "unknown command: $1" ;;
esac
