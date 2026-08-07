"""Expand a question into the vocabulary its answer is written in.

A grower asks about *dal kanseri*. The guidance that answers them is filed
under *ur ve siğil* — the same disease, a different name. Nothing is wrong with
either the question or the archive; they were written by different people, and
lexical retrieval cannot join them. Measured on the olive archive, the document
answering that question ranks 15th on the grower's words and 4th on the
archive's.

This closes that gap by rewriting the question, not the corpus. Rewriting the
corpus would mean deciding at ingest time which name is correct and discarding
the other, and the discarded one is the one somebody eventually searches for.

Expansion terms are returned separately from the asker's own words rather than
mixed in. A word the grower typed is direct evidence of what they want; a word
inferred from a synonym table is weaker, and giving both the same weight lets a
common synonym outrank the question itself.

The vocabulary is instance data. This module knows the shape of a term entry —
a name, translations, synonyms — and nothing about olives, Turkish or
agriculture. Pointing it at another crop or another language is a matter of
supplying different files.
"""

from __future__ import annotations

import json
import re
from dataclasses import dataclass, field
from pathlib import Path

# Fields on a term entry that hold a name the same thing may be called.
NAME_FIELDS = ("tr", "en", "latin", "label", "name")
SYNONYM_FIELDS = ("synonyms", "tr_synonyms", "en_synonyms", "alt")

# An expansion is weaker evidence than a word the asker chose. Retrieval keeps
# the two apart and applies this multiplier to the inferred half.
EXPANSION_WEIGHT = 0.5

# Below this length a name matches too much to be useful as a synonym: Turkish
# "ur" (gall) is a substring of ordinary words and a standalone word besides.
MIN_NAME_CHARS = 3

# A name shorter than this must match a question's word exactly. Turkish `dal`
# (branch) is a prefix of `dalga` (wave), and treating it as a stem would pull
# in documents about neither.
MIN_STEM_CHARS = 4

# How much ending a word may carry and still count as the same word. Turkish
# suffix chains are short; past a few characters a shared prefix is coincidence.
MAX_SUFFIX_CHARS = 6

WORD = re.compile(r"\w+", re.UNICODE)


@dataclass
class Vocabulary:
    """Names that refer to the same thing, keyed by each name."""

    groups: list[set] = field(default_factory=list)
    index: dict = field(default_factory=dict)
    skipped: list = field(default_factory=list)

    def by_specificity(self) -> list:
        """Names ordered so the most specific claims a question's words first."""
        return sorted(self.index, key=lambda n: (-len(n.split()), -len(n)))

    def alternatives(self, phrase: str) -> set:
        group = self.index.get(normalise(phrase))
        if not group:
            return set()
        return {alt for alt in group if alt != normalise(phrase)}

    def __len__(self) -> int:
        return len(self.groups)


def normalise(text: str) -> str:
    """Casefold and collapse whitespace so `Dal  Kanseri` matches `dal kanseri`.

    Turkish's dotted capital needs handling first. Both lower() and casefold()
    turn İ into i followed by a combining dot above, which no longer equals the
    plain i it came from — so `İĞNE` stops matching `iğne`. Mapping it before
    folding, and stripping any combining dot that arrives already decomposed,
    keeps the two forms equal.

    The dotless I is deliberately left to casefold's default. Turkish would map
    it to ı, but the archive mixes Turkish with English, and applying the
    Turkish rule turns English initialisms into words that match nothing.
    """
    prepared = (text or "").replace("İ", "i").casefold().replace("̇", "")
    return " ".join(WORD.findall(prepared))


def load_vocabulary(paths: list[Path]) -> Vocabulary:
    """Read term files into groups of interchangeable names.

    A malformed file is reported and skipped rather than raised on: a broken
    synonym table should degrade retrieval, not prevent it.
    """
    vocab = Vocabulary()
    for path in paths:
        try:
            entries = json.loads(Path(path).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            vocab.skipped.append(f"{path}: {exc}")
            continue
        if isinstance(entries, dict):
            entries = entries.get("terms") or entries.get("entries") or []
        if not isinstance(entries, list):
            vocab.skipped.append(f"{path}: expected a list of terms")
            continue

        for entry in entries:
            if not isinstance(entry, dict):
                continue
            names = set()
            for key in NAME_FIELDS:
                value = entry.get(key)
                if isinstance(value, str):
                    names.add(value)
            for key in SYNONYM_FIELDS:
                value = entry.get(key)
                if isinstance(value, list):
                    names.update(v for v in value if isinstance(v, str))

            group = {
                n for n in (normalise(name) for name in names)
                if len(n) >= MIN_NAME_CHARS
            }
            # A single name has nothing to expand to.
            if len(group) < 2:
                continue
            vocab.groups.append(group)
            for name in group:
                vocab.index.setdefault(name, set()).update(group)
    return vocab


def word_matches(asked: str, name: str) -> bool:
    """Whether a word in the question is the vocabulary's word, suffixes aside.

    Turkish builds meaning by adding endings, so the archive's `dal kanseri`
    appears in a real question as `dal kanserini`. Because the language suffixes
    rather than prefixes, the vocabulary's form survives at the front of the
    inflected one, and a prefix test recovers the match without a stemmer.

    Two guards keep it from over-reaching. A short name must match exactly —
    otherwise `dal` (branch) would match `dalga` (wave). And the extra ending is
    bounded, because beyond a few characters a shared prefix is a coincidence
    rather than an inflection.
    """
    if asked == name:
        return True
    if len(name) < MIN_STEM_CHARS:
        return False
    return asked.startswith(name) and len(asked) - len(name) <= MAX_SUFFIX_CHARS


def phrases_in(question: str, vocab: Vocabulary, max_words: int = 4) -> list[str]:
    """Every known name appearing in the question, most specific match first.

    Specificity matters: `zeytin sineği` is a pest and `zeytin` is the crop.
    Matching the crop first would widen the question toward every olive
    document in the archive, so longer names claim their words first and
    shorter ones only match what is left.
    """
    words = normalise(question).split()
    found: list[str] = []
    taken = [False] * len(words)
    for name in vocab.by_specificity():
        name_words = name.split()
        size = len(name_words)
        if size > max_words or size > len(words):
            continue
        for start in range(0, len(words) - size + 1):
            if any(taken[start:start + size]):
                continue
            if all(word_matches(words[start + i], name_words[i]) for i in range(size)):
                found.append(name)
                for i in range(start, start + size):
                    taken[i] = True
                break
    return found


def expand(question: str, vocab: Vocabulary) -> tuple[list[str], list[str]]:
    """Split a question into the asker's own words and the inferred ones.

    Returned separately so the caller can weight them apart. Nothing the asker
    typed is ever removed — expansion only adds.
    """
    asked = WORD.findall((question or "").casefold())
    added: list[str] = []
    seen = set(asked)
    for phrase in phrases_in(question, vocab):
        for alternative in sorted(vocab.alternatives(phrase)):
            for token in alternative.split():
                if token not in seen:
                    seen.add(token)
                    added.append(token)
    return asked, added


def describe(question: str, vocab: Vocabulary) -> str:
    """A one-line account of what expansion did, for the benchmark log."""
    matched = phrases_in(question, vocab)
    if not matched:
        return "no known term matched"
    parts = [f"{m} → {', '.join(sorted(vocab.alternatives(m)))}" for m in matched]
    return "; ".join(parts)
