#!/usr/bin/env python3
"""Handoff metadata for many files in one process.

bin/lib/handoff-meta.sh extracts a handoff's author, topic and date with a
grep | sed | xargs pipeline per field, and the startup gather of handoffs
addressed to the user added an awk, a read loop and a jq per file: over a
hundred processes for five handoffs. This module reads each file once and
reproduces those pipelines' results, including xargs' quote and whitespace
handling and the echo it runs, so the files the gather writes are
unchanged.

    handoff_meta.py addressed NAMES_OUT RICH_OUT [FILE...]

writes the gather's two files: NAMES_OUT holds the handoff names, RICH_OUT
their author, topic, date and Repo State table rows. bin/tests/
test-handoff-metadata.sh holds this module to the shell functions.
"""

from __future__ import annotations

import json
import os
import re
import sys

# POSIX [[:space:]]. On macOS, sed in a UTF-8 locale also counts Unicode
# spaces (a no-break space after "**Author**:" is stripped there).
_ASCII_SPACE = frozenset(" \t\n\v\f\r")
_DARWIN = sys.platform == "darwin"


def _is_space(character: str) -> bool:
    return character in _ASCII_SPACE or (_DARWIN and character.isspace())


def _lstrip_space(text: str) -> str:
    position = 0
    while position < len(text) and _is_space(text[position]):
        position += 1
    return text[position:]


def _echo_operands(arguments: list[str]) -> list[str]:
    """What /bin/echo prints of its arguments, as xargs runs it."""
    if _DARWIN:
        # FreeBSD echo: only an exact first "-n" is an option, and a "\c"
        # ending the last argument is dropped with the newline.
        if arguments and arguments[0] == "-n":
            arguments = arguments[1:]
        if arguments and arguments[-1].endswith("\\c"):
            arguments = [*arguments[:-1], arguments[-1][:-2]]
        return arguments
    # GNU echo: leading arguments made only of n, e and E are options.
    while arguments and re.fullmatch(r"-[neE]+", arguments[0]):
        arguments = arguments[1:]
    return arguments


def _xargs(text: str) -> str:
    """`printf '%s\\n' "$text" | xargs`, as captured by $(...).

    Blanks and newlines separate arguments, quotes group them, a backslash
    outside quotes escapes the next character, and an unterminated quote
    makes xargs fail before running echo.
    """
    arguments: list[str] = []
    argument: list[str] = []
    started = False
    quote = ""
    characters = iter(text + "\n")
    for character in characters:
        if quote:
            if character == quote:
                quote = ""
            elif character == "\n":
                return ""
            else:
                argument.append(character)
            continue
        if character in " \t\n":
            if started:
                arguments.append("".join(argument))
                argument, started = [], False
            continue
        started = True
        if character in "'\"":
            quote = character
        elif character == "\\":
            escaped = next(characters, None)
            if escaped is None:
                break
            argument.append(escaped)
        else:
            argument.append(character)
    if quote:
        return ""
    if started:
        arguments.append("".join(argument))
    return " ".join(_echo_operands(arguments)).rstrip("\n")


def _bash_echo(value: str) -> str:
    """`echo "$value"` in bash: an argument of only n, e and E is an option."""
    return "" if re.fullmatch(r"-[neE]+", value) else value


def _first(lines: list[str], prefix: str) -> str | None:
    return next((line for line in lines if line.startswith(prefix)), None)


def _after(lines: list[str], prefix: str) -> str:
    """grep -m1 "^prefix" | sed "s/^prefix[[:space:]]*//" | xargs"""
    line = _first(lines, prefix)
    return "" if line is None else _xargs(_lstrip_space(line[len(prefix):]))


def _markdown_field(lines: list[str], key: str) -> str:
    return _after(lines, f"**{key}**:") or _after(lines, f"**{key}:**")


def _yaml_field(lines: list[str], key: str) -> str:
    # sed -n '/^---$/,/^---$/p' prints every such range, not only the first.
    inside = False
    ranged: list[str] = []
    for line in lines:
        if inside:
            ranged.append(line)
            inside = line != "---"
        elif line == "---":
            ranged.append(line)
            inside = True
    line = _first(ranged, f"{key}:")
    if line is None:
        return ""
    value = _lstrip_space(line[len(key) + 1:])
    for mark in ('"', "'"):
        value = value[1:] if value.startswith(mark) else value
        value = value[:-1] if value.endswith(mark) else value
    return _xargs(value)


def _name(path: str) -> str:
    name = os.path.basename(path)
    return name[:-3] if name.endswith(".md") and name != ".md" else name


def _author_from_filename(path: str) -> str:
    match = re.match(r"[0-9]{2}-([^-]+)-", _name(path)) or re.match(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}-([^-]+)-", _name(path)
    )
    return match.group(1) if match else ""


def _date_from_filename(path: str) -> str:
    name = _name(path)
    directory = os.path.basename(os.path.dirname(path))
    day = re.match(r"([0-9]{2})-", name)
    if re.fullmatch(r"[0-9]{4}-[0-9]{2}", directory) and day:
        return f"{directory}-{day.group(1)}"
    dated = re.match(r"([0-9]{4}-[0-9]{2}-[0-9]{2})-", name)
    return dated.group(1) if dated else ""


def author(lines: list[str], path: str) -> str:
    found = (
        _markdown_field(lines, "Author")
        or _markdown_field(lines, "From")
        or _after(lines, "From:")
        or _yaml_field(lines, "author")
        or _yaml_field(lines, "from")
        or _author_from_filename(path)
    )
    # sed 's/[[:space:]]*→.*//'
    arrow = found.find("→")
    if arrow >= 0:
        while arrow > 0 and _is_space(found[arrow - 1]):
            arrow -= 1
        found = found[:arrow]
    return _xargs(found)


def topic(lines: list[str]) -> str:
    heading = _first(lines, "# ")
    found = ""
    if heading is not None:
        text = heading[2:]
        if text.startswith("Handoff:"):
            text = _lstrip_space(text[len("Handoff:"):])
        found = _xargs(text)
    return found or _yaml_field(lines, "topic")


def date(lines: list[str], path: str) -> str:
    return (
        _markdown_field(lines, "Date")
        or _after(lines, "Date:")
        or _yaml_field(lines, "date")
        or _date_from_filename(path)
    )


def _json_string(value: str) -> str:
    # jq's compact output: raw UTF-8, with DEL escaped as well.
    return json.dumps(value, ensure_ascii=False).replace("\x7f", "\\u007f")


def _cell(fields: list[str], position: int) -> str:
    return _xargs(_bash_echo(fields[position] if position < len(fields) else ""))


def repo_state(lines: list[str]) -> str:
    """The `## Repo State` table as the JSON array the gather builds.

    Each row was printed into JSON text and parsed with `jq -s`, so a cell
    jq could not parse empties the whole table, as it did there.
    """
    rows: list[str] = []
    found = False
    for line in lines:
        if line.startswith("## Repo State"):
            found = True
            continue
        if not found:
            continue
        if line.startswith("#"):
            break
        if len(line) > 1 and line[0] == "|" and line[1] != "-" and not line.startswith("| Repo"):
            rows.append(line)
    entries: list[str] = []
    for row in rows:
        fields = row.split("|")
        repository, branch, base = _cell(fields, 1), _cell(fields, 2), _cell(fields, 4)
        pull = _cell(fields, 3)
        pull = (pull[1:] if pull.startswith("#") else pull).replace("—", "", 1)
        if not repository:
            continue
        number = "null"
        if re.fullmatch(r"[+-]?[0-9]+", pull) and -(2**63) <= int(pull) < 2**63:
            number = ("-" if pull.startswith("-") else "") + (pull.lstrip("+-").lstrip("0") or "0")
        try:
            text = [json.loads(f'"{value}"') for value in (repository, branch, base)]
        except ValueError:
            return "[]"
        entries.append(
            f'{{"repo":{_json_string(text[0])},"branch":{_json_string(text[1])},'
            f'"pr":{number},"base":{_json_string(text[2])}}}'
        )
    return "[" + ",".join(entries) + "]"


def _lines(path: str) -> list[str]:
    try:
        with open(path, "rb") as handle:
            content = handle.read().decode("utf-8", errors="replace")
    except OSError:
        return []
    lines = content.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def addressed(paths: list[str]) -> tuple[str, str]:
    names: list[str] = []
    rich: list[str] = []
    for path in paths:
        lines = _lines(path)
        name = _name(path)
        names.append(f'"{name}"')
        try:
            entry = (
                f'{{"name":{_json_string(name)},"author":{_json_string(author(lines, path))},'
                f'"topic":{_json_string(topic(lines))},"date":{_json_string(date(lines, path))},'
                f'"repoState":{repo_state(lines)}}}'
            )
        except Exception:  # one unreadable handoff keeps its place, not the list's
            entry = f'{{"name":{_json_string(name)},"author":"","topic":"","date":"","repoState":[]}}'
        rich.append(entry)
    return "[" + ",".join(names) + "]", "[" + ",".join(rich) + "]"


def main(arguments: list[str]) -> int:
    if len(arguments) < 3 or arguments[0] != "addressed":
        print("usage: handoff_meta.py addressed NAMES_OUT RICH_OUT [FILE...]", file=sys.stderr)
        return 2
    names, rich = addressed(arguments[3:])
    for path, content in ((arguments[1], names), (arguments[2], rich)):
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(content + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
