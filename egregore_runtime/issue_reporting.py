"""Explicit framework reporting, with immutable private/public previews."""
from __future__ import annotations

import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import unicodedata
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import uuid4

from .contracts import Permission
from .github_issues import GitHubIssues, REPO
from .hosted_api import hosted_api_url
from .issue_markers import request_id
from .policy import allows, action_for

KINDS = {"bug", "improvement", "question"}
AREAS = {"runtime", "onboarding", "connectors", "site", "other"}
SEVERITIES = {"critical", "high", "normal"}
SUPPORT_STATES = {"filed", "failed", "submitting", "uncertain"}


def support_receipt(result, identifier):
    """Accept only a receipt for this request; filing never proves notification."""
    if (not isinstance(result, dict) or result.get('request_id') != identifier
        or not isinstance(result.get('submission_state'), str)
        or result['submission_state'] not in SUPPORT_STATES):
        raise ValueError(f"private support returned an invalid receipt; keep request {identifier} and use report-status")
    state = result['submission_state']
    notices = {
        'filed': 'Filed with Egregore support. Telegram delivery has not been verified.',
        'failed': 'Report preserved; support filing failed. Retry this same request.',
        'submitting': 'Report preserved; support filing is not confirmed. Keep this request ID and check report-status.',
        'uncertain': 'Report preserved; support filing needs reconciliation. Keep this request ID and check report-status.',
    }
    return {'request_id': identifier, 'submission_state': state,
            'retryable': state == 'failed',
            'reconciliation_needed': state in {'submitting', 'uncertain'},
            'notification_state': 'unverified', 'notice': notices[state]}


def _scrub(value, *, public=False):
    if not isinstance(value, str):
        raise ValueError("report text must be a string")
    value = ''.join(c for c in value if c in '\n\t' or unicodedata.category(c)[0] != 'C').strip()
    # Never automatically collect context. These conservative redactions cover
    # common secrets in explicitly supplied text; the exact preview remains the
    # human review boundary for content that a pattern cannot recognize.
    value = re.sub(r'\b(?:gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+|ek_[A-Za-z0-9_]+)\b', '[credential redacted]', value)
    value = re.sub(r'(?i)\bBearer\s+[A-Za-z0-9_.+/=-]+', 'Bearer [redacted]', value)
    if public:
        value = re.sub(r'(?:/Users/|/home/|[A-Za-z]:\\Users\\)[^\s\]\)<>]+', '[local path redacted]', value)
        value = re.sub(r'\b(?:actor|org|session)_[A-Za-z0-9_-]+\b', '[internal ID redacted]', value)
    if '<!-- egregore-' in value:
        raise ValueError("report text cannot contain reserved Egregore request markers")
    return value


def report_payload(title, description, kind='bug', area='other', severity='normal', *, public=False, environment=None, evidence=None):
    if kind not in KINDS or area not in AREAS or severity not in SEVERITIES:
        raise ValueError("invalid report kind, area or severity")
    title = ' '.join(_scrub(title, public=public).split())
    description = _scrub(description, public=public)
    for label, value in [('Environment',environment),('Evidence',evidence)]:
        if value:
            description += f'\n\n## {label}\n{_scrub(value, public=public)}'
    if not 1 <= len(title) <= 200 or not 1 <= len(description) <= 12000:
        raise ValueError("report needs a title (1–200 characters) and description (1–12000 characters)")
    return {'title':title, 'description':description, 'kind':kind, 'area':area, 'severity':severity}


def upstream_repo(config):
    value = config.get('upstream_url', 'https://github.com/egregore-labs/egregore')
    if value == 'none':
        raise ValueError("this instance has no upstream; use its internal issue tracker")
    if not isinstance(value, str):
        raise ValueError("upstream_url must be an HTTPS GitHub repository URL")
    match = re.fullmatch(r'https://github\.com/([^/]+/[^/]+?)(?:\.git)?/?', value)
    if not match or not REPO.fullmatch(match[1]) or any(c in value for c in '?#@%'):
        raise ValueError("upstream_url must be an unambiguous HTTPS GitHub repository URL")
    return match[1]


def support_destination(config):
    value = hosted_api_url(config.get('api_url') or '')
    parts = urlsplit(value)
    if (config.get('mode') != 'connected' and not config.get('api_url')) or not value:
        raise ValueError("private framework reports require Connected mode; explicitly choose upstream for a public report")
    if parts.scheme != 'https' or not parts.hostname or parts.username or parts.password or parts.query or parts.fragment:
        raise ValueError("private support requires a valid configured HTTPS API URL")
    return value


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def _support_credential(root):
    key = os.environ.get('EGREGORE_API_KEY', '').strip()
    if not key:
        env = Path(root) / '.env'
        if env.is_file():
            key = next((line.split('=',1)[1].strip().strip('\"\'') for line in env.read_text().splitlines() if line.startswith('EGREGORE_API_KEY=')), '')
    if not key:
        raise ValueError("private support credential is unavailable; reconnect this Egregore and retry the saved request")
    return key


def support_api(root, destination, endpoint, payload=None, *, credential):
    # The caller verifies this exact snapshot against /api/org/status. Never
    # reread environment or disk between identity verification and submission.
    request = Request(destination + endpoint, method='POST' if payload is not None else 'GET',
        data=json.dumps(payload).encode() if payload is not None else None,
        headers={'Authorization':f'Bearer {credential}', 'Content-Type':'application/json'})
    try:
        with build_opener(_NoRedirect()).open(request, timeout=45) as response:
            return response.status, json.loads(response.read())
    except HTTPError as exc:
        try:
            body = json.loads(exc.read())
        except ValueError:
            body = {}
        return exc.code, body
    except (OSError, URLError, ValueError):
        raise OSError("private support response unavailable; use report-status or confirm the same saved request") from None


class FrameworkReporting:
    def __init__(self, root, runtime, actor, *, api=support_api, github_factory=GitHubIssues, credential_loader=_support_credential):
        self.root, self.runtime, self.actor = Path(root), runtime, actor
        self.config = json.loads((self.root / 'egregore.json').read_text())
        self.api, self.github_factory = api, github_factory
        self.credential_loader = credential_loader

    def _authorize(self, destination, write=True):
        permissions = [Permission.DISCOVER, Permission.READ]
        if write:
            permissions += [Permission.WRITE, Permission.SHARE]
        for permission in permissions:
            decision = self.runtime.authorize(self.actor, permission, (destination,))
            if not decision.allowed or not allows(decision, 'memory/knowledge/issues/', action_for(decision.permission), root=self.runtime.canonical_root):
                raise PermissionError("framework report action or issue namespace scope denied")

    def _destination(self, route):
        destination = upstream_repo(self.config) if route == 'upstream' else support_destination(self.config)
        resource = f'github:{destination}:issues' if route == 'upstream' else 'support:egregore:reports'
        return destination, resource

    def _verified_credential(self, destination, expected_org):
        credential = self.credential_loader(self.root)
        code, identity = self.api(self.root,destination,'/api/org/status',credential=credential)
        authenticated_org = identity.get('org_id') if isinstance(identity,dict) else None
        if (code != 200 or not isinstance(authenticated_org,str) or not authenticated_org
            or authenticated_org != expected_org or authenticated_org != self.actor.profile.org_id):
            raise PermissionError("private support credential does not verify this organization's identity; reconnect and retry")
        return credential, authenticated_org

    @staticmethod
    def _digest(state):
        binding = {key:state[key] for key in ('actor','org','route','destination','payload','request_id')}
        if state['route'] == 'report':
            binding['authenticated_org'] = state.get('authenticated_org')
        return hashlib.sha256(json.dumps(binding, sort_keys=True, separators=(',',':')).encode()).hexdigest()

    def prepare(self, route, payload):
        destination, resource = self._destination(route)
        self._authorize(resource)
        state = {'actor':self.actor.actor.actor_id, 'org':self.actor.profile.org_id,
                 'route':route, 'destination':destination, 'payload':payload,
                 'request_id':str(uuid4()), 'status':'preview'}
        if route == 'report':
            _, state['authenticated_org'] = self._verified_credential(destination,state['org'])
        state['digest'] = self._digest(state)
        directory = self.root / '.egregore/runtime/issues/report-previews'
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        GitHubIssues._save(directory / f"{state['request_id']}.json", state)
        return self.preview(state)

    @staticmethod
    def preview(state):
        included = ['Title, description and selected classification']
        for label in ['Environment','Evidence']:
            if f'## {label}\n' in state['payload']['description']:
                included.append(f'{label} explicitly supplied in the report')
        included.append('Request ID' if state['route'] == 'upstream' else 'Request ID and organization-scoped routing marker')
        return {'included_with_report':included, 'request_id':state['request_id'], 'status':state['status'],
                'recipient':state['destination'] if state['route'] == 'upstream' else 'Egregore support',
                'visibility':'public' if state['route'] == 'upstream' else 'private',
                'report':state['payload'], 'notice':'No report submitted. Transcripts are excluded by default. Confirm this exact unchanged preview.'}

    def _load(self, route, identifier, *, write=True):
        identifier = request_id(identifier)
        path = self.root / f'.egregore/runtime/issues/report-previews/{identifier}.json'
        if not path.is_file():
            raise ValueError("report preview not found")
        state = json.loads(path.read_text())
        destination, resource = self._destination(route)
        self._authorize(resource, write=write)
        if (state['digest'] != self._digest(state) or state['route'] != route or state['destination'] != destination
            or state['actor'] != self.actor.actor.actor_id or state['org'] != self.actor.profile.org_id
            or (route == 'report' and state.get('authenticated_org') != state['org'])):
            raise PermissionError("report preview binding changed; prepare a new preview")
        return path, state

    def confirm(self, route, identifier):
        path, _ = self._load(route, identifier)
        with open(path.with_suffix('.lock'), 'a', opener=lambda p,f:os.open(p,f,0o600)) as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            path, state = self._load(route, identifier)
            if route == 'upstream':
                payload = state['payload']
                outgoing = {'title':payload['title'], 'body':payload['description'],
                    'labels':[f"kind:{payload['kind']}",f"area:{payload['area']}",f"severity:{payload['severity']}"]}
                service = self.github_factory(self.root, self.runtime, self.actor, state['destination'])
                try:
                    result = service.submit('create',outgoing,identifier)
                except ValueError as exc:
                    # No secrets/context are added, and the durable GitHub request
                    # keeps the no-blind-retry guarantee across CLI restarts.
                    raise ValueError(f"{exc}. If GitHub authentication is missing, run gh auth login and confirm this same request again") from None
                state['status'] = result['status']; GitHubIssues._save(path,state)
                return {'request_id':identifier,'status':result['status'],'github_url':result['github_url']}
            credential, _ = self._verified_credential(state['destination'],state['authenticated_org'])
            state['status'] = 'submitting'; GitHubIssues._save(path,state)
            try:
                code, result = self.api(self.root,state['destination'],'/api/v1/support-reports',
                    {'request_id':identifier, **state['payload']},credential=credential)
            except OSError:
                state['status'] = 'reconciliation_needed'; GitHubIssues._save(path,state)
                raise OSError(f"private support response unavailable; keep request {identifier} and use report-status or confirm this same preview") from None
            if not 200 <= code < 300:
                state['status'] = 'reconciliation_needed'; GitHubIssues._save(path,state)
                raise ValueError(f"private support request {identifier} needs recovery (HTTP {code}); use report-status or confirm this same preview")
            try:
                receipt = support_receipt(result, identifier)
            except ValueError:
                state['status'] = 'reconciliation_needed'; GitHubIssues._save(path,state)
                raise
            state['status'] = receipt['submission_state']; GitHubIssues._save(path,state)
            if state['status'] != 'filed':
                raise ValueError(f"private support request {identifier} needs recovery ({state['status']}); use report-status or confirm this same preview")
            return receipt

    def status(self, identifier):
        path, state = self._load('report',identifier,write=False)
        credential, _ = self._verified_credential(state['destination'],state['authenticated_org'])
        code, result = self.api(self.root,state['destination'],f'/api/v1/support-reports/{identifier}',credential=credential)
        if not 200 <= code < 300:
            raise ValueError(f"private support status unavailable (HTTP {code}); keep request {identifier}")
        return support_receipt(result, identifier)
