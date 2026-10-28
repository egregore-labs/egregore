// Eligibility adapter for pinned QMD 2.8.3. QMD retains query parsing, BM25
// scoring, embedding formatting/batching, RRF weighting and passage selection.
// No shared-index flags, temporary catalog, or query-time embedding rebuilds.
import { createHash } from 'node:crypto';

export const SCOPED_VERSION = 'egregore-qmd-scoped/v1';
const HASH = /^[a-f0-9]{64}$/;
const MAX_DOCUMENTS = 50_000;
const CHUNK_BATCH = 400;

function usableEmbeddings(values, count) {
  return Array.isArray(values) && values.length === count && values.every(value =>
    Array.isArray(value?.embedding) && value.embedding.length > 0 &&
    value.embedding.every(number => Number.isFinite(number)));
}

function canonicalRelative(path) {
  return typeof path === 'string' && path.length > 0 && path.length <= 4096 &&
    !path.startsWith('/') && !path.includes('\\') && !path.includes('\0') &&
    path.split('/').every(part => part && part !== '.' && part !== '..');
}

export function validateEligibility(value) {
  if (!value || value.version !== 'egregore-eligibility/v1' || !HASH.test(value.revision) ||
      typeof value.source_revision !== 'string' || value.source_revision.length > 500 ||
      !Array.isArray(value.documents) || value.documents.length > MAX_DOCUMENTS) {
    throw new Error('invalid canonical eligibility snapshot');
  }
  const paths = new Map();
  for (const document of value.documents) {
    if (!canonicalRelative(document?.path) || !HASH.test(document?.hash) || paths.has(document.path)) {
      throw new Error('invalid or duplicate eligible document');
    }
    paths.set(document.path, document.hash);
  }
  return paths;
}

function virtualPath(collection, path) {
  return `qmd://${collection}/${path.split('/').map(encodeURIComponent).join('/')}`;
}

export async function scopedSearch(store, qmd, payload, collection) {
  if (!Array.isArray(payload.collections) || payload.collections.length !== 1 || payload.collections[0] !== collection) {
    throw new Error('query must use the owned collection');
  }
  if (!Array.isArray(payload.searches) || payload.searches.length < 1 || payload.searches.length > 40 ||
      payload.searches.some(search => !['lex', 'vec'].includes(search?.type) ||
        typeof search.query !== 'string' || !search.query.trim() || search.query.length > 32768) ||
      !Number.isInteger(payload.limit) || payload.limit < 1 || payload.limit > 10000 || payload.rerank !== false) {
    throw new Error('invalid typed scoped query');
  }
  const requested = validateEligibility(payload.eligibility);
  const db = store.db;
  const started = performance.now();
  const timings = {};
  const wantsVectors = payload.searches.some(search => search.type === 'vec');
  let vectorMissing = 0;
  // The read snapshot fixes path/hash/chunk mappings throughout asynchronous
  // query embedding. The worker serializes calls on this connection.
  db.exec('BEGIN');
  try {
    const rows = db.prepare(`SELECT d.id, d.path, d.title, d.hash, c.doc AS body
      FROM documents d JOIN content c ON c.hash = d.hash
      WHERE d.active = 1 AND d.collection = ?
        AND d.path IN (SELECT value FROM json_each(?)) ORDER BY d.path`)
      .all(collection, JSON.stringify([...requested.keys()]));
    const documents = rows.filter(row => requested.get(row.path) === row.hash &&
      createHash('sha256').update(row.body).digest('hex') === row.hash);
    const byPath = new Map(documents.map(row => [row.path, row]));
    const idsJson = JSON.stringify(documents.map(row => row.id));
    const missing = requested.size - documents.length;
    timings.index_validation_ms = Math.round(performance.now() - started);
    const vectorTable = !!db.prepare("SELECT name FROM sqlite_master WHERE type='table' AND name='vectors_vec'").get();
    if (wantsVectors && !vectorTable) vectorMissing = documents.length;

    // Add the predicate inside QMD's FTS CTE, before its own LIMIT. Keep its
    // lexical parser, weights and score mapping unchanged. Fail closed if the
    // pinned SQL boundary changes rather than quietly doing post-filtering.
    const scopedDb = {
      prepare(sql) {
        if (sql.includes('documents_fts')) {
          const marker = 'WHERE documents_fts MATCH ?';
          if (!sql.includes('WITH fts_matches AS (') || sql.split(marker).length !== 2) {
            throw new Error('pinned QMD FTS scope boundary changed');
          }
          const statement = db.prepare(sql.replace(marker,
            `${marker} AND rowid IN (SELECT value FROM json_each(?))`));
          return { all: (...params) => statement.all(params[0], idsJson, ...params.slice(1)) };
        }
        return db.prepare(sql);
      },
    };
    function decorate(row) {
      const path = row.displayPath.slice(collection.length + 1);
      if (!byPath.has(path) || row.hash !== byPath.get(path).hash) {
        throw new Error('QMD returned a document outside the eligible snapshot');
      }
      return { ...row, filepath: virtualPath(collection, path) };
    }
    function searchFTS(query, limit, selectedCollection) {
      if (selectedCollection !== collection) throw new Error('foreign collection');
      const then = performance.now();
      const result = qmd.searchFTS(scopedDb, query, limit, collection).map(decorate);
      timings.keyword_ms = (timings.keyword_ms || 0) + Math.round(performance.now() - then);
      return result;
    }
    async function searchVec(query, model, limit, selectedCollection, session, embedding) {
      if (selectedCollection !== collection || !Array.isArray(embedding) || !embedding.length ||
          embedding.some(number => !Number.isFinite(number))) throw new Error('invalid scoped vector query');
      const then = performance.now();
      const hashes = [...new Set(documents.map(row => row.hash))];
      if (!vectorTable) return [];
      const chunks = db.prepare(`SELECT hash, seq, pos, total_chunks FROM content_vectors
        WHERE model = ? AND embed_fingerprint = ? AND hash IN (SELECT value FROM json_each(?))
        ORDER BY hash, seq`).all(model, qmd.getEmbeddingFingerprint(model), JSON.stringify(hashes));
      const grouped = new Map();
      for (const chunk of chunks) {
        if (!grouped.has(chunk.hash)) grouped.set(chunk.hash, []);
        grouped.get(chunk.hash).push(chunk);
      }
      for (const [hash, group] of grouped) {
        const total = group[0].total_chunks;
        if (!Number.isInteger(total) || total < 1 || group.length !== total ||
            group.some((chunk, index) => chunk.seq !== index || chunk.total_chunks !== total)) grouped.delete(hash);
      }
      const keys = [...grouped.values()].flatMap(group => group.map(chunk => `${chunk.hash}_${chunk.seq}`));
      const distances = new Map();
      const queryVector = new Float32Array(embedding);
      // Reuse QMD's sqlite-vec exact cosine primitive. Score only eligible
      // chunks, then deduplicate documents BEFORE truncation. No ANN fallback
      // or top-chunk cap can crowd another eligible document out of this set.
      for (let offset = 0; offset < keys.length; offset += CHUNK_BATCH) {
        const batch = keys.slice(offset, offset + CHUNK_BATCH);
        const scored = db.prepare(`SELECT hash_seq, vec_distance_cosine(embedding, ?) AS distance
          FROM vectors_vec WHERE hash_seq IN (${batch.map(() => '?').join(',')})`)
          .all(queryVector, ...batch);
        for (const row of scored) if (Number.isFinite(row.distance)) distances.set(row.hash_seq, row.distance);
      }
      const best = new Map();
      for (const [hash, group] of grouped) {
        if (group.some(chunk => !distances.has(`${hash}_${chunk.seq}`))) continue;
        for (const chunk of group) {
          const distance = distances.get(`${hash}_${chunk.seq}`);
          if (!best.has(hash) || distance < best.get(hash).distance) best.set(hash, { distance, pos: chunk.pos });
        }
      }
      vectorMissing = documents.filter(row => !best.has(row.hash)).length;
      const result = documents.filter(row => best.has(row.hash))
        .map(row => ({ row, ...best.get(row.hash) }))
        .sort((a, b) => a.distance - b.distance || a.row.path.localeCompare(b.row.path, 'en'))
        .slice(0, limit).map(({ row, distance, pos }) => ({
          filepath: virtualPath(collection, row.path), displayPath: `${collection}/${row.path}`,
          title: row.title, hash: row.hash, docid: qmd.getDocid(row.hash), collectionName: collection,
          modifiedAt: '', bodyLength: row.body.length, body: row.body,
          context: store.getContextForFile(virtualPath(collection, row.path)),
          score: 1 - distance, source: 'vec', chunkPos: pos,
        }));
      timings.vector_ms = (timings.vector_ms || 0) + Math.round(performance.now() - then);
      return result;
    }
    const hooks = { onEmbedDone: milliseconds => { timings.query_embedding_ms = milliseconds; } };
    // QMD's embedBatch can resolve to null entries after a native/model error.
    // structuredSearch silently skips those branches. Preserve its formatting
    // and batching, but never label that partial execution as a hybrid success.
    const llm = store.llm;
    const guardedLlm = llm && {
      get embedModelName() { return llm.embedModelName; },
      async embedBatch(texts) {
        const embeddings = await llm.embedBatch(texts);
        if (!usableEmbeddings(embeddings, texts.length)) {
          throw new Error('QMD produced no usable query embedding; semantic branches did not execute');
        }
        return embeddings;
      },
    };
    const results = documents.length ? await qmd.structuredSearch(
      { ...store, ...(guardedLlm ? { llm: guardedLlm } : {}), searchFTS, searchVec }, payload.searches, {
        collections: [collection], limit: payload.limit,
        candidateLimit: payload.candidateLimit ?? Math.max(payload.limit, 40),
        skipRerank: true, intent: payload.intent, hooks,
      }) : [];
    for (const result of results) {
      const decoded = decodeURIComponent(result.file.slice(`qmd://${collection}/`.length));
      if (!byPath.has(decoded)) throw new Error('rank fusion returned an ineligible document');
    }
    const warnings = [];
    if (missing) warnings.push(`${missing} eligible document(s) absent or stale in the text index`);
    if (vectorMissing) warnings.push(`${vectorMissing} eligible document(s) lack complete current vectors`);
    return { results, warnings, coverage: {
      capability: SCOPED_VERSION, eligibility_stage: 'pre_candidate',
      eligible_set_revision: payload.eligibility.revision, eligible_count: requested.size,
      indexed_eligible_count: documents.length, stale_or_missing_count: missing,
      vector_missing_count: vectorMissing, eligibility_complete: missing === 0 && vectorMissing === 0,
      ...(wantsVectors && documents.length ? { embedding_backend: llm?.executionBackend || 'qmd-auto' } : {}),
      ranked_exhaustive: false, branch_limit: 20, returned_count: results.length,
      phases: { ...timings, backend_ms: Math.round(performance.now() - started) },
    } };
  } finally {
    db.exec('ROLLBACK');
  }
}
