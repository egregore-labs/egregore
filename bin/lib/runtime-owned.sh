#!/usr/bin/env bash
# runtime-owned.sh — does the Runtime own this instance's framework paths?
#
# An activated upgrade or a fresh package installation owns the framework.
# Activation records use the same stable identity as the Python upgrade
# store and the graph cutover gate: sha256(org_id | main-checkout path),
# first 16 hex chars, under EGREGORE_UPGRADE_ROOT (default
# ~/.egregore/runtime/upgrade). No global flag, no pathname guess, no slug,
# no branch name, no hardcoded organization or version.
#
# An explicit rollback takes precedence over installation receipts. Fresh
# installations do not pass through upgrade activation: their package-owned
# file manifest is the receipt, including for Local instances without org_id.
#
# Contract: sourced with SCRIPT_DIR set to the instance root.

runtime_owns_framework() (
  # Resolve only the named checkout, even from a shell or Git hook carrying
  # another repository's overrides. The subshell leaves the caller unchanged.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
  local org main gd common key rec runtime manifest
  org=$(jq -r '.org_id // empty' "$SCRIPT_DIR/egregore.json" 2>/dev/null)
  main="$SCRIPT_DIR"
  gd=$(git -C "$SCRIPT_DIR" rev-parse --absolute-git-dir 2>/dev/null) || gd=""
  common=$(git -C "$SCRIPT_DIR" rev-parse --git-common-dir 2>/dev/null) || common=""
  case "$common" in
    "") ;;
    /*) ;;
    *) common="$SCRIPT_DIR/$common" ;;
  esac
  case "$gd" in */.git/worktrees/*) main="${gd%/.git/worktrees/*}" ;; esac
  main=$(cd "$main" 2>/dev/null && pwd -P || printf '%s' "$SCRIPT_DIR")
  if [ -n "$org" ]; then
    key=$(printf '%s|%s' "$org" "$main" | shasum -a 256 2>/dev/null | cut -c1-16)
    if [ -n "$key" ]; then
      rec="${EGREGORE_UPGRADE_ROOT:-$HOME/.egregore/runtime/upgrade}/${key}/active.json"
      if [ -f "$rec" ]; then
        case "$(jq -r '.retrieval // empty' "$rec" 2>/dev/null)" in
          previous-runtime) return 1 ;;
          *) return 0 ;; # Unreadable activation must not authorize an overlay.
        esac
      fi
    fi
  fi

  # Read only this checkout's receipts and its shared Git directory. A global
  # launcher installation, sibling clone, or a skills-only adapter is not
  # evidence that Runtime owns this instance. Do not compare installed bytes:
  # local modifications must remain protected too.
  for runtime in claude codex pi prime; do
    for manifest in \
      "${gd:-$SCRIPT_DIR/.git}/info/egregore-$runtime-runtime.json" \
      "${common:-$SCRIPT_DIR/.git}/info/egregore-$runtime-runtime.json" \
      "$SCRIPT_DIR/.egregore/$runtime-runtime-manifest.json"; do
      [ -f "$manifest" ] || continue
      if jq -e '
        .package == "create-egregore" and
        (.files["egregore_runtime/runtime.py"].hash | type == "string" and test("^[a-f0-9]{64}$")) and
        (.files["egregore_runtime/harness_cli.py"].hash | type == "string" and test("^[a-f0-9]{64}$"))
      ' "$manifest" >/dev/null 2>&1; then
        return 0
      fi
    done
  done
  return 1
)
