#!/usr/bin/env node
import fs from 'node:fs';

const WIDTH = 72;

function usage() {
  console.error(`usage:
  node bin/codex-skill-render.mjs classify-graph [--mode connected|local] [--attempt initial|retry] [file|-]
  node bin/codex-skill-render.mjs activity-card [file|-]
  node bin/codex-skill-render.mjs dashboard-card [file|-]
  node bin/codex-skill-render.mjs handoff-card [file|-]`);
  process.exit(2);
}

function readInput(file) {
  if (!file || file === '-') {
    return fs.readFileSync(0, 'utf8');
  }
  return fs.readFileSync(file, 'utf8');
}

function readJson(file) {
  const raw = readInput(file).trim() || '{}';
  try {
    return JSON.parse(raw);
  } catch (error) {
    console.error(`invalid JSON${file ? ` in ${file}` : ''}: ${error.message}`);
    process.exit(1);
  }
}

function parseFlags(args) {
  const flags = {};
  const rest = [];
  for (let i = 0; i < args.length; i += 1) {
    const arg = args[i];
    if (arg === '--mode' || arg === '--attempt') {
      flags[arg.slice(2)] = args[i + 1];
      i += 1;
    } else {
      rest.push(arg);
    }
  }
  return { flags, rest };
}

function asArray(value) {
  return Array.isArray(value) ? value : [];
}

function firstArray(data, paths) {
  for (const p of paths) {
    const value = p.split('.').reduce((acc, key) => (acc && acc[key] !== undefined ? acc[key] : undefined), data);
    if (Array.isArray(value)) return value;
  }
  return [];
}

function valueOf(item, keys, fallback = '') {
  for (const key of keys) {
    if (item && item[key] !== undefined && item[key] !== null && String(item[key]).trim() !== '') {
      return String(item[key]);
    }
  }
  return fallback;
}

function truncate(value, max) {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  if (text.length <= max) return text;
  return `${text.slice(0, Math.max(0, max - 3))}...`;
}

function padLine(left, right = '') {
  const inner = WIDTH - 4;
  const r = right ? truncate(right, Math.min(18, inner - 1)) : '';
  const l = truncate(left, inner - (r ? r.length + 1 : 0));
  const space = Math.max(0, inner - l.length - r.length);
  return `│ ${l}${' '.repeat(space)}${r} │`;
}

function topRule() {
  return `┌${'─'.repeat(WIDTH - 2)}┐`;
}

function rule() {
  return `├${'─'.repeat(WIDTH - 2)}┤`;
}

function bottomRule() {
  return `└${'─'.repeat(WIDTH - 2)}┘`;
}

function graphFields(data) {
  return {
    status: data.graph_status || data.graphStatus || data.graph?.status || '',
    reason: data.graph_reason || data.graphReason || data.graph?.reason || '',
  };
}

function classifyGraph(data, options = {}) {
  const mode = options.mode || data.mode || 'connected';
  const attempt = options.attempt || 'initial';
  const { status, reason } = graphFields(data);

  if (mode === 'local') {
    return {
      status: 'local',
      retry: false,
      reason: reason || 'local_mode',
      message: 'Local mode uses memory files as the source of truth.',
    };
  }

  if (status === 'connected') {
    return {
      status: 'connected',
      retry: false,
      reason: '',
      message: 'Graph connected.',
    };
  }

  if (reason === 'unreachable' && attempt !== 'retry') {
    return {
      status: 'retry',
      retry: true,
      reason,
      message: 'Connected-mode graph was unreachable; retry with network escalation.',
    };
  }

  const finalReason = reason || status || 'offline';
  return {
    status: 'offline',
    retry: false,
    reason: finalReason,
    message: `Graph offline (${finalReason}). Render filesystem fallback.`,
  };
}

function renderActivity(data) {
  const graph = classifyGraph(data, { mode: data.mode || 'connected', attempt: 'retry' });
  const org = data.org || data.organization || 'Egregore';
  const date = data.date || '';
  const me = typeof data.me === 'string'
    ? data.me
    : data.me?.github || data.me?.name || data.github_username || '';
  const handoffs = firstArray(data, ['handoffs_to_me', 'handoffs', 'pending_handoffs', 'me.handoffs', 'addressed_handoffs']);
  const questions = firstArray(data, ['questions', 'pending_questions', 'me.questions']);
  const prs = asArray(data.prs);
  const mine = firstArray(data, ['local_sessions.my_sessions', 'my_sessions', 'sessions']);
  const team = firstArray(data, ['local_sessions.team_sessions', 'team_sessions', 'team.sessions']);

  const brand = `${truncate(org, 20).toUpperCase()} EGREGORE ✦ ACTIVITY DASHBOARD`;
  const lines = [topRule(), padLine(brand), padLine([me, date].filter(Boolean).join(' · ')), rule()];
  if (graph.status !== 'connected') {
    lines.push(padLine(`graph: ${graph.status}`, graph.reason));
    lines.push(rule());
  }

  lines.push(padLine('FOR YOU'));
  if (questions.length === 0 && handoffs.length === 0) {
    lines.push(padLine('nothing pending'));
  } else {
    if (questions.length > 0) {
      lines.push(padLine('QUESTIONS'));
      questions.slice(0, 4).forEach((q) => {
        lines.push(padLine(`● ${valueOf(q, ['from', 'author', 'asker'], 'someone')}: ${valueOf(q, ['topic', 'title', 'question'], 'question')}`));
      });
    }
    if (handoffs.length > 0) {
      lines.push(padLine('HANDOFFS'));
      const glyph = { pending: '●', read: '◐', claimed: '◆', done: '✓', completed: '✓', expired: '×' };
      handoffs.slice(0, 6).forEach((h, index) => {
        const status = valueOf(h, ['status'], 'pending');
        const age = valueOf(h, ['ageDays', 'age_days'], '');
        const intent = valueOf(h, ['intent'], '');
        const meta = [
          age === '' ? '' : `${age}d`,
          intent && intent !== 'unclassified' ? intent : '',
          status,
        ].filter(Boolean).join(' · ');
        lines.push(padLine(
          `[${index + 1}] ${glyph[status] || '○'} ⇌ ${valueOf(h, ['author', 'from'], 'someone')}: ${valueOf(h, ['topic', 'title'], 'handoff')}`,
          meta,
        ));
      });
    }
  }

  lines.push(rule());
  lines.push(padLine('RECENT WORK'));
  if (mine.length === 0) {
    lines.push(padLine('no recent local sessions found'));
  } else {
    mine.slice(0, 5).forEach((s) => {
      lines.push(padLine(`${valueOf(s, ['date', 'when'], '')} ${valueOf(s, ['topic', 'title', 'branch'], 'session')}`, valueOf(s, ['type', 'status', 'duration'], '')));
    });
  }

  if (team.length > 0 || prs.length > 0) {
    lines.push(rule());
    lines.push(padLine('AROUND'));
    team.slice(0, 3).forEach((s) => {
      lines.push(padLine(`${valueOf(s, ['author', 'name'], 'teammate')}: ${valueOf(s, ['topic', 'title', 'branch'], 'session')}`));
    });
    prs.slice(0, 3).forEach((pr) => {
      lines.push(padLine(`#${valueOf(pr, ['number'], '')} ${valueOf(pr, ['title'], 'pull request')}`, valueOf(pr.author || {}, ['login', 'name'], '')));
    });
  }

  lines.push(rule());
  if (handoffs.length > 0) {
    lines.push(padLine('Handoff actions: done N · expire N · reopen N'));
    lines.push(padLine('Type a number to act, or keep working.'));
  } else {
    lines.push(padLine('Focus choices: questions, recent work, dashboard, done'));
  }
  lines.push(bottomRule());
  return lines.join('\n');
}

function humanTopic(session) {
  const topic = valueOf(session, ['topic', 'title'], '');
  if (topic) return topic;
  const branch = valueOf(session, ['branch'], '');
  if (branch && !['develop', 'main', 'master'].includes(branch)) {
    return branch.replace(/^dev\/[^/]+\//, '').replace(/[-_]+/g, ' ');
  }
  return valueOf(session, ['id', 'date'], 'session');
}

function renderDashboard(data) {
  const graph = classifyGraph(data, { mode: data.mode || 'connected', attempt: 'retry' });
  const org = data.org || 'Egregore';
  const date = data.date || '';
  const me = data.me?.github || data.me?.name || data.github_username || '';
  const current = data.current_session || {};
  const sessions = firstArray(data, ['sessions', 'local_sessions.sessions']);
  const todos = firstArray(data, ['todos', 'open_todos']);
  const quests = firstArray(data, ['quests', 'active_quests']);
  const handoffs = firstArray(data, ['handoffs', 'pending_handoffs']);
  const threads = firstArray(data, ['open_threads', 'threads']);
  const stats = data.stats || {};

  const lines = [topRule(), padLine('DASHBOARD', [org, me, date].filter(Boolean).join(' · ')), rule()];
  if (graph.status !== 'connected') {
    lines.push(padLine(`graph: ${graph.status}`, graph.reason));
    lines.push(rule());
  }

  lines.push(padLine(`* ${humanTopic(current) || '(starting...)'}`, 'active'));

  if (threads.length > 0) {
    lines.push(rule());
    lines.push(padLine('PICK UP WHERE YOU LEFT OFF'));
    threads.slice(0, 5).forEach((thread) => {
      lines.push(padLine(`- ${valueOf(thread, ['text', 'thread', 'title', 'topic'], 'open thread')}`));
    });
  }

  if (todos.length > 0) {
    lines.push(rule());
    lines.push(padLine(`OPEN TODOS (${todos.length})`));
    todos.slice(0, 3).forEach((todo, index) => {
      lines.push(padLine(`[${index + 1}] ${valueOf(todo, ['text', 'title'], 'todo')}`, valueOf(todo, ['status'], '')));
    });
  }

  if (handoffs.length > 0) {
    lines.push(rule());
    lines.push(padLine(`HANDOFFS (${handoffs.length} pending)`));
    handoffs.slice(0, 3).forEach((handoff) => {
      lines.push(padLine(`${valueOf(handoff, ['author', 'from'], 'someone')}: ${valueOf(handoff, ['topic', 'title'], 'handoff')}`, valueOf(handoff, ['when', 'date'], '')));
    });
  }

  lines.push(rule());
  lines.push(padLine(`SESSIONS (${data.range_label || 'recent'})`));
  if (sessions.length === 0) {
    lines.push(padLine('No activity recorded yet'));
  } else {
    sessions.slice(0, 5).forEach((session) => {
      lines.push(padLine(`${valueOf(session, ['date', 'when'], '')} ${humanTopic(session)}`, valueOf(session, ['status', 'type'], '')));
    });
  }

  if (quests.length > 0) {
    lines.push(rule());
    lines.push(padLine(`QUESTS (${quests.length} active)`));
    quests.slice(0, 3).forEach((quest) => {
      lines.push(padLine(valueOf(quest, ['id', 'quest', 'slug', 'title'], 'quest'), valueOf(quest, ['status', 'summary'], '')));
    });
  }

  lines.push(rule());
  const total = stats.totalSessions ?? data.local_sessions?.session_count ?? sessions.length;
  const wrapped = stats.wrappedSessions ?? sessions.filter((s) => valueOf(s, ['status', 'type'], '').includes('wrap')).length;
  lines.push(padLine(`${total} sessions · ${wrapped}/${total} wrapped · ${stats.openTodos ?? todos.length} open todos`));
  lines.push(padLine("What's next?"));
  lines.push(bottomRule());
  return lines.join('\n');
}

function renderHandoff(data) {
  const file = data.file ? `memory/${data.file}` : '';
  const statuses = [
    data.graphStatus ? `graph=${data.graphStatus}` : '',
    data.memoryStatus ? `memory=${data.memoryStatus}` : '',
    data.notifyStatus ? `notify=${data.notifyStatus}` : '',
    data.publishStatus ? `publish=${data.publishStatus}` : '',
  ].filter(Boolean).join(' · ');

  const lines = [topRule(), padLine('⇌ HANDOFF', data.author || ''), rule()];
  lines.push(padLine(`Topic: ${data.topic || '(untitled)'}`));
  if (data.recipient) lines.push(padLine(`To: ${data.recipient}`));
  if (file) lines.push(padLine(`Path: ${file}`));
  if (data.artifactUrl) lines.push(padLine(`Link: ${data.artifactUrl}`));
  if (statuses) lines.push(padLine(statuses));
  if (data.publishStatus === 'fidelity-failed') {
    lines.push(rule());
    lines.push(padLine('Artifact not published — restore missing content and preview again.'));
  }
  lines.push(bottomRule());
  return lines.join('\n');
}

const [command, ...rawArgs] = process.argv.slice(2);
if (!command) usage();

if (command === 'classify-graph') {
  const { flags, rest } = parseFlags(rawArgs);
  const data = readJson(rest[0]);
  console.log(JSON.stringify(classifyGraph(data, flags)));
} else if (command === 'activity-card') {
  const data = readJson(rawArgs[0]);
  console.log(renderActivity(data));
} else if (command === 'dashboard-card') {
  const data = readJson(rawArgs[0]);
  console.log(renderDashboard(data));
} else if (command === 'handoff-card') {
  const data = readJson(rawArgs[0]);
  console.log(renderHandoff(data));
} else {
  usage();
}
