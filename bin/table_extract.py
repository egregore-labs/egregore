"""Recover column structure from layout-preserved text, and flag what does not fit.

Some of the most consequential content in a document archive sits in tables:
application rates, dose per hectare, intervals that must elapse before harvest.
Extracted without layout, the columns collapse into a sequence and a value can
end up beside the wrong substance. Extracted with layout, the columns survive —
but multi-line and merged cells still break the alignment, and a row that has
lost its dose column looks exactly like a row that never had one.

This module does not try to parse such tables completely. It recovers the
column grid, splits each line against it, and marks every row that does not fit
the header. Rows that fit cleanly can be read directly; rows that do not are
handed on for review rather than resolved by guesswork.

Column detection reads vertical whitespace channels, so it is only as good as
the alignment in the source: one long line crossing a gutter merges the columns
either side of it. Where that happens the affected rows fall out as needing
review, which is the intended failure direction.

That division is deliberate. A dose parsed wrongly is not detectably wrong: the
resulting row is well-formed, correctly attributed, and carries a number nobody
can tell is the neighbouring row's. Marking a row uncertain is recoverable;
silently mis-parsing it is not.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

NUMERIC = re.compile(r"\d")

# A gutter must be at least this wide to separate columns, and may carry content
# on at most this fraction of lines — wrapped cells occasionally intrude.
MIN_GUTTER = 2
GUTTER_TOLERANCE = 0.10
MIN_TABLE_LINES = 3


@dataclass
class Row:
    line_number: int
    cells: list[str]
    filled: int
    status: str  # "complete" | "partial" | "orphan"
    text: str = ""


@dataclass
class Table:
    columns: list[int] = field(default_factory=list)
    header: list[str] = field(default_factory=list)
    rows: list[Row] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)

    @property
    def complete_rows(self) -> list[Row]:
        return [r for r in self.rows if r.status == "complete"]

    @property
    def needs_review(self) -> list[Row]:
        return [r for r in self.rows if r.status != "complete"]


def column_grid(lines: list[str], min_gutter: int = MIN_GUTTER) -> list[int]:
    """Column start positions, inferred from vertical whitespace channels."""
    lines = [line for line in lines if line.strip()]
    if len(lines) < MIN_TABLE_LINES:
        return []

    width = max(len(line) for line in lines)
    occupancy = [0] * (width + 1)
    for line in lines:
        for index, char in enumerate(line):
            if not char.isspace():
                occupancy[index] += 1

    allowed = max(0, int(len(lines) * GUTTER_TOLERANCE))
    gutters: list[tuple[int, int]] = []
    start = None
    for index in range(width + 1):
        if occupancy[index] <= allowed:
            start = index if start is None else start
        else:
            if start is not None and index - start >= min_gutter:
                gutters.append((start, index))
            start = None
    if start is not None and (width + 1) - start >= min_gutter:
        gutters.append((start, width + 1))

    # A column begins at the first position inside the gutter that any line
    # actually occupies. Taking the gutter's end instead would clip the first
    # character of any cell that starts one position early — a single line
    # reaching left is enough to make the gutter look wider than it is.
    columns = [0]
    for start, end in gutters:
        edge = None
        for index in range(start, min(end + 1, width + 1)):
            if occupancy[index] > 0:
                edge = index
                break
        if edge is None:
            edge = end
        if edge <= width and edge not in columns:
            columns.append(edge)
    columns = sorted(set(columns))

    # A single column is not a table.
    return columns if len(columns) >= 2 else []


def split_row(line: str, columns: list[int]) -> list[str]:
    cells = []
    for index, start in enumerate(columns):
        end = columns[index + 1] if index + 1 < len(columns) else len(line)
        cells.append(line[start:end].strip())
    return cells


def extract(text: str, min_columns: int = 3) -> Table:
    """Recover a table from layout-preserved page text.

    `min_columns` guards against reading ordinary indented prose as a table.
    """
    lines = text.split("\n")
    columns = column_grid(lines)
    table = Table(columns=columns)

    if len(columns) < min_columns:
        table.warnings.append(
            f"no column structure found (detected {len(columns)}, need {min_columns}) — "
            "the page is prose, or its columns did not survive extraction"
        )
        return table

    populated = [(number, line) for number, line in enumerate(lines, 1) if line.strip()]
    if not populated:
        return table

    split = [(number, split_row(line, columns), line.rstrip()) for number, line in populated]

    # A block indented as a whole yields a leading column empty on every line.
    # That is indentation, not a column, and keeping it shifts every cell index
    # by one for whoever reads the result.
    if len(columns) > 1 and all(not cells[0] for _, cells, _ in split):
        columns = columns[1:]
        table.columns = columns
        split = [(number, cells[1:], text) for number, cells, text in split]

    # How many columns a data row fills is taken from the rows themselves — the
    # most common count among lines that use the grid. Deriving it from a header
    # would inherit any error in finding one, and pages carry running heads and
    # section titles above their tables.
    fills = [sum(1 for cell in cells if cell) for _, cells, _ in split]
    substantial = [count for count in fills if count >= 3]
    expected = max(set(substantial), key=substantial.count) if substantial else len(columns)

    # A header is claimed only when a line looks like one: enough cells filled,
    # none of them numeric. Otherwise rows are reported without column names
    # rather than under invented ones.
    header_index = None
    for position, (_, cells, _) in enumerate(split[:6]):
        filled_cells = [cell for cell in cells if cell]
        if len(filled_cells) >= max(2, expected - 1) and not any(
            NUMERIC.search(cell) for cell in filled_cells
        ):
            header_index = position
            table.header = list(cells)
            break

    body = split[header_index + 1 :] if header_index is not None else split
    if header_index is None:
        table.warnings.append("no header row identified; rows are reported without column names")

    for number, cells, text in body:
        filled = sum(1 for cell in cells if cell)
        if filled == 0:
            continue
        if filled >= expected:
            status = "complete"
        elif filled == 1 and cells[0]:
            # Only the leading column carries content. In a dose table this is
            # the merged-cell case: several substances sharing one entry, with
            # the remaining columns absent rather than empty.
            status = "orphan"
        else:
            status = "partial"
        table.rows.append(Row(number, list(cells), filled, status, text))

    orphans = [row for row in table.rows if row.status == "orphan"]
    partials = [row for row in table.rows if row.status == "partial"]
    if orphans:
        table.warnings.append(
            f"{len(orphans)} row(s) carry only their first column — merged cells or "
            "continuation lines; the remaining values cannot be attributed"
        )
    if partials:
        table.warnings.append(
            f"{len(partials)} row(s) fill fewer columns than the rest — wrapped cells "
            "or missing values"
        )
    return table


def numeric_cells(row: Row) -> list[int]:
    """Indices of cells containing a digit.

    A dose field is not always a quantity: some entries carry an application
    instruction instead. Reporting which cells hold numbers lets a caller notice
    that, rather than failing to parse a sentence as a measurement.
    """
    return [index for index, cell in enumerate(row.cells) if NUMERIC.search(cell)]


def summarise(table: Table) -> str:
    if not table.columns:
        return "no table"
    parts = [f"{len(table.columns)} columns", f"{len(table.rows)} rows"]
    if table.needs_review:
        parts.append(f"{len(table.needs_review)} need review")
    return " · ".join(parts)
