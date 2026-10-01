"""Isolated shell/native-hook fixture; synthetic Observe backend, real executor.

This verifies transport, binding and state accounting, not QMD retrieval quality.
"""
from __future__ import annotations

import os
from pathlib import Path
import shlex
import shutil
import sys

ROOT = Path(__file__).resolve().parents[1]


def prepare(root):
    root = Path(root)
    tools = root / '.probe/tools'
    tools.mkdir(parents=True)
    shutil.copytree(ROOT / 'egregore_runtime', root / 'egregore_runtime',
                    ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
    for relative in ['bin/search.sh', 'bin/observe-context.sh', '.claude/hooks/retrieval-context.sh']:
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, target)
    shutil.copy2(ROOT / 'tests/harness_observe_fixture.py', tools / 'harness_observe_fixture.py')
    (tools / 'sitecustomize.py').write_text(
        'from harness_observe_fixture import FakeRuntime\n'
        'import egregore_runtime.runtime as runtime\n'
        'class FixtureRuntime(FakeRuntime):\n'
        '    def open_source(self, actor, path):\n'
        '        self.open_calls.append((actor, path))\n'
        '        return "The fixture courier departs at 09:30 UTC.\\n"\n'
        'runtime.local_runtime = lambda *args, **kwargs: FixtureRuntime()\n')
    (tools / 'python3').write_text('#!/bin/sh\nexec ' + shlex.quote(sys.executable) + ' "$@"\n')
    (tools / 'python3').chmod(0o755)
    (root / 'memory/knowledge/decisions').mkdir(parents=True)
    (root / 'memory/knowledge/decisions/runtime.md').write_text('The fixture courier departs at 09:30 UTC.\n')
    (root / 'egregore.json').write_text('{"mode":"local","org_id":"org_test","repos":[]}\n')
    (root / '.egregore-session-id').write_text('legacy-fixture\n')
    environment = {key: os.environ[key] for key in ['PATH','HOME','USER','LOGNAME','SHELL','LANG'] if key in os.environ}
    environment.update(EGREGORE_ROOT=str(root), CLAUDE_PROJECT_DIR=str(root),
        PYTHONPATH=os.pathsep.join([str(tools),str(root)]),
        PATH=str(tools)+os.pathsep+environment.get('PATH',''),
        EGREGORE_NO_TELEMETRY='1', PYTHONDONTWRITEBYTECODE='1')
    return environment
