#!/usr/bin/env bash
set -euo pipefail

# One offline resolver for source checkouts and installed Egregore instances.
# Provisioning is explicit (setup/update/artifact-renderer-install.sh), never
# a side effect of rendering private content.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

resolve_renderer() {
  local source_cli="$ROOT/packages/egregore-artifacts/bin/cli.js"
  local manifest_dir="$ROOT/bin/lib/artifact-renderer"
  local managed="" install_id=""
  local installed=""

  if [ "${EGREGORE_USE_PUBLISHED:-0}" != "1" ] && \
     [ -f "$source_cli" ] && \
     [ -d "$ROOT/packages/egregore-artifacts/node_modules/react" ]; then
    printf '%s\n' "$source_cli"
    return 0
  fi
  if [ -f "$manifest_dir/dependencies.json" ] && [ -f "$manifest_dir/dependencies-lock.json" ]; then
    install_id="$(python3 - "$manifest_dir" <<'PY'
import hashlib, json, pathlib, re, sys
source = pathlib.Path(sys.argv[1])
version = json.loads((source / 'dependencies.json').read_text())['dependencies']['egregore-artifacts']
if not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', version):
    raise SystemExit('artifact renderer: an exact package version is required')
digest = hashlib.sha256((source / 'dependencies-lock.json').read_bytes()).hexdigest()[:16]
print(version + '-' + digest)
PY
)" || return 1
    managed="$ROOT/.egregore/tools/artifact-renderer/$install_id"
    if cmp -s "$manifest_dir/dependencies.json" "$managed/package.json" && \
       cmp -s "$manifest_dir/dependencies-lock.json" "$managed/package-lock.json" && \
       [ -f "$managed/node_modules/egregore-artifacts/bin/cli.js" ] && \
       [ -d "$managed/node_modules/react" ]; then
      printf '%s\n' "$managed/node_modules/egregore-artifacts/bin/cli.js"
      return 0
    fi
  fi
  installed="$(command -v egregore-artifacts 2>/dev/null || true)"
  if [ -n "$installed" ] && [ -f "$installed" ]; then
    printf '%s\n' "$installed"
    return 0
  fi
  echo "The artifact renderer is not installed or its dependencies are missing." >&2
  echo "Run bash bin/artifact-renderer-install.sh from this instance, then retry." >&2
  return 1
}

renderer="$(resolve_renderer)" || exit 1
if [ "${1:-}" = "--resolve" ]; then
  [ "$#" -eq 1 ] || { echo "--resolve takes no arguments" >&2; exit 2; }
  printf '%s\n' "$renderer"
  exit 0
fi
exec bash "$ROOT/bin/node-run.sh" "$renderer" "$@"
