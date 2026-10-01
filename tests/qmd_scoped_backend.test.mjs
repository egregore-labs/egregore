import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtempSync, rmSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { scopedSearch } from '../egregore_runtime/adapters/qmd_scoped.mjs';
import { createHmac } from 'node:crypto';
import { spawn, spawnSync } from 'node:child_process';
import { createServer } from 'node:net';
import { fileURLToPath } from 'node:url';

// Real pinned QMD and sqlite-vec; synthetic vectors isolate candidate semantics
// from model inference. CI can point this at its provisioned QMD dependency.
const packageRoot = process.env.EGREGORE_TEST_QMD_PACKAGE;
const qmd = packageRoot && await import(pathToFileURL(join(packageRoot, 'dist/store.js')));
const options = { skip: !packageRoot };
const vector = [1, 0, 0, 0, 0, 0, 0, 0];
const model = 'fixture-embedding';
const collection = 'fixture';
const hashRevision = 'a'.repeat(64);

function fixture(t) {
  assert.equal(JSON.parse(readFileSync(join(packageRoot, 'package.json'))).version, '2.8.3');
  const directory = mkdtempSync(join(tmpdir(), 'egregore-scoped-'));
  const store = qmd.createStore(join(directory, 'index.sqlite'));
  store.ensureVecTable(8);
  store.llm = { embedModelName: model, embedBatch: async texts => texts.map(() => ({ embedding: vector })) };
  store.db.prepare('INSERT INTO store_collections (name,path) VALUES (?,?)').run(collection, directory);
  t.after(() => { store.close(); rmSync(directory, { recursive: true, force: true }); });
  const documents = [];
  async function add(path, body, embedding = vector, count = 1, hashOverride = null) {
    const hash = hashOverride || await qmd.hashContent(body);
    store.db.prepare('INSERT OR IGNORE INTO content(hash,doc,created_at) VALUES (?,?,?)').run(hash, body, '2026-09-01');
    qmd.insertDocument(store.db, collection, path, path, hash, '2026-09-01', '2026-09-01');
    if (hashOverride) {
      const document = { path, hash };
      documents.push(document);
      return document;
    }
    const insertMeta = store.db.prepare(`INSERT OR REPLACE INTO content_vectors
      (hash,seq,pos,model,embed_fingerprint,total_chunks,embedded_at) VALUES (?,?,?,?,?,?,?)`);
    const insertVec = store.db.prepare('INSERT OR REPLACE INTO vectors_vec (hash_seq,embedding) VALUES (?,?)');
    store.db.exec('BEGIN');
    try {
      for (let seq = 0; seq < count; seq++) {
        insertMeta.run(hash, seq, seq * 100, model, qmd.getEmbeddingFingerprint(model), count, '2026-09-01');
        insertVec.run(`${hash}_${seq}`, new Float32Array(embedding));
      }
      store.db.exec('COMMIT');
    } catch (error) { store.db.exec('ROLLBACK'); throw error; }
    const document = { path, hash };
    documents.push(document);
    return document;
  }
  return { store, documents, add };
}

function payload(documents, types = ['lex', 'vec'], limit = 6) {
  return { searches: types.map(type => ({ type, query: 'signal' })),
    collections: [collection], limit, candidateLimit: 128, rerank: false,
    eligibility: { version: 'egregore-eligibility/v1', revision: hashRevision,
      source_revision: 'fixture:current', documents } };
}

for (const types of [['lex'], ['vec'], ['lex', 'vec']]) {
  test(`eligible witness survives the native branch cutoff: ${types.join('+')}`, options, async t => {
    const f = fixture(t);
    for (let number = 0; number < 240; number++) {
      await f.add(`old-${number}.md`, `# signal\nsignal signal signal\nold ${number}`);
    }
    const target = await f.add('current.md', `# Current\nsignal ${'filler '.repeat(400)}`, [0.8, 0.6, 0, 0, 0, 0, 0, 0]);
    const baseline = await qmd.structuredSearch(f.store, payload([target], types).searches,
      { collections: [collection], limit: 128, candidateLimit: 1024, skipRerank: true });
    assert(!baseline.some(row => row.file.endsWith('/current.md')), 'fixture must expose the native candidate miss');
    const result = await scopedSearch(f.store, qmd, payload([target], types), collection);
    assert.deepEqual(result.results.map(row => row.file), ['qmd://fixture/current.md']);
    assert.equal(result.coverage.eligibility_stage, 'pre_candidate');
    assert.equal(result.coverage.eligibility_complete, true);
  });
}

test('shared hashes never expand back into an ineligible path', options, async t => {
  const f = fixture(t);
  const allowed = await f.add('allowed %.md', '# signal\nSame content');
  await f.add('private.md', '# signal\nSame content', vector, 1, allowed.hash);
  const result = await scopedSearch(f.store, qmd, payload([allowed]), collection);
  assert.deepEqual(result.results.map(row => row.file), ['qmd://fixture/allowed%20%25.md']);
  assert.equal(result.coverage.eligible_count, 1);
});

for (const metadataHeavy of [false, true]) {
test(`real SDK passages survive Python authorization and investigation discovery (metadata=${metadataHeavy})`, options, async t => {
  const f = fixture(t);
  const prose = '# Release follow-up\n143: files recovered\nsignal installer repair shipped.\n' + 'Evidence details. '.repeat(100);
  const header = metadataHeavy ? '---\ntitle: signal\ncreated_by: "actor"\nprovenance: "' + 'source '.repeat(800) + '"\n---\n' : '';
  const body = header + prose;
  const allowed = await f.add('public/release.md', body);
  await f.add('private.md', '# signal\nPrivate source must not enter discovery');
  const response = await scopedSearch(f.store, qmd, payload([allowed], ['lex']), collection);
  assert.equal(response.results.length, 1);
  assert.equal(response.results[0].snippet, undefined, 'exercise native SDK shape, never a CLI-shaped fixture');
  if (metadataHeavy) assert(response.results[0].bestChunk.startsWith('---\n'));
  else assert(response.results[0].bestChunk.includes('143: files recovered'));

  // Cross the actual JSON/Python boundary with the real structuredSearch row.
  // Only index readiness and transport are substituted; canonical eligibility,
  // passage mapping and compact investigation projection execute normally.
  const checked = spawnSync(process.env.PYTHON || 'python3', ['-c', `
import json, os, sys, tempfile
from pathlib import Path
from types import SimpleNamespace
from egregore_runtime import RetrievalMode, RetrievalRequest
from egregore_runtime.adapters.qmd import QmdLocalRetriever
from egregore_runtime.investigation import LookupAdapter

response = json.load(sys.stdin)
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    memory = root / 'memory'
    source = memory / 'public/release.md'
    source.parent.mkdir(parents=True)
    source.write_text(response['results'][0]['body'], encoding='utf-8')
    (root / 'egregore.json').write_text('{"slug":"fixture"}')
    environment = {**os.environ, 'EGREGORE_QMD_RUNTIME_DIR': str(root / 'runtime'),
                   'EGREGORE_QMD_PERSISTENT': '0', 'EGREGORE_SEARCH_NO_WARM': '1'}
    retriever = QmdLocalRetriever(repository_root=root, memory_root=memory,
                                 collection='fixture', environment=environment)
    retriever._ensure_ready = lambda warnings: None
    def query(searches, limit, intent, eligibility):
        assert [item.canonical_path for item in eligibility.documents] == ['memory/public/release.md']
        return response
    retriever._query_scoped = query
    actor = SimpleNamespace(actor=SimpleNamespace(actor_id='actor', display_name='Fixture', aliases={}))
    request = RetrievalRequest(request_id='sdk-contract', org_id='org', actor_id='actor',
        task='signal', lex=('signal',), vec=(), mode=RetrievalMode.LEX,
        authorized_scopes=('memory/public',))
    lookup = LookupAdapter(retriever, 'keyword', {}, actor, None)
    result = lookup.retrieve_authorized(request, actor=actor)
    hit, = result.hits
    assert hit.canonical_path == 'memory/public/release.md'
    assert hit.content_hash and hit.revision
    assert hit.passage_id is None, 'SDK character offset is not a line citation'
    excerpt = json.loads(hit.passage)['excerpt']
    assert excerpt == ('# Release follow-up\\n143: files recovered\\nsignal installer repair shipped.\\n' + 'Evidence details. ' * 100)[:600]
    assert '143: files recovered' in excerpt
    assert len(excerpt) == 600
    print('SDK passage delivered through authorized investigation')
`], { cwd: fileURLToPath(new URL('..', import.meta.url)),
    input: JSON.stringify(response), encoding: 'utf8' });
  assert.equal(checked.status, 0, checked.stderr || checked.error?.message);
  assert.match(checked.stdout, /SDK passage delivered through authorized investigation/);
});
}

test('stale and absent index entries produce explicit partial coverage', options, async t => {
  const f = fixture(t);
  const current = await f.add('current.md', '# signal\nCurrent');
  const stale = await f.add('stale.md', '# signal\nOlder');
  const result = await scopedSearch(f.store, qmd, payload([current,
    { ...stale, hash: 'b'.repeat(64) }, { path: 'missing.md', hash: 'c'.repeat(64) }]), collection);
  assert.deepEqual(result.results.map(row => row.file), ['qmd://fixture/current.md']);
  assert.equal(result.coverage.stale_or_missing_count, 2);
  assert.equal(result.coverage.eligibility_complete, false);
});

test('corrupted indexed bodies and incomplete vectors are not represented as current', options, async t => {
  const f = fixture(t);
  const corrupt = await f.add('corrupt.md', '# signal\nOriginal');
  const incomplete = await f.add('partial.md', '# signal\nPartial', vector, 2);
  f.store.db.prepare('UPDATE content SET doc=? WHERE hash=?').run('corrupted', corrupt.hash);
  f.store.db.prepare('DELETE FROM content_vectors WHERE hash=? AND seq=1').run(incomplete.hash);
  const result = await scopedSearch(f.store, qmd, payload([corrupt, incomplete], ['vec']), collection);
  assert.deepEqual(result.results, []);
  assert.equal(result.coverage.stale_or_missing_count, 1);
  assert.equal(result.coverage.vector_missing_count, 1);
});

test('exact eligible vectors deduplicate documents before limits beyond 20000 chunks', options, async t => {
  const f = fixture(t);
  const bulk = await f.add('bulk.md', '# signal\nMany chunks', vector, 20001);
  const other = await f.add('other.md', '# signal\nOther', [0.8, 0.6, 0, 0, 0, 0, 0, 0]);
  const baseline = await f.store.searchVec('signal', model, 20, collection, undefined, vector);
  assert(!baseline.some(row => row.filepath.endsWith('/other.md')));
  const result = await scopedSearch(f.store, qmd, payload([bulk, other], ['vec']), collection);
  assert.deepEqual(result.results.map(row => row.file), ['qmd://fixture/bulk.md', 'qmd://fixture/other.md']);
  assert.equal(result.coverage.eligibility_complete, true);
});

test('duplicate, escaping and foreign-collection requests fail closed', options, async t => {
  const f = fixture(t);
  const allowed = await f.add('allowed.md', '# signal');
  for (const request of [payload([allowed, allowed]), payload([{ ...allowed, path: '../escape.md' }]),
    { ...payload([allowed]), collections: ['foreign'] }]) {
    await assert.rejects(scopedSearch(f.store, qmd, request, collection));
  }
  assert.equal(f.store.db.prepare('SELECT count(*) AS n FROM documents').get().n, 1);
});

test('missing query embeddings cannot masquerade as complete hybrid execution', options, async t => {
  const f = fixture(t);
  const allowed = await f.add('allowed.md', '# signal');
  f.store.llm.embedBatch = async texts => texts.map(() => null);
  await assert.rejects(scopedSearch(f.store, qmd, payload([allowed]), collection), /no usable query embedding/);
  // Failure rolls back the read transaction; the worker can serve a later call.
  const lexical = await scopedSearch(f.store, qmd, payload([allowed], ['lex']), collection);
  assert.equal(lexical.results.length, 1);
});

test('owned SDK worker serves concurrent requests and the same cold capability', options, async t => {
  const f = fixture(t);
  const allowed = await f.add('allowed.md', '# signal\nSDK witness');
  const request = payload([allowed], ['lex']);
  const database = f.store.db.prepare('PRAGMA database_list').all().find(row => row.name === 'main').file;
  const common = [fileURLToPath(new URL('../egregore_runtime/adapters/qmd_worker.mjs', import.meta.url)),
    '--package', packageRoot, '--database', database, '--collection', collection,
    '--index', 'fixture-index', '--signature', 'fixture-signature'];
  const cold = spawn(process.execPath, [...common, '--once'], { stdio: ['pipe', 'pipe', 'pipe'] });
  let output = '', errors = '';
  cold.stdout.on('data', data => { output += data; });
  cold.stderr.on('data', data => { errors += data; });
  cold.stdin.end(JSON.stringify(request));
  assert.equal(await new Promise(resolve => cold.on('exit', resolve)), 0, errors);
  const once = JSON.parse(output);
  assert.equal(once.coverage.eligibility_stage, 'pre_candidate');
  const probe = createServer();
  await new Promise(resolve => probe.listen(0, 'localhost', resolve));
  const port = probe.address().port;
  await new Promise(resolve => probe.close(resolve));
  const token = 'c'.repeat(64), nonce = 'd'.repeat(64);
  const mac = message => createHmac('sha256',token).update(message).digest('hex');
  const worker = spawn(process.execPath, [...common, '--port', String(port)], {
    env:{...process.env,EGREGORE_QMD_WORKER_TOKEN:token}, stdio: ['ignore','ignore','pipe'] });
  const exited = new Promise(resolve => worker.on('exit', resolve));
  worker.stderr.on('data', data => { errors += data; });
  t.after(async () => { if (worker.exitCode === null) worker.kill('SIGTERM'); await exited; });
  let health;
  for (let attempt = 0; attempt < 100; attempt++) {
    try { health = await (await fetch(`http://localhost:${port}/health?challenge=${nonce}`)).json(); break; }
    catch { await new Promise(resolve => setTimeout(resolve, 50)); }
  }
  assert.equal(health?.signature, 'fixture-signature', errors);
  assert.equal(health.proof,mac('health:'+nonce+':'+['fixture-signature','fixture-index',database,collection].join('\n')));
  const post = (body, signed=true) => {
    const encoded=JSON.stringify(body);
    return fetch(`http://localhost:${port}/query`, { method:'POST',
      headers:{'Content-Type':'application/json',...(signed ? {'X-Egregore-Nonce':nonce,
        'X-Egregore-Auth':mac('POST\n/query\n'+nonce+'\n'+encoded)}:{})}, body:encoded });
  };
  assert.equal((await post(request,false)).status,403);
  const responses = await Promise.all(Array.from({length:4}, () => post(request).then(response => response.json())));
  for (const response of responses) assert.deepEqual(response.results, once.results);
  assert.equal((await post({...request, collections:['foreign']})).status, 400);
  assert.deepEqual((await (await post(request)).json()).results, once.results);
});
