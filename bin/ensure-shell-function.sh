#!/bin/bash
# Install egregore shell alias. Called by installers (not session-start).
#
# Usage:
#   ensure-shell-function.sh suggest   — output recommended alias name, write nothing
#   ensure-shell-function.sh install <name>  — write alias with given name
#   ensure-shell-function.sh           — legacy: auto-pick name, write, output name
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="$SCRIPT_DIR/egregore.json"
MODE="${1:-auto}"
CUSTOM_NAME="${2:-}"

if [ ! -f "$CONFIG" ]; then exit 0; fi

# Read slug from config (for alias naming)
SLUG=""
if command -v jq &>/dev/null; then
  SLUG=$(jq -r '.slug // empty' "$CONFIG" 2>/dev/null)
fi
if [ -z "$SLUG" ]; then
  SLUG=$(grep -o '"slug"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG" 2>/dev/null | sed 's/.*"slug"[[:space:]]*:[[:space:]]*"//;s/"$//' || true)
fi

# --- Detect shell and profile ---
detect_profile() {
  local shell_name
  shell_name=$(basename "${SHELL:-}")

  case "$shell_name" in
    zsh)
      echo "$HOME/.zshrc"
      return
      ;;
    bash)
      if [ -f "$HOME/.bash_profile" ]; then
        echo "$HOME/.bash_profile"
      elif [ -f "$HOME/.bashrc" ]; then
        echo "$HOME/.bashrc"
      else
        echo "$HOME/.bash_profile"
      fi
      return
      ;;
    fish)
      echo "$HOME/.config/fish/config.fish"
      return
      ;;
  esac

  for p in "$HOME/.zshrc" "$HOME/.bashrc" "$HOME/.bash_profile" "$HOME/.profile"; do
    if [ -f "$p" ]; then
      echo "$p"
      return
    fi
  done
}

PROFILE=$(detect_profile)
if [ -z "$PROFILE" ]; then
  PROFILE="$HOME/.$(basename "${SHELL:-bash}")rc"
fi

IS_FISH=false
if [[ "$PROFILE" == *"/fish/"* ]]; then
  IS_FISH=true
fi

ALIAS_CMD="cd \"$SCRIPT_DIR\" && claude start"

# --- Check if this directory already has an alias ---
get_existing_alias() {
  if ! grep -q "$SCRIPT_DIR" "$PROFILE" 2>/dev/null; then
    return
  fi
  if $IS_FISH; then
    grep "$SCRIPT_DIR" "$PROFILE" | head -1 | sed -n "s/^alias \([^ ]*\) .*/\1/p" 2>/dev/null || true
  else
    grep "$SCRIPT_DIR" "$PROFILE" | head -1 | sed -n "s/^alias \([^=]*\)=.*/\1/p" 2>/dev/null || true
  fi
}

# --- Compute recommended alias name ---
recommend_name() {
  # If already installed, recommend the existing name
  local existing
  existing=$(get_existing_alias)
  if [ -n "$existing" ]; then
    echo "$existing"
    return
  fi

  # First install (no "egregore" alias yet): use "egregore"
  if ! grep -q "^alias egregore=" "$PROFILE" 2>/dev/null && \
     ! grep -q "^alias egregore " "$PROFILE" 2>/dev/null; then
    echo "egregore"
    return
  fi

  # Subsequent: use slug-based name
  if [ -n "$SLUG" ]; then
    echo "egregore-${SLUG}"
  else
    local n=1
    while grep -q "^alias egregore-${n}=" "$PROFILE" 2>/dev/null || \
          grep -q "^alias egregore-${n} " "$PROFILE" 2>/dev/null; do
      n=$((n + 1))
    done
    echo "egregore-${n}"
  fi
}

# --- Write alias to profile ---
write_alias() {
  local name="$1"

  # Remove existing alias for this directory (if reinstalling)
  if grep -q "$SCRIPT_DIR" "$PROFILE" 2>/dev/null; then
    grep -v "$SCRIPT_DIR" "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
  fi

  # Remove existing alias with this name (if reusing a name)
  if $IS_FISH; then
    if grep -q "^alias ${name} " "$PROFILE" 2>/dev/null; then
      grep -v "^alias ${name} " "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
    fi
  else
    if grep -q "^alias ${name}=" "$PROFILE" 2>/dev/null; then
      grep -v "^alias ${name}=" "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
    fi
  fi

  mkdir -p "$(dirname "$PROFILE")"
  echo "" >> "$PROFILE"
  if $IS_FISH; then
    echo "alias ${name} '${ALIAS_CMD}'" >> "$PROFILE"
  else
    echo "alias ${name}='${ALIAS_CMD}'" >> "$PROFILE"
  fi
}

# --- Main ---
case "$MODE" in
  suggest)
    recommend_name
    ;;
  install)
    if [ -z "$CUSTOM_NAME" ]; then
      echo "Usage: ensure-shell-function.sh install <name>" >&2
      exit 1
    fi
    write_alias "$CUSTOM_NAME"
    echo "$CUSTOM_NAME:$PROFILE"
    ;;
  auto|*)
    NAME=$(recommend_name)
    write_alias "$NAME"
    echo "$NAME:$PROFILE"
    ;;
esac
