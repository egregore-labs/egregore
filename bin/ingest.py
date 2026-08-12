#!/usr/bin/env python3
"""Deterministic, org-scoped intake substrate for Egregore.

The agent skill owns interpretation and curation.  This program owns the parts
that must not depend on model judgment: stable identities, provenance,
deterministic chunks, boundary metadata, manifests, and retrieval filtering.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import mimetypes
import os
import re
import shutil
import subprocess
import sys
import zipfile
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree

sys.path.append(str(Path(__file__).resolve().parent))
import catalogue as catalogue_module  # noqa: E402
import doc_segment  # noqa: E402  (same-directory module, path set above)
import pdf_extract  # noqa: E402
import source_profile  # noqa: E402
import text_repair  # noqa: E402


ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / "egregore.json"
TEXT_EXTS = {".txt", ".md", ".markdown", ".rst", ".csv", ".tsv", ".json", ".jsonl", ".yaml", ".yml", ".xml"}
HTML_EXTS = {".html", ".htm"}
SELECTION_SCHEMA = "egregore-ingest-selection/v1"
EXTRACTION_SCHEMA = "egregore-ingest-extraction/v1"
CORPUS_SCHEMA = "egregore-ingest-corpus/v1"


def load_config() -> dict:
    with CONFIG.open(encoding="utf-8") as handle:
        return json.load(handle)


def metadata_root() -> Path:
    override = os.environ.get("EGREGORE_INGEST_META_ROOT")
    return Path(override).resolve() if override else (ROOT / "memory" / "ingest").resolve()


def data_root() -> Path:
    override = os.environ.get("EGREGORE_INGEST_ROOT")
    return Path(override).resolve() if override else (ROOT / ".egregore" / "ingest").resolve()


def staging_root() -> Path:
    override = os.environ.get("EGREGORE_INGEST_STAGING_ROOT")
    return Path(override).resolve() if override else (ROOT / ".egregore" / "ingest-staging").resolve()


def producer_session_id() -> str:
    trusted = os.environ.get("EGREGORE_SESSION_ID", "").strip()
    if trusted:
        return trusted
    session_file = ROOT / ".egregore-session-id"
    if session_file.is_file():
        return session_file.read_text(encoding="utf-8").strip()
    return ""


def slug(value: str) -> str:
    result = re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")
    if not result:
        raise ValueError("value must contain at least one letter or number")
    return result


def digest(value: bytes | str, length: int = 24) -> str:
    raw = value.encode("utf-8") if isinstance(value, str) else value
    return hashlib.sha256(raw).hexdigest()[:length]


def hash_file(path: Path) -> tuple[str, int]:
    hasher = hashlib.sha256()
    size = 0
    with path.open("rb") as handle:
        while block := handle.read(1024 * 1024):
            hasher.update(block)
            size += len(block)
    return hasher.hexdigest(), size


def parse_boundaries(items: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    for item in items:
        if "=" not in item:
            raise ValueError(f"boundary must be key=value: {item}")
        key, value = item.split("=", 1)
        key = slug(key)
        value = value.strip()
        if not value:
            raise ValueError(f"boundary value is empty: {item}")
        result[key] = value
    return dict(sorted(result.items()))


def read_text(path: Path) -> tuple[str | None, str | None, str | None, dict | None]:
    """Extract text. Returns (text, error, extractor, detail).

    `detail` carries per-page extraction facts for formats that have pages, so the
    manifest records which pages needed OCR and which remain sparse or blank.
    """
    ext = path.suffix.lower()
    try:
        if ext in TEXT_EXTS:
            return path.read_text(encoding="utf-8", errors="replace"), None, "builtin-text", None
        if ext in HTML_EXTS:
            raw = path.read_text(encoding="utf-8", errors="replace")
            raw = re.sub(r"(?is)<(script|style).*?>.*?</\1>", " ", raw)
            return html.unescape(re.sub(r"(?s)<[^>]+>", " ", raw)), None, "builtin-html", None
        if ext == ".docx":
            with zipfile.ZipFile(path) as archive:
                raw = archive.read("word/document.xml")
            root = ElementTree.fromstring(raw)
            text = "\n".join(t.text or "" for t in root.iter() if t.tag.endswith("}t"))
            return text, None, "builtin-docx", None
        if ext == ".pdf":
            result = pdf_extract.extract(path)
            return result.text, result.error, result.extractor, (result.report or None)
    except (OSError, ValueError, zipfile.BadZipFile, ElementTree.ParseError) as exc:
        return None, str(exc), None, None
    return None, f"unsupported extension {ext or '(none)'}", None, None


def chunks(text: str, limit: int = 7000) -> list[str]:
    paragraphs = [p.strip() for p in re.split(r"\n\s*\n", text) if p.strip()]
    if not paragraphs and text.strip():
        paragraphs = [text.strip()]
    result: list[str] = []
    current = ""
    for paragraph in paragraphs:
        pieces = [paragraph[i : i + limit] for i in range(0, len(paragraph), limit)] or [""]
        for piece in pieces:
            candidate = f"{current}\n\n{piece}".strip() if current else piece
            if current and len(candidate) > limit:
                result.append(current)
                current = piece
            else:
                current = candidate
    if current:
        result.append(current)
    return result


# Catalogue columns that carry provenance, by what they mean rather than by
# what any one organisation calls them. A profile's `map` already renames its
# own columns to these, so no further configuration is needed.
CATALOGUE_URL_FIELDS = ("url", "source_url", "link")
CATALOGUE_INSTITUTION_FIELDS = ("institution", "publisher", "source_type", "source")


def catalogue_provenance(catalogued: dict) -> tuple:
    """The URL and institution a catalogue records for a document.

    The resolver has always accepted these and ranks both above a filename,
    because a filename is what someone happened to save a file as. Ingest
    passed only the filename, so the stronger evidence sitting in the row it
    had just read went unused.

    Measured on a real archive that was not a marginal loss. Seventy articles
    downloaded from two journal indexes were saved under bare article titles,
    carrying no publisher token to match. The profile had rules for both
    indexes and the catalogue named the index for every one of them, and still
    nothing matched — the one input that could have identified them was the one
    input never passed.
    """
    if not catalogued:
        return "", ""
    url = next((str(catalogued[f]) for f in CATALOGUE_URL_FIELDS if catalogued.get(f)), "")
    institution = next(
        (str(catalogued[f]) for f in CATALOGUE_INSTITUTION_FIELDS if catalogued.get(f)), "")
    return url, institution


def find_publisher_profile() -> Path | None:
    """Where this instance's publisher profile is, if it has one.

    The profile is what assigns a zone and a trust tier to each document, and
    zone is a hard retrieval boundary. Ingesting without it produces a corpus
    where every document is unplaced, so every later question is refused — a
    failure that looks like an empty archive rather than a missing setting.

    So this looks in the places a profile actually lives rather than in one
    fixed path. An instance keeps its ontology under memory/knowledge/tools/,
    not beside its intake metadata, and requiring an environment variable to
    bridge that gap means the common case is the broken one.
    """
    override = os.environ.get("EGREGORE_PUBLISHER_PROFILE")
    if override:
        path = Path(override)
        return path if path.is_file() else None

    candidates = [metadata_root() / "publisher-profile.json"]
    memory = Path("memory")
    if memory.is_dir():
        candidates.extend(sorted(memory.glob("knowledge/tools/*/publisher-profile.json")))
        candidates.append(memory / "publisher-profile.json")
    for path in candidates:
        if path.is_file():
            return path
    return None


def publisher_profile() -> dict | None:
    """Load the instance's publisher profile, if one is configured.

    Resolution is recorded as evidence only. It never overrides a boundary the
    operator set: deriving a region is an inference, and an inference must not
    silently replace a stated fact.
    """
    path = find_publisher_profile()
    if path is None:
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def source_dir(source_id: str) -> Path:
    return metadata_root() / "sources" / slug(source_id)


def load_manifest(directory: Path) -> dict:
    path = directory / "manifest.json"
    if not path.exists():
        return {"documents": []}
    return json.loads(path.read_text(encoding="utf-8"))


def atomic_json(path: Path, value: object) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def atomic_text(path: Path, value: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(value, encoding="utf-8")
    temporary.replace(path)


def candidate_files(path: Path) -> tuple[Path, list[Path]]:
    resolved = path.resolve()
    if resolved.is_file():
        return resolved.parent, [resolved]
    if not resolved.is_dir():
        raise ValueError(f"source path does not exist: {path}")
    files = [
        p
        for p in resolved.rglob("*")
        if p.is_file()
        and not p.is_symlink()
        and not any(part.startswith(".") for part in p.relative_to(resolved).parts)
    ]
    return resolved, sorted(files, key=lambda p: p.as_posix())


def add_path(args: argparse.Namespace) -> dict:
    config = load_config()
    org = slug(config.get("slug") or "egregore")
    source_id = slug(args.source)
    boundaries = parse_boundaries(args.boundary)
    input_path = Path(args.path).resolve()
    base, files = candidate_files(input_path)
    directory = source_dir(source_id)
    docs_dir = data_root() / "sources" / source_id / "documents"
    docs_dir.mkdir(parents=True, exist_ok=True)
    existing_manifest = load_manifest(directory)
    previous = {d["id"]: d for d in existing_manifest.get("documents", [])}
    now = datetime.now(timezone.utc).isoformat()
    profile_path = find_publisher_profile()
    profile = publisher_profile()
    if profile is None:
        # Said once, plainly, because the alternative is a corpus that ingests
        # cleanly and then refuses every question with no indication why.
        print("ingest: no publisher-profile.json found — documents will carry no zone "
              "or trust tier, and a zoneless document can never be served. Put one "
              "under memory/knowledge/tools/<ontology>/ or set "
              "EGREGORE_PUBLISHER_PROFILE.", file=sys.stderr)
    catalogue = catalogue_module.load(
        profile or {}, base=profile_path.parent if profile_path else None
    )
    repair_map = text_repair.load_mapping(profile or {})
    ingested = unchanged = metadata_updated = skipped = pruned = 0
    # How often progress is written. The manifest used to be saved once, after
    # every file, so an interrupted run lost everything it had extracted — on a
    # 921-document folder that was two and a half hours of OCR with nothing to
    # show. Documents already on disk were re-extracted because nothing recorded
    # them. Writing periodically means an interruption costs at most this many.
    checkpoint_every = int(os.environ.get("EGREGORE_INGEST_CHECKPOINT", "25") or 0)
    since_checkpoint = 0
    # Read before the loop rather than after it, so a checkpoint writes the real
    # deletion records instead of dropping them. Pruning still happens later; a
    # mid-run save simply carries forward what the previous run recorded.
    tombstones = existing_manifest.get("tombstones", [])
    errors: list[dict] = []
    seen_paths: set[str] = set()

    for path in files:
        relative = path.relative_to(base).as_posix() if path != base else path.name
        seen_paths.add(relative)
        doc_id = digest(f"{org}\0{source_id}\0{relative}")
        content_hash, size_bytes = hash_file(path)
        existing = previous.get(doc_id)
        registered = getattr(args, "extractions", {}).get(relative)
        if (
            existing
            and existing.get("content_hash") == content_hash
            and existing.get("boundaries", {}) == boundaries
            and not registered
            and existing.get("status") == "unverified"
        ):
            unchanged += 1
            continue
        if registered:
            text, error = registered["text"], None
            extraction = {"kind": "runtime", "extractor": registered["extractor"]}
        else:
            text, error, extractor, detail = read_text(path)
            extraction = {"kind": "local", "extractor": extractor} if extractor else None
            if extraction and detail:
                extraction["pages"] = detail
        # Fix characters the document's own font encoding got wrong, before
        # anything downstream indexes or quotes them.
        repaired = None
        if text and repair_map:
            outcome = text_repair.repair(text, repair_map)
            if outcome.replaced:
                text = outcome.text
                repaired = outcome.as_report()

        if error or text is None or not text.strip():
            skipped += 1
            errors.append({"path": relative, "error": error or "empty extracted text"})
            if existing:
                normalized = data_root() / existing["file_path"]
                normalized.unlink(missing_ok=True)
                previous[doc_id] = {
                    **existing,
                    "content_hash": content_hash,
                    "revision": content_hash[:16],
                    "mime": mimetypes.guess_type(path.name)[0] or "application/octet-stream",
                    "bytes": size_bytes,
                    "chunks": [],
                    "extraction": None,
                    "boundaries": boundaries,
                    "status": "extraction_failed",
                    "ingested_at": now,
                }
            continue
        normalized_hash = hashlib.sha256(text.encode()).hexdigest()
        if (
            existing
            and existing.get("content_hash") == content_hash
            and existing.get("normalized_content_hash") == normalized_hash
            and existing.get("boundaries", {}) == boundaries
            and existing.get("status") == "unverified"
        ):
            unchanged += 1
            continue
        # Segment before chunking so no passage straddles two works. A document
        # holding a single work yields one segment, and chunking is unchanged.
        if repaired and extraction:
            extraction["repair"] = repaired

        segments = doc_segment.segment(text)
        document_chunks: list[tuple[str, doc_segment.Segment]] = []
        for seg in segments:
            for piece in chunks(seg.text(text)):
                document_chunks.append((piece, seg))

        chunk_rows = []
        body = []
        for index, (content, seg) in enumerate(document_chunks, 1):
            chunk_id = f"{doc_id}-c{index:04d}-{digest(content, 8)}"
            row = {"id": chunk_id, "index": index, "sha256": hashlib.sha256(content.encode()).hexdigest()}
            if seg.kind != "article" or seg.label:
                row["segment"] = {"kind": seg.kind, **({"label": seg.label} if seg.label else {})}
            chunk_rows.append(row)
            body.append(f"## Chunk {index:04d}\n\n<!-- ingest-chunk: {chunk_id} -->\n\n{content}")

        structure = {
            "segments": len([s for s in segments if s.kind == "article"]),
            "summary": doc_segment.summarise(segments),
        }
        derived_year = doc_segment.publication_year(segments)
        if derived_year:
            structure["publication_year"] = derived_year
            structure["year_source"] = "running_head"

        # Fill in boundaries the operator left blank, when the instance supplies a
        # profile that can work them out from where the document came from. People
        # dumping a folder of documents will not type these in, and a boundary that
        # is absent filters nothing. A derived value is marked as derived: anything
        # downstream can tell it apart from one a person stated, and weigh it by the
        # confidence recorded alongside. An operator's value is never overwritten.
        # Evidence strongest first: what the operator stated, then what the
        # organisation's own catalogue records, then what can be inferred from
        # the document's origin. A weaker source never overwrites a stronger one.
        provenance = None
        doc_boundaries = dict(boundaries)
        catalogued = catalogue_module.lookup(catalogue, relative)

        if catalogued:
            provenance = {"from_catalogue": {k: v for k, v in catalogued.items()}}
            for field_name, value in catalogued.items():
                if field_name in ("zone", "crop", "topic", "customer", "jurisdiction", "project"):
                    if field_name not in doc_boundaries:
                        doc_boundaries[field_name] = value
                        provenance["applied_boundary"] = field_name
            if catalogued.get("year"):
                structure.setdefault("publication_year", catalogued["year"])
                structure["year_source"] = structure.get("year_source") or "catalogue"
            if catalogued.get("tier"):
                provenance["tier"] = catalogued["tier"]
            provenance["confidence"] = "high"

        if profile:
            catalogue_url, catalogue_institution = catalogue_provenance(catalogued)
            resolved = source_profile.resolve(
                profile, url=catalogue_url, institution=catalogue_institution,
                filename=relative)
            if resolved.publisher_class or resolved.notes:
                inferred = resolved.as_dict()
                # Keep the inference visible even when the catalogue answered,
                # so a disagreement between the two is inspectable.
                provenance = {**inferred, **(provenance or {})} if provenance else inferred
            key = source_profile.boundary_key(profile)
            if key and resolved.zone and key not in doc_boundaries:
                doc_boundaries[key] = resolved.zone
                provenance = {**(provenance or {}), "applied_boundary": key, "derived": True}
        out_path = docs_dir / f"{doc_id}.md"
        frontmatter = {
            "id": doc_id,
            "type": "ingest-document",
            "org": org,
            "source_id": source_id,
            "source_path": relative,
            "title": path.stem,
            "content_hash": content_hash,
            "normalized_content_hash": normalized_hash,
            "revision": content_hash[:16],
            "status": "unverified",
            "boundaries": doc_boundaries,
            "extraction": extraction,
            "structure": structure,
            "provenance": provenance,
            "ingested_at": now,
        }
        yaml_lines = ["---"] + [f"{key}: {json.dumps(value, ensure_ascii=False)}" for key, value in frontmatter.items()] + ["---", ""]
        atomic_text(out_path, "\n".join(yaml_lines) + f"# {path.stem}\n\n" + "\n\n".join(body) + "\n")
        previous[doc_id] = {
            "id": doc_id,
            "title": path.stem,
            "source_path": relative,
            "file_path": out_path.relative_to(data_root()).as_posix(),
            "content_hash": content_hash,
            "normalized_content_hash": normalized_hash,
            "revision": content_hash[:16],
            "mime": mimetypes.guess_type(path.name)[0] or "application/octet-stream",
            "bytes": size_bytes,
            "chunks": chunk_rows,
            "extraction": extraction,
            "structure": structure,
            "provenance": provenance,
            "boundaries": doc_boundaries,
            "status": "unverified",
            "ingested_at": now,
        }
        since_checkpoint += 1
        if checkpoint_every and since_checkpoint >= checkpoint_every:
            # A crash between the document write and this one costs re-extraction
            # of at most `checkpoint_every` files, never the whole run.
            write_manifest(directory, source_id, org, args, boundaries, base, now,
                           previous, tombstones, errors)
            since_checkpoint = 0
        if existing and existing.get("content_hash") == content_hash:
            metadata_updated += 1
        else:
            ingested += 1

    if args.prune:
        if not input_path.is_dir():
            raise ValueError("--prune requires a directory snapshot")
        for doc_id, document in list(previous.items()):
            if document["source_path"] in seen_paths:
                continue
            normalized = data_root() / document["file_path"]
            if normalized.is_file():
                normalized.unlink()
            tombstones.append({
                "id": doc_id,
                "source_path": document["source_path"],
                "content_hash": document["content_hash"],
                "deleted_at": now,
            })
            del previous[doc_id]
            pruned += 1
    # A path can disappear in one authoritative snapshot and return later.
    # Current documents always win over historical deletion records.
    tombstones = [row for row in tombstones if row["id"] not in previous]

    write_manifest(directory, source_id, org, args, boundaries, base, now,
                   previous, tombstones, errors)
    return {"org": org, "source": source_id, "ingested": ingested, "unchanged": unchanged, "metadata_updated": metadata_updated, "skipped": skipped, "pruned": pruned, "documents": len(previous), "metadata_root": str(directory), "data_root": str(docs_dir)}


def write_manifest(directory, source_id, org, args, boundaries, base, now,
                   previous, tombstones, errors) -> None:
    """Persist progress. Called periodically during a run and once at the end.

    One writer for both so a checkpoint and a completed run cannot record the
    corpus differently.
    """
    source_record = {
        "id": source_id,
        "org": org,
        "name": getattr(args, "name", None) or source_id,
        "kind": getattr(args, "kind", None),
        "boundaries": boundaries,
        "root_hint": base.name,
        "updated_at": now,
    }
    atomic_json(directory / "source.json", source_record)
    atomic_json(
        directory / "manifest.json",
        {
            "schema": CORPUS_SCHEMA,
            "producer_session": producer_session_id(),
            "source": source_record,
            "documents": sorted(previous.values(), key=lambda d: d["id"]),
            "tombstones": tombstones,
            "errors": errors,
        },
    )


def cmd_add(args: argparse.Namespace) -> int:
    print(json.dumps(add_path(args), indent=2))
    return 0


def rewrite_frontmatter(path: Path, updates: dict) -> bool:
    """Replace named frontmatter fields in place, leaving the text untouched.

    A document's placement lives in two files — the manifest record and this
    document's own frontmatter — and a reader may consult either. Updating one
    and not the other produces a corpus that disagrees with itself, which is
    worse than the stale value it replaced.

    Only the named lines are rewritten. The body is never reparsed, so nothing
    that survived extraction can be lost by a maintenance pass.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError:
        return False
    lines = text.split("\n")
    if not lines or lines[0].strip() != "---":
        return False
    try:
        close = next(i for i in range(1, len(lines)) if lines[i].strip() == "---")
    except StopIteration:
        return False
    remaining = dict(updates)
    for i in range(1, close):
        key = lines[i].split(":", 1)[0].strip()
        if key in remaining:
            lines[i] = f"{key}: {json.dumps(remaining.pop(key), ensure_ascii=False)}"
    # A field the original write omitted is appended rather than dropped, so a
    # document ingested before a field existed still gains it.
    for key, value in remaining.items():
        lines.insert(close, f"{key}: {json.dumps(value, ensure_ascii=False)}")
        close += 1
    atomic_text(path, "\n".join(lines))
    return True


def reresolve_source(args: argparse.Namespace) -> dict:
    """Re-derive placement for documents already ingested.

    Placement is written once, at ingest, and never revisited. That is right
    for content — the text of a document does not change because a rule did —
    but wrong for the rules themselves. Correcting a publisher profile changed
    nothing about the corpus it governs: `add` skips on the content hash and
    returns before it ever consults the profile, so it reported every document
    unchanged while the corrected rule went unapplied. The only way to apply a
    fix was to re-extract thousands of documents, redoing OCR to recompute a
    field that depends on nothing but the filename.

    So this re-runs the resolver alone. No file is reopened, no text is
    re-extracted; the stored path is all the resolver ever needed.

    Evidence precedence is the same as at ingest, and is the reason this is
    safe to run at any time: a value the operator stated, or one the
    organisation's own catalogue recorded, is never overwritten by an
    inference. Only a placement this resolver derived — or the absence of one —
    is open to revision.
    """
    config = load_config()
    source_id = slug(args.source)
    directory = source_dir(source_id)
    manifest = load_manifest(directory)
    records = manifest.get("documents") or []
    if not records:
        return {"source": source_id, "error": "no manifest, or no documents in it",
                "metadata_root": str(directory)}

    profile = publisher_profile()
    if profile is None:
        return {"source": source_id,
                "error": "no publisher-profile.json found — nothing to resolve against"}
    key = source_profile.boundary_key(profile)
    if not key:
        return {"source": source_id, "error": "profile declares no boundary key"}

    docs_dir = data_root() / "sources" / source_id / "documents"
    placed = rezoned = identified = unchanged = protected = missing = 0
    changes: list = []

    for record in records:
        relative = record.get("source_path")
        if not relative:
            unchanged += 1
            continue
        boundaries = dict(record.get("boundaries") or {})
        provenance = dict(record.get("provenance") or {})
        catalogued = provenance.get("from_catalogue") or {}

        # The same evidence the original ingest had, re-read from the record so
        # a document identified only by its catalogue row resolves here too.
        catalogue_url, catalogue_institution = catalogue_provenance(catalogued)
        resolved = source_profile.resolve(
            profile, url=catalogue_url, institution=catalogue_institution,
            filename=relative)

        # Placement and identification are decided separately. A document can
        # become identifiable — a journal index naming its publisher — without
        # that saying anything about which region it applies to, and reporting
        # only the placement would call that document unchanged when the thing
        # that decides how far to trust it has just been settled.
        current = boundaries.get(key)
        # Anything the operator stated or the catalogue recorded outranks an
        # inference and is left exactly as it is.
        derived_here = (provenance.get("derived") is True
                        and provenance.get("applied_boundary") == key)
        zone_open = not ((current and not derived_here) or catalogued.get(key))
        zone_changes = bool(zone_open and resolved.zone and resolved.zone != current)

        # A tier the catalogue stated is likewise not ours to revise.
        class_open = not catalogued.get("tier")
        class_changes = bool(
            class_open and resolved.publisher_class
            and (resolved.publisher_class != provenance.get("publisher_class")
                 or resolved.tier != provenance.get("tier")))

        if not zone_changes and not class_changes:
            if not zone_open and not class_open:
                protected += 1
            elif current and not zone_open:
                protected += 1
            else:
                unchanged += 1
            continue

        # The fresh resolution replaces the recorded inference whenever either
        # half moved. Refreshing only on a class change once left a re-zoned
        # document carrying the confidence and notes of the resolution it no
        # longer had — a record that reported an inferred national zone with
        # the confidence of a precise one.
        updated_provenance = dict(provenance)
        updated_provenance.update(resolved.as_dict())
        if class_changes:
            identified += 1
        if catalogued:
            updated_provenance["from_catalogue"] = catalogued
        if zone_changes:
            updated_provenance["applied_boundary"] = key
            updated_provenance["derived"] = True
            boundaries[key] = resolved.zone
            if current:
                rezoned += 1
            else:
                placed += 1

        changes.append({"id": record["id"], "source_path": relative,
                        "zone": {"from": current, "to": boundaries.get(key)},
                        "class": {"from": provenance.get("publisher_class"),
                                  "to": updated_provenance.get("publisher_class")},
                        "matched_by": resolved.matched_by})

        if args.dry_run:
            continue
        record["boundaries"] = boundaries
        record["provenance"] = updated_provenance
        file_path = record.get("file_path")
        target = (data_root() / file_path) if file_path else (docs_dir / f"{record['id']}.md")
        if not rewrite_frontmatter(target, {"boundaries": boundaries,
                                            "provenance": updated_provenance}):
            missing += 1

    if not args.dry_run and (placed or rezoned or identified):
        manifest["documents"] = sorted(records, key=lambda d: d["id"])
        atomic_json(directory / "manifest.json", manifest)

    return {
        "org": slug(config.get("slug") or "egregore"),
        "source": source_id,
        "dry_run": bool(args.dry_run),
        "documents": len(records),
        "placed": placed,
        "rezoned": rezoned,
        "identified": identified,
        "unchanged": unchanged,
        "protected": protected,
        "frontmatter_not_found": missing,
        "examples": changes[: max(0, args.examples)],
        "metadata_root": str(directory),
    }


def cmd_reresolve(args: argparse.Namespace) -> int:
    result = reresolve_source(args)
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 1 if result.get("error") else 0


def selection_relative_path(value: object) -> str:
    if not isinstance(value, str) or not value or "\x00" in value or "\\" in value:
        raise ValueError("selection contains an invalid relative path")
    candidate = Path(value)
    if candidate.is_absolute() or any(part in {"", ".", ".."} or part.startswith(".") for part in candidate.parts):
        raise ValueError(f"selection path must be visible and relative: {value}")
    return candidate.as_posix()


def validate_selection(path: Path) -> tuple[dict, Path]:
    manifest_path = path.resolve()
    staging_base = staging_root()
    if manifest_path.name != "selection.json" or manifest_path.parent.parent != staging_base:
        raise ValueError("selection manifest must be inside the local ingest staging root")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != SELECTION_SCHEMA:
        raise ValueError("unsupported selection manifest schema")
    if "org" in manifest:
        raise ValueError("selection manifest cannot supply an org")
    if manifest.get("session_id") != manifest_path.parent.name:
        raise ValueError("selection session id does not match its staging directory")
    if Path(str(manifest.get("staging_root", ""))).resolve() != manifest_path.parent:
        raise ValueError("selection staging root does not match the manifest location")

    source = manifest.get("source")
    if not isinstance(source, dict) or "org" in source:
        raise ValueError("selection source contract is invalid")
    source_id = slug(str(source.get("id", "")))
    if source_id != source.get("id"):
        raise ValueError("selection source id must already be a normalized slug")
    name = str(source.get("name", "")).strip()
    if not name or len(name) > 200:
        raise ValueError("selection source name is invalid")
    if source.get("kind") != "files":
        raise ValueError("local selections must use source kind files")
    boundaries = source.get("boundaries", {})
    if not isinstance(boundaries, dict):
        raise ValueError("selection boundaries must be an object")
    normalized_boundaries = parse_boundaries([f"{key}={value}" for key, value in boundaries.items()])
    if normalized_boundaries != boundaries:
        raise ValueError("selection boundary keys must already be normalized slugs")

    files_root = manifest_path.parent / "files"
    items = manifest.get("items")
    if not isinstance(items, list) or not items:
        raise ValueError("selection must contain at least one item")
    declared: set[str] = set()
    for item in items:
        if not isinstance(item, dict):
            raise ValueError("selection item must be an object")
        relative = selection_relative_path(item.get("relative_path"))
        if relative in declared:
            raise ValueError(f"duplicate selection path: {relative}")
        declared.add(relative)
        expected = (files_root / relative).resolve()
        if Path(str(item.get("local_path", ""))).resolve() != expected or files_root.resolve() not in expected.parents:
            raise ValueError(f"selection item escaped its staging root: {relative}")
        if not expected.is_file() or expected.is_symlink():
            raise ValueError(f"selection item is missing or unsafe: {relative}")
        content_hash, size_bytes = hash_file(expected)
        if item.get("sha256") != content_hash or item.get("bytes") != size_bytes:
            raise ValueError(f"selection item changed after confirmation: {relative}")

    actual = {
        candidate.relative_to(files_root).as_posix()
        for candidate in files_root.rglob("*")
        if candidate.is_file() and not candidate.is_symlink()
    }
    if actual != declared:
        raise ValueError("staging directory does not match the confirmed selection")
    return manifest, files_root


def registered_extractions(manifest: dict) -> dict[str, dict]:
    session_root = Path(manifest["staging_root"])
    directory = session_root / "extractions"
    if not directory.exists():
        return {}
    declared = {item["relative_path"]: item for item in manifest["items"]}
    result: dict[str, dict] = {}
    for sidecar_path in sorted(directory.glob("*.json")):
        sidecar = json.loads(sidecar_path.read_text(encoding="utf-8"))
        if sidecar.get("schema") != EXTRACTION_SCHEMA:
            raise ValueError(f"unsupported extraction sidecar: {sidecar_path.name}")
        relative = selection_relative_path(sidecar.get("relative_path"))
        item = declared.get(relative)
        if not item:
            raise ValueError(f"extraction does not belong to this selection: {relative}")
        if sidecar_path.name != f"{digest(relative)}.json":
            raise ValueError(f"extraction sidecar has an invalid name: {relative}")
        if sidecar.get("source_sha256") != item["sha256"]:
            raise ValueError(f"extraction source hash does not match: {relative}")
        extractor = str(sidecar.get("extractor", "")).strip()
        text = sidecar.get("text")
        if not extractor or len(extractor) > 100 or not isinstance(text, str) or not text.strip():
            raise ValueError(f"extraction sidecar is incomplete: {relative}")
        result[relative] = {"extractor": extractor, "text": text}
    return result


def cmd_register_extraction(args: argparse.Namespace) -> int:
    manifest, _ = validate_selection(Path(args.manifest))
    relative = selection_relative_path(args.relative_path)
    item = next((row for row in manifest["items"] if row["relative_path"] == relative), None)
    if not item:
        raise ValueError(f"file is not part of this selection: {relative}")
    extractor = args.extractor.strip()
    if not extractor or len(extractor) > 100:
        raise ValueError("extractor name is invalid")
    text = sys.stdin.read()
    if not text.strip():
        raise ValueError("registered extraction is empty")
    directory = Path(manifest["staging_root"]) / "extractions"
    path = directory / f"{digest(relative)}.json"
    atomic_json(path, {
        "schema": EXTRACTION_SCHEMA,
        "relative_path": relative,
        "source_sha256": item["sha256"],
        "extractor": extractor,
        "text": text,
    })
    print(json.dumps({"registered": relative, "extractor": extractor, "sidecar": str(path)}))
    return 0


def cmd_add_selection(args: argparse.Namespace) -> int:
    manifest, files_root = validate_selection(Path(args.manifest))
    source = manifest["source"]
    add_args = argparse.Namespace(
        path=str(files_root),
        source=source["id"],
        name=source["name"],
        kind="files",
        boundary=[f"{key}={value}" for key, value in source.get("boundaries", {}).items()],
        prune=bool(source.get("authoritative_snapshot", False)),
        extractions=registered_extractions(manifest),
    )
    summary = add_path(add_args)
    cleaned = summary["skipped"] == 0
    if cleaned:
        shutil.rmtree(Path(manifest["staging_root"]), ignore_errors=True)
    summary["selection_files"] = len(manifest["items"])
    summary["staging_cleaned"] = cleaned
    if not cleaned:
        summary["selection_path"] = str(Path(args.manifest).resolve())
    print(json.dumps(summary, indent=2))
    return 0


def all_sources() -> list[tuple[dict, dict]]:
    base = metadata_root() / "sources"
    if not base.exists():
        return []
    result = []
    for manifest_path in sorted(base.glob("*/manifest.json")):
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        result.append((manifest.get("source", {}), manifest))
    return result


def boundaries_match(actual: dict, required: dict) -> bool:
    return all(str(actual.get(key, "")) == str(value) for key, value in required.items())


def cmd_filter_results(args: argparse.Namespace) -> int:
    required = parse_boundaries(args.boundary)
    allowed: set[str] = set()
    for source, manifest in all_sources():
        if args.source and source.get("id") != slug(args.source):
            continue
        if not boundaries_match(source.get("boundaries", {}), required):
            continue
        allowed.update(d["file_path"] for d in manifest.get("documents", []) if d.get("status") != "extraction_failed")
    results = json.load(sys.stdin)
    filtered = []
    for item in results if isinstance(results, list) else []:
        file_name = re.sub(r"^qmd://[^/]+/", "", item.get("file", ""))
        if file_name in allowed:
            filtered.append(item)
        if len(filtered) >= args.limit:
            break
    print(json.dumps(filtered, ensure_ascii=False))
    return 0


def cmd_status(_: argparse.Namespace) -> int:
    sources = all_sources()
    documents = sum(len(m.get("documents", [])) for _, m in sources)
    chunks_count = sum(len(d.get("chunks", [])) for _, m in sources for d in m.get("documents", []))
    errors = sum(len(m.get("errors", [])) for _, m in sources)
    cached = sum(1 for _, m in sources for d in m.get("documents", []) if (data_root() / d["file_path"]).is_file())
    state_dir = data_root() / ".state"
    pending = []
    if state_dir.exists():
        pending = [json.loads(path.read_text(encoding="utf-8")) for path in sorted(state_dir.glob("*.json"))]
    print(json.dumps({"org": slug(load_config().get("slug") or "egregore"), "metadata_root": str(metadata_root()), "data_root": str(data_root()), "staging_root": str(staging_root()), "sources": len(sources), "documents": documents, "cached_documents": cached, "chunks": chunks_count, "errors": errors, "pending_recovery": pending}, indent=2))
    return 0


def cmd_journal(args: argparse.Namespace) -> int:
    path = data_root() / ".state" / f"{slug(args.source)}.json"
    if args.clear:
        path.unlink(missing_ok=True)
        return 0
    detail = json.loads(args.detail) if args.detail else {}
    atomic_json(path, {
        "source": slug(args.source),
        "phase": args.phase,
        "detail": detail,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    })
    return 0


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    sub = result.add_subparsers(dest="command", required=True)
    add = sub.add_parser("add")
    add.add_argument("path")
    add.add_argument("--source", required=True, help="stable connector/dataset id")
    add.add_argument("--name")
    add.add_argument("--kind", default="files")
    add.add_argument("--boundary", action="append", default=[])
    add.add_argument("--prune", action="store_true", help="tombstone files absent from this authoritative directory snapshot")
    add.set_defaults(func=cmd_add)
    reresolve = sub.add_parser(
        "reresolve",
        help="re-derive placement from the current profile, without re-reading any document")
    reresolve.add_argument("--source", required=True, help="source id to re-resolve")
    reresolve.add_argument("--dry-run", action="store_true",
                           help="report what would change and write nothing")
    reresolve.add_argument("--examples", type=int, default=10,
                           help="how many changed documents to list (default 10)")
    reresolve.set_defaults(func=cmd_reresolve)
    add_selection = sub.add_parser("add-selection")
    add_selection.add_argument("manifest")
    add_selection.set_defaults(func=cmd_add_selection)
    extraction = sub.add_parser("register-extraction")
    extraction.add_argument("manifest")
    extraction.add_argument("relative_path")
    extraction.add_argument("--extractor", required=True)
    extraction.set_defaults(func=cmd_register_extraction)
    filt = sub.add_parser("filter-results")
    filt.add_argument("--source")
    filt.add_argument("--boundary", action="append", default=[])
    filt.add_argument("--limit", type=int, default=8)
    filt.set_defaults(func=cmd_filter_results)
    status = sub.add_parser("status")
    status.set_defaults(func=cmd_status)
    journal = sub.add_parser("journal")
    journal.add_argument("--source", required=True)
    journal.add_argument("--phase", default="pending")
    journal.add_argument("--detail")
    journal.add_argument("--clear", action="store_true")
    journal.set_defaults(func=cmd_journal)
    return result


def main() -> int:
    try:
        args = parser().parse_args()
        return args.func(args)
    except (ValueError, OSError, json.JSONDecodeError) as exc:
        print(f"ingest: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
