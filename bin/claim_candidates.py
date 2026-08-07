"""Find the sentences in a passage that carry advice, and mark what is at risk.

Turning a passage into recorded knowledge needs judgement, and judgement fails
in a small number of predictable ways: the negation is dropped, the condition is
dropped, the timing is dropped, an observation is recorded as an instruction, or
a figure is mis-transcribed. Each produces a statement that is well-formed,
correctly cited, and wrong — and none is detectable by looking at the result.

This module does the part that does not need judgement. It finds sentences that
carry advice, marks whether each is positive or negative, and flags the features
whose loss would invert or unground the meaning. What it produces is not a
statement: it is a candidate with its hazards labelled, so whatever fills the
slots afterwards — a model, a person — can be checked against something.

The linguistic patterns are instance configuration. Detecting obligation in
Turkish is a matter of verb suffixes; in another language it is not. A profile
that declares no grammar yields no candidates, which is the default.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

SENTENCE_END = re.compile(r"(?<=[.!?:;])\s+|\n{2,}")

# Risks named so a reviewer knows what to look for, rather than re-reading blind.
RISK_NEGATION = "negation present — dropping it inverts the advice"
RISK_CONDITION = "conditional — the advice does not hold unconditionally"
RISK_TIME = "carries timing — without it the advice is unusable"
RISK_NUMBER = "carries figures — a mis-transcribed value is undetectable downstream"
RISK_NOT_ACTION = "reads as an observation, not an instruction"


@dataclass
class Candidate:
    text: str
    polarity: str  # "recommend" | "warn" | "observe"
    marker: str | None = None
    conditions: list[str] = field(default_factory=list)
    times: list[str] = field(default_factory=list)
    figures: list[str] = field(default_factory=list)
    vocabulary: dict = field(default_factory=dict)
    risks: list[str] = field(default_factory=list)

    def as_dict(self) -> dict:
        out = {"text": self.text, "polarity": self.polarity}
        for name in ("marker", "conditions", "times", "figures", "vocabulary", "risks"):
            value = getattr(self, name)
            if value:
                out[name] = value
        return out


def _compile(patterns) -> list[re.Pattern]:
    out = []
    for p in patterns or []:
        try:
            out.append(re.compile(p, re.I | re.U))
        except re.error:
            continue
    return out


def load_grammar(config: dict) -> dict:
    """The linguistic patterns an instance declares for detecting advice."""
    grammar = (config or {}).get("claim_grammar") or {}
    if not isinstance(grammar, dict):
        return {}
    return {
        "obligation": _compile(grammar.get("obligation")),
        "negation": _compile(grammar.get("negation")),
        "condition": _compile(grammar.get("condition")),
        "time": _compile(grammar.get("time")),
        "observation": _compile(grammar.get("observation")),
        "figure": _compile(grammar.get("figure") or [r"\d+[.,]?\d*\s*(?:%|g|kg|ml|l|lt|cm|m|ha|da|gün|hafta|ay|°C)\b"]),
    }


def _matches(patterns: list[re.Pattern], text: str) -> list[str]:
    found = []
    for pattern in patterns:
        for m in pattern.finditer(text):
            fragment = m.group(0).strip()
            if fragment and fragment not in found:
                found.append(fragment)
    return found


def sentences(text: str) -> list[str]:
    parts = [s.strip() for s in SENTENCE_END.split(text or "") if s and s.strip()]
    return [s for s in parts if len(s) >= 25]


def find(text: str, grammar: dict, vocabulary: dict | None = None) -> list[Candidate]:
    """Sentences carrying advice, each with its hazards marked."""
    if not grammar or not grammar.get("obligation"):
        return []

    vocabulary = vocabulary or {}
    results: list[Candidate] = []

    for sentence in sentences(text):
        obligations = _matches(grammar["obligation"], sentence)
        observations = _matches(grammar.get("observation") or [], sentence)

        if not obligations and not observations:
            continue

        negations = _matches(grammar.get("negation") or [], sentence)
        # An observation pattern wins over an obligation one. The two overlap by
        # design: in Turkish "yapılmalıdır" (must be done) and "olmalıdır" (must
        # be) carry the same modal suffix on different verbs — one instructs, one
        # states a criterion. Recorded as an instruction, "the annual mean
        # temperature must be 15-20 °C" tells a grower to change the climate.
        if observations:
            polarity = "observe"
        elif negations:
            polarity = "warn"
        else:
            polarity = "recommend"

        conditions = _matches(grammar.get("condition") or [], sentence)
        times = _matches(grammar.get("time") or [], sentence)
        figures = _matches(grammar.get("figure") or [], sentence)

        hits = {}
        lowered = sentence.lower()
        for kind, terms in vocabulary.items():
            found = sorted({term for term in terms if term.lower() in lowered})
            if found:
                hits[kind] = found

        risks = []
        if negations:
            risks.append(RISK_NEGATION)
        if conditions:
            risks.append(RISK_CONDITION)
        if times:
            risks.append(RISK_TIME)
        if figures:
            risks.append(RISK_NUMBER)
        if polarity == "observe":
            risks.append(RISK_NOT_ACTION)

        results.append(
            Candidate(
                text=" ".join(sentence.split()),
                polarity=polarity,
                marker=(obligations or observations)[0],
                conditions=conditions,
                times=times,
                figures=figures,
                vocabulary=hits,
                risks=risks,
            )
        )

    return results


def summarise(candidates: list[Candidate]) -> str:
    if not candidates:
        return "no advice found"
    counts: dict[str, int] = {}
    for c in candidates:
        counts[c.polarity] = counts.get(c.polarity, 0) + 1
    parts = [f"{n} {kind}" for kind, n in sorted(counts.items())]
    flagged = sum(1 for c in candidates if c.risks)
    if flagged:
        parts.append(f"{flagged} with risks")
    return " · ".join(parts)
