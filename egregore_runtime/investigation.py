"""Bounded, resumable organizational investigation owned by Egregore Runtime.

Discovery passes through Observe authorization and compilation; source windows
pass through Runtime.open_source. Harnesses supply operations, not storage access.
"""
from dataclasses import replace
from contextlib import contextmanager
import copy
import fcntl
import os
from datetime import UTC, date, datetime, timedelta
import hashlib
import json
from pathlib import Path
import re
import secrets
import time
from zoneinfo import ZoneInfo

from .contracts import RetrievalHit, RetrievalMode, RetrievalRequest, RetrievalResult
from .errors import AuthorizationDenied, EgregoreRuntimeError
from .eligibility import is_internal_event
from .excerpts import select_excerpt
from .identity import actor_lexical_formulations, resolve_actor_query
from .investigation_contracts import InvestigationRequest
from .policy import scope_allows_path

KINDS = {'hybrid':RetrievalMode.HYBRID, 'semantic':RetrievalMode.VEC, 'keyword':RetrievalMode.LEX}
STATE_VERSION = 'egregore-investigation/v1'
MAX_STATE_BYTES = 16_000_000
# A source batch must fit one native tool result, independently of the larger
# per-prompt evidence budget. Count encoded bytes, including JSON escaping, so
# non-ASCII sources and code do not multiply the payload unnoticed.
MAX_OPEN_BATCH_BYTES = 16_000


def state_path(root, episode_id):
    key = hashlib.sha256(str(episode_id).encode()).hexdigest()
    return Path(root) / '.egregore/runtime/investigations' / (key + '.json')


@contextmanager
def locked_state(root, episode_id):
    path = state_path(root, episode_id)
    if not path.parent.resolve().is_relative_to(Path(root).resolve()):
        raise AuthorizationDenied('investigation state must stay inside this instance')
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    if path.is_symlink():
        raise AuthorizationDenied('invalid investigation state path')
    descriptor = os.open(path.with_suffix('.lock'), os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
    with os.fdopen(descriptor, 'a') as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield path
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def reset(root, episode_id):
    directory = state_path(root, episode_id).parent
    if not directory.exists():
        return
    with locked_state(root, episode_id) as path:
        path.unlink(missing_ok=True)


def execute(runtime, actor, request, *, root, episode_id, seeds=(), initial_searches=0, initial_bounds=None,
            request_id=None, binding=None, origin='direct'):
    """Commit delivered evidence atomically under one prompt-scoped lock."""
    episode = Investigation(runtime, actor)
    episode._authorize()  # permission precedes reading retained organizational context
    if binding:
        binding.check(root, actor)
        episode.question = binding.question(root, actor)
    with locked_state(root, episode_id) as path:
        if path.exists():
            if path.stat().st_size > MAX_STATE_BYTES:
                raise EgregoreRuntimeError('Investigation state is too large; start a new prompt.')
            try:
                saved = json.loads(path.read_text(encoding='utf-8'))
                episode.restore(saved)
            except (ValueError, KeyError, TypeError) as error:
                raise EgregoreRuntimeError('Investigation state is unreadable; start a new prompt.') from error
        elif seeds:
            episode.seed(seeds, initial_searches, initial_bounds or {})
        episode._checkpoint = lambda: _save_state(path, episode.export())
        episode._binding_check = (lambda: binding.check(root, actor)) if binding else lambda: None
        episode._binding_check()  # a prompt can change while this call waits for the lock
        response = episode.dispatch(request, request_id=request_id, origin=origin)
        episode._checkpoint()
        response['episode_id'] = episode_id
        return response


def _save_state(path, value):
    encoded = json.dumps(value, ensure_ascii=False, separators=(',', ':'))
    if len(encoded.encode()) > MAX_STATE_BYTES:
        raise EgregoreRuntimeError('Investigation state limit reached; narrow the discovery scope.')
    temporary = path.with_suffix('.' + secrets.token_hex(8) + '.tmp')
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w', encoding='utf-8') as handle:
            handle.write(encoded + '\n')
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)

class LookupAdapter:
    """Deterministic canonical lookup and filters, behind Runtime authorization."""
    def __init__(self, original, kind, params, actor, admin_gate, *, question=''):
        self.original, self.kind, self.params = original, kind, params
        self.actor, self.admin_gate = actor, admin_gate
        self.question = question or params.get('query', '')
        self.last_result = None
        self.scanned = 0
        self.pool_bound = 128 if kind in KINDS else None

    def __getattr__(self, name):
        return getattr(self.original, name)

    def _day(self, value):
        return value.astimezone(ZoneInfo(self.params.get('timezone', 'UTC'))).date() if value else None

    def _date_query_match(self, path, content):
        """Filter a dated inventory by text, resolving an exact active-actor name.

        These are references, not proof of authorship. Authorization still runs
        before any content read. An arbitrary phrase remains a literal phrase;
        only a query equal to an actor identifier expands to its known aliases.
        """
        query = self.params.get('query', '').strip()
        references = actor_lexical_formulations(self.actor, self.actor.actor.actor_id, ())
        terms = references if query.casefold() in {term.casefold() for term in references} else (query,)
        for term in terms:
            pattern = re.compile(r'(?<!\w)' + re.escape(term) + r'(?!\w)', re.I)
            match = pattern.search(content)
            if match:
                return content[max(0, match.start()-100):match.end()+500]
            if pattern.search(path):
                return content[:600]
        return None

    def _matches(self, path, metadata):
        p = self.params
        day = self._day(metadata.observed_at)
        if p.get('_not_before') and (metadata.observed_at is None or metadata.observed_at < datetime.fromisoformat(p['_not_before'])):
            return False
        if p.get('after') and (day is None or day < date.fromisoformat(p['after'])):
            return False
        if p.get('before') and (day is None or day > date.fromisoformat(p['before'])):
            return False
        prefix = p.get('prefix')
        if prefix and not scope_allows_path(path, (prefix,)):
            return False
        if p.get('artifact_type') and metadata.artifact_type != p['artifact_type']:
            return False
        if self.kind == 'filename' and p['query'].casefold() not in path.casefold():
            return False
        return True

    def retrieve(self, request):
        return self._retrieve(request)

    def retrieve_authorized(self, request, *, actor, admin_gate=None, lifecycle=None):
        return self._retrieve(request, lifecycle=lifecycle)

    def _retrieve(self, request, *, lifecycle=None):
        started = time.monotonic()
        if self.kind in KINDS:
            lexical = actor_lexical_formulations(self.actor, request.task, request.lex)
            ranked_request = replace(request, top_k=self.params.get('_candidate_limit',128),
                mode=KINDS[self.kind], lex=lexical,
                vec=tuple(resolve_actor_query(self.actor, value) for value in request.vec),
                artifact_types=(self.params['artifact_type'],) if self.params.get('artifact_type') else request.artifact_types)
            scoped = getattr(self.original, 'retrieve_authorized', None)
            raw = (scoped(ranked_request, actor=self.actor, admin_gate=self.admin_gate, lifecycle=lifecycle,
                path_filter=lambda path: not self.params.get('prefix') or scope_allows_path(path, (self.params['prefix'],)),
                metadata_filter=self._matches) if callable(scoped) else self.original.retrieve(ranked_request))
            candidates = raw.hits
            self.last_result = raw
        else:
            candidates = []
            root = self.original.memory_root
            for path in sorted(root.rglob('*.md')):
                canonical = 'memory/' + path.relative_to(root).as_posix()
                # No metadata/content read outside the authorized canonical scope.
                if not scope_allows_path(canonical, request.authorized_scopes):
                    continue
                resolved = path.resolve()
                if not resolved.is_relative_to(root.resolve()):
                    continue
                if not scope_allows_path('memory/' + resolved.relative_to(root.resolve()).as_posix(), request.authorized_scopes):
                    continue
                # Path lookup and explicit scope do not need to inspect every document.
                if self.params.get('prefix') and not scope_allows_path(canonical, (self.params['prefix'],)):
                    continue
                if self.kind == 'filename' and self.params['query'].casefold() not in canonical.casefold():
                    continue
                if is_internal_event(canonical) and not self.params.get('artifact_type'):
                    continue
                metadata = self.original.describe_source(canonical)
                if is_internal_event(canonical, metadata.artifact_type) and not self.params.get('artifact_type'):
                    continue
                if request.allowed_artifact_ids and metadata.artifact_id not in request.allowed_artifact_ids:
                    continue
                if self.admin_gate and not self.admin_gate.actor_is_admin(self.actor) and self.admin_gate.path_is_admin(canonical):
                    continue
                self.scanned += 1
                if not self._matches(canonical, metadata):
                    continue
                passage = ''
                if self.kind == 'dates' and self.params.get('query', '').strip():
                    passage = self._date_query_match(canonical, resolved.read_text(encoding='utf-8'))
                    if passage is None:
                        continue
                if self.kind == 'literal':
                    content = resolved.read_text(encoding='utf-8')
                    index = content.casefold().find(self.params['query'].casefold())
                    if index < 0:
                        continue
                    passage = content[max(0,index-100):index+500]
                candidates.append(RetrievalHit(artifact_id=metadata.artifact_id, canonical_path=canonical,
                    rank=len(candidates)+1, score=1.0, retrieval_types=(RetrievalMode.LEX,),
                    passage=passage, revision=metadata.revision, content_hash=metadata.content_hash,
                    observed_at=metadata.observed_at))
            candidates.sort(key=lambda hit: (-(hit.observed_at.timestamp() if hit.observed_at else 0), hit.canonical_path))
        filtered = []
        for hit in candidates:
            if not scope_allows_path(hit.canonical_path, request.authorized_scopes):
                continue
            metadata = self.original.describe_source(hit.canonical_path)
            if metadata.observed_at is None and hit.observed_at is not None:
                metadata = replace(metadata, observed_at=hit.observed_at, date_provenance='lifecycle.created_at')
            if not self._matches(hit.canonical_path, metadata):
                continue
            # Stable, compact metadata plus a passage; no full-source dump.
            passage = hit.passage if self.params.get('_context_projection') else json.dumps({
                'title':metadata.title, 'document_date':str(self._day(metadata.observed_at)) if metadata.observed_at else None,
                'date_provenance':getattr(metadata, 'date_provenance', None),
                'artifact_type':metadata.artifact_type,
                'excerpt':select_excerpt(hit.passage or '', self.question)},ensure_ascii=False)
            filtered.append(replace(hit, rank=len(filtered)+1, passage=passage))
        source_revision = self.original.source_revision()
        result = RetrievalResult(request_id=request.request_id,
            mode=self.last_result.mode if self.last_result else request.mode,
            requested_mode=(self.last_result.requested_mode or request.mode) if self.last_result else request.mode,
            hits=tuple(filtered),
            index_spec_version=STATE_VERSION, index_revision=self.original.index_revision(),
            source_revision=source_revision, latency_ms=round((time.monotonic()-started)*1000),
            degraded=self.last_result.degraded if self.last_result else False,
            warnings=self.last_result.warnings if self.last_result else (),
            coverage=self.last_result.coverage if self.last_result else {},
            semantic_source_revision=self.last_result.semantic_source_revision if self.last_result else None)
        self.last_result = result
        return result

class Investigation:
    def __init__(self, runtime, actor, *, search_budget=8, open_budget=20, output_budget=120000):
        self.runtime, self.actor = runtime, actor
        self.search_budget, self.open_budget, self.output_budget = search_budget, open_budget, output_budget
        self.searches, self.opens, self.output_chars = 0,0,0
        self.seeded_searches = 0
        self.cache, self.cursors, self.ledger, self.opened = {},{},{},{}
        self.calls = []
        self.episode_signature = None
        self.as_of = datetime.now(UTC).isoformat()
        self.bounds = {}
        self.question = ''
        self.context_cache, self.request_receipts, self.deliveries = {}, {}, {}
        self._checkpoint = lambda: None
        self._binding_check = lambda: None
        self._active_request_id = None
        self._phase_ms = {}

    def export(self):
        return {'schema_version':STATE_VERSION, 'actor_id':self.actor.actor.actor_id,
            'org_id':self.actor.profile.org_id,
            **{key:getattr(self,key) for key in ['searches','opens','output_chars','cache','cursors','ledger','opened','episode_signature','as_of','bounds','context_cache','request_receipts','deliveries']},
            'calls':self.calls, 'seeded_searches':self.seeded_searches}

    def restore(self, saved):
        if saved['schema_version'] != STATE_VERSION or saved['actor_id'] != self.actor.actor.actor_id or saved['org_id'] != self.actor.profile.org_id:
            raise AuthorizationDenied('investigation belongs to a different actor or organization')
        for key in ['searches','opens','output_chars','cache','cursors','ledger','opened','calls','episode_signature','as_of','bounds']:
            setattr(self,key,saved[key])
        self.context_cache = saved.get('context_cache', {})
        self.request_receipts = saved.get('request_receipts', {})
        self.deliveries = saved.get('deliveries', {})
        # Older episodes retain attempt counts in call receipts but do not name
        # their imported searches. Those unaccounted searches came from seeds.
        accounted = sum(call.get('searches_spent', 1 if call.get('status') == 'started'
                                 and call.get('operation') == 'discover' else 0)
                        for call in saved['calls'])
        self.seeded_searches = saved.get('seeded_searches', max(0, saved['searches'] - accounted))
        self._authorize()

    def seed(self, contexts, searches, bounds):
        """Import already delivered prefetch evidence after current authorization."""
        revision = self._revision()
        self.bounds = {k:v for k,v in bounds.items() if v is not None}
        self.searches = min(self.search_budget, max(0, searches))
        self.seeded_searches = self.searches
        for context in contexts:
            if context.get('source_revision') != revision or context.get('actor_id') != self.actor.actor.actor_id or context.get('profile_revision') != self.actor.profile.revision:
                continue
            for evidence in context.get('evidence',[]):
                path, identifier = evidence.get('canonical_path'), evidence.get('artifact_id')
                if path and identifier and self._can_deliver(path,identifier):
                    self.ledger[path] = evidence.get('revision','unknown')

    def _can_deliver(self, path, artifact_id):
        from .contracts import Permission
        decision = self.runtime.authorize(self.actor, Permission.READ, (artifact_id,))
        if not decision.allowed or not scope_allows_path(path,decision.scopes):
            return False
        gate = self.runtime.admin_gate
        return not gate or gate.actor_is_admin(self.actor) or not gate.path_is_admin(path)

    def _authorize(self):
        started=time.monotonic()
        try:
            return self._authorize_impl()
        finally:
            self._phase_ms['authorization']=self._phase_ms.get('authorization',0)+round((time.monotonic()-started)*1000)

    def _authorize_impl(self):
        request = self._request('authorization', 'lex+vec', 1)
        decision = self.runtime.policy_factory(self.actor).authorize_observe(self.actor,request)
        if not decision.allowed:
            raise AuthorizationDenied('investigation requires current discover/read permission')
        signature = decision.to_dict()
        signature['profile_revision'] = self.actor.profile.revision
        signature['admin'] = self.runtime.admin_gate.actor_is_admin(self.actor) if self.runtime.admin_gate else False
        digest = hashlib.sha256(json.dumps(signature,sort_keys=True).encode()).hexdigest()
        if self.episode_signature is not None and self.episode_signature != digest:
            raise AuthorizationDenied('authorization changed; start a new investigation')
        self.episode_signature = digest
        return digest

    def _revision(self):
        started=time.monotonic()
        retriever = self.runtime.retriever
        try:
            return retriever.source_revision() if hasattr(retriever,'source_revision') else retriever.health().source_revision
        finally:
            self._phase_ms['revision_check']=self._phase_ms.get('revision_check',0)+round((time.monotonic()-started)*1000)

    def _index_revision(self):
        retriever = self.runtime.retriever
        return retriever.index_revision() if hasattr(retriever,'index_revision') else retriever.health().index_revision

    def context_discover(self, specification):
        """Preserve Observe selection/packaging while sharing investigation state."""
        if self.bounds.get('_legacy_terminal_gap'):
            raise ValueError('legacy evidence gap requires a new prompt')
        options = specification.context
        request = replace(options.retrieval, request_id=self._active_request_id)
        if request.actor_id != self.actor.actor.actor_id or request.org_id != self.actor.profile.org_id:
            raise AuthorizationDenied('request identity must match the resolved actor')
        if options.recent_days is not None:
            request = replace(request, not_before=datetime.fromisoformat(self.as_of)-timedelta(days=options.recent_days))
        if self.bounds.get('_not_before'):
            cutoff = datetime.fromisoformat(self.bounds['_not_before'])
            if request.not_before is not None and request.not_before < cutoff:
                raise ValueError('keep the episode date boundary; a new prompt starts a new scope')
            request = replace(request, not_before=cutoff if request.not_before is None else request.not_before)
        if request.not_before is not None and not self.bounds:
            self.bounds = {'_not_before':request.not_before.isoformat()}
        if options.minimum_evidence < self.bounds.get('_minimum_evidence', 1):
            raise ValueError('keep the episode minimum evidence requirement')
        if options.recent_days is not None and options.minimum_evidence > 1:
            self.bounds['_minimum_evidence'] = options.minimum_evidence
        signature = self._authorize()

        def key_for(source, index):
            fields = request.to_dict()
            fields.pop('request_id', None)
            fields.pop('open_sources', None)
            for name in ['task','lex','vec']:
                value = fields[name]
                fields[name] = ' '.join(value.split()).casefold() if isinstance(value,str) else [' '.join(v.split()).casefold() for v in value]
            return hashlib.sha256(json.dumps([fields,options.minimum_evidence,signature,source,index],sort_keys=True).encode()).hexdigest()

        key = key_for(self._revision(), self._index_revision())
        cached = self.context_cache.get(key)
        if cached and (not request.open_sources or cached['open_sources']):
            context = cached['context']
            self._check_context(context)
            return {'projection':'context', 'context':context, 'source_revision':context['source_revision'],
                    'reused':True, 'searches_remaining':self.search_budget-self.searches}
        if self.searches >= self.search_budget:
            raise ValueError('investigation search budget exhausted; report remaining gaps')
        if request.open_sources and request.top_k > self.open_budget-self.opens:
            raise ValueError('source read budget exhausted; request fewer sources')
        self.searches += 1
        self._checkpoint()  # an interrupted backend attempt must still spend its discovery
        started = time.monotonic()
        target = self.runtime
        if any(self.bounds.get(k) for k in ['after','before']):
            # Legacy calls made inside a dated investigation keep that same scope.
            # The unfiltered compatibility path retains its existing QMD settings.
            adapter = LookupAdapter(self.runtime.retriever,
                {RetrievalMode.LEX:'keyword',RetrievalMode.VEC:'semantic',RetrievalMode.HYBRID:'hybrid'}[request.mode],
                {**self.bounds, '_context_projection':True, '_candidate_limit':request.top_k},
                self.actor,self.runtime.admin_gate)
            target = replace(self.runtime,retriever=adapter)
        try:
            context = target.observe(self.actor,request,token_budget=options.token_budget).to_dict()
        finally:
            self._phase_ms['observe'] = round((time.monotonic()-started)*1000)
        self._check_context(context)
        if context.get('source_revision') != self._revision():
            raise ValueError('sources changed during discovery; retry the operation')
        if context.get('freshness',{}).get('index_revision') != self._index_revision():
            raise ValueError('index changed before delivery; retry the operation')
        for evidence in context.get('evidence',[]):
            self.ledger[evidence['canonical_path']] = evidence['revision']
            if request.open_sources:
                self.opened[evidence['canonical_path']] = evidence['revision']
                self.opens += 1
        key = key_for(context['source_revision'],context['freshness']['index_revision'])
        self.context_cache[key] = {'context':context,'open_sources':request.open_sources}
        return {'projection':'context', 'context':context, 'source_revision':context['source_revision'],
                'reused':False, 'searches_remaining':self.search_budget-self.searches}

    def _check_context(self, context):
        if context.get('actor_id') != self.actor.actor.actor_id or context.get('profile_revision') != self.actor.profile.revision:
            raise AuthorizationDenied('context belongs to another actor or profile revision')
        if context.get('policy_epoch') != self.runtime.policy_factory(self.actor).authorize_observe(
                self.actor,self._request('authorization','lex+vec',1)).policy_epoch:
            raise AuthorizationDenied('context authorization changed before delivery')
        if any(not self._can_deliver(item['canonical_path'],item['artifact_id']) for item in context.get('evidence',[])):
            raise AuthorizationDenied('evidence authorization changed; start a new investigation')

    def check_response(self, response):
        """Current policy and source checks shared by retries and private delivery."""
        self._authorize()
        if not response.get('ok'):
            return
        result=response['result']
        if result.get('source_revision') and result['source_revision'] != self._revision():
            raise ValueError('sources changed since this response; retry with a new request_id')
        if result.get('projection')=='context':
            self._check_context(result['context'])
            if result['context'].get('freshness',{}).get('index_revision') != self._index_revision():
                raise ValueError('index changed before delivery; retry with a new request_id')
        elif result.get('path'):
            metadata=self.runtime.retriever.describe_source(result['path'])
            if not self._can_deliver(result['path'],metadata.artifact_id):
                raise AuthorizationDenied('evidence authorization changed')
        elif result.get('sources'):
            for source in result['sources']:
                metadata = self.runtime.retriever.describe_source(source['path'])
                if not self._can_deliver(source['path'], metadata.artifact_id):
                    raise AuthorizationDenied('evidence authorization changed')
        elif any(not self._can_deliver(row['path'],row['artifact_id']) for row in result.get('results',[])):
            raise AuthorizationDenied('evidence authorization changed')
        for key in ['seen_sources','opened_sources']:
            for path in result.get(key,{}):
                metadata=self.runtime.retriever.describe_source(path)
                if not self._can_deliver(path,metadata.artifact_id):
                    raise AuthorizationDenied('retained evidence authorization changed')

    def _request(self, text, mode, limit):
        return RetrievalRequest(request_id='investigate-'+secrets.token_hex(8), org_id=self.actor.profile.org_id,
            actor_id=self.actor.actor.actor_id, task=text,lex=(text,),vec=(text,), mode=RetrievalMode(mode),top_k=limit,open_sources=False)

    def _validate(self, params):
        allowed={'kind','query','after','before','recent_days','timezone','prefix','artifact_type','limit','gap','cursor'}
        if set(params)-allowed:
            raise ValueError('unknown discovery fields: '+','.join(sorted(set(params)-allowed)))
        for key in ['kind','query','after','before','timezone','prefix','artifact_type','gap']:
            if key in params and not isinstance(params[key],str):
                raise ValueError(key+' must be a string')
        if len(params.get('query',''))>1000:
            raise ValueError('query exceeds 1000 characters')
        kind=params.get('kind','keyword')
        if kind not in {*KINDS,'filename','literal','dates'}:
            raise ValueError('unsupported operation')
        if kind!='dates' and not str(params.get('query','')).strip():
            raise ValueError('query is required for this operation')
        if kind=='dates' and not any(params.get(key) or self.bounds.get(key) for key in ['after','before','recent_days','_not_before']):
            raise ValueError('date lookup needs a date bound')
        ZoneInfo(params.get('timezone','UTC'))
        if 'recent_days' in params and (type(params['recent_days']) is not int or not 1 <= params['recent_days'] <= 36500):
            raise ValueError('recent_days must be between 1 and 36500')
        if params.get('recent_days') and params.get('after'):
            raise ValueError('use after or recent_days, not both')
        limit=params.get('limit',8)
        if type(limit) is not int or not 1<=limit<=20:
            raise ValueError('limit must be 1–20')
        for key in ['after','before']:
            if params.get(key): date.fromisoformat(params[key])
        if params.get('after') and params.get('before') and params['after']>params['before']:
            raise ValueError('after must not exceed before')
        if params.get('prefix') and (not params['prefix'].startswith('memory') or '\\' in params['prefix'] or not scope_allows_path(params['prefix'],('memory',))):
            raise ValueError('prefix must be a canonical memory path')
        return kind,limit

    def discover(self, **params):
        if self.bounds.get('_legacy_terminal_gap'):
            raise ValueError('legacy evidence gap requires a new prompt')
        signature = self._authorize()
        revision = self._revision()
        cursor=params.get('cursor')
        if cursor:
            if set(params)-{'cursor','gap'}:
                raise ValueError('a continuation uses only cursor and optional gap')
            if cursor not in self.cursors:
                raise ValueError('unknown continuation cursor')
            fingerprint,offset,limit,old_signature,old_revision=self.cursors[cursor]
            if (signature,revision)!=(old_signature,old_revision):
                raise AuthorizationDenied('continuation invalidated by source or authorization change')
        else:
            kind,limit=self._validate(params)
            params = dict(params)
            if any(params.get(key) for key in ['after','before','recent_days']):
                params.setdefault('timezone', self.bounds.get('timezone', 'UTC'))
            if params.get('recent_days'):
                params['_not_before'] = (datetime.fromisoformat(self.as_of)-timedelta(days=params['recent_days'])).isoformat()
            # The first request/prefetch fixes the temporal boundary for this prompt.
            # A missing field inherits it; a refinement cannot broaden it.
            for key in ['after','before','_not_before','timezone']:
                if key in self.bounds and key not in params:
                    params[key] = self.bounds[key]
            for key in ['after','_not_before']:
                if self.bounds.get(key) and params.get(key,'') < self.bounds[key]:
                    raise ValueError('keep the episode date boundary; a new prompt starts a new scope')
            if self.bounds.get('before') and params.get('before','') > self.bounds['before']:
                raise ValueError('keep the episode date boundary; a new prompt starts a new scope')
            if self.bounds.get('timezone') and params.get('timezone') != self.bounds['timezone']:
                raise ValueError('keep the episode timezone')
            if not self.bounds:
                self.bounds = {key:params[key] for key in ['after','before','_not_before','timezone'] if key in params}
            normalized={key:value for key,value in params.items() if key not in ['gap','cursor','limit']}
            normalized['kind']=kind
            fingerprint=hashlib.sha256(json.dumps([normalized,signature,revision],sort_keys=True).encode()).hexdigest()
            offset=0
            if fingerprint not in self.cache:
                if self.searches>=self.search_budget:
                    raise ValueError('investigation search budget exhausted; report remaining gaps')
                self.searches+=1
                self._checkpoint()
                adapter=LookupAdapter(self.runtime.retriever,kind,params,self.actor,self.runtime.admin_gate,
                                      question=self.question)
                facade=replace(self.runtime,retriever=adapter)
                request=self._request(str(params.get('query') or 'Documents within the requested date interval'),KINDS.get(kind,RetrievalMode.LEX).value,10000)
                started=time.monotonic()
                try:
                    context=facade.observe(self.actor,request,token_budget=2_000_000)
                finally:
                    self._phase_ms['observe'] = round((time.monotonic()-started)*1000)
                self._phase_ms['retrieve'] = adapter.last_result.latency_ms
                if self._revision() != revision:
                    raise ValueError('sources changed during discovery; retry the operation')
                rows=[]
                for evidence in context.evidence:
                    try:metadata=json.loads(evidence.content)
                    except json.JSONDecodeError:metadata={'excerpt':evidence.content}
                    rows.append({'path':evidence.canonical_path,'artifact_id':evidence.artifact_id,'revision':evidence.revision,**metadata})
                details = dict(adapter.last_result.coverage)
                if details:
                    self._phase_ms['eligibility'] = details.get('eligibility_ms', 0)
                    self._phase_ms.update({'qmd_'+key.removesuffix('_ms'): value for key,value in details.get('phases', {}).items()})
                self.cache[fingerprint]={'rows':rows,'kind':kind,'coverage':('bounded ranked results within the eligible set; not exhaustive' if details else 'bounded ranked candidate pool (up to 128)') if kind in KINDS else 'authorized canonical scan; compiled matches (up to 10000) at this revision',
                    'coverage_details':details,
                    'degraded':adapter.last_result.degraded,'warnings':list(adapter.last_result.warnings),'source_revision':context.source_revision,
                    'retrieval_seconds':adapter.last_result.latency_ms/1000,'scanned_authorized':adapter.scanned}
        cached=self.cache[fingerprint]
        rows=cached['rows'][offset:offset+limit]
        if any(not self._can_deliver(row['path'],row['artifact_id']) for row in rows):
            raise AuthorizationDenied('evidence authorization changed; start a new investigation')
        next_cursor=None
        def result_for(selected):
            return {'operation':cached['kind'],'results':selected,'next_cursor':'x'*24 if offset+len(selected)<len(cached['rows']) else None,'remaining_in_result_set':max(0,len(cached['rows'])-offset-len(selected)),
            'coverage':cached['coverage'],'source_revision':cached['source_revision'],'degraded':cached['degraded'],'warnings':cached['warnings'],
            **({'coverage_details':cached['coverage_details']} if cached.get('coverage_details') else {}),
            'searches_remaining':self.search_budget-self.searches,'previous_evidence_retained':len(self.ledger)+len(selected),
            'date_note':'Document dates are discovery signals, not proof of event dates; verify source content.'}
        while rows and len(json.dumps(result_for(rows),ensure_ascii=False)) > self.output_budget-self.output_chars-100:
            rows=rows[:-1]
        if not rows and offset<len(cached['rows']):
            raise ValueError('evidence output budget exhausted; report the remaining gap')
        if offset+len(rows)<len(cached['rows']):
            next_cursor=secrets.token_urlsafe(18)
            self.cursors[next_cursor]=(fingerprint,offset+len(rows),limit,signature,revision)
        for row in rows:self.ledger[row['path']]=row['revision']
        result=result_for(rows);result['next_cursor']=next_cursor;result['previous_evidence_retained']=len(self.ledger)
        return result

    def open(self, path, offset=0, length=16000):
        self._authorize()
        if not isinstance(path,str) or not path.startswith('memory/'):
            raise ValueError('open requires a canonical memory path')
        if self.opens>=self.open_budget:raise ValueError('source read budget exhausted')
        if type(offset) is not int or offset<0 or type(length) is not int or not 1<=length<=16000:
            raise ValueError('length must be 1–16000 characters and offset must be a nonnegative integer')
        if self.output_budget-self.output_chars < 600:
            raise ValueError('evidence output budget exhausted; report the remaining gap')
        # Runtime performs path, stable-id and admin authorization on every read.
        revision=self._revision()
        started=time.monotonic()
        try:
            content=self.runtime.open_source(self.actor,path)
        finally:
            self._phase_ms['source_read'] = round((time.monotonic()-started)*1000)
        if self._revision() != revision:
            raise ValueError('sources changed during read; retry the operation')
        self.opens+=1
        self.opened[path]=revision
        result={'path':path,'source_revision':revision,'offset':offset,'content':content[offset:offset+length],
            'next_offset':offset+length if offset+length<len(content) else None,'reads_remaining':self.open_budget-self.opens}
        while len(json.dumps(result,ensure_ascii=False))>self.output_budget-self.output_chars-100 and result['content']:
            result['content']=result['content'][:len(result['content'])//2]
            result['next_offset']=offset+len(result['content'])
        return result

    def open_many(self, paths, offset=0, length=16000):
        # One invocation, with the same authorization and revision fence for
        # every source. dispatch rolls back the entire batch on any failure.
        paths = list(dict.fromkeys(paths))
        if self.opens + len(paths) > self.open_budget:
            raise ValueError('source read budget exhausted')
        if type(offset) is not int or offset < 0 or type(length) is not int or not 1 <= length <= 16000:
            raise ValueError('length must be 1–16000 characters and offset must be a nonnegative integer')
        sources = []
        initial_chars = self.output_chars
        batch_bytes = 0
        revision = self._revision()
        started = time.monotonic()
        try:
            for index, path in enumerate(paths):
                # Share both the prompt budget and this tool-result budget.
                # Short sources leave their unused share for the next source.
                remaining = len(paths)-index
                allowance = min(
                    (self.output_budget-self.output_chars-1000)//remaining-500,
                    (MAX_OPEN_BATCH_BYTES-batch_bytes-1000)//remaining-500,
                )
                if allowance < 1:
                    raise ValueError('evidence output budget exhausted')
                source = self.open(path, offset, min(length, allowance))
                content, next_offset = source['content'], source['next_offset']
                # Fit the serialized source, not an estimated characters/token
                # ratio. Offsets always remain offsets into the original text.
                low, high = 0, len(content)
                while low < high:
                    middle = (low+high+1)//2
                    source['content'] = content[:middle]
                    source['next_offset'] = offset+middle if middle<len(content) else next_offset
                    if len(json.dumps(source, ensure_ascii=False).encode('utf-8')) <= allowance:
                        low = middle
                    else:
                        high = middle-1
                source['content'] = content[:low]
                source['next_offset'] = offset+low if low<len(content) else next_offset
                encoded = json.dumps(source, ensure_ascii=False)
                if len(encoded.encode('utf-8')) > allowance or (content and low == 0):
                    raise ValueError('source metadata exceeds batch budget; open fewer sources together')
                sources.append(source)
                self.output_chars += len(encoded)
                batch_bytes += len(encoded.encode('utf-8'))
        finally:
            # dispatch accounts for the complete response exactly once.
            self.output_chars = initial_chars
            self._phase_ms['source_read'] = round((time.monotonic()-started)*1000)
        if self._revision() != revision:
            raise ValueError('sources changed during read; retry the operation')
        return {'operation':'open_many', 'sources':sources, 'source_revision':revision,
                'reads_remaining':self.open_budget-self.opens}

    def visible_source_history(self, sources):
        """Recheck document-level read gates before returning retained paths."""
        visible = {}
        for path, revision in sources.items():
            try:
                metadata = self.runtime.retriever.describe_source(path)
                if self._can_deliver(path, metadata.artifact_id):
                    visible[path] = revision
            except FileNotFoundError:
                continue
        return visible

    def dispatch(self, request, *, request_id=None, origin='direct'):
        started=time.monotonic()
        request_id=request_id or 'inv-'+secrets.token_hex(12)
        if not isinstance(request_id,str) or not 1<=len(request_id)<=200:
            raise ValueError('request_id must be a nonempty string of at most 200 characters')
        self._active_request_id=request_id
        self._phase_ms={}
        previous=copy.deepcopy(self.export())
        request_hash=None
        cached=None
        invocation_id='call-'+secrets.token_hex(12)
        event={'invocation_id':invocation_id,'request_id':request_id,'operation':'invalid','origin':origin,'status':'started'}
        try:
            if len(self.calls)>=50:raise ValueError('tool-call ceiling reached')
            if self.output_chars>=self.output_budget:raise ValueError('evidence output budget exhausted')
            self._binding_check()
            typed=InvestigationRequest.parse(request)
            operation=typed.operation
            event['operation']=operation
            event['projection']='context' if typed.context else 'discovery'
            if operation=='discover':
                event['kind']=typed.context.retrieval.mode.value if typed.context else typed.parameters.get('kind','keyword')
            normalized=typed.to_dict()
            if typed.context:
                normalized['context_projection']['retrieval'].pop('request_id',None)
                if typed.context.recent_days is not None:
                    normalized['context_projection']['retrieval']['not_before']={'recent_days':typed.context.recent_days}
            request_hash=hashlib.sha256(json.dumps(normalized,sort_keys=True).encode()).hexdigest()
            cached=self.request_receipts.get(request_id)
            if cached and cached['hash'] != request_hash:
                raise ValueError('request_id was already used with different arguments')
            self.calls.append(event)
            if cached is None:
                self.request_receipts[request_id]={'hash':request_hash,'status':'started'}
            self._checkpoint()
            if cached:
                if cached['status'] != 'ready':
                    raise ValueError('previous request was interrupted; use a new request_id to retry within this episode')
                self._authorize()
                if cached.get('source_revision') and cached['source_revision'] != self._revision():
                    raise ValueError('sources changed since this response; retry with a new request_id')
                response=copy.deepcopy(cached['response'])
                if not response['ok']:
                    result=None
                else:
                    result=response['result']
                    self.check_response(response)
                event['reused']=True
            elif operation=='discover':result=self.context_discover(typed) if typed.context else self.discover(**typed.parameters)
            elif operation=='open':result=self.open(**typed.parameters)
            elif operation=='open_many':result=self.open_many(**typed.parameters)
            elif operation=='status':
                self._authorize();result={'seen_sources':self.visible_source_history(self.ledger),'opened_sources':self.visible_source_history(self.opened),'searches_remaining':self.search_budget-self.searches,'reads_remaining':self.open_budget-self.opens,'characters_remaining':self.output_budget-self.output_chars}
            encoded=json.dumps(result,ensure_ascii=False) if not cached or response['ok'] else ''
            if self.output_chars+len(encoded)>self.output_budget:raise ValueError('evidence output budget would be exceeded; request a smaller page or source window')
            self._authorize()  # do not deliver evidence under a grant changed mid-operation
            self._binding_check()
            if result and result.get('source_revision') and result['source_revision'] != self._revision():
                raise ValueError('sources changed before delivery; retry the operation')
            self.output_chars+=len(encoded)
            if not cached or result is not None:
                response={'ok':True,'result':result}
        except (ValueError,TypeError,KeyError,EgregoreRuntimeError,OSError,RuntimeError) as error:
            # Failed delivery must not mark a source as read or advance a cursor.
            # Search attempts still consume budget; every attempt consumes a call.
            attempts=self.searches
            attempted_bounds=copy.deepcopy(self.bounds)
            for key in ['searches','opens','output_chars','cache','cursors','ledger','opened','context_cache','episode_signature','as_of','bounds']:
                setattr(self,key,previous[key])
            self.searches=max(self.searches,attempts)
            if attempts > previous['searches']:
                # Starting discovery fixes its date/minimum-evidence scope even
                # when the backend fails. Recovery cannot broaden that scope.
                self.bounds=attempted_bounds
            message=str(error)
            code=('not_authorized' if isinstance(error,AuthorizationDenied) else
                  'episode_closed' if 'episode closed' in message else
                  'binding_required' if 'episode' in message and 'reference' in message else
                  'budget_exhausted' if 'budget' in message or 'ceiling' in message else
                  'request_conflict' if 'different arguments' in message else
                  'request_interrupted' if 'interrupted' in message else
                  'source_changed' if 'sources changed' in message or 'index changed' in message else
                  'not_found_or_denied' if isinstance(error,FileNotFoundError) else
                  'runtime_error' if isinstance(error,EgregoreRuntimeError) else
                  'backend_error' if isinstance(error,(RuntimeError,OSError)) else 'invalid_request')
            response={'ok':False,'error':message,'error_code':code}
        response['request_id']=request_id
        response['invocation_id']=invocation_id
        response['replayed']=bool(cached and event.get('reused'))
        response['status']='ok' if response['ok'] else 'error'
        if response['ok'] and response.get('result',{}).get('results') == []:
            response['status']='empty'
        event.update(ok=response['ok'],status='response_ready',seconds=round(time.monotonic()-started,3),
                     phase_ms=dict(self._phase_ms),new_sources=max(0,len(self.ledger)-len(previous['ledger'])),
                     new_reads=max(0,len(self.opened)-len(previous['opened'])),
                     returned_characters=len(json.dumps(response,ensure_ascii=False)),
                     evidence_characters=max(0,self.output_chars-previous['output_chars']),
                     searches_spent=self.searches-previous['searches'],
                     reads_spent=self.opens-previous['opens'],
                     model_usage=None,
                     error_code=response.get('error_code'))
        if len(self.calls)<50 and not any(item is event for item in self.calls):
            self.calls.append(event)
        if request_hash and cached is None:
            self.request_receipts[request_id]={'hash':request_hash,'status':'ready',
                'source_revision':response.get('result',{}).get('source_revision'),
                'response':copy.deepcopy(response)}
        return response
