#!/usr/bin/env bash
set -euo pipefail
# Repository selection belongs to this script, never to inherited Git overrides.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# Sync this checkout with its configured base and shared memory through Runtime.
# Usage: bash bin/pull.sh [--json]
# Exit 0 = report printed (including an unchanged or dirty branch)
# Exit 1 = failed fetch, conflict, memory sync failure, or unavailable memory checkout
# Exit 2 = invalid arguments, not a Git checkout, or unresolved base

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
json=false
case "$#:${1:-}" in
  0:) ;;
  1:--json) json=true ;;
  *) echo 'pull: usage: bash bin/pull.sh [--json]' >&2; exit 2 ;;
esac

if ! command -v git >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo 'pull: git and jq are required' >&2
  exit 2
fi
if [ "$(git -C "$SCRIPT_DIR" rev-parse --is-inside-work-tree 2>/dev/null || true)" != true ]; then
  echo 'pull: not a git checkout' >&2
  exit 2
fi
base=$(bash "$SCRIPT_DIR/bin/base-branch.sh") || exit 2
base_ref="origin/$base"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/pull.XXXXXX") || {
  echo 'pull: cannot create scratch directory' >&2
  exit 2
}
trap 'rm -rf "$scratch"' EXIT
: > "$scratch/files"
result=0
base_action=up-to-date

# Fetch the remote-tracking ref without moving a branch in any other worktree.
before=$(git -C "$SCRIPT_DIR" rev-parse --verify --quiet "$base_ref" || true)
if ! git -C "$SCRIPT_DIR" fetch origin "+refs/heads/$base:refs/remotes/origin/$base" --quiet > "$scratch/fetch" 2>&1; then
  echo 'pull: fetch failed' >&2
  base_action=fetch-failed
  result=1
fi
after=$(git -C "$SCRIPT_DIR" rev-parse --verify --quiet "$base_ref" || true)
if [ -z "$after" ]; then
  echo "pull: $base_ref not found" >&2
  exit 2
fi
base_new=0
if [ -n "$before" ]; then
  base_new=$(git -C "$SCRIPT_DIR" rev-list --count "$before..$after")
fi
if [ "$base_action" != fetch-failed ] && [ "$base_new" -gt 0 ]; then
  base_action=synced
fi

ignored_overwrites() {
  # NUL-delimited paths preserve spaces, tabs, and Git's unquoted filenames.
  # Rename/copy destinations are new paths too; do not hide them as R/C entries.
  git -C "$SCRIPT_DIR" diff --no-renames --name-only --diff-filter=A -z "HEAD...$base_ref" > "$scratch/added" || return 1
  git -C "$SCRIPT_DIR" ls-files --others --ignored --exclude-standard -z > "$scratch/ignored" || return 1
  jq -nr --rawfile added "$scratch/added" --rawfile ignored "$scratch/ignored" '
    ($added | split("\u0000") | map(select(length > 0))) as $incoming
    | $ignored | split("\u0000") | map(select(length > 0))
    | map(select(. as $path | $incoming | index($path))) | join(", ")'
}

branch=$(git -C "$SCRIPT_DIR" branch --show-current)
branch_action=skipped
branch_note=""
if [ -z "$branch" ]; then
  branch=HEAD
  branch_note='detached HEAD'
elif [ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=no)" ]; then
  branch_note='uncommitted changes; branch not rebased'
elif git -C "$SCRIPT_DIR" merge-base --is-ancestor "$base_ref" HEAD; then
  branch_action=up-to-date
elif [ "$branch" = "$base" ]; then
  if git -C "$SCRIPT_DIR" merge --ff-only --no-squash --commit --no-overwrite-ignore "$base_ref" --quiet > "$scratch/branch" 2>&1; then
    branch_action=fast-forwarded
  elif ignored_paths=$(ignored_overwrites) && [ -n "$ignored_paths" ]; then
    branch_note="ignored files would be overwritten: $ignored_paths"
  else
    branch_note="diverged from $base_ref"
  fi
else
  case "$branch" in
    dev/*|feature/*|bugfix/*)
      if ! ignored_paths=$(ignored_overwrites); then
        branch_note='cannot check ignored files; branch not rebased'
        result=1
      elif [ -n "$ignored_paths" ]; then
        branch_note="ignored files would be overwritten: $ignored_paths"
      elif git -C "$SCRIPT_DIR" -c rebase.updateRefs=false rebase --quiet "$base_ref" > "$scratch/branch" 2>&1; then
        branch_action=rebased
      elif ! git -C "$SCRIPT_DIR" rebase --abort >> "$scratch/branch" 2>&1; then
        branch_action=conflict
        branch_note='rebase abort failed; resolve by hand'
        result=1
      elif git -C "$SCRIPT_DIR" -c merge.ff=true merge --ff --no-edit --commit --no-squash --no-overwrite-ignore \
        -m "Sync with $base" "$base_ref" >> "$scratch/branch" 2>&1; then
        branch_action=merged
      else
        branch_action=conflict
        branch_note='resolve by hand; tree restored'
        if ! git -C "$SCRIPT_DIR" merge --abort >> "$scratch/branch" 2>&1; then
          branch_note='merge abort failed; resolve by hand'
        fi
        result=1
      fi
      ;;
    *) branch_note='not a task branch' ;;
  esac
fi

memory_path="$SCRIPT_DIR/memory"
memory_action=skipped
memory_note=""
memory_new=0
linked_target=""

sync_memory() {
  local memory_repo memory_dir common_dir main_checkout main_parent target physical_memory memory_root
  local memory_before memory_after status file old_file
  if ! memory_repo=$(jq -r '.memory_repo // empty' "$SCRIPT_DIR/egregore.json" 2> "$scratch/config"); then
    memory_action=failed
    memory_note='cannot read memory_repo from egregore.json'
    result=1
    return
  fi
  if [ -z "$memory_repo" ]; then
    memory_note='no memory_repo configured'
    return
  fi
  memory_dir=$(basename "$memory_repo" .git)
  case "$memory_dir" in
    ''|.|..|*[!A-Za-z0-9._-]*)
      memory_action=unlinked
      memory_note='invalid memory_repo'
      result=1
      return
      ;;
  esac
  # Basename alone hides traversal components such as ../../etc.
  case "$memory_repo" in
    ../*|*/../*|*/..)
      memory_action=unlinked
      memory_note='invalid memory_repo'
      result=1
      return
      ;;
  esac
  if [ ! -d "$memory_path" ]; then
    common_dir=$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir)
    main_checkout=$(dirname "$common_dir")
    main_parent=$(cd "$main_checkout/.." && pwd -P)
    target="$main_parent/$memory_dir"
    if [ -L "$memory_path" ] || [ ! -d "$target" ]; then
      memory_action=unlinked
      memory_note="memory checkout not found at $target"
      result=1
      return
    fi
    target=$(cd "$target" && pwd -P)
    if [ "$(dirname "$target")" != "$main_parent" ]; then
      memory_action=unlinked
      memory_note='invalid memory_repo'
      result=1
      return
    fi
    if ! ln -s "$target" "$memory_path" > "$scratch/link" 2>&1; then
      memory_action=unlinked
      memory_note="cannot link memory at $memory_path"
      result=1
      return
    fi
    linked_target="$target"
    memory_action=linked
  fi

  # Git otherwise walks up from an ordinary memory directory into the hub.
  physical_memory=$(cd "$memory_path" && pwd -P)
  memory_root=$(git -C "$memory_path" rev-parse --show-toplevel 2>/dev/null || true)
  memory_before=$(git -C "$memory_path" rev-parse --verify HEAD 2>/dev/null || true)
  if [ "$memory_root" != "$physical_memory" ] || [ -z "$memory_before" ]; then
    memory_action=skipped
    memory_note='memory is not a git checkout'
    result=1
    return
  fi
  if [ ! -f "$SCRIPT_DIR/bin/agent.sh" ]; then
    memory_action=failed
    memory_note='bin/agent.sh missing'
    result=1
    return
  fi
  if ! bash "$SCRIPT_DIR/bin/agent.sh" sync > "$scratch/sync" 2>&1; then
    memory_action=failed
    memory_note='sync failed'
    echo 'pull: sync failed' >&2
    tail -n 5 "$scratch/sync" >&2
    result=1
    return
  fi
  if ! memory_after=$(git -C "$memory_path" rev-parse --verify HEAD 2> "$scratch/memory"); then
    memory_action=failed
    memory_note='memory HEAD unavailable after sync'
    result=1
    return
  fi
  if [ "$memory_before" = "$memory_after" ]; then
    memory_action=up-to-date
    return
  fi
  memory_action=updated
  if ! memory_new=$(git -C "$memory_path" rev-list --count "$memory_before..$memory_after" 2> "$scratch/memory") \
    || ! git -C "$memory_path" diff --name-status -z "$memory_before" "$memory_after" > "$scratch/diff" 2>> "$scratch/memory"; then
    memory_action=failed
    memory_note='cannot inspect memory changes after sync'
    memory_new=0
    result=1
    return
  fi
  while IFS= read -r -d '' status && IFS= read -r -d '' file; do
    # Rename/copy records have two paths; report the destination and status letter.
    case "$status" in R*|C*) old_file="$file"; IFS= read -r -d '' file || file="$old_file" ;; esac
    jq -cn --arg path "$file" --arg status "${status:0:1}" \
      '{path: $path, status: $status}' >> "$scratch/files"
  done < "$scratch/diff"
}
sync_memory
jq -s '.' "$scratch/files" > "$scratch/files.json"

if $json; then
  jq -n --arg base "$base" --arg ref "$base_ref" --arg base_action "$base_action" --argjson base_new "$base_new" \
    --arg branch "$branch" --arg branch_action "$branch_action" --arg branch_note "$branch_note" \
    --arg path "$memory_path" --arg memory_action "$memory_action" --arg memory_note "$memory_note" \
    --argjson memory_new "$memory_new" --slurpfile files "$scratch/files.json" --argjson result "$result" \
    '{base: {name: $base, ref: $ref, action: $base_action, new_commits: $base_new},
      branch: {name: $branch, action: $branch_action, note: $branch_note},
      memory: {path: $path, action: $memory_action, note: $memory_note,
        new_commits: $memory_new, files: $files[0]}, exit: $result}'
else
  row() { printf '  %-14s %s\n' "$1" "$2"; }
  echo 'Pulling...'
  if [ "$base_action" = fetch-failed ]; then row "$base" "⚠ fetch failed — using last known $base_ref"
  elif [ "$base_new" -gt 0 ]; then row "$base" "↓ $base_new commits → synced"
  else row "$base" '✓ up to date'; fi
  case "$branch_action" in
    rebased) row "$branch" "✓ rebased onto $base" ;;
    merged) row "$branch" "✓ merged with $base" ;;
    fast-forwarded) row "$branch" '✓ fast-forwarded' ;;
    up-to-date) row "$branch" '✓ up to date' ;;
    conflict) row "$branch" "✗ conflict: $branch_note" ;;
    skipped) row "$branch" "⚠ skipped: $branch_note" ;;
  esac
  if [ -n "$linked_target" ]; then row memory "✓ linked $linked_target"; fi
  case "$memory_action" in
    updated)
      file_count=$(jq 'length' "$scratch/files.json")
      row memory "↓ $memory_new commits — $file_count files updated"
      jq -r '.[] | "                   " + .path + (if .status == "A" then " (new)" else "" end)' "$scratch/files.json"
      ;;
    up-to-date) row memory '✓ up to date' ;;
    failed) row memory "✗ failed: $memory_note" ;;
    unlinked) row memory "⚠ unlinked: $memory_note" ;;
    skipped) row memory "⚠ skipped: $memory_note" ;;
  esac
fi
exit "$result"
