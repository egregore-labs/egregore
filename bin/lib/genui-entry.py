"""Run the interface-taste CLI, or name the Runtime update when it cannot run.

This file stays outside egregore_runtime/: /update carries bin/ but never the
Runtime, so a missing, older or partly updated Runtime fails here, where one
line can say what to run, instead of in a traceback. That includes the
package's own initialisation, which runs before any module inside it, and a
partial update that brought the taste modules without what they call.
"""

import importlib
import sys

OUTDATED_RUNTIME = (
    "genui: this workspace's Egregore Runtime is too old for interface taste; "
    "to update it, run `egregore`, press s for Settings, then choose Runtime update"
)

# What taste calls in Runtime modules it does not ship with.
REQUIRED = (
    ("egregore_runtime.writeback", "CanonicalArtifactWriteback", "create_file"),
    ("egregore_runtime.runtime", "EgregoreRuntime", "_writeback"),
    ("egregore_runtime.runtime", "EgregoreRuntime", "authorize"),
    ("egregore_runtime.runtime", "EgregoreRuntime", "resolve_actor"),
)

try:
    from egregore_runtime.taste_cli import main

    for module, owner, capability in REQUIRED:
        if not callable(getattr(getattr(importlib.import_module(module), owner), capability, None)):
            raise AttributeError(f"{owner}.{capability}")
except (ImportError, SyntaxError, AttributeError):
    print(OUTDATED_RUNTIME, file=sys.stderr)
    raise SystemExit(3)

raise SystemExit(main())
