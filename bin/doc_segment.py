"""Structural segmentation of documents that contain more than one work.

A single PDF is often a whole journal issue: several unrelated articles by
different authors bound together. Chunking such a file directly produces passages
that straddle two papers, and any claim drawn from one of those passages carries
the wrong attribution — a citation that looks complete and points at the wrong
author.

Segmentation runs before chunking so that each passage belongs to exactly one
work. It also marks bibliographies, which are lists of citations rather than
claims and would otherwise generate high volumes of well-formed nonsense.

The mechanism here is generic. The patterns are not: `PROFILES` holds the
instance-specific vocabulary, and pointing this at another literature means
adding a profile rather than changing the code.

Detection is deterministic — a running head of the form

    Zeytin Bilimi 1 (1) 2010, 7-13

carries the journal, volume, issue, year and page range, so one detection serves
three purposes: the article boundary, the bibliography exclusion, and the
publication year (which the archive catalogue does not record).

Where no running head is present, an article-opening signature is used as a
fallback: an abstract heading followed closely by a keywords line, in both
languages. A bare "Özet" is not sufficient on its own — it also occurs as an
ordinary section heading.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

PROFILES: dict[str, dict] = {
    # Turkish academic publishing. Journal issues carry a running head on each
    # article's first page; theses and articles carry a bibliography heading.
    "tr-academic": {
        "running_head": re.compile(
            r"^[ \t]*(?P<journal>[^\d\n]{2,60}?)[ \t]+"
            r"(?P<volume>\d{1,3})[ \t]*\((?P<issue>\d{1,3})\)[ \t]*"
            r"(?P<year>(?:19|20)\d{2})[ \t]*,[ \t]*"
            r"(?P<first_page>\d{1,4})[ \t]*[-–—][ \t]*(?P<last_page>\d{1,4})[ \t]*$",
            re.M,
        ),
        "bibliography": re.compile(
            r"^[ \t]*(?:Kaynaklar|Kaynakça|Kaynaklar\s+Dizini|Bibliyografya|"
            r"References|Reference\s+List|Literature\s+Cited|Bibliography)[ \t]*:?[ \t]*$",
            re.M | re.I,
        ),
        "abstract_open": re.compile(r"^[ \t]*(?:Özet|Öz|ÖZET|Abstract|ABSTRACT)[ \t]*$", re.M),
        "keywords": re.compile(
            r"^[ \t]*(?:Anahtar\s+Kelimeler|Anahtar\s+Sözcükler|Keywords)[ \t]*:", re.M
        ),
        # Distance within which a keywords line must follow an abstract heading
        # for the pair to count as an article opening.
        "opening_window": 2500,
    }
}

DEFAULT_PROFILE = "tr-academic"


@dataclass
class Segment:
    kind: str  # "front_matter" | "article" | "bibliography"
    start: int
    end: int
    label: str | None = None
    meta: dict = field(default_factory=dict)

    def text(self, source: str) -> str:
        return source[self.start : self.end]


def _article_starts(text: str, profile: dict) -> list[tuple[int, str, dict]]:
    """Offsets where a new work begins, with whatever metadata the marker carries."""
    found: list[tuple[int, str, dict]] = []

    for match in profile["running_head"].finditer(text):
        meta = {
            "journal": (match.group("journal") or "").strip(),
            "volume": match.group("volume"),
            "issue": match.group("issue"),
            "year": int(match.group("year")),
            "pages": f"{match.group('first_page')}-{match.group('last_page')}",
            "detected_by": "running_head",
        }
        found.append((match.start(), match.group(0).strip(), meta))

    if len(found) >= 2:
        return found

    # No usable running heads. Fall back to article openings: an abstract
    # heading closely followed by a keywords line. Requiring both avoids
    # splitting on an ordinary "Özet" section heading.
    openings: list[tuple[int, str, dict]] = []
    keyword_positions = [m.start() for m in profile["keywords"].finditer(text)]
    for match in profile["abstract_open"].finditer(text):
        window = match.start() + profile["opening_window"]
        if any(match.start() < pos <= window for pos in keyword_positions):
            openings.append((match.start(), match.group(0).strip(), {"detected_by": "abstract_opening"}))

    return openings if len(openings) >= 2 else found


def segment(text: str, profile_name: str = DEFAULT_PROFILE) -> list[Segment]:
    """Split `text` into works, marking bibliographies separately.

    A document containing a single work returns one article segment spanning it,
    so callers need no special case: chunking a single-segment document produces
    exactly what chunking the whole text produced.
    """
    if not text or not text.strip():
        return []

    profile = PROFILES.get(profile_name) or PROFILES[DEFAULT_PROFILE]
    starts = _article_starts(text, profile)
    segments: list[Segment] = []

    if not starts:
        segments.append(Segment("article", 0, len(text), None, {"detected_by": "whole_document"}))
    else:
        if starts[0][0] > 0:
            segments.append(Segment("front_matter", 0, starts[0][0]))
        for index, (offset, label, meta) in enumerate(starts):
            end = starts[index + 1][0] if index + 1 < len(starts) else len(text)
            segments.append(Segment("article", offset, end, label, dict(meta)))

    # Split a trailing bibliography off each article. Only the last heading
    # inside the article is used: earlier occurrences may be cross-references.
    expanded: list[Segment] = []
    for seg in segments:
        if seg.kind != "article":
            expanded.append(seg)
            continue
        body = seg.text(text)
        matches = list(profile["bibliography"].finditer(body))
        if not matches:
            expanded.append(seg)
            continue
        cut = seg.start + matches[-1].start()
        if cut <= seg.start:
            expanded.append(seg)
            continue
        expanded.append(Segment("article", seg.start, cut, seg.label, dict(seg.meta)))
        expanded.append(
            Segment("bibliography", cut, seg.end, seg.label, {**seg.meta, "excluded_from_claims": True})
        )

    return expanded


def publication_year(segments: list[Segment]) -> int | None:
    """The year carried by the article markers, when they agree.

    Journal running heads state the publication year directly, which is more
    reliable than scanning the body: a reference list is full of other years.
    """
    years = {seg.meta.get("year") for seg in segments if seg.meta.get("year")}
    return years.pop() if len(years) == 1 else None


def summarise(segments: list[Segment]) -> str:
    if not segments:
        return ""
    articles = sum(1 for s in segments if s.kind == "article")
    bibs = sum(1 for s in segments if s.kind == "bibliography")
    parts = [f"{articles} article{'s' if articles != 1 else ''}"]
    if bibs:
        parts.append(f"{bibs} bibliography" if bibs == 1 else f"{bibs} bibliographies")
    if any(s.kind == "front_matter" for s in segments):
        parts.append("front matter")
    year = publication_year(segments)
    if year:
        parts.append(str(year))
    return " · ".join(parts)
