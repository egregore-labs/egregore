#!/usr/bin/env bash
# Runtime-neutral Egregore agent bridge.
#
# This script exposes the Git-backed memory protocol without requiring
# Claude Code hooks or slash-command skills. Any agent runtime that can run
# shell commands inside an Egregore checkout can use it to sync memory,
# create handoffs, ask questions, answer questions, and inspect activity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MAIN_PROJECT_DIR="$SCRIPT_DIR"
if [ -f "$SCRIPT_DIR/.git" ]; then
  WT_GITDIR=$(sed 's/^gitdir: //' "$SCRIPT_DIR/.git" 2>/dev/null || true)
  [ -n "$WT_GITDIR" ] && MAIN_PROJECT_DIR=$(cd "$WT_GITDIR/../../.." 2>/dev/null && pwd || echo "$SCRIPT_DIR")
fi
if [ -f "$SCRIPT_DIR/bin/lib/worktree-links.sh" ]; then
  source "$SCRIPT_DIR/bin/lib/worktree-links.sh" >/dev/null 2>/dev/null || true
  egregore_link_shared_state "$SCRIPT_DIR" "$MAIN_PROJECT_DIR" >/dev/null 2>/dev/null || true
fi
CONFIG="$SCRIPT_DIR/egregore.json"
MEMORY_DIR="${EGREGORE_MEMORY_DIR:-$SCRIPT_DIR/memory}"
if [ -f "$SCRIPT_DIR/bin/lib/config.sh" ]; then
  # shellcheck source=bin/lib/config.sh
  source "$SCRIPT_DIR/bin/lib/config.sh"
fi
# Shared commit/PR message mechanics (trailers + skeleton body shape).
# shellcheck source=bin/lib/git-message.sh
. "$SCRIPT_DIR/bin/lib/git-message.sh" 2>/dev/null || true
type egregore_commit >/dev/null 2>&1 || egregore_commit() {
  local gd="$1" m="$3"; shift 3; git -C "$gd" commit -m "$m" "$@"
}
type egregore_pr_skeleton >/dev/null 2>&1 || egregore_pr_skeleton() {
  printf '## What\n%s\n\n## Why\n%s\n\n## Verification\n%s\n\n%s\n' "$1" "$2" "$3" "$4"
}

usage() {
  cat <<'EOF'
Usage: agent.sh <command> [options]

Runtime-neutral commands:
  protocol                         Print the portable agent protocol
  sync                             Pull latest shared memory
  activity [--for <person>]        Show recent handoffs and questions
  search "query" [-n N] [--fast|--semantic]
                                   Hybrid recall over shared memory (qmd)
  people                           List known people from memory/people
  branch --topic TEXT              Create or reuse a task branch/worktree
  save [--message TEXT] [--pr-body TEXT|--pr-body-file PATH]
                                   Commit and push current repo + memory changes;
                                   PR body follows .claude/context/pr-format.md
                                   (auto-generated skeleton if not provided)
  autosave [status|on|off|scope|publish|merge]  Personal ambient-save settings + consent
  wrap --topic T --summary TEXT    Write a session wrap to memory/wraps
  handoff --from A --to B --topic T [--intent action|feedback|fyi]
      [--body TEXT|--body-file PATH] [--no-push] [--no-publish] [--no-notify] [--json]
  ask --from A --to B --topic T --question TEXT [--no-push]
      [--harvest-id ID --harvest-session-id ID --turn N
       --question-intent TEXT --context-mode blind|disclosed|comparative]
  answer --from A --question PATH --body TEXT [--no-push]

The script uses the existing memory/ repository and keeps Claude Code
behavior unchanged.
EOF
}

die() {
  echo "agent.sh: $*" >&2
  exit 1
}

resolve_base_branch() {
  local base
  if ! base=$(_get_base_branch); then
    echo "agent.sh: could not resolve the configured base branch" >&2
    return 1
  fi
  echo "$base"
}

slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g' \
    | sed -E 's/^-+|-+$//g' \
    | cut -c1-60
}

# Reject control characters that would break YAML frontmatter when interpolated.
reject_newlines() {
  case "$2" in
    *$'\n'*|*$'\r'*) die "invalid $1: must not contain newlines" ;;
  esac
}

# Emit a value as a JSON-encoded string (valid YAML), so colons, quotes,
# and other YAML metacharacters in user-supplied values cannot inject keys.
yaml_str() {
  jq -n --arg v "$1" '$v'
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

current_author() {
  local author
  author="$(person_from_state)"
  [ -n "$author" ] || author="$(git -C "$SCRIPT_DIR" config user.name 2>/dev/null | awk '{print tolower($1)}')"
  [ -n "$author" ] || author="agent"
  echo "$author"
}

worktree_for_branch() {
  local branch="$1"
  git -C "$MAIN_PROJECT_DIR" worktree list --porcelain 2>/dev/null | awk -v ref="refs/heads/$branch" '
    $1 == "worktree" { path = $2 }
    $1 == "branch" && $2 == ref { print path; exit }
  '
}

base_ref() {
  local base
  base="$(resolve_base_branch)" || return 1
  git -C "$MAIN_PROJECT_DIR" fetch origin "$base" --quiet 2>/dev/null || true
  if git -C "$MAIN_PROJECT_DIR" show-ref --verify --quiet "refs/remotes/origin/$base" 2>/dev/null; then
    echo "origin/$base"
  elif git -C "$MAIN_PROJECT_DIR" show-ref --verify --quiet "refs/heads/$base" 2>/dev/null; then
    echo "$base"
  else
    echo "agent.sh: configured base branch '$base' does not exist locally or on origin" >&2
    return 1
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
7. Run `bin/agent.sh search "<query>"` to recall shared memory (decisions, handoffs, knowledge) before answering questions about past work.
8. Run `bin/agent.sh branch --topic "<what you are working on>"` before code changes when you need a task branch/worktree.
9. Run `bin/agent.sh save` and `bin/agent.sh wrap` for portable save/wrap flows.

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

cmd_branch() {
  local topic="" author="" branch_type="" slug="" branch="" wt_path="" existing_wt="" base=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --topic|--description) topic="${2:-}"; shift 2 ;;
      --from|--author) author="${2:-}"; shift 2 ;;
      --type) branch_type="${2:-}"; shift 2 ;;
      *) die "unknown branch option: $1" ;;
    esac
  done

  [ -n "$topic" ] || topic="$(date +%Y-%m-%d)"
  [ -n "$author" ] || author="$(current_author)"

  if [ -z "$branch_type" ]; then
    case "$(echo "$topic" | tr '[:upper:]' '[:lower:]')" in
      *fix*|*bug*|*broken*|*crash*) branch_type="bugfix" ;;
      *feature*|*add*|*implement*|*new*) branch_type="feature" ;;
      *) branch_type="dev" ;;
    esac
  fi
  case "$branch_type" in
    dev|feature|bugfix) ;;
    *) die "invalid --type: $branch_type (valid: dev|feature|bugfix)" ;;
  esac

  slug="$(slugify "$topic")"
  [ -n "$slug" ] || slug="$(date +%Y-%m-%d)"
  case "$branch_type" in
    dev) branch="dev/${author}/${slug}" ;;
    feature) branch="feature/${slug}" ;;
    bugfix) branch="bugfix/${slug}" ;;
  esac

  base="$(base_ref)" || die "could not find a safe branch point"

  if [ -f "$SCRIPT_DIR/.git" ]; then
    if git -C "$SCRIPT_DIR" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
      git -C "$SCRIPT_DIR" checkout "$branch" --quiet
    else
      git -C "$SCRIPT_DIR" checkout -b "$branch" "$base" --quiet
    fi
    egregore_link_shared_state "$SCRIPT_DIR" "$MAIN_PROJECT_DIR" >/dev/null 2>/dev/null || true
    echo "branch: $branch"
    echo "worktree: $SCRIPT_DIR"
    return 0
  fi

  existing_wt="$(worktree_for_branch "$branch")"
  if [ -n "$existing_wt" ] && [ -d "$existing_wt" ]; then
    bash "$MAIN_PROJECT_DIR/bin/worktree.sh" setup "$existing_wt" "$MAIN_PROJECT_DIR" >/dev/null 2>/dev/null || true
    echo "branch: $branch"
    echo "worktree: $existing_wt"
    return 0
  fi

  if ! git -C "$MAIN_PROJECT_DIR" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    git -C "$MAIN_PROJECT_DIR" branch "$branch" "$base" >/dev/null 2>&1 || die "failed to create branch $branch"
  fi

  wt_path="$MAIN_PROJECT_DIR/.claude/worktrees/$slug"
  if [ -e "$wt_path" ]; then
    die "worktree path already exists: $wt_path"
  fi

  mkdir -p "$MAIN_PROJECT_DIR/.claude/worktrees"
  git -C "$MAIN_PROJECT_DIR" worktree add "$wt_path" "$branch" --quiet 2>/dev/null || die "failed to create worktree at $wt_path"
  bash "$MAIN_PROJECT_DIR/bin/worktree.sh" setup "$wt_path" "$MAIN_PROJECT_DIR" >/dev/null 2>/dev/null || true

  echo "branch: $branch"
  echo "worktree: $wt_path"
}

ensure_working_branch() {
  local topic="${1:-$(date +%Y-%m-%d)}"
  local author branch slug base
  branch="$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "")"
  case "$branch" in
    dev/*|feature/*|bugfix/*) echo "$branch"; return 0 ;;
  esac

  author="$(current_author)"
  slug="$(slugify "$topic")"
  [ -n "$slug" ] || slug="$(date +%Y-%m-%d)"
  branch="dev/${author}/${slug}"
  base="$(base_ref)" || die "could not find a safe branch point"

  if git -C "$SCRIPT_DIR" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    git -C "$SCRIPT_DIR" checkout "$branch" --quiet || die "failed to checkout $branch"
  else
    git -C "$SCRIPT_DIR" checkout -b "$branch" "$base" --quiet || die "failed to create $branch"
  fi
  echo "$branch"
}

build_pr_body() {
  # Compliant fallback PR body (spec: .claude/context/pr-format.md) built
  # from the commit log + diff when the calling agent supplies none.
  local topic="${1:-portable save}" base commits stat
  base="$(resolve_base_branch)" || return 1
  commits="$(git -C "$SCRIPT_DIR" log --pretty='- %s' "origin/$base..HEAD" 2>/dev/null | head -8)"
  [ -n "$commits" ] || commits="- (commit list unavailable — see the Files tab)"
  stat="$(git -C "$SCRIPT_DIR" diff --shortstat "origin/$base...HEAD" 2>/dev/null | sed 's/^ *//')"
  egregore_pr_skeleton \
    "$commits" \
    "Shell-agent session save — topic: $topic. Body auto-generated by bin/agent.sh; pass --pr-body for a hand-written description." \
    "Not verified — auto-generated skeleton; review the diff before merging.${stat:+ ($stat)}" \
    "🤖 Saved via bin/agent.sh"
}

cmd_save() {
  local message="" topic="" no_pr=0 branch base pushed="false" committed="false" pr_url="" existing_pr="" pr_number="" non_md="" merged="false" pr_body="" pr_body_file=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --message|-m) message="${2:-}"; shift 2 ;;
      --topic) topic="${2:-}"; shift 2 ;;
      --pr-body) pr_body="${2:-}"; shift 2 ;;
      --pr-body-file) pr_body_file="${2:-}"; shift 2 ;;
      --no-pr) no_pr=1; shift ;;
      *) die "unknown save option: $1" ;;
    esac
  done

  [ -n "$topic" ] || topic="portable save"
  [ -n "$message" ] || message="chore(save): $topic"
  base="$(resolve_base_branch)" || die "save stopped before Git changes"

  if [ -d "$MEMORY_DIR" ]; then
    save_memory "$message" "."
    echo "memory: synced"
  fi

  branch="$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "")"
  if [ -n "$(git -C "$SCRIPT_DIR" status --porcelain 2>/dev/null | head -1)" ]; then
    branch="$(ensure_working_branch "$topic")"
    git -C "$SCRIPT_DIR" add -A >/dev/null 2>&1 || die "git add failed"
    if ! git -C "$SCRIPT_DIR" diff --cached --quiet 2>/dev/null; then
      egregore_commit "$SCRIPT_DIR" "$SCRIPT_DIR" "$message" --quiet || die "git commit failed"
      committed="true"
    fi
  fi
  [ -n "$branch" ] || branch="$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || echo "")"

  if [ -n "$branch" ] && git -C "$SCRIPT_DIR" remote get-url origin >/dev/null 2>&1; then
    if git -C "$SCRIPT_DIR" push -u origin "$branch" --quiet 2>/dev/null; then
      pushed="true"
    else
      die "push failed for $branch; commits are safe locally"
    fi
  fi

  if [ "$no_pr" = "0" ] && [ "$pushed" = "true" ] && command -v gh >/dev/null 2>&1; then
    existing_pr="$(gh pr list --head "$branch" --state open --json url --jq '.[0].url // empty' 2>/dev/null || true)"
    if [ -n "$existing_pr" ]; then
      pr_url="$existing_pr"
    else
      if [ -z "$pr_body" ] && [ -n "$pr_body_file" ] && [ -f "$pr_body_file" ]; then
        pr_body="$(cat "$pr_body_file")"
      fi
      [ -n "$pr_body" ] || pr_body="$(build_pr_body "$topic")"
      pr_url="$(gh pr create --base "$base" --head "$branch" --title "${message%%$'\n'*}" --body "$pr_body" 2>/dev/null || true)"
    fi
  fi

  # Non-coding saves auto-merge to the configured base (same rule as /save and the
  # handoff helper; policy in bin/lib/noncode.sh). `--auto` needs repo
  # auto-merge + pending required checks; without branch protection it always
  # errors, so fall back to a direct merge.
  if [ -n "$pr_url" ]; then
    # shellcheck source=bin/lib/noncode.sh
    . "$SCRIPT_DIR/bin/lib/noncode.sh" 2>/dev/null || true
    type noncode_blockers >/dev/null 2>&1 || noncode_blockers() {
      git -C "${2:-.}" diff "${1:-origin/$base}...HEAD" --name-only 2>/dev/null | grep -v '\.md$' | head -1 || true
    }
    pr_number="${pr_url##*/}"
    non_code="$(noncode_blockers "origin/$base" "$SCRIPT_DIR")"
    if [ -z "$non_code" ] && [ -n "$pr_number" ]; then
      if gh pr merge "$pr_number" --auto --merge >/dev/null 2>&1 \
         || gh pr merge "$pr_number" --merge >/dev/null 2>&1; then
        merged="true"
      fi
    fi
  fi

  echo "branch: ${branch:-none}"
  echo "commit: $committed"
  echo "push: $pushed"
  [ -n "$pr_url" ] && echo "pr: $pr_url"
  [ "$merged" = "true" ] && echo "merge: non-coding, merged to $base"
  return 0
}

cmd_wrap() {
  ensure_memory
  local from="" topic="" summary="" body="" body_file="" no_push=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --topic) topic="${2:-}"; shift 2 ;;
      --summary) summary="${2:-}"; shift 2 ;;
      --body) body="${2:-}"; shift 2 ;;
      --body-file) body_file="${2:-}"; shift 2 ;;
      --no-push) no_push=1; shift ;;
      *) die "unknown wrap option: $1" ;;
    esac
  done

  [ -n "$from" ] || from="$(current_author)"
  [ -n "$topic" ] || die "wrap requires --topic"
  [ -n "$summary" ] || die "wrap requires --summary"
  if [ -n "$body_file" ]; then
    [ -f "$body_file" ] || die "body file not found: $body_file"
    body="$(cat "$body_file")"
  elif [ -z "$body" ] && [ ! -t 0 ]; then
    body="$(cat)"
  fi
  [ -n "$body" ] || body="$summary"

  local tmpd result rel session_id branch
  local capture_args=(--mode personal)
  tmpd="$(mktemp -d -t egregore-agent-wrap-XXXXXX)"
  trap 'rm -rf "$tmpd"' RETURN
  session_id="$(cat "$SCRIPT_DIR/.egregore-session-id" 2>/dev/null || true)"
  branch="$(git -C "$SCRIPT_DIR" branch --show-current 2>/dev/null || true)"
  [ "$no_push" = "1" ] && capture_args+=(--no-push)

  printf '%s\n' "$body" |
    TMPDIR="$tmpd" bash "$SCRIPT_DIR/bin/capture-run.sh" \
      "${capture_args[@]}" \
      --author "$from" \
      --topic "$topic" \
      --summary "$summary" \
      --session-id "$session_id" \
      --branch "$branch" >/dev/null

  result="$tmpd/capture-run-result.json"
  rel="$(jq -r '.file // empty' "$result" 2>/dev/null || true)"
  [ -n "$rel" ] || die "wrap was not created"
  echo "wrap: memory/$rel"

  # Session close: non-coding core-repo changes save + merge themselves
  # (gated inside session-autosave.sh — code is never auto-committed).
  if [ "$no_push" = "0" ]; then
    ( bash "$SCRIPT_DIR/bin/session-autosave.sh" --dir "$SCRIPT_DIR" >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
}

cmd_handoff() {
  ensure_memory
  local from="" to="" topic="" body="" body_file="" project="" intent="action"
  local no_publish=0 no_notify=0 json=0 body_supplied=0 content_mode="generated"
  NO_PUSH=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --to) to="${2:-}"; shift 2 ;;
      --topic) topic="${2:-}"; shift 2 ;;
      --body) body="${2:-}"; shift 2 ;;
      --body-file) body_file="${2:-}"; shift 2 ;;
      --project) project="${2:-}"; shift 2 ;;
      --intent) intent="${2:-}"; shift 2 ;;
      --no-push) NO_PUSH=1; shift ;;
      --no-publish) no_publish=1; shift ;;
      --no-notify) no_notify=1; shift ;;
      --json) json=1; shift ;;
      *) die "unknown handoff option: $1" ;;
    esac
  done

  [ -z "$from" ] && from="$(person_from_state)"
  [ -n "$from" ] || die "handoff requires --from"
  [ -n "$topic" ] || die "handoff requires --topic"
  case "$intent" in
    action|feedback|fyi) ;;
    *) die "invalid --intent: $intent (action|feedback|fyi)" ;;
  esac
  if [ -n "$body_file" ]; then
    [ -f "$body_file" ] || die "body file not found: $body_file"
    body="$(cat "$body_file")"
    body_supplied=1
  elif [ -z "$body" ] && [ ! -t 0 ]; then
    body="$(cat)"
    [ -n "$body" ] && body_supplied=1
  elif [ -n "$body" ]; then
    body_supplied=1
  fi
  [ "$body_supplied" = "1" ] && content_mode="supplied"

  local today tmpd result result_out rel stdout_file
  local handoff_args=()
  today="$(date +%Y-%m-%d)"
  tmpd="$(mktemp -d -t egregore-agent-handoff-XXXXXX)"
  trap 'rm -rf "$tmpd"' RETURN
  result_out="$(mktemp -t egregore-agent-handoff-result-XXXXXX.json)"
  stdout_file="$tmpd/stdout"

  [ -n "$to" ] && handoff_args+=(--recipient "$to")
  [ -n "$project" ] && handoff_args+=(--project "$project")
  handoff_args+=(--intent "$intent" --content-mode "$content_mode")
  [ "$content_mode" = "generated" ] && handoff_args+=(--include-session-artifacts)
  [ "$NO_PUSH" = "1" ] && handoff_args+=(--no-push)
  [ "$no_publish" = "1" ] && handoff_args+=(--no-publish)
  [ "$no_notify" = "1" ] && handoff_args+=(--no-notify)

  {
    printf '%s\n' '---'
    printf 'capture_schema: egregore-capture/v1\n'
    printf 'capture_mode: addressed\n'
    printf 'kind: addressed\n'
    printf 'content_mode: %s\n' "$content_mode"
    printf 'from: %s\n' "$(yaml_str "$from")"
    [ -n "$to" ] && printf 'addressed_to: %s\n' "$(yaml_str "$to")"
    printf 'date: %s\n' "$today"
    printf 'topic: %s\n' "$(yaml_str "$topic")"
    printf 'intent: %s\n' "$intent"
    [ -n "$project" ] && printf 'project: %s\n' "$(yaml_str "$project")"
    printf '%s\n\n' '---'
    if [ "$content_mode" = "supplied" ]; then
      printf '%s\n' "$body"
    else
      printf '# Handoff: %s\n\n' "$topic"
      printf '## Briefing\n\nNo briefing was supplied.\n\n'
      printf '## Next Steps\n\n1. Continue from this handoff using the shared Egregore memory protocol.\n'
    fi
  } | TMPDIR="$tmpd" bash "$SCRIPT_DIR/bin/capture-run.sh" \
        --mode addressed \
        --author "$from" \
        --topic "$topic" \
        "${handoff_args[@]}" \
        > "$stdout_file"

  result="$tmpd/handoff-run-result.json"
  rel="$(jq -r '.file // empty' "$result" 2>/dev/null || true)"
  [ -n "$rel" ] || die "handoff was not created"
  cp "$result" "$result_out"
  if [ "$json" = "1" ]; then
    cat "$result_out"
    return 0
  fi
  [ -s "$stdout_file" ] && sed 's/^/status: /' "$stdout_file"
  echo "handoff: memory/$rel"
  echo "result: $result_out"

  # Parity with the Claude /handoff skill: save core-repo session work in the
  # background (non-coding diffs auto-merge to the configured base; code stays
  # in a PR).
  if [ "$NO_PUSH" = "0" ]; then
    ( bash "$SCRIPT_DIR/bin/handoff-save-egregore.sh" "$from" "$topic" --repo-dir "$SCRIPT_DIR" >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
}

cmd_ask() {
  ensure_memory
  local from="" to="" topic="" question=""
  local harvest_id="" harvest_session_id="" turn="" question_intent="" context_mode=""
  NO_PUSH=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --to) to="${2:-}"; shift 2 ;;
      --topic) topic="${2:-}"; shift 2 ;;
      --question) question="${2:-}"; shift 2 ;;
      --harvest-id) harvest_id="${2:-}"; shift 2 ;;
      --harvest-session-id) harvest_session_id="${2:-}"; shift 2 ;;
      --turn) turn="${2:-}"; shift 2 ;;
      --question-intent) question_intent="${2:-}"; shift 2 ;;
      --context-mode) context_mode="${2:-}"; shift 2 ;;
      --no-push) NO_PUSH=1; shift ;;
      *) die "unknown ask option: $1" ;;
    esac
  done

  [ -z "$from" ] && from="$(person_from_state)"
  [ -n "$from" ] || die "ask requires --from"
  [ -n "$to" ] || die "ask requires --to"
  [ -n "$topic" ] || die "ask requires --topic"
  [ -n "$question" ] || die "ask requires --question"

  if [ -n "$context_mode" ]; then
    case "$context_mode" in
      blind|disclosed|comparative) ;;
      *) die "invalid --context-mode: $context_mode (valid: blind|disclosed|comparative)" ;;
    esac
  fi

  if [ -n "$turn" ]; then
    case "$turn" in
      ''|*[!0-9]*) die "invalid --turn: must be a non-negative integer" ;;
    esac
  fi

  reject_newlines "--from"               "$from"
  reject_newlines "--to"                 "$to"
  reject_newlines "--topic"              "$topic"
  reject_newlines "--question"           "$question"
  reject_newlines "--harvest-id"         "$harvest_id"
  reject_newlines "--harvest-session-id" "$harvest_session_id"
  reject_newlines "--question-intent"    "$question_intent"

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

  {
    echo "---"
    echo "from: $from"
    echo "to: $to"
    echo "topic: $topic"
    echo "status: pending"
    echo "created: $now"
    [ -n "$harvest_id" ]         && echo "harvest_id: $(yaml_str "$harvest_id")"
    [ -n "$harvest_session_id" ] && echo "harvest_session_id: $(yaml_str "$harvest_session_id")"
    [ -n "$turn" ]               && echo "turn: $turn"
    [ -n "$question_intent" ]    && echo "question_intent: $(yaml_str "$question_intent")"
    [ -n "$context_mode" ]       && echo "context_mode: $context_mode"
    echo "---"
    echo ""
    echo "## Questions"
    echo ""
    echo "- $question"
  } > "$abs"

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

cmd_search() {
  bash "$SCRIPT_DIR/bin/search.sh" query "$@"
}

case "${1:-}" in
  --help|-h|help|"") usage ;;
  protocol) shift; cmd_protocol "$@" ;;
  sync) shift; cmd_sync "$@" ;;
  activity) shift; cmd_activity "$@" ;;
  search) shift; cmd_search "$@" ;;
  people) shift; cmd_people "$@" ;;
  branch) shift; cmd_branch "$@" ;;
  save) shift; cmd_save "$@" ;;
  autosave) shift; bash "$SCRIPT_DIR/bin/autosave.sh" "$@" ;;
  wrap) shift; cmd_wrap "$@" ;;
  handoff) shift; cmd_handoff "$@" ;;
  ask) shift; cmd_ask "$@" ;;
  answer) shift; cmd_answer "$@" ;;
  *) die "unknown command: $1" ;;
esac
