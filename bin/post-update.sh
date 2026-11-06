#!/usr/bin/env bash
# Post-update migrations for Egregore framework.
#
# This script is synced from upstream on every /update. All migration
# logic lives here — not in the /update skill itself. This avoids the
# chicken-and-egg problem: the dumb syncer pulls this script, then
# this script handles whatever needs to happen.
#
# Migrations must be idempotent — they run on every update.

set -euo pipefail

# This migration entry point is invoked by explicit /update, never startup.
# The helper preserves a previous working install if provisioning fails.
SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
bash "$SCRIPT_DIR/bin/artifact-renderer-install.sh"

MIGRATED=0

# --- Migration: commands → skills (CC 2.0+) ---
# CC 2.0 dropped .claude/commands/ support. If skills exist (synced from
# upstream) and commands still exist locally, remove commands to prevent
# duplicate entries in the slash menu.
if [ -d ".claude/skills" ] && [ -d ".claude/commands" ]; then
  CC_MAJOR=$(claude --version 2>/dev/null | grep -oE '^[0-9]+' || echo "0")
  if [ "${CC_MAJOR:-0}" -ge 2 ]; then
    git rm -r .claude/commands/ 2>/dev/null || rm -rf .claude/commands/
    echo "  ✓ Removed .claude/commands/ (migrated to skills)"
    MIGRATED=1
  fi
fi

# --- Migration: Runtime core travels with its adapters ---
# Earlier overlays copied bin/ but not egregore_runtime/, leaving the Runtime
# adapters without the module they import. The overlay that ran this update
# was loaded before bin/ changed, so copy the core here: one /update is
# enough. A Runtime-managed installation owns these files and is left alone.
if [ ! -e "$SCRIPT_DIR/egregore_runtime" ] && \
   git -C "$SCRIPT_DIR" cat-file -e 'upstream/main:egregore_runtime' 2>/dev/null && \
   ! (source "$SCRIPT_DIR/bin/lib/runtime-owned.sh"; runtime_owns_framework); then
  git -C "$SCRIPT_DIR" checkout upstream/main -- egregore_runtime/
  echo "  ✓ Added the Runtime core (egregore_runtime/)"
  MIGRATED=1
fi

# --- Migration: saved hosted address after the October 2026 security reset ---
# Connected setups before 22 Oct 2026 saved the hosted API's old Railway origin
# in egregore.json. That origin is retired; requests already resolve it to the
# hosted API (bin/lib/config.sh), and this rewrites the saved value once so the
# committed file says where requests go. Only that origin, without a path,
# changes; other keys, custom origins and Local configs are left alone.
#
# The working file and the index copy are handled separately, so /update
# commits this change and never an unrelated edit someone left in the file.
# Only the api_url string itself is replaced, byte for byte: formatting, key
# order, line endings, a byte-order mark and the file mode all stay as they
# were. An api_url written any other way (escaped, repeated) is left for the
# person to change by hand. Nothing is rewritten when either copy is Local,
# when egregore.json is a link (its target may belong to something else; the
# warning says to change it there), or when the working file is missing or
# unreadable. Nothing is staged for an untracked, sparse or assume-unchanged
# file. The index copy is staged first and the working file written second; a
# failed write restores the index, so the two never disagree about the
# address. A skip warns on stderr and never stops /update: the resolver
# already sends every request to the hosted API. Never at session start, where
# a modified tracked file would stop the startup sync. A source instance
# (upstream_url "none") skips the update commit, so it is left to the
# resolver.
# shellcheck source=bin/lib/config.sh
source "$SCRIPT_DIR/bin/lib/config.sh"
address_warn() { echo "  ! $*" >&2; }
# saved_api_url TEXT — the api_url string jq reads from TEXT, if any.
saved_api_url() { jq -r '.api_url | strings' 2>/dev/null <<< "$1" || true; }
# other_keys TEXT — everything jq reads from TEXT apart from api_url.
other_keys() { jq -cS 'del(.api_url)' 2>/dev/null <<< "$1"; }
# address_state TEXT — "retired" for a Connected config (the _detect_mode
# test) whose saved address is the retired origin, "local" for a Local one,
# "keep" for anything else, including text that is not a JSON object.
address_state() {
  local text="$1" saved
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$text"; then echo keep; return 0; fi
  if ! jq -e "$EGREGORE_CONNECTED_JQ" >/dev/null 2>&1 <<< "$text"; then echo local; return 0; fi
  saved="$(saved_api_url "$text")"
  if [ "$(jq -r '.upstream_url | strings' 2>/dev/null <<< "$text" || true)" != none ] \
     && _retired_api_url "$saved" \
     && [ "$(_hosted_api_url "$saved" 2>/dev/null || true)" = "$EGREGORE_HOSTED_API_ORIGIN" ]; then
    echo retired
  else
    echo keep
  fi
}
# hosted_address_text TEXT — sets ADDRESS_TEXT to TEXT with only its api_url
# string replaced by the hosted address. Fails, leaving it empty, unless TEXT
# holds "api_url" exactly once, as a string without escapes that is the value
# jq reads, and the replacement changes nothing else jq can see.
hosted_address_text() {
  local LC_ALL=C
  local text="$1" key='"api_url"' value_re='^([[:space:]]*:[[:space:]]*")([^"\\]*)"' after updated before_keys after_keys
  ADDRESS_TEXT=""
  case "$text" in *"$key"*) ;; *) return 1 ;; esac
  after="${text#*"$key"}"
  case "$after" in *"$key"*) return 1 ;; esac
  [[ "$after" =~ $value_re ]] || return 1
  [ "${BASH_REMATCH[2]}" = "$(saved_api_url "$text")" ] || return 1
  updated="${text%%"$key"*}$key${BASH_REMATCH[1]}$EGREGORE_HOSTED_API_ORIGIN\"${after#"${BASH_REMATCH[0]}"}"
  [ "$(saved_api_url "$updated")" = "$EGREGORE_HOSTED_API_ORIGIN" ] || return 1
  before_keys="$(other_keys "$text")" && after_keys="$(other_keys "$updated")" \
    && [ "$before_keys" = "$after_keys" ] || return 1
  ADDRESS_TEXT="$updated"
}
# read_exact FILE — sets EXACT_TEXT to FILE's bytes, trailing newlines kept.
read_exact() {
  local text
  text="$(cat -- "$1" 2>/dev/null && printf .)" || return 1
  EXACT_TEXT="${text%.}"
}
config_path="$SCRIPT_DIR/egregore.json"
worktree_state=absent
worktree_text=""
if [ -L "$config_path" ]; then
  worktree_state=link
elif [ -f "$config_path" ]; then
  if [ -r "$config_path" ] && read_exact "$config_path"; then
    worktree_text="$EXACT_TEXT"
    worktree_state="$(address_state "$worktree_text")"
  else
    worktree_state=unreadable
  fi
fi
index_state=untracked
index_stageable=false
index_entry="$(git -C "$SCRIPT_DIR" ls-files -s -- egregore.json 2>/dev/null || true)"
index_mode="${index_entry%% *}"
index_sha="${index_entry#* }"
index_sha="${index_sha%% *}"
index_text=""
case "$index_entry" in
  100644\ *\ 0$'\t'egregore.json|100755\ *\ 0$'\t'egregore.json)
    index_text="$(git -C "$SCRIPT_DIR" cat-file blob "$index_sha" 2>/dev/null && printf .)" || index_text=""
    if [ -n "$index_text" ]; then
      index_text="${index_text%.}"
      index_state="$(address_state "$index_text")"
      # Only a normal entry ("H"): skip-worktree and assume-unchanged files
      # are set aside from this checkout, so their commits are not ours to make.
      index_tag="$(git -C "$SCRIPT_DIR" ls-files -v -- egregore.json 2>/dev/null || true)"
      [ "${index_tag%% *}" = H ] && index_stageable=true
    else
      index_state=other
    fi
    ;;
  '') ;;
  *) index_state=other ;;
esac
address_updated=false
by_hand="set api_url to $EGREGORE_HOSTED_API_ORIGIN by hand"
if [ "$worktree_state" = link ]; then
  if read_exact "$config_path" && [ "$(address_state "$EXACT_TEXT")" = retired ]; then
    address_warn "egregore.json is a link, so its saved hosted address was left as is; requests still use $EGREGORE_HOSTED_API_ORIGIN. Set api_url to it in the file the link points to."
  fi
elif [ "$worktree_state" = unreadable ]; then
  address_warn "egregore.json can't be read, so its saved hosted address wasn't checked. If it names the retired address, $by_hand."
elif [ "$worktree_state" = local ] || [ "$index_state" = local ]; then
  if [ "$worktree_state" = retired ] || [ "$index_state" = retired ]; then
    address_warn "egregore.json is Local in one copy and Connected in the other, so its saved hosted address was left as is; requests still use $EGREGORE_HOSTED_API_ORIGIN."
  fi
else
  stage_index=false
  write_worktree=false
  if [ "$index_state" = retired ]; then
    if [ "$worktree_state" = absent ]; then
      address_warn "egregore.json is missing from this checkout, so its committed hosted address was left as is."
    elif [ "$index_stageable" != true ]; then
      address_warn "egregore.json is set aside from this checkout (sparse or assume-unchanged), so its committed hosted address was left as is."
    else
      stage_index=true
    fi
  fi
  [ "$worktree_state" != retired ] || write_worktree=true
  index_new=""
  worktree_new=""
  plan_ok=true
  if [ "$stage_index" = true ]; then
    if hosted_address_text "$index_text"; then index_new="$ADDRESS_TEXT"; else plan_ok=false; fi
  fi
  if [ "$write_worktree" = true ]; then
    if hosted_address_text "$worktree_text"; then worktree_new="$ADDRESS_TEXT"; else plan_ok=false; fi
  fi
  if [ "$plan_ok" != true ]; then
    address_warn "egregore.json's api_url is written in a way this update can't change safely, so it was left as is; requests still use $EGREGORE_HOSTED_API_ORIGIN. Please $by_hand."
  elif [ "$stage_index" = true ] || [ "$write_worktree" = true ]; then
    landed=true
    index_staged=false
    if [ "$stage_index" = true ]; then
      if index_blob="$(printf '%s' "$index_new" | git -C "$SCRIPT_DIR" hash-object -w --no-filters --stdin 2>/dev/null)" \
         && git -C "$SCRIPT_DIR" update-index --cacheinfo "$index_mode,$index_blob,egregore.json" 2>/dev/null; then
        index_staged=true
      else
        landed=false
        address_warn "Could not stage the hosted services address, so egregore.json was left as is; requests still use $EGREGORE_HOSTED_API_ORIGIN. Run /update again, or $by_hand."
      fi
    fi
    if [ "$landed" = true ] && [ "$write_worktree" = true ]; then
      config_mode="$(stat -c '%a' "$config_path" 2>/dev/null || stat -f '%Lp' "$config_path" 2>/dev/null || echo 644)"
      config_tmp="$(mktemp "$config_path.XXXXXX" 2>/dev/null || true)"
      if [ -n "$config_tmp" ] && printf '%s' "$worktree_new" > "$config_tmp" \
         && chmod "$config_mode" "$config_tmp" && mv -f "$config_tmp" "$config_path"; then
        :
      else
        landed=false
        [ -z "$config_tmp" ] || rm -f "$config_tmp"
        if [ "$index_staged" = true ] \
           && ! git -C "$SCRIPT_DIR" update-index --cacheinfo "$index_mode,$index_sha,egregore.json" 2>/dev/null; then
          address_warn "Could not update the hosted services address in egregore.json, and its staged copy could not be put back; run git restore --staged egregore.json, then $by_hand."
        else
          address_warn "Could not update the hosted services address in egregore.json; it is unchanged, and requests still use $EGREGORE_HOSTED_API_ORIGIN."
        fi
      fi
    fi
    [ "$landed" != true ] || address_updated=true
  fi
fi
if [ "$address_updated" = true ]; then
  echo "  ✓ Hosted services address updated after the October security reset"
  MIGRATED=1
fi

# --- Future migrations go here ---
# Each migration should:
# 1. Check if it needs to run (idempotent guard)
# 2. Do the work
# 3. Echo a status line
# 4. Set MIGRATED=1

if [ "$MIGRATED" -eq 0 ]; then
  echo "  ✓ No migrations needed"
fi
