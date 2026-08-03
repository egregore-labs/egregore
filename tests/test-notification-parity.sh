#!/usr/bin/env bash
# Consent policy and callers stay aligned across Claude, Codex, Pi, and jobs.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0
ok() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad() { echo "  ✗ $1" >&2; FAIL=$((FAIL + 1)); }

echo "test-notification-parity"

for spec in CLAUDE.md AGENTS.md .pi/APPEND_SYSTEM.md; do
  if grep -q 'Every external notification requires a separate' "$ROOT/$spec" &&
     grep -q 'Background jobs and automation may only' "$ROOT/$spec"; then
    ok "$spec carries the explicit-consent invariant"
  else
    bad "$spec is missing the explicit-consent invariant"
  fi
done

for runtime in codex pi; do
  bundle="$ROOT/packages/create-egregore/runtime/$runtime"
  if cmp -s "$ROOT/bin/notify.sh" "$bundle/bin/notify.sh" &&
     test -f "$bundle/.claude/context/notification-consent.md" &&
     grep -q 'Every external notification requires a separate' \
       "$bundle/AGENTS.md"; then
    ok "$runtime runtime bundle carries the transport and consent protocol"
  else
    bad "$runtime runtime bundle is missing notification-consent parity"
  fi
done

if grep -q 'notify.sh plan' \
  "$ROOT/.claude/context/notification-consent.md" &&
   grep -q 'notify.sh approve' \
  "$ROOT/.claude/context/notification-consent.md" &&
   grep -q 'notify.sh dispatch' \
  "$ROOT/.claude/context/notification-consent.md" &&
   grep -q 'batch approval' \
  "$ROOT/.claude/context/notification-consent.md"; then
  ok "shared protocol separates workflow and notification consent"
else
  bad "shared protocol no longer defines the dedicated checkpoint"
fi

LEGACY_CALLS="$(
  rg -n 'bin/notify\.sh (send|group)|\$NOTIFY"? (send|group)|notify\.sh"? (send|group)' \
    "$ROOT/bin" "$ROOT/.claude" "$ROOT/.codex" "$ROOT/.pi" \
    --glob '!notify.sh' \
    --glob '!tests/**' \
    --glob '!dataroom-*/**' \
    --glob '!*.html' \
    --glob '!*.json' \
    --glob '!notification-consent.md' 2>/dev/null || true
)"
if [ -z "$LEGACY_CALLS" ]; then
  ok "active harness callers cannot use legacy one-step notification commands"
else
  bad "active harness callers retain legacy notification commands"
  printf '%s\n' "$LEGACY_CALLS" >&2
fi

for job in \
  bin/capture-reconcile.sh \
  bin/handoff-lifecycle-job.sh \
  bin/handoff-run.sh \
  bin/handoff-save-publish.sh \
  bin/pulse-report.sh; do
  if grep -qE 'bash .*notify\.sh"? (approve|dispatch|send|group)' "$ROOT/$job"; then
    bad "$job can approve or dispatch unattended"
  else
    ok "$job is proposal-only"
  fi
done

if grep -q 'notify approval pending' "$ROOT/bin/handoff-run.sh" &&
   ! grep -q 'relayed to group' "$ROOT/bin/handoff-run.sh"; then
  ok "handoff exposes pending consent and has no DM-to-group fallback"
else
  bad "handoff consent status or no-fallback contract regressed"
fi

if grep -q 'separate exact Send / Edit / Cancel checkpoint' \
  "$ROOT/.codex/skills/answer/SKILL.md" &&
   bash "$ROOT/bin/codex-sync-skills.sh" --check >/dev/null; then
  ok "generated Codex adapters carry and pass the consent contract"
else
  bad "generated Codex adapters are missing or out of sync"
fi

if python3 - "$ROOT/api/main.py" <<'PY'
import ast
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
tree = ast.parse(path.read_text())
allowed = {"notify_send", "notify_group"}
violations = []
for node in tree.body:
    if not isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)):
        continue
    for child in ast.walk(node):
        if not isinstance(child, ast.Await) or not isinstance(child.value, ast.Call):
            continue
        func = child.value.func
        if isinstance(func, ast.Name) and func.id in {"send_message", "send_group"}:
            if node.name not in allowed:
                violations.append(f"{path}:{child.lineno}:{node.name} calls {func.id}")
if violations:
    print("\n".join(violations))
    raise SystemExit(0)
raise SystemExit(1)
PY
then
  bad "API background routes still dispatch notifications"
else
  ok "API background routes cannot dispatch notifications"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
