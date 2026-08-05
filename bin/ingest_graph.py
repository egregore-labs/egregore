#!/usr/bin/env python3
"""Validate and plan replayable Egregore ingestion graph projections."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent.parent
CORPUS_SCHEMA = "egregore-ingest-corpus/v1"
CONNECTOR_SCHEMA = "egregore-connector-lifecycle/v1"
KNOWLEDGE_SCHEMA = "egregore-knowledge-projection/v1"
PLAN_SCHEMA = "egregore-ingest-graph-plan/v2"
SOURCE_KINDS = {"meeting", "interview", "google", "notion", "corpus", "document"}
SOURCE_RELATIONS = {"INVOLVES", "CONDUCTED_BY"}
ARTIFACT_RELATIONS = {"RELATES_TO", "SUPERSEDES"}
ARTIFACT_LABELS = {
    "decision": "Decision",
    "finding": "Finding",
    "pattern": "Pattern",
    "claim": "Claim",
    "research": "Research",
}
PERSON_MATCH = """(
  (
    $personKind = 'external'
    AND p.kind = 'external'
    AND $identityKey <> ''
    AND coalesce(p.ingestRef, '') = $identityKey
  )
  OR (
    $personKind = 'member'
    AND NOT coalesce(p.kind, '') IN ['external', 'identity_alias']
    AND coalesce(p.status, 'active') = 'active'
    AND p.ingestRef IS NULL
    AND (
      coalesce(p.personId, '') = $personRef
      OR coalesce(toString(p.githubId), '') = $personRef
      OR toLower(coalesce(p.name, '')) = toLower($personRef)
      OR toLower(coalesce(p.github, '')) = toLower($personRef)
      OR toLower(coalesce(p.handle, '')) = toLower($personRef)
      OR toLower($personRef) IN [alias IN coalesce(p.previousNames, []) | toLower(alias)]
      OR toLower($personRef) IN [alias IN coalesce(p.githubAliases, []) | toLower(alias)]
      OR toLower($personRef) IN [email IN coalesce(p.emails, []) | toLower(email)]
    )
  )
)"""


class ContractError(ValueError):
    """The manifest does not satisfy the projection contract."""


def required_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ContractError(f"{field} is required")
    return value.strip()


def string_list(value: Any, field: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item.strip() for item in value
    ):
        raise ContractError(f"{field} must be an array of non-empty strings")
    return [item.strip() for item in value]


def graph_properties(value: Any, field: str) -> dict[str, Any]:
    if value is None:
        return {}
    if not isinstance(value, dict):
        raise ContractError(f"{field} must be an object")
    result: dict[str, Any] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_]*", key):
            raise ContractError(f"{field} contains an unsafe property name")
        if isinstance(item, (str, int, float, bool)) or item is None:
            result[key] = item
        elif isinstance(item, list) and all(
            isinstance(entry, (str, int, float, bool)) or entry is None
            for entry in item
        ):
            result[key] = item
        else:
            raise ContractError(f"{field}.{key} is not a graph-safe scalar or array")
    return result


def manifest_path(path: Path) -> str:
    resolved = path.resolve()
    memory = (ROOT / "memory").resolve()
    try:
        return resolved.relative_to(memory).as_posix()
    except ValueError:
        return str(resolved)


def query(statement: str, parameters: dict[str, Any]) -> dict[str, Any]:
    return {"statement": statement, "parameters": parameters}


def corpus_manifest(value: dict[str, Any]) -> bool:
    return isinstance(value.get("source"), dict) and isinstance(
        value.get("documents"), list
    )


def validate_corpus(value: dict[str, Any]) -> None:
    schema = value.get("schema")
    if schema not in (None, CORPUS_SCHEMA):
        raise ContractError(f"unsupported corpus schema: {schema}")
    source = value.get("source")
    if not isinstance(source, dict):
        raise ContractError("source must be an object")
    required_string(source.get("id"), "source.id")
    required_string(source.get("updated_at"), "source.updated_at")
    graph_properties(source.get("boundaries", {}), "source.boundaries")
    documents = value.get("documents")
    if not isinstance(documents, list):
        raise ContractError("documents must be an array")
    for index, document in enumerate(documents):
        if not isinstance(document, dict):
            raise ContractError(f"documents[{index}] must be an object")
        required_string(document.get("id"), f"documents[{index}].id")
        required_string(
            document.get("source_path"), f"documents[{index}].source_path"
        )
        required_string(
            document.get("content_hash"), f"documents[{index}].content_hash"
        )
        chunks = document.get("chunks", [])
        if not isinstance(chunks, list):
            raise ContractError(f"documents[{index}].chunks must be an array")
        for chunk_index, chunk in enumerate(chunks):
            if not isinstance(chunk, dict):
                raise ContractError(
                    f"documents[{index}].chunks[{chunk_index}] must be an object"
                )
            required_string(
                chunk.get("id"),
                f"documents[{index}].chunks[{chunk_index}].id",
            )
            required_string(
                chunk.get("sha256"),
                f"documents[{index}].chunks[{chunk_index}].sha256",
            )
            if not isinstance(chunk.get("index"), int) or chunk["index"] < 0:
                raise ContractError(
                    f"documents[{index}].chunks[{chunk_index}].index must be a non-negative integer"
                )
    tombstones = value.get("tombstones", [])
    if not isinstance(tombstones, list):
        raise ContractError("tombstones must be an array")
    for index, tombstone in enumerate(tombstones):
        if not isinstance(tombstone, dict):
            raise ContractError(f"tombstones[{index}] must be an object")
        required_string(tombstone.get("id"), f"tombstones[{index}].id")


def corpus_plan(value: dict[str, Any], path: Path) -> dict[str, Any]:
    validate_corpus(value)
    source = value["source"]
    source_id = source["id"]
    projection_id = f"ingest-source:{source_id}"
    producer = str(value.get("producer_session") or "")
    file_path = manifest_path(path)
    queries: list[dict[str, Any]] = []
    queries.append(
        query(
            """MERGE (s:IngestSource:KnowledgeSource {id: $id})
SET s.name = $name,
    s.kind = $kind,
    s.sourceKind = $kind,
    s.revision = $updated,
    s.boundariesJson = $boundariesJson,
    s.rootHint = $rootHint,
    s.filePath = $filePath,
    s.updatedAt = datetime($updated),
    s.ingestManifestId = $manifestId,
    s.quarantineStatus = 'unverified'
WITH s
OPTIONAL MATCH (producer:Session {id: $producerSid})
FOREACH (_ IN CASE WHEN producer IS NULL OR $producerSid = '' THEN [] ELSE [1] END |
  MERGE (producer)-[r:INGESTED]->(s)
  SET r.provenance = $manifestId,
      r.method = 'ingest-corpus-v1',
      r.recordedAt = datetime()
)
RETURN s.id""",
            {
                "id": source_id,
                "name": source.get("name") or source_id,
                "kind": source.get("kind") or "files",
                "updated": source["updated_at"],
                "boundariesJson": json.dumps(
                    source.get("boundaries", {}), sort_keys=True
                ),
                "rootHint": source.get("root_hint") or "",
                "filePath": file_path,
                "manifestId": projection_id,
                "producerSid": producer,
            },
        )
    )
    for document in value.get("documents", []):
        chunk_ids = [chunk["id"] for chunk in document.get("chunks", [])]
        common = {
            "id": document["id"],
            "title": document.get("title") or document["source_path"],
            "sourcePath": document["source_path"],
            "contentHash": document["content_hash"],
            "normalizedContentHash": document.get("normalized_content_hash") or "",
            "revision": document.get("revision") or document["content_hash"],
            "normalizedPath": document.get("file_path") or "",
            "manifestPath": file_path,
            "status": document.get("status") or "unverified",
            "boundariesJson": json.dumps(
                document.get("boundaries", {}), sort_keys=True
            ),
            "mime": document.get("mime") or "",
            "bytes": int(document.get("bytes") or 0),
            "extractionJson": json.dumps(
                document.get("extraction") or {}, sort_keys=True
            ),
            "ingestedAt": document.get("ingested_at") or "",
            "chunkIds": chunk_ids,
            "sourceId": source_id,
            "manifestId": projection_id,
        }
        queries.append(
            query(
                """MERGE (d:IngestDocument:Document:KnowledgeSource {id: $id})
SET d.title = $title,
    d.sourcePath = $sourcePath,
    d.contentHash = $contentHash,
    d.normalizedContentHash = $normalizedContentHash,
    d.revision = $revision,
    d.filePath = $manifestPath,
    d.normalizedPath = $normalizedPath,
    d.status = $status,
    d.boundariesJson = $boundariesJson,
    d.mime = $mime,
    d.bytes = $bytes,
    d.extractionJson = $extractionJson,
    d.chunkIds = $chunkIds,
    d.ingestedAt = CASE WHEN $ingestedAt = '' THEN d.ingestedAt ELSE datetime($ingestedAt) END,
    d.ingestManifestId = $manifestId
WITH d
MATCH (s:IngestSource {id: $sourceId})
MERGE (d)-[r:FROM_SOURCE]->(s)
SET r.provenance = $manifestId,
    r.method = 'ingest-corpus-v1',
    r.recordedAt = datetime()
WITH d
OPTIONAL MATCH (old:IngestChunk)-[:FROM_DOCUMENT]->(d)
WHERE NOT (old.id IN $chunkIds)
SET old.status = 'superseded',
    old.supersededAt = datetime()
RETURN d.id""",
                common,
            )
        )
        if document.get("chunks"):
            queries.append(
                query(
                    """MATCH (d:IngestDocument {id: $id})
UNWIND $chunks AS chunk
MERGE (c:IngestChunk:EvidenceChunk {id: chunk.id})
SET c.ordinal = chunk.index,
    c.contentHash = chunk.sha256,
    c.documentId = $id,
    c.documentRevision = $revision,
    c.pointerPath = $normalizedPath,
    c.textPointer = $normalizedPath + '#ingest-chunk:' + chunk.id,
    c.status = 'current',
    c.ingestManifestId = $manifestId
MERGE (c)-[r:FROM_DOCUMENT]->(d)
SET r.provenance = $manifestId,
    r.method = 'ingest-corpus-v1',
    r.recordedAt = datetime()
RETURN count(c)""",
                    {
                        **common,
                        "chunks": document["chunks"],
                    },
                )
            )
    for tombstone in value.get("tombstones", []):
        queries.append(
            query(
                """MATCH (d:IngestDocument {id: $id})
SET d.status = 'deleted',
    d.deletedAt = CASE WHEN $deleted = '' THEN datetime() ELSE datetime($deleted) END,
    d.ingestManifestId = $manifestId
WITH d
OPTIONAL MATCH (c:IngestChunk)-[:FROM_DOCUMENT]->(d)
SET c.status = 'deleted'
RETURN d.id""",
                {
                    "id": required_string(tombstone.get("id"), "tombstone.id"),
                    "deleted": tombstone.get("deleted_at") or "",
                    "manifestId": projection_id,
                },
            )
        )
    return {
        "schema": PLAN_SCHEMA,
        "schema_family": "corpus-intake",
        "manifest_id": projection_id,
        "source": {"kind": "corpus", "id": source_id},
        "query_count": len(queries),
        "queries": queries,
    }


def validate_person(person: Any, field: str) -> dict[str, Any]:
    if not isinstance(person, dict):
        raise ContractError(f"{field} must be an object")
    ref = required_string(person.get("ref"), f"{field}.ref")
    kind = str(person.get("kind") or "member")
    if kind not in {"member", "external"}:
        raise ContractError(f"{field}.kind must be member or external")
    relation = str(person.get("relation") or "INVOLVES")
    if relation not in SOURCE_RELATIONS:
        raise ContractError(f"{field}.relation is not supported")
    name = str(person.get("name") or "").strip()
    identity_key = str(person.get("identity_key") or "").strip()
    if kind == "external" and (not name or not identity_key):
        raise ContractError(
            f"{field} external people require name and identity_key"
        )
    return {
        "ref": ref,
        "kind": kind,
        "relation": relation,
        "name": name,
        "identity_key": identity_key,
        "properties": graph_properties(person.get("properties", {}), f"{field}.properties"),
    }


def validate_knowledge(value: dict[str, Any]) -> dict[str, Any]:
    legacy = value.get("schema_version") == 1
    if value.get("schema") != KNOWLEDGE_SCHEMA and not legacy:
        raise ContractError(f"schema must be {KNOWLEDGE_SCHEMA}")
    required_string(value.get("manifest_id"), "manifest_id")
    required_string(value.get("producer_session"), "producer_session")
    pipeline = value.get("pipeline")
    if not isinstance(pipeline, dict):
        raise ContractError("pipeline must be an object")
    required_string(pipeline.get("name"), "pipeline.name")
    if not isinstance(pipeline.get("version"), int):
        raise ContractError("pipeline.version must be an integer")
    source = value.get("source")
    if not isinstance(source, dict):
        raise ContractError("source must be an object")
    kind = required_string(source.get("kind"), "source.kind")
    if kind not in SOURCE_KINDS:
        raise ContractError(f"source.kind must be one of {sorted(SOURCE_KINDS)}")
    required_string(source.get("id"), "source.id")
    required_string(source.get("title"), "source.title")
    required_string(source.get("file_path"), "source.file_path")
    date = str(source.get("date") or "")
    if date and not re.fullmatch(r"\d{4}-\d{2}-\d{2}", date):
        raise ContractError("source.date must be YYYY-MM-DD")
    if kind in {"meeting", "interview"} and not date:
        raise ContractError(f"source.date is required for {kind}")
    people = [
        validate_person(person, f"source.people[{index}]")
        for index, person in enumerate(source.get("people", []))
    ]
    refs = [person["ref"] for person in people]
    if len(refs) != len(set(refs)):
        raise ContractError("source.people refs must be unique")
    source["people"] = people
    graph_properties(source.get("properties", {}), "source.properties")
    string_list(source.get("quest_ids", []), "source.quest_ids")
    artifacts = value.get("artifacts")
    if not isinstance(artifacts, list):
        raise ContractError("artifacts must be an array")
    for index, artifact in enumerate(artifacts):
        field = f"artifacts[{index}]"
        if not isinstance(artifact, dict):
            raise ContractError(f"{field} must be an object")
        required_string(artifact.get("id"), f"{field}.id")
        required_string(artifact.get("title"), f"{field}.title")
        artifact_type = required_string(artifact.get("type"), f"{field}.type").lower()
        if not re.fullmatch(r"[a-z][a-z0-9-]{0,49}", artifact_type):
            raise ContractError(f"{field}.type is invalid")
        required_string(artifact.get("file_path"), f"{field}.file_path")
        required_string(artifact.get("summary"), f"{field}.summary")
        string_list(artifact.get("topics", []), f"{field}.topics")
        string_list(artifact.get("quest_ids", []), f"{field}.quest_ids")
        string_list(artifact.get("mentions", []), f"{field}.mentions")
        chunks = string_list(
            artifact.get("source_chunks", []), f"{field}.source_chunks"
        )
        if kind in {"corpus", "document"} and not chunks:
            raise ContractError(
                f"{field}.source_chunks is required for corpus/document promotion"
            )
        confidence = artifact.get("confidence", 0)
        if not isinstance(confidence, (int, float)) or not 0 <= confidence <= 1:
            raise ContractError(f"{field}.confidence must be between 0 and 1")
        graph_properties(artifact.get("properties", {}), f"{field}.properties")
        author = str(artifact.get("author") or "").strip()
        if author and author not in refs:
            raise ContractError(f"{field}.author must reference source.people")
        unknown_mentions = set(artifact.get("mentions", [])) - set(refs)
        if unknown_mentions:
            raise ContractError(
                f"{field}.mentions contains unknown people: {sorted(unknown_mentions)}"
            )
    relations = value.get("relations", [])
    if not isinstance(relations, list):
        raise ContractError("relations must be an array")
    for index, relation in enumerate(relations):
        field = f"relations[{index}]"
        if not isinstance(relation, dict):
            raise ContractError(f"{field} must be an object")
        required_string(relation.get("from"), f"{field}.from")
        required_string(relation.get("to"), f"{field}.to")
        if relation.get("type") not in ARTIFACT_RELATIONS:
            raise ContractError(f"{field}.type is not supported")
    return value


def source_shape(kind: str) -> tuple[str, str]:
    if kind == "meeting":
        return "Meeting:KnowledgeSource", "FROM_MEETING"
    if kind == "interview":
        return "Interview:KnowledgeSource", "FROM_INTERVIEW"
    if kind == "google":
        return "Artifact:KnowledgeSource", "DERIVED_FROM"
    if kind == "notion":
        return "Artifact:KnowledgeSource", "DERIVED_FROM"
    if kind == "corpus":
        return "IngestSource:KnowledgeSource", "DERIVED_FROM"
    return "IngestDocument:Document:KnowledgeSource", "DERIVED_FROM"


def person_parameters(
    ref: str, people: dict[str, dict[str, Any]]
) -> dict[str, str]:
    record = people.get(ref, {})
    return {
        "personRef": ref,
        "personKind": str(record.get("kind") or "member"),
        "identityKey": str(record.get("identity_key") or ""),
    }


def knowledge_plan(value: dict[str, Any], path: Path) -> dict[str, Any]:
    value = validate_knowledge(value)
    manifest_id = value["manifest_id"]
    producer = value["producer_session"]
    pipeline = value["pipeline"]
    source = value["source"]
    kind = source["kind"]
    source_labels, source_edge = source_shape(kind)
    method = f"{pipeline['name']}-v{pipeline['version']}"
    people = {person["ref"]: person for person in source.get("people", [])}
    source_params = {
        "id": source["id"],
        "title": source["title"],
        "kind": kind,
        "date": source.get("date") or "",
        "filePath": source["file_path"],
        "externalRef": source.get("external_ref") or "",
        "contentHash": source.get("content_hash") or "",
        "properties": graph_properties(
            source.get("properties", {}), "source.properties"
        ),
        "manifestId": manifest_id,
        "producerSid": producer,
        "method": method,
    }
    queries: list[dict[str, Any]] = [
        query(
            f"""MERGE (src:{source_labels} {{id: $id}})
SET src.title = $title,
    src.name = coalesce(src.name, $title),
    src.sourceKind = $kind,
    src.date = CASE WHEN $date = '' THEN src.date ELSE date($date) END,
    src.filePath = $filePath,
    src.externalRef = $externalRef,
    src.contentHash = $contentHash,
    src.ingestManifestId = $manifestId,
    src.verificationStatus = 'reviewed',
    src += $properties
WITH src
OPTIONAL MATCH (producer:Session {{id: $producerSid}})
FOREACH (_ IN CASE WHEN producer IS NULL THEN [] ELSE [1] END |
  MERGE (producer)-[r:INGESTED]->(src)
  SET r.provenance = $manifestId,
      r.method = $method,
      r.recordedAt = datetime()
)
RETURN src.id""",
            source_params,
        )
    ]
    for quest_id in source.get("quest_ids", []):
        queries.append(
            query(
                f"""MATCH (src:{source_labels} {{id: $sourceId}})
MATCH (q:Quest {{id: $questId}})
MERGE (src)-[r:PART_OF]->(q)
SET r.provenance = $manifestId,
    r.method = $method,
    r.recordedAt = datetime()
RETURN q.id""",
                {
                    "sourceId": source["id"],
                    "questId": quest_id,
                    "manifestId": manifest_id,
                    "method": method,
                },
            )
        )
    for person in source.get("people", []):
        if person["kind"] == "external":
            queries.append(
                query(
                    """MERGE (p:Person:KnowledgeEntity {ingestRef: $identityKey})
SET p.name = $name,
    p.kind = 'external',
    p.identityStatus = 'source-scoped',
    p.ingestManifestId = $manifestId,
    p += $properties
RETURN p.ingestRef""",
                    {
                        "identityKey": person["identity_key"],
                        "name": person["name"],
                        "manifestId": manifest_id,
                        "properties": person["properties"],
                    },
                )
            )
        params = {
            **person_parameters(person["ref"], people),
            "sourceId": source["id"],
            "manifestId": manifest_id,
            "method": method,
        }
        queries.append(
            query(
                f"""MATCH (src:{source_labels} {{id: $sourceId}})
MATCH (p:Person)
WHERE {PERSON_MATCH}
MERGE (src)-[r:{person['relation']}]->(p)
SET r.provenance = $manifestId,
    r.method = $method,
    r.recordedAt = datetime()
RETURN p.name""",
                params,
            )
        )
    for artifact in value["artifacts"]:
        artifact_type = artifact["type"].lower()
        subtype = ARTIFACT_LABELS.get(artifact_type)
        labels = f"Artifact:{subtype}" if subtype else "Artifact"
        artifact_params = {
            "id": artifact["id"],
            "title": artifact["title"],
            "type": artifact_type,
            "filePath": artifact["file_path"],
            "topics": artifact.get("topics", []),
            "summary": artifact["summary"],
            "confidence": artifact.get("confidence", 0),
            "verificationStatus": artifact.get("verification_status")
            or "reviewed",
            "properties": graph_properties(
                artifact.get("properties", {}),
                f"artifact {artifact['id']} properties",
            ),
            "manifestId": manifest_id,
            "producerSid": producer,
            "method": method,
        }
        queries.append(
            query(
                f"""MERGE (a:{labels} {{id: $id}})
SET a.title = $title,
    a.type = $type,
    a.filePath = $filePath,
    a.topics = $topics,
    a.summary = $summary,
    a.confidence = $confidence,
    a.verificationStatus = $verificationStatus,
    a.ingestManifestId = $manifestId,
    a.updatedAt = datetime(),
    a += $properties
WITH a
OPTIONAL MATCH (producer:Session {{id: $producerSid}})
FOREACH (_ IN CASE WHEN producer IS NULL THEN [] ELSE [1] END |
  MERGE (producer)-[r:PRODUCED]->(a)
  SET r.provenance = $manifestId,
      r.method = $method,
      r.recordedAt = datetime()
)
RETURN a.id""",
                artifact_params,
            )
        )
        queries.append(
            query(
                f"""MATCH (a:Artifact {{id: $artifactId}})
MATCH (src:{source_labels} {{id: $sourceId}})
MERGE (a)-[r:{source_edge}]->(src)
SET r.provenance = $manifestId,
    r.method = $method,
    r.recordedAt = datetime()
RETURN a.id""",
                {
                    "artifactId": artifact["id"],
                    "sourceId": source["id"],
                    "manifestId": manifest_id,
                    "method": method,
                },
            )
        )
        if artifact.get("author"):
            queries.append(
                query(
                    f"""MATCH (a:Artifact {{id: $artifactId}})
MATCH (p:Person)
WHERE {PERSON_MATCH}
MERGE (a)-[r:CONTRIBUTED_BY]->(p)
SET r.provenance = $manifestId,
    r.method = $method,
    r.recordedAt = datetime()
RETURN p.name""",
                    {
                        "artifactId": artifact["id"],
                        **person_parameters(artifact["author"], people),
                        "manifestId": manifest_id,
                        "method": method,
                    },
                )
            )
        for mentioned in artifact.get("mentions", []):
            queries.append(
                query(
                    f"""MATCH (a:Artifact {{id: $artifactId}})
MATCH (p:Person)
WHERE {PERSON_MATCH}
MERGE (a)-[r:MENTIONS]->(p)
SET r.provenance = $manifestId,
    r.method = $method,
    r.recordedAt = datetime()
RETURN p.name""",
                    {
                        "artifactId": artifact["id"],
                        **person_parameters(mentioned, people),
                        "manifestId": manifest_id,
                        "method": method,
                    },
                )
            )
        if artifact.get("source_chunks"):
            queries.append(
                query(
                    """MATCH (a:Artifact {id: $artifactId})
UNWIND $chunkIds AS chunkId
MATCH (c:IngestChunk {id: chunkId})
MERGE (a)-[r:DERIVED_FROM_CHUNK]->(c)
SET r.provenance = $manifestId,
    r.method = $method,
    r.recordedAt = datetime()
RETURN count(c)""",
                    {
                        "artifactId": artifact["id"],
                        "chunkIds": artifact["source_chunks"],
                        "manifestId": manifest_id,
                        "method": method,
                    },
                )
            )
        for quest_id in artifact.get("quest_ids", []):
            queries.append(
                query(
                    """MATCH (a:Artifact {id: $artifactId})
MATCH (q:Quest {id: $questId})
MERGE (a)-[r:PART_OF]->(q)
SET r.provenance = $manifestId,
    r.method = $method,
    r.recordedAt = datetime()
RETURN q.id""",
                    {
                        "artifactId": artifact["id"],
                        "questId": quest_id,
                        "manifestId": manifest_id,
                        "method": method,
                    },
                )
            )
    for relation in value.get("relations", []):
        queries.append(
            query(
                f"""MATCH (a:Artifact {{id: $fromId}})
MATCH (b:Artifact {{id: $toId}})
MERGE (a)-[r:{relation['type']}]->(b)
SET r.provenance = $manifestId,
    r.method = $method,
    r.recordedAt = datetime()
RETURN a.id""",
                {
                    "fromId": relation["from"],
                    "toId": relation["to"],
                    "manifestId": manifest_id,
                    "method": method,
                },
            )
        )
    return {
        "schema": PLAN_SCHEMA,
        "schema_family": "reviewed-knowledge",
        "manifest_id": manifest_id,
        "manifest_path": manifest_path(path),
        "source": {"kind": kind, "id": source["id"]},
        "query_count": len(queries),
        "queries": queries,
    }


def connector_manifest(value: dict[str, Any]) -> bool:
    return value.get("schema") == CONNECTOR_SCHEMA


def connector_plan(value: dict[str, Any], path: Path) -> dict[str, Any]:
    """Project connector lifecycle: which providers this org has connected,
    which accounts are authorized on each, and which ingest sources arrived
    through which account. Connected mode only — the plan is executed by the
    same runner as corpus plans and is idempotent (MERGE throughout)."""
    provider = required_string(value.get("provider"), "provider")
    if provider not in ("google", "notion"):
        raise ContractError(f"unsupported connector provider: {provider}")
    accounts = value.get("accounts")
    if not isinstance(accounts, list) or not accounts:
        raise ContractError("accounts must be a non-empty list")
    recorded = required_string(value.get("recorded_at"), "recorded_at")
    source_id = str(value.get("source_id") or "")
    queries: list[dict[str, Any]] = []
    queries.append(
        query(
            """MERGE (c:Connector {id: $provider})
SET c.provider = $provider,
    c.updatedAt = datetime($recorded)
RETURN c.id""",
            {"provider": provider, "recorded": recorded},
        )
    )
    for entry in accounts:
        if not isinstance(entry, dict):
            raise ContractError("each account must be an object")
        email = required_string(entry.get("email"), "accounts[].email")
        status = str(entry.get("status") or "authorized")
        if status not in ("authorized", "revoked"):
            raise ContractError(f"unsupported account status: {status}")
        account_id = f"{provider}:{email.lower()}"
        queries.append(
            query(
                """MERGE (a:SourceAccount {id: $id})
SET a.email = $email,
    a.provider = $provider,
    a.status = $status,
    a.updatedAt = datetime($recorded)
FOREACH (_ IN CASE WHEN $status = 'authorized' AND a.authorizedAt IS NULL THEN [1] ELSE [] END |
  SET a.authorizedAt = datetime($recorded)
)
WITH a
MATCH (c:Connector {id: $provider})
MERGE (a)-[:ON]->(c)
WITH a
OPTIONAL MATCH (s:IngestSource {id: $sourceId})
FOREACH (_ IN CASE WHEN s IS NULL OR $sourceId = '' THEN [] ELSE [1] END |
  MERGE (s)-[v:VIA_ACCOUNT]->(a)
  SET v.recordedAt = datetime($recorded)
)
RETURN a.id""",
                {
                    "id": account_id,
                    "email": email,
                    "provider": provider,
                    "status": status,
                    "recorded": recorded,
                    "sourceId": source_id,
                },
            )
        )
    return {
        "schema": PLAN_SCHEMA,
        "schema_family": "connector-lifecycle",
        "manifest_id": f"connector:{provider}",
        "source": {"kind": "connector", "id": provider},
        "query_count": len(queries),
        "queries": queries,
    }


def build_plan(value: dict[str, Any], path: Path) -> dict[str, Any]:
    if connector_manifest(value):
        return connector_plan(value, path)
    if corpus_manifest(value):
        return corpus_plan(value, path)
    return knowledge_plan(value, path)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("validate", "plan"))
    parser.add_argument("manifest")
    args = parser.parse_args()
    path = Path(args.manifest)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise ContractError("manifest must be a JSON object")
        plan = build_plan(value, path)
    except (OSError, json.JSONDecodeError, ContractError, TypeError) as exc:
        print(
            json.dumps(
                {
                    "valid": False,
                    "path": str(path),
                    "error": str(exc),
                }
            )
        )
        return 2
    if args.mode == "validate":
        print(
            json.dumps(
                {
                    "valid": True,
                    "path": str(path),
                    "manifest_id": plan["manifest_id"],
                    "schema_family": plan["schema_family"],
                }
            )
        )
    else:
        print(json.dumps(plan, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
