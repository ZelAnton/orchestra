"""Pair A closures: completed work survives partial reports, retry and recovery."""

import copy
import json
import unittest
from unittest.mock import patch

import test_cycle as fixtures
import test_focus_pairs as pairs
from test_cycle import report
from test_focus_pairs import finding, decision
from cycle_state import Blocked
from cycle_transport import parse_report
from cycle_prompts import PAIR_CONTRACT
from focus_pair_view import read_record
from focus_status import build_panel
from focus_control import status


class PairExecutionTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    edit = fixtures.CycleTests.edit
    start = pairs.PairTests.start
    assign = pairs.PairTests.assign
    until = pairs.PairTests.until

    def step(self):
        self.cycle.paired_review_step()

    def prepare(self, severity='high', blocking=True, effort='xhigh'):
        pair = self.assign(severity=severity, blocking=blocking, effort=effort)
        verify = dict(finding('check'), source_id='check', kind='verification', severity=severity)
        pair['issues'].append(verify)
        task = decision(verify, action='verify', blocking=blocking)
        pair['decisions'].append(task)
        pair['tasks'].append(task)
        self.step()  # Complexity pins a writer for the whole original batch.
        self.role = pair['executor_role']
        self.state['sessions'][self.role] = 'saved-writer-session'
        self.calls = []
        def writer(c, h):
            self.calls.append(copy.deepcopy(c))
            if len(self.calls) == 1:
                (self.root / 'source.txt').write_text('fixed once\n')
                return self.result([self.resolution('assigned')], implementation_fixes=1)
            return self.result([self.resolution(t['source_id'], 'verified' if t['action'] == 'verify' else 'fixed') for t in c['assignments']])
        self.transport.handlers[self.role] = writer
        return pair

    def resolution(self, identity, outcome='fixed'):
        return {'source_id': identity, 'outcome': outcome, 'resolution': 'Exact fixture closure', 'evidence': ['Concrete existing proof']}

    def result(self, resolutions, **kwargs):
        return report(resolutions=resolutions, handoff={'decisions': ['Scoped fixture decision'], 'assumptions': [], 'checks': ['Fixture evidence']}, **kwargs)

    def legacy_result(self, pair):
        prompt = self.cycle.pair_writer_context(self.role)
        self.cycle.invoke(self.role)
        directory = self.store.directory / 'invocations' / self.state['pending']['id']
        intent = json.loads((directory / 'intent.json').read_text())
        intent.pop('pair_execution_binding')
        (directory / 'intent.json').write_text(json.dumps(intent))
        (directory / 'prompt.txt').write_text(prompt)
        self.state['pending'] = None
        pair.pop('writer_invocation', None)
        self.cycle.save()
        return directory

    def test_missing_diagnostic_continues_same_executor_without_repeating_fix(self):
        pair = self.prepare()
        self.step()
        self.assertEqual(pair['execution']['remaining'], ['check'])
        self.assertNotIn('pair_a', self.state['pair_completed'])
        self.assertEqual(self.state['phase'], 'pair_a')
        self.assertEqual(self.state['sessions'][self.role], 'saved-writer-session')
        first_snapshot = self.repo.snapshot()
        self.step()
        self.assertEqual(self.repo.snapshot(), first_snapshot)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual([t['source_id'] for t in self.calls[1]['assignments']], ['check'])
        self.assertEqual(self.calls[1]['continuation']['completed_resolutions'][0]['source_id'], 'assigned')
        self.assertIsNone(self.state['pair_review'])
        self.assertEqual(self.state['phase'], 'pair_a')  # Significant fixes require a fresh outer review.
        self.assertEqual({r['source_id']: r['resolution']['outcome'] for r in self.state['pair_carry']}, {'assigned': 'fixed', 'check': 'verified'})
        self.assertEqual(self.calls[1]['complexity'], self.calls[0]['complexity'])
        self.until(lambda: self.state['phase'] == 'pair_b')
        self.assertEqual([r for r, c in self.transport.calls].count('pair_complexity'), 1)

    def test_deferred_is_representable_and_never_completes_a_pair(self):
        pair = self.prepare(severity='low', blocking=False, effort='high')
        original = self.transport.handlers[self.role]
        def writer(c, h):
            result = original(c, h)
            if len(self.calls) == 1:
                result['resolutions'].append(self.resolution('check', 'deferred'))
            return result
        self.transport.handlers[self.role] = writer
        self.step()
        self.assertEqual(pair['execution']['remaining'], ['check'])
        self.assertEqual(self.state['phase'], 'pair_a')
        self.step()
        self.assertEqual(self.state['phase'], 'pair_b')
        self.assertEqual(self.role, 'pair_cleanup_high')
        conclusion = read_record(self.store, self.state['pair_completed']['pair_a'])
        self.assertEqual({r['outcome'] for r in conclusion['resolutions'][-1]}, {'fixed', 'verified'})

    def test_omitted_fix_is_accounted_without_fabricating_completion(self):
        pair = self.prepare()
        self.transport.handlers[self.role] = lambda c, h: self.result([self.resolution('check', 'verified')])
        self.step()
        self.assertEqual(pair['execution']['remaining'], ['assigned'])
        self.assertNotIn('assigned', pair['execution']['resolutions'])
        self.assertIs(self.state['pair_review'], pair)

    def test_two_stalled_continuations_stop_without_false_credit(self):
        pair = self.prepare()
        initial = self.transport.handlers[self.role]
        def writer(c, h):
            if not self.calls:
                return initial(c, h)
            self.calls.append(c)
            return self.result([self.resolution('check', 'deferred')])
        self.transport.handlers[self.role] = writer
        with self.assertRaisesRegex(Blocked, 'Two executor continuations'):
            self.until(lambda: self.state['phase'] == 'pair_b')
        self.assertEqual(len(self.calls), 3)
        self.assertEqual(pair['execution']['remaining'], ['check'])
        self.assertEqual(self.state['pair_completed'], {})
        with self.assertRaises(Blocked):
            self.step()
        self.assertEqual(len(self.calls), 3)

    def test_wrong_outcome_is_pending_until_real_diagnostic_closure(self):
        pair = self.prepare()
        initial = self.transport.handlers[self.role]
        def writer(c, h):
            value = initial(c, h)
            if len(self.calls) == 1:
                value['resolutions'].append(self.resolution('check', 'fixed'))
            return value
        self.transport.handlers[self.role] = writer
        self.step()
        self.assertEqual(pair['execution']['remaining'], ['check'])
        self.assertIn('requires verified', pair['execution']['errors'][0])
        self.step()
        self.assertIsNone(self.state['pair_review'])

    def test_unknown_resolutions_cannot_expand_assignments(self):
        pair = self.prepare()
        self.transport.handlers[self.role] = lambda c, h: self.result([self.resolution('foreign')])
        with self.assertRaisesRegex(Blocked, 'outside the accepted assignment'):
            self.step()
        self.assertNotIn('execution', pair)
        self.assertEqual(self.state['pair_completed'], {})

    def test_later_edit_invalidates_a_previously_verified_diagnostic(self):
        pair = self.prepare()
        calls = []
        def writer(c, h):
            calls.append(c)
            if len(calls) == 1:
                return self.result([self.resolution('check', 'verified')])
            if len(calls) == 2:
                (self.root / 'source.txt').write_text('later fix\n')
                return self.result([self.resolution('assigned')], implementation_fixes=1)
            return self.result([self.resolution('check', 'verified')])
        self.transport.handlers[self.role] = writer
        self.until(lambda: self.state['pair_review'] is None)
        self.assertEqual([[t['source_id'] for t in c['assignments']] for c in calls], [['assigned', 'check'], ['assigned'], ['check']])
        self.assertEqual(len(pair['execution']['reports']), 3)

    def test_substantial_first_report_is_not_erased_by_clean_continuation(self):
        pair = self.prepare(severity='low', blocking=False)
        original = self.transport.handlers[self.role]
        def writer(c, h):
            result = original(c, h)
            result['substantial'] = len(self.calls) == 1
            return result
        self.transport.handlers[self.role] = writer
        self.step()
        panel = '\n'.join(build_panel(self.state).lines)
        self.assertIn('повтор этой пары', panel)
        self.assertNotIn('без повторного ревью', panel)
        self.step()
        self.assertTrue(pair['execution']['substantial'])
        self.assertEqual(self.state['phase'], 'pair_a')
        self.assertIsNone(self.state['pair_review'])

    def test_dispute_goes_to_arbiter_with_unfinished_obligation_preserved(self):
        pair = self.prepare()
        self.transport.handlers[self.role] = lambda c, h: self.result([self.resolution('assigned', 'disputed')])
        self.step()
        self.assertEqual(pair['step'], 'arbitrate')
        self.assertEqual({r['source_id']: r['resolution']['outcome'] for r in pair['issues']}, {'assigned': 'disputed', 'check': 'deferred'})
        self.assertEqual(self.state['pair_completed'], {})
        self.assertNotIn('execution', pair)

    def test_restart_after_partial_acceptance_only_sends_outstanding_work(self):
        self.prepare()
        self.step()
        self.state = self.store.read()
        self.cycle.state = self.state
        self.step()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual([t['source_id'] for t in self.calls[1]['assignments']], ['check'])

    def test_arbitrated_second_batch_preserves_first_batch_evidence(self):
        pair = self.prepare()
        def partial(c, h):
            (self.root / 'source.txt').write_text('partially fixed\n')
            return self.result([self.resolution('assigned', 'disputed')], implementation_fixes=1)
        self.transport.handlers[self.role] = partial
        self.step()
        first = read_record(self.store, self.state['pair_handoff'][-1])
        original = read_record(self.store, first['sources'][0])
        self.step()  # Arbitration retains unfinished work on the new candidate.
        self.step()  # A changed candidate permits the assignment again.
        self.step()  # Reassess complexity for this batch.
        self.transport.handlers[self.role] = lambda c, h: self.result([
            self.resolution(t['source_id'], 'verified' if t['action'] == 'verify' else 'fixed')
            for t in c['assignments']])
        self.step()
        second = read_record(self.store, self.state['pair_handoff'][-1])
        self.assertEqual(read_record(self.store, first['sources'][0]), original)
        self.assertNotEqual(first['sources'][0]['path'], second['sources'][0]['path'])
        self.assertEqual(len(pair['resolutions']), 2)
        self.assertIsNone(self.state['pair_review'])

    def test_legacy_replay_preserves_original_bytes_and_does_not_repeat_fix(self):
        pair = self.prepare()
        directory = self.legacy_result(pair)
        original = (directory / 'result.json').read_bytes()
        self.state['last'] = {'role': 'heal', 'report': '/unused/healer/result.json'}
        self.step()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(pair['execution']['remaining'], ['check'])
        self.step()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual((directory / 'result.json').read_bytes(), original)

    def test_new_completed_result_can_replay_after_pending_was_cleared(self):
        pair = self.prepare()
        self.cycle.invoke(self.role)
        identity = self.state['pending']['id']
        self.state['pending'] = None
        self.step()
        self.assertEqual(len(self.calls), 1)
        self.assertEqual(pair['execution']['consumed'], [identity])
        self.step()
        self.assertEqual(len(self.calls), 2)

    def test_legacy_intent_must_match_phase_assignment_revision_and_current_bytes(self):
        pair = self.prepare()
        directory = self.legacy_result(pair)
        path = directory / 'prompt.txt'
        original = path.read_text()
        context = json.JSONDecoder().raw_decode(original.split('Executor assignment:\n', 1)[1])[0]
        for key, value in [('phase', 'final'), ('assignments', []), ('candidate', 'stale'), ('complexity', {})]:
            with self.subTest(field=key):
                path.write_text('Executor assignment:\n' + json.dumps(dict(context, **{key: value})))
                self.assertIsNone(self.cycle.saved_pair_execution(pair))
        path.write_text(original)
        self.state['correction_revision'] = 'later'
        self.assertIsNone(self.cycle.saved_pair_execution(pair))
        self.state['correction_revision'] = None
        self.assertIsNotNone(self.cycle.saved_pair_execution(pair))
        (self.root / 'source.txt').write_text('different bytes\n')
        self.assertIsNone(self.cycle.saved_pair_execution(pair))
        with self.assertRaisesRegex(Blocked, 'candidate changed'):
            self.step()

    def test_noop_heal_keeps_original_result_available_for_closure(self):
        pair = self.prepare()
        self.legacy_result(pair)
        self.state['blocker'] = {'phase': 'pair_a', 'status': 'healing'}
        transport = self.cycle.transport
        self.cycle.transport = fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()
        self.cycle.transport = transport
        self.assertIs(self.state['pair_review'], pair)
        self.step()
        self.assertEqual(len(self.calls), 1)
        self.step()
        self.assertEqual(len(self.calls), 2)

    def test_changed_shared_operator_instructions_reject_legacy_replay(self):
        pair = self.prepare()
        self.legacy_result(pair)
        self.state['pair_instructions'] = [{'id': 'new-instruction', 'text': 'Require new diagnostic evidence'}]
        self.assertIsNone(self.cycle.saved_pair_execution(pair))
        with self.assertRaisesRegex(Blocked, 'candidate changed'):
            self.step()
        self.assertEqual(len(self.calls), 1)

    def test_cli_retry_recovers_original_then_only_continues_verification(self):
        import cc_focus
        pair = self.prepare()
        self.legacy_result(pair)
        self.state.update(status='blocked', blocker={'phase': 'pair_a', 'status': 'blocked',
            'signature': 'fixture', 'code': 'pair-closure', 'message': 'Incomplete report'})
        self.cycle.save()
        with patch('cc_focus.Path.cwd', return_value=self.root), patch('cc_focus.Lease') as lease, patch('cc_focus.Cycle.run', return_value=0):
            lease.return_value.__enter__.return_value.pwsh = 'pwsh'
            self.assertEqual(cc_focus.main(['--retry']), 0)
        self.state = self.store.read()
        self.cycle.state = self.state
        self.assertIsNone(self.state['blocker'])
        self.step()
        self.assertEqual(len(self.calls), 1)
        self.step()
        self.assertEqual([t['source_id'] for t in self.calls[1]['assignments']], ['check'])

    def test_cached_continuation_is_consumed_once_after_restart(self):
        pair = self.prepare()
        self.step()
        self.cycle.invoke(self.role)
        identity = self.state['pending']['id']
        self.state['pending'] = None
        self.cycle.save()
        self.state = self.store.read()
        self.cycle.state = self.state
        self.step()
        self.assertEqual(len(self.calls), 2)
        self.assertIsNone(self.state['pair_review'])
        history = read_record(self.store, self.state['pair_handoff'][-1])
        self.assertEqual(len(history['sources']), 2)
        self.assertEqual(read_record(self.store, history['sources'][-1])['invocation'], identity)

    def test_noop_heal_during_continuation_does_not_restart_inspection(self):
        pair = self.prepare()
        self.step()
        self.state['blocker'] = {'phase': 'pair_a', 'status': 'healing'}
        transport = self.cycle.transport
        self.cycle.transport = fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()
        self.cycle.transport = transport
        self.assertIs(self.state['pair_review'], pair)
        self.assertEqual(pair['execution']['remaining'], ['check'])
        self.step()
        self.assertIsNone(self.state['pair_review'])

    def test_external_edit_during_continuation_cannot_be_adopted(self):
        self.prepare()
        self.step()
        (self.root / 'source.txt').write_text('external\n')
        with self.assertRaisesRegex(Blocked, 'candidate changed'):
            self.step()
        self.assertEqual(len(self.calls), 1)

    def test_continuation_preserves_vcs_and_protected_work_guards(self):
        pair = self.prepare()
        self.step()
        def writer(c, h):
            self.repo.git('add', '--', 'source.txt')
            return self.result([self.resolution('check', 'verified')])
        self.transport.handlers[self.role] = writer
        with self.assertRaisesRegex(Blocked, 'changed staging'):
            self.step()
        self.assertEqual(pair['execution']['remaining'], ['check'])

    def test_operator_steering_precedes_closure_validation(self):
        self.prepare()
        def writer(c, h):
            self.state['pending']['restart_reviews'] = True
            return self.result([])
        self.transport.handlers[self.role] = writer
        self.step()
        self.assertIsNone(self.state['pair_review'])
        self.assertEqual(self.state['phase'], 'pair_a')
        self.assertEqual(len(self.state['pair_carry']), 2)

    def test_ledger_corruption_cannot_replay_closures(self):
        pair = self.prepare()
        self.step()
        ref = pair['execution']['reports'][0]
        (self.store.directory / ref['path']).write_text('corrupt')
        with self.assertRaisesRegex(Blocked, 'sealed pair artifact'):
            self.step()
        self.assertEqual(len(self.calls), 1)

    def test_schema_and_instruction_scopes_agree_for_all_writer_variants(self):
        value = self.result([self.resolution('check', 'deferred')])
        for role in ('pair_fix', 'pair_fix_high', 'pair_cleanup', 'pair_cleanup_high'):
            self.assertEqual(parse_report(json.dumps(value), role)['resolutions'][0]['outcome'], 'deferred')
        self.assertIn('Pair A has NO two-clean-pass inner', PAIR_CONTRACT)
        self.assertIn('ONLY B/FINAL repair_execute with operation=fix', PAIR_CONTRACT)
        self.prepare()
        context = self.cycle.pair_writer_context(self.role)
        self.assertIn('PAIR A: make the assigned corrections now. Then run the assigned targeted checks.', context)

    def test_panel_and_json_status_show_remaining_obligations(self):
        self.prepare()
        self.step()
        self.assertIn('закрыто 1/2', '\n'.join(build_panel(self.state).lines))
        self.assertEqual(status(self.store, self.state)['pair_review']['execution']['remaining'], ['check'])


if __name__ == '__main__':
    unittest.main()
