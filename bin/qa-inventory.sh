#!/usr/bin/env bash
set -euo pipefail
# Repository selection belongs to this script, never to inherited Git overrides.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR

# Read-only QA scope, skill consumers, and candidate suites by reference.
# Full paths and skill directories match; basenames are matched only when unique in the repository.
# Usage: bash bin/qa-inventory.sh [--pr N | --branch NAME | <paths...>] [--base REF] [--json]
# Exit 0 = inventory printed (including an empty inventory)
# Exit 2 = invalid arguments or unresolved base, branch, or PR (including missing gh)

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/generated-trees.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bin/lib/repo-paths.sh"
# Git and the optional skill engine must not refresh the repository's index.
export GIT_OPTIONAL_LOCKS=0

usage() {
  echo "Usage: bash bin/qa-inventory.sh [--pr N | --branch NAME | <paths...>] [--base REF] [--json]" >&2
  exit 2
}

mode=working-tree
base=""
branch=""
pr=""
json=false
selected=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --json) json=true; shift ;;
    --base|--branch|--pr)
      [ "$#" -ge 2 ] && [ -n "$2" ] || usage
      case "$2" in -*) usage ;; esac
      case "$1" in
        --base) base="$2" ;;
        --branch) [ "$mode" = working-tree ] || usage; mode=branch; branch="$2" ;;
        --pr)
          [ "$mode" = working-tree ] || usage
          case "$2" in *[!0-9]*) usage ;; esac
          mode='pr'; pr="$2"
          ;;
      esac
      shift 2
      ;;
    -*) usage ;;
    *) selected+=("$1"); shift ;;
  esac
done
if [ "${#selected[@]}" -gt 0 ]; then
  [ "$mode" = working-tree ] || usage
  mode=paths
fi

# An inherited TMPDIR may point into the checkout. Scratch always stays outside it.
scratch=$(mktemp -d /tmp/qa-inventory.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
for file in changed skipped matches paths; do : > "$scratch/$file"; done

commit_ref() {
  case "$1" in ''|-*) return 1 ;; esac
  git -C "$SCRIPT_DIR" rev-parse --verify --quiet "$1^{commit}"
}

remote_only=false
if [ -n "$base" ]; then
  if ! commit_ref "$base" >/dev/null; then
    echo "qa-inventory: base $base not found" >&2
    exit 2
  fi
fi
if [ "$mode" = pr ]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "qa-inventory: gh is required for --pr" >&2
    exit 2
  fi
  if ! (cd "$SCRIPT_DIR" && gh pr view "$pr" --json baseRefName,headRefName,headRefOid,files) > "$scratch/pr"; then
    exit 2
  fi
  if ! jq -e '
    (.baseRefName | type == "string" and length > 0) and
    (.headRefName | type == "string" and length > 0) and
    (.headRefOid | type == "string" and test("^[0-9a-fA-F]{40}$")) and
    (.files | type == "array") and all(.files[]; .path | type == "string" and length > 0)
  ' "$scratch/pr" >/dev/null; then
    echo "qa-inventory: gh returned an invalid PR inventory" >&2
    exit 2
  fi
  if [ -z "$base" ]; then
    base=$(jq -r '.baseRefName' "$scratch/pr")
    if commit_ref "origin/$base" >/dev/null; then base="origin/$base"; else remote_only=true; fi
  fi
elif [ -z "$base" ]; then
  base=$(bash "$SCRIPT_DIR/bin/base-branch.sh" --resolve) || exit 2
fi

head_ref=HEAD
head_oid=""
working_tree=false
case "$mode" in
  branch)
    if head_oid=$(commit_ref "$branch"); then
      head_ref="$branch"
    elif head_oid=$(commit_ref "origin/$branch"); then
      head_ref="origin/$branch"
    else
      echo "qa-inventory: branch $branch not found locally or on origin" >&2
      exit 2
    fi
    head_description="$branch"
    ;;
  pr)
    head_ref=$(jq -r '.headRefName' "$scratch/pr")
    head_oid=$(jq -r '.headRefOid' "$scratch/pr")
    head_description="$head_ref@${head_oid:0:8}"
    ;;
  *)
    head_oid=$(commit_ref HEAD) || { echo "qa-inventory: HEAD not found" >&2; exit 2; }
    head_description=$(git -C "$SCRIPT_DIR" symbolic-ref --quiet --short HEAD) || head_description=HEAD
    if [ "$mode" = working-tree ]; then
      working_tree=true
      head_description="$head_description + working tree"
    fi
    ;;
esac

requested_tree=false
head_args=()
coverage_note=""
if [ "$mode" = branch ] || [ "$mode" = pr ]; then
  if commit_ref "$head_oid" >/dev/null; then
    requested_tree=true
    head_args=(--head "$head_oid")
  else
    coverage_note="suites and skills computed from the local checkout; requested head $head_oid is not fetched"
    printf 'Coverage: %s\n' "$coverage_note" >&2
  fi
fi

merge_base=""
if ! merge_base=$(git -C "$SCRIPT_DIR" merge-base "$base" "$head_oid" 2>/dev/null); then
  # A remote-only PR head has no local ancestry to inspect.
  if [ "$mode" != pr ]; then merge_base=$(commit_ref "$base"); fi
fi

add_path() {
  local status="$1" file="$2" note="${3:-}"
  if [ "$note" != 'outside repository' ] && is_generated_path "$file"; then
    jq -cn --arg path "$file" '$path' >> "$scratch/skipped"
    return
  fi
  jq -cn --arg path "$file" --arg status "$status" --arg note "$note" \
    '{path: $path, status: $status, note: (if $note == "" then null else $note end)}' >> "$scratch/changed"
}

case "$mode" in
  working-tree|branch)
    diff_args=("$merge_base")
    # Diff the captured commit, not the ref name: a concurrent fetch must not mix two heads.
    if [ "$mode" = branch ]; then diff_args+=("$head_oid"); fi
    git -C "$SCRIPT_DIR" diff --name-status --no-renames -z "${diff_args[@]}" -- > "$scratch/diff" || exit 2
    while IFS= read -r -d '' status && IFS= read -r -d '' file; do
      add_path "$status" "$file"
    done < "$scratch/diff"
    if [ "$mode" = working-tree ]; then
      git -C "$SCRIPT_DIR" ls-files --others --exclude-standard -z > "$scratch/untracked" || exit 2
      while IFS= read -r -d '' file; do add_path '?' "$file" untracked; done < "$scratch/untracked"
    fi
    ;;
  pr)
    jq -j '.files[] | .path, "\u0000"' "$scratch/pr" > "$scratch/pr-paths"
    while IFS= read -r -d '' file; do
      case "$file" in /*|../*|*/../*|*/..) add_path X "$file" 'outside repository' ;; *) add_path P "$file" ;; esac
    done < "$scratch/pr-paths"
    ;;
  paths)
    physical_root=$(physical_path "$SCRIPT_DIR")
    for file in ${selected[@]+"${selected[@]}"}; do
      # Relative entries retain their identity, including symlink names. Only
      # remove redundant separators and dots here; never collapse parent steps.
      case "$file" in
        /*|..|../*|*/../*|*/..) relative_entry=false ;;
        *) relative_entry=true
           file=$(jq -nr --arg path "$file" '$path | split("/")
             | map(select(. != "" and . != ".")) | join("/")
             | if . == "" then "." else . end')
           # Preserve missing entries even when their parent directory is absent.
           if [ ! -e "$SCRIPT_DIR/$file" ] && [ ! -L "$SCRIPT_DIR/$file" ]; then
             add_path X "$file" missing
             continue
           fi ;;
      esac
      if ! inside_repository "$file"; then
        add_path X "$file" 'outside repository'
        continue
      fi
      if ! $relative_entry; then
        case "$file" in /*) ;; *) file="$SCRIPT_DIR/$file" ;; esac
        file=$(physical_path "$file")
        if [ "$file" = "$physical_root" ]; then file=.; else file="${file#"$physical_root"/}"; fi
      fi
      if [ -e "$SCRIPT_DIR/$file" ] || [ -L "$SCRIPT_DIR/$file" ]; then add_path E "$file"
      else add_path X "$file" missing; fi
    done
    ;;
esac

jq -s 'unique_by(.path)' "$scratch/changed" > "$scratch/changed.json"
jq -s 'unique' "$scratch/skipped" > "$scratch/skipped.json"
jq -r '.[] | select(.note != "outside repository") | .path' "$scratch/changed.json" > "$scratch/paths"
affected_note=""
printf '{}\n' > "$scratch/affected.json"
if [ ! -f "$SCRIPT_DIR/bin/capability-distribution.mjs" ] || [ ! -f "$SCRIPT_DIR/bin/node-run.sh" ]; then
  affected_note='unavailable (no distribution engine)'
elif [ -s "$scratch/paths" ]; then
  if (cd "$SCRIPT_DIR" && bash bin/node-run.sh bin/capability-distribution.mjs skill-references \
      --paths-file "$scratch/paths" --base "$base" ${head_args[@]+"${head_args[@]}"} --json) > "$scratch/skills" 2> "$scratch/skills.err" \
      && jq -e '.affected | select(type == "object")' "$scratch/skills" > "$scratch/affected.json" 2>> "$scratch/skills.err"; then
    :
  else
    cat "$scratch/skills.err" >&2
    reason=$(cat "$scratch/skills.err")
    affected_note="unavailable (${reason:-distribution engine failed})"
  fi
fi
if [ -n "$affected_note" ]; then printf 'null\n' > "$scratch/affected.json"; fi

corpus=()
suite_paths_skipped=0
if $requested_tree; then
  # Count basename collisions in the same tree whose suite content is searched.
  git -C "$SCRIPT_DIR" ls-tree -r --name-only -z "$head_oid" > "$scratch/head-paths"
  jq -Rs 'split("\u0000") | reduce (.[] | select(length > 0)) as $path ({};
    ($path | split("/")[-1]) as $basename | .[$basename] += [$path])' \
    "$scratch/head-paths" > "$scratch/head-basenames.json"
else
  for suite in "$SCRIPT_DIR"/tests/*.sh "$SCRIPT_DIR"/tests/*.py "$SCRIPT_DIR"/bin/tests/*.sh "$SCRIPT_DIR"/bin/tests/*.mjs; do
    if [ -L "$suite" ]; then
      suite_paths_skipped=$((suite_paths_skipped + 1))
      continue
    fi
    [ -f "$suite" ] || continue
    if inside_repository "$suite"; then corpus+=("$suite")
    else suite_paths_skipped=$((suite_paths_skipped + 1)); fi
  done
fi
if [ "$suite_paths_skipped" -gt 0 ]; then
  echo "qa-inventory: skipped $suite_paths_skipped suite path(s) outside the repository" >&2
fi
runtime_change=$(jq 'any(.[]; .note != "outside repository" and
  (.path | test("^(\\.claude/skills/|\\.codex/|\\.pi/|\\.prime/|bin/)")))' "$scratch/changed.json")
jq -j '.[] | select(.status != "D" and .note != "outside repository") | .path, "\u0000"' \
  "$scratch/changed.json" > "$scratch/search-paths"
while IFS= read -r -d '' file; do
  if $requested_tree || [ "${#corpus[@]}" -gt 0 ]; then
    patterns=(-e "$file")
    basename="${file##*/}"
    if [ "$basename" != "$file" ]; then
      if $requested_tree; then
        jq -j --arg basename "$basename" '.[$basename][]? | ., "\u0000"' \
          "$scratch/head-basenames.json" > "$scratch/basename-paths"
      else
        git -C "$SCRIPT_DIR" ls-files -z -- "$basename" "*/$basename" > "$scratch/basename-paths"
      fi
      tracked_count=0
      tracked_path=""
      while IFS= read -r -d '' tracked_path; do
        tracked_count=$((tracked_count + 1))
        only_tracked_path="$tracked_path"
      done < "$scratch/basename-paths"
      # A tracked basename must identify this path; an untracked one has no tracked matches.
      if [ "$tracked_count" -eq 0 ] \
         || { [ "$tracked_count" -eq 1 ] && [ "$only_tracked_path" = "$file" ]; }; then
        patterns+=(-e "$basename")
      fi
    fi
    case "$file" in
      .claude/skills/*/*)
        skill="${file#.claude/skills/}"
        patterns+=(-e "skills/${skill%%/*}/")
        ;;
    esac
    # Exactly one fixed-string search over the corpus per changed path.
    code=0
    if $requested_tree; then
      git -C "$SCRIPT_DIR" grep -l -z -F "${patterns[@]}" "$head_oid" -- \
        ':(top,glob)tests/*.sh' ':(top,glob)tests/*.py' \
        ':(top,glob)bin/tests/*.sh' ':(top,glob)bin/tests/*.mjs' > "$scratch/hits" || code=$?
      while IFS= read -r -d '' suite; do
        jq -cn --arg suite "${suite#"$head_oid":}" --arg match "$file" \
          '{suite: $suite, match: $match}' >> "$scratch/matches"
      done < "$scratch/hits"
    else
      grep -l -F "${patterns[@]}" -- ${corpus[@]+"${corpus[@]}"} > "$scratch/hits" || code=$?
      while IFS= read -r suite || [ -n "$suite" ]; do
        jq -cn --arg suite "${suite#"$SCRIPT_DIR"/}" --arg match "$file" \
          '{suite: $suite, match: $match}' >> "$scratch/matches"
      done < "$scratch/hits"
    fi
    if [ "$code" -gt 1 ]; then
      echo "qa-inventory: candidate suite search failed for $file" >&2
    fi
  fi
done < "$scratch/search-paths"
if $runtime_change; then
  jq -cn '{suite: "tests/test-runtime-skill-migration.sh", match: "skill or bin change"}' >> "$scratch/matches"
fi
jq -s 'group_by(.suite) | map({suite: .[0].suite, matches: (map(.match) | unique)})' \
  "$scratch/matches" > "$scratch/suites.json"
jq -n --arg mode "$mode" --arg base "$base" --arg merge_base "$merge_base" \
  --arg head_ref "$head_ref" --arg head_oid "$head_oid" --arg description "$head_description" \
  --argjson working_tree "$working_tree" --arg note "$affected_note" \
  --argjson suite_paths_skipped "$suite_paths_skipped" --arg coverage_note "$coverage_note" \
  --slurpfile changed "$scratch/changed.json" --slurpfile skipped "$scratch/skipped.json" \
  --slurpfile affected "$scratch/affected.json" --slurpfile suites "$scratch/suites.json" '
  {mode: $mode, base: {ref: $base, merge_base: (if $merge_base == "" then null else $merge_base end)},
   head: {ref: $head_ref, oid: $head_oid, description: $description, working_tree: $working_tree},
   changed: $changed[0], generated_skipped: $skipped[0], affected_skills: $affected[0],
   affected_skills_note: (if $note == "" then null else $note end), candidate_suites: $suites[0],
   suite_paths_skipped: $suite_paths_skipped,
   coverage_note: (if $coverage_note == "" then null else $coverage_note end)}
  ' > "$scratch/inventory.json"
if $json; then cat "$scratch/inventory.json"; exit 0; fi
jq -r --argjson remote_only "$remote_only" '
  "QA inventory",
  ("Base: " + .base.ref + (if $remote_only then " (remote only)" else "" end) +
    " (merge-base " + (if .base.merge_base then .base.merge_base[:7] else "unavailable" end) + ")"),
  ("Head: " + .head.description),
  (if .coverage_note then "Coverage: " + .coverage_note else empty end),
  if (.changed | length) == 0 then "Nothing to QA."
  else
    "Changed (\(.changed | length); \(.generated_skipped | length) generated skipped):",
    (.changed[] | "  \(.status) \(.path)" + (if .note then " (\(.note))" else "" end)),
    (if .affected_skills == null then "Affected skills: " + .affected_skills_note
     else "Affected skills (\(.affected_skills | length)):",
       (.affected_skills | to_entries[] | "  $\(.key) (\(.value | join(", ")))") end),
    "Candidate suites (\(.candidate_suites | length), by reference):",
    (.candidate_suites[] | "  \(.suite) (\(.matches | join(", ")))")
  end' "$scratch/inventory.json"
