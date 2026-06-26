#!/usr/bin/env bash
# Render a real artifact through this BRANCH's local MERIDIAN render code —
# NOT `npx egregore-artifacts` (which pulls the published npm 0.10.2 = the OLD design).
# This is how Design Convention Round-1 testers see the new design on real output
# before it merges to production. See memory/feedback/design-convention-r1/GUIDE.md.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
PKG="$ROOT/packages/egregore-artifacts"
SAMPLES="$ROOT/skills/preview-design/samples"
CLI="$PKG/bin/cli.js"

SURFACE="${1:-}"
FILE="${2:-}"

usage() {
  echo "Usage: bash skills/preview-design/render.sh <surface> [file]"
  echo "  surfaces: document [file.md] | handoff [file.json] | platform | emissary"
  echo "  (no file → renders the bundled sample)"
}

case "$SURFACE" in
  emissary)
    echo "Emissary is harness-only for Round 1 — its renderer is server-side and not"
    echo "design-system-wired yet (that's the #1 Round-2 task). Review it here:"
    echo ""
    echo "  https://egregore.xyz/view/curvelabs/design-convention   (emissary tab)"
    echo ""
    echo "Then give feedback: say to your Egregore → \"Run the Design Convention feedback protocol\""
    exit 0 ;;
  document|handoff|platform|board|activity|network) : ;;
  ""|-h|--help) usage; exit 0 ;;
  *) echo "Unknown surface: $SURFACE"; usage; exit 1 ;;
esac

# Local package deps are absent on a fresh checkout / worktree — install once.
if [ ! -d "$PKG/node_modules" ]; then
  echo "Installing the local renderer's deps (one-time, ~30–60s)…"
  npm install --prefix "$PKG" >/dev/null 2>&1 \
    || { echo "✗ npm install failed. Run manually: npm install --prefix \"$PKG\""; exit 1; }
fi

case "$SURFACE" in
  document)        node "$CLI" document   "${FILE:-$SAMPLES/document.md}" ;;
  handoff)         node "$CLI" handoff-v1 "${FILE:-$SAMPLES/handoff.json}" ;;
  platform|board)  node "$CLI" board ;;
  activity)        node "$CLI" activity ;;
  network)         node "$CLI" network ;;
esac

echo ""
echo "✓ Rendered '$SURFACE' through the branch's MERIDIAN code — the real"
echo "  Round-2-bound renderer, not the hand-built harness mock."
echo "  When you've looked it over, give feedback: say to your Egregore →"
echo "  \"Run the Design Convention feedback protocol\""
