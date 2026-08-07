"""Tell what kind of document this is, separately from who published it.

Trust tier answers "how much can this source be relied on" by looking at the
publisher. It cannot answer "is this the kind of document that addresses my
question", and those come apart badly in a government archive, where the same
ministry publishes both the manual telling a grower how to prune and the
regulation setting out what they are paid for pruning.

Measured on the archive: asked whether to rejuvenate a forty-year-old tree and
what the risk is, the system returned the rehabilitation subsidy conditions.
That text repeats the exact phrase the grower used, is in zone, is correctly
sourced, is tier T2 — and is not an answer. It scores six regulation markers and
no guidance markers; the manual that does answer scores the reverse. Nothing in
the model could see the difference, because tier records the publisher and both
came from the same one.

So genre is a second axis, orthogonal to tier, and neither substitutes for the
other. A regulation from the ministry is highly trustworthy about what the
ministry will pay for and says nothing about when to prune.

Detection is by declared markers rather than by reading. A legal article number,
a communiqué heading, a gazette reference — these are structural and cheap and
they do not hallucinate. Where the markers are silent this reports `unknown`
rather than guessing, and a document of unknown genre is never penalised for it:
being unclassified is not evidence of being the wrong kind.

Genres and their markers are instance data. That a corpus mixes regulation with
practice is general; that Turkish regulations say MADDE is not.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

UNKNOWN = "unknown"

# How far ahead the leading genre must be before the label means anything. A
# document carrying two regulation markers and two guidance markers has not been
# classified, it has been guessed at.
MARGIN = 2


@dataclass
class Genre:
    name: str
    score: int = 0
    evidence: list = field(default_factory=list)
    runner_up: str = ""
    runner_up_score: int = 0

    @property
    def confident(self) -> bool:
        return self.name != UNKNOWN

    def as_dict(self) -> dict:
        out = {"genre": self.name, "score": self.score, "evidence": self.evidence}
        if self.runner_up:
            out["runner_up"] = self.runner_up
            out["runner_up_score"] = self.runner_up_score
        return out


def load_genres(config: dict) -> dict:
    """Genre names mapped to their compiled markers.

    A profile declaring no genres classifies nothing, which is the default and
    leaves ranking exactly as it was.
    """
    declared = (config or {}).get("document_genres") or {}
    genres: dict = {}
    for name, patterns in declared.items():
        if not isinstance(patterns, list):
            continue
        compiled = []
        for pattern in patterns:
            if not isinstance(pattern, str):
                continue
            try:
                compiled.append(re.compile(pattern, re.IGNORECASE | re.UNICODE))
            except re.error:
                continue
        if compiled:
            genres[name] = compiled
    return genres


def classify(text: str, genres: dict) -> Genre:
    """Which kind of document this is, or that it cannot be told.

    Scored by how many distinct markers appear, not how often. A regulation that
    says MADDE forty times is not more of a regulation than one that says it
    twice, and counting occurrences would let a long document outrank a short
    one of the same kind.
    """
    if not genres or not text:
        return Genre(UNKNOWN)

    scored = []
    for name, patterns in genres.items():
        evidence = [p.pattern for p in patterns if p.search(text)]
        scored.append((len(evidence), name, evidence))
    scored.sort(key=lambda x: (-x[0], x[1]))

    top_score, top_name, top_evidence = scored[0]
    if top_score == 0:
        return Genre(UNKNOWN)

    runner_score, runner_name = (scored[1][0], scored[1][1]) if len(scored) > 1 else (0, "")
    if top_score - runner_score < MARGIN and runner_score > 0:
        # Genuinely mixed. Saying so is more useful than picking the leader by a
        # single marker, because the caller can then decline to weight it.
        return Genre(UNKNOWN, score=top_score, evidence=top_evidence,
                     runner_up=runner_name, runner_up_score=runner_score)

    return Genre(top_name, score=top_score, evidence=top_evidence,
                 runner_up=runner_name, runner_up_score=runner_score)


def load_preferences(config: dict) -> dict:
    """How much each genre is worth for the kind of question being answered.

    A weight below 1 demotes rather than excludes. Excluding would mean a grower
    asking about subsidies could never be shown the regulation that answers
    them, and the point is to stop regulation crowding out agronomy — not to
    make it unreachable.
    """
    prefs = (config or {}).get("genre_preferences") or {}
    return {k: float(v) for k, v in prefs.items() if isinstance(v, (int, float))}


def weight_for(genre_name: str, preferences: dict) -> float:
    """The multiplier for a genre, defaulting to no opinion.

    An unclassified document scores 1.0 — unchanged. Being unclassifiable is not
    evidence of being the wrong kind of document, and demoting for it would
    quietly bury every document whose markers this instance has not declared.
    """
    if not preferences:
        return 1.0
    return preferences.get(genre_name, preferences.get("_default", 1.0))


def summarise(genres_found: list) -> dict:
    """The genre mix of a corpus, including how much of it could not be told."""
    counts: dict = {}
    for g in genres_found:
        counts[g.name] = counts.get(g.name, 0) + 1
    total = len(genres_found) or 1
    return {
        "documents": len(genres_found),
        "by_genre": dict(sorted(counts.items(), key=lambda kv: -kv[1])),
        "unknown_pct": round(100 * counts.get(UNKNOWN, 0) / total, 1),
    }
