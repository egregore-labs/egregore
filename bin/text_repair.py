"""Repair characters a document's own font encoding got wrong.

Some PDFs carry a text layer whose glyphs are mapped to the wrong code points.
The page looks correct to a reader — the glyphs are drawn properly — but the
characters extracted from it are not the ones on the page. In one Turkish
archive, `Araştırma` extracts as `AraĢtırma`: the letter is wrong and its case
is inverted.

This is not OCR damage. OCR failure garbles unpredictably and is visible as
nonsense; this is systematic, silent, and produces text that still looks like
words. Its cost is retrieval: someone searching `araştırma` never matches
`araĢtırma`, and nothing anywhere reports a problem.

The mapping is instance configuration, not framework knowledge. Which
substitutions a corpus suffers depends on the fonts its publishers used, and
a character that is corruption in one language is ordinary text in another —
`Ģ` is a real letter in Latvian. An instance that declares no mapping gets no
repair, which is the default.

Repairs are counted and reported so a corpus can be audited for how much of it
needed correcting.
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class Repair:
    text: str
    replaced: int = 0
    by_char: dict | None = None

    def as_report(self) -> dict | None:
        if not self.replaced:
            return None
        return {"characters_repaired": self.replaced, "substitutions": self.by_char or {}}


def load_mapping(config: dict) -> dict:
    """The character substitutions an instance declares, if any."""
    mapping = (config or {}).get("text_repair") or {}
    if not isinstance(mapping, dict):
        return {}
    # Single characters only. A multi-character rule would be a find-and-replace
    # on content, which is a different and far riskier thing than fixing an
    # encoding, and is not what this is for.
    return {k: v for k, v in mapping.items() if isinstance(k, str) and isinstance(v, str) and len(k) == 1}


def repair(text: str, mapping: dict) -> Repair:
    if not text or not mapping:
        return Repair(text=text or "")

    counts: dict[str, int] = {}
    total = 0
    for wrong, right in mapping.items():
        found = text.count(wrong)
        if found:
            counts[f"{wrong}->{right}"] = found
            total += found

    if not total:
        return Repair(text=text)

    return Repair(text=text.translate(str.maketrans(mapping)), replaced=total, by_char=counts)


def looks_affected(text: str, mapping: dict, threshold: int = 20) -> bool:
    """Whether a document carries enough suspect characters to be worth reporting.

    Used for reporting rather than for deciding: repair is applied wherever the
    mapping matches, since a handful of wrong characters is still wrong.
    """
    if not text or not mapping:
        return False
    return sum(text.count(c) for c in mapping) >= threshold
