"""Transport for the Runtime-owned QMD capability; existing index/model storage.

Dependency code is not patched. The framework worker imports the pinned SDK and
retains models between calls; its once mode is the same scoped cold fallback.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import os
from pathlib import Path
import shutil
import secrets
import signal
import subprocess
import sys
import urllib.error
import urllib.request

SCOPED_VERSION = 'egregore-qmd-scoped/v1'


def worker_signature():
    digest = hashlib.sha256()
    for name in ('qmd_worker.mjs', 'qmd_scoped.mjs'):
        digest.update(Path(__file__).with_name(name).read_bytes())
    return digest.hexdigest()


def package_root(retriever):
    command = retriever._command()
    binary = shutil.which(command[0], path=retriever.environment.get('PATH')) or command[0]
    resolved = Path(binary).resolve()
    for candidate in list(resolved.parents)[:5]:
        manifest = candidate / 'package.json'
        if not manifest.is_file():
            continue
        metadata = json.loads(manifest.read_text())
        if metadata.get('name') == '@tobilu/qmd' and metadata.get('version') == '2.8.3':
            if (candidate / 'dist/index.js').is_file():
                return candidate
    raise RuntimeError('scoped retrieval requires the pinned QMD 2.8.3 SDK alongside its executable')


def worker_command(retriever, *, port=None):
    node = retriever.environment.get('EGREGORE_QMD_NODE_BIN') or shutil.which('node', path=retriever.environment.get('PATH'))
    if not node:
        raise RuntimeError('Node is unavailable for the owned QMD query worker')
    command = [node, str(Path(__file__).with_name('qmd_worker.mjs')),
               '--package', str(package_root(retriever)), '--database', str(retriever._index_path()),
               '--collection', retriever.collection, '--index', retriever.index_name,
               '--signature', worker_signature()]
    return command + (['--port', str(port)] if port is not None else ['--once'])


def worker_environment(retriever):
    environment = dict(retriever.environment)
    # Match QMD's launcher before its native binding is imported.
    if sys.platform == 'darwin' and environment.get('QMD_METAL_KEEP_RESIDENCY') != '1':
        environment.setdefault('GGML_METAL_NO_RESIDENCY', '1')
    for key, value in [('LLAMA_LOG_LEVEL', 'error'), ('GGML_LOG_LEVEL', 'error'), ('GGML_BACKEND_SILENT', '1')]:
        environment.setdefault(key, value)
    return environment


def launch_worker(retriever, port, token):
    command = worker_command(retriever, port=port)
    path = retriever._runtime_root() / 'query-worker.log'
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_CREAT | os.O_APPEND | os.O_WRONLY | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(descriptor, 'a') as log:
        process = subprocess.Popen(command, cwd=retriever.repository_root,
            env={**worker_environment(retriever), 'EGREGORE_QMD_WORKER_TOKEN':token}, stdin=subprocess.DEVNULL,
            stdout=log, stderr=log, start_new_session=True)
    return process


def signed_headers(body, token, *, path='/query'):
    headers = {'Content-Type':'application/json'}
    if token:
        nonce = secrets.token_hex(32)
        headers.update({'X-Egregore-Nonce':nonce,
            'X-Egregore-Auth':hmac.new(token.encode(), ('POST\n'+path+'\n'+nonce+'\n').encode()+body, hashlib.sha256).hexdigest()})
    return headers


def query_scoped(retriever, searches, limit, intent, eligibility):
    payload = {'searches': searches, 'collections': [retriever.collection],
               'limit': limit, 'candidateLimit': max(limit, 40), 'rerank': False,
               'intent': intent, 'eligibility': eligibility.to_wire()}
    retriever._last_query_used_daemon = None
    result = None
    if retriever._ensure_daemon(require_scoped=True):
        runtime = retriever._owned_runtime()
        if runtime is None:
            raise RuntimeError('owned scoped query worker identity changed; retry the operation')
        body = json.dumps(payload).encode()
        request = urllib.request.Request(runtime.endpoint + '/query',
            data=body, headers=signed_headers(body, runtime.worker_token), method='POST')
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                result = json.load(response)
            retriever._last_query_used_daemon = True
        except urllib.error.HTTPError as error:
            # A completed rejected request must not be silently executed twice.
            try:
                message = json.loads(error.read(65536)).get('error', 'scoped query rejected')
            except (ValueError, OSError):
                message = 'scoped query rejected'
            raise RuntimeError(message) from error
        except (OSError, ValueError, urllib.error.URLError) as error:
            # A timed-out worker may still be computing. Do not duplicate that
            # work in a cold process; the caller can explicitly retry.
            raise RuntimeError('owned scoped query interrupted; retry within the current investigation') from error
    else:
        retriever._last_query_used_daemon = False
        process = subprocess.Popen(worker_command(retriever), cwd=retriever.repository_root,
            env=worker_environment(retriever), text=True, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
        try:
            stdout, stderr = process.communicate(json.dumps(payload), timeout=90)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            raise RuntimeError('scoped cold query timed out; retry within the current investigation')
        if process.returncode != 0:
            raise RuntimeError('scoped cold query failed: ' + stderr[-1500:])
        try:
            result = json.loads(stdout)
        except ValueError as error:
            raise RuntimeError('scoped cold query returned invalid output') from error
    coverage = result.get('coverage', {}) if isinstance(result, dict) else {}
    if coverage.get('capability') != SCOPED_VERSION or coverage.get('eligibility_stage') != 'pre_candidate' or \
            coverage.get('eligible_set_revision') != eligibility.revision or not isinstance(result.get('results'), list):
        raise RuntimeError('QMD did not prove the requested eligibility capability')
    return result
