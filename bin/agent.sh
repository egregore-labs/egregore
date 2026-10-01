#!/usr/bin/env bash
# Runtime-neutral Egregore agent bridge.
#
# This script exposes the Git-backed memory protocol without requiring
# Claude Code hooks or slash-command skills. Any agent runtime that can run
# shell commands inside an Egregore checkout can use it to sync memory,
# create handoffs, ask questions, answer questions, and inspect activity.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/scratch.sh"
MAIN_PROJECT_DIR="$SCRIPT_DIR"
if [ -f "$SCRIPT_DIR/.git" ]; then
  WT_GITDIR=$(sed 's/^gitdir: //' "$SCRIPT_DIR/.git" 2>/dev/null || true)
  [ -n "$WT_GITDIR" ] && MAIN_PROJECT_DIR=$(cd "$WT_GITDIR/../../.." 2>/dev/null && pwd || echo "$SCRIPT_DIR")
fi
if [ -f "$SCRIPT_DIR/bin/lib/worktree-links.sh" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/bin/lib/worktree-links.sh" >/dev/null 2>/dev/null || true
  egregore_link_shared_state "$SCRIPT_DIR" "$MAIN_PROJECT_DIR" >/dev/null 2>/dev/null || true
fi
# Read by the sourced bin/lib/config.sh helpers.
# shellcheck disable=SC2034
CONFIG="$SCRIPT_DIR/egregore.json"
MEMORY_DIR="${EGREGORE_MEMORY_DIR:-$SCRIPT_DIR/memory}"
if [ -f "$SCRIPT_DIR/bin/lib/config.sh" ]; then
  # shellcheck source=/dev/null
  source "$SCRIPT_DIR/bin/lib/config.sh"
fi
# Shared commit/PR message mechanics (trailers + skeleton body shape).
# shellcheck source=/dev/null
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
  save [--message TEXT] [--pr-body TEXT|--pr-body-file PATH] [--draft|--ready]
                                   Commit and push current repo + memory changes;
                                   PR body follows .claude/context/pr-format.md
                                   (auto-generated skeleton if not provided);
                                   new code PRs stay draft until --ready
  autosave [status|on|off|scope|publish|merge]  Personal ambient-save settings + consent
  wrap --topic T --summary TEXT    Write a session wrap to memory/wraps
  handoff --from A --to B --topic T [--intent action|feedback|fyi]
      [--body TEXT|--body-file PATH] [--no-push] [--no-publish] [--no-notify] [--json]
  ask --from A --to B [--to-actor-id ID] --topic T --question TEXT [--no-push]
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

# Record the workspace topic and branch on the session's graph node. Detached
# and fail-soft; the same write bin/worktree-create.sh makes for Claude Code,
# so every runtime's branch path leaves the Session node named without the
# model having to run anything (the by-hand step was silently dead under the
# worktree parser, 2026-09-10). graph-op.sh prefers the calling checkout's
# session receipt before falling back to the shared session file.
record_session_topic() {
  local topic="$1" branch="$2" root="$3"
  [ -x "$root/bin/graph-op.sh" ] || return 0
  [ -e "$root/.egregore-session-id" ] || return 0
  ( nohup bash "$root/bin/graph-op.sh" set-current-topic "$topic" "$branch" >/dev/null 2>&1 & ) 2>/dev/null
  return 0
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

clear_base_upstream() {
  local repo="$1" branch="$2" base="$3" upstream=""
  case "$branch" in dev/*|feature/*|bugfix/*) ;; *) return 0 ;; esac
  upstream="$(git -C "$repo" rev-parse --abbrev-ref "${branch}@{upstream}" 2>/dev/null || true)"
  if [ "$upstream" = "$base" ]; then
    git -C "$repo" branch --unset-upstream "$branch" >/dev/null 2>&1 || true
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
  ensure_memory
  EGREGORE_ROOT="$SCRIPT_DIR" \
    PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m egregore_runtime.harness_cli sync
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
  local lifecycle_args=(scan --managed-only)
  [ -n "$for_person" ] && lifecycle_args+=(--user "$for_person")
  EGREGORE_ROOT="$SCRIPT_DIR" EGREGORE_LIFECYCLE_PUSH=0 \
    PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m egregore_runtime.lifecycle_cli "${lifecycle_args[@]}" 2>/dev/null |
    jq -r --argjson limit "$limit" '
      .items[:$limit][]?
      | "- \(.from) -> \(.to // "team") [\(.status)]: \(.topic) (\(.filePath))"
    ' || true

  echo
  echo "Questions"
  EGREGORE_ROOT="$SCRIPT_DIR" bash "$SCRIPT_DIR/bin/question.sh" pending \
    --limit "$limit" 2>/dev/null |
    jq -r '.questions[]? | "- \(.sender) -> \(.recipient) [pending]: \(.topic) (\(.canonical_path))"' || true
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
      git -C "$SCRIPT_DIR" checkout --no-track -b "$branch" "$base" --quiet
    fi
    clear_base_upstream "$SCRIPT_DIR" "$branch" "$base"
    egregore_link_shared_state "$SCRIPT_DIR" "$MAIN_PROJECT_DIR" >/dev/null 2>/dev/null || true
    record_session_topic "$topic" "$branch" "$SCRIPT_DIR"
    echo "branch: $branch"
    echo "worktree: $SCRIPT_DIR"
    return 0
  fi

  existing_wt="$(worktree_for_branch "$branch")"
  if [ -n "$existing_wt" ] && [ -d "$existing_wt" ]; then
    bash "$MAIN_PROJECT_DIR/bin/worktree.sh" setup "$existing_wt" "$MAIN_PROJECT_DIR" >/dev/null 2>/dev/null || true
    record_session_topic "$topic" "$branch" "$MAIN_PROJECT_DIR"
    echo "branch: $branch"
    echo "worktree: $existing_wt"
    return 0
  fi

  if ! git -C "$MAIN_PROJECT_DIR" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    git -C "$MAIN_PROJECT_DIR" branch --no-track "$branch" "$base" >/dev/null 2>&1 || die "failed to create branch $branch"
  fi
  clear_base_upstream "$MAIN_PROJECT_DIR" "$branch" "$base"

  wt_path="$MAIN_PROJECT_DIR/.claude/worktrees/$slug"
  if [ -e "$wt_path" ]; then
    die "worktree path already exists: $wt_path"
  fi

  mkdir -p "$MAIN_PROJECT_DIR/.claude/worktrees"
  git -C "$MAIN_PROJECT_DIR" worktree add "$wt_path" "$branch" --quiet 2>/dev/null || die "failed to create worktree at $wt_path"
  bash "$MAIN_PROJECT_DIR/bin/worktree.sh" setup "$wt_path" "$MAIN_PROJECT_DIR" >/dev/null 2>/dev/null || true
  record_session_topic "$topic" "$branch" "$MAIN_PROJECT_DIR"

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
    git -C "$SCRIPT_DIR" checkout --no-track -b "$branch" "$base" --quiet || die "failed to create $branch"
  fi
  clear_base_upstream "$SCRIPT_DIR" "$branch" "$base"
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
  local message="" topic="" no_pr=0 branch base pushed="false" committed="false" pr_url="" existing_pr="" pr_number="" merged="false" pr_body="" pr_body_file=""
  local readiness="" pr_draft="" changed_paths="" non_code="" use_pr=0
  local -a create_args

  while [ $# -gt 0 ]; do
    case "$1" in
      --message|-m) message="${2:-}"; shift 2 ;;
      --topic) topic="${2:-}"; shift 2 ;;
      --pr-body) pr_body="${2:-}"; shift 2 ;;
      --pr-body-file) pr_body_file="${2:-}"; shift 2 ;;
      --no-pr) no_pr=1; shift ;;
      --draft|--ready)
        [ -z "$readiness" ] || [ "$readiness" = "$1" ] || die "--draft and --ready cannot be combined"
        readiness="$1"; shift ;;
      *) die "unknown save option: $1" ;;
    esac
  done

  [ "$no_pr" = "0" ] || [ -z "$readiness" ] || die "--no-pr cannot be combined with --draft or --ready"
  [ -n "$topic" ] || topic="portable save"
  [ -n "$message" ] || message="chore(save): $topic"
  base="$(resolve_base_branch)" || die "save stopped before Git changes"

  # Shared invariant across harnesses, before memory or project mutations.
  # Installed public instances intentionally omit the development engine.
  if [ -f "$SCRIPT_DIR/bin/capability-distribution.mjs" ] && [ -f "$SCRIPT_DIR/capability-distribution.json" ]; then
    if [ "${EGREGORE_SKILL_REVIEW:-1}" = "0" ]; then
      echo "Skill review: disabled (EGREGORE_SKILL_REVIEW=0)."
    else
      # Advisory only: a missing comparison base remains visible, while the
      # established save invariants below retain their own blocking policy.
      bash "$SCRIPT_DIR/bin/node-run.sh" "$SCRIPT_DIR/bin/capability-distribution.mjs" skill-references \
        --root "$SCRIPT_DIR" --changed --base "origin/$base" --review \
        || echo "Skill review unavailable; save continues without an affected-skill receipt." >&2
    fi
    bash "$SCRIPT_DIR/bin/node-run.sh" "$SCRIPT_DIR/bin/capability-distribution.mjs" validate --root "$SCRIPT_DIR" || die "distribution validation failed"
    bash "$SCRIPT_DIR/bin/node-run.sh" "$SCRIPT_DIR/bin/capability-distribution.mjs" changes --root "$SCRIPT_DIR" --base "origin/$base" --json || die "distribution change check failed"
    bash "$SCRIPT_DIR/bin/node-run.sh" "$SCRIPT_DIR/bin/capability-distribution.mjs" runtime-skill-audit --root "$SCRIPT_DIR" --strict-contract || die "runtime skill contract failed"

  fi

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
    if [ "$no_pr" = "0" ]; then
      command -v gh >/dev/null 2>&1 || die "GitHub CLI is required to save a PR; use --no-pr to push only"
      use_pr=1
      # Classify the complete branch diff, including commits saved earlier.
      # An unavailable comparison must never look like safe non-code work.
      changed_paths="$(git -C "$SCRIPT_DIR" diff "origin/$base...HEAD" --name-only)" \
        || die "could not classify changes against origin/$base; push stopped"
      # shellcheck source=/dev/null
      . "$SCRIPT_DIR/bin/lib/noncode.sh" 2>/dev/null || true
      type noncode_filter >/dev/null 2>&1 || noncode_filter() {
        grep -v '\.md$' | head -1 || true
      }
      non_code="$(printf '%s\n' "$changed_paths" | noncode_filter)"
      existing_pr="$(cd "$SCRIPT_DIR" && gh pr list --head "$branch" --state open --json url,number,isDraft)" \
        || die "could not read PR state; push stopped"
      printf '%s' "$existing_pr" | jq -e '
        type == "array" and length <= 1 and all(.[];
          (.url | type == "string" and length > 0) and
          (.number | type == "number") and (.isDraft | type == "boolean"))
      ' >/dev/null 2>&1 || die "invalid or ambiguous PR state; push stopped"
      pr_url="$(printf '%s' "$existing_pr" | jq -r '.[0].url // empty')"
      if [ -n "$pr_url" ]; then
        pr_number="$(printf '%s' "$existing_pr" | jq -r '.[0].number')"
        pr_draft="$(printf '%s' "$existing_pr" | jq -r '.[0].isDraft')"
        # Convert before push: a synchronize event must already see the draft.
        if [ "$readiness" = "--draft" ] && [ "$pr_draft" = "false" ]; then
          (cd "$SCRIPT_DIR" && gh pr ready "$pr_number" --undo) \
            || die "could not convert PR to draft; push stopped"
          pr_draft="true"
        fi
      fi
    fi
    if git -C "$SCRIPT_DIR" push -u origin "$branch" --quiet 2>/dev/null; then
      pushed="true"
    else
      die "push failed for $branch; commits are safe locally"
    fi
  elif [ -n "$readiness" ]; then
    die "cannot set PR readiness without a branch and origin remote; commits are safe locally"
  fi

  if [ "$use_pr" = "1" ] && [ "$pushed" = "true" ]; then
    if [ -n "$pr_url" ]; then
      # Readiness follows the successful push so CI sees the newly saved head.
      if [ "$readiness" = "--ready" ] && [ "$pr_draft" = "true" ]; then
        (cd "$SCRIPT_DIR" && gh pr ready "$pr_number") \
          || die "push succeeded but could not confirm PR readiness; check its state before retrying"
        pr_draft="false"
      fi
    else
      if [ -z "$pr_body" ] && [ -n "$pr_body_file" ]; then
        [ -f "$pr_body_file" ] || die "push succeeded but PR body file is missing: $pr_body_file"
        pr_body="$(cat "$pr_body_file")"
      fi
      [ -n "$pr_body" ] || pr_body="$(build_pr_body "$topic")"
      pr_draft="false"
      create_args=(--base "$base" --head "$branch" --title "${message%%$'\n'*}" --body "$pr_body")
      if [ "$readiness" = "--draft" ] || { [ -z "$readiness" ] && [ -n "$non_code" ]; }; then
        pr_draft="true"
        create_args+=(--draft)
      fi
      pr_url="$(cd "$SCRIPT_DIR" && gh pr create "${create_args[@]}")" \
        || die "push succeeded but PR creation failed"
      [ -n "$pr_url" ] || die "push succeeded but PR creation returned no URL"
      pr_number="${pr_url##*/}"
    fi
  fi

  # Preserve non-code auto-merge, but never merge a deliberately draft PR.
  # `--auto` requires repository support; direct merge is the existing fallback.
  if [ -n "$pr_url" ] && [ "$pr_draft" = "false" ] && [ -z "$non_code" ]; then
    if (cd "$SCRIPT_DIR" && gh pr merge "$pr_number" --auto --merge) >/dev/null 2>&1 \
       || (cd "$SCRIPT_DIR" && gh pr merge "$pr_number" --merge) >/dev/null 2>&1; then
      merged="true"
    fi
  fi

  echo "branch: ${branch:-none}"
  echo "commit: $committed"
  echo "push: $pushed"
  [ -n "$pr_url" ] && echo "pr: $pr_url"
  [ -n "$pr_draft" ] && echo "pr-draft: $pr_draft"
  [ "$merged" = "true" ] && echo "merge: non-coding, merged to $base"
  return 0
}

# Deterministic wrap result card — the visible product surface of a wrap.
# Pure renderer: no writes, callable standalone (wrap-card) for tests.
render_wrap_card() {
  local actor="" topic="" summary="" threads="0" path="" save=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --actor) actor="${2:-}"; shift 2 ;;
      --topic) topic="${2:-}"; shift 2 ;;
      --summary) summary="${2:-}"; shift 2 ;;
      --threads) threads="${2:-0}"; shift 2 ;;
      --path) path="${2:-}"; shift 2 ;;
      --save) save="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  local rule="──────────────────────────────────────────────────────────"
  printf '┌%s\n' "$rule"
  printf '│ EGREGORE ✦ SESSION WRAPPED\n'
  printf '├%s\n' "$rule"
  printf '│ actor    %s\n' "$actor"
  printf '│ topic    %s\n' "$topic"
  printf '%s\n' "$summary" | fold -s -w 48 | sed '1s/^/│ summary  /; 2,$s/^/│          /'
  printf '│ threads  %s open\n' "$threads"
  printf '│ path     %s\n' "$path"
  [ -n "$save" ] && printf '│ save     %s\n' "$save"
  printf '└%s\n' "$rule"
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
    scratch_consume "$body_file"
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
    TMPDIR="$tmpd" bash "$SCRIPT_DIR/bin/artifact-writeback.sh" capture \
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

  local open_threads save_line
  open_threads="$(printf '%s\n' "$body" | grep -c '^\- \[ \]' 2>/dev/null || echo 0)"
  if [ "$no_push" = "1" ]; then
    save_line="✓ canonical writeback · push skipped (--no-push)"
  else
    save_line="✓ canonical writeback · session autosave sweeping in background"
  fi
  render_wrap_card \
    --actor "$from" \
    --topic "$topic" \
    --summary "$summary" \
    --threads "$open_threads" \
    --path "memory/$rel" \
    --save "$save_line"

  # Session close: non-coding core-repo changes save + merge themselves
  # (gated inside session-autosave.sh — code is never auto-committed).
  if [ "$no_push" = "0" ]; then
    ( bash "$SCRIPT_DIR/bin/session-autosave.sh" --dir "$SCRIPT_DIR" >/dev/null 2>&1 & ) >/dev/null 2>&1
  fi
  bash "$SCRIPT_DIR/bin/scratch-sweep.sh" || true
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
    scratch_consume "$body_file"
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
  } | TMPDIR="$tmpd" bash "$SCRIPT_DIR/bin/artifact-writeback.sh" capture \
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
  local from="" to="" to_actor_id="" topic="" question=""
  local harvest_id="" harvest_session_id="" turn="" question_intent="" context_mode=""
  NO_PUSH=0

  while [ $# -gt 0 ]; do
    case "$1" in
      --from) from="${2:-}"; shift 2 ;;
      --to) to="${2:-}"; shift 2 ;;
      --to-actor-id) to_actor_id="${2:-}"; shift 2 ;;
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
  reject_newlines "--to-actor-id"        "$to_actor_id"
  reject_newlines "--topic"              "$topic"
  reject_newlines "--question"           "$question"
  reject_newlines "--harvest-id"         "$harvest_id"
  reject_newlines "--harvest-session-id" "$harvest_session_id"
  reject_newlines "--question-intent"    "$question_intent"

  local -a question_args
  question_args=(create --from "$from" --to "$to" --topic "$topic" --question "$question")
  [ -n "$to_actor_id" ] && question_args+=(--to-actor-id "$to_actor_id")
  [ -n "$harvest_id" ] && question_args+=(--harvest-id "$harvest_id")
  [ -n "$harvest_session_id" ] && question_args+=(--harvest-session-id "$harvest_session_id")
  [ -n "$turn" ] && question_args+=(--turn "$turn")
  [ -n "$question_intent" ] && question_args+=(--question-intent "$question_intent")
  [ -n "$context_mode" ] && question_args+=(--context-mode "$context_mode")
  [ "$NO_PUSH" = "1" ] && question_args+=(--no-push)

  local receipt
  receipt="$(bash "$SCRIPT_DIR/bin/question.sh" "${question_args[@]}")"
  echo "question: $(printf '%s' "$receipt" | jq -r '.canonical_path')"
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

  local -a question_args
  question_args=(answer --from "$from" --question "$question_path" --body "$body")
  [ "$NO_PUSH" = "1" ] && question_args+=(--no-push)
  local receipt
  receipt="$(bash "$SCRIPT_DIR/bin/question.sh" "${question_args[@]}")"
  echo "answered: $(printf '%s' "$receipt" | jq -r '.canonical_path')"
}

cmd_search() {
  bash "$SCRIPT_DIR/bin/search.sh" query "$@"
}

# The observation covers the save transaction's process boundary, including
# validation/rendering errors. It does not claim the broader user task or
# skill completed. Optional telemetry cannot alter the command exit.
_operation_observation() {
  EGREGORE_ROOT="$SCRIPT_DIR" PYTHONSAFEPATH=1 PYTHONPATH="$SCRIPT_DIR${PYTHONPATH:+:$PYTHONPATH}" \
    python3 -m egregore_runtime.operation_cli "$@" 2>/dev/null || true
}
if [ "${1:-}" = "save" ] && [ -f "$SCRIPT_DIR/egregore_runtime/operation_cli.py" ] && \
   [ -z "$(trap -p EXIT INT TERM HUP)" ]; then
  _observed_operation_id="$(_operation_observation start --operation save)"
  # An explicit caller ID belongs to this invocation, not nested operations.
  unset EGREGORE_OPERATION_ID
  if [ -n "$_observed_operation_id" ]; then
    # The trap captures _observed_exit before its subsequent references.
    # shellcheck disable=SC2154
    trap '_observed_exit=$?; _operation_observation finish --operation save --invocation-id "$_observed_operation_id" --exit-status "$_observed_exit" >/dev/null; exit "$_observed_exit"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
  fi
fi

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
  wrap-card) shift; render_wrap_card "$@" ;;
  handoff) shift; cmd_handoff "$@" ;;
  ask) shift; cmd_ask "$@" ;;
  answer) shift; cmd_answer "$@" ;;
  *) die "unknown command: $1" ;;
esac
