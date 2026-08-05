"""Derive retrieval boundary and trust tier from publisher provenance.

Two values cannot be taken reliably from a document's text. The first is the
region it applies to: in some literatures the major place names are also the
major cultivar names, so a paper about a variety reads as a paper about a
district. The second is how much weight the source carries, which is a property
of the publisher rather than of the prose.

Both come from provenance instead — who published the document. A publication of
a provincial directorate concerns that province whether or not it says so, and a
national research institute's output applies nationally.

The mechanism here is generic; nothing in it knows what a region is. A profile
is a list of patterns matched against whatever provenance string is available —
an institution name, a source URL, or the filename when the catalogue offers
nothing better — plus a table mapping names to codes, plus the name of the
boundary the profile fills (`boundary_key`). An organisation without a profile
derives nothing, which is the default state.

`Resolution.zone` carries the value derived for that declared boundary. The
name is historical: for a profile whose `boundary_key` is `jurisdiction` or
`customer`, that is what the field holds.

Confidence is reported rather than assumed. A match on an official domain is
stronger evidence than a match on a filename, and a caller enforcing a hard
boundary needs to know which it has.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

# Provenance sources, strongest first. An official domain is authoritative; a
# filename is a convention that may drift.
EVIDENCE_STRENGTH = {"url": "high", "institution": "high", "filename": "low"}


@dataclass
class Resolution:
    publisher_class: str | None = None
    tier: str | None = None
    zone: str | None = None
    confidence: str = "none"
    matched_by: str | None = None
    evidence: str | None = None
    notes: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        out = {
            "publisher_class": self.publisher_class,
            "tier": self.tier,
            "zone": self.zone,
            "confidence": self.confidence,
        }
        if self.matched_by:
            out["matched_by"] = self.matched_by
        if self.evidence:
            out["evidence"] = self.evidence
        if self.notes:
            out["notes"] = self.notes
        return {k: v for k, v in out.items() if v is not None}


def load_profile(path: str | Path) -> dict:
    return json.loads(Path(path).read_text(encoding="utf-8"))


def boundary_key(profile: dict) -> str | None:
    """Which boundary this profile fills in, if it declares one."""
    key = (profile or {}).get("boundary_key")
    return key.strip() if isinstance(key, str) and key.strip() else None


def _normalise(text: str) -> str:
    """Lower-case and turn separators into spaces.

    Filenames join words with underscores, which are word characters, so a
    word-boundary match cannot see `balikesir` inside `11_IlMudurlugu_Balikesir_x`.
    URLs happen to work because dots are not word characters — a difference that
    should not decide whether a region is found.
    """
    return re.sub(r"[^0-9a-zçğıöşü]+", " ", text.lower(), flags=re.UNICODE)


def _region_entry(value) -> tuple[str, str | None]:
    """Regions may be a bare code or an object carrying its administrative level."""
    if isinstance(value, dict):
        return value.get("code", ""), value.get("level")
    return value, None


def _regions(profile: dict, text: str, level: str | None = None) -> tuple[str | None, str | None]:
    """Match an administrative name to its code, restricted to `level` if given.

    The publisher's own level decides which match to take. A provincial
    directorate publishes for its province even when its text names several
    districts — one such publication in the sample names three. Choosing the
    "most specific" name found would file a provincial survey under whichever
    district it happened to mention first.
    """
    haystack = _normalise(text)
    matches: list[tuple[str, str, str | None]] = []
    for name, value in (profile.get("regions") or {}).items():
        code, entry_level = _region_entry(value)
        if not code:
            continue
        if level and entry_level and entry_level != level:
            continue
        needle = _normalise(name).strip()
        if needle and re.search(rf"(?<![0-9a-zçğıöşü]){re.escape(needle)}(?![0-9a-zçğıöşü])", haystack):
            matches.append((code, name, entry_level))

    if not matches:
        return (None, None)
    if len(matches) == 1:
        return (matches[0][0], matches[0][1])

    # Several names matched at the permitted level. Distinct codes at the same
    # level mean the provenance is ambiguous, and guessing would put a document
    # in a region it was not written for.
    codes = {code for code, _, _ in matches}
    if len(codes) == 1:
        return (matches[0][0], matches[0][1])
    return (None, ", ".join(sorted(name for _, name, _ in matches)))


def resolve(profile: dict, *, url: str = "", institution: str = "", filename: str = "") -> Resolution:
    """Resolve boundary and tier from the strongest provenance available."""
    candidates = [("url", url or ""), ("institution", institution or ""), ("filename", filename or "")]
    joined = " ".join(value for _, value in candidates)
    normalised = {kind: _normalise(value) for kind, value in candidates}

    result = Resolution()

    # Strongest provenance first, and only then rule order. Iterating rules
    # first would let a filename decide the outcome merely because its rule
    # happened to be listed earlier than the one an official URL matches.
    for kind, value in candidates:
        if not value:
            continue
        for rule in profile.get("rules") or []:
            pattern = re.compile(rule["pattern"], re.I)
            # Try the raw string and the separator-normalised form. Raw keeps
            # domain patterns working (`tarimorman\.gov\.tr`, whose dots
            # normalisation would erase); normalised lets a plain word match
            # inside an underscore-joined filename.
            if not (pattern.search(value) or pattern.search(normalised[kind])):
                continue
            result.publisher_class = rule.get("class")
            result.tier = rule.get("tier")
            result.matched_by = kind
            result.evidence = pattern.pattern
            result.confidence = EVIDENCE_STRENGTH.get(kind, "low")

            scope = rule.get("zone_scope", "national")
            if scope == "national":
                result.zone = rule.get("zone") or profile.get("national_zone")
            elif scope == "regional":
                level = rule.get("zone_level")
                code, name = _regions(profile, joined, level=level)
                if code:
                    result.zone = code
                    result.notes.append(
                        f"region from provenance: {name}" + (f" ({level})" if level else "")
                    )
                elif name:
                    result.notes.append(
                        f"ambiguous region in provenance ({name}) — zone must be supplied"
                    )
                else:
                    result.notes.append(
                        "regional publisher but no region identified in provenance — "
                        "zone must be supplied or the document held back"
                    )
            elif scope == "none":
                # Journals and theses have no administrative region of their own.
                result.notes.append("publisher carries no region; zone must come from content or be supplied")
            break
        if result.publisher_class:
            break

    if not result.publisher_class:
        result.notes.append("no publisher rule matched")

    if result.zone is None and result.tier is not None:
        result.notes.append("tier resolved but zone unresolved")

    return result


def default_profile_path() -> Path:
    return Path(__file__).resolve().parent.parent / "memory" / "ingest" / "publisher-profile.json"
