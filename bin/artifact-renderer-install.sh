#!/usr/bin/env bash
# Explicit setup/update/repair only. Rendering and startup must never install.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET_ROOT="$SCRIPT_DIR"
CHECK_ONLY=0
LOCK_FD=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --root)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { echo 'artifact renderer: --root needs a directory' >&2; exit 2; }
      TARGET_ROOT="$2"; shift 2 ;;
    --check) CHECK_ONLY=1; shift ;;
    --lock-fd) LOCK_FD="${2:?missing lock descriptor}"; shift 2 ;;
    *) echo 'Usage: bash bin/artifact-renderer-install.sh [--root <instance>] [--check]' >&2; exit 2 ;;
  esac
done
# npm 11 treats a symlinked --prefix as a linked root package, which makes
# `ci` reject the lockfile (including macOS's /var -> /private/var alias).
TARGET_ROOT="$(cd "$TARGET_ROOT" && pwd -P)"
MANIFEST_DIR="$SCRIPT_DIR/bin/lib/artifact-renderer"

for required in dependencies.json dependencies-lock.json; do
  [ -f "$MANIFEST_DIR/$required" ] || {
    echo "artifact renderer: pinned $required is missing; update the framework and retry" >&2
    exit 1
  }
done
NODE_BIN="$(bash "$SCRIPT_DIR/bin/node-run.sh" -p 'process.execPath')"
export PATH="$(dirname "$NODE_BIN"):$PATH"
MANIFEST_INFO="$(python3 - "$MANIFEST_DIR" <<'PY'
import hashlib, json, pathlib, re, sys
source = pathlib.Path(sys.argv[1])
version = json.loads((source / 'dependencies.json').read_text())['dependencies']['egregore-artifacts']
if not isinstance(version, str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.-]+)?', version):
    raise SystemExit('artifact renderer: an exact package version is required')
digest = hashlib.sha256((source / 'dependencies-lock.json').read_bytes()).hexdigest()[:16]
print(version, version + '-' + digest)
PY
)"
read -r VERSION INSTALL_ID <<< "$MANIFEST_INFO"
TOOLS_DIR="$TARGET_ROOT/.egregore/tools/artifact-renderer"
PREFIX="$TOOLS_DIR/$INSTALL_ID"

renderer_ready() {
  local candidate="$1"
  cmp -s "$MANIFEST_DIR/dependencies.json" "$candidate/package.json" || return 1
  cmp -s "$MANIFEST_DIR/dependencies-lock.json" "$candidate/package-lock.json" || return 1
  "$NODE_BIN" -e '
    const fs = require("node:fs");
    const path = require("node:path");
    const actual = JSON.parse(fs.readFileSync(path.join(process.argv[1], "node_modules/egregore-artifacts/package.json"), "utf8"));
    if (actual.version !== process.argv[2]) process.exit(1);
  ' "$candidate" "$VERSION" >/dev/null 2>&1 || return 1
  "$NODE_BIN" "$candidate/node_modules/egregore-artifacts/bin/cli.js" --help >/dev/null 2>&1
}

if renderer_ready "$PREFIX"; then
  printf 'Artifact renderer %s is ready\n' "$VERSION"
  exit 0
fi
if [ "$CHECK_ONLY" = 1 ]; then
  printf 'Artifact renderer %s is not ready; run bash bin/artifact-renderer-install.sh\n' "$VERSION" >&2
  exit 1
fi

NPM_BIN="$(command -v npm || true)"
[ -n "$NPM_BIN" ] && "$NPM_BIN" --version >/dev/null 2>&1 || {
  echo 'artifact renderer: npm is unavailable; install Node with npm, then retry' >&2
  exit 1
}
mkdir -p "$TOOLS_DIR"
[ ! -L "$PREFIX" ] || { echo 'artifact renderer: managed install must not be a symbolic link' >&2; exit 1; }
LOCK="$TOOLS_DIR/.$INSTALL_ID.lock"
# A kernel lock survives in children while they are still installing and is
# released after forced interruption. Its persistent file never means "busy".
# Re-exec under the inherited descriptor so Bash, npm, and cleanup all share
# ownership; unlike mkdir locks, a killed process cannot leave a stale owner.
if [ -z "$LOCK_FD" ]; then
  exec python3 - "$LOCK" "$SCRIPT_DIR/bin/artifact-renderer-install.sh" "$TARGET_ROOT" <<'PY'
import fcntl, os, stat, sys
lock, script, root = sys.argv[1:]
fd = os.open(lock, os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
if not stat.S_ISREG(os.fstat(fd).st_mode):
    raise SystemExit('artifact renderer: invalid install lock')
try:
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError:
    raise SystemExit('artifact renderer: another install is in progress; retry after it finishes')
os.set_inheritable(fd, True)
os.execvp('bash', ['bash', script, '--root', root, '--lock-fd', str(fd)])
PY
fi
# Validate the internal descriptor instead of accepting an unlocked re-entry.
python3 - "$LOCK_FD" "$LOCK" <<'PY'
import fcntl, os, sys
try:
    fd = int(sys.argv[1])
    if not os.path.samestat(os.fstat(fd), os.stat(sys.argv[2])):
        raise ValueError('wrong lock file')
    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
except (ValueError, OSError):
    raise SystemExit('artifact renderer: install lock is unavailable')
PY
STAGE=""
BACKUP="$TOOLS_DIR/.$INSTALL_ID.previous"
cleanup() {
  if [ -n "$BACKUP" ] && [ -d "$BACKUP" ] && [ ! -e "$PREFIX" ]; then mv "$BACKUP" "$PREFIX"; fi
  [ -z "$STAGE" ] || rm -rf "$STAGE"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Recover an interrupted swap and discard only this pin's abandoned staging
# trees. Another Runtime's version/lock and in-progress install stay untouched.
if [ -d "$BACKUP" ]; then
  if [ ! -e "$PREFIX" ]; then mv "$BACKUP" "$PREFIX"; else rm -rf "$BACKUP"; fi
fi
for abandoned in "$TOOLS_DIR/.$INSTALL_ID.stage."*; do
  [ ! -d "$abandoned" ] || rm -rf "$abandoned"
done

# Recheck under the lock in case another explicit installer just completed.
if renderer_ready "$PREFIX"; then
  printf 'Artifact renderer %s is ready\n' "$VERSION"
  exit 0
fi
STAGE="$(mktemp -d "$TOOLS_DIR/.$INSTALL_ID.stage.XXXXXX")"
cp "$MANIFEST_DIR/dependencies.json" "$STAGE/package.json"
cp "$MANIFEST_DIR/dependencies-lock.json" "$STAGE/package-lock.json"
printf 'Installing artifact renderer %s with locked dependencies…\n' "$VERSION"
if ! "$NPM_BIN" ci --prefix "$STAGE" --ignore-scripts --omit=dev --no-audit --no-fund >"$STAGE/install.log" 2>&1; then
  echo 'artifact renderer: installation failed; the previous install was kept' >&2
  # npm often appends a long usage guide after the actionable error.
  head -12 "$STAGE/install.log" >&2
  if [ "$(wc -l < "$STAGE/install.log")" -gt 20 ]; then
    echo '… npm output abbreviated …' >&2
    tail -8 "$STAGE/install.log" >&2
  fi
  exit 1
fi
if ! renderer_ready "$STAGE"; then
  echo 'artifact renderer: the installed package failed its readiness check; the previous install was kept' >&2
  exit 1
fi
rm -f "$STAGE/install.log"
# Both renames are on the same filesystem. No live install is removed until
# the complete replacement has passed its version/dependency probe.
if [ -e "$PREFIX" ]; then
  mv "$PREFIX" "$BACKUP"
fi
mv "$STAGE" "$PREFIX"
STAGE=""
[ ! -d "$BACKUP" ] || rm -rf "$BACKUP"
printf 'Artifact renderer %s installed\n' "$VERSION"
