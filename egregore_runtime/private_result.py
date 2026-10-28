"""One-shot native result delivery tied to an exact Runtime invocation.

No shared session-named packet: parallel tool calls return distinct opaque
receipts in their own stdout, which PostToolUse consumes with current authority.
"""
from __future__ import annotations

import json
import hashlib
import os
from pathlib import Path
import re
import secrets

from . import episode_binding
from .errors import EgregoreRuntimeError
from .investigation import Investigation, locked_state, _save_state

MARKER = 'EGREGORE_RUNTIME_PACKET='
MAX_BYTES = 1_000_000


def supports_attachment(root, episode_id, harness):
    """Only Claude has a consumer for the opaque PostToolUse receipt.

    A native prompt binding is stronger than inherited launcher environment or
    a shell default. Its conversation key already binds the harness and session;
    use that exact record, never the newest conversation in the directory.
    Unknown/unbound shells keep ordinary stdout so evidence cannot disappear.
    """
    if episode_id.startswith('ep_'):
        binding = episode_binding.resolve(root, episode_id)
        claude_key = hashlib.sha256(f'claude:{binding.session_id}'.encode()).hexdigest()
        return binding.conversation_key == claude_key
    return harness == 'claude'


def _path(root, identifier):
    if not re.fullmatch(r'[a-f0-9]{32}',identifier):
        raise ValueError('invalid private receipt')
    directory=Path(root)/'.egregore/runtime/result-packets'
    if not directory.resolve().is_relative_to(Path(root).resolve()):
        raise ValueError('private packets must remain in this instance')
    directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    os.chmod(directory,0o700)
    return directory/(identifier+'.json')


def prepare(root, response, rendered, session_id):
    identifier=secrets.token_hex(16)
    packet={'session_id':session_id,'response':response,'rendered':rendered}
    encoded=json.dumps(packet,ensure_ascii=False)
    if len(encoded.encode())>MAX_BYTES:
        raise EgregoreRuntimeError('private result exceeds its delivery limit')
    path=_path(root,identifier)
    descriptor=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    with os.fdopen(descriptor,'w',encoding='utf-8') as handle:
        handle.write(encoded)
    try:
        with locked_state(root,response['episode_id']) as state_file:
            state=json.loads(state_file.read_text())
            if not any(call.get('invocation_id')==response['invocation_id'] for call in state['calls']):
                raise EgregoreRuntimeError('private result has no recorded Runtime invocation')
            for call in state['calls']:
                if call.get('invocation_id')==response['invocation_id']:
                    call['delivery']='packet_ready'
                    call['rendered_characters']=len(rendered)
            state.setdefault('deliveries',{})[identifier]={
                'request_id':response['request_id'],'invocation_id':response['invocation_id'],'sha256':hashlib.sha256(encoded.encode()).hexdigest(),
                'status':'packet_ready'}
            _save_state(state_file,state)
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return MARKER+json.dumps({'id':identifier,'root':str(Path(root).resolve())},separators=(',',':'))


def receipts_from_tool(payload):
    response=payload.get('tool_response',{})
    stdout=response.get('stdout','') if isinstance(response,dict) else str(response)
    matches=[]
    for line in stdout.splitlines():
        if line.startswith(MARKER):
            value=json.loads(line[len(MARKER):])
            if isinstance(value,dict):
                matches.append(value)
    return matches


def allowed_root(project_root, supplied):
    root=Path(supplied).resolve()
    project=Path(project_root).resolve()
    instance=Path(str(project).split('/.claude/worktrees/',1)[0])
    if root!=project and not root.is_relative_to(instance/'.claude/worktrees'):
        raise EgregoreRuntimeError('private receipt belongs to another Runtime root')
    return root


def consume(root, identifier, runtime, actor, *, session_id, native_turn_id=None):
    validator=Investigation(runtime,actor)
    validator._authorize()  # precedes opening retained evidence
    path=_path(root,identifier)
    if path.is_symlink() or not path.is_file() or path.stat().st_size>MAX_BYTES:
        raise EgregoreRuntimeError('private receipt is unavailable')
    encoded=path.read_text(encoding='utf-8')
    packet=json.loads(encoded)
    if packet.get('session_id')!=session_id:
        raise EgregoreRuntimeError('private receipt belongs to another native session')
    response=packet['response']
    episode_id=response['episode_id']
    binding=episode_binding.resolve(root,episode_id) if episode_id.startswith('ep_') else None
    if binding:
        binding.check(root,actor)
        if native_turn_id and binding.native_turn_id and native_turn_id != binding.native_turn_id:
            raise EgregoreRuntimeError('private receipt belongs to another native prompt')
    elif episode_binding.requires_binding(root):
        raise EgregoreRuntimeError('private receipt has no native prompt binding')
    validator.check_response(response)
    with locked_state(root,episode_id) as state_file:
        state=json.loads(state_file.read_text())
        validator.restore(state)
        if binding:
            binding.check(root,actor)
        validator.check_response(response)
        receipt=state.get('deliveries',{}).get(identifier)
        if not receipt or receipt.get('status')!='packet_ready' or receipt.get('sha256')!=hashlib.sha256(encoded.encode()).hexdigest():
            raise EgregoreRuntimeError('private response has no completed Runtime invocation')
        for call in state['calls']:
            if call.get('invocation_id')==response['invocation_id']:
                call['delivery']='attachment_prepared'
                call['rendered_characters']=len(packet['rendered'])
        receipt['status']='attachment_prepared'
        _save_state(state_file,state)
        path.unlink()
    return packet['rendered']


def record_stdout(root, response, rendered):
    """Record presentation size, without claiming the host received stdout."""
    with locked_state(root,response['episode_id']) as state_file:
        state=json.loads(state_file.read_text())
        for call in state['calls']:
            if call.get('invocation_id')==response['invocation_id']:
                call['delivery']='stdout_prepared'
                call['rendered_characters']=len(rendered)
                _save_state(state_file,state)
                break
