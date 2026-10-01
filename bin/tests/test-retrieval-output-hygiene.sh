#!/usr/bin/env bash
set -euo pipefail

# Deterministic instruction parity. Behavioral packet delivery, bounded
# evidence, errors and continuations use disposable authorized fixtures in
# tests/test_native_result_delivery.py and the installed-tarball canary.
# Never query a developer's live organizational corpus from this CI gate.
SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
python3 - "$SCRIPT_DIR" <<'PYTEST'
from pathlib import Path
import re
import sys

root = Path(sys.argv[1])
passed = 0
errors = []
def check(condition, message):
    global passed
    if condition:
        passed += 1
        print(f"  ✓ {message}")
    else:
        errors.append(message)
        print(f"  ✗ {message}")

def read(path):
    return (root / path).read_text()

claude = read('CLAUDE.md')
check('bash bin/search.sh find "<query>" --kind <kind> --context-packet' in claude,
      'Claude discovery requests private evidence delivery')
check('reuse its authorized evidence' in claude,
      'Claude reuses supplied authorized evidence')
check('Prompt hooks attach identity and guidance only; they never retrieve evidence.' in claude,
      'startup supplies guidance without automatic retrieval')
check('Never re-print ranked results' in claude,
      'Claude does not expose internal ranking traces')
check('**Claude Code:** append --context-packet' in read('.claude/skills/search/SKILL.md'),
      'Claude search skill preserves private delivery')

for name in ['AGENTS.md', '.pi/APPEND_SYSTEM.md', '.prime/agent/APPEND_SYSTEM.md']:
    spec = read(name)
    commands = re.findall(r'bin/search\.sh[^\n]*', spec)
    check(not any('--context-packet' in command for command in commands),
          f'{name}: all search commands deliver evidence through native stdout')
    check('bash bin/search.sh find "<query>" --kind <kind>' in spec,
          f'{name}: model-selected discovery command present')
    check('model-internal' in spec,
          f'{name}: ranking traces stay out of user-facing prose')
    check('reuse its authorized evidence' in spec,
          f'{name}: supplied evidence is reused')
    check('Never relax the date boundary' in spec,
          f'{name}: refinements preserve date scope')
    check('Open necessary sources together' in spec,
          f'{name}: source reads can be batched')

contract = read('.claude/context/retrieval-investigation.md')
check('find --cursor TOKEN' in contract, 'discovery continuation is explicit')
check('--offset N' in contract and '--length N' in contract,
      'source window continuation is explicit')
check('On Claude append --context-packet' in contract,
      'shared contract scopes private packets to Claude')
check("The renderer's stdout IS the product card:" in read('.claude/skills/activity/SKILL.md')
      and 'appearing exactly once in the' in read('.claude/skills/activity/SKILL.md'),
      'explicit activity cards remain visible')
check("If the canonical body says the command's stdout is the card and must not "
      "be repeated, that rule assumes a host that displays command output in full; "
      "in Codex, paste the card once as the visible response in a `text` fenced "
      "block and do not print it a second time."
      in ' '.join(read('.codex/skills/activity/SKILL.md').split()),
      'Codex displays the renderer card once in the visible response')
check('readiness' in read('bin/search.sh'), 'readiness remains an explicit command')
print(f"\n{passed} passed, {len(errors)} failed")
sys.exit(bool(errors))
PYTEST
