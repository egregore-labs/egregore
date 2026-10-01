"""Hermetic eval chassis substrate: pinned code plus labeled synthetic probes."""
from functools import lru_cache
from pathlib import Path
import shutil
from tempfile import TemporaryDirectory

_directories = []  # keep fixtures alive until interpreter cleanup


@lru_cache(maxsize=1)
def fixture_root():
    directory = TemporaryDirectory(prefix="egregore-eval-fixture-")
    _directories.append(directory)
    root = Path(directory.name)
    shutil.copytree(Path(__file__).parent / "fixtures/egregore-value-v2", root, dirs_exist_ok=True)
    # These test-only files exercise inclusion/exclusion, not historical facts.
    probes = {
        "memory/people/oz.md": "# Synthetic fixture member\n",
        "memory/knowledge/research/2026-05-28-self-host-feasibility.md": "Synthetic quarantined fixture\n",
        "bin/session-start.sh": "# Synthetic legitimate script fixture\n",
        "bin/eval-egregore-value.sh": "# hidden_gold test marker\n",
        "tmp/egregore_deck_pilot_plan_v2.md": "scores.json synthetic test marker\n",
        "eg_eval/cli.py": "# hidden_gold test marker\n",
        "eg_eval/execv2/adapter.py": "# Synthetic excluded harness fixture\n",
        ".egregore/context.md": "Synthetic excluded runtime state\n",
        "evals/deck/scores.json": "{}\n",
    }
    for relative, body in probes.items():
        target = root / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(body)
    return root
