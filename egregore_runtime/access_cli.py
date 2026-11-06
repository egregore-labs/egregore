"""``access show|check|shadow|materialize``: who can read what, and why.

Without ``--as`` each command speaks for the operator, decided from the
working tree. ``--as P`` decides an outside principal from the committed base
only, through ``policy.as_principal``, and narrows to what the operator holds.
``check`` names the deciding rule to an admin only: anyone else gets a plain
refusal for a path, so a held path and an absent one read alike.
``materialize --as P --to DIR`` writes P's read-only copy (``projection.materialize``).
"""

from __future__ import annotations

import argparse
from dataclasses import replace
import html
import json
import os
from pathlib import Path
import subprocess

from .contracts import Permission
from . import harness_cli, held, projection, shadow
from .policy import ACTIONS, Verdict, as_principal, check, is_admin, rule, tree_for
from .runtime import local_runtime

_PERMISSION = {"read": Permission.READ, "write": Permission.WRITE, "append": Permission.WRITE}


def register(commands) -> None:
    access = commands.add_parser("access", help="show and check who can read what")
    actions = access.add_subparsers(dest="access_command", required=True)
    show = actions.add_parser("show", help="the grant you, or an outside principal, holds")
    check_ = actions.add_parser("check", help="decide paths and name the rule that decided each")
    check_.add_argument("path", nargs="+")
    check_.add_argument("--action", choices=ACTIONS, default="read")
    check_.add_argument("--hand-over", action="store_true",
                        help="decide as what leaves this machine (a publish): every held class, under every policy")
    for parser in (show, check_):
        parser.add_argument("--as", dest="principal", metavar="P")
    show.add_argument("--json", action="store_true")
    count = actions.add_parser("shadow", help="where roster-v1 would hold what is served, by surface and class")
    copy = actions.add_parser("materialize", help="write an outside principal's read-only copy to a folder")
    copy.add_argument("--as", dest="principal", metavar="P", required=True)
    copy.add_argument("--to", required=True, metavar="DIR")
    for parser, handler in ((show, _show), (check_, _check), (count, _shadow), (copy, _materialize)):
        parser.add_argument("--harness", default=os.environ.get("EGREGORE_RUNTIME", "shell"))
        parser.set_defaults(handler=handler)


def _decide(args, *permissions: Permission):
    root = harness_cli._root()
    runtime = local_runtime(root, push_remote=False)
    actor = harness_cli._actor(runtime, root, args.harness)
    decisions = [runtime.authorize(actor, permission) for permission in permissions]
    if getattr(args, "principal", None) is not None:
        decisions = [as_principal(root, actor, decision, args.principal, permission)
                     for decision, permission in zip(decisions, permissions)]
    return runtime, actor, *decisions


def _capabilities(runtime, actor, decision) -> dict:
    """The Settings privacy panel's snapshot (formerly ``access-status``)."""
    def allowed(*permissions: Permission) -> bool:
        return all(runtime.authorize(actor, permission).allowed for permission in permissions)

    membership = actor.membership
    return {
        "status": "ok", "display_name": actor.actor.display_name, "actor_id": actor.actor.actor_id,
        "org_name": actor.profile.name, "org_id": actor.profile.org_id,
        "membership_status": membership.status if membership else "unknown",
        "roles": sorted(membership.roles) if membership else [], "admin": is_admin(decision),
        "capabilities": {
            "read": allowed(Permission.READ), "create": allowed(Permission.WRITE), "update": allowed(Permission.WRITE),
            "publish": allowed(Permission.SHARE), "notify": allowed(Permission.SHARE, Permission.EXECUTE),
            "org_settings": allowed(Permission.ADMINISTER),
        },
        "shared_memory_scope": sorted(decision.scopes),
    }


def _show(args: argparse.Namespace) -> int:
    if args.json and args.principal is None:
        try:
            print(json.dumps(_capabilities(*_decide(args, Permission.READ)), sort_keys=True))
        except Exception:
            print(json.dumps({"status": "attention"}))
        return 0
    _, actor, decision, appending = _decide(args, Permission.READ, Permission.WRITE)
    lines = [f"{args.principal.strip().casefold()} · outside principal" if args.principal is not None
             else f"{actor.actor.display_name} · {decision.audience}"]
    if not decision.allowed and not appending.allowed:
        lines.append("refused: " + "; ".join(dict.fromkeys(decision.reasons + appending.reasons)))
    else:
        source = f"committed {decision.memory_revision[:12]}" if decision.memory_revision else "working tree"
        rows = (("policy", (f"{decision.policy_epoch} · {source}",)), ("read", decision.read_prefixes),
                ("write", appending.write_prefixes), ("append", appending.append_prefixes + appending.write_prefixes),
                *((("release", decision.released),) if decision.released else ()))
        lines += [f"{name:<8}{', '.join(values) or '—'}" for name, values in rows]
        lenient = held.judge(decision.scope, decision.policy_epoch, (2,), False)[0] is None
        lines.append("holds   " + ("none (admin)" if is_admin(decision) else
                                   "admin: true in your reads; every class in hand-overs" if lenient else "every class"))
    print("\n".join(lines))
    return 0 if decision.allowed or appending.allowed else 1


def _unnamed(decision, verdict, action: str) -> bool:
    """Whether naming this verdict's rule could tell a non-admin what lies at the path.

    Every refusal of a path is plain (a refusal of the whole grant keeps its
    reasons), and so is a read of a working-tree path that does not exist.
    """
    if not verdict.allowed:
        return verdict.reason != "denied"
    return action == "read" and not decision.memory_revision and not os.path.lexists(verdict.resolved)


NAMES_HELD = "it names held material"


def _decided(decision, path: str, args, root) -> Verdict:
    """A path decided by the predicate. With ``--hand-over`` (a publish) it is decided where it resolves: in
    memory by the predicate, elsewhere by every class its own bytes hold; and a text naming held material is
    refused, as nothing published can be stripped of it."""
    spelled, memory = path.strip(), Path(root).resolve()
    if not args.hand_over:
        return check(decision, spelled, args.action, root=root, explain=True)
    resolved = (memory / spelled.removeprefix("memory/") if spelled.startswith("memory/") else Path(spelled)).resolve()
    outside = not spelled.startswith("memory/") and not resolved.is_relative_to(memory)
    verdict = Verdict(True, "allowed", spelled, resolved, "outside memory") if outside else check(  # a link in reads as its target
        decision, spelled if spelled.startswith("memory/") else "memory/" + resolved.relative_to(memory).as_posix(),
        args.action, root=root, explain=True)
    if not verdict.allowed:  # in the caller's spelling: a link's target is not named back
        return replace(verdict, canonical=spelled)
    try:
        data = resolved.read_bytes()
        found = tree_for(decision, root).classes(f".publish/{resolved.name}", data) if outside and not is_admin(decision) else ()
        text = data.decode("utf-8", "replace")
        if found or any(held.redact(decision, shown, root=root) != shown for shown in {text, html.unescape(text)}):
            return Verdict(False, f"held:{found[0]}" if found else NAMES_HELD, spelled)
    except (OSError, held.RedactionError):
        return Verdict(False, "invalid-path", spelled)
    return verdict


def _check(args: argparse.Namespace) -> int:
    runtime, actor, decision = _decide(args, _PERMISSION[args.action])
    admin = is_admin(runtime.authorize(actor, Permission.READ)) if args.principal is not None else is_admin(decision)
    if args.hand_over:
        decision = replace(decision, scope="hand-over")
    refused = 0
    for path in args.path:
        verdict = _decided(decision, path, args, runtime.canonical_root)
        plain = not admin and _unnamed(decision, verdict, args.action)
        refused += plain or not verdict.allowed
        named = verdict.note if verdict.note == "outside memory" else rule(decision, verdict, args.action)
        if args.hand_over and admin and verdict.allowed:  # an admin publishes held material only knowingly
            other = _decided(replace(decision, audience="member"), path, args, runtime.canonical_root)
            named += (f" · {rule(decision, other, args.action)} for everyone else"
                      if other.reason.startswith("held:") or other.reason == NAMES_HELD else "")
        print(f"{verdict.canonical or path}\t{args.action}\t"
              + ("refused\tnot available" if plain else f"{'allowed' if verdict.allowed else 'refused'}\t{named}"))
    return 1 if refused else 0


def _shadow(args: argparse.Namespace) -> int:
    runtime, _, decision = _decide(args, Permission.READ)
    counts, unsettled = shadow.tally(runtime.canonical_root)
    print(f"policy {decision.policy_epoch}"
          + ("" if decision.policy_epoch == "roster-v1-shadow" else " · shadow counting is off"))
    print(f"disagreements {sum(counts.values())}" + (" · partial" if unsettled else ""))
    for (surface, number), value in sorted(counts.items()):
        print(f"{surface} · {held.CLASS_NAMES.get(number, f'class {number}')}\t{value}")
    if unsettled.get(shadow.PENDING):
        print(f"not yet judged\t{unsettled[shadow.PENDING]}")
    if unsettled.get(shadow.UNJUDGED):
        print(f"could not be judged\t{unsettled[shadow.UNJUDGED]}")
    return 0


def _materialize(args: argparse.Namespace) -> int:
    """A status line only: the copy goes to the folder, never to the terminal."""
    _, _, decision = _decide(args, Permission.READ)
    handle = args.principal.strip().casefold()
    try:
        state, count = projection.materialize(harness_cli._root(), decision, Path(args.to))
    except (projection.ProjectionError, held.RedactionError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"{handle} · nothing was copied: {error}")
        return 1
    print(f"{handle} · {count} documents from committed memory {decision.memory_revision[:12]} · {state}")
    return 0
