"""Read document metadata an organisation already holds, rather than inferring it.

Many archives arrive with a catalogue: a spreadsheet listing every document with
its publisher, region, reliability grade and year. Where one exists it is better
evidence than anything derivable from a filename — it was written by whoever
assembled the archive and knows what each document is.

This module joins a catalogue to the documents being ingested and returns the
fields it supplies. The mechanism is generic: the instance declares which file,
how rows join to documents, and which columns map to which fields. Nothing here
knows what a region or a reliability grade is.

Where no catalogue is configured, nothing is returned and the caller falls back
to whatever else it has.
"""

from __future__ import annotations

import csv
import json
import re
from dataclasses import dataclass, field
from pathlib import Path

# How a catalogue row is matched to a document on disk. Every strategy compares
# basenames: a catalogue lists documents, not the directory tree they happen to
# sit in, and the two sides are rarely written the same way.
JOIN_STRATEGIES = ("id_prefix", "stem", "filename")


@dataclass
class Catalogue:
    rows_by_key: dict[str, dict] = field(default_factory=dict)
    mapping: dict = field(default_factory=dict)
    join: str = "id_prefix"
    source: str | None = None
    warnings: list[str] = field(default_factory=list)

    def __bool__(self) -> bool:
        return bool(self.rows_by_key)


def _key_for(strategy: str, value: str) -> str:
    """Reduce a filename or catalogue value to its join key."""
    value = (value or "").strip()
    if not value:
        return ""
    if strategy == "filename":
        return Path(value).name
    stem = Path(value).stem
    if strategy == "stem":
        return stem
    # id_prefix: the identifier before the first separator, e.g.
    # "agr-0509_tagem-t2-096" -> "agr-0509"
    return re.split(r"[_\s]", stem, 1)[0]


def load(config: dict, base: Path | None = None) -> Catalogue:
    """Load a catalogue from an instance's configuration.

    Expected shape:

        {"catalogue": {
            "path": "INDEX.csv",
            "key_column": "source_id",
            "join": "id_prefix",
            "map": {
                "zone":  {"column": "zone", "values": {"genel": "TR"}},
                "tier":  {"column": "tier"},
                "year":  {"column": "yil"}
            }
        }}
    """
    spec = (config or {}).get("catalogue") or {}
    path = spec.get("path")
    if not path:
        return Catalogue()

    resolved = Path(path)
    if not resolved.is_absolute() and base:
        resolved = base / resolved
    if not resolved.is_file():
        return Catalogue(warnings=[f"catalogue not found: {resolved}"])

    join = spec.get("join", "id_prefix")
    if join not in JOIN_STRATEGIES:
        return Catalogue(warnings=[f"unknown join strategy: {join}"])

    key_column = spec.get("key_column")
    if not key_column:
        return Catalogue(warnings=["catalogue declares no key_column"])

    try:
        if resolved.suffix.lower() == ".json":
            raw = json.loads(resolved.read_text(encoding="utf-8"))
            rows = raw if isinstance(raw, list) else raw.get("rows", [])
        else:
            with resolved.open(encoding="utf-8-sig", newline="") as handle:
                rows = list(csv.DictReader(handle))
    except (OSError, ValueError, csv.Error) as exc:
        return Catalogue(warnings=[f"catalogue unreadable: {exc}"])

    by_key: dict[str, dict] = {}
    collisions = 0
    for row in rows:
        key = _key_for(join, str(row.get(key_column) or ""))
        if not key:
            continue
        if key in by_key:
            collisions += 1
            continue
        by_key[key] = row

    catalogue = Catalogue(
        rows_by_key=by_key,
        mapping=spec.get("map") or {},
        join=join,
        source=str(resolved),
    )
    if collisions:
        # A duplicate key means the first row wins and the rest are unreachable.
        # Silently preferring one row would make the metadata depend on file order.
        catalogue.warnings.append(
            f"{collisions} catalogue row(s) share a join key and were skipped; "
            "the first occurrence is used"
        )
    return catalogue


def lookup(catalogue: Catalogue, relative_path: str) -> dict:
    """Fields the catalogue supplies for one document. Empty when it has no row."""
    if not catalogue:
        return {}
    row = catalogue.rows_by_key.get(_key_for(catalogue.join, relative_path))
    if row is None:
        return {}

    result: dict = {}
    for field_name, spec in catalogue.mapping.items():
        if isinstance(spec, str):
            column, values = spec, {}
        else:
            column, values = spec.get("column"), (spec.get("values") or {})
        if not column:
            continue
        raw = (row.get(column) or "").strip()
        if not raw:
            continue
        result[field_name] = values.get(raw, raw)
    return result


def coverage(catalogue: Catalogue, relative_paths: list[str]) -> dict:
    """How much of this intake the catalogue actually covers.

    Reported rather than assumed: a catalogue that joins to a third of the
    documents is a different situation from one that joins to all of them, and
    the difference is invisible unless counted.
    """
    if not catalogue:
        return {"catalogue": False}
    matched = sum(1 for path in relative_paths if lookup(catalogue, path))
    return {
        "catalogue": True,
        "source": catalogue.source,
        "documents": len(relative_paths),
        "matched": matched,
        "unmatched": len(relative_paths) - matched,
        "join": catalogue.join,
    }
