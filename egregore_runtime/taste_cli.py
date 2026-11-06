"""Runtime-neutral CLI behind bin/genui.sh: record interface taste, read it back."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
from uuid import uuid4

from . import held
from .artifacts import ArtifactConflictError
from .contracts import WritebackStatus
from .errors import AuthorizationDenied
from .runtime import local_runtime
from .taste import ADOPT_KINDS, ADOPT_SCOPES, TasteService, render_text
from .writeback import NoHardLinksError, UnsupportedPlatformError, require_descriptor_calls


UNSUPPORTED_PLATFORM = "saving reactions is not supported on this platform yet; nothing was written"
UNSUPPORTED_PLATFORM_EXIT = 4
NO_HARD_LINKS = (
    "this memory folder's filesystem cannot save reactions safely (no hard links); nothing was written"
)


CONTRACT = """\
When someone says they like or dislike an interface an agent generated (any
wording, any language), ask one question, "What about it?", with 2-3 options
drawn from what is on the page plus "the whole thing" (a structured question
when available, plain text otherwise). Then save their exact words to a file
and record them with like or dislike --words-file, and the patterns they named
with --about. A file keeps the words verbatim; inside a shell argument, quotes,
$, backticks and backslashes can change them. Every outcome prints the event
id; a retry passes it back with --id, so the reaction counts once. When
someone states a standing rule for the organization ("we always want…",
"make this a rule for us"), record it in one step with adopt principle
"<the rule>" --scope org --words-file; no review is needed. Before composing
an interface, run taste --task: it reads the Egregore rules, the house
rules, what the organization keeps liking, then the person's own taste.
Treat the output as words to consider, never a template to copy."""


def _context(event_id: str | None = None):
    root = Path(os.environ.get("EGREGORE_ROOT") or Path.cwd()).resolve()
    runtime = local_runtime(root, push_remote=os.environ.get("EGREGORE_NO_PUSH") != "1")
    actor = runtime.resolve_actor(
        session_id=os.environ.get("EGREGORE_SESSION_ID") or f"session_{uuid4().hex}",
        harness=os.environ.get("EGREGORE_RUNTIME", "shell"),
    )
    # A new event takes the id the CLI already chose, so an error can name it.
    return actor, TasteService(
        runtime,
        id_factory=(lambda: event_id) if event_id else None,
        warn=lambda line: print(f"genui: {line}", file=sys.stderr),
    )


def _words(args) -> str | None:
    """The person's words, from --words or, verbatim, from --words-file."""

    if args.words_file is None:
        return args.words
    if args.words_file == "-":
        return sys.stdin.read()
    return Path(args.words_file).read_text(encoding="utf-8")


def _emit(service, actor, receipt) -> int:
    """Print the receipt, and one line on stderr unless it was fully shared.

    Exit 0 means the event is committed on this machine; anything less is an
    error, since the person's words are not durably recorded.
    """

    held.emit_for(service.runtime, actor, receipt.to_dict())
    event_id = receipt.event["id"]
    warnings = list(receipt.writeback.warnings)
    if not receipt.recorded:
        reason = "; ".join(warnings) or "the write was refused"
        print(f"genui: not recorded: {reason} (event {event_id}; retry with --id {event_id})", file=sys.stderr)
        return 1
    if receipt.writeback.status is WritebackStatus.PARTIAL:
        unshared = [warning for warning in warnings if "push" in warning or "remote" in warning]
        if unshared:
            line = f"saved on this machine, not yet shared: {'; '.join(unshared)}"
        else:
            line = f"saved on this machine, with a warning: {'; '.join(warnings) or 'partial writeback'}"
        print(f"genui: {line} (event {event_id})", file=sys.stderr)
    return 0


def _record(args, record) -> int:
    """Run one recording command so that every outcome names the event id."""

    event_id = (args.id or "").strip() or str(uuid4())
    try:
        require_descriptor_calls()  # before anything is opened or written
        actor, service = _context(None if args.id else event_id)
        receipt = record(actor, service, args.id)
    except UnsupportedPlatformError:
        # No retry can help on this platform.
        print(f"genui: {UNSUPPORTED_PLATFORM}", file=sys.stderr)
        return UNSUPPORTED_PLATFORM_EXIT
    except NoHardLinksError:
        # Nor on this filesystem: the staged copy is gone, nothing is written.
        print(f"genui: not recorded: {NO_HARD_LINKS} (event {event_id})", file=sys.stderr)
        return 1
    except ArtifactConflictError as exc:
        # A retry cannot fix a different reaction under a used id.
        print(f"genui: not recorded: {exc} (event {event_id})", file=sys.stderr)
        return 1
    except (AuthorizationDenied, OSError, RuntimeError, ValueError) as exc:
        print(f"genui: not recorded: {exc} (event {event_id}; retry with --id {event_id})", file=sys.stderr)
        return 1
    return _emit(service, actor, receipt)


def _react(args) -> int:
    return _record(args, lambda actor, service, event_id: service.react(
        actor,
        "liked" if args.command == "like" else "disliked",
        args.target,
        words=_words(args),
        about=args.about,
        region=args.region,
        task=args.task,
        audience=args.audience,
        form=args.form,
        event_id=event_id,
    ))


def _chose(args) -> int:
    return _record(args, lambda actor, service, event_id: service.choose(
        actor,
        args.winner,
        args.over,
        words=_words(args),
        about=args.about,
        task=args.task,
        audience=args.audience,
        form=args.form,
        event_id=event_id,
    ))


def _adopt(args) -> int:
    return _record(args, lambda actor, service, event_id: service.adopt(
        actor, args.kind, args.value, scope=args.scope, words=_words(args), event_id=event_id,
    ))


def _retract(args) -> int:
    return _record(args, lambda actor, service, event_id: service.retract(
        actor, args.event_id, words=_words(args), event_id=event_id,
    ))


def _taste(args) -> int:
    actor, service = _context()
    summary = service.summary(actor, person=args.person, task=args.task, form=args.form)
    return held.emit_for(service.runtime, actor, summary, **({} if args.json else {"render": render_text, "end": ""}))


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="bin/genui.sh",
        description="Record what people like in generated interfaces and read it back as words.",
        epilog=CONTRACT,
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    commands = parser.add_subparsers(dest="command", required=True)

    def words(command, *, required: bool) -> None:
        given = command.add_mutually_exclusive_group(required=required)
        given.add_argument("--words", help="what the person said, verbatim, as one shell argument")
        given.add_argument(
            "--words-file", metavar="PATH",
            help="a file holding what the person said, kept verbatim; '-' reads standard input",
        )

    def context(command, *, region: bool = True) -> None:
        command.add_argument("--about", action="append", default=[], metavar="PATTERN",
                             help="a pattern the person named; repeat for each")
        if region:
            command.add_argument("--region", help="the part of the page, as free text or a selector")
        command.add_argument("--task", help="what the interface was for")
        command.add_argument("--audience", help="who it was for")
        command.add_argument("--form", help="the kind of interface, e.g. cards, scroll, mock, view")
        command.add_argument("--id", help="event UUID; reuse it when retrying the same event")

    for name, verb in (("like", "liked"), ("dislike", "disliked")):
        react = commands.add_parser(name, help=f"record that someone {verb} a generated interface")
        react.add_argument("target", help="registry id, hosted URL, local path or claude.ai artifact link")
        words(react, required=True)
        context(react)
        react.set_defaults(handler=_react)

    chose = commands.add_parser("chose", help="record that someone chose one interface over another")
    chose.add_argument("winner", help="the interface they chose")
    chose.add_argument("--over", required=True, help="the interface they passed over")
    words(chose, required=False)
    context(chose, region=False)
    chose.set_defaults(handler=_chose)

    adopt = commands.add_parser(
        "adopt",
        help="make a palette or pattern a default, or a principle a standing rule (--scope org: a house rule)",
    )
    adopt.add_argument("kind", choices=ADOPT_KINDS)
    adopt.add_argument("value", help="the palette, pattern or principle, in a few words")
    adopt.add_argument("--scope", choices=ADOPT_SCOPES, default="person")
    words(adopt, required=False)
    adopt.add_argument("--id", help="event UUID; reuse it when retrying the same event")
    adopt.set_defaults(handler=_adopt)

    retract = commands.add_parser("retract", help="withdraw one of your own taste events")
    retract.add_argument("event_id")
    words(retract, required=False)
    retract.add_argument("--id", help="event UUID; reuse it when retrying the same event")
    retract.set_defaults(handler=_retract)

    taste = commands.add_parser("taste", help="read back what someone liked, in their words")
    taste.add_argument("--person", help="a name or actor id; defaults to you")
    taste.add_argument("--task", help="the work about to be composed; closest reactions come first")
    taste.add_argument("--form", help="the kind of interface about to be composed")
    taste.add_argument("--json", action="store_true")
    taste.set_defaults(handler=_taste)
    return parser


def main(argv: list[str] | None = None) -> int:
    """Run one command; bin/genui.sh reaches it through bin/lib/genui-entry.py."""

    args = _parser().parse_args(argv)
    try:
        return args.handler(args)
    except (AuthorizationDenied, OSError, RuntimeError, ValueError) as exc:
        print(f"genui: {exc}", file=sys.stderr)
        return 1
