#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ✓ $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  ✗ $1"; [ -n "${2:-}" ] && echo "    $2"; }

echo "Testing: receiver-facing handoff UX"
echo ""

PY_RESULT=$(python3 - "$ROOT" <<'PY' 2>&1
import ast
import json
import re
import sys

root = sys.argv[1]
sys.path.insert(0, root)

from api.handoff_render import render_handoff_html

forbidden = re.compile(
    r'\b(?:POST|GET|curl|npx|MCP)\b|reply_endpoint|extension_endpoint|Content-Type|custom headers|/api/artifacts/handoff/[A-Za-z0-9_-]+/extend'
)

artifact = {
    "@context": "https://egregore.xyz/spec/handoff/v1",
    "version": "1.0",
    "id": "https://egregore.xyz/h/testUx42",
    "kind": "handoff",
    "topic": "Receiver UX cleanup",
    "claim": "Receiver-facing handoffs should hide transport mechanics.",
    "ask": "Confirm the reply flow stays clear.",
    "author": {"handle": "oz", "display": "Oz"},
    "audience": {"addressed_to": [{"handle": "ren", "display": "Ren"}], "visible_to": "public", "extendable_by": "anyone"},
    "receiver_instructions": "Review the claim, then help draft a reply.",
    "body": {"prose": "This handoff contains clean prose for renderer regression checks.", "sidecar": {"next_steps": ["Review", "Reply"]}},
    "references": [],
    "repo_state": [],
    "extensions": [],
    "created_at": "2026-05-14T00:00:00Z",
    "updated_at": "2026-05-14T00:00:00Z",
}

html = render_handoff_html(artifact).decode("utf-8")
checks = {
    "python-render": html,
}

source = open(f"{root}/api/main.py", encoding="utf-8").read()
module = ast.parse(source)
doc_const = next(node for node in module.body if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "_DOC_PRESENTATION_GUIDANCE" for t in node.targets))
receiver_fn = next(node for node in module.body if isinstance(node, ast.FunctionDef) and node.name == "_receiver_hints")
namespace = {}
exec(compile(ast.Module(body=[doc_const, receiver_fn], type_ignores=[]), "receiver_hints", "exec"), namespace)
for harness in ["claude-code", "codex", "cursor", "chatgpt", "generic"]:
    hints = namespace["_receiver_hints"](harness, "testUx42")
    checks[f"receiver-hints-{harness}"] = json.dumps(hints, sort_keys=True)
    for banned_key in ("reply_endpoint", "extension_endpoint", "mcp_server", "install"):
        if banned_key in hints:
            print(f"FAIL receiver-hints-{harness}: banned key {banned_key}")
            sys.exit(1)

# documentation kind must inject the section-by-section guidance for every harness
for harness in ["claude-code", "codex", "cursor", "chatgpt", "generic"]:
    doc_hints = namespace["_receiver_hints"](harness, "testUx42", "documentation")
    instr = doc_hints.get("instructions", "")
    if "DOCUMENTATION MODE" not in instr or "section by section" not in instr:
        print(f"FAIL doc-kind-{harness}: missing documentation guidance in instructions")
        sys.exit(1)
    # documentation kind on claude-code must NOT include the AskUserQuestion sentence
    # (otherwise the agent skips the doc and jumps to the ask)
    if harness == "claude-code" and "AskUserQuestion to present the claim" in instr:
        print(f"FAIL doc-kind-claude-code: AskUserQuestion clause survives doc mode")
        sys.exit(1)

# non-documentation kind on claude-code MUST keep the AskUserQuestion clause
default_cc = namespace["_receiver_hints"]("claude-code", "testUx42", "question")
if "AskUserQuestion to present the claim" not in default_cc.get("instructions", ""):
    print("FAIL non-doc claude-code lost AskUserQuestion clause")
    sys.exit(1)

for name, text in checks.items():
    match = forbidden.search(text)
    if match:
        print(f"FAIL {name}: {match.group(0)}")
        sys.exit(1)

print("OK")
PY
)

if [ "$PY_RESULT" = "OK" ]; then
  pass "Python render and receiver hints hide transport mechanics"
else
  fail "Python receiver UX check failed" "$PY_RESULT"
fi

NODE_RESULT=$(cd "$ROOT/packages/egregore-handoff" && node --input-type=module <<'JS' 2>&1
import { generateAgentBlock } from './lib/agent-block.js'

const forbidden = /\b(?:POST|GET|curl|npx|MCP)\b|reply_endpoint|extension_endpoint|Content-Type|custom headers|\/api\/artifacts\/handoff\/[A-Za-z0-9_-]+\/extend/
const block = generateAgentBlock({
  id: 'https://egregore.xyz/h/testUx42',
  topic: 'Receiver UX cleanup',
  kind: 'handoff',
  claim: 'Receiver-facing handoffs should hide transport mechanics.',
  ask: 'Confirm the reply flow stays clear.',
  author: { handle: 'oz', display: 'Oz' },
  audience: { addressed_to: [] },
  body: { prose: 'Clean prose.' },
  extensions: [],
})

const match = forbidden.exec(block)
if (match) {
  console.log(`FAIL agent-block: ${match[0]}`)
  process.exit(1)
}
console.log('OK')
JS
)

if [ "$NODE_RESULT" = "OK" ]; then
  pass "Agent copy block hides transport mechanics"
else
  fail "Agent copy block check failed" "$NODE_RESULT"
fi

# Belt-and-suspenders: even if _receiver_hints regresses, the egress
# sanitizer must strip the leaky keys before they hit the wire.
SANITIZER_RESULT=$(python3 - "$ROOT" <<'PY' 2>&1
import ast
import sys

root = sys.argv[1]
source = open(f"{root}/api/main.py", encoding="utf-8").read()
module = ast.parse(source)
sanitizer_fn = next(node for node in module.body if isinstance(node, ast.FunctionDef) and node.name == "_sanitize_receiver_hints")
leaky_keys = next(node for node in module.body if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "_LEAKY_HINT_KEYS" for t in node.targets))
leaky_setup_keys = next(node for node in module.body if isinstance(node, ast.Assign) and any(getattr(t, "id", None) == "_LEAKY_SETUP_KEYS" for t in node.targets))

ns = {}
exec(compile(ast.Module(body=[leaky_keys, leaky_setup_keys, sanitizer_fn], type_ignores=[]), "sanitizer", "exec"), ns)
sanitize = ns["_sanitize_receiver_hints"]

dirty = {
    "harness_detected": "generic",
    "reply_endpoint": "https://egregore.xyz/h/X/reply",
    "extension_endpoint": "https://railway/X/extend",
    "mcp_server": "https://mcp/X",
    "install": "npx whatever",
    "reply_method": "POST",
    "instructions": "clean prose only",
    "setup": {
        "connector_url": "https://mcp/X",
        "user_message": "settings...",
        "confirm_link_template": "https://egregore.xyz/X/reply?...",
    },
}
clean = sanitize(dirty)
for banned in ("reply_endpoint", "extension_endpoint", "mcp_server", "install", "reply_method", "setup"):
    if banned in clean:
        print(f"FAIL sanitizer left {banned} in output")
        sys.exit(1)
if clean.get("harness_detected") != "generic" or "instructions" not in clean:
    print("FAIL sanitizer stripped non-leaky fields")
    sys.exit(1)

# Sanitizer keeps a partial setup dict with only safe keys.
partial = sanitize({"setup": {"connector_url": "x", "tone": "friendly"}})
if "setup" in partial and "connector_url" in partial["setup"]:
    print("FAIL sanitizer kept connector_url in setup")
    sys.exit(1)
if "setup" not in partial:
    pass
elif partial["setup"].get("tone") != "friendly":
    print("FAIL sanitizer dropped safe setup keys")
    sys.exit(1)

# Empty / None must round-trip safely.
for case in (None, {}, {"harness_detected": "claude-code"}):
    out = sanitize(case)
    if not isinstance(out, dict):
        print("FAIL sanitizer returned non-dict for", case)
        sys.exit(1)

print("OK")
PY
)

if [ "$SANITIZER_RESULT" = "OK" ]; then
  pass "Egress sanitizer strips leaky transport keys"
else
  fail "Egress sanitizer check failed" "$SANITIZER_RESULT"
fi

echo ""
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1 || exit 0
