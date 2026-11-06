#!/usr/bin/env python3
"""Read-only retrieval readings. Episode cohorts are local; records are organizational."""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from contextlib import ExitStack
import errno
from datetime import date, datetime, timedelta, timezone
import json
import math
import os
from pathlib import Path
import re
import stat
import sys

# A scorecard must not create bytecode in the evidence installation.
sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
from egregore_runtime.installation import installation_root
from session_record import metadata, record_day, read_json

MAX_BYTES = 2 * 1024 * 1024
KINDS = {'keyword', 'semantic', 'hybrid', 'filename', 'literal', 'dates'}
HARNESSES = {'claude', 'codex', 'pi', 'prime'}
# Investigation.run's error codes; no free-text labels enter the scorecard.
ERROR_CODES = {'not_authorized', 'episode_closed', 'binding_required', 'budget_exhausted',
               'request_conflict', 'request_interrupted', 'source_changed', 'not_found_or_denied',
               'runtime_error', 'backend_error', 'invalid_request'}
# Investigation's direct phases and adapters/qmd_scoped.mjs phases with the qmd_ prefix.
PHASES = {'authorization', 'revision_check', 'observe', 'retrieve', 'eligibility', 'source_read',
          'qmd_index_validation', 'qmd_keyword', 'qmd_vector', 'qmd_query_embedding', 'qmd_backend'}
# private_result.consume currently advances packet_ready to this final state.
DELIVERED = {'attachment_prepared'}


def number(value):
    try:
        return (float(value) if type(value) in (int, float) and math.isfinite(value) and value >= 0 else None)
    except OverflowError:
        return None


def label(value, allowed):
    return value if isinstance(value, str) and value in allowed else 'unknown'


def correlation(value):
    return value if isinstance(value, str) and value.strip() else None


def percentile(values, fraction):
    if not values:
        return None
    ordered = sorted(values)
    position = (len(ordered) - 1) * fraction
    low, high = math.floor(position), math.ceil(position)
    return round(ordered[low] + (ordered[high] - ordered[low]) * (position - low), 6)


def stamp(value):
    try:
        value = datetime.fromisoformat(value.replace('Z', '+00:00'))
        return value.astimezone(timezone.utc)
    except (ValueError, TypeError, AttributeError, OverflowError):
        return None


def window(days, after, before, today):
    def day(value):
        return date.fromisoformat(value) if isinstance(value, str) else value
    today = day(today) or datetime.now().date()
    start, end = day(after), day(before)
    end = end or (start + timedelta(days=days - 1) if start else today)
    start = start or end - timedelta(days=days - 1)
    if end < start:
        raise ValueError('--before must be on or after --after')
    length = (end - start).days + 1
    return length, {'now': (start, end), 'before': (start - timedelta(days=length), start - timedelta(days=1))}


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW


def open_directory(parent, relative):
    """Pin a directory component by component; never reopen an evidence ancestor by path."""
    path = Path(relative)
    if parent is None:
        if not path.is_absolute():
            raise OSError('evidence root must be absolute')
        descriptor = os.open(path.anchor, DIRECTORY_FLAGS)
        parts = path.parts[1:]
    else:
        if path.is_absolute() or '..' in path.parts:
            raise OSError('evidence directory must be relative')
        descriptor = os.dup(parent)
        parts = path.parts
    try:
        for part in parts:
            child = os.open(part, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


class DirectoryPins(ExitStack):
    """Own all directory descriptors until this scorecard has finished reading."""
    def open(self, parent, relative):
        descriptor = open_directory(parent, relative)
        self.callback(os.close, descriptor)
        return descriptor


def rejected(error, skipped):
    skipped['symlink' if getattr(error, 'errno', None) in (errno.ELOOP, errno.ENOTDIR)
            or isinstance(error, RuntimeError) else 'unreadable'] += 1


def optional_directory(pins, parent, relative, skipped):
    try:
        return pins.open(parent, relative)
    except FileNotFoundError:
        return None
    except OSError as error:
        rejected(error, skipped)
        return None


def evidence_names(descriptor, skipped):
    try:
        return sorted(os.listdir(descriptor))
    except OSError as error:
        rejected(error, skipped)
        return []


def read_evidence(directory, name):
    """Read a bounded regular file relative to its retained evidence directory."""
    if Path(name).name != name or name in ('.', '..'):
        raise OSError('evidence file must be a single name')
    file = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(file, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode):
            raise OSError('not a regular evidence file')
        if info.st_size > MAX_BYTES:
            raise OverflowError('oversized evidence')
        data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise OverflowError('oversized evidence')
        return data


def linked_worktree(pins, installation, installation_fd, worktrees, name):
    """Resolve an explicit worktree-root alias once, then validate through pinned handles."""
    link = Path(os.readlink(name, dir_fd=worktrees))
    target = (link if link.is_absolute() else installation / '.claude/worktrees' / link).resolve()
    # Open every component of the resolved root without following a replacement link.
    directory = pins.open(None, target)
    marker = read_evidence(directory, '.git').decode('utf-8')
    line = next((line for line in marker.splitlines() if line.startswith('gitdir:')), '')
    gitdir = Path(line.partition(':')[2].strip())
    if not line:
        raise OSError('unverified worktree root')
    if not gitdir.is_absolute():
        gitdir = Path(os.path.normpath(target / gitdir))
    relative = gitdir.relative_to(installation)
    if len(relative.parts) != 3 or relative.parts[:2] != ('.git', 'worktrees'):
        raise OSError('unverified worktree root')
    git_fd = pins.open(installation_fd, relative)
    back = read_evidence(git_fd, 'gitdir').decode('utf-8').strip()
    if not back or Path(os.path.normpath(gitdir / back)) != target / '.git':
        raise OSError('unverified worktree root')
    return directory


def episode_files(installation, pins, installation_fd):
    found, skipped = [], Counter(unreadable=0, oversized=0, symlink=0)
    if installation_fd is None:
        skipped['unreadable'] += 1
        return found, skipped
    roots = [('', installation_fd)]
    worktrees = optional_directory(pins, installation_fd, '.claude/worktrees', skipped)
    if worktrees is not None:
        for name in evidence_names(worktrees, skipped):
            linked = False
            try:
                info = os.stat(name, dir_fd=worktrees, follow_symlinks=False)
                linked = stat.S_ISLNK(info.st_mode)
                if stat.S_ISDIR(info.st_mode):
                    directory = pins.open(worktrees, name)
                    pinned = os.fstat(directory)
                    if (pinned.st_dev, pinned.st_ino) != (info.st_dev, info.st_ino):
                        raise OSError('worktree root changed during validation')
                elif linked:
                    directory = linked_worktree(pins, installation, installation_fd, worktrees, name)
                else:
                    continue
                roots.append(('.claude/worktrees/' + name, directory))
            except (OSError, ValueError, RuntimeError, OverflowError) as error:
                if linked:
                    skipped['symlink'] += 1
                else:
                    rejected(error, skipped)
    seen = set()
    for key, directory in roots:
        identity = os.fstat(directory)
        identity = (identity.st_dev, identity.st_ino)
        if identity in seen:
            continue
        seen.add(identity)
        folder = optional_directory(pins, directory, '.egregore/runtime/investigations', skipped)
        if folder is None:
            continue
        for name in evidence_names(folder, skipped):
            if not name.endswith('.json'):
                continue
            try:
                info = os.stat(name, dir_fd=folder, follow_symlinks=False)
                if stat.S_ISLNK(info.st_mode):
                    skipped['symlink'] += 1
                elif stat.S_ISREG(info.st_mode):
                    found.append((info.st_mtime_ns, key + '/' + name, folder, name))
                else:
                    skipped['unreadable'] += 1
            except OSError as error:
                rejected(error, skipped)
    return found, skipped


def episodes(installation, maximum, pins, installation_fd):
    files, skipped = episode_files(installation, pins, installation_fd)
    capped = len(files) > maximum
    # The relative key breaks equal-mtime ties without reopening a pathname.
    selected = sorted(files, key=lambda item: (-item[0], item[1]))[:maximum]
    loaded = []
    for _, _, directory, filename in selected:
        try:
            value = json.loads(read_evidence(directory, filename))
            started = stamp(value.get('as_of')) if isinstance(value, dict) else None
            if started is None or not isinstance(value.get('calls'), list):
                raise ValueError('invalid episode')
            if any(not isinstance(call, dict) for call in value['calls']):
                raise ValueError('invalid call')
            loaded.append((started, value))
        except OverflowError:
            skipped['oversized'] += 1
        except (OSError, ValueError, RecursionError):
            skipped['unreadable'] += 1
    loaded.sort(key=lambda item: item[0], reverse=True)
    return loaded, {'episodes_read': len(loaded), 'episodes_skipped': dict(skipped),
                    'unattributed': sum(skipped.values()), 'episode_files': len(files) + skipped['symlink'],
                    'max_episodes': maximum, 'cap_reached': capped, 'preselected_by_mtime': capped,
                    'observation_cutoff': loaded[0][0].isoformat() if loaded else None,
                    'oldest_as_of': loaded[-1][0].isoformat() if loaded else None}


def notices(pins, installation_fd):
    """Only local optional logs, kept pinned from enumeration through the final read."""
    shown, read, skipped = {}, 0, Counter()
    mind = (optional_directory(pins, installation_fd, '.egregore/runtime/mind', skipped)
            if installation_fd is not None else None)
    folders = [] if mind is None else [mind]
    if mind is not None:
        log = optional_directory(pins, mind, 'log', skipped)
        if log is not None:
            folders.append(log)
    for folder in folders:
        for name in evidence_names(folder, skipped):
            if not name.endswith('.jsonl'):
                continue
            try:
                raw = read_evidence(folder, name)
            except (OSError, OverflowError):
                skipped['unreadable'] += 1
                continue
            read += 1
            for line in raw.splitlines():
                try:
                    notice = json.loads(line)
                except (ValueError, RecursionError):
                    skipped['unreadable'] += 1
                    continue
                if not isinstance(notice, dict) or notice.get('k') != 'seen':
                    continue
                invocation = correlation(notice.get('invocation'))
                paths = notice.get('paths', notice.get('shown'))
                if invocation and isinstance(paths, list):
                    shown.setdefault(invocation, set()).update(p for p in paths if isinstance(p, str) and p.strip())
    return shown, {'logs_read': read, 'skipped': sum(skipped.values())}


KIND_ALIASES = {'lex': 'keyword', 'vec': 'semantic', 'lex+vec': 'hybrid'}


def lookup_kind(value):
    return label(KIND_ALIASES.get(value, value) if isinstance(value, str) else None, KINDS)


def lookup_in_record(text):
    """Only supported counters in the final writer section establish a measurement."""
    headings = list(re.finditer(r'^##[ \t]+Memory and artifacts[ \t\r]*$', text, re.M))
    if not headings:
        return None
    section = text[headings[-1].end():]
    end = re.search(r'^##[ \t]', section, re.M)
    total, seen, recalls, sentinels = 0, set(), False, set()
    for line in section[:end.start() if end else None].splitlines():
        line = line.strip()
        if not line:
            continue
        match = re.fullmatch(r'- ([a-z_]+)/([^: ]+): (\d{1,9}) calls, (\d{1,9}) failed', line)
        if match:
            operation, kind, count, failed = match.groups()
            if operation not in {'find', 'query', 'discover', 'open', 'open_many', 'handoffs', 'investigate'}:
                return None
            kind = '-' if kind == '-' else lookup_kind(kind)
            key = (operation, kind)
            if kind == 'unknown' or key in seen or int(failed) > int(count):
                return None
            seen.add(key)
            recalls = True
            if operation in {'find', 'query', 'discover'}:
                total += int(count)
            continue
        match = re.fullmatch(r'- (publish-artifact|notify\.sh): (\d{1,9}) calls', line)
        if match:
            if match[1] in sentinels:
                return None
            sentinels.add(match[1])
            continue
        if line.startswith('- memory/') and len(line) > len('- memory/'):
            continue
        return None
    if len(sentinels) == 1:
        return None
    return total if recalls or len(sentinels) == 2 else None


def organizations(pins, memory_fd, windows):
    """Retain memory, sessions and month handles throughout enumeration and record reads."""
    totals = {name: {'scope': 'organization', 'sessions': 0, 'sessions_by_harness': Counter(),
                     'sessions_without_lookup': 0, 'sessions_without_lookup_by_harness': Counter(),
                     'sessions_lookup_measured': 0} for name in windows}
    read, skipped = 0, Counter()
    if memory_fd is None:
        skipped['unreadable'] += 1
    sessions = (optional_directory(pins, memory_fd, 'sessions', skipped) if memory_fd is not None else None)
    available = sessions is not None
    months = set(evidence_names(sessions, skipped)) if available else set()
    # A UTC-named record near midnight can belong to an adjacent local month.
    start, end = windows['before'][0] - timedelta(days=1), windows['now'][1] + timedelta(days=1)
    month = start.replace(day=1)
    while available and month <= end:
        next_month = (month + timedelta(days=32)).replace(day=1)
        folder = month.strftime('%Y-%m')
        if folder in months:
            try:
                directory = pins.open(sessions, folder)
            except OSError as error:
                rejected(error, skipped)
                directory = None
            names = evidence_names(directory, skipped) if directory is not None else []
            for filename in names:
                if not filename.endswith('.md'):
                    continue
                try:
                    text = read_evidence(directory, filename).decode('utf-8', errors='replace')
                except (OSError, OverflowError):
                    skipped['unreadable'] += 1
                    continue
                read += 1
                meta = metadata(text)
                when = record_day(meta)[0] if meta.get('kind') == 'session-record' else None
                for name, (first, last) in windows.items():
                    if when is None or not first <= when <= last:
                        continue
                    total = totals[name]
                    harness = label(meta.get('harness'), HARNESSES)
                    total['sessions'] += 1
                    total['sessions_by_harness'][harness] += 1
                    looks = lookup_in_record(text)
                    if looks is not None:
                        total['sessions_lookup_measured'] += 1
                        total['sessions_without_lookup_by_harness'][harness] += int(looks == 0)
                        total['sessions_without_lookup'] += int(looks == 0)
        month = next_month
    for total in totals.values():
        for harness in total['sessions_by_harness']:
            total['sessions_without_lookup_by_harness'].setdefault(harness, None)
        if not total['sessions_lookup_measured'] and total['sessions']:
            total['sessions_without_lookup'] = None
        if not available or (skipped and not total['sessions']):
            for field in ('sessions', 'sessions_without_lookup'):
                total[field] = None
        total['sessions_by_harness'] = dict(sorted(total['sessions_by_harness'].items()))
        total['sessions_without_lookup_by_harness'] = dict(sorted(total['sessions_without_lookup_by_harness'].items()))
        total['coverage'] = 'uncertain' if skipped else 'unavailable' if not available else 'complete'
        # Keep the earlier session-named fields as compatibility aliases for one release.
        total.update(records_zero_calls=total['sessions_without_lookup'],
                     records_measured=total['sessions_lookup_measured'], records_total=total['sessions'])
    return totals, read, sum(skipped.values())


def installation_readings(cohort, shown, observed):
    calls = [(call, episode) for _, episode in cohort for call in episode['calls']]
    looks = [(call, ep) for call, ep in calls if call.get('operation') == 'discover']
    opens = [call for call, _ in calls if call.get('operation') in ('open', 'open_many')]
    oks = [(c, ep) for c, ep in looks if c.get('ok') is True]
    known_ok = [c for c, _ in looks if isinstance(c.get('ok'), bool)]
    failed = [c for c, _ in looks if c.get('ok') is False]
    ok_total = len(oks) if known_ok or (observed and not looks) else None
    delivery, empties = [], []
    for call, episode in oks:
        invocation = correlation(call.get('invocation_id'))
        receipts = episode.get('deliveries')
        receipts = receipts.values() if isinstance(receipts, dict) else []
        matched = [r for r in receipts if isinstance(r, dict) and invocation
                   and correlation(r.get('invocation_id')) == invocation and isinstance(r.get('status'), str)]
        status = call.get('delivery')
        if (isinstance(status, str) and status.strip()) or matched:
            delivery.append((isinstance(status, str) and status.startswith('stdout'))
                            or any(r['status'] in DELIVERED for r in matched))
        sources = number(call.get('new_sources'))
        if sources is not None:
            empties.append(sources == 0)
    refinements = [sum(c.get('operation') == 'discover' for c in ep['calls']) for _, ep in cohort]
    reading = [ep for _, ep in cohort if any(c.get('operation') == 'discover' for c in ep['calls'])
               and isinstance(ep.get('opened'), dict)]
    phases = defaultdict(list)
    for call, _ in calls:
        if call.get('operation') not in ('discover', 'open', 'open_many'):
            continue
        phase = call.get('phase_ms')
        for key, value in (phase.items() if isinstance(phase, dict) else []):
            if number(value) is not None:
                phases[label(key, PHASES)].append(number(value))
    grounding = [len(shown[ident]) for c, _ in looks
                 if (ident := correlation(c.get('invocation_id'))) and ident in shown]
    def count(value):
        return value if observed else None
    def measured(values):
        return sum(values) if values else None
    def share(values):
        return sum(values) / len(values) if values else None
    def latency(items):
        samples = [number(c.get('seconds')) for c in items if number(c.get('seconds')) is not None]
        return {'p50': percentile(samples, .5), 'p95': percentile(samples, .95),
                'measured': len(samples), 'total': count(len(items))}
    return {'scope': 'installation', 'lookups': count(len(looks)), 'opens': count(len(opens)),
            'ok': ok_total, 'failed': len(failed) if known_ok else (0 if observed and not looks else None),
            'failed_measured': len(known_ok), 'failed_total': count(len(looks)),
            'failed_by_cause': dict(sorted(Counter(label(c.get('error_code'), ERROR_CODES) for c in failed).items())) if observed else None,
            'delivered': measured(delivery), 'delivered_share': share(delivery),
            'delivered_measured': len(delivery), 'delivered_total': ok_total,
            'empty': measured(empties), 'empty_share': share(empties),
            'empty_measured': len(empties), 'empty_total': ok_total,
            'episodes': count(len(cohort)), 'refinements': {'median': percentile(refinements, .5), 'p90': percentile(refinements, .9)},
            'read_after_lookup': sum(bool(ep['opened']) for ep in reading) if reading else (0 if observed and not looks else None),
            'lookups_without_read': sum(not ep['opened'] for ep in reading) if reading else (0 if observed and not looks else None),
            'read_measured': len(reading), 'read_total': count(sum(n > 0 for n in refinements)),
            'kinds': dict(sorted(Counter(lookup_kind(c.get('kind')) for c, _ in looks).items())) if observed else None,
            'latency_s': {'discover': latency([c for c, _ in looks]), 'open': latency(opens)},
            'phase_ms_p50': {key: percentile(values, .5) for key, values in sorted(phases.items())} or None,
            'phase_ms_measured': {key: len(values) for key, values in sorted(phases.items())},
            'grounding': {'lookups_with_shown_path': share([n > 0 for n in grounding]),
                          'shown_paths_per_lookup': percentile(grounding, .5),
                          'measured': len(grounding), 'total': count(len(looks))} if grounding else None,
            'grounding_coverage': {'correlated': len(grounding), 'total': count(len(looks))} if grounding else 'unavailable'}


def scorecard(root, *, days=7, after=None, before=None, max_episodes=2000, memory=None, today=None):
    root = Path(root).resolve()
    installation = installation_root(root).resolve()
    memory = Path(memory or root / 'memory').resolve()
    days, windows = window(days, after, before, today)
    with DirectoryPins() as pins:
        try:
            installation_fd = pins.open(None, installation)
        except OSError:
            installation_fd = None
        try:
            memory_fd = pins.open(None, memory)
        except OSError:
            memory_fd = None
        loaded, coverage = episodes(installation, max_episodes, pins, installation_fd)
        shown, notice_coverage = notices(pins, installation_fd)
        org, read, skipped = organizations(pins, memory_fd, windows)
    coverage.update(records_read=read, records_skipped=skipped, notices=notice_coverage)
    result = {'days': days, 'cohort': 'episode_start', 'coverage': coverage,
              'field_descriptions': {
                  'read_after_lookup': 'Number of episodes with at least one lookup and a non-empty opened dict; '
                                       'counts episodes, not individual calls, and establishes no chronology.',
                  'lookups_without_read': 'Number of episodes with at least one lookup and an empty opened dict; '
                                          'counts episodes, not individual calls, and establishes no chronology. '
                                          'Missing or malformed opened is unmeasured.'}}
    for name, (start, end) in windows.items():
        cohort = [(at, ep) for at, ep in loaded if start <= at.astimezone().date() <= end]
        # Modification time cannot place an excluded episode into a start-time
        # cohort. Any preselection therefore leaves every period incomplete.
        incomplete = coverage['preselected_by_mtime']
        completeness = 'uncertain' if coverage['unattributed'] else 'incomplete' if incomplete else 'complete'
        observed = bool(cohort) or completeness == 'complete'
        result[name] = {'after': start.isoformat(), 'before': end.isoformat(), 'completeness': completeness,
                        'boundaries': {'start': start.isoformat(), 'end': end.isoformat()},
                        'incomplete': incomplete, 'skipped_episodes': coverage['unattributed'],
                        'installation': installation_readings(cohort, shown, observed), 'organization': org[name]}
    return result


def display(value):
    return 'n/a' if value is None else f'{value:g}' if isinstance(value, float) else str(value)


def mapping(values):
    return ', '.join(f'{key} {display(value)}' for key, value in (values or {}).items()) or ('n/a' if values is None else 'none')


def percentage(value):
    return 'n/a' if value is None else f'{value:.0%}'


def completeness_text(period):
    return period['completeness'] + (', incomplete' if period['incomplete'] and period['completeness'] == 'uncertain' else '')


def record_reach(organization):
    return (f'records reporting zero calls: {display(organization["records_zero_calls"])} '
            f'of {organization["records_measured"]} measured, '
            f'out of {display(organization["records_total"])} records')


def text_output(data):
    lines = []
    for name in ('now', 'before'):
        period = data[name]
        i, o = period['installation'], period['organization']
        shares = ' · '.join(f'{key} {display(i[key])} ({percentage(i[key + "_share"])}; measured '
                            f'{i[key + "_measured"]}/{display(i[key + "_total"])} ok)' for key in ('delivered', 'empty'))
        latency = '; '.join(f'{kind} {display(values["p50"])}/{display(values["p95"])} '
                            f'({values["measured"]}/{display(values["total"])} measured)'
                            for kind, values in i['latency_s'].items())
        ground = i['grounding']
        grounding = ('unavailable' if ground is None else
                     f'{percentage(ground["lookups_with_shown_path"])} shown, median {display(ground["shown_paths_per_lookup"])} '
                     f'paths ({ground["measured"]}/{display(ground["total"])} correlated)')
        lines.append(f'{name} boundaries {period["boundaries"]["start"]}..{period["boundaries"]["end"]} '
                     f'[{completeness_text(period)}] · scope: installation · '
                     f'lookups {display(i["lookups"])} · opens {display(i["opens"])} · failed {display(i["failed"])} '
                     f'({i["failed_measured"]}/{display(i["failed_total"])} measured) · {shares} · episodes {display(i["episodes"])} · '
                     f'refinements median/p90 {display(i["refinements"]["median"])}/{display(i["refinements"]["p90"])} · '
                     f'read_after_lookup {display(i["read_after_lookup"])} · lookups_without_read {display(i["lookups_without_read"])} '
                     f'({i["read_measured"]}/{display(i["read_total"])} measured) · latency_s p50/p95 {latency} · '
                     f'phase_ms_p50 {mapping(i["phase_ms_p50"])} · grounding {grounding} · scope: organization · '
                     f'records {display(o["records_total"])} ({mapping(o["sessions_by_harness"])}) · '
                     f'{record_reach(o)} ({mapping(o["sessions_without_lookup_by_harness"])}; {o["coverage"]})')
    lines.append('scope: installation · ' + ' · '.join(
        f'{name} failed_by_cause: {mapping(data[name]["installation"]["failed_by_cause"])}; '
        f'kinds: {mapping(data[name]["installation"]["kinds"])}' for name in ('now', 'before')))
    c = data['coverage']
    lines.append(f'coverage: episodes read {c["episodes_read"]} · skipped unattributed {c["unattributed"]} '
                 f'({mapping(c["episodes_skipped"])}) · records read {c["records_read"]}, skipped {c["records_skipped"]} · '
                 f'preselected_by_mtime {str(c["preselected_by_mtime"]).lower()} · '
                 f'observation_cutoff {display(c["observation_cutoff"])} · oldest_as_of {display(c["oldest_as_of"])} · '
                 f'now {completeness_text(data["now"])}, before {completeness_text(data["before"])}' +
                 (' · cap reached; incomplete periods show observed readings only' if c['cap_reached'] else '') +
                 f' · notice logs read {c["notices"]["logs_read"]}, skipped {c["notices"]["skipped"]}')
    return '\n'.join(lines)


def reflex_line(data):
    p = data['now']
    i, o = p['installation'], p['organization']
    if i['lookups'] is None or i['lookups'] < 2:
        return ''
    partial = (p['completeness'] != 'complete' or o['coverage'] != 'complete'
               or o['records_measured'] != o['records_total']
               or i['delivered_measured'] != i['delivered_total'])
    suffix = ' · /records retrieval' + (' · partial' if partial else '')
    delivery = f'delivered {percentage(i["delivered_share"])} of {i["delivered_measured"]}'
    line = (f'memory lookups {data["days"]}d: {i["lookups"]} here · {delivery} · '
            f'org {record_reach(o)}')
    if len(line + suffix) > 160:
        line = f'memory {data["days"]}d: {i["lookups"]} here · {delivery} · org {record_reach(o)}'
    if len(line + suffix) > 160:
        line = f'{data["days"]}d: {i["lookups"]} here · {delivery} · org {record_reach(o)}'
    return line + suffix


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', nargs='?', choices=['line'])
    parser.add_argument('--root', required=True)
    parser.add_argument('--memory')
    parser.add_argument('--days', type=int, default=7)
    parser.add_argument('--after', type=date.fromisoformat)
    parser.add_argument('--before', type=date.fromisoformat)
    parser.add_argument('--json', action='store_true')
    parser.add_argument('--max-episodes', type=int, default=2000)
    args = parser.parse_args(argv)
    if not 1 <= args.days <= 36500 or args.max_episodes < 1:
        parser.error('--days takes 1 to 36500; --max-episodes must be positive')
    if args.command == 'line':
        policy = read_json(Path(args.root) / 'egregore.json').get('features', {})
        policy = policy.get('session_records') if isinstance(policy, dict) else None
        if not isinstance(policy, dict) or policy.get('enabled') is not True:
            return 0
    try:
        data = scorecard(args.root, days=args.days, after=args.after, before=args.before,
                         max_episodes=args.max_episodes, memory=args.memory)
    except (ValueError, OverflowError) as exc:
        parser.error(str(exc))
    output = reflex_line(data) if args.command == 'line' else json.dumps(data, allow_nan=False) if args.json else text_output(data)
    if output:
        print(output)
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
