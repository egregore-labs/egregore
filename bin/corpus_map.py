#!/usr/bin/env python3
"""The corpus map: every document listed, none understood before it must be.

Intake makes documents retrievable. It does not make them knowledge, and the
distance between the two is where a corpus can become expensive: downstream
statement refinement may run a model or consume expert attention over passages
whether or not anyone will ever ask about them. On an archive of thousands of
documents, doing that wholesale spends effort on material that may never be
retrieved.

This module holds the line between the two. It maintains a *map* — one card
per document, built from evidence intake already recorded, at no model cost —
and a deterministic *promotion* step that scans only the chunks a real question
needs. Every promotion is written to a ledger with its trigger and exact local
scan size. This module makes no model call; downstream model or expert work has
to record its own actual cost rather than infer spend from promoted text.

The map is markdown and JSONL in the memory repo. Files are authoritative;
everything here can be rebuilt from the intake manifest and the state file,
and a rebuild never loses a promotion. Agents read the index in one pass and
open cards on need — nothing is ever re-ingested to answer a question.

Nothing in this module knows what an olive or a zone is. Vocabulary, grammar,
genres and boundaries come from the instance's publisher profile.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.append(str(Path(__file__).resolve().parent))
import claim_candidates  # noqa: E402
import doc_genre  # noqa: E402
import doc_segment  # noqa: E402
import ingest  # noqa: E402
import lac_record  # noqa: E402
import retrieval_eval  # noqa: E402

CHUNK_MARK = re.compile(r"<!-- ingest-chunk: ([0-9a-f-]+-c\d{4}-[0-9a-f]+) -->")
CHUNK_HEAD = re.compile(r"^## Chunk \d{4}$", re.M)
# How many documents a single index file may list before it is split by
# publisher class. One file an agent reads in a gulp is the point of the map;
# past this size the gulp stops being one.
SHARD_AT = 400
ABSTRACT_LIMIT = 1800
STATE_FILE = "state.json"
ROWS_FILE = "map.jsonl"
STATEMENTS_FILE = "statements.jsonl"


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def map_dir_for(args) -> Path:
    if getattr(args, "map_dir", None):
        return Path(args.map_dir).resolve()
    return (ingest.ROOT / "memory" / "corpora" / ingest.slug(args.source)).resolve()


def load_state(map_dir: Path) -> dict:
    path = map_dir / STATE_FILE
    if path.is_file():
        return json.loads(path.read_text(encoding="utf-8"))
    return {"documents": {}}


def save_state(map_dir: Path, state: dict) -> None:
    ingest.atomic_json(map_dir / STATE_FILE, state)


def load_rows(map_dir: Path) -> list[dict]:
    path = map_dir / ROWS_FILE
    if not path.is_file():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]


def manifest_for(source_id: str) -> dict:
    directory = ingest.source_dir(ingest.slug(source_id))
    manifest = ingest.load_manifest(directory)
    if not manifest.get("documents"):
        raise SystemExit(f"no manifest for source '{source_id}' under {directory} — run ingest first")
    return manifest


def doc_body(path: Path) -> str:
    """The document's text with intake scaffolding removed.

    The normalized file interleaves frontmatter, chunk headings and chunk
    markers with the extracted text. Genre markers and abstracts live in the
    text, not the scaffolding.
    """
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return ""
    if raw.startswith("---"):
        close = raw.find("\n---", 3)
        if close != -1:
            raw = raw[close + 4:]
    raw = CHUNK_MARK.sub("", raw)
    return CHUNK_HEAD.sub("", raw)


def doc_chunks(path: Path) -> list[tuple[str, str]]:
    """(chunk_id, text) pairs in document order."""
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        return []
    parts = CHUNK_MARK.split(raw)
    # parts = [preamble, id1, text1, id2, text2, ...]
    out = []
    for i in range(1, len(parts) - 1, 2):
        out.append((parts[i], parts[i + 1].split("## Chunk")[0].strip()))
    return out


def extract_abstract(text: str) -> str | None:
    """The document's own abstract, verbatim, when it declares one.

    The map never paraphrases: a card's position statement is the author's
    abstract or nothing. Where no abstract exists the card shows an opening
    excerpt labelled as such — an honest sample, not a summary.
    """
    profile = doc_segment.PROFILES[doc_segment.DEFAULT_PROFILE]
    match = profile["abstract_open"].search(text[:20000])
    if not match:
        return None
    window = text[match.end(): match.end() + 3000]
    keywords = profile["keywords"].search(window)
    body = window[: keywords.start()] if keywords else window[:ABSTRACT_LIMIT]
    body = body.strip()
    if len(body) > ABSTRACT_LIMIT:
        cut = body.rfind(".", 0, ABSTRACT_LIMIT)
        body = body[: cut + 1] if cut > 200 else body[:ABSTRACT_LIMIT]
    return body or None


def resolve_doc(manifest: dict, needle: str) -> dict:
    """One document record from an id prefix, a source-path fragment, or a title."""
    docs = manifest["documents"]
    hits = [d for d in docs if d["id"].startswith(needle)]
    if not hits:
        lowered = needle.lower()
        hits = [d for d in docs
                if lowered in d.get("source_path", "").lower()
                or lowered in d.get("title", "").lower()]
    if not hits:
        raise SystemExit(f"no document matches '{needle}'")
    if len(hits) > 1:
        listing = "\n".join(f"  {d['id'][:12]}  {d.get('source_path')}" for d in hits[:10])
        raise SystemExit(f"'{needle}' is ambiguous — {len(hits)} matches:\n{listing}")
    return hits[0]


def ledger_append(map_dir: Path, action: str, target: str, trigger: str,
                  cost: str, outcome: str) -> None:
    """One row per act that spent something, appended, never rewritten.

    The ledger is the corpus's account of itself: what was done, at whose
    request, at what cost, to what effect. It is the difference between
    claiming the pipeline is economical and being able to show it.
    """
    path = map_dir / "ledger.md"
    if not path.is_file():
        path.write_text(
            "# Ledger\n\n"
            "Every act that spent extraction, local compute, model attention, or expert time. "
            "`bin/corpus_map.py` records deterministic compute only; model or expert work "
            "must add its own actual cost. Appended by `bin/corpus_map.py`, never edited.\n\n"
            "| when | action | target | trigger | cost | outcome |\n"
            "|---|---|---|---|---|---|\n",
            encoding="utf-8",
        )
    def cell(value: str) -> str:
        return (value or "—").replace("|", "\\|").replace("\n", " ")
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"| {now_iso()} | {cell(action)} | {cell(target)} | "
                     f"{cell(trigger)} | {cell(cost)} | {cell(outcome)} |\n")


def gap_append(map_dir: Path, entry: dict) -> None:
    path = map_dir / "gaps.md"
    if not path.is_file():
        path.write_text(
            "# Gaps\n\nQuestions the corpus could not answer, with the reason. "
            "This is the acquisition and review queue — each entry is work for "
            "whoever curates the corpus, not an apology.\n",
            encoding="utf-8",
        )
    with path.open("a", encoding="utf-8") as handle:
        handle.write(f"\n## {entry.get('asked_at', now_iso())} — {entry.get('reason', 'gap')}\n\n"
                     f"> {entry.get('question', '')}\n\n"
                     f"- zone: `{entry.get('zone', '')}`\n")
        for follow_up in entry.get("follow_ups") or []:
            handle.write(f"- follow-up: {follow_up}\n")


# ---------------------------------------------------------------- build


def build_rows(manifest: dict, state: dict, profile: dict | None) -> list[dict]:
    genres = doc_genre.load_genres(profile or {})
    data_root = ingest.data_root()
    rows = []
    for doc in manifest["documents"]:
        doc_state = state["documents"].get(doc["id"], {})
        row = {
            "id": doc["id"],
            "title": doc.get("title", ""),
            "source_path": doc.get("source_path", ""),
            "revision": doc.get("revision", ""),
            "status": doc.get("status", ""),
            "chunks": len(doc.get("chunks") or []),
            "boundaries": doc.get("boundaries") or {},
            "tier": (doc.get("provenance") or {}).get("tier", ""),
            "publisher_class": (doc.get("provenance") or {}).get("publisher_class", ""),
            "zone_derived": bool((doc.get("provenance") or {}).get("derived")),
            "year": (doc.get("structure") or {}).get("publication_year"),
            "year_source": (doc.get("structure") or {}).get("year_source", ""),
            "extractor": (doc.get("extraction") or {}).get("extractor", ""),
            "uses": doc_state.get("uses", 0),
            "last_used": doc_state.get("last_used"),
            "promoted_chunks": len(doc_state.get("promoted", {})),
            "card": bool(doc_state.get("card")),
        }
        file_path = doc.get("file_path")
        text = doc_body(data_root / file_path) if file_path else ""
        row["text_chars"] = len(text)
        row["has_abstract"] = bool(text) and bool(
            doc_segment.PROFILES[doc_segment.DEFAULT_PROFILE]["abstract_open"].search(text[:20000]))
        if text and genres:
            genre = doc_genre.classify(text[:8000], genres)
            row["genre"] = genre.name
            row["genre_confident"] = genre.confident
        else:
            row["genre"] = ""
            row["genre_confident"] = False
        rows.append(row)
    return rows


def state_marker(row: dict) -> str:
    if row["status"] == "extraction_failed":
        return "✕"
    if row["promoted_chunks"]:
        return "◆"
    if row["uses"]:
        return "●"
    return "○"


def index_table(rows: list[dict]) -> str:
    lines = ["| st | id | title | year | zone | tier | genre | chunks | uses |",
             "|---|---|---|---|---|---|---|---|---|"]
    for row in sorted(rows, key=lambda r: (-(r["uses"]), r.get("source_path", ""))):
        zone = row["boundaries"].get("zone", "")
        title = row["title"][:64].replace("|", "\\|")
        genre = row["genre"] or "—"
        if row["genre"] and not row["genre_confident"]:
            genre += "?"
        lines.append(
            f"| {state_marker(row)} | `{row['id'][:12]}` | {title} "
            f"| {row['year'] or '—'} | {zone or '—'}{'*' if row['zone_derived'] else ''} "
            f"| {row['tier'] or '—'} | {genre} | {row['chunks']} | {row['uses']} |")
    return "\n".join(lines)


def write_index(map_dir: Path, source_id: str, rows: list[dict], manifest: dict) -> None:
    failed = [r for r in rows if r["status"] == "extraction_failed"]
    ok = [r for r in rows if r["status"] != "extraction_failed"]
    zoneless = [r for r in ok if not r["boundaries"].get("zone")]
    yearless = [r for r in ok if not r["year"]]
    promoted = [r for r in ok if r["promoted_chunks"]]
    total_chunks = sum(r["chunks"] for r in ok)
    promoted_chunks = sum(r["promoted_chunks"] for r in ok)
    total_chars = sum(r["text_chars"] for r in ok)

    head = [
        f"# Corpus map — `{source_id}`",
        "",
        f"Rebuilt {now_iso()} by `bin/corpus_map.py build`. One card per document; "
        "nothing here required a model. Position statements are the authors' own "
        "abstracts, verbatim — the map enriches, it never summarises.",
        "",
        "## How to use this map",
        "",
        "1. **Read this index** (or grep `map.jsonl`) — never re-ingest to find a document.",
        "2. **Retrieve** for a question: `python3 bin/corpus_map.py retrieve --source "
        f"{source_id} --question \"…\" --zone <zone>`.",
        "3. **Touch** documents a question used: `… touch <id> --source "
        f"{source_id} --question \"…\"` — usage is the curation signal.",
        "4. **Promote on need, never wholesale**: `… promote <id> --reason \"<the question>\"` "
        "extracts advice candidates from just that document, at a ledger-recorded cost.",
        "5. **Validate** filled statements (`… validate <id>`), then **answer** "
        "(`… answer --question \"…\"`) — refusals are recorded in `gaps.md`, not improvised around.",
        "",
        "States: ○ mapped · ● used · ◆ promoted · ✕ extraction failed. "
        "`*` marks a zone derived from provenance rather than stated.",
        "",
        "## Coverage — honest counts",
        "",
        f"- documents: **{len(rows)}** ({len(ok)} readable, {len(failed)} failed extraction)",
        f"- chunks: **{total_chunks}** · extracted text: ~{total_chars:,} chars",
        f"- without a zone (unservable until placed): **{len(zoneless)}**",
        f"- without a year (no freshness weighting): **{len(yearless)}**",
        f"- promoted: **{len(promoted)}** documents, {promoted_chunks} chunks "
        f"({(100 * promoted_chunks / total_chunks):.1f}% of the corpus)" if total_chunks else
        "- promoted: 0",
    ]
    if failed:
        head.append("")
        head.append("Failed extraction (reported, never silently indexed):")
        for row in failed:
            head.append(f"- `{row['id'][:12]}` {row['source_path']}")
    head.append("")
    head.append("## Spend")
    head.append("")
    head.append(f"- map build: deterministic, model cost **0** (read ~{total_chars:,} chars locally)")
    if total_chunks:
        head.append(
            f"- promotion so far: **{promoted_chunks} of {total_chunks} chunks** scanned "
            f"deterministically — `corpus_map.py` made 0 model calls; see `ledger.md`")
    head.append("")

    if len(ok) + len(failed) <= SHARD_AT:
        body = ["## Documents", "", index_table(rows)]
    else:
        shard_dir = map_dir / "index"
        shard_dir.mkdir(exist_ok=True)
        groups: dict[str, list[dict]] = {}
        for row in rows:
            groups.setdefault(row["publisher_class"] or "unclassified", []).append(row)
        body = ["## Documents", "",
                f"{len(rows)} documents, sharded by publisher class:", ""]
        for name in sorted(groups):
            shard = shard_dir / f"{ingest.slug(name)}.md"
            shard.write_text(f"# {name} — {len(groups[name])} documents\n\n"
                             + index_table(groups[name]) + "\n", encoding="utf-8")
            body.append(f"- [`{name}`](index/{ingest.slug(name)}.md) — {len(groups[name])}")
    (map_dir / "index.md").write_text("\n".join(head + body) + "\n", encoding="utf-8")


def cmd_build(args) -> int:
    manifest = manifest_for(args.source)
    map_dir = map_dir_for(args)
    map_dir.mkdir(parents=True, exist_ok=True)
    state = load_state(map_dir)
    profile = ingest.publisher_profile()
    rows = build_rows(manifest, state, profile)
    with (map_dir / ROWS_FILE).open("w", encoding="utf-8") as handle:
        for row in rows:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")
    write_index(map_dir, ingest.slug(args.source), rows, manifest)
    save_state(map_dir, state)
    total_chars = sum(r["text_chars"] for r in rows)
    ledger_append(map_dir, "map build", f"{len(rows)} documents", "operator",
                  f"~{total_chars:,} chars read locally · model 0", "index.md + map.jsonl rebuilt")
    print(json.dumps({"map_dir": str(map_dir), "documents": len(rows),
                      "failed": sum(1 for r in rows if r["status"] == "extraction_failed"),
                      "model_cost": 0}, ensure_ascii=False, indent=2))
    return 0


# ---------------------------------------------------------------- card


def materialize_card(map_dir: Path, doc: dict, row: dict | None) -> Path:
    data_root = ingest.data_root()
    text = doc_body(data_root / doc["file_path"]) if doc.get("file_path") else ""
    abstract = extract_abstract(text) if text else None
    provenance = doc.get("provenance") or {}
    structure = doc.get("structure") or {}
    lines = [
        f"# {doc.get('title', doc['id'][:12])}",
        "",
        f"- id: `{doc['id']}` · revision `{doc.get('revision')}`",
        f"- source: `{doc.get('source_path')}`",
        f"- boundaries: `{json.dumps(doc.get('boundaries') or {}, ensure_ascii=False)}`",
        f"- publisher: {provenance.get('publisher_class') or 'unknown'} · tier {provenance.get('tier') or '—'}"
        + (" · zone derived from provenance" if provenance.get("derived") else ""),
        f"- year: {structure.get('publication_year') or 'unknown'}"
        + (f" ({structure.get('year_source')})" if structure.get("year_source") else ""),
        f"- genre: {(row or {}).get('genre') or 'unclassified'}"
        + ("" if (row or {}).get("genre_confident") else " (unconfident)" if (row or {}).get("genre") else ""),
        f"- chunks: {len(doc.get('chunks') or [])} · extracted ~{len(text):,} chars",
        "",
    ]
    if abstract:
        lines += ["## Abstract — verbatim from the source", "", "> " + abstract.replace("\n", "\n> "), ""]
    elif text:
        opening = " ".join(text.split()[:80])
        lines += ["## Opening excerpt — no abstract in source; this is a sample, not a summary",
                  "", "> " + opening, ""]
    digest = map_dir / "digests" / f"{doc['id'][:12]}.md"
    if digest.is_file():
        lines += [f"Digest: [`digests/{digest.name}`](digests/{digest.name})", ""]
    cards = map_dir / "papers"
    cards.mkdir(parents=True, exist_ok=True)
    path = cards / f"{doc['id'][:12]}.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def cmd_card(args) -> int:
    manifest = manifest_for(args.source)
    map_dir = map_dir_for(args)
    state = load_state(map_dir)
    doc = resolve_doc(manifest, args.document)
    rows = {r["id"]: r for r in load_rows(map_dir)}
    path = materialize_card(map_dir, doc, rows.get(doc["id"]))
    state["documents"].setdefault(doc["id"], {})["card"] = True
    save_state(map_dir, state)
    print(path)
    return 0


# ---------------------------------------------------------------- touch


def cmd_touch(args) -> int:
    manifest = manifest_for(args.source)
    map_dir = map_dir_for(args)
    state = load_state(map_dir)
    touched = []
    for needle in args.documents:
        doc = resolve_doc(manifest, needle)
        entry = state["documents"].setdefault(doc["id"], {})
        entry["uses"] = entry.get("uses", 0) + 1
        entry["last_used"] = now_iso()
        touched.append(doc["id"][:12])
    save_state(map_dir, state)
    ledger_append(map_dir, "touch", ", ".join(touched), args.question or "—",
                  "0", "usage recorded")
    print(json.dumps({"touched": touched}))
    return 0


# ---------------------------------------------------------------- promote


def promotion_context(doc: dict) -> dict:
    provenance = doc.get("provenance") or {}
    structure = doc.get("structure") or {}
    boundaries = doc.get("boundaries") or {}
    return {
        "document": doc["id"],
        "revision": doc.get("revision", ""),
        "zone": boundaries.get("zone", ""),
        "crop": boundaries.get("crop", ""),
        "tier": provenance.get("tier", ""),
        "zone_confidence": provenance.get("confidence"),
        "year": structure.get("publication_year"),
    }


def cmd_promote(args) -> int:
    manifest = manifest_for(args.source)
    map_dir = map_dir_for(args)
    state = load_state(map_dir)
    profile = ingest.publisher_profile() or {}
    grammar = claim_candidates.load_grammar(profile)
    if not grammar.get("obligation"):
        raise SystemExit("the publisher profile declares no claim grammar — "
                         "promotion would find nothing; add claim_grammar first")
    doc = resolve_doc(manifest, args.document)
    if not doc.get("file_path"):
        raise SystemExit(f"{doc['id'][:12]} has no extracted text to promote")
    pairs = doc_chunks(ingest.data_root() / doc["file_path"])
    wanted = None
    if args.chunks and args.chunks != "all":
        indexes = {int(i) for i in args.chunks.split(",")}
        pairs = [(cid, text) for n, (cid, text) in enumerate(pairs, 1) if n in indexes]
        wanted = sorted(indexes)
    if not pairs:
        raise SystemExit("no chunks matched")

    digest_dir = map_dir / "digests"
    digest_dir.mkdir(parents=True, exist_ok=True)
    context = promotion_context(doc)
    chars_in = sum(len(t) for _, t in pairs)
    candidates_out = []
    lines = [
        f"# Digest — {doc.get('title')}",
        "",
        f"- source: `{doc.get('source_path')}` · revision `{doc.get('revision')}`",
        f"- zone `{context['zone'] or '—'}` · tier {context['tier'] or '—'} · year {context['year'] or '—'}",
        f"- promoted {now_iso()} · reason: {args.reason}",
        f"- chunks: {wanted or 'all'} ({len(pairs)} of {len(doc.get('chunks') or [])})",
        "",
        "Candidates below are the source's own sentences, found deterministically, "
        "with the features whose loss would invert or unground them. To refine one, "
        f"write slots to `digests/{doc['id'][:12]}.slots.json` "
        '(`{"<candidate id>": {"claim": …, "growth_stage": …, "season_window": …}}`), '
        "then run `validate`. Unrefined candidates are recorded verbatim — the "
        "deterministic path rewrites nothing and cannot misquote.",
        "",
    ]
    for chunk_id, text in pairs:
        found = claim_candidates.find(text, grammar)
        if not found:
            continue
        lines.append(f"## Chunk `{chunk_id}`")
        lines.append("")
        for n, candidate in enumerate(found, 1):
            cand_id = f"{chunk_id}-s{n:02d}"
            candidates_out.append({"id": cand_id, "chunk": chunk_id, **candidate.as_dict()})
            risks = ", ".join(candidate.risks) or "none"
            lines.append(f"### `{cand_id}` — {candidate.polarity} · hazards: {risks}")
            lines.append("")
            lines.append(f"> {candidate.text}")
            lines.append("")
    (digest_dir / f"{doc['id'][:12]}.md").write_text("\n".join(lines), encoding="utf-8")
    ingest.atomic_json(digest_dir / f"{doc['id'][:12]}.candidates.json",
                       {"document": doc["id"], "context": context, "reason": args.reason,
                        "promoted_at": now_iso(), "candidates": candidates_out})

    entry = state["documents"].setdefault(doc["id"], {})
    promoted = entry.setdefault("promoted", {})
    for chunk_id, _ in pairs:
        promoted[chunk_id] = {"reason": args.reason, "at": now_iso()}
    save_state(map_dir, state)
    materialize_card(map_dir, doc, None)
    entry["card"] = True
    save_state(map_dir, state)

    ledger_append(
        map_dir, "promote", f"{doc['id'][:12]} ({len(pairs)} chunks)", args.reason,
        f"{chars_in:,} source chars scanned deterministically; 0 model calls",
        f"{len(candidates_out)} advice candidates → digests/{doc['id'][:12]}.md")
    print(json.dumps({"document": doc["id"][:12], "chunks": len(pairs),
                      "candidates": len(candidates_out),
                      "digest": str(digest_dir / (doc['id'][:12] + '.md'))},
                     ensure_ascii=False, indent=2))
    return 0


# ---------------------------------------------------------------- validate


def cmd_validate(args) -> int:
    manifest = manifest_for(args.source)
    map_dir = map_dir_for(args)
    profile = ingest.publisher_profile() or {}
    grammar = claim_candidates.load_grammar(profile)
    doc = resolve_doc(manifest, args.document)
    digest_dir = map_dir / "digests"
    saved_path = digest_dir / f"{doc['id'][:12]}.candidates.json"
    if not saved_path.is_file():
        raise SystemExit(f"{doc['id'][:12]} has no promotion — run promote first")
    saved = json.loads(saved_path.read_text(encoding="utf-8"))
    slots_path = digest_dir / f"{doc['id'][:12]}.slots.json"
    slots_all = json.loads(slots_path.read_text(encoding="utf-8")) if slots_path.is_file() else {}

    built = []
    statements = []
    for entry in saved["candidates"]:
        candidate = claim_candidates.Candidate(**{
            k: v for k, v in entry.items() if k not in ("id", "chunk")})
        context = dict(saved["context"])
        context["chunk"] = entry["chunk"]
        statement = lac_record.build(candidate, context, slots_all.get(entry["id"]), grammar)
        built.append(statement)
        row = statement.as_dict()
        row["id"] = entry["id"]
        row["document_title"] = doc.get("title", "")
        row["reason"] = saved.get("reason", "")
        row["validated_at"] = now_iso()
        statements.append(row)

    # Rows for this document replace its previous rows; other documents' rows
    # are kept as they are. Statement identity is the candidate id, which is
    # anchored to the chunk hash — a re-promotion after content change gets new
    # ids rather than silently overwriting old evidence.
    path = map_dir / STATEMENTS_FILE
    kept = []
    if path.is_file():
        kept = [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()
                if line.strip() and not json.loads(line)["source"]["document"] == doc["id"]]
    with path.open("w", encoding="utf-8") as handle:
        for row in kept + statements:
            handle.write(json.dumps(row, ensure_ascii=False) + "\n")

    summary = lac_record.summarise(built)
    ledger_append(map_dir, "validate", doc["id"][:12], saved.get("reason", "—"),
                  f"{len(statements)} statements checked against source",
                  json.dumps(summary, ensure_ascii=False) if isinstance(summary, dict) else str(summary))
    print(json.dumps({"document": doc["id"][:12], "statements": len(statements),
                      "servable": sum(1 for s in statements if s.get("servable")),
                      "needs_review": sum(1 for s in statements if s.get("status") == "needs_review"),
                      "rejected": sum(1 for s in statements if s.get("status") == "rejected")},
                     ensure_ascii=False, indent=2))
    return 0


# ---------------------------------------------------------------- retrieve / answer


def load_vocabulary(paths: list[str]):
    if not paths:
        return None
    import term_expand
    return term_expand.load_vocabulary([Path(p) for p in paths])


def hierarchy_from(args, profile: dict | None) -> dict:
    if getattr(args, "fixture", None):
        fixture = json.loads(Path(args.fixture).read_text(encoding="utf-8"))
        return fixture.get("zone_hierarchy") or {}
    return (profile or {}).get("zone_hierarchy") or {}


def cmd_retrieve(args) -> int:
    directory = ingest.source_dir(ingest.slug(args.source))
    passages = retrieval_eval.load_passages(directory / "manifest.json", ingest.data_root())
    index = retrieval_eval.Index(passages)
    profile = ingest.publisher_profile()
    hierarchy = hierarchy_from(args, profile)
    allowed = retrieval_eval.zones_in_scope(args.zone, hierarchy)
    vocabulary = load_vocabulary(args.vocabulary)
    results = index.search(args.question, allowed, limit=args.limit, vocabulary=vocabulary)
    out = []
    for score, passage in results:
        out.append({"score": round(score, 2), "chunk": passage.id,
                    "document": passage.document, "zone": passage.zone,
                    "tier": passage.tier,
                    "snippet": " ".join(passage.text.split())[:220]})
    print(json.dumps({"question": args.question, "zone": args.zone,
                      "passages_in_corpus": len(passages), "results": out},
                     ensure_ascii=False, indent=2))
    return 0


def rehydrate(row: dict) -> lac_record.Statement:
    statement = lac_record.Statement(
        claim=row["claim"], polarity=row.get("polarity", ""),
        zone=row.get("zone", ""), crop=row.get("crop", ""),
        growth_stage=row.get("growth_stage", ""),
        season_window=row.get("season_window", ""),
        source=row.get("source") or {}, trust_tier=row.get("trust_tier", ""),
        freshness_ts=row.get("freshness_ts"),
        violations=[lac_record.Violation(v["kind"], v["severity"], v["detail"])
                    for v in row.get("violations") or []])
    statement.integrity_score = row.get("integrity_score")
    return statement


def cmd_answer(args) -> int:
    import answer as answer_module
    map_dir = map_dir_for(args)
    profile = ingest.publisher_profile() or {}
    path = map_dir / STATEMENTS_FILE
    rows = ([json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]
            if path.is_file() else [])
    statements = [rehydrate(row) for row in rows]
    vocabulary = load_vocabulary(args.vocabulary)
    hierarchy = hierarchy_from(args, profile)
    manifest = manifest_for(args.source)
    revisions = {d["id"]: d.get("revision") for d in manifest["documents"]}
    genre_of = {r["id"]: r.get("genre") for r in load_rows(map_dir) if r.get("genre")}
    relevance = answer_module.score_statements(args.question, statements, vocabulary=vocabulary)
    result = answer_module.assemble(
        args.question, args.zone, statements, hierarchy,
        follow_up_rules=answer_module.load_follow_up_rules(profile),
        current_revisions=revisions, vocabulary=vocabulary, relevance=relevance,
        genre_of=genre_of, genre_preferences=doc_genre.load_preferences(profile))
    print(answer_module.render(result))
    if result.gap:
        gap_append(map_dir, answer_module.gap_entry(result, now_iso()))
        ledger_append(map_dir, "answer (refused)", "—", args.question,
                      f"{len(statements)} statements considered", f"gap recorded: {result.gap}")
    else:
        ledger_append(map_dir, "answer", f"{len(result.served)} statements served",
                      args.question, f"{len(statements)} statements considered",
                      "served with provenance and tier")
    return 0


# ---------------------------------------------------------------- status


def cmd_status(args) -> int:
    map_dir = map_dir_for(args)
    rows = load_rows(map_dir)
    if not rows:
        raise SystemExit(f"no map at {map_dir} — run build first")
    # The rows snapshot promotion state as of the last build; promotions since
    # then live in the state file. Status must answer for now, not for then.
    state = load_state(map_dir)
    for row in rows:
        doc_state = state["documents"].get(row["id"], {})
        row["promoted_chunks"] = len(doc_state.get("promoted", {}))
        row["uses"] = doc_state.get("uses", row.get("uses", 0))
    ok = [r for r in rows if r["status"] != "extraction_failed"]
    total_chunks = sum(r["chunks"] for r in ok)
    promoted_chunks = sum(r["promoted_chunks"] for r in ok)
    total_chars = sum(r["text_chars"] for r in ok)
    promoted_docs = [r for r in ok if r["promoted_chunks"]]
    statements_path = map_dir / STATEMENTS_FILE
    statement_rows = ([json.loads(line) for line in
                       statements_path.read_text(encoding="utf-8").splitlines() if line.strip()]
                      if statements_path.is_file() else [])
    print(json.dumps({
        "map_dir": str(map_dir),
        "documents": len(rows),
        "extraction_failed": len(rows) - len(ok),
        "chunks": total_chunks,
        "corpus_text_chars": total_chars,
        "promoted": {
            "documents": len(promoted_docs),
            "chunks": promoted_chunks,
            "share_of_corpus": f"{(100 * promoted_chunks / total_chunks):.1f}%" if total_chunks else "0%",
        },
        "statements": {
            "total": len(statement_rows),
            "servable": sum(1 for s in statement_rows if s.get("servable")),
            "needs_review": sum(1 for s in statement_rows if s.get("status") == "needs_review"),
            "rejected": sum(1 for s in statement_rows if s.get("status") == "rejected"),
        },
        "counterfactual": {
            "wholesale_deterministic_scan_chars": total_chars,
            "demand_driven_deterministic_scan_chars_estimate": sum(
                r["text_chars"] * (r["promoted_chunks"] / r["chunks"])
                for r in promoted_docs if r["chunks"]),
            "corpus_map_model_calls": 0,
            "corpus_map_model_input_chars": 0,
        },
    }, ensure_ascii=False, indent=2))
    return 0


# ---------------------------------------------------------------- entry


def parser() -> argparse.ArgumentParser:
    top = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = top.add_subparsers(dest="command", required=True)

    def common(p):
        p.add_argument("--source", required=True, help="ingest source id")
        p.add_argument("--map-dir", help="map directory (default memory/corpora/<source>)")

    build = sub.add_parser("build", help="(re)build the map from the intake manifest — deterministic")
    common(build)
    build.set_defaults(func=cmd_build)

    card = sub.add_parser("card", help="materialize one document's card with its verbatim abstract")
    common(card)
    card.add_argument("document")
    card.set_defaults(func=cmd_card)

    touch = sub.add_parser("touch", help="record that a question used these documents")
    common(touch)
    touch.add_argument("documents", nargs="+")
    touch.add_argument("--question", default="")
    touch.set_defaults(func=cmd_touch)

    promote = sub.add_parser("promote", help="extract advice candidates from one document, on demand")
    common(promote)
    promote.add_argument("document")
    promote.add_argument("--reason", required=True, help="the question or need that triggered this")
    promote.add_argument("--chunks", default="all", help="comma-separated chunk numbers, or 'all'")
    promote.set_defaults(func=cmd_promote)

    validate = sub.add_parser("validate", help="check filled statements against their source sentences")
    common(validate)
    validate.add_argument("document")
    validate.set_defaults(func=cmd_validate)

    retrieve = sub.add_parser("retrieve", help="BM25 over the corpus, zone-bounded")
    common(retrieve)
    retrieve.add_argument("--question", required=True)
    retrieve.add_argument("--zone", required=True)
    retrieve.add_argument("--limit", type=int, default=5)
    retrieve.add_argument("--vocabulary", nargs="*", default=[])
    retrieve.add_argument("--fixture", help="fixture JSON supplying zone_hierarchy")
    retrieve.set_defaults(func=cmd_retrieve)

    ans = sub.add_parser("answer", help="assemble an answer from validated statements")
    common(ans)
    ans.add_argument("--question", required=True)
    ans.add_argument("--zone", required=True)
    ans.add_argument("--vocabulary", nargs="*", default=[])
    ans.add_argument("--fixture", help="fixture JSON supplying zone_hierarchy")
    ans.set_defaults(func=cmd_answer)

    status = sub.add_parser("status", help="map, promotion and spend summary")
    common(status)
    status.set_defaults(func=cmd_status)
    return top


def main() -> int:
    args = parser().parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
