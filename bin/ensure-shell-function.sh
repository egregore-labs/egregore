#!/usr/bin/env bash
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

# Build alias command — escape SCRIPT_DIR for safe embedding in shell alias
# printf %q handles paths with spaces, quotes, backticks, $ etc.
ESCAPED_DIR=$(printf '%q' "$SCRIPT_DIR")
ALIAS_CMD="cd ${ESCAPED_DIR} && claude start"

# --- Check if this directory already has an alias ---
get_existing_alias() {
  if ! grep -q "$SCRIPT_DIR" "$PROFILE" 2>/dev/null; then
    return
  fi
  if $IS_FISH; then
    # Fish: detect both legacy alias lines and function blocks
    # Function format: function <name>\n  cd "...SCRIPT_DIR..."\nend
    local func_name
    func_name=$(grep -B1 "$SCRIPT_DIR" "$PROFILE" 2>/dev/null | sed -n 's/^function \([^ ]*\)$/\1/p' | head -1)
    if [ -n "$func_name" ]; then
      echo "$func_name"
      return
    fi
    # Legacy alias format
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

  # First install (no "egregore" alias/function yet): use "egregore"
  if ! grep -q "^alias egregore=" "$PROFILE" 2>/dev/null && \
     ! grep -q "^alias egregore " "$PROFILE" 2>/dev/null && \
     ! grep -q "^function egregore$" "$PROFILE" 2>/dev/null; then
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

  # Remove existing entries for this directory (if reinstalling)
  if $IS_FISH; then
    # Fish: remove function blocks containing SCRIPT_DIR (multi-line)
    # Also remove legacy alias lines
    if grep -q "$SCRIPT_DIR" "$PROFILE" 2>/dev/null; then
      awk -v dir="$SCRIPT_DIR" '
        /^function / { buf=$0; in_func=1; next }
        in_func && /^end$/ { buf=buf"\n"$0; if (buf !~ dir) print buf; in_func=0; buf=""; next }
        in_func { buf=buf"\n"$0; next }
        $0 !~ dir { print }
      ' "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
    fi
    # Remove existing function with this name
    if grep -q "^function ${name}$" "$PROFILE" 2>/dev/null; then
      awk -v fname="^function ${name}$" '
        $0 ~ fname { skip=1; next }
        skip && /^end$/ { skip=0; next }
        skip { next }
        { print }
      ' "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
    fi
  else
    # Bash/Zsh: remove single-line alias entries
    if grep -q "$SCRIPT_DIR" "$PROFILE" 2>/dev/null; then
      grep -v "$SCRIPT_DIR" "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
    fi
    if grep -q "^alias ${name}=" "$PROFILE" 2>/dev/null; then
      grep -v "^alias ${name}=" "$PROFILE" > "$PROFILE.tmp" && mv "$PROFILE.tmp" "$PROFILE"
    fi
  fi

  mkdir -p "$(dirname "$PROFILE")"
  echo "" >> "$PROFILE"
  if $IS_FISH; then
    # Fish: use a function for robust path handling
    printf '\nfunction %s\n  cd "%s"; and claude start\nend\n' "$name" "$SCRIPT_DIR" >> "$PROFILE"
  else
    # Bash/Zsh: printf %q already escaped the path
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
