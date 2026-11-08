"""Durable Pair A executor closure and bounded continuation of unfinished work."""

import copy
import json
from pathlib import Path
import uuid

from cycle_state import Blocked, digest, encode
from focus_pair_protocol import assignment_key
from focus_pair_view import artifact, read_record


class PairExecution:
    def pair_execution_tasks(self, pair):
        execution = pair.get('execution')
        return [t for t in pair['tasks'] if not execution or t['source_id'] in execution['remaining']]

    def pair_execution_binding(self, pair):
        snapshot = (pair.get('execution') or {}).get('snapshot', pair['snapshot'])
        return {'pair': pair['id'], 'role': pair['executor_role'],
                'assignment': assignment_key(snapshot, self.pair_execution_tasks(pair)),
                'assessment': pair['assessment'], 'instructions': digest(encode(self.pair_operator_instructions()))}

    def saved_pair_execution(self, pair):
        if not pair or pair['phase'] != 'pair_a' or pair['step'] not in ('fix', 'cleanup'):
            return None
        pending = self.state.get('pending') or {}
        identity = pending.get('id') if pending.get('role') == pair['executor_role'] else pair.get('writer_invocation')
        last = self.state.get('last') or {}
        if not identity and last.get('role') == pair['executor_role']:
            identity = Path(last['report']).parent.name
        if identity:
            return self.read_pair_execution(pair, identity)
        if pending:
            return None
        # Older recoveries may have replaced `last` with a healer result. A
        # unique exact original is required; never use a healer's account as proof.
        matches = [saved for directory in (self.store.directory / 'invocations').glob('*')
                   if directory.is_dir() and (saved := self.read_pair_execution(pair, directory.name))]
        return matches[0] if len(matches) == 1 else None

    def read_pair_execution(self, pair, identity):
        execution = pair.get('execution') or {}
        if not identity or identity in execution.get('consumed', []) or Path(identity).name != identity:
            return None
        directory = self.store.directory / 'invocations' / identity
        if not directory.resolve().is_relative_to(self.store.directory.resolve()):
            return None
        try:
            intent = json.loads((directory / 'intent.json').read_text(encoding='utf-8'))
            expected = execution.get('snapshot', pair['snapshot'])
            if (intent.get('id') != identity or intent.get('role') != pair['executor_role']
                    or intent.get('iteration') != self.state['iteration']
                    or intent.get('correction_revision') != self.state.get('correction_revision')
                    or intent.get('restart_reviews') or self.snapshot(intent['before']) != expected):
                return None
            result = self.executor_result_candidate(directory, intent)
            report = self.executor_candidate_report(intent, result)
            if (self.snapshot(result['before']) != expected or self.snapshot(result['after']) != self.snapshot()
                    or report['status'] != 'done' or self.messages.unresolved(self.state['iteration'])):
                return None
            accepted = [m['identity']['id'] for m in self.messages.accepted(self.state['iteration'], identity)]
            if result.get('operator_messages', []) != accepted:
                return None
            if 'pair_execution_binding' in intent:
                if intent['pair_execution_binding'] != self.pair_execution_binding(pair):
                    return None
            else:
                if execution:
                    return None  # Continuations were introduced with explicit binding.
                prompt = (directory / 'prompt.txt').read_text(encoding='utf-8')
                context = json.JSONDecoder().raw_decode(prompt.split('Executor assignment:\n', 1)[1])[0]
                if (context.get('phase') != pair['phase'] or context.get('assignments') != pair['tasks']
                        or context.get('candidate') != digest(encode(pair['snapshot']))
                        or context.get('operator_instructions') != self.pair_operator_instructions()
                        or context.get('complexity') != self.pair_assessment(pair)):
                    return None
            return intent, result
        except (OSError, ValueError, KeyError, TypeError, IndexError, Blocked):
            return None

    def pair_executor_step(self, pair):
        assessment = self.pair_assessment(pair)
        role = 'pair_' + pair['step'] + ('_high' if assessment['effort'] == 'high' else '')
        if role != pair['executor_role']:
            raise Blocked('pair-complexity', 'The pinned executor does not match the complexity assessment.')
        execution = pair.get('execution')
        if execution and execution.get('stalls', 0) >= 2:
            raise Blocked('pair-no-progress', 'Two executor continuations left the same assignments unresolved; retained reports require recovery.')
        saved = self.saved_pair_execution(pair)
        if saved and not self.state.get('pending'):
            self.state['pending'] = copy.deepcopy(saved[0])
            pair['writer_invocation'] = saved[0]['id']
            self.save()
        expected = execution['snapshot'] if execution else pair['snapshot']
        if not self.state.get('pending') and self.snapshot() != expected:
            raise Blocked('pair-executor-drift', 'The executor candidate changed outside its saved invocation; no completed work was replayed.')
        report, before, after, _ = self.invoke(role)
        if (self.state.get('pending') or {}).get('restart_reviews'):
            self.reset_reviews('Оператор изменил задание исполнителю; обе пары проверяются заново')
            self.state.update(pending=None, last_snapshot=after)
            self.save()
            return
        self.accept_pair_execution(pair, report, before, after)

    def accept_pair_execution(self, pair, report, before, after):
        state = self.state
        tasks = {t['source_id']: t for t in pair['tasks']}
        incoming = {r['source_id']: r for r in report['resolutions']}
        if set(incoming) - set(tasks):
            raise Blocked('pair-closure', 'Executor reported findings outside the accepted assignment.')
        previous = pair.get('execution')
        execution = copy.deepcopy(previous) if previous else {'id': uuid.uuid4().hex, 'resolutions': {}, 'remaining': list(tasks),
            'reports': [], 'consumed': [], 'stalls': 0, 'substantial': pair['impact'] == 'substantial'}
        resolutions = execution['resolutions']
        # A later edit cannot silently reuse diagnostics on the previous bytes.
        # Fix claims remain for the independent outer review to inspect.
        if previous and self.changes(before, after):
            resolutions = {k: v for k, v in resolutions.items() if v['outcome'] != 'verified'}
        errors = []
        for identity, row in incoming.items():
            expected = 'fixed' if tasks[identity]['action'] == 'fix' else 'verified'
            if row['outcome'] in (expected, 'disputed'):
                resolutions[identity] = row
            else:
                resolutions.pop(identity, None)
                errors.append(identity + ': ' + row['outcome'] + '; requires ' + expected + ' or a reasoned dispute')
        remaining = [k for k in tasks if k not in resolutions]
        pending = state['pending']
        record = artifact(self.store, f"pair-reviews/{state['iteration']}/{pair['id']}/execution-{execution['id']}/report-{len(execution['reports'])}.json",
            {'report': report, 'invocation': pending['id'], 'before': digest(encode(before)), 'after': digest(encode(after)),
             'requested': [t['source_id'] for t in self.pair_execution_tasks(pair)]})
        execution['reports'].append(record)
        execution['consumed'] += self.with_correction_source(pending['id'])
        execution['substantial'] |= report['substantial']
        execution.update(snapshot=after, resolutions=resolutions, remaining=remaining, errors=errors,
            stalls=execution['stalls'] + 1 if previous and set(previous['remaining']) == set(remaining) else 0)
        pair['execution'] = execution
        pair.pop('writer_invocation', None)
        state.update(pending=None, last_snapshot=after)
        if self.changes(pair['snapshot'], after):
            state.setdefault('pair_clean', {})[pair['phase']] = 0
        disputed = any(r['outcome'] == 'disputed' for r in resolutions.values())
        if remaining and not disputed:
            self.save()
            if execution['stalls'] >= 2:
                raise Blocked('pair-no-progress', 'Two executor continuations left the same assignments unresolved; retained reports require recovery.')
            print(f'cc-focus: executor retained {len(resolutions)}/{len(tasks)} closures; continuing {len(remaining)} outstanding assignments.', flush=True)
            return
        if disputed:
            # Pending work is an obligation for arbitration, never a fabricated
            # successful resolution. Do not run diagnostics on a disputed repair.
            for identity in remaining:
                resolutions[identity] = {'source_id': identity, 'outcome': 'deferred',
                    'resolution': 'Unfinished assignment; arbitration must retain or explicitly decide it.',
                    'evidence': [tasks[identity]['check']]}
        self.finish_pair_execution(pair, list(resolutions.values()), after, disputed)

    def finish_pair_execution(self, pair, resolutions, after, disputed):
        state = self.state
        execution = pair['execution']
        reports = [read_record(self.store, record)['report'] for record in execution['reports']]
        pair['resolutions'].append(resolutions)
        record = artifact(self.store, f"pair-reviews/{state['iteration']}/{pair['id']}/executor-{len(pair['resolutions'])}.json",
            {'sources': execution['reports'], 'resolutions': resolutions, 'candidate_after': digest(encode(after)),
             'handoff': {k: list(dict.fromkeys(v for r in reports for v in r['handoff'][k]))
                         for k in ('decisions', 'assumptions', 'checks')},
             'phase': pair['phase'], 'round': pair.get('round')})
        state.setdefault('pair_handoff', []).append(record)
        edited = bool(self.changes(pair['snapshot'], after))
        if disputed:
            by_id = {r['source_id']: r for r in pair['issues']}
            for resolution in resolutions:
                by_id[resolution['source_id']]['resolution'] = resolution
            pair['step'] = 'arbitrate'
            if edited:
                pair.setdefault('reports_candidate', digest(encode(pair['snapshot'])))
                pair.update(snapshot=after, view=None, needs_inspection=True, view_generation=pair.get('view_generation', 0) + 1)
            pair.pop('execution')
            self.save()
        elif pair['step'] == 'cleanup' and not execution['substantial']:
            self.finish_pair(pair, after, cleanup=True)
        else:
            by_id = {r['source_id']: r for r in pair['issues']}
            by_resolution = {r['source_id']: r for r in resolutions}
            carry = [dict(by_id[t['source_id']], previous_decision=t, resolution=by_resolution[t['source_id']]) for t in pair['tasks']]
            state.update(pair_carry=carry, pair_review=None, last_snapshot=after)
            self.save()
