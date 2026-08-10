"""Turn a candidate sentence into a recorded statement, or refuse to.

A statement is the unit this whole pipeline exists to produce: a claim, the
place and crop and growth stage it applies to, the chunk it came from, and how
much the source is to be trusted. Everything before this stage moves text
around. This stage asserts something about the world.

Which is why the interesting part is not the making but the refusing. Filling
these slots needs judgement, and judgement fails in five ways that leave no
trace in the result: the negation is dropped, the condition is dropped, the
timing is dropped, an observation is written down as an instruction, or a figure
is mis-transcribed. Each produces a statement that is fluent, correctly cited
and wrong. Reading it will not reveal the problem, because there is nothing
wrong with it as a sentence.

So nothing here trusts the filled slots. Whatever produced them — a model, a
person, a rule — the claim it returns is run back through the same deterministic
grammar that found the candidate, and compared with the source feature by
feature. Negation must survive. Conditions must survive. Timing must survive. A
figure in the claim must exist in the source. An observation may not become an
instruction. A statement that fails any of these is not emitted with a warning
attached; it is not emitted.

This is the inverse of the usual arrangement, where a model produces and a human
spot-checks. Spot-checking cannot find these errors — that is their defining
property. The check has to be mechanical and it has to run on every statement.

The grammar and the vocabulary are instance data. This module knows that
negation matters and nothing about how Turkish spells it.
"""

from __future__ import annotations

import math
import re
import sys
from dataclasses import dataclass, field
from datetime import date, datetime
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent))

import claim_candidates  # noqa: E402

# Trust tiers, weighted by how much a source of that class is worth relying on.
# Instance data supplies which publisher lands in which tier; the ordering is a
# property of the tiers themselves.
TIER_WEIGHT = {"T1": 1.0, "T2": 0.8, "T3": 0.5}

# Guidance ages. A dose or a spray date from twenty years ago may be withdrawn,
# and the half-life says how fast confidence in it should decay.
FRESHNESS_HALF_LIFE_YEARS = 12.0

# What an undated source is worth. Not nothing — most archives record a year for
# almost nothing, and measured on a real 2,748-document corpus only about forty
# carried one. Treating unknown age as disqualifying made 98% of that archive
# unservable and refused twenty-one of twenty-four grower questions, while the
# passages themselves were correct, in zone and correctly cited.
#
# So an unknown year lowers confidence rather than voiding it, and the answer
# shows the source as undated so the reader can weigh that themselves. The
# alternative — silently scoring it as fresh — is the thing worth avoiding, and
# this is not that.
UNDATED_WEIGHT = 0.6

# A violation of any of these means the statement is wrong, not merely thin.
HARD = "hard"
SOFT = "soft"

DIGIT = re.compile(r"\d[\d.,]*")


@dataclass
class Violation:
    kind: str
    severity: str
    detail: str

    def __str__(self) -> str:
        return f"{self.kind}: {self.detail}"


@dataclass
class Statement:
    """A claim with everything needed to serve it, or the reasons it cannot be."""

    claim: str
    polarity: str
    zone: str = ""
    crop: str = ""
    growth_stage: str = ""
    season_window: str = ""
    source: dict = field(default_factory=dict)
    trust_tier: str = ""
    freshness_ts: str | None = None
    integrity_score: float | None = None
    violations: list = field(default_factory=list)

    @property
    def status(self) -> str:
        if any(v.severity == HARD for v in self.violations):
            return "rejected"
        if self.violations or self.integrity_score is None:
            return "needs_review"
        return "accepted"

    @property
    def servable(self) -> bool:
        """Whether this may be shown to a grower.

        Provenance is mandatory and the boundary is hard, so a statement without
        a source chunk or without a zone is withheld however good it looks.
        """
        return (
            self.status == "accepted"
            and bool(self.source.get("chunk"))
            and bool(self.zone)
        )

    def as_dict(self) -> dict:
        return {
            "claim": self.claim,
            "polarity": self.polarity,
            "zone": self.zone,
            "crop": self.crop,
            "growth_stage": self.growth_stage,
            "season_window": self.season_window,
            "source": self.source,
            "trust_tier": self.trust_tier,
            "freshness_ts": self.freshness_ts,
            "integrity_score": self.integrity_score,
            "status": self.status,
            "servable": self.servable,
            "violations": [{"kind": v.kind, "severity": v.severity, "detail": v.detail}
                           for v in self.violations],
        }


def normalise_figures(text: str) -> set:
    """Every number in a text, in a form two spellings of it share.

    Turkish writes decimals with a comma, so 0,24 and 0.24 are one value. A
    trailing separator is punctuation rather than part of the number.
    """
    out = set()
    for raw in DIGIT.findall(text or ""):
        cleaned = raw.rstrip(".,")
        if not cleaned:
            continue
        # Thousands separators vary by document; compare on the digits and the
        # position of the decimal mark rather than on the spelling.
        unified = cleaned.replace(".", ",")
        parts = unified.split(",")
        if len(parts) > 1 and len(parts[-1]) in (1, 2) and parts[-1].isdigit():
            value = "".join(parts[:-1]) + "." + parts[-1]
        else:
            value = "".join(parts)
        try:
            out.add(f"{float(value):g}")
        except ValueError:
            continue
    return out


def _feature(candidate) -> dict:
    return {
        "polarity": candidate.polarity,
        "conditions": len(candidate.conditions),
        "times": len(candidate.times),
        "figures": normalise_figures(candidate.text),
    }


def validate(claim: str, candidate, grammar: dict) -> list:
    """Compare a produced claim against the sentence it came from.

    The claim is re-read with the same grammar that found the candidate, so the
    comparison is between two things measured the same way rather than between a
    measurement and an impression.
    """
    violations: list = []
    if not (claim or "").strip():
        return [Violation("empty", HARD, "no claim was produced")]

    read_back = claim_candidates.find(claim, grammar)
    source = _feature(candidate)

    # A claim may be rephrased into something the grammar no longer recognises
    # as advice. That is not automatically wrong, but every check below depends
    # on reading the claim, so silence here would look like agreement.
    if not read_back:
        if source["polarity"] != "observe":
            violations.append(Violation(
                "unreadable", HARD,
                "the claim carries no recognisable advice though the source did"))
        return violations

    produced = _feature(read_back[0])

    # 1. Negation. In Turkish the difference is two letters and the meaning is
    #    opposite, which is why it is compared rather than read.
    if source["polarity"] == "warn" and produced["polarity"] != "warn":
        violations.append(Violation(
            "dropped_negation", HARD,
            "the source forbids this and the claim does not"))
    if source["polarity"] != "warn" and produced["polarity"] == "warn":
        violations.append(Violation(
            "added_negation", HARD,
            "the claim forbids something the source does not"))

    # 2. An observation must not become an instruction. The source described
    #    what happens; the claim would tell a grower to do it.
    if source["polarity"] == "observe" and produced["polarity"] == "recommend":
        violations.append(Violation(
            "observation_as_instruction", HARD,
            "the source reports what occurs; the claim instructs someone to act"))

    # 3. Conditions. Losing one makes conditional advice unconditional, which is
    #    how advice reaches a grower it was never meant for.
    if source["conditions"] and not produced["conditions"]:
        violations.append(Violation(
            "dropped_condition", HARD,
            "the source states the advice conditionally and the claim does not"))

    # 4. Timing. Guidance whose season or stage is lost cannot be acted on, and
    #    acting on it at the wrong time can be worse than not acting.
    if source["times"] and not produced["times"]:
        violations.append(Violation(
            "dropped_timing", HARD,
            "the source carries timing the claim omits"))

    # 5. Figures. A number in the claim that is absent from the source has been
    #    invented or mis-read, and doses are the highest-risk content here.
    invented = produced["figures"] - source["figures"]
    if invented:
        violations.append(Violation(
            "figure_not_in_source", HARD,
            f"claim states {sorted(invented)}, which the source does not"))
    dropped = source["figures"] - produced["figures"]
    if dropped:
        violations.append(Violation(
            "dropped_figure", SOFT,
            f"the source gives {sorted(dropped)} and the claim omits it"))

    return violations


def freshness(year, today: date | None = None) -> float | None:
    """How much weight a source's age leaves it, between 0 and 1.

    Returned as None rather than 1.0 when the year is unknown. An undated source
    is not a fresh one, and scoring it as fresh would rank guidance of unknown
    age above guidance known to be recent.
    """
    if not year:
        return None
    try:
        published = int(year)
    except (TypeError, ValueError):
        return None
    current = (today or date.today()).year
    if published > current:
        return None
    age = current - published
    return 0.5 ** (age / FRESHNESS_HALF_LIFE_YEARS)


# Provenance resolution reports confidence as a word; scoring needs a number.
# The two halves were written apart and met for the first time on a real corpus,
# where a caller had to bridge them by hand. Accepting both is the seam.
CONFIDENCE_WORDS = {"high": 1.0, "medium": 0.7, "moderate": 0.7, "low": 0.4}


def _as_confidence(value):
    """A confidence as a number, whether it arrived as one or as a word."""
    if value is None:
        return None
    if isinstance(value, str):
        return CONFIDENCE_WORDS.get(value.strip().lower())
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def integrity(tier: str, zone_confidence, year, violations: list, today: date | None = None):
    """A single number for how much a statement can be relied on, or None.

    None only where the statement is genuinely unusable: it failed a hard check,
    its publisher class is unknown, or it could not be placed. Those are facts
    about whether it may be served at all.

    An unknown publication year is not one of them. It is missing information
    about a real statement, and it is weighted down rather than treated as
    disqualifying — see UNDATED_WEIGHT for what that cost.
    """
    if any(v.severity == HARD for v in violations):
        return None
    weight = TIER_WEIGHT.get(tier)
    if weight is None:
        return None
    confidence = _as_confidence(zone_confidence)
    if confidence is None:
        return None
    fresh = freshness(year, today=today)
    if fresh is None:
        # Age unknown. Weigh it below anything of known recency, and serve it.
        fresh = UNDATED_WEIGHT
    score = weight * confidence * fresh
    # A soft violation is a real reduction in usefulness, not a note.
    score *= 0.8 ** sum(1 for v in violations if v.severity == SOFT)
    return round(min(1.0, max(0.0, score)), 3)


def build(candidate, context: dict, slots: dict | None, grammar: dict,
          today: date | None = None) -> Statement:
    """Assemble a statement from a candidate and the slots something filled.

    `slots` is whatever produced the judgement — a model, a person, a rule. It
    is treated as a proposal throughout. Passing None records the candidate's
    own sentence unchanged, which is the deterministic path and cannot introduce
    any of the five errors because it rewrites nothing.
    """
    slots = slots or {}
    claim = (slots.get("claim") or candidate.text).strip()

    violations = validate(claim, candidate, grammar)

    source = {
        "document": context.get("document", ""),
        "chunk": context.get("chunk", ""),
        "revision": context.get("revision", ""),
    }
    if not source["chunk"]:
        violations.append(Violation(
            "no_provenance", HARD,
            "no source chunk, and a statement without one may never be served"))

    zone = slots.get("zone") or context.get("zone", "")
    if not zone:
        violations.append(Violation(
            "no_zone", HARD,
            "no zone, and the boundary cannot be enforced without one"))

    statement = Statement(
        claim=claim,
        polarity=candidate.polarity,
        zone=zone,
        crop=slots.get("crop") or context.get("crop", ""),
        growth_stage=slots.get("growth_stage", ""),
        season_window=slots.get("season_window", ""),
        source=source,
        trust_tier=context.get("tier", ""),
        freshness_ts=str(context["year"]) if context.get("year") else None,
        violations=violations,
    )
    statement.integrity_score = integrity(
        statement.trust_tier, context.get("zone_confidence"), context.get("year"),
        violations, today=today,
    )
    return statement


def summarise(statements: list) -> dict:
    """What a run produced, counted by what happens to each statement."""
    by_kind: dict = {}
    for s in statements:
        for v in s.violations:
            by_kind[v.kind] = by_kind.get(v.kind, 0) + 1
    scored = [s.integrity_score for s in statements if s.integrity_score is not None]
    return {
        "statements": len(statements),
        "accepted": sum(1 for s in statements if s.status == "accepted"),
        "needs_review": sum(1 for s in statements if s.status == "needs_review"),
        "rejected": sum(1 for s in statements if s.status == "rejected"),
        "servable": sum(1 for s in statements if s.servable),
        "violations_by_kind": dict(sorted(by_kind.items(), key=lambda kv: -kv[1])),
        "mean_integrity": round(sum(scored) / len(scored), 3) if scored else None,
        "unscored": sum(1 for s in statements if s.integrity_score is None),
    }
