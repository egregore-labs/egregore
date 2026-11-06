#!/usr/bin/env bash
# Every bin/ script a SHIPPED skill references must ship in the same bundle.
# A packaged skill that names a missing executable makes every session
# rediscover the flow by spelunking bin/ — observed live 2026-09-01 when the
# bundled handoff skill referenced bin/handoff-preview.sh, which the bundle
# did not carry. This test turns that class of drift into a build failure.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TOOL_ROOT="$ROOT"
# Explicit fixture root lets regression tests mutate disposable trees only.
if [ "$#" -gt 0 ]; then
  if [ "$#" -ne 2 ] || [ "$1" != "--root" ] || [ ! -d "$2" ]; then
    echo "Usage: $0 [--root <source-tree>]" >&2
    exit 2
  fi
  ROOT="$(cd "$2" && pwd)"
fi
BUNDLES=(claude codex pi prime)
PASS=0; FAIL=0
ALL_REFS=""
pass() { PASS=$((PASS+1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL+1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

# Scripts a shipped skill may reference without shipping, each with a reason:
#   bin/loom.sh — Loom is availability:internal; the referencing skills
#     (view) explicitly fall through to their script path when it is absent.
#   bin/capability-distribution.mjs — source-instance distribution engine;
#     the referencing skills (save, test) guard on its presence.
TOLERATED="bin/loom.sh bin/capability-distribution.mjs"

tolerated() {
  local needle="$1" t
  for t in $TOLERATED; do [ "$t" = "$needle" ] && return 0; done
  return 1
}

# Normalize literal root placeholders without evaluating shell expressions.
# Match complete path tokens: packages/foo/bin/cli.js is not root bin/cli.js,
# and bin/loom.sh-example must not count as the tolerated bin/loom.sh.
skill_refs() {
  sed -E 's|\$\{?[A-Za-z_][A-Za-z0-9_]*\}?/bin/|bin/|g; s|<[^>]+>/bin/|bin/|g' "$1" \
    | grep -oE '(^|[^A-Za-z0-9_./-])(\./)?bin/[A-Za-z0-9_./-]+' \
    | sed -E 's/^[^b.]//; s|^\./||; s/\.+$//' \
    | grep -E '\.(sh|py|mjs|cjs|js)$' | sort -u
}

check_tree() {
  local tree="$1" label="$2"
  [ -d "$tree" ] || { fail "$label bundle tree missing at $tree"; return; }
  local missing="" skill name ref count=0
  while IFS= read -r skill; do
    count=$((count+1))
    name="${skill#"$tree/"}"
    while IFS= read -r ref; do
      [ -z "$ref" ] && continue
      ALL_REFS="${ALL_REFS}${ref}"$'\n'
      tolerated "$ref" && continue
      [ -f "$tree/$ref" ] || missing="${missing}${name} → ${ref}\n"
    done < <(skill_refs "$skill")
  done < <(find "$tree" -type f -name "SKILL.md")
  if [ "$count" -eq 0 ]; then
    fail "$label: bundle contains no shipped skills"
  elif [ -z "$missing" ]; then
    pass "$label: every shipped skill's bin/ reference ships in the bundle"
  else
    fail "$label: shipped skills reference scripts the bundle does not carry" "$(printf '%b' "$missing" | sort -u | tr '\n' ' ')"
  fi
}

for bundle in "${BUNDLES[@]}"; do
  # Pi/Prime carry Codex skills; Prime also adds a native bridge skill.
  check_tree "$ROOT/packages/create-egregore/runtime/$bundle" "$bundle"
done

# No shipped surface may advertise bare `node` invocations: the machine's
# node can be a broken shim (Volta), and models copy usage banners verbatim
# — observed live when a Codex session read codex-skill-render.mjs's banner
# and bypassed bin/node-run.sh into a Volta error. Node always runs through
# the adapter.
bare_node=""
for bundle in "${BUNDLES[@]}"; do
  tree="$ROOT/packages/create-egregore/runtime/$bundle"
  [ -d "$tree" ] || continue
  found=$(find "$tree" -type f \( -name '*.mjs' -o -name 'SKILL.md' \) \
    -exec grep -nH "node bin/" {} + 2>/dev/null | grep -v "node-run" || true)
  [ -n "$found" ] && bare_node="${bare_node}${found}\n"
  # Spawn-level: shipped shell scripts must never exec bare node/npx either.
  # Sole tolerated spawn: connect-refresh.sh refreshing the installer itself
  # via npx — the same channel the user installed through; a broken npx there
  # fails loudly instead of degrading retrieval or rendering.
  spawns=$(grep -rnE '(^|[;&|[:space:]])(node|npx) ' "$tree"/bin/*.sh 2>/dev/null \
    | grep -vE "node-run\.sh|node_modules|#.*(node|npx)|node not available|command -v node|--version|connect-refresh\.sh:.*create-egregore --refresh-connect" || true)
  [ -n "$spawns" ] && bare_node="${bare_node}${spawns}\n"
done
if [ -z "$bare_node" ]; then
  pass "no shipped surface instructs bare node (bin/node-run.sh everywhere)"
else
  fail "bare node invocations shipped" "$(printf '%b' "$bare_node" | head -4)"
fi

# The shipped Python runtime must carry every source module selected for OSS.
# Use the builders' actual distribution authority, not a second exemption list.
# The on-disk scan remains intentional: builders take git-tracked files only,
# so untracked public modules must still fail until they ship with their callers.
PYTHON_EXCLUSIONS=""
if ! PYTHON_EXCLUSIONS="$(bash "$TOOL_ROOT/bin/node-run.sh" --input-type=module - "$TOOL_ROOT" "$ROOT" <<'NODE'
import path from 'node:path';
import { pathToFileURL } from 'node:url';
const [toolRoot, sourceRoot] = process.argv.slice(2);
try {
  const { loadDistribution, validateDistribution, excludedComponentPaths } = await import(
    pathToFileURL(path.join(toolRoot, 'bin/capability-distribution.mjs')).href);
  const distribution = loadDistribution(path.join(sourceRoot, 'capability-distribution.json'));
  const errors = validateDistribution(distribution, sourceRoot);
  if (errors.length) throw new Error(errors.slice(0, 4).join('; '));
  for (const location of excludedComponentPaths(distribution, ['oss'], 'available')) {
    if (location === 'egregore_runtime' || location.startsWith('egregore_runtime/')) console.log(location);
  }
} catch (error) {
  console.error(`runtime distribution authority unavailable: ${error.message}`);
  process.exit(1);
}
NODE
)"; then
  fail "runtime distribution authority unavailable; no Python exclusions accepted"
  PYTHON_EXCLUSIONS=""
fi

python_excluded() {
  local relative="$1" excluded
  while IFS= read -r excluded; do
    [ -z "$excluded" ] && continue
    case "$relative" in "$excluded"|"$excluded"/*) return 0 ;; esac
  done <<< "$PYTHON_EXCLUSIONS"
  return 1
}

if [ ! -d "$ROOT/egregore_runtime" ]; then
  fail "source egregore_runtime tree missing at $ROOT/egregore_runtime"
else
  for bundle in "${BUNDLES[@]}"; do
    tree="$ROOT/packages/create-egregore/runtime/$bundle"
    missing_py=""; excluded_py=""
    while IFS= read -r module; do
      rel="${module#"$ROOT/"}"
      if python_excluded "$rel"; then
        [ ! -e "$tree/$rel" ] && [ ! -L "$tree/$rel" ] || excluded_py="${excluded_py}${rel}\n"
        continue
      fi
      [ -f "$tree/$rel" ] || missing_py="${missing_py}${rel}\n"
    done < <(find "$ROOT/egregore_runtime" -type f -name '*.py' ! -path '*/__pycache__/*' | sort)
    if [ ! -d "$tree/egregore_runtime" ]; then
      fail "$bundle bundle is missing egregore_runtime"
    elif [ -n "$excluded_py" ]; then
      fail "$bundle bundle carries excluded runtime modules" "$(printf '%b' "$excluded_py" | tr '\n' ' ')"
    elif [ -z "$missing_py" ]; then
      pass "$bundle: shipped egregore_runtime matches OSS-selected source"
    else
      fail "$bundle bundle is missing runtime modules" "$(printf '%b' "$missing_py" | tr '\n' ' ')"
    fi
  done
fi

# The tolerated list must stay honest: a tolerated script that no shipped
# skill references anymore is stale and should be removed.
for t in $TOLERATED; do
  if printf '%s' "$ALL_REFS" | grep -Fx "$t" >/dev/null; then
    pass "tolerated $t is still referenced (entry current)"
  else
    fail "tolerated $t is no longer referenced — remove it from TOLERATED"
  fi
done

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
