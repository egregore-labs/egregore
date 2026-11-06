#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP_ROOT="$(mktemp -d -t artifact-renderer-test-XXXXXX)"
trap 'rm -rf "$TMP_ROOT"' EXIT
FIXTURE="$TMP_ROOT/downstream instance"
SHIMS="$TMP_ROOT/system commands"
mkdir -p "$FIXTURE/bin/lib/artifact-renderer" "$SHIMS"
cp "$ROOT/bin/artifact-renderer.sh" "$FIXTURE/bin/artifact-renderer.sh"
cp "$ROOT/bin/lib/artifact-renderer/"*.json "$FIXTURE/bin/lib/artifact-renderer/"

# A hermetic PATH prevents a developer's installed renderer from rescuing a
# broken fixture. Package managers and the installer are explicit tripwires.
for command_name in bash cat cmp dirname readlink realpath python3; do
  command_path="$(command -v "$command_name" || true)"
  [ -z "$command_path" ] || ln -s "$command_path" "$SHIMS/$command_name"
done
cat > "$SHIMS/npm" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "${NETWORK_CALLS:?}"
exit 91
SH
cp "$SHIMS/npm" "$SHIMS/npx"
cp "$SHIMS/npm" "$FIXTURE/bin/artifact-renderer-install.sh"
cat > "$FIXTURE/bin/node-run.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${NODE_CALLS:?}"
exec bash "$@"
SH
chmod +x "$SHIMS/npm" "$SHIMS/npx" "$FIXTURE/bin/"*.sh

export NETWORK_CALLS="$TMP_ROOT/network.calls"
export NODE_CALLS="$TMP_ROOT/node.calls"
export RENDER_CALLS="$TMP_ROOT/render.calls"
export RENDER_ARGS="$TMP_ROOT/render.args"
export EGREGORE_USE_PUBLISHED=0
SOURCE_CLI="$FIXTURE/packages/egregore-artifacts/bin/cli.js"
SOURCE_REACT="$FIXTURE/packages/egregore-artifacts/node_modules/react"
INSTALL_ID="$(python3 - "$FIXTURE/bin/lib/artifact-renderer" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1])
version = json.loads((p / 'dependencies.json').read_text())['dependencies']['egregore-artifacts']
print(version + '-' + hashlib.sha256((p / 'dependencies-lock.json').read_bytes()).hexdigest()[:16])
PY
)"
MANAGED_ROOT="$FIXTURE/.egregore/tools/artifact-renderer/$INSTALL_ID"
MANAGED_CLI="$MANAGED_ROOT/node_modules/egregore-artifacts/bin/cli.js"
MANAGED_REACT="$MANAGED_ROOT/node_modules/react"
PATH_CLI="$SHIMS/egregore-artifacts"

make_cli() {
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" > "$1.label"
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat "$0.label" >> "${RENDER_CALLS:?}"
printf '%s\n' "$@" > "${RENDER_ARGS:?}"
exit "${RENDER_EXIT:-0}"
SH
  chmod +x "$1"
}

resolve() {
  PATH="$SHIMS" bash "$FIXTURE/bin/artifact-renderer.sh" --resolve
}

render() {
  PATH="$SHIMS" bash "$FIXTURE/bin/artifact-renderer.sh" "$@"
}

expect_resolution() {
  local actual
  actual="$(resolve)"
  [ "$actual" = "$1" ] || {
    printf 'wrong renderer: expected <%s>, got <%s>\n' "$1" "$actual" >&2
    exit 1
  }
}

expect_missing() {
  if resolve > "$TMP_ROOT/missing.stdout" 2> "$TMP_ROOT/missing.stderr"; then
    echo "resolution succeeded without a usable renderer" >&2
    exit 1
  fi
  [ ! -s "$TMP_ROOT/missing.stdout" ]
  grep -Fq 'artifact-renderer-install.sh' "$TMP_ROOT/missing.stderr"
}

# Installed downstreams have no packages/ checkout. Resolution is read-only,
# and running the selected PATH renderer preserves every spaced argument.
expect_missing
[ ! -e "$FIXTURE/packages" ]
[ ! -e "$NODE_CALLS" ]
make_cli "$PATH_CLI" path
expect_resolution "$PATH_CLI"
[ ! -e "$NODE_CALLS" ]
render composed "$FIXTURE/composed source.json" --source "$FIXTURE/canonical source.md" --verify-fidelity
printf '%s\n' composed "$FIXTURE/composed source.json" --source "$FIXTURE/canonical source.md" --verify-fidelity > "$TMP_ROOT/expected.args"
cmp "$TMP_ROOT/expected.args" "$RENDER_ARGS"
[ "$(cat "$RENDER_CALLS")" = path ]
[ "$(cat "$NODE_CALLS")" = "$PATH_CLI" ]

# A managed install wins over PATH only when its dependencies are present.
make_cli "$MANAGED_CLI" managed
cp "$FIXTURE/bin/lib/artifact-renderer/dependencies.json" "$MANAGED_ROOT/package.json"
cp "$FIXTURE/bin/lib/artifact-renderer/dependencies-lock.json" "$MANAGED_ROOT/package-lock.json"
expect_resolution "$PATH_CLI"
mkdir -p "$MANAGED_REACT"
expect_resolution "$MANAGED_CLI"
: > "$RENDER_CALLS"
render handoff "$FIXTURE/canonical source.md" --verify-fidelity
[ "$(cat "$RENDER_CALLS")" = managed ]

# A prepared candidate is selected only after its Runtime's pin is active.
# Same-version transitive dependency changes cannot select or replace the
# prior Runtime's install; switching back to its manifests selects it offline.
cp "$FIXTURE/bin/lib/artifact-renderer/dependencies-lock.json" "$TMP_ROOT/old-lock.json"
printf '\n' >> "$FIXTURE/bin/lib/artifact-renderer/dependencies-lock.json"
expect_resolution "$PATH_CLI"
NEW_ID="$(python3 - "$FIXTURE/bin/lib/artifact-renderer" <<'PY'
import hashlib, json, pathlib, sys
p = pathlib.Path(sys.argv[1])
version = json.loads((p / 'dependencies.json').read_text())['dependencies']['egregore-artifacts']
print(version + '-' + hashlib.sha256((p / 'dependencies-lock.json').read_bytes()).hexdigest()[:16])
PY
)"
NEW_ROOT="$FIXTURE/.egregore/tools/artifact-renderer/$NEW_ID"
make_cli "$NEW_ROOT/node_modules/egregore-artifacts/bin/cli.js" candidate
mkdir -p "$NEW_ROOT/node_modules/react"
cp "$FIXTURE/bin/lib/artifact-renderer/dependencies.json" "$NEW_ROOT/package.json"
cp "$FIXTURE/bin/lib/artifact-renderer/dependencies-lock.json" "$NEW_ROOT/package-lock.json"
expect_resolution "$NEW_ROOT/node_modules/egregore-artifacts/bin/cli.js"
cp "$TMP_ROOT/old-lock.json" "$FIXTURE/bin/lib/artifact-renderer/dependencies-lock.json"
expect_resolution "$MANAGED_CLI"
[ -f "$NEW_ROOT/node_modules/egregore-artifacts/bin/cli.js" ]

# A directory bearing the right identifier still needs matching manifests.
printf '\n' >> "$MANAGED_ROOT/package.json"
expect_resolution "$PATH_CLI"
cp "$FIXTURE/bin/lib/artifact-renderer/dependencies.json" "$MANAGED_ROOT/package.json"
expect_resolution "$MANAGED_CLI"

# Source checkouts take precedence when usable; a CLI without dependencies
# must not be passed to Node merely because the source file exists.
make_cli "$SOURCE_CLI" source
expect_resolution "$MANAGED_CLI"
mkdir -p "$SOURCE_REACT"
expect_resolution "$SOURCE_CLI"
: > "$RENDER_CALLS"
render handoff "$FIXTURE/canonical source.md" --verify-fidelity
[ "$(cat "$RENDER_CALLS")" = source ]

# Explicit published mode ignores the source checkout, preferring the managed
# install and then PATH without downloading a package during rendering.
EGREGORE_USE_PUBLISHED=1 expect_resolution "$MANAGED_CLI"
rm -rf "$MANAGED_REACT"
EGREGORE_USE_PUBLISHED=1 expect_resolution "$PATH_CLI"
expect_resolution "$SOURCE_CLI"

# A genuine renderer/fidelity failure must be returned, not hidden by retrying
# another installation. The node adapter and renderer each run exactly once.
: > "$RENDER_CALLS"
: > "$NODE_CALLS"
status=0
RENDER_EXIT=23 render handoff "$FIXTURE/canonical source.md" --verify-fidelity || status=$?
[ "$status" -eq 23 ]
[ "$(cat "$RENDER_CALLS")" = source ]
[ "$(cat "$NODE_CALLS")" = "$SOURCE_CLI" ]

rm -f "$PATH_CLI"
EGREGORE_USE_PUBLISHED=1 expect_missing
rm -rf "$SOURCE_REACT"
expect_missing
[ ! -e "$NETWORK_CALLS" ]

echo "PASS: artifact renderer resolves source, managed and PATH installs without fetching or hiding failures"
