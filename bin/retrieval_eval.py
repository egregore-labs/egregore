"""Measure retrieval against questions whose answers are known.

A system that answers questions phrases a wrong answer exactly as well as a
right one. Nothing about the output distinguishes them, so the only instrument
that can is a set of questions someone has already answered — asked of the
system, and compared.

This runs such a fixture and reports what the plan requires: whether the hard
boundary ever leaked, how often the expected source was retrieved, how often
nothing was found, and how long it took. A boundary violation is a failure
regardless of how good the answer looked.

Expected answers are marked verified or not. An unverified expectation is a
guess written down, and counting it as evidence would make the measurement
agree with whoever wrote the fixture rather than with the domain.
"""

from __future__ import annotations

import json
import math
import re
import time
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

TOKEN = re.compile(r"\w{3,}", re.UNICODE)

# Turkish is agglutinative: budama, budaması and budamada are one word wearing
# three suffixes, and exact token matching treats them as three. Retrieval
# therefore under-returns on inflected forms. Stemming is a known gap, recorded
# here rather than silently tolerated — measuring it needs the fixture.
STEMMING = False


@dataclass
class Passage:
    id: str
    text: str
    document: str
    zone: str
    tier: str
    topic: str


@dataclass
class QueryResult:
    id: str
    question: str
    found: int
    top: list = field(default_factory=list)
    expected_hit: bool | None = None
    boundary_violation: list = field(default_factory=list)
    elapsed_ms: float = 0.0
    verified_expectation: bool = False


def tokenize(text: str) -> list[str]:
    return TOKEN.findall((text or "").lower())


def zones_in_scope(zone: str, hierarchy: dict) -> set[str]:
    """A zone plus everything it inherits from.

    Inheritance runs one way. A grower's own zone and the wider zones containing
    it are in scope; a sibling zone never is, which is the direction where a
    violation does harm.
    """
    scope = {zone}
    current = zone
    seen = {zone}
    while True:
        parent = hierarchy.get(current)
        if not parent or parent in seen:
            break
        scope.add(parent)
        seen.add(parent)
        current = parent
    return scope


# BM25 parameters at their standard values. k1 bounds how much repeating a term
# can raise a score; b sets how strongly length is normalised away.
K1 = 1.2
B = 0.75

# How many passages one document may contribute. Without a cap a single long
# document fills the whole list, and a grower reading five results sees one
# source five times instead of five sources.
PER_DOCUMENT = 2


class Index:
    """A lexical index over passages, filtered before ranking.

    Ranking is BM25 rather than plain term frequency. The difference is length:
    a longer passage contains more of every word, so under raw counts the
    longest passages in a corpus rise to the top of questions they have no
    particular claim to. Measured here, the two documents topping unrelated
    queries were the two longest chunks in the archive.
    """

    def __init__(self, passages: list[Passage]):
        self.passages = passages
        self.df: Counter = Counter()
        self.tf: list[Counter] = []
        self.lengths: list[int] = []
        for p in passages:
            counts = Counter(tokenize(p.text))
            self.tf.append(counts)
            self.lengths.append(sum(counts.values()))
            self.df.update(set(counts))
        self.n = max(1, len(passages))
        self.avg_length = (sum(self.lengths) / self.n) if self.lengths else 0.0

    def idf(self, term: str) -> float:
        """Inverse document frequency, in the form that stays positive.

        The textbook ratio goes to zero — and can go negative — for a term
        present in most of the corpus, which silently drops passages that do
        match. The +1 keeps every genuine match above zero.
        """
        df = self.df.get(term, 0)
        return math.log(1 + (self.n - df + 0.5) / (df + 0.5))

    def search(
        self,
        question: str,
        allowed_zones: set[str],
        limit: int = 5,
        per_document: int = PER_DOCUMENT,
        vocabulary=None,
    ) -> list[tuple[float, Passage]]:
        terms = tokenize(question)
        weights = {t: 1.0 for t in terms}
        if vocabulary is not None:
            import term_expand

            _, added = term_expand.expand(question, vocabulary)
            for t in added:
                # Only where the asker did not already use the word. An inferred
                # word never raises the weight of one they chose themselves.
                if len(t) >= 3 and t not in weights:
                    weights[t] = term_expand.EXPANSION_WEIGHT

        scored = []
        for i, p in enumerate(self.passages):
            # The zone filter runs before ranking, not after. Filtering a ranked
            # list would let a better-scoring out-of-zone passage displace an
            # in-zone one and shorten the result rather than replace it.
            if p.zone not in allowed_zones:
                continue
            counts = self.tf[i]
            norm = K1 * (1 - B + B * (self.lengths[i] / self.avg_length)) if self.avg_length else K1
            score = 0.0
            for t, weight in weights.items():
                tf = counts.get(t, 0)
                if tf:
                    score += weight * self.idf(t) * (tf * (K1 + 1)) / (tf + norm)
            if score > 0:
                scored.append((score, p))
        scored.sort(key=lambda x: -x[0])

        if per_document <= 0:
            return scored[:limit]
        seen: Counter = Counter()
        capped = []
        for score, p in scored:
            if seen[p.document] >= per_document:
                continue
            seen[p.document] += 1
            capped.append((score, p))
            if len(capped) >= limit:
                break
        return capped


def load_passages(manifest_path: Path, data_root: Path) -> list[Passage]:
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    chunk_re = re.compile(r"<!-- ingest-chunk: (\S+) -->\n\n(.*?)(?=\n## Chunk |\Z)", re.S)
    passages: list[Passage] = []
    for doc in manifest.get("documents", []):
        body = (data_root / doc["file_path"]).read_text(encoding="utf-8", errors="replace")
        provenance = doc.get("provenance") or {}
        catalogued = provenance.get("from_catalogue") or {}
        excluded = {
            c["id"] for c in doc.get("chunks", []) if (c.get("segment") or {}).get("kind") == "bibliography"
        }
        for match in chunk_re.finditer(body):
            cid = match.group(1)
            if cid in excluded:
                continue
            passages.append(
                Passage(
                    id=cid,
                    text=match.group(2),
                    document=doc.get("title", ""),
                    zone=(doc.get("boundaries") or {}).get("zone", ""),
                    tier=provenance.get("tier", ""),
                    topic=catalogued.get("topic", ""),
                )
            )
    return passages


def run(fixture: dict, index: Index, vocabulary=None) -> list[QueryResult]:
    hierarchy = fixture.get("zone_hierarchy") or {}
    results: list[QueryResult] = []

    for query in fixture.get("queries", []):
        zone = query.get("zone") or fixture.get("default_zone") or ""
        scope = zones_in_scope(zone, hierarchy) if zone else set()

        started = time.perf_counter()
        hits = (
            index.search(query["text"], scope, limit=query.get("limit", 5), vocabulary=vocabulary)
            if scope
            else []
        )
        elapsed = (time.perf_counter() - started) * 1000

        expected = (query.get("expect") or {}).get("documents") or []
        verified = bool((query.get("expect") or {}).get("verified"))
        expected_hit = None
        if expected:
            retrieved = {p.document for _, p in hits}
            expected_hit = any(e in retrieved for e in expected)

        # Anything returned from outside the permitted scope is a failure of the
        # only guarantee the system makes about where advice applies.
        violations = [p.document for _, p in hits if p.zone not in scope]

        results.append(
            QueryResult(
                id=query.get("id", "?"),
                question=query["text"],
                found=len(hits),
                top=[{"document": p.document, "zone": p.zone, "tier": p.tier, "chunk": p.id} for _, p in hits[:3]],
                expected_hit=expected_hit,
                boundary_violation=violations,
                elapsed_ms=round(elapsed, 1),
                verified_expectation=verified,
            )
        )
    return results


def diagnose(passages: list[Passage]) -> list[str]:
    """Reasons a corpus will answer nothing, stated before the run does.

    Zone is a hard retrieval boundary, so a corpus ingested without a publisher
    profile carries no zone and every query is refused. That is the boundary
    working — advice that cannot be placed is not served — but the report it
    produces reads as `0 answered, 0 boundary violations`, which looks closer to
    success than to the misconfiguration it is.
    """
    notes = []
    if not passages:
        return ["the corpus is empty: no passages were loaded from the manifest"]

    zoneless = sum(1 for p in passages if not p.zone)
    if zoneless == len(passages):
        notes.append(
            f"every one of {len(passages):,} passages has no zone, so every query will be "
            "refused. The corpus was probably ingested without EGREGORE_PUBLISHER_PROFILE set."
        )
    elif zoneless:
        notes.append(f"{zoneless:,} of {len(passages):,} passages have no zone and can never be served")

    tierless = sum(1 for p in passages if not p.tier)
    if tierless == len(passages):
        notes.append("no passage carries a trust tier, so results cannot be ranked by source reliability")
    return notes


def report(results: list[QueryResult]) -> dict:
    answered = [r for r in results if r.found]
    checked = [r for r in results if r.expected_hit is not None and r.verified_expectation]
    hits = [r for r in checked if r.expected_hit]
    latencies = sorted(r.elapsed_ms for r in results) or [0.0]
    violations = [r for r in results if r.boundary_violation]

    def pct(n, d):
        return round(100 * n / d, 1) if d else None

    return {
        "queries": len(results),
        "answered": len(answered),
        "unanswered": len(results) - len(answered),
        "unanswered_rate_pct": pct(len(results) - len(answered), len(results)),
        "boundary_violations": len(violations),
        "citation_hit_rate_pct": pct(len(hits), len(checked)),
        "expectations_verified": len(checked),
        "expectations_unverified": sum(
            1 for r in results if r.expected_hit is not None and not r.verified_expectation
        ),
        "p50_ms": latencies[len(latencies) // 2],
        "p95_ms": latencies[min(len(latencies) - 1, int(len(latencies) * 0.95))],
    }


def format_report(report: dict, results: list[QueryResult], verbose: bool = False) -> str:
    lines = [
        f"queries {report['queries']} · answered {report['answered']} · unanswered {report['unanswered']}",
        "",
        f"boundary_violations          {report['boundary_violations']}",
        f"citation_hit_rate_pct        {report['citation_hit_rate_pct']}",
        f"expectations_verified        {report['expectations_verified']}",
        f"expectations_unverified      {report['expectations_unverified']}",
        f"p50_ms {report['p50_ms']} · p95_ms {report['p95_ms']}",
    ]
    if report["citation_hit_rate_pct"] is None:
        lines += [
            "",
            "The hit rate is unavailable because no expectation has been confirmed by",
            "someone who knows the domain. It is withheld rather than computed from",
            "guesses, which would only measure agreement with whoever wrote the fixture.",
        ]
    if verbose:
        lines.append("")
        for r in results:
            lines.append(f"[{r.id}] {r.question}")
            lines.append(f"    {r.found} found · {r.elapsed_ms} ms")
            for hit in r.top:
                lines.append(f"    · {hit['document'][:70]}  ({hit['zone']}, {hit['tier']})")
            if r.boundary_violation:
                lines.append(f"    VIOLATION: {r.boundary_violation}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    import argparse

    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--fixture", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--data-root", required=True, type=Path)
    parser.add_argument("--vocabulary", type=Path, nargs="*", default=[],
                        help="term files used to expand a question into the archive's wording")
    parser.add_argument("--verbose", action="store_true", help="show retrieved sources per query")
    parser.add_argument("--json", action="store_true", help="emit the report as JSON")
    args = parser.parse_args(argv)

    fixture = json.loads(args.fixture.read_text(encoding="utf-8"))
    started = time.perf_counter()
    passages = load_passages(args.manifest, args.data_root)
    index = Index(passages)
    if not args.json:
        print(f"loaded {len(passages):,} passages in {time.perf_counter() - started:.1f}s "
              "(bibliographies excluded)\n")

    vocabulary = None
    if args.vocabulary:
        import term_expand

        vocabulary = term_expand.load_vocabulary(args.vocabulary)
        if not args.json:
            print(f"vocabulary: {len(vocabulary)} term groups")
            for skipped in vocabulary.skipped:
                print(f"  skipped {skipped}")

    problems = diagnose(passages)
    if problems and not args.json:
        for note in problems:
            print(f"!! {note}")
        print()

    results = run(fixture, index, vocabulary=vocabulary)
    summary = report(results)

    if args.json:
        print(json.dumps({"report": summary, "diagnostics": problems,
                          "results": [vars(r) for r in results]},
                         ensure_ascii=False, indent=2))
    else:
        print(format_report(summary, results, verbose=args.verbose))

    # A boundary violation is the one failure that must be actionable from a
    # script; everything else is a measurement, not a fault.
    return 1 if (summary["boundary_violations"] or problems) else 0


if __name__ == "__main__":
    raise SystemExit(main())
