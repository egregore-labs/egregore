"""Bounded, offline lexical suggestions for human review of existing issues.

Scores rank shared words; they are not probabilities or duplicate decisions.
The caller owns repository validation and authorization. No report text is
executed, treated as instructions, sent to a provider, or returned as a body.
"""
from __future__ import annotations

import re
import unicodedata


_TITLE_INPUT_LIMIT = 512
_BODY_INPUT_LIMIT = 12000
_TITLE_OUTPUT_LIMIT = 240
_TERM_LIMIT = 256
_MATCHED_TERM_LIMIT = 12
_WORD = re.compile(r"[^\W_]+", re.UNICODE)
_STOP_WORDS = frozenset("""
a an and any are as at be been being but by can cannot could did do does doing for from
had has have having how i if in into is it its just me more my no not of on
once only or our out should so some than that the their them then there these
they this those through to too up us very was we were what when where which
while who why will with would you your other same still unable
actual affected again agent agents also api app application area bug bugs component context currently default
description egregore environment error errors expected fail failed failing
failure failures fix help issue issues normal please problem problems repro
report reports reproduce request result run running runs runtime session
sessions severity software something steps suite system test tests testing thing
things user users using want work working works broken
after before inside outside within without explicit explicitly require required requires
""".split())


def _text(value: str, limit: int) -> str:
    """Normalize bounded text; controls cannot escape a terminal or hide words."""
    normalized = unicodedata.normalize("NFKC", value[:limit])
    return " ".join("".join(
        " " if unicodedata.category(character).startswith("C") else character
        for character in normalized
    ).split())[:limit]


def _words(value: str) -> list[str]:
    # Punctuation splits paths, snake_case, flags, and filenames into searchable
    # words; unlike an English stemmer this preserves technical spellings.
    return _WORD.findall(value.casefold())


def _terms(value: str) -> set[str]:
    # Count each distinct term once so repetition cannot manufacture relevance.
    return set(list(dict.fromkeys(
        word for word in _words(value)
        if 3 <= len(word) <= 64 and not word.isdecimal() and word not in _STOP_WORDS
    ))[:_TERM_LIMIT])


def rank_candidates(title: str, description: str, issues: list[dict], *, limit: int = 5) -> list[dict]:
    """Return up to ten existing issues to review, without deciding a duplicate.

    Inputs are repository-validated issue rows. Each shared informative word
    contributes one lexical point, multiplied by three for each title in which
    it appears. An exact normalized title receives a 10,000-point priority
    bonus. Non-exact matches need at least two distinct informative words.
    Labels and lifecycle state never manufacture or boost a textual match.
    """
    if not isinstance(title, str) or not isinstance(description, str):
        raise ValueError("title and description must be text")
    if isinstance(limit, bool) or not isinstance(limit, int):
        raise ValueError("candidate limit must be an integer")
    limit = max(0, min(limit, 10))
    if not limit:
        return []

    whole_title = len(title) <= _TITLE_INPUT_LIMIT
    title = _text(title, _TITLE_INPUT_LIMIT)
    title_words = _words(title)
    title_terms = _terms(title)
    query_terms = title_terms | _terms(_text(description, _BODY_INPUT_LIMIT))
    if not query_terms:
        return []

    candidates = []
    for issue in issues:
        candidate_title = _text(issue["title"], _TITLE_INPUT_LIMIT)
        candidate_title_terms = _terms(candidate_title)
        candidate_terms = candidate_title_terms | _terms(_text(issue.get("body") or "", _BODY_INPUT_LIMIT))
        matched = query_terms & candidate_terms
        exact = (whole_title and len(issue["title"]) <= _TITLE_INPUT_LIMIT
                 and bool(title_terms) and title_words == _words(candidate_title))
        if not exact and len(matched) < 2:
            continue
        score = sum(
            (3 if term in title_terms else 1) * (3 if term in candidate_title_terms else 1)
            for term in matched
        ) + (10000 if exact else 0)
        # Put title evidence first, then lexical ordering for reproducibility.
        matched_terms = sorted(matched, key=lambda term: (
            -(int(term in title_terms) + int(term in candidate_title_terms)), term
        ))[:_MATCHED_TERM_LIMIT]
        reason = (
            "Exact normalized title; lexical ranking score, not a duplicate probability."
            if exact else
            f"{len(matched)} shared informative terms; lexical ranking score, not a duplicate probability."
        )
        candidates.append({
            "number": issue["number"],
            "url": issue["html_url"],
            # Plain untrusted JSON text; UI callers must escape their own output.
            "title": candidate_title[:_TITLE_OUTPUT_LIMIT],
            "state": issue["state"],
            "match": {"score": score, "matched_terms": matched_terms, "reason": reason},
            "next_action": "review_closed_issue" if issue["state"] == "closed" else "review_open_issue",
        })
    candidates.sort(key=lambda candidate: (-candidate["match"]["score"], candidate["number"]))
    return candidates[:limit]
