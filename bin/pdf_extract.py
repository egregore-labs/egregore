"""Per-page PDF text extraction with OCR fallback.

A PDF may carry a text layer on some pages and be a scanned image on others, in any
position. Whole-document extraction hides this: if most pages carry text the document
appears to extract successfully, and whatever the image pages held is simply absent
from the result with nothing to indicate it.

Two measurements motivate the design. A 172-page scanned thesis yielded zero
characters whole-document and is fully readable page by page — the case where OCR
recovers an entire document. A 99-page policy document extracted 93 pages from its
text layer while six fell below threshold; of those, one carried recoverable text,
four were sparse (a divider, some diagram labels) and one was blank. The gain there
is not bulk recovery but knowing which pages are thin and why, rather than assuming
the document extracted cleanly.

This module routes each page independently:

    >= MIN_CHARS non-whitespace characters   ->  pdftotext output kept
    <  MIN_CHARS and tesseract available     ->  rasterise and OCR the page
    <  MIN_CHARS and tesseract absent        ->  page reported, never silently dropped

Concatenated per-page `pdftotext` output is byte-identical to whole-document output,
so documents that need no OCR produce exactly the text they produced before and their
content hashes are unchanged.

Deterministic tooling is used in preference to a model: OCR failure is visible in the
output (character-level garbling) and can be validated, whereas a model asked to read
an illegible figure emits a plausible replacement. This corpus carries pesticide doses
and pre-harvest intervals, where an undetectable substitution is the worse failure.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

MIN_CHARS = int(os.environ.get("EGREGORE_PDF_MIN_CHARS_PER_PAGE", "100"))
OCR_LANGS = os.environ.get("EGREGORE_OCR_LANGS", "tur+eng")
OCR_DPI = int(os.environ.get("EGREGORE_OCR_DPI", "300"))
OCR_MAX_PAGES = int(os.environ.get("EGREGORE_OCR_MAX_PAGES", "600"))
OCR_ENABLED = os.environ.get("EGREGORE_OCR", "1") not in {"0", "false", "no"}
PAGE_TIMEOUT = int(os.environ.get("EGREGORE_PDF_PAGE_TIMEOUT", "120"))

_WS = re.compile(r"\s+")


def _dense(text: str) -> int:
    """Non-whitespace character count — the measure the routing threshold uses."""
    return len(_WS.sub("", text or ""))


@dataclass
class PageResult:
    number: int
    text: str
    extractor: str  # "pdftotext" | "tesseract" | "none"
    chars: int


@dataclass
class Result:
    text: str | None = None
    error: str | None = None
    extractor: str | None = None
    report: dict = field(default_factory=dict)


def _run(cmd: list[str], timeout: int = PAGE_TIMEOUT) -> subprocess.CompletedProcess | None:
    try:
        return subprocess.run(cmd, check=False, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired):
        return None


def page_count(path: Path) -> int | None:
    tool = shutil.which("pdfinfo")
    if not tool:
        return None
    proc = _run([tool, str(path)])
    if not proc or proc.returncode:
        return None
    match = re.search(r"^Pages:\s+(\d+)", proc.stdout, re.M)
    if not match:
        return None
    count = int(match.group(1))
    return count if count > 0 else None


def all_pages(path: Path, layout: bool = False) -> list[str] | None:
    """Every page's text from a single extraction pass.

    `pdftotext` separates pages with a form feed, so one call yields the whole
    document page by page. Shelling out per page instead costs one subprocess
    each — on a corpus of a hundred thousand pages that is the difference
    between minutes and hours — and returns identical text.

    Returns None when the split does not agree with the page count, so the
    caller can fall back to per-page extraction rather than trust a bad split.
    """
    tool = shutil.which("pdftotext")
    if not tool:
        return None
    cmd = [tool, "-q"] + (["-layout"] if layout else []) + [str(path), "-"]
    proc = _run(cmd, timeout=PAGE_TIMEOUT * 4)
    if not proc or proc.returncode:
        return None
    # Keep the form feed on each page. Splitting on it and rejoining without it
    # would drop one byte per page from the document text — enough to change
    # every content hash and orphan the chunk ids derived from them.
    raw = proc.stdout
    parts = raw.split("\f")
    if len(parts) == 1:
        return parts if parts[0] else None
    if parts[-1] == "":
        parts.pop()
        pages = [part + "\f" for part in parts]
    else:
        pages = [part + "\f" for part in parts[:-1]] + [parts[-1]]
    return pages or None


def page_text(path: Path, page: int, layout: bool = False) -> str:
    tool = shutil.which("pdftotext")
    if not tool:
        return ""
    cmd = [tool, "-q", "-f", str(page), "-l", str(page)]
    if layout:
        cmd.append("-layout")
    cmd += [str(path), "-"]
    proc = _run(cmd)
    if not proc or proc.returncode:
        return ""
    return proc.stdout


def ocr_available() -> bool:
    return bool(shutil.which("tesseract") and shutil.which("pdftoppm"))


def ocr_page(path: Path, page: int) -> str:
    """Rasterise one page and read it with tesseract. Returns "" on any failure."""
    toppm, tess = shutil.which("pdftoppm"), shutil.which("tesseract")
    if not (toppm and tess):
        return ""
    with tempfile.TemporaryDirectory(prefix="egregore-ocr-") as tmp:
        prefix = Path(tmp) / "page"
        raster = _run(
            [toppm, "-r", str(OCR_DPI), "-f", str(page), "-l", str(page), "-png", str(path), str(prefix)]
        )
        if not raster or raster.returncode:
            return ""
        images = sorted(Path(tmp).glob("page*.png"))
        if not images:
            return ""
        read = _run([tess, str(images[0]), "-", "-l", OCR_LANGS])
        if not read or read.returncode:
            return ""
        return read.stdout


def extract(path: Path, layout: bool = False) -> Result:
    """Extract a PDF page by page, falling back to OCR where the text layer is absent."""
    if not shutil.which("pdftotext"):
        return Result(error="pdf requires a text-layer or runtime-native extraction")

    total = page_count(path)
    if total is None:
        # pdfinfo unavailable or the structure is unreadable. Fall back to
        # whole-document extraction rather than failing outright.
        proc = _run([shutil.which("pdftotext"), "-q", str(path), "-"], timeout=PAGE_TIMEOUT * 4)
        if not proc or proc.returncode:
            return Result(error="pdftotext failed and page count is unreadable")
        text = proc.stdout
        if not text.strip():
            return Result(
                error="no text layer and page count unreadable — requires visual processing",
                report={"pages": None, "page_count_unreadable": True},
            )
        return Result(text=text, extractor="pdftotext", report={"pages": None, "page_count_unreadable": True})

    can_ocr = OCR_ENABLED and ocr_available()
    pages: list[PageResult] = []
    ocr_budget = OCR_MAX_PAGES

    # One pass for the whole document; per-page calls only if the split is
    # inconsistent with the page count.
    bulk = all_pages(path, layout=layout)
    if bulk is not None and len(bulk) != total:
        bulk = None

    for number in range(1, total + 1):
        raw = bulk[number - 1] if bulk is not None else page_text(path, number, layout=layout)
        if _dense(raw) >= MIN_CHARS:
            pages.append(PageResult(number, raw, "pdftotext", _dense(raw)))
            continue

        if can_ocr and ocr_budget > 0:
            ocr_budget -= 1
            recovered = ocr_page(path, number)
            # The threshold decides whether a page needs OCR. It does not decide
            # whether the result is worth keeping: a page carrying a few labels —
            # a diagram, an org chart — is legitimately sparse, not a failure.
            # Keep whatever OCR added.
            if _dense(recovered) > _dense(raw):
                pages.append(PageResult(number, recovered, "tesseract", _dense(recovered)))
                continue
            pages.append(PageResult(number, raw, "none", _dense(raw)))
            continue

        if can_ocr:
            # OCR was possible but the per-document budget is spent. This page was
            # never attempted, which is not the same as having nothing on it.
            pages.append(PageResult(number, raw, "skipped_budget", _dense(raw)))
            continue

        pages.append(PageResult(number, raw, "none", _dense(raw)))

    by_extractor: dict[str, int] = {}
    for page in pages:
        by_extractor[page.extractor] = by_extractor.get(page.extractor, 0) + 1

    ocr_pages = [p.number for p in pages if p.extractor == "tesseract"]
    skipped = [p.number for p in pages if p.extractor == "skipped_budget"]
    # Pages still below the threshold after the best available extractor ran. These
    # are candidates for visual processing: a full-page chart, map or photograph
    # carries meaning that neither a text layer nor OCR reports. Distinguished from
    # pages that are simply blank, which need nothing, and from pages never
    # attempted because the budget ran out.
    attempted = [p for p in pages if p.extractor != "skipped_budget"]
    sparse = [p.number for p in attempted if 0 < p.chars < MIN_CHARS]
    empty = [p.number for p in attempted if p.chars == 0]

    report = {
        "pages": total,
        "by_extractor": by_extractor,
        "ocr_pages": ocr_pages,
        "sparse_pages": sparse,
        "empty_pages": empty,
        "ocr_available": can_ocr,
        "min_chars_per_page": MIN_CHARS,
    }
    if skipped:
        report["budget_skipped_pages"] = skipped
        report["ocr_budget_exhausted"] = True
        report["ocr_max_pages"] = OCR_MAX_PAGES
    if not can_ocr and (sparse or empty):
        report["ocr_unavailable_note"] = (
            "tesseract or pdftoppm not installed; low-text pages were not recovered"
        )

    text = "".join(p.text for p in pages)

    if not text.strip():
        return Result(
            error=f"no extractable text on any of {total} pages — requires visual processing",
            report=report,
        )

    if by_extractor.get("tesseract"):
        extractor = "pdftotext+tesseract" if by_extractor.get("pdftotext") else "tesseract"
    else:
        extractor = "pdftotext"

    return Result(text=text, extractor=extractor, report=report)


def summarise(report: dict) -> str:
    """One-line human summary of a page report."""
    if not report or not report.get("pages"):
        return ""
    parts = [f"{report['pages']} pages"]
    by = report.get("by_extractor", {})
    if by.get("pdftotext"):
        parts.append(f"{by['pdftotext']} text")
    if by.get("tesseract"):
        parts.append(f"{by['tesseract']} ocr")
    if report.get("sparse_pages"):
        parts.append(f"{len(report['sparse_pages'])} sparse")
    if report.get("empty_pages"):
        parts.append(f"{len(report['empty_pages'])} blank")
    if report.get("budget_skipped_pages"):
        parts.append(f"{len(report['budget_skipped_pages'])} not attempted (budget)")
    return " · ".join(parts)
