#!/usr/bin/env bash
set -euo pipefail

# Resolve a working Node executable without trusting a broken version-manager
# shim. Skills call this adapter instead of embedding Volta/NVM paths.
working_node() {
  local candidate
  candidate="$(command -v node 2>/dev/null || true)"
  if [ -n "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
    printf '%s\n' "$candidate"
    return 0
  fi

  for root in \
    "${VOLTA_HOME:-$HOME/.volta}/tools/image/node" \
    "${NVM_DIR:-$HOME/.nvm}/versions/node"
  do
    [ -d "$root" ] || continue
    while IFS= read -r candidate; do
      if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done < <(find "$root" -type f -path '*/bin/node' 2>/dev/null)
  done

  for candidate in /opt/homebrew/bin/node /usr/local/bin/node /usr/bin/node; do
    if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

NODE_BIN="$(working_node || true)"
if [ -z "$NODE_BIN" ]; then
  echo "egregore: Node is unavailable; install Node 22, then retry" >&2
  exit 126
fi

exec "$NODE_BIN" "$@"
