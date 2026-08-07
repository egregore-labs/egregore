"""Assemble an answer from recorded statements, or decline to.

This is the last stage, and the only one a grower ever sees. Everything upstream
can be correct and this stage can still do harm, because harm here is not a
crash — it is a confident, well-sourced paragraph about a grove three hundred
kilometres away, or a recommendation whose registration lapsed in 2019, or a
silent choice between two sources that disagree.

So the rules it enforces are the ones stated as invariants rather than
preferences:

    Zone is a hard boundary. Advice valid in one zone is not served outside it,
    and a statement whose zone is unknown is not served at all. The filter runs
    before ranking, because filtering a ranked list quietly shortens it instead
    of replacing what it removed.

    Provenance is mandatory. Nothing reaches a grower without the chunk it came
    from. An unattributable claim is dropped, however good it looks.

    Trust tier is always visible. The reader decides how much weight to give a
    field report against a ministry instruction; that judgement is not made for
    them by hiding where the sentence came from.

    Disagreement is not resolved. Sources that point different ways are served
    side by side with their tiers, because picking one silently presents a live
    controversy as settled fact. What this stage will not do is *label* a pair
    as contradictory, having failed twice to do it honestly — see
    find_review_candidates.

    If it is not in the substrate it does not exist. No answer is improvised
    from nothing; an empty result is reported as empty and written to the gap
    log, which is the queue of what the archive still needs.

The last rule is the one that costs something. A system that declines is less
impressive than one that always replies, and most of the questions real growers
ask have a part no archive can answer — what their own yield was, which mill to
use, what this particular spring did. Those get a question back rather than a
guess, and the difference between asking and guessing is the whole point.
"""

from __future__ import annotations

import re
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent))

import retrieval_eval  # noqa: E402

# Reasons an answer was withheld, named so the gap log is a work queue rather
# than a list of failures.
GAP_NO_STATEMENTS = "no statement in the archive matches this question"
GAP_OUT_OF_ZONE = "statements exist but none apply to this zone"
GAP_NO_PROVENANCE = "matching statements carry no source chunk and cannot be served"
GAP_STALE = "matching statements cite a revision the document no longer has"

WORD = re.compile(r"\w{4,}", re.UNICODE)


@dataclass
class Served:
    """One statement as a grower sees it, with everything needed to judge it."""

    claim: str
    tier: str
    zone: str
    source: dict
    freshness: str | None
    integrity: float | None
    stale: bool = False

    def as_dict(self) -> dict:
        return {
            "claim": self.claim,
            "tier": self.tier,
            "zone": self.zone,
            "source": self.source,
            "freshness": self.freshness,
            "integrity": self.integrity,
            "stale": self.stale,
        }


@dataclass
class ReviewCandidate:
    """Two statements that may disagree — for a curator, never for a grower.

    This is not a detected contradiction. It is a pair worth a domain expert's
    minute, produced by a test too coarse to assert anything to the person
    working the grove.
    """

    subject: str
    recommends: Served
    warns: Served

    def as_dict(self) -> dict:
        return {
            "subject": self.subject,
            "recommends": self.recommends.as_dict(),
            "warns": self.warns.as_dict(),
            "note": "possible disagreement, unverified — for expert review, not for display",
        }


@dataclass
class Answer:
    question: str
    zone: str
    served: list = field(default_factory=list)
    review_candidates: list = field(default_factory=list)
    follow_ups: list = field(default_factory=list)
    gap: str | None = None

    @property
    def answered(self) -> bool:
        return bool(self.served)

    @property
    def partial(self) -> bool:
        """Answered from the archive, but part of the question needs the asker."""
        return bool(self.served and self.follow_ups)

    def as_dict(self) -> dict:
        return {
            "question": self.question,
            "zone": self.zone,
            "answered": self.answered,
            "partial": self.partial,
            "statements": [s.as_dict() for s in self.served],
            "review_candidates": [c.as_dict() for c in self.review_candidates],
            "follow_ups": self.follow_ups,
            "gap": self.gap,
        }


def load_follow_up_rules(config: dict) -> list:
    """Questions the archive cannot answer, and what to ask back.

    Instance configuration. Which phrasings signal "this needs your own figures"
    is a fact about a language and a farming culture, not about answering.
    """
    rules = ((config or {}).get("answer_grammar") or {}).get("follow_ups") or []
    out = []
    for rule in rules:
        if not isinstance(rule, dict):
            continue
        pattern, ask = rule.get("pattern"), rule.get("ask")
        if not pattern or not ask:
            continue
        try:
            out.append((re.compile(pattern, re.IGNORECASE | re.UNICODE), ask))
        except re.error:
            continue
    return out


def follow_ups_for(question: str, rules: list) -> list:
    asks = []
    for pattern, ask in rules:
        if pattern.search(question or "") and ask not in asks:
            asks.append(ask)
    return asks


def _subject(text: str) -> set:
    return set(WORD.findall((text or "").lower()))


def find_review_candidates(served: list, statements: list, vocabulary=None,
                           overlap: int = 3) -> list:
    """Pairs that might disagree, for a curator to check. Never shown to a grower.

    Two attempts at calling these conflicts outright both failed on the real
    archive, and the failures are recorded here because the second looked like a
    fix and was not.

    Word overlap flagged 52 pairs across the benchmark questions. Every one
    inspected was spurious: two passages sharing a section heading, or "open
    drainage channels in waterlogged soil" set against "avoid planting in
    waterlogged clay, and if planted, open drainage channels" — which agree, the
    warning belonging to a different action in the same sentence.

    Gating on shared ontology concepts halved that to 26 and did not improve it.
    The concepts available are crop-level and practice-level, so the shared term
    came back as `zeytin` — olive, which every statement in the archive is about
    — or `budama`, pruning, under which one passage says to pile prunings away
    from the grove and another says to remove them two kilometres. They agree.

    The common fault is that neither test establishes the two statements address
    the same *action*, and no amount of threshold tuning reaches that. The plan
    puts real detection on CONFLICTS_WITH edges between statements resolved to a
    single concept, which needs the graph projection and name resolution.

    So this no longer claims a contradiction. A false one tells a grower the
    archive is unreliable when it is not, and sends them to check by hand — the
    exact cost the archive exists to remove. Serving both statements with their
    tiers already satisfies "not silently merged"; labelling the disagreement is
    the part that has to wait for the ontology.
    """
    if vocabulary is None:
        return []

    import term_expand

    def concepts(text: str) -> set:
        return set(term_expand.phrases_in(text, vocabulary))

    by_polarity = {"recommend": [], "warn": []}
    for s, st in zip(served, statements):
        if st.polarity in by_polarity:
            by_polarity[st.polarity].append((s, concepts(s.claim), _subject(s.claim)))

    candidates = []
    for rec, rec_concepts, rec_terms in by_polarity["recommend"]:
        for warn, warn_concepts, warn_terms in by_polarity["warn"]:
            shared_concepts = rec_concepts & warn_concepts
            if not shared_concepts:
                continue
            # A shared concept establishes they are about the same thing. Shared
            # wording beyond it is weak evidence they address the same action —
            # weak enough that this stays a review candidate.
            if len(rec_terms & warn_terms) < overlap:
                continue
            candidates.append(ReviewCandidate(
                subject=" ".join(sorted(shared_concepts)[:3]),
                recommends=rec,
                warns=warn,
            ))
    return candidates


def assemble(question: str, zone: str, statements: list, hierarchy: dict,
             follow_up_rules: list | None = None, limit: int = 5,
             current_revisions: dict | None = None, vocabulary=None,
             relevance: list | None = None, genre_of: dict | None = None,
             genre_preferences: dict | None = None) -> Answer:
    """Turn matching statements into an answer, applying every invariant.

    `statements` are the candidates retrieval already found. This stage does not
    search; it decides what of the found material may be shown, and says so when
    the honest response is that nothing may.

    `relevance` is how well each statement answers *this* question, parallel to
    `statements`. It is required for a sensible answer and its absence is a real
    degradation, not a neutral default. Ranking on integrity alone looks
    reasonable and is not: integrity says how far a statement can be trusted,
    never what it is about. Measured on the archive, every statement drawn from
    one publisher class shares a tier, a year and a zone confidence, so their
    integrity scores are identical and the ordering among them is arbitrary. A
    grower asking about rejuvenation pruning was served three passages of
    fertiliser subsidy regulation, each perfectly trustworthy and none an answer.

    So relevance decides what is shown and integrity decides how far to trust
    what is shown. Neither substitutes for the other.

    `genre_of` maps a document to its kind and `genre_preferences` says what each
    kind is worth for this question. Together they stop a regulation from
    crowding out agronomy purely by repeating the asker's words — the ministry's
    subsidy conditions are a true and well-sourced answer to a question nobody
    asked. Weights demote; they never exclude, so a grower who does want the
    subsidy rules can still reach them.
    """
    answer = Answer(question=question, zone=zone)
    answer.follow_ups = follow_ups_for(question, follow_up_rules or [])

    if not zone:
        # Without a zone the boundary cannot be enforced, so nothing is served.
        # This is the fail-closed direction: no zone means no answer, never
        # every answer.
        answer.gap = GAP_OUT_OF_ZONE
        return answer

    if not statements:
        answer.gap = GAP_NO_STATEMENTS
        return answer

    scope = retrieval_eval.zones_in_scope(zone, hierarchy or {})

    in_zone = [s for s in statements if s.zone in scope]
    if not in_zone:
        answer.gap = GAP_OUT_OF_ZONE
        return answer

    with_source = [s for s in in_zone if s.source.get("chunk")]
    if not with_source:
        answer.gap = GAP_NO_PROVENANCE
        return answer

    servable = [s for s in with_source if s.servable]
    if not servable:
        answer.gap = GAP_NO_PROVENANCE
        return answer

    revisions = current_revisions or {}

    def is_stale(st) -> bool:
        current = revisions.get(st.source.get("document"))
        cited = st.source.get("revision")
        return bool(current and cited and current != cited)

    fresh = [s for s in servable if not is_stale(s)]
    if not fresh:
        # Every match cites a revision the document has moved past. Serving it
        # would quote a version of the guidance that no longer exists.
        answer.gap = GAP_STALE
        return answer

    # Rank by integrity, which already folds in tier, zone confidence and age.
    # Rank on relevance first, then integrity. A trustworthy statement about the
    # wrong subject is not a better answer than a less certain one about the
    # right subject — it is not an answer at all.
    weight = {}
    if relevance is not None:
        for st, score in zip(statements, relevance):
            weight[id(st)] = float(score)
    if genre_of:
        import doc_genre

        for st in statements:
            key = id(st)
            if key not in weight:
                continue
            genre = genre_of.get(st.source.get("document", ""), doc_genre.UNKNOWN)
            weight[key] *= doc_genre.weight_for(genre, genre_preferences or {})
    fresh.sort(key=lambda s: (
        -weight.get(id(s), 0.0),
        s.integrity_score is None,
        -(s.integrity_score or 0),
    ))

    def serve(st):
        return Served(claim=st.claim, tier=st.trust_tier, zone=st.zone,
                      source=dict(st.source), freshness=st.freshness_ts,
                      integrity=st.integrity_score, stale=False)

    # Disagreement is looked for across everything retrieved, not only across
    # what ranking chose to show. A contradicting source that placed fourth is
    # exactly the one a grower needs to see, and checking only the served subset
    # is how a live controversy gets presented as settled.
    all_served = [serve(s) for s in fresh]
    candidates = find_review_candidates(all_served, fresh, vocabulary=vocabulary)

    chosen = fresh[:limit]
    answer.served = [serve(s) for s in chosen]
    answer.review_candidates = candidates

    # A statement pointing the other way is promoted into the answer even if it
    # ranked below the cut, so both reach the grower with their tiers. They are
    # not labelled as contradicting — that claim is not currently supportable —
    # but neither is one of them silently dropped.
    shown = {(s.claim, s.source.get("chunk")) for s in answer.served}
    for candidate in candidates:
        for side in (candidate.recommends, candidate.warns):
            key = (side.claim, side.source.get("chunk"))
            if key not in shown:
                answer.served.append(side)
                shown.add(key)
    return answer


def score_statements(question: str, statements: list, vocabulary=None) -> list:
    """How well each individual statement answers the question.

    Retrieval scores passages, and a passage is many sentences. Inheriting the
    passage score gives every statement inside it the same relevance, so the
    ordering within the best passage stays arbitrary and an off-topic sentence
    from a well-matched document outranks the sentence that actually answers.
    Measured: a question about rejuvenation pruning was served fertiliser subsidy
    clauses that happened to sit in a highly-ranked passage.

    Scoring the claims themselves is the same BM25 machinery applied at the unit
    that is actually served.
    """
    if not statements:
        return []
    passages = [
        retrieval_eval.Passage(id=str(i), text=s.claim, document=s.source.get("document", ""),
                               zone=s.zone, tier=s.trust_tier, topic="")
        for i, s in enumerate(statements)
    ]
    index = retrieval_eval.Index(passages)
    every_zone = {p.zone for p in passages}
    ranked = index.search(question, every_zone, limit=len(passages),
                          per_document=0, vocabulary=vocabulary)
    scores = [0.0] * len(statements)
    for score, passage in ranked:
        scores[int(passage.id)] = score
    return scores


def gap_entry(answer: Answer, asked_at: str) -> dict:
    """What an unanswered question leaves behind.

    The gap log is the queue that tells the people curating this archive what it
    does not yet cover, so an unanswered question is more useful recorded than
    it is apologised for.
    """
    return {
        "question": answer.question,
        "zone": answer.zone,
        "reason": answer.gap,
        "asked_at": asked_at,
        "follow_ups": answer.follow_ups,
    }


def render(answer: Answer) -> str:
    """The answer as a grower reads it, tier and source always attached."""
    if not answer.answered:
        lines = [f"No answer in the archive for this. Reason: {answer.gap}"]
        if answer.follow_ups:
            lines.append("")
            lines.extend(f"  ? {q}" for q in answer.follow_ups)
        return "\n".join(lines)

    lines = []
    for s in answer.served:
        age = f", {s.freshness}" if s.freshness else ", undated"
        lines.append(f"• {s.claim}")
        lines.append(f"    [{s.tier or 'tier unknown'}{age}] {s.source.get('document', '')}"
                     f" · {s.source.get('chunk', '')}")

    if answer.follow_ups:
        lines.append("")
        lines.append("To answer the rest, I need:")
        lines.extend(f"  ? {q}" for q in answer.follow_ups)

    return "\n".join(lines)
