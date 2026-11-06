"""Executed with -I -B and cwd in a delivered tree, never imported from checkout."""
import argparse
import contextlib
from datetime import UTC, datetime
import importlib
import io
import json
import os
from pathlib import Path
import sys
from unittest.mock import patch

tree = Path.cwd().resolve()
sys.path.insert(0, str(tree))
for name in ("egregore_runtime", "harness_cli", "runtime", "status", "projection", "access_cli"):
    importlib.import_module(name if name == "egregore_runtime" else "egregore_runtime." + name)
from egregore_runtime import harness_cli, runtime, status

assert not (tree / "egregore_runtime/document_lines.py").exists()
parser = harness_cli._parser()
commands = next(action.choices for action in parser._actions if isinstance(action, argparse._SubParsersAction))
assert "mind" not in commands and not any(name.startswith("member") for name in commands)
assert not any(action.dest.startswith("member") for action in parser._actions)

(tree / "memory/wraps").mkdir(parents=True, exist_ok=True)
(tree / "egregore.json").write_text(json.dumps({"org_name": "Fixture", "slug": "fixture", "mode": "local",
    "profile": {"default_policy": "all-access-v1"}}))
(tree / ".egregore-state.json").write_text(json.dumps({"github_username": "ada", "display_name": "Ada"}))
os.environ["EGREGORE_ROOT"] = str(tree)
local = runtime.local_runtime(tree, push_remote=False)
actor = local.resolve_actor(session_id="delivery-test", harness="claude")

# Drive the prompt adapter as the harness tests do. Keep episode/identity work
# outside this assertion: the real record_notice call must be harmless absent.
with patch.object(harness_cli.sys, "stdin", io.StringIO('{"prompt":"hello"}')), \
        patch.object(harness_cli, "_observe_episode", return_value=contextlib.nullcontext()), \
        patch.object(harness_cli, "_prompt_hook_in_episode", return_value=0), \
        patch.object(harness_cli, "record_notice", wraps=harness_cli.record_notice) as notice:
    assert harness_cli.main(["prompt-hook", "--harness", "claude"]) == 0
    notice.assert_called_once_with(tree, "asked", "claude", None)

marked = "# Session: marked\n\n**Author**: ada\n**Date**: 2026-11-03T10:00:00Z\n\n## Open Threads\n- [ ] Ship <!-- ^abc123 -->\n"
ordinary = marked.replace("marked", "ordinary").replace(" <!-- ^abc123 -->", "")
for name, text in (("marked", marked), ("ordinary", ordinary)):
    (tree / f"memory/wraps/{name}.md").write_text(text)
    assert status._extract_open_threads(text) == ["Ship"]
service = status.CanonicalStatusSnapshotService(local, tree, clock=lambda: datetime(2026, 11, 3, 12, tzinfo=UTC))
snapshot = service.build(actor)
assert len(snapshot["my_sessions"]) == 2, snapshot
assert all(row["openThreads"] == ["Ship"] for row in snapshot["my_sessions"])
assert status.unmarked("ordinary text\t ") == "ordinary text\t "
assert status.unmarked("marked\t <!-- ^abc123 -->\t") == "marked"
for name, module in tuple(sys.modules.items()):
    if name == "egregore_runtime" or name.startswith("egregore_runtime."):
        assert Path(module.__file__).resolve().is_relative_to(tree), (name, module.__file__)
print("isolated imports, command table, prompt delivery and marked/unmarked status passed")
