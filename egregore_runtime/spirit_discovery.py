"""Read-only capability discovery. Local files and remote authority stay distinct."""
from __future__ import annotations
import hashlib
import http.client
import ipaddress
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone, timedelta
from urllib.parse import urlencode, urlsplit

RUNTIMES = ('claude', 'codex', 'pi', 'prime')
FACETS = ('declared', 'installed', 'exposed', 'permitted', 'operational', 'verified', 'adopted')
HASH = re.compile(r'^[a-f0-9]{64}$')
ID = re.compile(r'^[a-z][a-z0-9._/-]{0,159}$')
MAX_BYTES = 2_000_000
class DiscoveryError(ValueError):
    """Safe, stable error without provider or local path details."""

def canonical(value):
    try:
        return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False, allow_nan=False).encode('utf-8')
    except (ValueError, TypeError, UnicodeError, RecursionError):
        raise DiscoveryError('invalid-json') from None

def _text(value, maximum, *, blank=False):
    if not isinstance(value, str): return False
    try: size = len(value.encode('utf-8'))
    except UnicodeError: return False
    return size <= maximum and (blank or bool(value.strip())) and not any(ord(c) < 32 or ord(c) == 127 for c in value)

def _json_strings(value):
    pending = [(value, 0)]; count = 0
    while pending:
        item, depth = pending.pop(); count += 1
        if depth > 64 or count > 200000: raise DiscoveryError('invalid-json')
        if isinstance(item, str):
            try: item.encode('utf-8')
            except UnicodeError: raise DiscoveryError('invalid-json') from None
        elif isinstance(item, dict):
            pending.extend((part, depth + 1) for pair in item.items() for part in pair)
        elif isinstance(item, list): pending.extend((part, depth + 1) for part in item)

def _unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise DiscoveryError('invalid-json')
        result[key] = value
    return result

def parse_json(data):
    try:
        value = json.loads(data, object_pairs_hook=_unique, parse_constant=lambda _: (_ for _ in ()).throw(DiscoveryError('invalid-json')))
        _json_strings(value)
        return value
    except (ValueError, UnicodeError, TypeError, RecursionError):
        raise DiscoveryError('invalid-json') from None

def query_request(value):
    if not isinstance(value, dict):
        raise DiscoveryError('invalid-query')
    op = value.get('operation')
    fields = {'capabilities.list': {'operation'}, 'capabilities.find': {'operation', 'query'},
              'capabilities.describe': {'operation', 'id'}, 'capabilities.explain': {'operation', 'id'},
              'system.explain': {'operation', 'id'} if 'id' in value else {'operation'}}
    if not isinstance(op, str) or op not in fields or set(value) != fields[op]:
        raise DiscoveryError('invalid-query')
    for field, maximum in [('query', 200), ('id', 160)]:
        if field in value and not _text(value[field], maximum):
            raise DiscoveryError('invalid-query')
    return value

def _safe_relative(value):
    if not _text(value, 4096) or value.startswith('/') or '\\' in value:
        return False
    parts=value.split('/')
    denied={'.git','memory','.egregore','.spirit-workflow-state','tmp','node_modules','sessions','logs','auth.json','credentials.json','history.jsonl'}
    return all(part and part not in ('.','..') and part not in denied and not part.startswith('.env') for part in parts)

def _read(file, maximum=MAX_BYTES, private=False):
    # Descriptor-relative traversal prevents ancestor symlink/rename swaps from
    # redirecting later opens. Each child is opened while its parent FD is held.
    file = Path(os.path.abspath(file))
    parent = os.open(file.anchor, os.O_RDONLY | os.O_DIRECTORY)
    fd = None
    try:
        for part in file.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            os.close(parent); parent = child
        fd = os.open(file.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or st.st_size > maximum or private and (st.st_mode & 0o077):
            raise DiscoveryError('unreadable-evidence')
        data = os.read(fd, maximum + 1)
        if len(data) > maximum:
            raise DiscoveryError('unreadable-evidence')
        return data
    finally:
        if fd is not None: os.close(fd)
        os.close(parent)

def _json(file, maximum=MAX_BYTES, private=False):
    return parse_json(_read(file, maximum, private))

def _snapshot(root, runtime):
    raw = _read(root / 'bin' / 'data' / 'capabilities' / f'{runtime}.json')
    value = parse_json(raw)
    fields = {'schema', 'runtime', 'audience', 'provenance', 'items', 'files', 'digest'}
    if not isinstance(value, dict) or set(value) != fields or value['schema'] != 'egregore.capability-snapshot/v1' or value['runtime'] != runtime or value['audience'] != 'oss' or value['provenance'] != 'build-projection-unattested':
        raise DiscoveryError('invalid-snapshot')
    if not HASH.fullmatch(str(value['digest'])) or hashlib.sha256(canonical({k:v for k,v in value.items() if k != 'digest'})).hexdigest() != value['digest']:
        raise DiscoveryError('invalid-snapshot')
    if not isinstance(value['files'], list) or len(value['files']) > 4096 or not isinstance(value['items'], list) or len(value['items']) > 512:
        raise DiscoveryError('invalid-snapshot')
    files = {}
    for record in value['files']:
        if not isinstance(record, dict) or set(record) != {'path', 'sha256'} or not _safe_relative(record['path']) or not isinstance(record['sha256'], str) or not HASH.fullmatch(record['sha256']) or record['path'] in files:
            raise DiscoveryError('invalid-snapshot')
        files[record['path']] = record['sha256']
    ids = set()
    for item in value['items']:
        if not isinstance(item, dict) or set(item) != {'id', 'kind', 'summary', 'state_owner', 'requires', 'files', 'unmeasured_dependencies', 'contract', 'availability'} or not isinstance(item['id'], str) or not ID.fullmatch(item['id']) or item['id'] in ids or item['kind'] not in ('catalog-component','catalog-capability') or item['availability'] != 'oss' or item['contract'] != 'unknown':
            raise DiscoveryError('invalid-snapshot')
        for field in ('summary', 'state_owner'):
            if not _text(item[field], 8000):
                raise DiscoveryError('invalid-snapshot')
        if not isinstance(item['files'], list) or any(not isinstance(file, str) or file not in files for file in item['files']) or not isinstance(item['requires'], list) or not isinstance(item['unmeasured_dependencies'], list):
            raise DiscoveryError('invalid-snapshot')
        if len(item['files']) != len(set(item['files'])): raise DiscoveryError('invalid-snapshot')
        ids.add(item['id'])
    if any(not isinstance(dep, str) or dep not in ids for item in value['items'] for dep in item['requires'] + item['unmeasured_dependencies']):
        raise DiscoveryError('invalid-snapshot')
    value['_raw_sha256'] = hashlib.sha256(raw).hexdigest()
    return value

def _receipt_path(root, runtime):
    """Per-checkout receipt; never borrow the main checkout's receipt."""
    marker = root / '.git'
    if marker.exists():
        mode = marker.lstat().st_mode
        if stat.S_ISLNK(mode):
            raise DiscoveryError('unreadable-evidence')
        if stat.S_ISDIR(mode):
            return marker / 'info' / f'egregore-{runtime}-runtime.json'
        if not stat.S_ISREG(mode):
            raise DiscoveryError('unreadable-evidence')
        text = _read(marker, 4096).decode().strip()
        if not text.startswith('gitdir: '):
            raise DiscoveryError('unreadable-evidence')
        directory = Path(text[8:])
        if not directory.is_absolute(): directory = root / directory
        directory = directory.absolute()
        from .installation import installation_root
        main = installation_root(root)
        if main == root or directory.parent.parent != main / '.git' or directory.parent.name != 'worktrees':
            raise DiscoveryError('unreadable-evidence')
        # Reopen only the validated backlink path; _read rejects symlink traversal.
        backlink = _read(directory / 'gitdir', 4096).decode().strip()
        if Path(os.path.abspath(directory / backlink)) != marker:
            raise DiscoveryError('unreadable-evidence')
        return directory / 'info' / f'egregore-{runtime}-runtime.json'
    return root / '.egregore' / f'{runtime}-runtime-manifest.json'

def _receipt(root, runtime):
    data = _json(_receipt_path(root, runtime))
    if not isinstance(data, dict) or data.get('package') != 'create-egregore' or not isinstance(data.get('version'), str) or not isinstance(data.get('installedAt'), str) or not isinstance(data.get('files'), dict):
        raise DiscoveryError('invalid-installer-record')
    for name, record in data['files'].items():
        if not _safe_relative(name) or not isinstance(record, dict) or set(record) != {'hash'} or not isinstance(record['hash'], str) or not HASH.fullmatch(record['hash']):
            raise DiscoveryError('invalid-installer-record')
    return data

def _empty_view(kind, state, query, runtime=None):
    result = {'kind': kind, 'state': state, 'execution_authority': False, 'coverage': {'state': state, 'denominator': 'unknown'}}
    if runtime: result['runtime'] = runtime
    result['item' if query['operation'] in ('capabilities.describe','capabilities.explain','system.explain') else 'items'] = None if query['operation'] in ('capabilities.describe','capabilities.explain','system.explain') else []
    return result

def _select(items, query):
    if 'id' in query: return [item for item in items if item['id'] == query['id']]
    if query['operation'] == 'capabilities.find':
        words = query['query'].casefold().split()
        return [item for item in items if all(word in (item['id']+' '+item['summary']).casefold() for word in words)]
    return items

def local_view(root, runtime, query, at, until):
    if runtime is None:
        found = []; invalid = False
        for candidate in RUNTIMES:
            try: _snapshot(root, candidate); found.append(candidate)
            except FileNotFoundError: pass
            except (OSError, ValueError): invalid = True
        if len(found) != 1:
            return _empty_view('local-installed-snapshot', 'ambiguous' if found else 'unavailable' if invalid else 'unconfigured', query)
        runtime = found[0]
    try: snapshot = _snapshot(root, runtime)
    except FileNotFoundError: return _empty_view('local-installed-snapshot', 'unconfigured', query, runtime)
    except (OSError, ValueError): return _empty_view('local-installed-snapshot', 'unavailable', query, runtime)
    try: receipt = _receipt(root, runtime); receipt_state = 'local-installer-record'
    except FileNotFoundError: receipt = {'files': {}}; receipt_state = 'unrecorded'
    except (OSError, ValueError): receipt = {'files': {}}; receipt_state = 'unreadable'
    snapshot_path = f'bin/data/capabilities/{runtime}.json'
    try:
        actual_snapshot = snapshot['_raw_sha256']
        snapshot_record = receipt['files'].get(snapshot_path, {}).get('hash')
        snapshot_state = 'unreadable' if receipt_state == 'unreadable' else 'unrecorded' if snapshot_record is None else 'record-mismatch' if snapshot_record != actual_snapshot else 'recorded-and-matching'
    except (OSError, ValueError): snapshot_state = 'unreadable'
    observed = {}
    byte_budget = 16_000_000
    def file_state(relative):
        nonlocal byte_budget
        if relative not in observed:
            try:
                data = _read(root / relative, min(MAX_BYTES, max(byte_budget, 0)))
                byte_budget -= len(data)
                actual = hashlib.sha256(data).hexdigest()
                expected = next(file['sha256'] for file in snapshot['files'] if file['path'] == relative)
                recorded = receipt['files'].get(relative, {}).get('hash')
                observed[relative] = 'modified' if actual != expected else 'unreadable' if receipt_state == 'unreadable' else 'unrecorded' if recorded is None else 'record-mismatch' if recorded != actual else 'recorded-and-matching'
            except FileNotFoundError: observed[relative] = 'missing'
            except (OSError, ValueError): observed[relative] = 'unreadable'
        return observed[relative]
    def facet(state, source):
        return {'state': state, 'source': source, 'as_of': at, 'expires_at': until, 'subject_digest': snapshot['digest']}
    records=[]
    for item in _select(snapshot['items'], query):
        states = [file_state(name) for name in item['files']] + ([snapshot_state] if item['files'] else [])
        installed = next((state for state in ('unreadable','missing','modified','record-mismatch','unrecorded') if state in states), 'recorded-and-matching' if states else 'unsupported')
        if installed == 'recorded-and-matching' and item['unmeasured_dependencies']: installed = 'partial'
        facets = {name: facet('unknown', 'no current owner-bound evidence') for name in FACETS}
        facets['declared'] = facet('declared', 'audience-filtered build projection; publisher trust unverified')
        facets['installed'] = facet(installed, 'current checkout bytes joined to local installer ownership record; not authenticated release attestation')
        record = {k:item[k] for k in ('id','kind','summary','state_owner','requires','unmeasured_dependencies','contract')}
        record.update({'subject_digest':snapshot['digest'], 'execution_authority':False, 'callable_here':False, 'installation_scope':'enumerated delivered files; non-file dependencies unmeasured', 'facets':facets})
        if query['operation'] != 'capabilities.list':
            record['files'] = [{'path':name,'state':file_state(name)} for name in item['files']]
        records.append(record)
    view={'kind':'local-installed-snapshot','runtime':runtime,'state':'observed','scope':'current checkout; local installation evidence only', 'execution_authority':False,
          'coverage':{'state':'declared-snapshot-only','denominator':'unknown','registry':'unknown','installer_record':receipt_state,'snapshot_installer_record':snapshot_state,'max_observed_bytes':16000000,'source_map':'not-read','connect_overlay':'not-admitted','runtime_dependency_closure':'not-enumerated'}}
    if query['operation'] == 'system.explain':
        view['item'] = {'state_owner':'local installer ownership record and current checkout files','capabilities':records,'limitations':['registry and action permission are not inferred from installation','operational, evaluation and release adoption evidence are unknown']} if 'id' not in query or records else None
    elif query['operation'] in ('capabilities.describe','capabilities.explain'): view['item']=records[0] if records else None
    else: view['items']=records
    return view

def _identity(root):
    state = _json(root / '.egregore-state.json', 200000)
    config = _json(root / 'egregore.json', 200000)
    # A read cannot create an ephemeral identity via compatibility migrations.
    if not isinstance(state, dict) or any(not _text(state.get(key), 2000) or state[key] != state[key].strip() for key in ('account_id','actor_id','membership_id')):
        raise DiscoveryError('caller-unavailable')
    if not isinstance(config, dict) or not _text(config.get('org_id'),2000) or config['org_id'] != config['org_id'].strip():
        raise DiscoveryError('caller-unavailable')
    from .identity import LocalIdentityResolver
    from .installation import installation_key
    actor = LocalIdentityResolver(root, require_existing=True).resolve(session_id='discovery-read', harness='shell')
    if (actor.membership.status != 'active' or (state.get('membership_status') or 'active') != actor.membership.status or actor.account.account_id != state['account_id']
        or actor.actor.account_id != state['account_id'] or actor.actor.actor_id != state['actor_id']
        or actor.membership.actor_id != state['actor_id'] or actor.membership.membership_id != state['membership_id']
        or actor.membership.org_id != config['org_id'] or actor.profile.org_id != config['org_id']):
        raise DiscoveryError('caller-unavailable')
    return actor.profile.org_id, installation_key(root, existing_org_id=config['org_id']), actor.actor.actor_id

def _http_get_inner(origin, params, headers):
    url = urlsplit(origin)
    if url.username or url.password or url.path not in ('','/') or url.query or url.fragment or url.scheme not in ('http','https') or not url.hostname:
        raise DiscoveryError('invalid-binding')
    if url.scheme == 'http':
        try: loopback = ipaddress.ip_address(url.hostname).is_loopback
        except ValueError: loopback = False
        if not loopback: raise DiscoveryError('invalid-binding')
    connection = (http.client.HTTPSConnection if url.scheme == 'https' else http.client.HTTPConnection)(url.hostname, url.port, timeout=5)
    try:
        connection.request('GET', '/capabilities?' + urlencode(params), headers=headers)
        response=connection.getresponse()
        if response.status != 200: raise DiscoveryError('provider-unavailable')
        data=response.read(MAX_BYTES+1)
        if len(data)>MAX_BYTES: raise DiscoveryError('provider-unavailable')
        return parse_json(data)
    except (OSError, ValueError, http.client.HTTPException):
        raise DiscoveryError('provider-unavailable') from None
    finally: connection.close()

def _http_get(origin, params, headers):
    # One short-lived child gives DNS resolution and trickling response bodies a
    # true total lifetime bound. Secrets travel only on stdin, never argv/env.
    module_root = str(Path(__file__).absolute().parent.parent)
    env = {'PYTHONPATH': module_root, 'PYTHONSAFEPATH': '1', 'PYTHONDONTWRITEBYTECODE': '1'}
    process = subprocess.Popen([sys.executable, '-B', '-m', 'egregore_runtime.spirit_discovery_transport'],
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env)
    try:
        output, _ = process.communicate(canonical({'origin':origin,'params':params,'headers':headers}), timeout=7)
    except subprocess.TimeoutExpired:
        process.kill(); process.communicate()
        raise DiscoveryError('provider-unavailable') from None
    if process.returncode != 0 or len(output)>MAX_BYTES:
        raise DiscoveryError('provider-unavailable')
    return parse_json(output)

def _require(condition):
    if not condition: raise DiscoveryError('provider-unavailable')

def _exact(value, fields):
    return isinstance(value, dict) and set(value) == set(fields)

def _instant(value):
    _require(_text(value, 64) and re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})', value))
    result = datetime.fromisoformat(value.replace('Z', '+00:00'))
    _require(result.tzinfo is not None)
    return result

def _strings(value, maximum=64, *, limit=2000):
    _require(isinstance(value, list) and len(value) <= maximum and all(_text(item, limit) for item in value))
    _require(len(value) == len(set(value)))

def _native_schema(value):
    # Support standard JSON Schema vocabulary used by v1 contracts. Unknown
    # extensions are unavailable, never silently stripped or returned as data.
    _require(isinstance(value, dict) and len(canonical(value)) <= 16000)
    maps = {'properties', 'patternProperties', '$defs', 'definitions', 'dependentSchemas'}
    singles = {'additionalProperties', 'unevaluatedProperties', 'propertyNames', 'contains', 'not', 'if', 'then', 'else', 'unevaluatedItems', 'additionalItems', 'contentSchema'}
    arrays = {'allOf', 'anyOf', 'oneOf', 'prefixItems'}
    texts = {'$schema', '$id', '$anchor', '$dynamicAnchor', '$comment', 'title', 'description', 'format', 'pattern', 'contentEncoding', 'contentMediaType'}
    numbers = {'multipleOf', 'maximum', 'minimum', 'exclusiveMaximum', 'exclusiveMinimum'}
    sizes = {'minLength', 'maxLength', 'minItems', 'maxItems', 'minContains', 'maxContains', 'minProperties', 'maxProperties'}
    flags = {'uniqueItems', 'readOnly', 'writeOnly', 'deprecated'}
    known = maps | singles | arrays | texts | numbers | sizes | flags | {'type', 'enum', 'const', 'default', 'examples', 'required', 'dependentRequired', '$ref', '$dynamicRef', 'items'}
    pending = [(value, 0)]
    while pending:
        item, depth = pending.pop()
        _require(depth <= 32)
        if isinstance(item, bool): continue
        _require(isinstance(item, dict) and set(item) <= known)
        for key, part in item.items():
            if key in maps:
                _require(isinstance(part, dict) and len(part) <= 256 and all(_text(name, 500, blank=True) for name in part))
                pending.extend((schema, depth + 1) for schema in part.values())
            elif key in singles: pending.append((part, depth + 1))
            elif key in arrays or key == 'items' and isinstance(part, list):
                _require(isinstance(part, list) and 0 < len(part) <= 64)
                pending.extend((schema, depth + 1) for schema in part)
            elif key == 'items': pending.append((part, depth + 1))
            elif key in texts: _require(_text(part, 16000, blank=True))
            elif key in {'$ref', '$dynamicRef'}: _require(_text(part, 1000) and part.startswith('#/'))
            elif key in numbers:
                _require(type(part) in (int, float) and abs(part) < float('inf') and (key != 'multipleOf' or part > 0))
            elif key in sizes: _require(type(part) is int and part >= 0)
            elif key in flags: _require(type(part) is bool)
            elif key == 'type':
                types = [part] if isinstance(part, str) else part
                _strings(types, 7)
                _require(bool(types) and set(types) <= {'null', 'boolean', 'object', 'array', 'number', 'string', 'integer'})
            elif key == 'required': _strings(part, 256, limit=500)
            elif key == 'dependentRequired':
                _require(isinstance(part, dict) and len(part) <= 256 and all(_text(name, 500) for name in part))
                for names in part.values(): _strings(names, 256, limit=500)
            elif key == 'enum':
                _require(isinstance(part, list) and 0 < len(part) <= 256 and len({canonical(option) for option in part}) == len(part))
            elif key == 'examples': _require(isinstance(part, list) and len(part) <= 256)
            # const/default are JSON values, not provider metadata.

def _native_adoption(value):
    _require(_exact(value, ('state','provenance','source_check','authority')) and value['authority'] is False)
    _require(value['state'] in ('stale','not-adopted','unknown','local-unverified','source-bound'))
    _require(value['provenance'] in ('unknown','local-unverified','authenticated-github-service','simulated-github-service'))
    check = value['source_check']
    _require(_exact(check, ('state','checked_at','expires_at','scope','current_authority')))
    _require(check['state'] in ('unknown','not-checked','recorded-at-startup','expired') and check['scope'] == 'startup-only' and check['current_authority'] == 'unknown')
    if check['state'] in ('recorded-at-startup','expired'):
        _require(_instant(check['checked_at']) < _instant(check['expires_at']))
    else: _require(check['checked_at'] is None and check['expires_at'] is None)

def _native_generation(value):
    _require(isinstance(value, dict) and value.get('state') in ('off','enforced','drifted'))
    _require(_exact(value, ('state','draining','digest') if value['state'] == 'enforced' else ('state','draining')))
    _require(type(value['draining']) is bool)
    if 'digest' in value: _require(isinstance(value['digest'], str) and HASH.fullmatch(value['digest']))

def _native_bindings(value):
    _require(isinstance(value, list) and 0 < len(value) <= 64)
    seen = set()
    for binding in value:
        _require(_exact(binding, ('adapter','phase','exposed','permitted','callable_here')))
        _require(_text(binding['adapter'], 2000) and binding['adapter'] not in seen); seen.add(binding['adapter'])
        _require(binding['phase'] in ('unsupported','parent-admission','child-execution'))
        _require(binding['exposed'] in ('unsupported','unbound','bound','schema-mismatch','profile-unbound'))
        _require(binding['permitted'] in ('unsupported','allowed','unsupported-permissions','requires-direct-message','requires-parent-assistant','draining','requires-owned-running-child','evidence-stale'))
        _require(type(binding['callable_here']) is bool)
        if binding['callable_here']: _require(binding['phase'] != 'unsupported' and binding['exposed'] == 'bound' and binding['permitted'] == 'allowed')

def _native_facets(value, envelope, subject=None):
    states = {'declared':('declared','stale'), 'installed':('files-match','modified','missing','unreadable'),
              'exposed':('bound','unavailable'), 'permitted':('allowed-here','conditional-or-unavailable'),
              'operational':('unknown',), 'verified':('unknown',), 'adopted':('stale','not-adopted','unknown','local-unverified','source-bound')}
    _require(_exact(value, FACETS))
    for name, facet in value.items():
        _require(_exact(facet, ('state','source','as_of','expires_at','subject_digest')))
        _require(facet['state'] in states[name] and _text(facet['source'], 2000))
        _require(facet['as_of'] == envelope['as_of'] and facet['expires_at'] == envelope['expires_at'])
        _require(isinstance(facet['subject_digest'], str) and HASH.fullmatch(facet['subject_digest']))
        if subject is None: subject = facet['subject_digest']
        _require(facet['subject_digest'] == subject)

def _validate_native(response, query, now, remote_actor):
    _json_strings(response)
    _require(_exact(response, ('ok','binding','discovery')) and response['ok'] is True)
    witness = response['binding']
    _require(_exact(witness, ('schema','runtime_actor_id')) and witness['schema'] == 'egregore.discovery-caller/v1' and witness['runtime_actor_id'] == remote_actor)
    native = response['discovery']; op = query['operation'].removeprefix('capabilities.')
    collection = op in ('list','find')
    _require(_exact(native, ('schema','operation','as_of','expires_at','scope','execution_authority','items' if collection else 'item')))
    _require(native['schema'] == 'egregore.spirit-discovery/v1' and native['operation'] == op and native['execution_authority'] is False)
    _require(native['scope'] == 'current-actor; read-only local candidate selection')
    start, end = _instant(native['as_of']), _instant(native['expires_at'])
    _require(start <= now + timedelta(seconds=1) and end > now and timedelta(0) < end - start <= timedelta(seconds=30))
    if collection:
        records = native['items']; _require(isinstance(records, list))
    else:
        _require(native['item'] is None or isinstance(native['item'], dict))
        records = [native['item']] if native['item'] is not None else []
    if op == 'system.explain' and records:
        system = records[0]
        _require(_exact(system, ('state_owner','capabilities','coverage')) and system['state_owner'] == 'host registry, current transport grants and generation owner')
        _require(system['coverage'] == {'state':'current-caller-visible-contracts','denominator':'unknown','operational':'unknown','verified':'unknown','deployment_identity':'unknown'})
        records = system['capabilities']; _require(isinstance(records, list) and bool(records))
    _require(len(records) <= 32)
    seen = set()
    for record in records:
        fields = {'id','summary','source_adoption','generation','bindings','facets'}
        fields |= {'state_owners'} if op == 'system.explain' else {'subject_digest','trust','execution_authority','recipes'}
        if op in ('describe','explain'): fields |= {'limitations','input_schema','output_schema'}
        _require(_exact(record, fields))
        _require(_text(record['id'],160) and re.fullmatch(r'[a-z][a-z0-9.-]*(?:/[a-z][a-z0-9.-]*)?',record['id']) and record['id'] not in seen)
        seen.add(record['id']); _require('id' not in query or record['id'] == query['id'])
        _require(_text(record['summary'],2000))
        _native_adoption(record['source_adoption']); _native_generation(record['generation']); _native_bindings(record['bindings'])
        if op == 'system.explain':
            _strings(record['state_owners'],2)
            _require(set(record['state_owners']) == {'WorkStore owned job' if binding['phase'] == 'child-execution' else 'current transport grants' for binding in record['bindings']})
            _native_facets(record['facets'],native)
        else:
            _require(record['execution_authority'] is False and record['trust'] == 'local-candidate-untrusted')
            _require(isinstance(record['subject_digest'],str) and HASH.fullmatch(record['subject_digest']))
            _strings(record['recipes']); _native_facets(record['facets'],native,record['subject_digest'])
        _require(record['facets']['adopted']['state'] == record['source_adoption']['state'])
        if op in ('describe','explain'):
            _strings(record['limitations']); _native_schema(record['input_schema']); _native_schema(record['output_schema'])
    return native

def remote_view(root, query, now, environ=None):
    environ = os.environ if environ is None else environ
    file=root / '.egregore' / 'spirit-discovery' / 'binding.json'
    try: binding=_json(file,64000,private=True)
    except FileNotFoundError: return _empty_view('durable-authenticated','unconfigured',query)
    except (OSError, ValueError): return _empty_view('durable-authenticated','unavailable',query)
    try:
        fields={'schema','org_id','installation_key','actor_id','origin','remote_runtime_actor_id','bridge_token_env','actor_token_env'}
        if not isinstance(binding,dict) or set(binding)!=fields or binding['schema']!='egregore.discovery-binding/v1': raise DiscoveryError('invalid-binding')
        if not all(_text(binding[field], 4096) for field in fields - {'schema'}): raise DiscoveryError('invalid-binding')
        if _identity(root)!=(binding['org_id'],binding['installation_key'],binding['actor_id']): raise DiscoveryError('caller-unavailable')
        credentials=[]
        for key in ('bridge_token_env','actor_token_env'):
            if not isinstance(binding[key],str) or not re.fullmatch(r'[A-Z][A-Z0-9_]{0,79}',binding[key]): raise DiscoveryError('invalid-binding')
            value=environ.get(binding[key])
            if not isinstance(value,str) or not value or len(value)>4096 or any(ord(c)<33 or ord(c)>126 for c in value): raise DiscoveryError('caller-unavailable')
            credentials.append(value)
        op=query['operation'].removeprefix('capabilities.')
        response=_http_get(binding['origin'],{**query,'operation':op}, {'x-bridge-token':credentials[0],'x-actor-token':credentials[1]})
        native=_validate_native(response, query, now, binding['remote_runtime_actor_id'])
        return {'kind':'durable-authenticated','state':'observed','scope':'authenticated HTTP caller at fixed host; not local tool exposure',
                'execution_authority':False,'callable_here':False,'deployment_identity':'unknown','coverage':{'state':'provider-scoped','denominator':'unknown'},'native':native}
    except (OSError, ValueError, TypeError, KeyError, AttributeError, RecursionError):
        return _empty_view('durable-authenticated','unavailable',query)

def discover(root, request, *, runtime=None, now=None, environ=None):
    query=query_request(request)
    if runtime is not None and runtime not in RUNTIMES: raise DiscoveryError('invalid-adapter')
    root=Path(root).absolute()
    now=now or datetime.now(timezone.utc)
    at=now.isoformat(); until=(now+timedelta(seconds=30)).isoformat()
    return {'schema':'egregore.capability-query/v1','operation':query['operation'],'as_of':at,'expires_at':until,'execution_authority':False,
            'views':[local_view(root,runtime,query,at,until),remote_view(root,query,now,environ)]}
