#!/usr/bin/env bash
# release-safety.sh — preflight for npm + API releases.
#
# Inspects the packages/** and api/** changes that are about to ship and
# reports four things:
#   1. Supply-chain red flags (npm injection surface)
#   2. Version-bump correctness (changed package without a new version)
#   3. Infra-boundary respect (server-only concerns leaking into client pkgs)
#   4. Blast-radius summary (what will publish / deploy, in plain language)
#
# Two modes:
#   --mode warn   (default) print findings, ALWAYS exit 0. For local use,
#                 woven into /save. Never blocks a human (esp. non-technical
#                 teammates).
#   --mode block  print findings, exit 1 if any CRITICAL supply-chain finding.
#                 For the CI release workflow — the real enforcement point,
#                 where the npm token/publish actually lives.
#
# Compares against a base ref (default origin/develop) to find what changed.
# Supply-chain checks also inspect current package state regardless of diff.
#
# Usage: bin/release-safety.sh [--mode warn|block] [--base <ref>]

MODE="warn"
BASE="origin/develop"
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --base) BASE="$2"; shift 2 ;;
    *) shift ;;
  esac
done

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
cd "$ROOT" || exit 0

CRIT=0    # critical supply-chain findings
WARN=0    # advisory findings

red()  { printf '\033[0;31m%s\033[0m\n' "$1"; }
yel()  { printf '\033[0;33m%s\033[0m\n' "$1"; }
grn()  { printf '\033[0;32m%s\033[0m\n' "$1"; }
crit() { red   "  ✗ CRITICAL: $1"; CRIT=$((CRIT+1)); }
warn() { yel   "  ⚠ $1"; WARN=$((WARN+1)); }

# --- changed files vs base (fall back to working tree if base missing) ---
git fetch origin --quiet 2>/dev/null || true
if git rev-parse --verify "$BASE" >/dev/null 2>&1; then
  CHANGED=$(git diff --name-only "$BASE"...HEAD 2>/dev/null; git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
else
  CHANGED=$(git diff --name-only 2>/dev/null; git diff --cached --name-only 2>/dev/null)
fi
CHANGED=$(printf '%s\n' "$CHANGED" | sort -u | grep -v '^$')

CHANGED_PKGS=$(printf '%s\n' "$CHANGED" | grep -E '^packages/[^/]+/' | sed -E 's#^packages/([^/]+)/.*#\1#' | sort -u)
API_CHANGED=$(printf '%s\n' "$CHANGED" | grep -cE '^api/' 2>/dev/null)

echo "release-safety [$MODE] — base $BASE"
echo "────────────────────────────────────────────────────────"

if [ -z "$CHANGED_PKGS" ] && [ "${API_CHANGED:-0}" -eq 0 ]; then
  grn "No packages/** or api/** changes detected. Nothing to release-check."
  exit 0
fi

# ── 1 + 2 + 3: per-package checks ────────────────────────────────────────
for pkg in $CHANGED_PKGS; do
  dir="packages/$pkg"
  pj="$dir/package.json"
  # A packages/ subdir without a package.json is not an npm package
  # (e.g. emissary-plugin is a Claude plugin) — skip silently.
  [ -f "$pj" ] || continue
  echo ""
  echo "■ $pkg"

  name=$(jq -r '.name // "?"' "$pj" 2>/dev/null)
  ver=$(jq -r '.version // "?"' "$pj" 2>/dev/null)

  # --- 2. version bump correctness ---
  base_ver=$(git show "$BASE:$pj" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
  if [ -n "$base_ver" ] && [ "$ver" = "$base_ver" ]; then
    warn "$name: code changed but version is still $ver (== $BASE). Bump it or nothing publishes."
  fi
  if [ "$(jq -r '.private // false' "$pj" 2>/dev/null)" != "true" ]; then
    on_npm=$(npm view "$name@$ver" version 2>/dev/null)
    if [ -n "$on_npm" ]; then
      warn "$name@$ver is already on npm — this version will be SKIPPED (no republish)."
    fi
  fi

  # --- 1. supply-chain ---
  # install-time lifecycle scripts run on every consumer machine: the classic
  # injection vector. preinstall/install/postinstall = CRITICAL.
  for s in preinstall install postinstall; do
    if jq -e --arg s "$s" '.scripts[$s] // empty' "$pj" >/dev/null 2>&1; then
      crit "$name: defines a '$s' script — runs on consumers' machines on npm install. Injection vector; justify or remove."
    fi
  done
  # prepare/prepublishOnly run at publish/local time — advisory.
  for s in prepare prepublishOnly; do
    if jq -e --arg s "$s" '.scripts[$s] // empty' "$pj" >/dev/null 2>&1; then
      warn "$name: has a '$s' script (runs at publish/build) — confirm it's expected."
    fi
  done
  # No `files` whitelist => publishes the WHOLE directory (can leak .env, src, secrets).
  if ! jq -e '.files // empty' "$pj" >/dev/null 2>&1; then
    crit "$name: no \"files\" whitelist in package.json — npm would publish the entire package dir. Add a files list."
  fi
  # New/changed dependencies vs base — surface for human review.
  if [ -n "$base_ver" ]; then
    new_deps=$(comm -13 \
      <(git show "$BASE:$pj" 2>/dev/null | jq -r '(.dependencies // {}) | keys[]' 2>/dev/null | sort) \
      <(jq -r '(.dependencies // {}) | keys[]' "$pj" 2>/dev/null | sort) )
    if [ -n "$new_deps" ]; then
      warn "$name: new dependencies added — review each for trust: $(echo "$new_deps" | tr '\n' ' ')"
    fi
  fi
  # Obfuscation / dangerous primitives in published JS.
  js=$(find "$dir/lib" "$dir/bin" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' \) 2>/dev/null)
  if [ -n "$js" ]; then
    if grep -lE '\beval\(|new Function\(|fromCharCode\(|atob\(|Buffer\.from\([^,]+, *.base64.\)' $js >/dev/null 2>&1; then
      warn "$name: published JS uses eval/Function/base64-decode primitives — verify it's not obfuscated/injected."
    fi
    # very long minified lines are a smell in human-authored CLIs
    if awk 'length > 2000 {found=1} END{exit !found}' $js 2>/dev/null; then
      warn "$name: published JS has >2000-char lines (minified/obfuscated?) — eyeball it."
    fi
  fi

  # --- 3. infra-boundary: server-only concerns in a client package ---
  src=$(find "$dir/lib" "$dir/bin" -type f 2>/dev/null)
  if [ -n "$src" ]; then
    leak=$(grep -lnE 'SUPABASE_|NEO4J|DATABASE_URL|service_role|_SECRET|EGREGORE_API_KEY|GITHUB_TOKEN' $src 2>/dev/null | head -3)
    if [ -n "$leak" ]; then
      warn "$name: references server/secret identifiers (SUPABASE/NEO4J/SECRET/TOKEN…) in a published client package — likely belongs in api/, not here: $(echo "$leak" | tr '\n' ' ')"
    fi
  fi

  # --- tarball preview: what would actually publish ---
  pack=$( (cd "$dir" && npm pack --dry-run --json 2>/dev/null) | jq -r '.[0].files[].path' 2>/dev/null )
  if [ -n "$pack" ]; then
    bad=$(printf '%s\n' "$pack" | grep -iE '(^|/)\.env|(^|/)\.git|secret|credential|\.pem$|\.key$' | head -5)
    if [ -n "$bad" ]; then
      crit "$name: tarball would include sensitive-looking files: $(echo "$bad" | tr '\n' ' ')"
    fi
  fi
done

# ── api/ ───────────────────────────────────────────────────────────────
if [ "${API_CHANGED:-0}" -gt 0 ]; then
  echo ""
  echo "■ api/ ($API_CHANGED file(s) changed)"
  warn "api/ changed — merging to main auto-deploys to Railway. Verify the deploy after merge (deployed API ≠ local; the egregore service doesn't always auto-deploy — see memory)."
fi

# ── 4. blast-radius summary ──────────────────────────────────────────────
echo ""
echo "── Blast radius ──────────────────────────────────────────"
WILL_PUBLISH=""
for pkg in $CHANGED_PKGS; do
  pj="packages/$pkg/package.json"
  [ -f "$pj" ] || continue
  [ "$(jq -r '.private // false' "$pj" 2>/dev/null)" = "true" ] && continue
  name=$(jq -r '.name' "$pj" 2>/dev/null); ver=$(jq -r '.version' "$pj" 2>/dev/null)
  if [ -z "$(npm view "$name@$ver" version 2>/dev/null)" ]; then
    WILL_PUBLISH="$WILL_PUBLISH  • $name@$ver → npm (new)\n"
  fi
done
if [ -n "$WILL_PUBLISH" ]; then
  echo "Will PUBLISH to npm on merge to main:"; printf "$WILL_PUBLISH"
else
  echo "No new npm versions will publish (no changed package has a fresh version)."
fi
[ "${API_CHANGED:-0}" -gt 0 ] && echo "Will DEPLOY: api/ → Railway on merge to main."

echo ""
echo "────────────────────────────────────────────────────────"
echo "Findings: $CRIT critical, $WARN advisory."

if [ "$MODE" = "block" ] && [ "$CRIT" -gt 0 ]; then
  red "BLOCKED: $CRIT critical supply-chain finding(s). Resolve before publishing."
  exit 1
fi
if [ "$CRIT" -gt 0 ]; then
  yel "Critical findings present — review before shipping (local mode does not block)."
fi
exit 0
