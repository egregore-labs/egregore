// Runtime-owned query worker over the existing pinned QMD SDK/index. All query
// state is per invocation; the existing worker metadata owns this process.
import { createServer } from 'node:http';
import { readFileSync, existsSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';
import { scopedSearch, SCOPED_VERSION } from './qmd_scoped.mjs';
import { createHmac, timingSafeEqual } from 'node:crypto';

const args = process.argv.slice(2);
const option = name => { const index = args.indexOf(name); return index < 0 ? undefined : args[index + 1]; };
const packageRoot = resolve(option('--package'));
const metadata = JSON.parse(readFileSync(join(packageRoot, 'package.json'), 'utf8'));
if (metadata.name !== '@tobilu/qmd' || metadata.version !== '2.8.3') throw new Error('pinned QMD 2.8.3 required');
const database = resolve(option('--database'));
const collection = option('--collection');
const indexName = option('--index');
const signature = option('--signature');
if (!collection || !indexName || !signature) throw new Error('owned worker identity is required');
// Match QMD's existing per-index configuration and model selection.
const configPath = process.env.QMD_CONFIG_DIR && join(process.env.QMD_CONFIG_DIR, `${indexName}.yml`);
const { createStore } = await import(pathToFileURL(join(packageRoot, 'dist/index.js')));
const qmd = await import(pathToFileURL(join(packageRoot, 'dist/store.js')));
const sdk = await createStore({ dbPath: database, ...(configPath && existsSync(configPath) ? { configPath } : {}) });
const workerToken = process.env.EGREGORE_QMD_WORKER_TOKEN;
delete process.env.EGREGORE_QMD_WORKER_TOKEN;
const mac = message => createHmac('sha256', workerToken).update(message).digest('hex');
const healthIdentity = [signature, indexName, database, collection].join('\n');
const MAX_BODY = 16 * 1024 * 1024;
let queue = Promise.resolve();

async function readBody(stream) {
  let size = 0;
  const chunks = [];
  for await (const chunk of stream) {
    size += chunk.length;
    if (size > MAX_BODY) throw new Error('query payload exceeds 16 MiB');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString('utf8');
}

async function query(payload) {
  if (payload.eligibility) return scopedSearch(sdk.internal, qmd, payload, collection);
  if (payload.rerank !== false || !Array.isArray(payload.searches) || !payload.searches.length ||
      !Array.isArray(payload.collections) || payload.collections.length !== 1 || payload.collections[0] !== collection) {
    throw new Error('invalid owned typed query');
  }
  const results = await sdk.search({ queries: payload.searches, collections: [collection],
    limit: payload.limit, candidateLimit: payload.candidateLimit, rerank: false, intent: payload.intent });
  return { results };
}

function enqueue(payload) {
  const result = queue.then(() => query(payload));
  queue = result.catch(() => {});
  return result;
}

if (args.includes('--once')) {
  try {
    process.stdout.write(JSON.stringify(await query(JSON.parse(await readBody(process.stdin)))) + '\n');
  } catch (error) {
    process.stderr.write(String(error.message || error) + '\n');
    process.exitCode = 2;
  } finally {
    await sdk.close();
  }
} else {
  if (!/^[a-f0-9]{64}$/.test(workerToken || '')) throw new Error('owned worker token is required');
  const port = Number(option('--port'));
  if (!Number.isInteger(port) || port < 1 || port > 65535 || port === 8181) throw new Error('invalid owned port');
  const server = createServer(async (request, response) => {
    response.setHeader('Content-Type', 'application/json');
    // This endpoint is an internal loopback transport, not a browser API.
    if (request.headers.origin) { response.writeHead(403).end('{}'); return; }
    const url = new URL(request.url, 'http://localhost');
    if (url.pathname === '/health' && request.method === 'GET') {
      const challenge = url.searchParams.get('challenge');
      if (!/^[a-f0-9]{64}$/.test(challenge || '')) { response.writeHead(400).end('{}'); return; }
      response.end(JSON.stringify({ status: 'ok', capability: SCOPED_VERSION, signature,
        index: indexName, database, collection, proof: mac('health:' + challenge + ':' + healthIdentity) }));
      return;
    }
    if (!['/query','/shutdown'].includes(request.url) || request.method !== 'POST' ||
        !String(request.headers['content-type'] || '').startsWith('application/json')) {
      response.writeHead(404).end('{}'); return;
    }
    try {
      const body = await readBody(request);
      const nonce = request.headers['x-egregore-nonce'];
      const auth = request.headers['x-egregore-auth'];
      if (!/^[a-f0-9]{64}$/.test(nonce || '') || !/^[a-f0-9]{64}$/.test(auth || '') ||
          !timingSafeEqual(Buffer.from(auth, 'hex'), Buffer.from(mac('POST\n'+request.url+'\n'+nonce+'\n'+body), 'hex'))) {
        response.writeHead(403).end('{}'); return;
      }
      const payload = JSON.parse(body);
      if (request.url === '/shutdown') {
        if (JSON.stringify(payload) !== '{"operation":"shutdown"}') throw new Error('invalid worker shutdown');
        response.end(JSON.stringify({stopping:true}));
        setImmediate(close);
        return;
      }
      const result = await enqueue(payload);
      response.end(JSON.stringify(result));
    } catch (error) {
      response.writeHead(400).end(JSON.stringify({ error: String(error.message || error) }));
    }
  });
  server.requestTimeout = 60_000;
  server.listen(port, 'localhost');
  let closing = false;
  const close = async () => {
    if (closing) return;
    closing = true;
    server.close();
    await queue;
    await sdk.close();
    process.exit(0);
  };
  process.on('SIGTERM', close);
  process.on('SIGINT', close);
}
