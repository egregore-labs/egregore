#!/usr/bin/env bash
# Behavioral lifecycle coverage; every writer uses a disposable memory repository.
# About 3.5 minutes on a laptop; past the 300 s default on CI's one-CPU runners.
# test-baseline: timeout=600
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/tmp"
python3 - "$ROOT" <<'PY'
import contextlib
from datetime import datetime, timezone, timedelta
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import shlex
import subprocess
import sys
import tempfile
import time

ROOT = Path(sys.argv[1])
PASSED = FAILED = 0
sys.path.insert(0, str(ROOT / 'bin/lib'))
import session_trail as st
import session_record as sr

FAKE = r'''#!/usr/bin/env python3
import json, os, sys, time
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['FAKE_CALLS'], 'a') as f: f.write(json.dumps(args) + '\n')
if '--version' in args:
    if os.environ.get('FAKE_TOUCH_ON_VERSION'): Path(os.environ['FAKE_TOUCH_ON_VERSION']).touch()
    print('fake-' + os.environ.get('FAKE_VERSION', '1')); sys.exit(0)
if '--help' in args:
    print('--tools --mcp-config --setting-sources --model --output-format ' + ('' if os.environ.get('FAKE_MISSING') else '--strict-mcp-config')); sys.exit(0)
required = ['--tools','--strict-mcp-config','--mcp-config','--setting-sources','--model','--output-format']
if any(flag not in args for flag in required): sys.exit(99)
if '--max-turns' in args: sys.exit(99)
if args[args.index('--tools')+1] != '' or args[args.index('--setting-sources')+1] != '': sys.exit(99)
if json.loads(args[args.index('--mcp-config')+1]) != {'mcpServers':{}}: sys.exit(99)
if any(key in os.environ for key in ['CLAUDECODE','CLAUDE_CODE_ENTRYPOINT','NODE_OPTIONS','TRACEPARENT']): sys.exit(99)
if Path.cwd() == Path(os.environ['FIXTURE_ROOT']) or list(Path.cwd().iterdir()): sys.exit(99)
with open(os.environ['FAKE_PIDS'], 'a') as f: f.write(str(os.getpid())+'\n')
trail = sys.stdin.read()
Path(os.environ['FAKE_INPUT']).write_text(trail)
time.sleep(float(os.environ.get('FAKE_SLEEP','0')))
if os.environ.get('FAKE_EXIT'): sys.exit(int(os.environ['FAKE_EXIT']))
print(Path(os.environ['FAKE_OUTPUT']).read_text())
with open(os.environ['FAKE_EXITS'], 'a') as f: f.write(str(os.getpid())+'\n')
'''

class Fixture:
    def __init__(self):
        self.temp = Path(tempfile.mkdtemp(prefix='session-record-', dir=ROOT/'tmp'))
        self.root = self.temp/'project'
        self.home = self.temp/'home'
        self.memory = self.temp/'memory'
        self.fake = self.temp/'fake-bin'
        for p in (self.root/'bin/lib', self.home, self.memory, self.fake, self.temp/'scratch'):
            p.mkdir(parents=True)
        for name in ('session-record.sh','records.sh','capture-run.sh','session-log.sh'):
            shutil.copy(ROOT/'bin'/name, self.root/'bin'/name)
        for name in ('config.sh','session_trail.py','session_record.py','session-record-prompt.txt'):
            shutil.copy(ROOT/'bin/lib'/name, self.root/'bin/lib'/name)
        # Real publication dependency, with an explicit fixture-host transport
        # selection. All history/ref/ack checks run; no production environment
        # switch or raw-push fallback is introduced for local test remotes.
        shutil.copytree(ROOT/'egregore_runtime', self.root/'egregore_runtime',
                        ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        fixture_guard=self.root/'egregore_runtime/memory_push.py'
        with fixture_guard.open('a') as handle:
            handle.write('\n_fixture_push_memory = push_memory\n'
                         'def push_memory(repository, **kwargs):\n'
                         '    kwargs["allow_local_transport"] = True\n'
                         '    return _fixture_push_memory(repository, **kwargs)\n')
        (self.root/'memory').symlink_to(self.memory, target_is_directory=True)
        self.env = {k:v for k,v in os.environ.items() if not k.startswith(('GIT_', 'EGREGORE_', 'CLAUDE_', 'CODEX_', 'FAKE_')) and k not in ('CLAUDECODE','NODE_OPTIONS','TRACEPARENT')}
        self.env.update(HOME=str(self.home), TMPDIR=str(self.root), PATH=str(self.fake)+os.pathsep+os.environ['PATH'],
                        FIXTURE_ROOT=str(self.root), EGREGORE_NO_TELEMETRY='1', EGREGORE_RECORD_NO_PROJECT_GIT='1', CLAUDECODE='1', CLAUDE_CODE_ENTRYPOINT='cli', NODE_OPTIONS='--trace-warnings', TRACEPARENT='test')
        # No real service can be invoked by a fixture.
        for exe in ('gh','curl','wget','ssh'):
            (self.fake/exe).write_text('#!/bin/sh\nexit 99\n'); (self.fake/exe).chmod(0o755)
        (self.fake/'claude').write_text(FAKE); (self.fake/'claude').chmod(0o755)
        for key in ('CALLS','PIDS','INPUT','OUTPUT','EXITS'):
            self.env['FAKE_'+key] = str(self.temp/key.lower())
        Path(self.env['FAKE_OUTPUT']).write_text('## Asked\n- Improve checkpoint reliability\n## Decided\n- Keep the durable lock — cem, 10:01\n## Open\n- Check recovery — cem\n## Risks\n- Coordination needs care\n## Friction\nRepeated waits slowed the work\n')
        self.config = {'base_branch':'develop','mode':'local','features':{'session_records':{'enabled':True,'model':'haiku','default_detail':'outline','retroactive_days':90}}}
        self.state = {'github_username':'cem','display_name':'Cem'}
        self.save()
        self.prefix = st.instance_prefix(self.root)
        self.folder = self.home/'.claude/projects'/self.prefix
        self.folder.mkdir(parents=True)
        self.base = self.home/'.egregore/trails'/self.prefix
        self.git('init','-q')
        self.git('config','user.name','Fixture')
        self.git('config','user.email','fixture@example.invalid')
        (self.memory/'seed').write_text('fixture\n')
        self.git('add','seed'); self.git('commit','-qm','fixture seed')
        self.prompt = 'Please repair the durable checkpoint'
        self.path = self.transcript('session-one')
    def save(self):
        (self.root/'egregore.json').write_text(json.dumps(self.config))
        (self.root/'.egregore-state.json').write_text(json.dumps(self.state))
    def git(self,*args):
        env = {k:v for k,v in self.env.items() if not k.startswith('GIT_')}
        p = subprocess.run(['git','-C',str(self.memory),*args],env=env,text=True,capture_output=True)
        assert p.returncode == 0, p.stderr
        return p.stdout.strip()
    def transcript(self,sid,minutes=5,folder=None,ago=0,commit=False):
        folder = folder or self.folder
        folder.mkdir(parents=True,exist_ok=True)
        path = folder/(sid+'.jsonl')
        start = datetime.now(timezone.utc)-timedelta(days=ago,minutes=minutes)
        def e(kind,minute,**kw):
            return dict(type=kind,sessionId=sid,gitBranch='dev/cem/record-fixture',timestamp=(start+timedelta(minutes=minute)).isoformat(),**kw)
        blocks = [{'type':'text','text':'The implementation needs durable ownership and careful release checks.'},
                  {'type':'tool_use','id':'file','name':'Edit','input':{'file_path':str(self.root/'a.py')}}]
        if commit: blocks.append({'type':'tool_use','id':'git','name':'Bash','input':{'command':'git commit -m "repair locks"'}})
        lines=[e('user',0,message={'content':self.prompt}),e('assistant',1,requestId='a',message={'model':'claude-haiku-4-5','usage':{},'content':blocks}),e('user',minutes,message={'content':[{'type':'tool_result','tool_use_id':'file','content':'ok'}]}),e('cost-state',minutes,totalCostUSD=1.25,modelUsage={'haiku':{'costUSD':1.25}})]
        path.write_text('\n'.join(json.dumps(x) for x in lines)+'\n')
        modified = time.time() - 1200
        os.utime(path, (modified, modified))
        return path
    def run(self,script,*args,input=None,env=None,timeout=30):
        return subprocess.run(['bash',str(self.root/'bin'/script),*map(str,args)],input=input,text=True,capture_output=True,env=env or self.env,timeout=timeout,cwd=self.root)
    def hook(self,mode='end',path=None,sid=None,wait=True,extra=(),env=None):
        path = path or self.path
        sid = sid or path.stem
        data=json.dumps({'session_id':sid,'transcript_path':str(path),'cwd':str(self.root),'hook_event_name':'Stop' if mode=='checkpoint' else 'SessionEnd'})
        start=time.monotonic()
        p=self.run('session-record.sh','--mode',mode,*extra,input=data,env=env)
        elapsed=time.monotonic()-start
        assert p.returncode==0 and not p.stdout and not p.stderr,(p.returncode,p.stdout,p.stderr)
        if wait: self.wait(sid,path)
        return elapsed
    def wait(self,sid='session-one',path=None,timeout=25):
        folder=(path or self.path).resolve().parent.name
        lock=self.home/'.egregore/trails'/folder/'locks'/sid
        end=time.monotonic()+timeout
        while lock.exists():
            assert time.monotonic()<end,'worker did not finish: '+str(lock)+' '+self.errors()
            time.sleep(.04)
    def records(self): return list((self.memory/'sessions').glob('**/*.md'))
    def text(self):
        paths=self.records()
        assert len(paths)==1,(paths,self.errors())
        return paths[0].read_text()
    def errors(self):
        return '\n'.join(p.read_text() for p in (self.home/'.egregore/trails').glob('*/errors.log'))
    def calls(self,builds=False):
        path=Path(self.env['FAKE_CALLS'])
        calls=[json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
        return [x for x in calls if '-p' in x] if builds else calls
    def cleanup(self):
        for lock in (self.home/'.egregore/trails').glob('*/locks/*'):
            if lock.is_dir():
                end=time.monotonic()+25
                while lock.exists() and time.monotonic()<end: time.sleep(.05)
        remove_tree(self.temp)

def remove_tree(path):
    """Remove a fixture tree. A detached worker can delete its own file, such as
    maintenance.lock, while the tree is removed; a file already gone is no failure.
    A worker also outlives its session lock: after releasing it, it reads memory
    once more, and when the removal has taken memory away its error handler writes
    errors.log into the trail folder. A directory refilled that way is removed again."""
    def gone(function,target,error):
        error=error[1] if isinstance(error,tuple) else error
        if not isinstance(error,FileNotFoundError):
            raise error
    end=time.monotonic()+10
    while True:
        try:
            shutil.rmtree(path,**({'onexc':gone} if sys.version_info>=(3,12) else {'onerror':gone}))
            return
        except OSError as error:
            if error.errno not in (errno.ENOTEMPTY,errno.EEXIST) or time.monotonic()>end:
                raise
            time.sleep(.1)

@contextlib.contextmanager
def fixture():
    f=Fixture()
    try: yield f
    finally: f.cleanup()

def test(name,fn):
    global PASSED,FAILED
    try:
        fn(); PASSED+=1; print('PASS: '+name,flush=True)
    except Exception as exc:
        FAILED+=1; print('FAIL: '+name+' — '+repr(exc),flush=True)
        import traceback; traceback.print_exc()

def off_gates():
    with fixture() as f:
        f.config['features']['session_records']['enabled']=False;f.save();f.hook();assert not f.records()
        f.config['features']['session_records']['enabled']=True;f.state['session_records_enabled']=False;f.save();f.hook();assert not f.records()
        del f.state['session_records_enabled'];f.state.pop('github_username');f.save();f.hook();assert not f.records()
        (f.root/'.egregore-state.json').unlink();f.hook();assert not f.records()
test('1–2. policy, personal and missing identity gates are silent',off_gates)

def held():
    with fixture() as f:
        hold=f.base/'holds/session-one';hold.parent.mkdir(parents=True);hold.write_text('held')
        f.hook();text=f.text();assert 'detail: stub' in text and text.count('## ')==1 and 'held session ·' in text
        assert '# Session: held\n' in text and 'record fixture' not in text and 'dev/cem/' not in text
        assert f.records()[0].name.endswith('-cem-held-session-.md')
        assert set(sr.metadata(text))=={'kind','from','date','session','detail','status','record_revision','cost_usd','cost_source','duration'}
        assert not f.calls()
    with fixture() as f:
        hold=f.base/'holds/session-one';hold.parent.mkdir(parents=True);hold.write_text('held')
        f.state['session_records_hold_stub']=False;f.save();f.hook();assert not f.records()
test('3. durable hold writes only a stub or no file',held)

def held_metadata_privacy():
    data={'author':'synthetic-person','date':'2026-10-15T10:00:00Z',
          'topic':'SYNTHETIC_CONFIDENTIAL_TOPIC','session':'synthetic-session',
          'detail':'outline','status':'final','record_revision':1,'cost_usd':0,
          'cost_source':'estimate','duration':'1m','branch':'synthetic/CONFIDENTIAL_BRANCH',
          'summary':'original','body':'SYNTHETIC_CONTENT_TO_REMOVE','backfill':True}
    held=sr.stub_data(data)
    assert held['topic']==held['branch']=='held'
    text=sr.record_text(held)
    assert data['topic'] not in text and data['branch'] not in text and data['body'] not in text
    assert '10:00:00' not in text and '# Session: held\n' in text
    meta=sr.metadata(text)
    assert set(meta)=={'kind','from','date','session','detail','status','record_revision','cost_usd','cost_source','duration'},meta
    assert meta['date']=='2026-10-15' and meta['session']=='synthetic-session'
    assert text.split('---',2)[2].strip()=='# Session: held\n\n## Summary\n\nheld session · 1m · $0.00'
test('P2. synthetic sensitive topic and branch are absent from the held metadata whitelist',held_metadata_privacy)

def unborn_memory_hold():
    with fixture() as f:
        f.git('symbolic-ref','HEAD','refs/heads/unborn-memory')
        f.env['EGREGORE_NATIVE_SESSION_ID']='session-one'
        result=f.run('records.sh','hold')
        assert result.returncode==0 and 'none yet' in result.stdout,(result.stdout,result.stderr)
        assert (f.base/'holds/session-one').is_file() and not f.records()
    with fixture() as f:
        real_git=shutil.which('git')
        (f.fake/'git').write_text('#!/bin/bash\nfor arg in "$@"; do\n  if [ "$arg" = diff ]; then exit 77; fi\ndone\nexec '+shlex.quote(real_git)+' "$@"\n')
        (f.fake/'git').chmod(0o755)
        f.env['EGREGORE_NATIVE_SESSION_ID']='session-one'
        result=f.run('records.sh','hold')
        assert result.returncode==1 and 'memory write failed' in result.stdout,(result.stdout,result.stderr)
        assert not (f.base/'holds/session-one').exists()
test('R1. new-session hold permits unborn memory HEAD while real diff failures remain errors',unborn_memory_hold)

def outline_full():
    with fixture() as f:
        f.hook();text=f.text()
        for heading in ('Summary','Asked','Decided','Open','Risks','Commits and PRs','Files','Memory and artifacts','Related','Friction','Cost'):
            assert '## '+heading+'\n' in text,heading
        assert f.prompt not in text and '- Keep the durable lock — cem, 10:01' in text
        assert '**Author**: cem' in text and 'cost_source: ledger' in text
        assert (f.base/'session-one.md').stat().st_mode&0o777==0o600
        assert f.base.stat().st_mode&0o777==0o700
        assert any('--help' in x for x in f.calls())
        f.hook(extra=('--detail','full'));assert '## Prompts' in f.text() and f.prompt in f.text()
test('4–5,23. guarded outline, full detail, private files and inert CLI flags',outline_full)

def named_model_prompt():
    for display,expected in (('Cem','Cem'), ('','cem')):
        with fixture() as f:
            f.state['display_name']=display;f.save();f.hook()
            prompt=f.calls(True)[0]
            prompt=prompt[prompt.index('-p')+1]
            assert 'The person is '+expected+';' in prompt,prompt
            assert "the agent's to 'the assistant'; never write 'user'." in prompt
            assert 'PERSON_NAME' not in prompt
test('A2. fake claude receives the display name or handle and never the prompt token',named_model_prompt)

def detached_topics():
    for branch in ('HEAD','head','HeAd','(detached)',''):
        with fixture() as f:
            rows=[json.loads(line) for line in f.path.read_text().splitlines()]
            for row in rows: row['gitBranch']=branch
            f.path.write_text('\n'.join(map(json.dumps,rows))+'\n')
            f.hook()
            assert '# Session: improve-checkpoint-reliability' in f.text(),(branch,f.text())
            assert not f.records()[0].name.endswith('-head.md')
    with fixture() as f:
        rows=[json.loads(line) for line in f.path.read_text().splitlines()]
        for row in rows: row['gitBranch']='HEAD'
        f.path.write_text('\n'.join(map(json.dumps,rows))+'\n')
        f.config['features']['session_records']['model']='none';f.save();f.hook()
        assert '# Session: session\n' in f.text(),f.text()
test('A4. detached and empty branch topics use Asked or the session fallback',detached_topics)

def digest_record(f,name,day,author,topic,sections,kind='session-record'):
    path=f.memory/'sessions'/day.strftime('%Y-%m')/(name+'.md')
    path.parent.mkdir(parents=True,exist_ok=True)
    fields={'kind':kind,'from':author,'date':day.isoformat(),'topic':topic,'session':name}
    front='---\n'+'\n'.join(k+': '+json.dumps(v) for k,v in fields.items())+'\n---\n'
    path.write_text(front+'\n**Date**: '+day.isoformat()+'T09:15:00Z\n\n'+sections)
    return path

def digest_shape():
    with fixture() as f:
        today=datetime.now().date();yesterday=today-timedelta(days=1)
        digest_record(f,'a',yesterday,'cem','durable locks',
                      '## Decided\n- Keep durable locks. — Cem, 10:01\n- none recorded\n'
                      '## Open\n- Check recovery — Cem\n- not derived (model unavailable)\n'
                      '## Risks\nCoordination needs care\nnone noted\n')
        digest_record(f,'b',today,'Oz','record digest',
                      '## Decided\n- KEEP DURABLE LOCKS! — Oz, 11:02\n- Ship the digest\n'
                      '## Open\n- Review the summary\n- (withheld: paraphrase check failed)\n'
                      '## Risks\n- Coordination needs care.\n## Prompts\n- PRIVATE PROMPT\n')
        digest_record(f,'c',today,'Cem','clean\nlabels',
                      '## Decided\n- Keep review — revised scope — Renç, '+yesterday.strftime('%m-%d')+' 23:59\n'
                      '## Open\n- none recorded\n## Risks\n(withheld: currency guard)\n')
        digest_record(f,'old',today-timedelta(days=2),'cem','old topic',
                      '## Decided\n- OLD DECISION\n')
        digest_record(f,'other-kind',today,'cem','not a record',
                      '## Decided\n- WRONG KIND\n',kind='decision')
        before={p.relative_to(f.memory):p.read_bytes() for p in f.records()}
        result=f.run('records.sh','digest')
        assert result.returncode==0,result.stderr
        lines=result.stdout.splitlines()
        assert lines[0]==f'Since {yesterday} · 3 sessions (2 yours, 1 others)',result.stdout
        assert f'  - Keep durable locks. — Cem, {yesterday:%m-%d} 10:01 · durable locks · sessions/{yesterday:%Y-%m}/a.md' in lines,result.stdout
        local_stamp=datetime.fromisoformat(today.isoformat()+'T09:15:00+00:00').astimezone()
        assert f'  - Ship the digest — Oz, {local_stamp:%m-%d %H:%M} · record digest · sessions/{today:%Y-%m}/b.md' in lines,result.stdout
        assert f'  - Keep review — revised scope — Renç, {yesterday:%m-%d} 23:59 · clean labels · sessions/{today:%Y-%m}/c.md' in lines,result.stdout
        # Each open item carries its id: six hex digits of its digest key's hash.
        recovery,summary=(sr.item_id(sr.digest_key(item)) for item in ('Check recovery','Review the summary'))
        assert recovery==hashlib.sha256(b'check recovery').hexdigest()[:6]
        assert f'  - {recovery} Check recovery — Cem · durable locks · sessions/{yesterday:%Y-%m}/a.md' in lines,result.stdout
        assert f'  - {summary} Review the summary — Oz by default · record digest · sessions/{today:%Y-%m}/b.md' in lines,result.stdout
        assert '\nCarried\n' not in result.stdout,result.stdout
        for line in lines:
            if line.startswith('  - '):
                relative=line.rsplit(' · ',1)[1]
                assert relative.startswith('sessions/') and (f.memory/relative).is_file(),line
        assert result.stdout.casefold().count('keep durable locks')==1
        assert result.stdout.count('Coordination needs care')==1
        for hidden in ('OLD DECISION','WRONG KIND','PRIVATE PROMPT','none recorded','none noted','withheld','not derived'):
            assert hidden not in result.stdout,(hidden,result.stdout)
        assert f.run('records.sh','digest','--all').stdout==result.stdout
        assert before=={p.relative_to(f.memory):p.read_bytes() for p in f.records()}
        assert not f.calls() and not f.errors()
test('B1. digest reads all authors, dedupes attribution, ignores placeholders, and writes nothing',digest_shape)

def digest_windows():
    with fixture() as f:
        today=datetime.now().date();yesterday=today-timedelta(days=1)
        digest_record(f,'yesterday',yesterday,'cem','previous day','## Decided\n- Yesterday decision\n')
        digest_record(f,'today',today,'Oz','current day','## Open\n- Current item\n')
        result=f.run('records.sh','digest','--days','0')
        assert result.returncode==0 and 'Yesterday decision' not in result.stdout,result.stdout
        assert f'Since {today} · 1 sessions (0 yours, 1 others)' in result.stdout
        assert '\nDecided\n' not in result.stdout and '\nRisks\n' not in result.stdout
        assert f.run('records.sh','digest','--since',yesterday.isoformat()).stdout==f.run('records.sh','digest').stdout
        future=today+timedelta(days=1)
        result=f.run('records.sh','digest','--since',future.isoformat())
        assert result.returncode==0 and result.stdout==f'Nothing recorded since {future}.\n'
        for args in (('--since','invalid'),('--days','invalid'),('--days','1','--since',today.isoformat())):
            assert f.run('records.sh','digest',*args).returncode==0
    with fixture() as f:
        today=datetime.now().date();yesterday=today-timedelta(days=1)
        digest_record(f,'placeholder',today,'cem','empty','## Decided\n- none recorded\n## Open\n- (withheld: check failed)\n## Risks\nnot derived (model unavailable)\n')
        result=f.run('records.sh','digest')
        assert result.returncode==0 and result.stdout==f'Nothing recorded since {yesterday}.\n'
test('B1. digest supports local date windows and --since, omits empty sections, and always exits zero',digest_windows)

def digest_caps():
    with fixture() as f:
        today=datetime.now().date()
        sections=[]
        for section in ('Decided','Open','Risks'):
            sections.append('## '+section+'\n'+'\n'.join('- '+section+' item '+str(i)+('x'*220 if i==0 else '') for i in range(12)))
        digest_record(f,'caps',today,'cem','limits','\n'.join(sections))
        result=f.run('records.sh','digest')
        assert result.returncode==0,result.stdout+result.stderr
        groups={};section=None
        for line in result.stdout.splitlines():
            assert len(line)<=180,(len(line),line)
            if line in ('Decided','Open','Risks'): section=line;groups[section]=[]
            elif line.startswith('  - '): groups[section].append(line)
        assert {key:len(value) for key,value in groups.items()}=={'Decided':8,'Open':8,'Risks':4},result.stdout
        assert all('… · sessions/' in lines[0] for lines in groups.values())
        assert all((f.memory/line.rsplit(' · ',1)[1]).is_file() for lines in groups.values() for line in lines)
test('B1/P5. digest caps sections at 8/8/4 and 180 characters while preserving every source path',digest_caps)

def digest_record_boundaries():
    with fixture() as f:
        today=datetime.now().date()
        target=digest_record(f,'foreign',today,'cem','private knowledge','## Decided\n- PRIVATE_OUTSIDE_SESSION_RECORD\n')
        outside=f.memory/'knowledge/foreign.md';outside.parent.mkdir();target.rename(outside)
        target.symlink_to(outside)
        valid=digest_record(f,'valid',today,'cem','bounded record','## Decided\n- Keep the bounded reader\n')
        prefix=valid.read_bytes()
        valid.write_bytes(prefix+b'\n## Files\n'+b'x'*(256*1024)+b'\n## Open\n- AFTER_READ_LIMIT\n')
        code='''import sys
from pathlib import Path
sys.path.insert(0,sys.argv[1])
import session_record as sr
ctx=sr.Context(sys.argv[2])
rows=list(sr.record_files(ctx.memory))
assert len(rows)==1 and rows[0][0].name=='valid.md',rows
assert len(rows[0][2].encode())==256*1024
assert sr.existing(ctx,'foreign') is None
assert sr.existing(ctx,'valid')[0].name=='valid.md'
assert 'PRIVATE_OUTSIDE_SESSION_RECORD' not in rows[0][2]
assert 'AFTER_READ_LIMIT' not in rows[0][2]
'''
        result=subprocess.run([sys.executable,'-c',code,str(f.root/'bin/lib'),str(f.root)],
                              env=f.env,text=True,capture_output=True)
        assert result.returncode==0,result.stdout+result.stderr
        result=f.run('records.sh','digest')
        assert result.returncode==0 and '1 sessions (1 yours)' in result.stdout,result.stdout+result.stderr
        assert 'Keep the bounded reader' in result.stdout
        assert 'PRIVATE_OUTSIDE_SESSION_RECORD' not in result.stdout and 'AFTER_READ_LIMIT' not in result.stdout
        assert outside.read_text().endswith('- PRIVATE_OUTSIDE_SESSION_RECORD\n')
test('F2. digest and existing reject record symlinks and cap each read at 256 KiB',digest_record_boundaries)

def digest_sessions_root_boundary():
    with fixture() as f:
        today=datetime.now().date()
        valid=digest_record(f,'valid',today,'cem','physical record','## Decided\n- PHYSICAL_RECORD_DECISION\n')
        leaf=valid.with_name('alias.md');leaf.symlink_to(valid)
        result=f.run('records.sh','digest')
        assert result.returncode==0 and '1 sessions (1 yours)' in result.stdout,result.stdout+result.stderr
        assert result.stdout.count('PHYSICAL_RECORD_DECISION')==1
        sessions=f.memory/'sessions'
        for outside in (f.temp/'outside-sessions',f.memory/'relocated-sessions'):
            sessions.rename(outside);sessions.symlink_to(outside,target_is_directory=True)
            try:
                assert list(sr.record_files(f.memory))==[]
                result=f.run('records.sh','digest')
                assert result.returncode==0 and result.stdout.startswith('Nothing recorded since '),result.stdout+result.stderr
                assert 'PHYSICAL_RECORD_DECISION' not in result.stdout
            finally:
                sessions.unlink();outside.rename(sessions)
test('P3. digest accepts physical records, rejects leaf links and rejects sessions-root links inside or outside memory',digest_sessions_root_boundary)

def digest_section_boundaries():
    for detail in ('Prompts','Said'):
        with fixture() as f:
            today=datetime.now().date()
            digest_record(f,'sections',today,'cem','record sections',
                          '## Decided\n- Real decision\n## Files\n- UNKNOWN_SECTION_ITEM\n'
                          '## Decided\n- DUPLICATE_DECIDED_SECTION\n'
                          '## Open\n- Real open item\n## Open\n- DUPLICATE_OPEN_SECTION\n'
                          '## Risks\nReal risk\n## Risks\nDUPLICATE_RISK_SECTION\n'
                          '## Commits and PRs\nattempted (from the session\'s commands):\n- PRIVATE_ATTEMPT\n'
                          'verified (in the repository):\n- PRIVATE_VERIFIED\n'
                          '## '+detail+'\n- Private text\n## Decided\n- PRIVATE_INJECTED_DECISION\n'
                          '## Open\n- PRIVATE_INJECTED_OPEN\n## Risks\nPRIVATE_INJECTED_RISK\n')
            result=f.run('records.sh','digest')
            assert result.returncode==0,result.stdout+result.stderr
            assert all(line in result.stdout for line in ('Real decision','Real open item','Real risk')),result.stdout
            for forbidden in ('UNKNOWN_SECTION_ITEM','DUPLICATE_','PRIVATE_','Private text'):
                assert forbidden not in result.stdout,(detail,result.stdout)
    with fixture() as f:
        today=datetime.now().date()
        digest_record(f,'first-heading-after-prompts',today,'cem','private detail',
                      '## Prompts\n## Decided\n- PRIVATE_INJECTED_FIRST_DECISION\n')
        result=f.run('records.sh','digest')
        assert result.returncode==0 and result.stdout.startswith('Nothing recorded since '),result.stdout+result.stderr
test('F3. digest reads each record section once and stops before Prompts or Said',digest_section_boundaries)

def digest_local_dates():
    with fixture() as f:
        previous=datetime(2026,10,14).date()
        path=digest_record(f,'near-midnight',previous,'cem','local date','## Decided\n- Keep the local date\n')
        path.write_text(path.read_text().replace('2026-10-14T09:15:00Z','2026-10-14T23:30:00Z'))
        code='''import json,os,sys,time
sys.path.insert(0,sys.argv[1])
import session_record as sr
time.tzset()
class FixedDateTime(sr.datetime):
    @classmethod
    def now(cls,tz=None):
        return cls(2026,10,15,12,tzinfo=tz)
sr.datetime=FixedDateTime
ctx=sr.Context(sys.argv[2])
data=sr.collect_digest(ctx.memory,author=ctx.author,person=ctx.display,days=0)
if os.environ.get('TZ')=='UTC':
    utc_day=sr.collect_digest(ctx.memory,author=ctx.author,person=ctx.display,today='2026-10-14',days=0)
    assert utc_day['sessions']==1,utc_day
    assert utc_day['decided'][0]['time']=='10-14 23:30',utc_day
print(json.dumps(data))
sr.records(ctx,['digest','--days','0'])
'''
        for zone,count,stamp in (('Europe/Berlin',1,'10-15 01:30'),('UTC',0,None)):
            result=subprocess.run([sys.executable,'-c',code,str(f.root/'bin/lib'),str(f.root)],
                                  env=dict(f.env,TZ=zone),text=True,capture_output=True)
            assert result.returncode==0,result.stdout+result.stderr
            raw,_,rendered=result.stdout.partition('\n');data=json.loads(raw)
            assert data['sessions']==count,(zone,data)
            if count:
                assert data['decided'][0]['time']==stamp,data
                assert 'Keep the local date — cem, '+stamp+' · local date' in rendered,rendered
            else:
                assert rendered=='Nothing recorded since 2026-10-15.\n',rendered
        for unavailable in ('2026-10-15T01:30:00','not-an-iso-date',''):
            original=path.read_text()
            path.write_text(original.replace('2026-10-14T23:30:00Z',unavailable))
            result=subprocess.run([sys.executable,'-c',code,str(f.root/'bin/lib'),str(f.root)],
                                  env=dict(f.env,TZ='Europe/Berlin'),text=True,capture_output=True)
            assert result.returncode==0,result.stdout+result.stderr
            data=json.loads(result.stdout.splitlines()[0])
            assert data['sessions']==0,(unavailable,data)
            path.write_text(original)
test('F4. digest filters and attributes offset timestamps in local time with date fallback',digest_local_dates)

def revisions():
    with fixture() as f:
        f.hook('checkpoint');assert 'record_revision: 1' in f.text()
        f.hook();assert 'record_revision: 2' in f.text() and 'status: final' in f.text()
        count=len(f.calls(True));f.hook('checkpoint');assert 'record_revision: 2' in f.text() and len(f.calls(True))==count
        f.hook();assert 'record_revision: 3' in f.text()
test('6. checkpoint/end replace one file, final blocks checkpoints, resumed end advances',revisions)

def boundaries():
    with fixture() as f:
        other=f.transcript('outside',folder=f.folder.with_name(f.prefix+'-new'));other.chmod(0)
        f.hook(path=other);assert not f.records() and not f.errors()
        link=f.temp/'outside-link.jsonl';link.symlink_to(f.path)
        f.hook(path=link,sid='session-one');assert 'status: final' in f.text()
        escape=f.folder/'escape.jsonl';escape.symlink_to(other)
        f.hook(path=escape);assert len(f.records())==1
        assert not f.errors()
test('7. physical instance gate precedes read; inward symlink accepted, escape refused',boundaries)

def invalid():
    with fixture() as f:
        f.hook(path=f.folder/'missing.jsonl');assert not f.records()
        f.path.chmod(0);f.hook();assert not f.records();f.path.chmod(0o600)
        f.path.write_text('{"type":"session","version":3}\n');f.hook();assert not f.records()
        assert not f.errors()
        p=f.run('session-record.sh','--mode','end',input='{}');assert p.returncode==0 and not p.stdout+p.stderr
        (f.root/'memory').unlink();f.hook();assert not f.records()
test('8. missing, unreadable, Pi-shaped and absent memory fail closed',invalid)

def no_model():
    with fixture() as f:
        # Force lookup absent without changing the system PATH needed by bash/jq/Python.
        (f.fake/'claude').unlink()
        local=f.temp/'tools';local.mkdir()
        for name in ('bash','jq','python3','dirname','git'):
            (local/name).symlink_to(shutil.which(name))
        f.env['PATH']=str(local)
        f.hook();assert 'detail: outline-deterministic' in f.text() and 'not derived (model unavailable)' in f.text()
    with fixture() as f:
        f.env.update(FAKE_SLEEP='60',EGREGORE_RECORD_MODEL_TIMEOUT_S='3')
        start=time.monotonic();f.hook();assert time.monotonic()-start<20
        assert 'detail: outline-deterministic' in f.text() and 'model timed out' in f.text()
        for pid in Path(f.env['FAKE_PIDS']).read_text().splitlines():
            try: os.kill(int(pid),0)
            except ProcessLookupError: pass
            else: raise AssertionError('orphan model '+pid)
test('9–10. absent model and timeout produce deterministic record without orphans',no_model)

def related():
    with fixture() as f:
        dest=f.root/'memory/handoffs/example.md';dest.parent.mkdir(parents=True);dest.write_text('handoff')
        with f.path.open('a') as out:out.write(json.dumps({'type':'assistant','message':{'content':[{'type':'tool_use','id':'h','name':'Write','input':{'file_path':str(dest)}}]}})+'\n')
        f.hook();assert '## Related\n- memory/handoffs/example.md' in f.text()
test('11. explicit handoff appears in Related and does not suppress record',related)

def debounce_detach():
    with fixture() as f:
        f.hook('checkpoint',extra=('--debounce','600'));time.sleep(1)
        stamp=(f.base/'stamps/session-one').stat().st_mtime_ns
        f.hook('checkpoint',extra=('--debounce','600'));assert len(f.calls(True))==1
        assert (f.base/'stamps/session-one').stat().st_mtime_ns==stamp
    with fixture() as f:
        f.env['FAKE_SLEEP']='5';elapsed=f.hook('checkpoint',wait=False)
        assert elapsed<2,elapsed
        f.wait();assert f.records()
test('12–13. debounce under lock and detached hook return below two seconds',debounce_detach)

def backfill():
    with fixture() as f:
        f.transcript('session-two',ago=1);f.transcript('short',minutes=1);f.transcript('old',ago=100)
        f.transcript('foreign',folder=f.folder.with_name(f.prefix+'-new'))
        p=f.run('records.sh','backfill','--dry-run');assert p.returncode==0,p.stderr
        assert 'session-one' in p.stdout and 'session-two' in p.stdout and 'foreign' not in p.stdout
        assert '2 model calls' in p.stdout and 'skipped shorter than 2 minutes with no commits: 1' in p.stdout
        p=f.run('records.sh','backfill','--yes');assert p.returncode==0,(p.stdout,p.stderr)
        assert len(f.records())==2,(p.stdout,f.errors())
        assert all('backfill: true' in x.read_text() for x in f.records())
        message=f.git('log','-1','--format=%B');assert message.startswith('chore(sessions): record 2 past sessions (') and 'Built: 2' in message
        assert f.git('rev-list','--count','HEAD')=='2'
        assert json.loads((f.root/'.egregore-state.json').read_text()).get('session_records_backfilled_through')
        p=f.run('records.sh','backfill','--dry-run');assert 'skipped already recorded: 2' in p.stdout
        p=f.run('records.sh','show','session-on');assert p.returncode==0 and 'ASK' in p.stdout
        p=f.run('records.sh','show','session-');assert p.returncode==1 and 'ambiguous' in p.stdout
test('14. filtered dry-run, model count, sequential staged backfill and one batch commit',backfill)

def hold_identity():
    with fixture() as f:
        p=f.run('records.sh','hold');assert p.returncode==1 and len(p.stdout.splitlines())==1 and 'could not be identified' in p.stdout
        f.env['EGREGORE_NATIVE_SESSION_ID']='session-one';f.env['CLAUDE_CODE_SESSION_ID']='not-this'
        p=f.run('records.sh','hold');assert p.returncode==0,p.stdout+p.stderr
        assert (f.base/'holds/session-one').exists() and not (f.base/'holds/not-this').exists()
        assert 'none yet' in p.stdout
        assert not list(f.root.glob('.egregore-native-session-id'))
        del f.env['EGREGORE_NATIVE_SESSION_ID'];f.env['CLAUDE_CODE_SESSION_ID']='fallback'
        p=f.run('records.sh','hold');assert p.returncode==0 and (f.base/'holds/fallback').exists()
test('15. hold uses native environment id, fallback, never shared-file guessing',hold_identity)

def inherited_git():
    with fixture() as f:
        f.env.update(GIT_DIR=str(f.temp/'wrong'),GIT_WORK_TREE=str(f.temp/'wrong-tree'),GIT_INDEX_FILE=str(f.temp/'wrong-index'))
        f.hook();assert f.git('rev-list','--count','HEAD')=='2'
        assert not (f.temp/'wrong-index').exists()
test('16. inherited Git environment cannot redirect memory writes',inherited_git)

def overlap():
    with fixture() as f:
        f.env['FAKE_SLEEP']='5';f.hook('checkpoint',wait=False);time.sleep(1)
        assert f.hook(wait=False)<2
        assert (f.base/'locks/session-one.end-requested').exists()
        f.wait(timeout=20);text=f.text();assert 'status: final' in text and 'record_revision: 2' in text
        assert len(f.calls(True))==2
        assert Path(f.env['FAKE_PIDS']).read_text()==Path(f.env['FAKE_EXITS']).read_text()
        f.hook('checkpoint');assert 'record_revision: 2' in f.text()
test('17. overlapping end queues final build, no model killed, final record terminal',overlap)

def concurrent():
    with fixture() as f:
        f.env['FAKE_SLEEP']='1'
        data=json.dumps({'session_id':'session-one','transcript_path':str(f.path),'hook_event_name':'Stop'})
        command=['bash',str(f.root/'bin/session-record.sh'),'--mode','checkpoint','--debounce','600']
        a=subprocess.Popen(command,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=f.env)
        a.stdin.write(data);a.stdin.close();time.sleep(.01)
        b=subprocess.run(command,input=data,text=True,capture_output=True,env=f.env)
        a.wait();assert b.returncode==0 and a.returncode==0 and not b.stdout+b.stderr
        f.wait();assert len(f.calls(True))==1 and 'record_revision: 1' in f.text()
test('18. simultaneous checkpoint admission permits exactly one build',concurrent)

def redact():
    for mode in ('checkpoint','end'):
        with fixture() as f:
            f.hook(mode);f.env['EGREGORE_NATIVE_SESSION_ID']='session-one'
            previous=f.records()[0]
            p=f.run('records.sh','hold');assert p.returncode==0 and 'stubbed' in p.stdout,(p.stdout,p.stderr)
            assert 'detail: stub' in f.text() and '## Asked' not in f.text()
            neutral=f.records()[0]
            assert not previous.exists() and neutral.parent==previous.parent
            assert neutral.name==previous.name[:3]+'cem-held-session-.md',neutral
            committed=f.git('ls-tree','-r','--name-only','HEAD','--','sessions').splitlines()
            assert committed==[str(neutral.relative_to(f.memory))],committed
            if mode=='end':
                changes=f.git('diff-tree','--no-commit-id','--name-status','--no-renames','-r','HEAD').splitlines()
                assert set(changes)=={'D\t'+str(previous.relative_to(f.memory)),'A\t'+str(neutral.relative_to(f.memory))},changes
            f.state['session_records_hold_stub']=False;f.save()
            p=f.run('records.sh','hold');assert p.returncode==0 and 'removed' in p.stdout and not f.records()
            assert f.git('show','--format=','--name-status','HEAD').startswith('D\t')
    with fixture() as f:
        f.env['FAKE_SLEEP']='5';f.hook('checkpoint',wait=False);time.sleep(1)
        f.env['EGREGORE_NATIVE_SESSION_ID']='session-one';p=f.run('records.sh','hold',timeout=20)
        assert p.returncode==0 and 'detail: stub' in f.text() and '## Asked' not in f.text()
        f.state['session_records_enabled']=False;f.save()
        p=f.run('records.sh','redact','session-one');assert p.returncode==0 and 'stubbed' in p.stdout
test('19/P2. synchronous hold renames final/in-progress records, commits old-path removal, and wins mid-build',redact)

def durable():
    with fixture() as f:
        f.env['EGREGORE_NATIVE_SESSION_ID']='session-one';assert f.run('records.sh','hold').returncode==0
        scratch=f.temp/'scratch';shutil.rmtree(scratch);scratch.mkdir();f.env['TMPDIR']=str(scratch)
        for args in (('--dry-run',),('--yes',)):
            p=f.run('records.sh','backfill',*args);assert p.returncode==0 and 'skipped held: 1' in p.stdout and not f.records()
        assert (f.base/'holds/session-one').exists()
test('20. holds survive temporary-directory reset and exclude both backfill modes',durable)

def failure_batch():
    with fixture() as f:
        (f.folder/'broken.jsonl').write_text('malformed\n')
        modified=time.time()-1200;os.utime(f.folder/'broken.jsonl',(modified,modified))
        f.env['FAKE_SLEEP']='.3'
        remote=f.temp/'remote.git'
        subprocess.run(['git','init','--bare','-q',str(remote)],check=True,capture_output=True,env={k:v for k,v in f.env.items() if not k.startswith('GIT_')})
        hook=remote/'hooks/pre-receive';hook.write_text('#!/bin/sh\nexit 1\n');hook.chmod(0o755)
        f.git('remote','add','origin',str(remote))
        p=f.run('records.sh','backfill','--yes');assert p.returncode==0,(p.stdout,p.stderr)
        assert f.git('rev-list','--count','HEAD')=='2'
        msg=f.git('log','-1','--format=%B');assert 'Built: 1' in msg and 'Failed: 0' in msg and 'unreadable header=1' in msg,msg
        assert json.loads((f.root/'.egregore-state.json').read_text()).get('session_records_backfilled_through')
        p=f.run('records.sh','status');assert '1 commit waiting to push' in p.stdout and 'push_acknowledgement_unknown' in f.errors()
        hook.unlink();p=f.run('records.sh','status','--push');assert p.returncode==0 and 'waiting to push' not in p.stdout
        assert subprocess.run(['git','--git-dir',str(remote),'rev-list','--all','--count'],capture_output=True,text=True).stdout.strip()=='2'
test('21. unreadable header counted, one commit, rejected push retained and retryable',failure_batch)

def fifo():
    with fixture() as f:
        for folder in (f.folder,f.folder.with_name(f.prefix+'-new')):
            folder.mkdir(exist_ok=True)
            path=folder/'pipe.jsonl';os.mkfifo(path)
            assert f.hook(path=path)<2
        assert not f.records() and not f.errors()
test('22. FIFOs inside and outside instance never open or block',fifo)

def isolation():
    with fixture() as f:
        f.env['FAKE_EXIT']='99';f.hook();assert 'detail: outline-deterministic' in f.text() and 'exit 99' in f.text()
    with fixture() as f:
        f.env['FAKE_MISSING']='1';f.hook();assert not f.calls(True)
        assert '--strict-mcp-config' in f.text() and 'detail: outline-deterministic' in f.text()
        assert any('--help' in x for x in f.calls())
test('23. failed inert invocation and missing isolation flag fail closed',isolation)

def paraphrase():
    with fixture() as f:
        assistant=' '.join('word'+str(i) for i in range(15))
        with f.path.open('a') as out:out.write(json.dumps({'type':'assistant','message':{'content':[{'type':'text','text':assistant}]}})+'\n')
        Path(f.env['FAKE_OUTPUT']).write_text('## Asked\n'+f.prompt+'\nRepair checkpoint persistence\n## Decided\n'+assistant+'\n## Open\n- Cost is $123\n## Risks\nnone noted\n## Friction\nWaits slowed progress\n')
        f.hook();text=f.text();assert f.prompt not in text and assistant not in text and '$123' not in text
        assert 'Repair checkpoint persistence' in text and '(withheld: paraphrase check failed)' in text
test('24. short whole-text, assistant 12-word and currency guards enforced',paraphrase)

def disabled_model():
    for personal in (False,True):
        with fixture() as f:
            if personal:f.state['session_records_model_call']=False
            else:f.config['features']['session_records']['model']='none'
            f.save();f.hook();assert 'detail: outline-deterministic' in f.text() and not f.calls()
test('25. org and personal model opt-outs prevent every CLI invocation',disabled_model)

def stale():
    with fixture() as f:
        lock=f.base/'locks/session-one';lock.mkdir(parents=True);(lock/'owner').write_text('99999999')
        (lock.parent/'session-one.end-requested').write_text('end')
        f.hook('checkpoint');assert 'status: final' in f.text() and not lock.exists()
        assert not (lock.parent/'session-one.end-requested').exists()
test('26. dead owner recovered and abandoned end request finalized',stale)

def staging():
    with fixture() as f:
        (f.memory/'unrelated').write_text('do not commit me');f.git('add','unrelated')
        p=f.run('records.sh','backfill','--yes');assert p.returncode==0,(p.stdout,p.stderr)
        changed=f.git('show','--format=','--name-only','HEAD').splitlines()
        assert changed and all(x.startswith('sessions/') for x in changed),changed
        assert f.git('diff','--cached','--name-only')=='unrelated'
        assert not list((f.base/'backfill-staging').glob('sessions/**/*.md'))
test('27. batch commit preserves unrelated staged content and touches exact paths',staging)

def routing():
    for enabled in (True,False):
        with fixture() as f:
            f.config['features']['session_records'].update(enabled=enabled,model='none');f.save()
            # Pi's real storage location and exact workflow payload shape.
            pi=f.home/'.pi/agent/sessions/fixture/session.jsonl';pi.parent.mkdir(parents=True)
            now=datetime.now(timezone.utc)
            rows=[{'type':'session','version':3,'id':'pi-native','cwd':str(f.root),'timestamp':(now-timedelta(minutes=5)).isoformat()},
                  {'type':'message','timestamp':(now-timedelta(minutes=5)).isoformat(),'message':{'role':'user','content':'Review fixture coverage'}},
                  {'type':'message','timestamp':now.isoformat(),'message':{'role':'assistant','model':'fixture','content':[{'type':'text','text':'Fixture reply'}]}}]
            pi.write_text('\n'.join(json.dumps(row,separators=(',',':')) for row in rows)+'\n')
            # Stub only source-branch discovery. Actual writes and commits run
            # unchanged, with Git restricted to the disposable memory repo.
            real_git=shutil.which('git')
            (f.fake/'git').write_text('#!/bin/bash\nif [ "$1" = "-C" ] && [ "$2" = '+shlex.quote(str(f.root))+' ]; then echo develop; exit 0; fi\nexec '+shlex.quote(real_git)+' "$@"\n')
            (f.fake/'git').chmod(0o755)
            p=f.run('session-log.sh',input=json.dumps({'session_id':'pi-session','transcript_path':str(pi),'runtime':'pi'}))
            assert p.returncode==0
            deadline=time.monotonic()+10
            while f.git('rev-list','--count','HEAD')!='2':
                assert time.monotonic()<deadline,'Pi memory commit did not finish: '+f.errors()
                time.sleep(.03)
            if enabled:
                assert sr.metadata(f.text())['session']=='pi-native'
                assert sr.metadata(f.text())['harness']=='pi' and sr.metadata(f.text())['kind']=='session-record'
            else:
                assert 'capture_mode: baseline' in f.text()
                assert 'observed action(s)' in f.text() and '**Session**: pi-session' in f.text()
            assert not f.calls()
            # The enabled route rejects foreign Claude files before a read.
            f.config['features']['session_records']['enabled']=True;f.save()
            before=f.text()
            outside=f.transcript('forbidden',folder=f.folder.with_name(f.prefix+'-new'));outside.chmod(0)
            p=f.run('session-log.sh',input=json.dumps({'session_id':'forbidden','transcript_path':str(outside),'hook_event_name':'SessionEnd'}))
            assert p.returncode==0 and f.text()==before and not f.errors()
test('29. Pi routes to records when enabled and baseline when disabled; foreign Claude gates before read',routing)

# Additional regressions for policy races and non-hook entry points.
def await_model(f, timeout=10):
    deadline=time.monotonic()+timeout
    while not Path(f.env['FAKE_INPUT']).exists():
        assert time.monotonic()<deadline,'model did not receive trail: '+f.errors()
        time.sleep(.02)

def changed_controls():
    for control in ('organization','person'):
        with fixture() as f:
            f.env['FAKE_SLEEP']='1.5';f.hook('checkpoint',wait=False);await_model(f)
            if control=='organization':f.config['features']['session_records']['enabled']=False
            else:f.state['session_records_enabled']=False
            f.save();f.wait()
            assert not f.records(),control+' disabled during build still wrote a record'
            assert f.git('rev-list','--count','HEAD')=='1'
            assert not (f.base/'locks/session-one').exists()
            assert Path(f.env['FAKE_PIDS']).read_text()==Path(f.env['FAKE_EXITS']).read_text()
    with fixture() as f:
        f.env['FAKE_SLEEP']='1.5';f.hook('checkpoint',wait=False);await_model(f)
        f.state['session_records_hold_stub']=False;f.save()
        f.env['EGREGORE_NATIVE_SESSION_ID']='session-one'
        p=f.run('records.sh','hold',timeout=15)
        assert p.returncode==0,(p.stdout,p.stderr)
        f.wait();assert not f.records() and (f.base/'holds/session-one').exists()
        assert f.git('rev-list','--count','HEAD')=='1'
test('30. org off, personal off and no-stub hold win after the model starts',changed_controls)

def direct_redact_disabled():
    for stub in (True,False):
        with fixture() as f:
            f.hook();before=f.text()
            f.config['features']['session_records']['enabled']=False
            f.state.update(session_records_enabled=False,session_records_hold_stub=stub);f.save()
            p=f.run('session-record.sh','--mode','redact','--session-id','session-one')
            assert p.returncode==0 and not p.stdout+p.stderr,(p.returncode,p.stdout,p.stderr)
            if stub:
                text=f.text();assert 'detail: stub' in text and '## Asked' not in text
                assert 'record_revision: 2' in text and 'status: final' in text
                assert sr.metadata(text)['date']==sr.metadata(before)['date']
                assert '**Date**:' not in text and 'started_at' not in sr.metadata(text)
            else:
                assert not f.records()
                assert f.git('show','--format=','--name-status','HEAD').startswith('D\t')
test('31. direct redact bypasses disabled gates and honors stub/removal on final records',direct_redact_disabled)

def show_cached():
    with fixture() as f:
        f.hook()
        trail=f.base/'session-one.md';expected=trail.read_text();before=f.git('rev-list','--count','HEAD')
        f.path.unlink()
        p=f.run('records.sh','show','session-on')
        assert p.returncode==0 and p.stdout==expected,(p.returncode,p.stdout,p.stderr)
        assert f.git('rev-list','--count','HEAD')==before and len(f.records())==1
        assert len(f.calls(True))==1
        # A cached file outside this instance's trail family is never discovered.
        other=f.home/'.egregore/trails'/(f.prefix+'-new');other.mkdir()
        (other/'foreign.md').write_text('outside trail')
        p=f.run('records.sh','show','foreign');assert p.returncode==1 and 'outside trail' not in p.stdout
test('32. show reads a surviving cached trail without transcript or shared writes',show_cached)

def capped_model_input():
    with fixture() as f:
        with f.path.open('a') as target:
            for index in range(130):
                target.write(json.dumps({'type':'user','sessionId':'session-one','timestamp':datetime.now(timezone.utc).isoformat(),
                                         'message':{'content':f'Topic {index} '+('bounded source material '*35)}})+'\n')
            target.write(json.dumps({'type':'user','sessionId':'session-one','message':{'content':'LAST_TRAIL_MARKER remains visible'}})+'\n')
        f.hook()
        original=(f.base/'session-one.md').read_text();sent=Path(f.env['FAKE_INPUT']).read_text()
        assert len(original)>60000,len(original)
        assert len(sent)<=60000,len(sent)
        assert sent.startswith(original[:100]) and 'LAST_TRAIL_MARKER' in sent
        assert 'truncated' in sent.lower() and 'truncated' in f.text().lower()
test('33. model stdin caps at 60000 characters while keeping both trail ends',capped_model_input)

def busy_backfill():
    with fixture() as f:
        lock=f.base/'locks/session-one';lock.mkdir(parents=True)
        (lock/'owner').write_text(str(os.getpid()));(lock/'mode').write_text('checkpoint');(lock/'since').write_text(str(time.time()))
        try:
            p=f.run('records.sh','backfill','--yes')
            assert p.returncode==0,(p.stdout,p.stderr)
            assert not f.records() and not f.calls(True)
            assert f.git('rev-list','--count','HEAD')=='1'
            assert 'skipped: 1' in p.stdout,p.stdout
            assert (lock/'owner').read_text()==str(os.getpid())
        finally:
            shutil.rmtree(lock)
test('34. backfill skips a live session lock without disturbing its owner',busy_backfill)

def main_checkout_prefix():
    with fixture() as f:
        # No project Git command is needed: .git's worktree pointer is sufficient.
        checkout=f.temp/'main.checkout';(checkout/'.git/worktrees/task').mkdir(parents=True)
        (f.root/'.git').write_text('gitdir: '+str(checkout/'.git/worktrees/task')+'\n')
        prefix=st.instance_prefix(checkout)
        assert st.instance_prefix(f.root)==prefix
        worktree_folder=f.home/'.claude/projects'/(prefix+'--claude-worktrees-topic')
        inside=f.transcript('worktree-native',folder=worktree_folder)
        f.hook(path=inside)
        assert '**Session**: worktree-native' in f.text()
        assert (f.home/'.egregore/trails'/worktree_folder.name/'worktree-native.md').exists()
        foreign=f.transcript('main-sibling',folder=worktree_folder.with_name(prefix+'-new'))
        f.hook(path=foreign);assert len(f.records())==1 and not f.errors()
test('35. worktree gitdir resolves main-checkout transcript prefix without project git',main_checkout_prefix)

def config_false_values():
    with fixture() as f:
        script='SCRIPT_DIR="$1"; source "$SCRIPT_DIR/bin/lib/config.sh"; if _session_records_enabled; then echo on; else echo off; fi; _session_records_default_detail; _session_records_model'
        def readers():
            p=subprocess.run(['bash','-c',script,'config-reader',str(f.root)],env=f.env,text=True,capture_output=True)
            assert p.returncode==0,p.stderr
            return p.stdout.splitlines()
        f.config['features']['session_records']={'enabled':False,'default_detail':False,'model':False};f.save()
        assert readers()==['off','false','false']
        f.config['features'].pop('session_records');f.save()
        assert readers()==['off','outline','haiku']
        f.config['features']['session_records']={'enabled':True};f.save()
        assert readers()==['on','outline','haiku']
test('36. config readers preserve explicit false and default only absent keys',config_false_values)

def linked_state_written_through():
    with fixture() as f:
        # A worktree links the checkout's state file (bin/worktree-create.sh).
        # A settings write follows the link: the link stays a link, the
        # installation's file gains the key and keeps its own values, and no
        # copy or temp file is left beside the link.
        shared=f.temp/'installation'/'.egregore-state.json'
        shared.parent.mkdir()
        shared.write_text(json.dumps(dict(f.state,identity_version=7)))
        link=f.root/'.egregore-state.json'
        link.unlink();link.symlink_to(shared)
        for action in ('noticed','on'):
            result=f.run('records.sh',action)
            assert result.returncode==0 and result.stdout=='Session records: '+action+'\n',(action,result.stdout,result.stderr)
        assert link.is_symlink() and os.readlink(link)==str(shared)
        written=json.loads(shared.read_text())
        assert written['session_records_noticed'] is True and written['session_records_enabled'] is True and written['identity_version']==7,written
        assert json.loads(link.read_text())==written
        assert not [p.name for p in f.root.iterdir() if p.name.startswith(('.record-','.egregore-record-settings'))]
        assert not [p.name for p in shared.parent.iterdir() if p.name!='.egregore-state.json']
test('37. a linked state file is written through, never replaced by a copy',linked_state_written_through)


def checkpoint_writes():
    with fixture() as f:
        sid='checkpoint-'+f.temp.name
        f.path=f.transcript(sid)
        remote=f.temp/'remote.git'
        subprocess.run(['git','init','--bare','-q',str(remote)],check=True,capture_output=True,env={k:v for k,v in f.env.items() if not k.startswith('GIT_')})
        receive=remote/'hooks/post-receive';counter=f.temp/'push-count'
        receive.write_text('#!/bin/sh\necho push >> '+shlex.quote(str(counter))+'\n');receive.chmod(0o755)
        f.git('remote','add','origin',str(remote))
        f.hook('checkpoint')
        path=f.records()[0];relative=str(path.relative_to(f.memory))
        assert f.git('rev-list','--count','HEAD')=='1' and not counter.exists()
        assert f.git('ls-files','--others','--exclude-standard','--','sessions')==relative
        # A tracked record is also rewritten without a commit or push.
        f.git('add','--',relative);f.git('commit','-qm','fixture earlier record')
        before=f.git('rev-parse','HEAD')
        f.hook('checkpoint')
        assert f.git('rev-parse','HEAD')==before and not counter.exists()
        assert f.git('diff','--name-only','--','sessions')==relative
        assert not f.git('diff','--cached','--name-only')
        f.hook();assert len(counter.read_text().splitlines())==1
        assert f.git('rev-list','--count','HEAD')=='3'
        assert 'record_revision: 3' in f.text()
        assert not f.git('status','--porcelain','--','sessions')
test('G1. checkpoints leave untracked or modified records uncommitted; end commits and pushes',checkpoint_writes)

def replacement_flag():
    with fixture() as f:
        for topic in ('first topic','changed topic'):
            p=f.run('capture-run.sh','--mode','baseline','--replace-session','--author','cem','--session-id','same-id','--topic',topic,'--branch','fixture','--summary','Fixture summary','--date','2026-10-15T10:00:00Z','--duration','5m',input='## Files\n- a.py\n')
            assert p.returncode==0,(p.stdout,p.stderr)
        assert len(f.records())==1 and 'record_revision: 2' in f.text()
        assert f.records()[0].name.endswith('first-topic.md') and '# Session: changed topic' in f.text()
        assert f.git('rev-list','--count','HEAD')=='3'
test('38. capture replace-session works directly and keeps path across topic changes',replacement_flag)

def absent_runtime():
    with fixture() as f:
        env=dict(f.env);env.pop('HOME')
        p=f.run('session-record.sh','--mode','end',input='{}',env=env);assert p.returncode==0 and not p.stdout+p.stderr
        local=f.temp/'without-jq';local.mkdir()
        for name in ('bash','dirname','python3'):(local/name).symlink_to(shutil.which(name))
        env=dict(f.env,PATH=str(local))
        p=f.run('session-record.sh','--mode','end',input='{}',env=env);assert p.returncode==0 and not p.stdout+p.stderr
        assert not f.records()
test('39. absent HOME or jq silently disables hook writes',absent_runtime)

def foreign_author():
    with fixture() as f:
        f.hook()
        path=f.records()[0];original=path.read_text();path.write_text(original.replace('from: "cem"','from: "other"').replace('**Author**: cem','**Author**: other'))
        p=f.run('records.sh','redact','session-one');assert p.returncode==1 and 'another person' in p.stdout
        assert 'detail: stub' not in path.read_text() and not (f.base/'holds/session-one').exists()
test('40. past-record redaction refuses another author before writing a hold',foreign_author)

def unadvertised_turn_limit():
    with fixture() as f:
        f.hook()
        calls=f.calls()
        assert any('--help' in call for call in calls)
        assert len(f.calls(True))==1 and all('--max-turns' not in call for call in calls)
        assert 'detail: outline\n' in f.text() and '- Keep the durable lock — cem, 10:01' in f.text()
test('F1. CLI help without max-turns still makes one inert model call',unadvertised_turn_limit)

def legacy_record(f, owner='CEM', revision=4, status=''):
    when=datetime.now(timezone.utc)
    path=f.memory/'sessions'/when.strftime('%Y-%m')/(when.strftime('%d')+'-cem-session.md')
    path.parent.mkdir(parents=True,exist_ok=True)
    path.write_text('---\ncapture_mode: baseline\nrecord_revision: '+str(revision)+'\n'+
                    ('status: '+status+'\n' if status else '')+'---\n# Session: session\n\n'+
                    '**Date**: '+when.isoformat()+'\n**Author**: '+owner+'\n'+
                    '**Session**: session-one\n**Duration**: 5m\n\n## Summary\n0 observed action(s)\n')
    return path

def legacy_identity():
    with fixture() as f:
        f.state.update(github_username='fcdagdelen',display_name='Cem');f.save()
        path=legacy_record(f)
        f.hook('checkpoint')
        assert f.records()==[path] and 'record_revision: 5' in path.read_text()
        assert 'kind: session-record' in path.read_text() and not f.errors()
    with fixture() as f:
        f.state.update(github_username='fcdagdelen',display_name='Cem');f.save()
        path=legacy_record(f,status='final')
        p=f.run('records.sh','redact','session-one')
        assert p.returncode==0 and 'stubbed' in p.stdout,(p.stdout,p.stderr)
        assert not path.exists() and 'detail: stub' in f.text() and 'record_revision: 5' in f.text()
    with fixture() as f:
        path=legacy_record(f,owner='someone-else');before=path.read_text()
        f.hook('checkpoint')
        assert path.read_text()==before and 'another person' in f.errors()
        p=f.run('records.sh','redact','session-one')
        assert p.returncode==1 and 'another person' in p.stdout and path.read_text()==before
        assert not (f.base/'holds/session-one').exists()
test('F4. legacy display-name ownership permits replacement/redaction and rejects others',legacy_identity)

def legacy_backfill_filename():
    with fixture() as f:
        f.state.update(github_username='fcdagdelen',display_name='Cem');f.save()
        path=legacy_record(f)
        p=f.run('records.sh','backfill','--yes')
        assert p.returncode==0,(p.stdout,p.stderr)
        assert f.records()==[path],(f.records(),p.stdout,f.errors())
        text=path.read_text()
        assert 'backfill: true' in text and 'record_revision: 5' in text
        assert path.name.endswith('-session.md') and '# Session: record fixture' in text
test('F6. backfill replaces legacy baseline at its original session filename',legacy_backfill_filename)

def foreign_trail_alias():
    with fixture() as f:
        foreign=f.home/'.egregore/trails/foreign-instance';(foreign/'holds').mkdir(parents=True)
        (foreign/'foreign-session.md').write_text('FOREIGN_TRAIL_MUST_NOT_APPEAR')
        (foreign/'index.json').write_text(json.dumps({'unrecorded_count':999,'waiting_push':1}))
        (foreign/'holds/aliased-local').write_text('held in another instance')
        alias_name=f.prefix+'--alias'
        f.transcript('aliased-local',folder=f.folder.with_name(alias_name))
        alias=f.home/'.egregore/trails'/alias_name;alias.symlink_to(foreign,target_is_directory=True)
        before={p.relative_to(foreign):p.read_bytes() for p in foreign.rglob('*') if p.is_file()}
        p=f.run('records.sh','show','foreign-session')
        assert p.returncode==1 and 'FOREIGN_TRAIL' not in p.stdout+p.stderr,(p.stdout,p.stderr)
        p=f.run('records.sh','redact','foreign-session')
        assert 'FOREIGN_TRAIL' not in p.stdout+p.stderr
        p=f.run('records.sh','status')
        assert p.returncode==0 and '2 unrecorded sessions on this machine' in p.stdout,p.stdout+p.stderr
        assert '999' not in p.stdout and 'waiting to push' not in p.stdout
        after={p.relative_to(foreign):p.read_bytes() for p in foreign.rglob('*') if p.is_file()}
        assert before==after and alias.is_symlink()
test('F9. show, redact and status ignore symlinked foreign trail aliases',foreign_trail_alias)

def recent_backfill():
    with fixture() as f:
        os.utime(f.path,None)
        for mode in ('--dry-run','--yes'):
            p=f.run('records.sh','backfill',mode)
            assert p.returncode==0 and 'skipped live: 1' in p.stdout,(p.stdout,p.stderr)
            assert not f.records() and not f.calls(True)
test('F10. backfill skips recently modified transcripts as live',recent_backfill)

def backfill_end_request():
    with fixture() as f:
        f.env['FAKE_SLEEP']='1.5'
        child=subprocess.Popen(['bash',str(f.root/'bin/records.sh'),'backfill','--yes'],
                               cwd=f.root,env=f.env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        try:
            await_model(f)
            with f.path.open('a') as target:
                target.write(json.dumps({'type':'assistant','sessionId':'session-one',
                                         'gitBranch':'dev/cem/updated-record-topic',
                                         'timestamp':datetime.now(timezone.utc).isoformat(),
                                         'message':{'content':[{'type':'tool_use','id':'later',
                                                               'name':'Edit','input':{'file_path':str(f.root/'later.py')}}]}})+'\n')
            assert f.hook(wait=False)<2
            assert (f.base/'locks/session-one.end-requested').exists()
            stdout,stderr=child.communicate(timeout=25)
            assert child.returncode==0,(stdout,stderr,f.errors())
            f.wait()
            text=f.text()
            assert 'status: final' in text and '- later.py' in text,(text,stdout,f.errors())
            assert '# Session: updated record topic' in text
            assert 'record-fixture' in f.records()[0].name
            assert not list((f.base/'backfill-staging').glob('sessions/**/*.md'))
            assert len(f.calls(True))==2
            assert not (f.base/'locks/session-one.end-requested').exists()
            assert not (f.base/'locks/session-one').exists()
        finally:
            if child.poll() is None:
                child.wait(timeout=25)
test('F10. backfill lock holder drains end request using the updated transcript',backfill_end_request)

def large_full_record():
    with fixture() as f:
        with f.path.open('a') as target:
            for index in range(200):
                target.write(json.dumps({'type':'user','sessionId':'session-one',
                                         'timestamp':datetime.now(timezone.utc).isoformat(),
                                         'message':{'content':f'Long fixture prompt {index:03}: '+('x'*800)}})+'\n')
        f.hook(extra=('--detail','full'))
        text=f.text()
        assert 'detail: full' in text and '## Prompts' in text
        assert text.count('Long fixture prompt ')==200 and len(text)>140000
        assert not f.errors()
test('F11. full record with 200 long prompts travels on stdin and captures successfully',large_full_record)

def ownerless_locks():
    with fixture() as f:
        session_lock=f.base/'locks/session-one';session_lock.mkdir(parents=True)
        old=time.time()-120;os.utime(session_lock,(old,old))
        key=hashlib.sha256(str(f.memory.resolve()).encode()).hexdigest()[:16]
        memory_lock=f.home/'.egregore/locks'/('memory-'+key);memory_lock.mkdir(parents=True)
        os.utime(memory_lock,(old,old))
        f.hook('checkpoint')
        assert 'record_revision: 1' in f.text() and not session_lock.exists() and not memory_lock.exists()
    with fixture() as f:
        session_lock=f.base/'locks/session-one';session_lock.mkdir(parents=True)
        young=time.time()-1;os.utime(session_lock,(young,young))
        before=session_lock.stat().st_mtime_ns
        try:
            assert f.hook('checkpoint',wait=False)<2
            assert session_lock.exists() and not (session_lock/'owner').exists()
            assert session_lock.stat().st_mtime_ns==before and not f.records()
            assert not (f.base/'stamps/session-one').exists()
        finally:
            shutil.rmtree(session_lock)
        key=hashlib.sha256(str(f.memory.resolve()).encode()).hexdigest()[:16]
        memory_lock=f.home/'.egregore/locks'/('memory-'+key);memory_lock.mkdir(parents=True)
        os.utime(memory_lock,(young,young))
        code='import sys;sys.path.insert(0,sys.argv[1]);from session_record import Lock;lock=Lock(sys.argv[2]);assert not lock.acquire();assert lock.path.exists() and lock.owner() is None'
        p=subprocess.run([sys.executable,'-c',code,str(f.root/'bin/lib'),str(memory_lock)],
                         env=f.env,text=True,capture_output=True,timeout=10)
        assert p.returncode==0,p.stdout+p.stderr
        shutil.rmtree(memory_lock)
test('F12. old ownerless session/memory locks recover while young locks remain untouched',ownerless_locks)


def local_remote(f):
    remote=f.temp/'remote.git';real_git=shutil.which('git')
    env={k:v for k,v in f.env.items() if not k.startswith('GIT_')}
    subprocess.run([real_git,'init','--bare','-q',str(remote)],check=True,capture_output=True,env=env)
    f.git('remote','add','origin',str(remote))
    def remote_git(*args):
        p=subprocess.run([real_git,'--git-dir='+str(remote),*args],env=env,text=True,capture_output=True)
        assert p.returncode==0,p.stderr
        return p.stdout.strip()
    return remote_git,real_git


def no_stub_end_recovers_deletion():
    for staged in (False,True):
        with fixture() as f:
            remote_git,_=local_remote(f)
            f.hook()
            old=f.records()[0];relative=str(old.relative_to(f.memory))
            unrelated=old.with_name('another-session.md')
            unrelated.write_text(old.read_text().replace('session-one','another-session'))
            other_relative=str(unrelated.relative_to(f.memory))
            f.git('add','--',other_relative);f.git('commit','-qm','fixture unrelated session');f.git('push','origin','HEAD')
            old.unlink();unrelated.unlink()
            if staged: f.git('add','--',relative)
            marker=f.base/'holds/session-one';marker.parent.mkdir(parents=True,exist_ok=True);marker.write_text('held')
            f.state['session_records_hold_stub']=False;f.save()
            head=f.git('rev-parse','HEAD');index=f.git('diff','--cached','--name-only');calls=f.calls()
            trail=(f.base/'session-one.md').read_text()
            f.path.write_text('not a readable transcript\n')
            f.hook('checkpoint')
            assert f.git('rev-parse','HEAD')==head and remote_git('rev-parse','HEAD')==head
            assert f.git('diff','--cached','--name-only')==index and f.calls()==calls
            assert relative in f.git('ls-tree','-r','--name-only','HEAD','--','sessions').splitlines()
            f.hook('end')
            local_paths=f.git('ls-tree','-r','--name-only','HEAD','--','sessions').splitlines()
            remote_paths=remote_git('ls-tree','-r','--name-only','HEAD','--','sessions').splitlines()
            assert relative not in local_paths and relative not in remote_paths,(local_paths,remote_paths,f.errors())
            assert other_relative in local_paths and other_relative in remote_paths
            assert f.git('diff','--name-only','--',other_relative)==other_relative
            assert not f.records() and not f.git('diff','--cached','--name-only')
            assert f.calls()==calls and not f.errors(),f.errors()
            assert (f.base/'session-one.md').read_text()==trail
test('S2. held no-stub end publishes pending deletion while checkpoints and unrelated deletions stay untouched',no_stub_end_recovers_deletion)


def no_stub_worker_end_recovers_deletion():
    with fixture() as f:
        remote_git,_=local_remote(f)
        f.hook('checkpoint')
        old=f.records()[0];relative=str(old.relative_to(f.memory))
        f.git('add','--',relative);f.git('commit','-qm','fixture checkpoint record');f.git('push','origin','HEAD')
        Path(f.env['FAKE_INPUT']).unlink()
        f.env['FAKE_SLEEP']='1.5'
        f.hook('checkpoint',wait=False);await_model(f)
        assert f.hook('end',wait=False)<2
        assert (f.base/'locks/session-one.end-requested').is_file()
        marker=f.base/'holds/session-one';marker.parent.mkdir(parents=True,exist_ok=True);marker.write_text('held')
        f.state['session_records_hold_stub']=False;f.save();old.unlink()
        f.wait()
        assert relative not in f.git('ls-tree','-r','--name-only','HEAD','--','sessions').splitlines()
        assert relative not in remote_git('ls-tree','-r','--name-only','HEAD','--','sessions').splitlines()
        assert not f.records() and len(f.calls(True))==2 and not f.errors(),f.errors()
        assert not (f.base/'locks/session-one.end-requested').exists()
test('S2. an active checkpoint worker drains held no-stub end requests and publishes the deletion',no_stub_worker_end_recovers_deletion)


def head_record_reads():
    with fixture() as f:
        limit=256*1024
        folder=f.memory/'sessions/2026-10';folder.mkdir(parents=True)
        for name,size in (('normal',100),('exact-limit',limit),('large',limit+100)):
            prefix='---\nsession: "'+name+'"\n---\n'
            path=folder/(name+'.md');path.write_text(prefix+'x'*(size-len(prefix)))
            f.git('add','--',str(path.relative_to(f.memory)))
        f.git('commit','-qm','fixture bounded HEAD reads')
        missing=folder/'missing-head.md';missing.write_text('working-tree-only record\n')
        code='''import sys
from pathlib import Path
sys.path.insert(0,sys.argv[1]);import session_record as sr
ctx=sr.Context(sys.argv[2]);limit=256*1024
for name in ('normal','exact-limit','large'):
    path=ctx.memory/'sessions/2026-10'/(name+'.md')
    text=sr.head_record_text(ctx,path)
    assert text==path.read_text()[:limit],path
    assert len(text)<=limit
    if name=='normal': assert sr.metadata(text)['session']=='normal'
missing=ctx.memory/'sessions/2026-10/missing-head.md'
try:
    sr.head_record_text(ctx,missing)
except RuntimeError as exc:
    assert str(exc)=='memory write failed: cannot read HEAD:sessions/2026-10/missing-head.md',str(exc)
else:
    raise AssertionError('working-tree-only record did not fail its HEAD read')
'''
        result=subprocess.run([sys.executable,'-c',code,str(f.root/'bin/lib'),str(f.root)],env=f.env,text=True,capture_output=True)
        assert result.returncode==0,result.stdout+result.stderr
test('S3. normal and exact-limit HEAD reads succeed and large records return only the deliberate bounded window',head_record_reads)


def head_record_failure():
    for partial in (False,True):
        with fixture() as f:
            remote_git,real_git=local_remote(f)
            f.hook()
            old=f.records()[0];relative=str(old.relative_to(f.memory));meta=sr.metadata(old.read_text())
            neutral=old.with_name(old.name[:3]+'cem-held-session-.md')
            neutral.write_text(sr.record_text(sr.stub_data(dict(meta,author=meta['from'],branch=meta['branch']))))
            old.unlink()
            head=f.git('rev-parse','HEAD')
            payload='---\nsession: "session-one"\n---\n' if partial else ''
            (f.fake/'git').write_text('#!/usr/bin/env python3\nimport os,sys\nargs=sys.argv[1:]\n'+
                'if "show" in args:\n    sys.stdout.write('+repr(payload)+')\n    sys.exit(74)\n'+
                'os.execv('+repr(real_git)+', ['+repr(real_git)+', *args])\n')
            (f.fake/'git').chmod(0o755)
            result=f.run('records.sh','redact','session-one')
            assert result.returncode==1 and result.stdout=='memory write failed: cannot read HEAD:'+relative+'\n',(result.stdout,result.stderr)
            assert f.git('rev-parse','HEAD')==head and remote_git('rev-parse','HEAD')==head
            assert relative in f.git('ls-tree','-r','--name-only','HEAD','--','sessions').splitlines()
            assert f.git('diff','--name-only','--',relative)==relative
            assert not (f.base/'holds/session-one').exists() and neutral.is_file()
test('S3. failed HEAD reads with empty or partial output fail explicitly and leave recovery uncommitted',head_record_failure)


def interrupted_hold_recovery():
    for retry in ('end', 'other-end', 'staged-legacy', 'no-stub', 'stale-capture', 'before-stub', 'no-local-evidence', 'prefix-only', 'ownerless-head'):
        with fixture() as f:
            remote_git,_=local_remote(f)
            f.hook()
            old=f.records()[0]
            old_relative=str(old.relative_to(f.memory))
            original=old.read_text()
            unrelated=old.with_name('unrelated-session.md')
            unrelated.write_text(original.replace('session-one','unrelated-session'))
            # Even a late session-looking header beyond the bounded metadata
            # window must not cause an unrelated deletion to be collected.
            oversized=old.with_name('oversized-unrelated.md')
            oversized.write_text('x'*(256*1024)+'\n**Session**: session-one\n')
            f.git('add','--',str(unrelated.relative_to(f.memory)),str(oversized.relative_to(f.memory)))
            f.git('commit','-qm','fixture unrelated records')
            meta=sr.metadata(original)
            held=sr.stub_data(dict(meta,author=meta['from'],branch=meta['branch']))
            if retry=='staged-legacy':
                old.write_text(sr.record_text(held))
                f.git('add','--',old_relative);f.git('commit','-qm','fixture topic-named legacy stub')
            elif retry=='ownerless-head':
                old.write_text(original.replace('from: "cem"\n','').replace('**Author**: cem\n',''))
                f.git('add','--',old_relative);f.git('commit','-qm','fixture legacy ownerless HEAD')
            f.git('push','origin','HEAD')
            neutral=old.with_name(old.name[:3]+'cem-held-session-.md')
            if retry not in ('no-stub','before-stub','no-local-evidence','prefix-only'):
                neutral.write_text(sr.record_text(held))
            old.unlink()
            unrelated.unlink()
            oversized.unlink()
            if retry=='staged-legacy':
                f.git('add','--',old_relative,str(neutral.relative_to(f.memory)))
            marker=f.base/'holds/session-one';marker.parent.mkdir(parents=True,exist_ok=True);marker.write_text('held')
            if retry in ('no-local-evidence','prefix-only'):
                f.path.unlink()
                (f.base/'session-one.md').unlink()
                result=f.run('records.sh','redact','session-o' if retry=='prefix-only' else 'session-one')
                assert result.returncode==0 and 'stubbed' in result.stdout,(result.stdout,result.stderr,f.errors())
            elif retry=='no-stub':
                f.state['session_records_hold_stub']=False;f.save()
                f.env['EGREGORE_NATIVE_SESSION_ID']='session-one'
                result=f.run('records.sh','hold')
                assert result.returncode==0 and 'removed' in result.stdout,(result.stdout,result.stderr,f.errors())
            elif retry=='ownerless-head':
                f.env['EGREGORE_NATIVE_SESSION_ID']='session-one'
                result=f.run('records.sh','hold')
                assert result.returncode==0 and 'stubbed' in result.stdout,(result.stdout,result.stderr,f.errors())
            elif retry=='other-end':
                next_path=f.transcript('session-two')
                next_path.write_text(next_path.read_text().replace('dev/cem/record-fixture','dev/cem/later-topic'))
                f.hook(path=next_path)
            elif retry=='stale-capture':
                held.update(mode='checkpoint')
                result=f.run('capture-run.sh','--mode','baseline','--replace-session','--record-metadata',json.dumps(held),
                             '--project-root',f.root,'--record-folder',f.prefix,input='')
                assert result.returncode==0,(result.stdout,result.stderr,f.errors())
            else:
                f.hook()
            expected=set(f.git('ls-tree','-r','--name-only','HEAD','--','sessions').splitlines())
            remote=set(remote_git('ls-tree','-r','--name-only','HEAD','--','sessions').splitlines())
            assert old_relative not in expected and old_relative not in remote,(retry,expected,remote,f.errors())
            if retry!='no-stub':
                assert neutral.is_file() and str(neutral.relative_to(f.memory)) in expected
                assert str(neutral.relative_to(f.memory)) in remote
            else:
                assert not neutral.exists()
            for pending in (unrelated,oversized):
                relative=str(pending.relative_to(f.memory))
                assert relative in expected and relative in remote and not pending.exists(),(retry,relative)
                assert f.git('diff','--name-only','--',relative)==relative
            assert not f.git('diff','--cached','--name-only')
            assert not f.errors(),(retry,f.errors())
test('R1. interrupted held renames recover deleted paths in HEAD and remote without staging unrelated deletions',interrupted_hold_recovery)


def deleted_prefix_validation():
    for case in ('ambiguous','foreign'):
        with fixture() as f:
            f.hook()
            old=f.records()[0]
            if case=='ambiguous':
                other=old.with_name('other-prefix-match.md')
                other.write_text(old.read_text().replace('session-one','session-other'))
                f.git('add','--',str(other.relative_to(f.memory)))
            else:
                old.write_text(old.read_text().replace('from: "cem"','from: "someone-else"')
                               .replace('**Author**: cem','**Author**: someone-else'))
                f.git('add','--',str(old.relative_to(f.memory)))
            f.git('commit','-qm','fixture deleted prefix ownership')
            for path in f.records(): path.unlink()
            f.path.unlink();(f.base/'session-one.md').unlink()
            result=f.run('records.sh','redact','session-o')
            assert result.returncode==1,(case,result.stdout,result.stderr)
            assert ('ambiguous' if case=='ambiguous' else 'another person') in result.stdout,result.stdout
            assert not list((f.base/'holds').glob('*')) and not f.records()
test('R1. deleted-only session prefix lookup retains ambiguity and ownership checks before holding',deleted_prefix_validation)


def held_filename_collision():
    with fixture() as f:
        first_id='samepref-first-session';second_id='samepref-second-session'
        for sid in (first_id,second_id):
            path=f.transcript(sid)
            f.hook(path=path)
            f.env['EGREGORE_NATIVE_SESSION_ID']=sid
            result=f.run('records.sh','hold')
            assert result.returncode==0 and 'stubbed' in result.stdout,(result.stdout,result.stderr,f.errors())
        by_id={sr.metadata(path.read_text())['session']:path for path in f.records()}
        first=by_id[first_id];second=by_id[second_id]
        assert first.name.endswith('-cem-held-samepref.md')
        assert second.name.endswith('-cem-held-'+second_id+'.md')
        assert first!=second and all(sr.metadata(path.read_text())['detail']=='stub' for path in by_id.values())
        assert all('record fixture' not in path.read_text() for path in by_id.values())
        f.state['session_records_hold_stub']=False;f.save()
        f.env['EGREGORE_NATIVE_SESSION_ID']=first_id
        result=f.run('records.sh','hold')
        assert result.returncode==0 and not first.exists(),(result.stdout,result.stderr)
        f.state['session_records_hold_stub']=True;f.save()
        f.env['EGREGORE_NATIVE_SESSION_ID']=second_id
        result=f.run('records.sh','hold')
        assert result.returncode==0 and f.records()==[second],(result.stdout,result.stderr,f.records())
        assert f.git('ls-tree','-r','--name-only','HEAD','--','sessions')==str(second.relative_to(f.memory))
        assert not f.errors(),f.errors()
    with fixture() as f:
        f.hook()
        old=f.records()[0]
        short=old.with_name(old.name[:3]+'cem-held-session-.md')
        full=old.with_name(old.name[:3]+'cem-held-session-one.md')
        short.symlink_to(f.temp/'absent-target')
        occupied=old.read_text().replace('session-one','another-session')
        full.write_text(occupied)
        f.env['EGREGORE_NATIVE_SESSION_ID']='session-one'
        result=f.run('records.sh','hold')
        assert result.returncode==1 and old.exists() and full.read_text()==occupied,(result.stdout,result.stderr)
        assert short.is_symlink() and not short.exists()
        full.unlink()
        result=f.run('records.sh','hold')
        assert result.returncode==0 and not old.exists() and full.is_file(),(result.stdout,result.stderr)
        assert sr.metadata(full.read_text())['session']=='session-one' and short.is_symlink()
test('R3. held filename collisions use the full session ID and preserve that fallback on retry',held_filename_collision)


def publication_hold():
    for batch in (False, True):
        for keep_stub in (True, False):
            with fixture() as f:
                f.state['session_records_hold_stub']=keep_stub;f.save()
                remote_git,real_git=local_remote(f)
                blocked=f.temp/'push-waiting'
                (f.fake/'git').write_text('#!/bin/bash\nfor arg in "$@"; do\n  if [ "$arg" = push ]; then\n    touch '+shlex.quote(str(blocked))+'\n    sleep 3\n  fi\ndone\nexec '+shlex.quote(real_git)+' "$@"\n')
                (f.fake/'git').chmod(0o755)
                (f.memory/'unrelated').write_text('stay staged');f.git('add','unrelated')
                publication=None
                if batch:
                    publication=subprocess.Popen(['bash',str(f.root/'bin/records.sh'),'backfill','--yes'],env=f.env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                else:
                    f.hook(wait=False)
                deadline=time.monotonic()+15
                while not blocked.exists():
                    assert time.monotonic()<deadline,'push did not start: '+f.errors()
                    time.sleep(.02)
                hold_path=f.base/'holds/session-one'
                assert not hold_path.exists()
                hold_env=dict(f.env,EGREGORE_NATIVE_SESSION_ID='session-one')
                started=time.monotonic()
                hold_proc=subprocess.Popen(['bash',str(f.root/'bin/records.sh'),'hold'],env=hold_env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                try:
                    time.sleep(.3)
                    assert hold_proc.poll() is None and not hold_path.exists(),'hold marker interleaved with publication'
                    if publication:
                        stdout,stderr=publication.communicate(timeout=25)
                        assert publication.returncode==0,(stdout,stderr,f.errors())
                    stdout,stderr=hold_proc.communicate(timeout=25)
                    assert hold_proc.returncode==0,(stdout,stderr,f.errors())
                    assert time.monotonic()-started>=2 and hold_path.exists()
                    assert ('stubbed' if keep_stub else 'removed') in stdout,stdout
                    f.wait(timeout=25)
                    revisions=remote_git('log','--all','--format=%H','--','sessions').splitlines()
                    assert len(revisions)==2,(revisions,f.errors())
                    earlier_files=remote_git('ls-tree','-r','--name-only',revisions[1],'--','sessions').splitlines()
                    assert len(earlier_files)==1,earlier_files
                    content=remote_git('show',revisions[1]+':'+earlier_files[0])
                    assert '## Asked' in content and 'Keep the durable lock' in content
                    latest_files=remote_git('ls-tree','-r','--name-only',revisions[0],'--','sessions').splitlines()
                    if keep_stub:
                        assert len(latest_files)==1 and latest_files!=earlier_files,latest_files
                        assert latest_files[0].endswith('-cem-held-session-.md'),latest_files
                        content=remote_git('show',revisions[0]+':'+latest_files[0])
                        assert 'detail: stub' in content and '## Asked' not in content
                    else:
                        assert not latest_files and not f.records()
                    assert remote_git('rev-list','--all','--count')=='3'
                    assert f.git('diff','--cached','--name-only')=='unrelated'
                    assert not f.errors(),f.errors()
                finally:
                    if hold_proc.poll() is None: hold_proc.wait(timeout=30)
                    if publication and publication.poll() is None: publication.wait(timeout=30)
test('G2. single and batch publication finish before hold marker and subsequent stub/removal',publication_hold)

def hold_before_end():
    for keep_stub in (True,False):
        with fixture() as f:
            f.state['session_records_hold_stub']=keep_stub;f.save()
            remote_git,_=local_remote(f)
            f.env['EGREGORE_NATIVE_SESSION_ID']='session-one'
            p=f.run('records.sh','hold')
            assert p.returncode==0 and 'none yet' in p.stdout,(p.stdout,p.stderr)
            assert (f.base/'holds/session-one').exists()
            f.hook()
            revisions=remote_git('log','--all','--format=%H','--','sessions').splitlines()
            if keep_stub:
                assert len(revisions)==1,revisions
                paths=remote_git('ls-tree','-r','--name-only',revisions[0],'--','sessions').splitlines()
                assert len(paths)==1,paths
                content=remote_git('show',revisions[0]+':'+paths[0])
                assert 'detail: stub' in content and '## Asked' not in content and 'Keep the durable lock' not in content
            else:
                assert not revisions and not f.records()
            assert not f.calls() and not f.errors()
test('G2. hold placed before end commit publishes only a stub or no record',hold_before_end)

def crashed_records():
    for keep_stub in (True,False):
        with fixture() as f:
            f.state['session_records_hold_stub']=keep_stub;f.save()
            month=f.memory/'sessions'/datetime.now(timezone.utc).strftime('%Y-%m')
            month.mkdir(parents=True)
            def leftover(sid,author='cem'):
                path=month/(sid+'.md')
                path.write_text('---\nkind: session-record\nfrom: "'+author+'"\n'+
                                'detail: outline\nstatus: in progress\nrecord_revision: 1\n'+
                                'cost_usd: 1.25\ncost_source: ledger\nduration: 5m\n---\n'+
                                '# Session: earlier work\n\n**Date**: '+datetime.now(timezone.utc).isoformat()+'\n'+
                                '**Author**: '+author+'\n**Session**: '+sid+'\n**Duration**: 5m\n\n'+
                                '## Summary\nCRASH_PRIVATE '+sid+'\n\n## Asked\n- Earlier topic\n')
                return path
            modified=leftover('crashed-modified')
            f.git('add','--',str(modified.relative_to(f.memory)));f.git('commit','-qm','fixture earlier record')
            modified.write_text(modified.read_text()+'\nA later checkpoint remained here.\n')
            own=leftover('crashed-untracked')
            held=leftover('crashed-held')
            foreign=leftover('someone-elses-record','someone-else')
            foreign_before=foreign.read_text()
            f.git('add','--',str(foreign.relative_to(f.memory)))
            marker=f.base/'holds/crashed-held';marker.parent.mkdir(parents=True);marker.write_text('held before publication')
            f.hook()
            committed=set(f.git('show','--format=','--name-only','HEAD').splitlines())
            expected={str(modified.relative_to(f.memory)),str(own.relative_to(f.memory))}
            if keep_stub:
                neutral=next(path for path in f.records() if sr.metadata(path.read_text()).get('session')=='crashed-held')
                expected.add(str(neutral.relative_to(f.memory)))
            current=next(path for path in f.records() if '**Session**: session-one\n' in path.read_text())
            expected.add(str(current.relative_to(f.memory)))
            assert committed==expected,(committed,expected,f.errors())
            assert f.git('diff','--cached','--name-only')==str(foreign.relative_to(f.memory))
            assert foreign.read_text()==foreign_before
            for path in (modified,own):
                assert not f.git('status','--porcelain','--',str(path.relative_to(f.memory)))
            if keep_stub:
                assert not held.exists() and 'detail: stub' in neutral.read_text() and 'CRASH_PRIVATE' not in neutral.read_text()
            else:
                assert not held.exists()
            assert not f.errors(),f.errors()
test('G1. end commits own modified/untracked leftovers, honors holds, and leaves foreign staged records alone',crashed_records)

def held_end_collects_leftovers():
    with fixture() as f:
        f.hook('checkpoint')
        current=f.records()[0]
        leftover=current.with_name('earlier-session.md')
        leftover.write_text(current.read_text().replace('session-one','earlier-session'))
        f.state['session_records_hold_stub']=False;f.save()
        f.env['FAKE_SLEEP']='1'
        f.hook(wait=False)
        f.env['EGREGORE_NATIVE_SESSION_ID']='session-one'
        result=f.run('records.sh','hold')
        assert result.returncode==0,(result.stdout,result.stderr,f.errors())
        f.wait()
        assert not current.exists() and leftover.exists()
        assert f.git('show','--format=','--name-only','HEAD')==str(leftover.relative_to(f.memory))
        assert not f.git('status','--porcelain','--',str(leftover.relative_to(f.memory)))
        assert f.git('rev-list','--count','HEAD')=='2'
test('G1. an end build removing its held record still commits earlier own leftovers',held_end_collects_leftovers)

def staging_boundaries():
    for kind in ('directory', 'file', 'inside-file', 'nested-directory'):
        with fixture() as f:
            f.base.mkdir(parents=True)
            outside=f.temp/'foreign-staging';outside.mkdir()
            sentinel=outside/'foreign.md';sentinel.write_text('foreign staged content must not be read')
            stage=f.base/'backfill-staging'
            if kind=='directory':
                stage.symlink_to(outside,target_is_directory=True)
            else:
                stage.mkdir()
                if kind=='nested-directory':
                    (stage/'sessions').symlink_to(outside,target_is_directory=True)
                else:
                    month=stage/'sessions/2026-10';month.mkdir(parents=True)
                    if kind=='inside-file':
                        sentinel=month/'source.md';sentinel.write_text('inside symlink target')
                    (month/'alias.md').symlink_to(sentinel)
            before=sentinel.read_text()
            result=f.run('records.sh','backfill','--yes')
            assert result.returncode==0,(result.stdout,result.stderr)
            assert 'failed: 1' in result.stdout and 'built: 0' in result.stdout,result.stdout
            assert 'invalid backfill staging' in f.errors(),f.errors()
            assert sentinel.read_text()==before and not f.records() and not f.calls(True)
            assert f.git('rev-list','--count','HEAD')=='1'
    with fixture() as f:
        stage=f.base/'backfill-staging';stage.mkdir(parents=True)
        outside=f.temp/'outside.md';outside.write_text('not staged record data')
        link=stage/'record.md';link.symlink_to(outside)
        code='''import sys
sys.path.insert(0,sys.argv[1])
from collections import Counter
from pathlib import Path
import session_record as sr
ctx=sr.Context(sys.argv[2])
assert sr.publish_batch(ctx,[(ctx,Path(sys.argv[3]))],Counter(),0)==(0,1)
'''
        result=subprocess.run([sys.executable,'-c',code,str(f.root/'bin/lib'),str(f.root),str(link)],
                              env=f.env,text=True,capture_output=True)
        assert result.returncode==0,result.stdout+result.stderr
        assert 'invalid backfill staging file' in f.errors() and outside.read_text()=='not staged record data'
test('G3. staging directories and every staged-file read reject symlinks before opening',staging_boundaries)

def resumed_after_discovery():
    with fixture() as f:
        # Version discovery occurs after candidate discovery and before locks.
        f.env['FAKE_TOUCH_ON_VERSION']=str(f.path)
        result=f.run('records.sh','backfill','--yes')
        assert result.returncode==0,(result.stdout,result.stderr)
        assert 'skipped live: 1' in result.stdout and 'built: 0; skipped: 1; failed: 0' in result.stdout,result.stdout
        assert not f.records() and not f.calls(True) and not f.errors()
        assert f.git('rev-list','--count','HEAD')=='1'
        assert not (f.base/'locks/session-one').exists()
test('G5. transcript resumed after discovery is skipped as live under the session lock',resumed_after_discovery)


# Harness fixtures never use the caller's HOME or session identities.
from unittest.mock import patch

@contextlib.contextmanager
def native_fixture():
    with fixture() as f:
        f.path.unlink()
        f.config['features']['session_records']['model']='none'
        f.state['session_records_noticed']=True
        # Enrolled before every fixture session, history not accepted: the
        # sweep tests below run on the path a person who answered no takes.
        f.state['session_records_since']='2000-01-01T00:00:00+00:00'
        f.save()
        with patch.dict(os.environ, f.env, clear=True):
            yield f

def native_transcript(f,sid,harness='codex',ago=0,idle=1200,parent=None,folder_date=None,files=()):
    end=datetime.now(timezone.utc)-timedelta(days=ago,seconds=1200)
    start=end-timedelta(minutes=5)
    if harness=='codex':
        folder=f.home/'.codex/sessions'/(folder_date or start.strftime('%Y/%m/%d'))
        path=folder/('rollout-fixture-'+sid+'.jsonl')
        payload={'id':sid,'session_id':sid,'cwd':str(f.root),'timestamp':start.isoformat(),
                 'originator':'codex-tui','source':'cli',
                 'git':{'branch':'dev/cem/native-fixture'}}
        if parent:payload.update(parent)
        entries=[{'type':'session_meta','timestamp':start.isoformat(),'payload':payload},
                 {'type':'turn_context','timestamp':start.isoformat(),'payload':{'model':'gpt-6'}},
                 {'type':'event_msg','timestamp':start.isoformat(),'payload':{'type':'item_completed','item':{'type':'UserMessage','content':[{'text':'Improve native recording'}]}}}]
        for value in files:
            entries.append({'type':'event_msg','timestamp':end.isoformat(),'payload':{'type':'item_completed','item':{'type':'FileChange','changes':{str(f.root/value):{'type':'update','unified_diff':'private'}},'status':'completed'}}})
        entries.append({'type':'event_msg','timestamp':end.isoformat(),'payload':{'type':'task_complete','duration_ms':300000}})
    else:
        folder=f.home/('.'+harness)/'agent/sessions'/sid
        path=folder/'session.jsonl'
        entries=[{'type':'session','version':3,'id':sid,'cwd':str(f.root),'timestamp':start.isoformat()},
                 {'type':'message','timestamp':start.isoformat(),'message':{'role':'user','content':'Improve native recording'}},
                 {'type':'message','timestamp':end.isoformat(),'message':{'role':'assistant','model':'fixture-model','content':[{'type':'text','text':'Completed the implementation.'}], 'usage':{'cost':{'total':0.25}}}}]
    folder.mkdir(parents=True,exist_ok=True)
    path.write_text('\n'.join(map(json.dumps,entries))+'\n')
    os.utime(path,(time.time()-idle,)*2)
    return path

def native_append(path,text='Continue native work',idle=1200):
    last=st.last_event_time(path,st.read_header(path))
    stamp=datetime.fromtimestamp(last+300,timezone.utc).isoformat()
    if st.probe_format(path)=='codex':
        row={'type':'event_msg','timestamp':stamp,'payload':{'type':'item_completed','item':{'type':'UserMessage','content':[{'text':text}]}}}
    else:
        row={'type':'message','timestamp':stamp,'message':{'role':'user','content':text}}
    with path.open('a') as stream:stream.write(json.dumps(row)+'\n')
    os.utime(path,(time.time()-idle,)*2)

def run_sweep(f,force=True):
    result=f.run('session-record.sh','--mode','sweep',*(('--force',) if force else ()))
    assert result.returncode==0 and not result.stdout and not result.stderr
    lock=f.base/'locks/sweep'
    until=time.monotonic()+25
    while lock.exists():
        assert time.monotonic()<until,'sweep stuck: '+f.errors()
        time.sleep(.04)
    assert not f.errors(),f.errors()

def native_rows(f):
    return {sr.metadata(path.read_text())['session']:(path,sr.metadata(path.read_text()),path.read_text()) for path in f.records()}

def sweep_gates_and_batch():
    with native_fixture() as f:
        for sid in ('codex-one','codex-two'):native_transcript(f,sid)
        live=native_transcript(f,'codex-live',idle=0)
        held=native_transcript(f,'codex-held')
        native_transcript(f,'codex-held-child',parent={'parent_thread_id':'codex-held'})
        foreign=native_transcript(f,'foreign')
        entries=foreign.read_text().splitlines();header=json.loads(entries[0]);header['payload']['cwd']=str(f.temp/'other')
        foreign.write_text(json.dumps(header)+'\ninvalid JSON must not be read\n')
        marker=f.base/'holds/codex-held';marker.parent.mkdir(parents=True);marker.write_text('hold')
        ctx=sr.Context(f.root)
        assert foreign not in sr.discover_paths(ctx)
        f.state['session_records_noticed']=False;f.save();run_sweep(f)
        assert not f.records() and not (f.base/'sweep.stamp').exists()
        f.state['session_records_noticed']=True;f.state['session_records_enabled']=False;f.save();run_sweep(f)
        assert not f.records()
        f.state['session_records_enabled']=True;f.save();run_sweep(f,force=False)
        assert set(native_rows(f))=={'codex-one','codex-two'},native_rows(f)
        assert f.git('rev-list','--count','HEAD')=='2'
        assert all(row[1]['cost_source']=='unavailable' and row[1]['status']=='in progress' and row[1]['through'] for row in native_rows(f).values())
        native_transcript(f,'codex-later');run_sweep(f,force=False)
        assert len(f.records())==2 and f.git('rev-list','--count','HEAD')=='2'
        for harness in ('codex','pi','prime'):
            folder=f.home/'.egregore/trails'/(f.prefix+'--'+harness);folder.mkdir(exist_ok=True)
            assert st.valid_trail_folder(folder,ctx.projects,ctx.prefix)
        bad=f.home/'.egregore/trails'/(f.prefix+'--bogus');bad.mkdir()
        assert not st.valid_trail_folder(bad,ctx.projects,ctx.prefix)
test('H4–H5. sweep is consent-gated, one commit, debounced, idle-only and instance-gated',sweep_gates_and_batch)

def native_holds():
    with native_fixture() as f:
        path=native_transcript(f,'codex-parent')
        native_transcript(f,'child',parent={'forked_from_id':'codex-parent'})
        env=dict(f.env,CODEX_THREAD_ID='codex-parent')
        result=f.run('records.sh','hold',env=env)
        assert result.returncode==0,(result.stdout,result.stderr)
        ctx=sr.Context(f.root)
        assert ctx.held('codex-parent')
        assert sr.candidates(ctx,90)[0]==[]
        assert sr.refresh_index(ctx)['unrecorded_count']==0
        run_sweep(f);assert not f.records()
    for harness in ('pi','prime'):
        with native_fixture() as f:
            path=native_transcript(f,'pi-native',harness)
            aliasdir=f.home/('.'+harness)/'agent/sessions/alias'
            aliasdir.symlink_to(path.parent,target_is_directory=True)
            spelling=aliasdir/path.name
            digest=hashlib.sha256(str(spelling).encode()).hexdigest()
            base=f.home/'.egregore/trails'/(f.prefix+'--'+harness);base.mkdir(parents=True)
            (base/'aliases.jsonl').write_text(json.dumps({'hash':digest,'path':str(spelling),'session':'pi-native'})+'\n')
            # A hash-only marker is sufficient even before a second marker is written.
            (base/'holds').mkdir();(base/'holds'/digest).write_text('held')
            ctx=sr.Context(f.root)
            assert ctx.held('pi-native',path) and ctx.held('pi-native',spelling)
            assert sr.candidates(ctx,90)[0]==[]
            env=dict(f.env,EGREGORE_NATIVE_SESSION_ID=digest,EGREGORE_NATIVE_HARNESS=harness)
            result=f.run('records.sh','hold',env=env)
            assert result.returncode==0,(result.stdout,result.stderr)
            assert (base/'holds/pi-native').is_file() and (base/'holds'/digest).is_file()
            f.state['session_records_hold_stub']=False;f.save()
            f.hook(path=spelling,sid='egregore-id',wait=False)
            time.sleep(.1)
            assert not f.records()
    with native_fixture() as f:
        path=native_transcript(f,'raw-spelling','pi')
        spelling=str(path.parent)+'/./'+path.name
        digest=hashlib.sha256(spelling.encode()).hexdigest()
        base=f.home/'.egregore/trails'/(f.prefix+'--pi');(base/'holds').mkdir(parents=True)
        (base/'holds'/digest).write_text('held before alias capture')
        f.hook(path=spelling,sid='egregore-id',wait=False)
        lock=base/'locks/raw-spelling';until=time.monotonic()+20
        while lock.exists():
            assert time.monotonic()<until,'Pi end did not finish'
            time.sleep(.04)
        assert sr.metadata(f.text())['detail']=='stub',f.text()
        assert not f.calls() and not f.errors(),f.errors()
test('H6/R2/R6. Codex family holds and Pi/Prime alias holds cover discovery and hooks',native_holds)

def native_revisions():
    for harness in ('codex','pi','prime'):
        with native_fixture() as f:
            path=native_transcript(f,'continued',harness)
            run_sweep(f)
            meta=native_rows(f)['continued'][1]
            assert meta['record_revision']==1 and meta['status']=='in progress',meta
            native_append(path,idle=90000)
            run_sweep(f)
            row=native_rows(f)['continued'];assert row[1]['record_revision']==2 and row[1]['status']=='final',row
            trail=f.home/'.egregore/trails'/(f.prefix+'--'+harness)/'continued.md'
            assert trail.read_text().count('ASK ')==2,trail.read_text()
            native_append(path)
            run_sweep(f)
            assert native_rows(f)['continued'][1]['record_revision']==3
            assert native_rows(f)['continued'][1]['status']=='final'
            marker=trail.parent/'holds/continued';marker.parent.mkdir(exist_ok=True);marker.write_text('held')
            native_append(path);run_sweep(f)
            assert native_rows(f)['continued'][1]['record_revision']==3
    with native_fixture() as f:
        path=native_transcript(f,'paused')
        run_sweep(f)
        os.utime(path,(time.time()-90000,)*2)
        # Finalization ignores activity window and does not require new events.
        f.config['features']['session_records']['retroactive_days']=0;f.save()
        run_sweep(f)
        assert native_rows(f)['paused'][1]['status']=='final'
        assert native_rows(f)['paused'][1]['record_revision']==2
        run_sweep(f);assert native_rows(f)['paused'][1]['record_revision']==2
test('R1/R7. native records refresh, finalize without append, and remain final after resume',native_revisions)

def claude_killed_tab_finalized():
    # A killed tab never runs SessionEnd: the Stop checkpoint is the last write.
    with fixture() as f:
        f.state['session_records_noticed']=True;f.save()
        with patch.dict(os.environ, f.env, clear=True):
            f.hook('checkpoint')
            meta=sr.metadata(f.text());assert meta['status']=='in progress' and int(meta['record_revision'])==1,meta
            run_sweep(f)
            meta=sr.metadata(f.text());assert meta['status']=='in progress' and int(meta['record_revision'])==1,meta
            os.utime(f.path,(time.time()-90000,)*2)
            f.config['features']['session_records']['retroactive_days']=0;f.save()
            run_sweep(f)
            meta=sr.metadata(f.text());assert meta['status']=='final' and int(meta['record_revision'])==2,meta
            run_sweep(f)
            assert int(sr.metadata(f.text())['record_revision'])==2
test('R8. a Claude record a killed tab left in progress is finished after a day idle, once',claude_killed_tab_finalized)

def complete_codex_families():
    with native_fixture() as f:
        parent=native_transcript(f,'old-parent',ago=200,idle=90000,folder_date='2020/01/01')
        oldchild=native_transcript(f,'old-child',ago=150,idle=90000,parent={'parent_thread_id':'old-parent'},files=('old-child.py',))
        recent=native_transcript(f,'recent-child',ago=1,parent={'parent_thread_id':'old-parent'},folder_date='2026/01/01')
        ctx=sr.Context(f.root)
        rows,_=sr.candidates(ctx,90)
        assert len(rows)==1 and rows[0][1]==parent and rows[0][3]==3,rows
        run_sweep(f)
        assert 'old-child.py' in native_rows(f)['old-parent'][2]
        native_append(recent);run_sweep(f)
        assert native_rows(f)['old-parent'][1]['record_revision']==2
        assert 'old-child.py' in native_rows(f)['old-parent'][2]
        # Family activity blocks publication even when the root itself is idle.
        recent.touch();assert sr.candidates(ctx,90)[0]==[]
        index=sr.codex_header_index(ctx)
        with patch.object(st,'read_header',side_effect=AssertionError('unchanged index reread a header')):
            assert sr.codex_header_index(ctx)==index
    with native_fixture() as f:
        parent=native_transcript(f,'root',folder_date='2020/01/01')
        forms=[{'parent_thread_id':'root'},{'forked_from_id':'root'},
               {'source':{'subagent':{'thread_spawn':{'parent_thread_id':'root'}}}}, {'session_id':'root'}]
        for n,relation in enumerate(forms):native_transcript(f,'form-'+str(n),parent=relation,files=('form-'+str(n)+'.py',))
        ctx=sr.Context(f.root)
        assert list(sr.discover_paths(ctx))==[parent]
        rows,_=sr.candidates(ctx,90)
        assert len(rows)==1 and rows[0][3]==5,rows
        assert sr.refresh_index(ctx)['unrecorded_count']==1
        run_sweep(f)
        text=native_rows(f)['root'][2]
        assert all('form-'+str(n)+'.py' in text for n in range(4)),text
test('R4/R7. cached complete families use descendant activity and retain old children',complete_codex_families)


def native_resume_during_sweep():
    for harness in ('codex','pi'):
        with native_fixture() as f:
            path=native_transcript(f,'resumed',harness)
            f.config['features']['session_records']['model']='haiku';f.save()
            f.env['FAKE_SLEEP']='1.5'
            result=f.run('session-record.sh','--mode','sweep','--force')
            assert result.returncode==0
            await_model(f)
            native_append(path,idle=0)
            lock=f.base/'locks/sweep';until=time.monotonic()+20
            while lock.exists():
                assert time.monotonic()<until,'sweep did not finish'
                time.sleep(.04)
            assert not f.records() and not f.errors(),f.errors()
            assert f.git('rev-list','--count','HEAD')=='1'
test('H5. native sessions resumed during outline generation stay unpublished',native_resume_during_sweep)

def sweep_limit_and_native_backfill():
    with native_fixture() as f:
        for index in range(21):native_transcript(f,'limited-'+str(index))
        run_sweep(f)
        assert len(f.records())==20 and f.git('rev-list','--count','HEAD')=='2'
    with native_fixture() as f:
        native_transcript(f,'backfilled-codex')
        native_transcript(f,'backfilled-pi','pi')
        native_transcript(f,'backfilled-prime','prime')
        result=f.run('records.sh','backfill','--yes')
        assert result.returncode==0,(result.stdout,result.stderr)
        assert set(native_rows(f))=={'backfilled-codex','backfilled-pi','backfilled-prime'},result.stdout+f.errors()
        assert f.git('rev-list','--count','HEAD')=='2'
        assert all(row[1]['backfill'] for row in native_rows(f).values())
test('H4–H5. sweeps cap publication at 20 and backfill uses native header identities',sweep_limit_and_native_backfill)

def state_file(f):
    return json.loads((f.root/'.egregore-state.json').read_text())

def enrolled(f,hours=1):
    f.state['session_records_since']=(datetime.now(timezone.utc)-timedelta(hours=hours)).isoformat();f.save()
    return sr.event_time(f.state['session_records_since'])

def declined_history():
    with native_fixture() as f:
        f.state.pop('session_records_since');f.state['session_records_noticed']=False;f.save()
        before=time.time()
        result=f.run('records.sh','noticed');assert result.returncode==0,(result.stdout,result.stderr)
        first=state_file(f)
        assert first['session_records_noticed'] is True and 'session_records_backfill' not in first,first
        assert before-1<=sr.event_time(first['session_records_since'])<=time.time()+1,first
        result=f.run('records.sh','noticed');assert result.returncode==0,(result.stdout,result.stderr)
        assert state_file(f)['session_records_since']==first['session_records_since']
    with native_fixture() as f:
        since=enrolled(f)
        native_transcript(f,'after-enrollment')
        before=native_transcript(f,'before-enrollment',ago=10)
        run_sweep(f)
        assert set(native_rows(f))=={'after-enrollment'},native_rows(f)
        ctx=sr.Context(f.root)
        rows,skipped=sr.candidates(ctx,90,since=since)
        assert not rows and skipped['before enrollment']==1,(rows,skipped)
        # Only the boundary holds it back: without it the session is eligible.
        assert [row[1] for row in sr.candidates(ctx,90)[0]]==[before]
        state=state_file(f)
        assert state['session_records_since']==f.state['session_records_since'] and 'session_records_backfill' not in state
test('C1. after a no, the sweep records a session started after enrollment and skips an earlier one inside the window',declined_history)

def accepted_history():
    with native_fixture() as f:
        enrolled(f)
        for args in (('backfill',),('backfill','--dry-run'),('backfill','--yes','--dry-run')):
            result=f.run('records.sh',*args);assert result.returncode==0,(result.stdout,result.stderr)
            assert 'session_records_backfill' not in state_file(f),args
        before=time.time()
        result=f.run('records.sh','backfill','--yes');assert result.returncode==0,(result.stdout,result.stderr)
        state=state_file(f)
        assert state['session_records_backfill']=='accepted',state
        assert before-1<=sr.event_time(state['session_records_backfill_accepted_at'])<=time.time()+1,state
        f.state=state
        native_transcript(f,'older-codex',ago=10)
        native_transcript(f,'older-pi','pi',ago=10)
        native_transcript(f,'outside-window',ago=120)
        run_sweep(f)
        assert set(native_rows(f))=={'older-codex','older-pi'},native_rows(f)
test('C2. after backfill --yes, the sweep records older sessions inside the window as before',accepted_history)

def existing_noticed_state():
    with native_fixture() as f:
        native_transcript(f,'published-earlier');run_sweep(f)
        assert set(native_rows(f))=={'published-earlier'}
        # An install that answered before enrollment existed, with records out.
        f.state.pop('session_records_since');f.state['session_records_backfilled_through']='2026-01-01';f.save()
        native_transcript(f,'older',ago=10)
        native_transcript(f,'recent')
        before=time.time();run_sweep(f);after=time.time()
        state=state_file(f)
        assert before-1<=sr.event_time(state['session_records_since'])<=after+1,state
        assert 'session_records_backfill' not in state,state
        assert set(native_rows(f))=={'published-earlier'},native_rows(f)
        run_sweep(f)
        assert state_file(f)['session_records_since']==state['session_records_since']
        assert set(native_rows(f))=={'published-earlier'},native_rows(f)
test('C3. a noticed install without enrollment is enrolled at its first sweep and skips older sessions',existing_noticed_state)

def unknown_start_skipped():
    with native_fixture() as f:
        since=enrolled(f)
        path=f.transcript('no-clock',commit=True)
        lines=[json.loads(line) for line in path.read_text().splitlines()]
        for line in lines:line.pop('timestamp',None)
        path.write_text('\n'.join(map(json.dumps,lines))+'\n');os.utime(path,(time.time()-1200,)*2)
        ctx=sr.Context(f.root)
        assert [row[1] for row in sr.candidates(ctx,90)[0]]==[path]
        rows,skipped=sr.candidates(ctx,90,since=since)
        assert not rows and skipped['start unknown']==1,(rows,skipped)
        run_sweep(f)
        assert not f.records()
        f.state=state_file(f);f.state['session_records_backfill']='accepted';f.save()
        run_sweep(f)
        assert set(native_rows(f))=={'no-clock'},native_rows(f)
test('C4. a session whose start cannot be determined is skipped until history is accepted',unknown_start_skipped)

def declined_off_and_holds():
    with native_fixture() as f:
        since=enrolled(f)
        native_transcript(f,'while-off')
        result=f.run('records.sh','off');assert result.returncode==0,(result.stdout,result.stderr)
        run_sweep(f)
        assert not f.records() and not (f.base/'sweep.stamp').exists()
        assert state_file(f)['session_records_since']==f.state['session_records_since']
    with native_fixture() as f:
        enrolled(f)
        native_transcript(f,'held-new')
        result=f.run('records.sh','hold',env=dict(f.env,CODEX_THREAD_ID='held-new'))
        assert result.returncode==0,(result.stdout,result.stderr)
        path=native_transcript(f,'redacted-later')
        run_sweep(f)
        assert set(native_rows(f))=={'redacted-later'},native_rows(f)
        result=f.run('records.sh','redact','redacted-later')
        assert result.returncode==0 and 'stubbed' in result.stdout,(result.stdout,result.stderr)
        native_append(path);run_sweep(f)
        assert set(native_rows(f))=={'redacted-later'} and native_rows(f)['redacted-later'][1]['detail']=='stub'
test('C5. after a no, off still records nothing and holds still skip or stub as before',declined_off_and_holds)


def malformed_codex_inventory():
    with native_fixture() as f:
        path=native_transcript(f,'valid-rollout')
        for index,body in enumerate(('', 'garbage', '[]', '{"type":"session_meta","payload":null}')):
            (path.parent/('rollout-invalid-'+str(index)+'.jsonl')).write_text(body)
        ctx=sr.Context(f.root)
        assert list(sr.discover_paths(ctx))==[path]
        cache=f.home/'.egregore/trails'/(f.prefix+'--codex')/'header-index.json'
        original=json.loads(cache.read_text())[str(path)]
        for bad in ([],None,1,{'key':original['key'],'header':[]},
                    dict(original,header=[]),dict(original,last_event='bad')):
            cache.write_text(json.dumps({str(path):bad}))
            assert list(sr.discover_paths(ctx))==[path],bad
        run_sweep(f)
        assert set(native_rows(f))=={'valid-rollout'}
test('H4. malformed rollout headers and malformed cache rows cannot stop discovery',malformed_codex_inventory)

def short_native_record_finalization():
    for harness in ('codex','pi','prime'):
        with native_fixture() as f:
            sid='short-'+harness
            path=native_transcript(f,sid,harness)
            rows=[json.loads(line) for line in path.read_text().splitlines()]
            first=datetime.fromisoformat(rows[0]['timestamp'])
            rows[-1]['timestamp']=(first+timedelta(seconds=30)).isoformat()
            path.write_text('\n'.join(map(json.dumps,rows))+'\n')
            f.hook(path=path,sid='egregore-id',wait=False)
            lock=f.home/'.egregore/trails'/(f.prefix+'--'+harness)/'locks'/sid
            until=time.monotonic()+20
            while lock.exists():
                assert time.monotonic()<until,'native end did not finish'
                time.sleep(.04)
            meta=native_rows(f)[sid][1]
            assert meta['status']=='final' and meta['record_revision']==1,meta
            assert meta['cost_sessions']==[sid],meta
            assert meta['cost_coverage'] in ('complete','partial','unavailable'),meta
            assert not f.errors(),f.errors()
test('R7. an explicit native end finalizes immediately with cost scope on every harness',short_native_record_finalization)


def claude_preamble_build():
    with fixture() as f:
        f.path.write_text(json.dumps({'type':'summary','summary':'metadata only'})+'\n\n'+f.path.read_text())
        f.hook()
        assert sr.metadata(f.text())['session']=='session-one'
        assert sr.metadata(f.text())['harness']=='claude'
        assert not f.errors(),f.errors()
test('R1. Claude summary and blank preambles still probe and build',claude_preamble_build)

def human_driven_candidates():
    with native_fixture() as f:
        interactive=native_transcript(f,'human')
        companion=native_transcript(f,'companion')
        executable=native_transcript(f,'exec-review')
        empty=native_transcript(f,'empty-human')
        pi=native_transcript(f,'empty-pi','pi')
        for path,origin,source,strip in ((companion,'Claude Code','vscode',False),
                                        (executable,'codex-tui','exec',False),
                                        (empty,'codex-tui','cli',True)):
            rows=[json.loads(line) for line in path.read_text().splitlines()]
            rows[0]['payload'].update(originator=origin,source=source)
            if strip:rows=[row for row in rows if row.get('payload',{}).get('item',{}).get('type')!='UserMessage']
            path.write_text('\n'.join(map(json.dumps,rows))+'\n');os.utime(path,(time.time()-1200,)*2)
        rows=[json.loads(line) for line in pi.read_text().splitlines()]
        pi.write_text('\n'.join(json.dumps(row) for row in rows if row.get('message',{}).get('role')!='user')+'\n');os.utime(pi,(time.time()-1200,)*2)
        ctx=sr.Context(f.root);rows,skipped=sr.candidates(ctx,90)
        assert [row[1] for row in rows]==[interactive],rows
        assert skipped['agent-driven']==2 and skipped['no prompts']==2,skipped
        assert sr.refresh_index(ctx)['unrecorded_count']==3
        # Direct end admission cannot bypass these filters.
        for path in (companion,executable,empty,pi):f.hook(path=path,sid='hook-id',wait=False)
        time.sleep(.2)
        run_sweep(f)
        assert set(native_rows(f))=={'human'},native_rows(f)
        result=f.run('records.sh','backfill','--dry-run')
        assert 'skipped agent-driven: 2' in result.stdout and 'skipped no prompts: 2' in result.stdout,result.stdout
test('F2. full eligibility requires human-driven native sessions with real prompts',human_driven_candidates)

def exact_header_skips():
    with native_fixture() as f:
        valid=native_transcript(f,'valid')
        directory=valid.parent
        (directory/'rollout-malformed.jsonl').write_text('not JSON\n')
        (directory/'rollout-over-bound.jsonl').write_text('x'*(1024*1024+1)+'\n')
        (directory/'rollout-unknown.jsonl').write_text(json.dumps({'type':'unknown'})+'\n')
        (directory/'rollout-array.jsonl').write_text('[]\n')
        other=native_transcript(f,'other-project')
        rows=other.read_text().splitlines();header=json.loads(rows[0]);header['payload']['cwd']=str(f.temp/'elsewhere')
        other.write_text(json.dumps(header)+'\nnot JSON beyond foreign header\n')
        rows,skipped=sr.candidates(sr.Context(f.root),90)
        assert [row[1] for row in rows]==[valid]
        assert skipped['unreadable header']==2 and skipped['unsupported']==2 and skipped['other project']==1,skipped
        assert skipped['failed']==0 and not f.errors(),(skipped,f.errors())
        result=f.run('records.sh','backfill','--dry-run')
        for expected in ('skipped unreadable header: 2','skipped unsupported: 2','skipped other project: 1','failed: 0'):
            assert expected in result.stdout,result.stdout
        with patch.object(st,'load_session',side_effect=RuntimeError('synthetic reader failure')):
            rows,skipped=sr.candidates(sr.Context(f.root),90)
        assert not rows and skipped['failed']==1 and 'synthetic reader failure' in f.errors(),(skipped,f.errors())
        with patch.object(sr.Context,'held',side_effect=FileNotFoundError('synthetic disappearing transcript')):
            rows,skipped=sr.candidates(sr.Context(f.root),90)
        assert not rows and skipped['failed']==1 and 'synthetic disappearing transcript' in f.errors(),(skipped,f.errors())
test('F3. skip reasons distinguish unreadable headers, foreign cwd, unsupported formats and logged failures',exact_header_skips)

def count_before_publication_gate():
    for setting in ('session_records_noticed','session_records_enabled','organization'):
        with native_fixture() as f:
            native_transcript(f,'count-only')
            if setting=='organization':f.config['features']['session_records']['enabled']=False
            else:f.state[setting]=False
            f.save();run_sweep(f)
            cache=json.loads((f.base/'index.json').read_text())
            assert cache['unrecorded_count']==1 and not f.records(),(setting,cache)
            assert not f.calls() and f.git('rev-list','--count','HEAD')=='1'
            assert not (f.base/'sweep.stamp').exists()
    with native_fixture() as f:
        native_transcript(f,'recorded');run_sweep(f)
        native_transcript(f,'counted-on-debounce');run_sweep(f,force=False)
        assert json.loads((f.base/'index.json').read_text())['unrecorded_count']==1
        assert set(native_rows(f))=={'recorded'}
test('F1. detached sweep counts before publication gates and during publication debounce',count_before_publication_gate)

def pi_hold_recovers_without_alias():
    for harness in ('pi','prime'):
        for action in ('hold','redact'):
            with native_fixture() as f:
                path=native_transcript(f,'pi-record',harness)
                run_sweep(f)
                assert native_rows(f)['pi-record'][1]['detail']!='stub'
                digest=sr.path_identity(path)
                env=dict(f.env,EGREGORE_NATIVE_HARNESS=harness,EGREGORE_NATIVE_SESSION_ID=digest)
                result=f.run('records.sh',action,*(([digest]) if action=='redact' else []),env=env)
                assert result.returncode==0,(result.stdout,result.stderr)
                base=f.home/'.egregore/trails'/(f.prefix+'--'+harness)
                assert (base/'holds'/digest).is_file() and (base/'holds/pi-record').is_file()
                alias=json.loads((base/'aliases.jsonl').read_text().splitlines()[0])
                assert alias=={'hash':digest,'path':str(path),'session':'pi-record'},alias
                assert native_rows(f)['pi-record'][1]['detail']=='stub'
                assert 'existing record stubbed' in result.stdout,result.stdout
                assert not f.errors(),f.errors()
test('R2. Pi/Prime holds and redactions recover missing aliases and stub native records',pi_hold_recovers_without_alias)

def unchanged_native_skips_reader():
    for harness in ('codex','pi','prime'):
        with native_fixture() as f:
            path=native_transcript(f,'unchanged',harness)
            run_sweep(f)
            ctx=sr.Context(f.root)
            with patch.object(st,'load_session',side_effect=AssertionError('unchanged body opened')) as reader, \
                 patch.object(st,'last_event_time',side_effect=AssertionError('unchanged tail opened')) as tail:
                rows,skipped=sr.candidates(ctx,90)
                assert not rows and skipped['already recorded']==1 and skipped['failed']==0,(rows,skipped)
                assert sr.refresh_index(ctx)['unrecorded_count']==0
                reader.assert_not_called();tail.assert_not_called()
            native_append(path)
            with patch.object(st,'load_session',wraps=st.load_session) as reader:
                rows,skipped=sr.candidates(ctx,90)
                assert len(rows)==1 and rows[0][3]==2,(rows,skipped)
                assert reader.call_count==1
            assert not f.errors(),f.errors()
test('P1. unchanged native records skip all full readers and changed records load once',unchanged_native_skips_reader)

def header_only_count_and_consent():
    with native_fixture() as f:
        for n in range(50):native_transcript(f,'count-'+str(n))
        native_transcript(f,'child',parent={'parent_thread_id':'count-0'})
        rejected=native_transcript(f,'companion')
        entries=rejected.read_text().splitlines();head=json.loads(entries[0]);head['payload']['originator']='Claude Code'
        rejected.write_text(json.dumps(head)+'\n'+ '\n'.join(entries[1:])+'\n')
        f.state.pop('session_records_noticed',None);f.save()
        ctx=sr.Context(f.root)
        with patch.object(st,'last_event_time',side_effect=AssertionError('tail opened before consent')) as tail, \
             patch.object(st,'load_session',side_effect=AssertionError('body opened while counting')) as reader:
            rows,skipped=sr.candidates(ctx,90,include_live=True)
            assert len(rows)==50 and skipped['agent-driven']==1 and skipped['failed']==0,(len(rows),skipped)
            assert not skipped['no prompts'] and not skipped['shorter than 2 minutes with no commits']
            args=sr.record_parser().parse_args(['--root',str(f.root),'--mode','sweep','--worker','--force'])
            lock=ctx.lock('sweep','sweep');assert lock.acquire()
            assert sr.sweep(ctx,args)==0
            assert json.loads((f.base/'index.json').read_text())['unrecorded_count']==50
            reader.assert_not_called();tail.assert_not_called()
        assert not f.records() and not f.errors(),f.errors()
test('P1/P2. count and pre-consent sweep inspect only headers and mtimes for 50 roots',header_only_count_and_consent)

def claude_folder_rejects_native_content():
    with native_fixture() as f:
        path=native_transcript(f,'native-id')
        misplaced=f.folder/'misplaced.jsonl';shutil.move(path,misplaced)
        ctx=sr.Context(f.root)
        assert sr.inspect_transcript(ctx,misplaced)==(None,'unsupported')
        for count in (False,True):
            rows,skipped=sr.candidates(ctx,90,include_live=count)
            assert not rows and skipped['unsupported']==1,(rows,skipped)
        f.hook(path=misplaced,sid='misplaced',wait=False)
        run_sweep(f)
        assert not f.records() and not f.calls(True)
        assert json.loads((f.base/'index.json').read_text())['unrecorded_count']==0
test('P3. native content in a Claude project folder is unsupported everywhere',claude_folder_rejects_native_content)

def unresolved_pi_hold_notice():
    message="Hold recorded for this session's identity; its existing record could not be located. The hook identity will apply at the next publication."
    for harness in ('pi','prime'):
        with native_fixture() as f:
            path=native_transcript(f,'unresolved',harness)
            run_sweep(f)
            link=f.home/('.'+harness)/'agent/sessions/linked';link.symlink_to(path.parent,target_is_directory=True)
            spelling=link/path.name;digest=sr.path_identity(spelling)
            env=dict(f.env,EGREGORE_NATIVE_HARNESS=harness,EGREGORE_NATIVE_SESSION_ID=digest)
            result=f.run('records.sh','hold',env=env)
            assert result.returncode==0 and result.stdout.strip()==message,(result.stdout,result.stderr)
            assert sr.Context(f.root).held(digest)
            assert native_rows(f)['unresolved'][1]['detail']!='stub'
            f.hook(path=spelling,sid='egregore-id',wait=False)
            lock=f.home/'.egregore/trails'/(f.prefix+'--'+harness)/'locks/unresolved'
            until=time.monotonic()+20
            while lock.exists():
                assert time.monotonic()<until,'held end did not finish'
                time.sleep(.04)
            assert native_rows(f)['unresolved'][1]['detail']=='stub'
            # A physical-path match resolves without the warning, even without an alias.
            env['EGREGORE_NATIVE_SESSION_ID']=sr.path_identity(path)
            result=f.run('records.sh','hold',env=env)
            assert result.returncode==0 and message not in result.stdout and 'existing record stubbed' in result.stdout
            result=f.run('records.sh','hold',env=env)
            assert result.returncode==0 and message not in result.stdout
test('P4. unresolved Pi/Prime holds explain deferred hook identity protection',unresolved_pi_hold_notice)

def codex_root_prompts_required():
    with native_fixture() as f:
        parent=native_transcript(f,'prompt-free-root')
        rows=[json.loads(line) for line in parent.read_text().splitlines()]
        parent.write_text('\n'.join(json.dumps(row) for row in rows if row.get('payload',{}).get('item',{}).get('type')!='UserMessage')+'\n')
        os.utime(parent,(time.time()-1200,)*2)
        native_transcript(f,'prompted-child',parent={'parent_thread_id':'prompt-free-root'})
        rows,skipped=sr.candidates(sr.Context(f.root),90)
        assert not rows and skipped['no prompts']==1,(rows,skipped)
        run_sweep(f)
        assert not f.records() and not f.calls(True)
        assert sr.refresh_index(sr.Context(f.root))['unrecorded_count']==1
test('P5. child prompts cannot make a prompt-free Codex root eligible',codex_root_prompts_required)

def gate_line(**event):
    """One merge-gate decision in the shared schema of memory/sessions/gate.jsonl."""
    line={'at':datetime.now(timezone.utc).isoformat(timespec='seconds'),'kind':'merge','pr':1981,
          'head':'49edeb5341a2c022475fc944925f4c23c67904f1','base':'develop','repo':'Curve-Labs/egregore',
          'checks':{'green':21,'neutral':1,'red':0},'attempts':2,'flaked':[],'receipt':False,'by':'cem'}
    line.update(event)
    return json.dumps(line)

def gate_ledger(f,*lines):
    sessions=f.memory/'sessions';sessions.mkdir(exist_ok=True)
    (sessions/'gate.jsonl').write_text('\n'.join(lines)+'\n')

def open_section(text):
    return text.split('\n## Open\n',1)[1].split('\n## ',1)[0].strip().splitlines()

def gate_flakes_raised():
    with fixture() as f:
        long_job='Mind long '+'j'*110
        gate_ledger(f,
            gate_line(session='session-one',flaked=['Mind fast contracts','Full CI result — 49edeb5341a2','Suite baseline — shard 2']),
            '',
            '{"kind":"merge","session":"session-one","flaked":["MALFORMED_JOB"',
            '['*5000,
            json.dumps(['not','an','object']),
            gate_line(session='another-session',flaked=['FOREIGN_SESSION_JOB']),
            gate_line(kind='refuse',session='session-one',flaked=['REFUSED_JOB']),
            gate_line(kind='hold',session='session-one',flaked=['UNKNOWN_KIND_JOB']),
            gate_line(session='session-one',flaked='NOT_A_LIST_JOB'),
            gate_line(session='session-one',flaked=[None,7,'x'*121,'BELL\x07JOB','Mind fast contracts']),
            gate_line(session='session-one',recovered=['RECOVERED_ONLY_JOB']),
            gate_line(session='session-one',note={'unknown':'field'},flaked=[long_job]))
        # The model writes no Open section here; the record makes one for the raised items.
        Path(f.env['FAKE_OUTPUT']).write_text('## Asked\n- Improve checkpoint reliability\n## Decided\n'
                                              '- Keep the durable lock — cem, 10:01\n## Risks\n- Coordination needs care\n')
        f.hook();text=f.text()
        lines=open_section(text)
        assert lines==['- CI flaked: Mind fast contracts','- CI flaked: Suite baseline – shard 2','- CI flaked: '+long_job],(lines,text)
        assert all(len(line)<=160 for line in lines)
        for absent in ('Full CI result','MALFORMED_JOB','FOREIGN_SESSION_JOB','REFUSED_JOB','UNKNOWN_KIND_JOB',
                       'NOT_A_LIST_JOB','BELL','x'*121,'#1981','RECOVERED_ONLY_JOB'):
            assert absent not in text,absent
test('M1. a merge by this session raises one ownerless CI flaked line per real job; other ledger lines and recovered jobs are skipped',gate_flakes_raised)

def gate_flakes_absent():
    with fixture() as f:
        f.hook();text=f.text()
        assert 'CI flaked' not in text and open_section(text)==['- Check recovery — cem'],text
    with fixture() as f:
        gate_ledger(f,gate_line(session='another-session',flaked=['Mind fast contracts']),gate_line(session='session-one'))
        f.hook();text=f.text()
        assert 'CI flaked' not in text and open_section(text)==['- Check recovery — cem'],text
    with fixture() as f:
        assert sr.gate_flakes(f.temp/'no-memory','session-one')==[]
        assert sr.gate_flakes(f.memory,'session-one')==[]
        sessions=f.memory/'sessions';sessions.mkdir()
        assert sr.gate_flakes(f.memory,'session-one')==[]
        ledger=sessions/'gate.jsonl';ledger.write_text('')
        assert sr.gate_flakes(f.memory,'session-one')==[]
        ledger.unlink();outside=f.temp/'outside-gate.jsonl'
        outside.write_text(gate_line(session='session-one',flaked=['Mind fast contracts'])+'\n');ledger.symlink_to(outside)
        assert sr.gate_flakes(f.memory,'session-one')==[]
        ledger.unlink();ledger.write_text(gate_line(session='session-one',flaked=['Mind fast contracts']))
        assert sr.gate_flakes(f.memory,'session-one')==['Mind fast contracts']
        assert sr.gate_flakes(f.memory,'')==[] and sr.gate_flakes(f.memory,None)==[]
test('M2. no flaked merge by this session, an empty or linked ledger, or no memory raise nothing',gate_flakes_absent)

def gate_flake_shared_id():
    with fixture() as f:
        two=f.transcript('session-two')
        gate_ledger(f,gate_line(session='session-one',flaked=['Mind fast contracts','Suite baseline — shard 2']),
                    gate_line(session='session-two',pr=1982,flaked=['Mind fast contracts']))
        f.hook();f.hook(path=two)
        texts=[p.read_text() for p in f.records()]
        assert len(texts)==2 and all('\n- CI flaked: Mind fast contracts\n' in t for t in texts),texts
        # An earlier record carrying only its date raised the same flake yesterday.
        yesterday=datetime.now().date()-timedelta(days=1)
        earlier=f.memory/'sessions'/yesterday.strftime('%Y-%m')/(yesterday.strftime('%d')+'-cem-earlier-merge.md')
        earlier.parent.mkdir(parents=True,exist_ok=True)
        earlier.write_text('---\nkind: session-record\nfrom: "cem"\ndate: "'+yesterday.isoformat()+'"\nsession: "earlier"\n'
                           'topic: "earlier merge"\n---\n\n# Session: earlier merge\n\n## Open\n- CI flaked: Mind fast contracts\n')
        flake=sr.item_id(sr.digest_key('CI flaked: Mind fast contracts'))
        shard=sr.item_id(sr.digest_key('CI flaked: Suite baseline – shard 2'))
        listed=f.run('records.sh','open').stdout
        rows={line[:6]:line for line in listed.splitlines() if 'CI flaked' in line}
        assert set(rows)=={flake,shard},listed
        # One item for three records, aged from the earliest; ownerless, so a
        # job's own dash never becomes its owner.
        assert rows[flake].startswith(flake+'   1d  cem (default)  CI flaked: Mind fast contracts · sessions/'),listed
        assert 'd  cem (default)  CI flaked: Suite baseline – shard 2 · sessions/' in rows[shard],listed
        for zone in ('Pacific/Kiritimati','Pacific/Pago_Pago'):
            listed=f.run('records.sh','open',env=dict(f.env,TZ=zone)).stdout
            assert sum(line.startswith(flake) for line in listed.splitlines())==1,(zone,listed)
test('M3. records raising the same flake share one id, aged from the earliest raise, in any time zone',gate_flake_shared_id)

def gate_flakes_held():
    with fixture() as f:
        gate_ledger(f,gate_line(session='session-one',flaked=['Mind fast contracts']))
        hold=f.base/'holds/session-one';hold.parent.mkdir(parents=True);hold.write_text('held')
        f.hook();text=f.text()
        assert 'detail: stub' in text and 'CI flaked' not in text and '## Open' not in text,text
    with fixture() as f:
        gate_ledger(f,gate_line(session='session-one',flaked=['Mind fast contracts']))
        f.hook();assert '\n- CI flaked: Mind fast contracts\n' in f.text()
        f.env['EGREGORE_NATIVE_SESSION_ID']='session-one'
        p=f.run('records.sh','hold');assert p.returncode==0 and 'stubbed' in p.stdout,(p.stdout,p.stderr)
        assert 'detail: stub' in f.text() and 'CI flaked' not in f.text()
        p=f.run('records.sh','redact','session-one');assert p.returncode==0,(p.stdout,p.stderr)
        assert 'CI flaked' not in f.text() and 'CI flaked' not in f.run('records.sh','open').stdout
test('M4. a held stub and a redacted record raise no item',gate_flakes_held)

def hook_prompts_recorded():
    with fixture() as f:
        outside=f.home/'.claude/projects/elsewhere/memory/self-audit-map.md'
        context=('admin-content-detector: '+str(outside)+' matches sensitive keywords [fundraising / legal / personnel]'
                 ' but is not marked admin-only.\n\nCall AskUserQuestion now to confirm with the user:\n'
                 '  question: "PRIVATE_HOOK_CONTEXT mentions sensitive content."')
        entry={'type':'attachment','sessionId':'session-one','timestamp':datetime.now(timezone.utc).isoformat(),
               'attachment':{'type':'hook_success','hookName':'PostToolUse:Edit','hookEvent':'PostToolUse',
                             'command':'"$CLAUDE_PROJECT_DIR"/.claude/hooks/admin-content-detector.sh',
                             'stdout':json.dumps({'hookSpecificOutput':{'hookEventName':'PostToolUse','additionalContext':context}}),
                             'stderr':'','exitCode':0,'durationMs':40}}
        with f.path.open('a') as out: out.write((json.dumps(entry)+'\n')*3)
        f.hook();text=f.text()
        item='hook asked for a decision and got none: admin-content-detector on self-audit-map.md'
        assert '- compactions: 0\n- hook prompts without a decision: 3 (admin-content-detector 3)\n' in text,text
        assert open_section(text)==['- Check recovery — cem','- '+item],text
        for private in ('PRIVATE_HOOK_CONTEXT','sensitive keywords',str(outside.parent)):
            assert private not in text,private
        listed=f.run('records.sh','open').stdout
        assert any(line.startswith(sr.item_id(sr.digest_key(item))) and 'cem (default)  '+item+' · sessions/' in line
                   for line in listed.splitlines()),listed
test('M5. three undecided hook prompts are counted in Friction and raised as one ownerless open item',hook_prompts_recorded)

def append_entries(f,*entries):
    with f.path.open('a') as out: out.write(''.join(json.dumps(entry)+'\n' for entry in entries))

def free_text_answer(question,answer):
    """A question the person answered in free text, as Claude Code keeps it."""
    stamp=datetime.now(timezone.utc).isoformat()
    ask={'type':'assistant','sessionId':'session-one','timestamp':stamp,'requestId':'ask','message':{'model':'claude-haiku-4-5',
         'usage':{},'content':[{'type':'tool_use','id':'ask','name':'AskUserQuestion','input':{'questions':[
             {'question':question,'header':'Check','options':[{'label':'Yes'},{'label':'No'}]}]}}]}}
    reply={'type':'user','sessionId':'session-one','timestamp':stamp,'message':{'content':[{'type':'tool_result','tool_use_id':'ask',
           'content':'Your questions have been answered: '+json.dumps(question)+'='+json.dumps(answer)}]}}
    return [ask,reply]

def hook_prompts(name,path,count=3):
    """Three hook outputs asking for a decision, after any question the fixture answered."""
    context=(name+': '+path+' matches sensitive keywords [fundraising / legal / personnel] but is not marked'
             ' admin-only.\n\nCall AskUserQuestion now to confirm with the user.')
    entry={'type':'attachment','sessionId':'session-one','timestamp':datetime.now(timezone.utc).isoformat(),
           'attachment':{'type':'hook_success','hookName':'PostToolUse:Edit','hookEvent':'PostToolUse',
                         'command':'"$CLAUDE_PROJECT_DIR"/.claude/hooks/admin-content-detector.sh',
                         'stdout':json.dumps({'hookSpecificOutput':{'hookEventName':'PostToolUse','additionalContext':context}}),
                         'stderr':'','exitCode':0,'durationMs':40}}
    return [entry]*count

def hook_line(text):
    return next(line for line in text.splitlines() if line.startswith('- hook prompts without a decision: '))

def withheld_hook_values():
    with fixture() as f:
        append_entries(f,*free_text_answer('Which codename?','BLUE-LANTERN'),
                       *hook_prompts('blue-lantern-check','memory/blue-lantern-plan.md'))
        f.hook();text=f.text()
        assert hook_line(text)=='- hook prompts without a decision: 3 (hook 3)',text
        assert open_section(text)==['- Check recovery — cem','- hook asked for a decision and got none: hook'],text
        assert 'lantern' not in text.casefold(),text
test('M6. a hook name or file carrying a withheld free-text answer becomes the generic hook with no file',withheld_hook_values)

def uncertain_paths():
    with fixture() as f:
        append_entries(f,*hook_prompts('admin-content-detector','/private/Acme Corp/notes.md'))
        f.hook();text=f.text()
        assert open_section(text)[-1]=='- hook asked for a decision and got none: admin-content-detector',text
        assert 'acme' not in text.casefold() and 'corp' not in text.casefold(),text
    with fixture() as f:
        append_entries(f,*hook_prompts('admin-content-detector','"/private/Acme Corp/notes.md"'))
        f.hook();text=f.text()
        assert open_section(text)[-1]=='- hook asked for a decision and got none: admin-content-detector on notes.md',text
        assert 'acme' not in text.casefold(),text
test('M7. an unquoted path whose end is uncertain gives no file; a quoted path is read whole',uncertain_paths)

def currency_values():
    with fixture() as f:
        append_entries(f,*hook_prompts('admin-content-detector','memory/120k-'+'a'*80+'-salary.md'),
                       *hook_prompts('salary-120k','memory/notes.md'))
        f.hook();text=f.text()
        assert hook_line(text)=='- hook prompts without a decision: 6 (admin-content-detector 3, hook 3)',text
        assert open_section(text)==['- Check recovery — cem','- hook asked for a decision and got none: admin-content-detector',
                                    '- hook asked for a decision and got none: hook on notes.md'],text
        assert '120k' not in text and 'salary' not in text,text
test('M8. the currency guard reads a file name whole before any cut and checks the hook names in Friction',currency_values)

def placeholder_lead():
    with fixture() as f:
        gate_ledger(f,gate_line(session='session-one',flaked=['Mind fast contracts']))
        Path(f.env['FAKE_OUTPUT']).write_text('## Asked\n- Improve checkpoint reliability\n## Decided\n'
            '- Keep the durable lock — cem, 10:01\n## Open\n- None recorded for the API change; ask ops — cem\n'
            '- none noted.\n## Risks\n- Coordination needs care\n')
        f.hook();text=f.text()
        assert open_section(text)==['- None recorded for the API change; ask ops — cem','- CI flaked: Mind fast contracts'],text
test('M9. a model open item that only begins with a placeholder phrase survives the raised items',placeholder_lead)

def dashed_jobs():
    with fixture() as f:
        gate_ledger(f,gate_line(session='session-one',flaked=['Suite — — shard 2','— shard 3']))
        f.hook();text=f.text()
        assert open_section(text)[1:]==['- CI flaked: Suite – – shard 2','- CI flaked: – shard 3'],text
        listed=f.run('records.sh','open').stdout
        for item in ('CI flaked: Suite – – shard 2','CI flaked: – shard 3'):
            assert any(line.startswith(sr.item_id(sr.digest_key(item))) and 'cem (default)  '+item+' · sessions/' in line
                       for line in listed.splitlines()),(item,listed)
test('M10. no em dash in a job name, doubled or leading, ever reads as the item owner',dashed_jobs)

def unwritable_and_many_jobs():
    with fixture() as f:
        gate_ledger(f,gate_line(session='session-one',flaked=['Mind \ud800 job','Mind fast contracts']))
        assert sr.gate_flakes(f.memory,'session-one')==['Mind fast contracts']
        f.hook();text=f.text()
        assert open_section(text)==['- Check recovery — cem','- CI flaked: Mind fast contracts'],text
    with fixture() as f:
        # Sixty thousand names over fifteen merges, each name twice: deduplication stays linear.
        names=['job-%06d'%i for i in range(60000)]
        lines=[gate_line(session='session-one',flaked=names[i:i+4000]) for i in range(0,60000,4000)]
        gate_ledger(f,*lines,*lines)
        start=time.monotonic();jobs=sr.gate_flakes(f.memory,'session-one');elapsed=time.monotonic()-start
        assert jobs==names and elapsed<5,(len(jobs),elapsed)
test('M11. a job name that cannot be written is skipped and the record is still written; deduplication is linear',unwritable_and_many_jobs)

def placeholder_lead_carried():
    with fixture() as f:
        today=datetime.now().date()
        item='None recorded for the failed restore; retry it from the backup'
        risk='None noted, but the backup is a day old'
        digest_record(f,'restore',today,'cem','restore check',
                      '## Decided\n- None recorded.\n- not derived (model unavailable)\n'
                      '## Open\n- '+item+'\n- none recorded\n- (withheld: paraphrase check failed)\n- (withheld)\n'
                      '* None noted!\n## Risks\n'+risk+'\nnone noted\n(withheld — currency guard)\n')
        lines=list(sr.digest_lines(f.records()[0].read_text()))
        assert lines==[('Open',item),('Risks',risk)],lines
        ident=sr.item_id(sr.digest_key(item))
        carried=[row for row in sr.collect_digest(f.memory,days=0)['carried']]
        assert [(row['id'],row['line'],row['owner']) for row in carried]==[(ident,item,'cem')],carried
        listed=f.run('records.sh','open').stdout
        assert any(line.startswith(ident) and 'cem (default)  '+item+' · sessions/' in line for line in listed.splitlines()),listed
        digest=f.run('records.sh','digest').stdout
        assert item in digest and risk in digest,digest
        for hidden in ('none recorded\n','not derived','(withheld','None noted!','None recorded.'):
            assert hidden not in digest,(hidden,digest)
test('M12. a real item that begins with a placeholder phrase is carried; whole-line placeholders are not',placeholder_lead_carried)

def quoted_path_boundary():
    with fixture() as f:
        append_entries(f,*hook_prompts('admin-content-detector','"/private/Acme"/notes.md'))
        f.hook();text=f.text()
        assert open_section(text)[-1]=='- hook asked for a decision and got none: admin-content-detector',text
        assert 'acme' not in text.casefold() and 'notes.md' not in text,text
test('M13. a quoted path whose closing quote does not end it gives no file',quoted_path_boundary)

def job_checked_before_rewrite():
    with fixture() as f:
        append_entries(f,*free_text_answer('Which codename?','Phoenix—'))
        gate_ledger(f,gate_line(session='session-one',flaked=['Test Phoenix— build','Mind fast contracts']))
        f.hook();text=f.text()
        assert open_section(text)==['- Check recovery — cem','- CI flaked: Mind fast contracts'],text
        assert 'phoenix' not in text.casefold(),text
test('M14. a job name is checked as found, before its em dashes are rewritten',job_checked_before_rewrite)

def threshold_by_hook():
    with fixture() as f:
        append_entries(f,*hook_prompts('salary-120k','memory/notes.md',1),*hook_prompts('equity-2M','memory/notes.md',1),
                       *hook_prompts('revenue-5k','memory/notes.md',1))
        f.hook();text=f.text()
        assert hook_line(text)=='- hook prompts without a decision: 3 (hook 3)',text
        assert open_section(text)==['- Check recovery — cem'],text
        for figure in ('120k','2M','5k'):
            assert figure not in text,(figure,text)
test('M15. three hooks each seen once raise no item, however their names are written',threshold_by_hook)

def teardown_race():
    tree=Path(tempfile.mkdtemp(prefix='teardown-race-',dir=ROOT/'tmp'))
    (tree/'locks').mkdir();(tree/'locks/maintenance.lock').write_text('worker\n');(tree/'kept.md').write_text('fixture\n')
    real=os.unlink
    def racing(path,*args,**kwargs):
        if os.fspath(path).endswith('maintenance.lock'):
            # The worker removes its own lock first; the removal then finds it gone.
            real(path,*args,**kwargs)
            raise FileNotFoundError(2,'No such file or directory',os.fspath(path))
        return real(path,*args,**kwargs)
    os.unlink=racing
    try:
        remove_tree(tree)
    finally:
        os.unlink=real
    assert not tree.exists(),list(tree.rglob('*'))
    # A tree a worker already removed whole is gone too; plain rmtree raises here on every Python.
    remove_tree(tree)
    # A worker past its lock writes errors.log into a trail folder the removal has just emptied.
    trail=tree/'trails/one';trail.mkdir(parents=True);(trail/'stamp').write_text('fixture\n')
    real_rmdir=os.rmdir
    def refilled(path,*args,**kwargs):
        if os.fspath(path).endswith('one') and not refilled.done:
            refilled.done=True;(trail/'errors.log').write_text('memory write failed\n')
        return real_rmdir(path,*args,**kwargs)
    refilled.done=False
    os.rmdir=refilled
    try:
        remove_tree(tree)
    finally:
        os.rmdir=real_rmdir
    assert refilled.done and not tree.exists(),list(tree.rglob('*'))
    tree.mkdir();(tree/'kept.md').write_text('fixture\n')
    def denied(path,*args,**kwargs):
        raise PermissionError(13,'Permission denied',os.fspath(path))
    os.unlink=denied
    try:
        remove_tree(tree)
        raise AssertionError('a real removal error was hidden')
    except PermissionError:
        pass
    finally:
        os.unlink=real
        shutil.rmtree(tree)
test('M16. fixture teardown ignores a file a worker removes during removal, removes again a folder a worker refills, and still reports real errors',teardown_race)

print(f'session-record: {PASSED} passed, {FAILED} failed',flush=True)
sys.exit(bool(FAILED))
PY

result=$?
node "$ROOT/tests/test-pi-record-aliases.mjs" || result=1
exit "$result"
