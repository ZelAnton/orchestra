"""Unchanged executor reports: correct accounting without repeating successful work."""

import copy
import json
import unittest
from pathlib import Path
from unittest.mock import patch

import test_focus_pair_execution as execution_tests
import test_cycle as fixtures
from cycle_state import Blocked, ProviderQuota
from cycle_transport import Transport, parse_report, repairable_executor_accounting
from focus_pair_view import read_record


class ExecutorAccountingTests(unittest.TestCase):
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'assign', 'until', 'step', 'prepare', 'resolution', 'result'):
        locals()[_name] = getattr(execution_tests.PairExecutionTests, _name)

    def correction_transport(self, callback=None):
        self.corrections = []
        normal = self.transport.run
        def run(role, prompt, pending, directory):
            if not pending.get('report_repair'):
                return normal(role, prompt, pending, directory)
            self.corrections.append((role, prompt, copy.deepcopy(pending)))
            original = json.loads(json.loads(Path(pending['report_repair']['source']).read_text())['raw'])
            value = dict(original, substantial=False, description='No edits in this invocation; earlier cumulative impact is retained by runtime.')
            if callback:
                value = callback(value)
            return json.dumps(value)
        self.transport.run = run

    def verification(self):
        pair = self.prepare()
        normal = self.transport.handlers[self.role]
        def writer(c, h):
            return dict(normal(c, h), substantial=True)
        self.transport.handlers[self.role] = writer
        self.step()  # Significant fix accepted; verification remains.
        self.correction_transport()
        return pair

    def legacy_rejection(self):
        pair = self.verification()
        with patch('cycle_workflow.repairable_executor_accounting', return_value=None), \
                patch('cycle_workflow.repairable_substantial_accounting', return_value=None):  # Older runtime.
            with self.assertRaisesRegex(Blocked, 'substantial requires') as caught:
                self.step()
        pending = copy.deepcopy(self.state['pending'])
        self.cycle.handle_block(caught.exception)
        self.state['status'] = self.state['blocker']['status'] = 'blocked'
        self.cycle.save()
        return pair, pending

    def test_successful_checks_get_one_correction_and_keep_batch_impact(self):
        pair = self.verification()
        before = self.repo.snapshot()
        self.step()
        self.assertEqual(self.repo.snapshot(), before)
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(len(self.corrections), 1)
        self.assertTrue(pair['execution']['substantial'])
        self.assertIsNone(self.state['pair_review'])
        self.assertEqual(self.state['phase'], 'pair_a')
        self.assertEqual(self.state['sessions'][self.role], 'saved-writer-session')
        role, prompt, pending = self.corrections[0]
        self.assertEqual(role, self.role)
        self.assertIn('REPORT-ONLY CORRECTION', prompt)
        self.assertIn('Do not run tools, tests, builds', prompt)
        self.assertIn('original_report', prompt)
        corrected = json.loads(Path(self.state['last']['report']).read_text())
        original = json.loads(Path(pending['report_repair']['source']).read_text())
        self.assertTrue(json.loads(original['raw'])['substantial'])
        with self.assertRaises(Blocked):
            parse_report(original['raw'], role)  # Strict original validation was not weakened.
        self.assertFalse(parse_report(corrected['raw'], role)['substantial'])
        self.assertEqual(original['before'], corrected['before'])
        self.assertEqual(original['after'], corrected['after'])

    def test_native_claude_prompt_keeps_report_only_scope_after_interruption(self):
        self.verification()
        self.correction_transport(lambda value: (_ for _ in ()).throw(KeyboardInterrupt()))
        with self.assertRaises(KeyboardInterrupt):
            self.step()
        pending = self.state['pending']
        pending['attempts'] = 1
        directory = self.store.directory / 'native-correction-prompt'
        directory.mkdir()
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        with patch.object(transport, '_claude', return_value=json.dumps(self.result([]))) as provider:
            transport.run(self.role, self.cycle.report_repair_context(pending), pending, directory)
        prompt = provider.call_args.args[4]
        self.assertIn('REPORT-ONLY CORRECTION', prompt)
        self.assertIn('substantial=false', prompt)
        self.assertIn('Do not run tools, tests, builds', prompt)
        self.assertNotIn('RECOVERY:', prompt)

    def test_existing_blocker_cli_retry_only_requests_report_correction(self):
        import cc_focus
        pair, original = self.legacy_rejection()
        path = self.store.directory / 'invocations' / original['id'] / 'result.json'
        raw = path.read_bytes()
        with patch('cc_focus.Path.cwd', return_value=self.root), patch('cc_focus.Lease') as lease, patch('cc_focus.Cycle.run', return_value=0):
            lease.return_value.__enter__.return_value.pwsh = 'pwsh'
            self.assertEqual(cc_focus.main(['--retry']), 0)
        self.state = self.cycle.state = self.store.read()
        self.step()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(len(self.corrections), 1)
        self.assertEqual(path.read_bytes(), raw)
        self.assertIsNone(self.state['pair_review'])
        self.assertTrue(read_record(self.store, self.state['pair_handoff'][-1])['sources'])

    def test_incomplete_correction_resumes_after_blocker_clears_pending(self):
        pair = self.verification()
        self.correction_transport(lambda value: (_ for _ in ()).throw(KeyboardInterrupt()))
        with self.assertRaises(KeyboardInterrupt):
            self.step()
        identity = self.state['pending']['id']
        self.cycle.handle_block(Blocked('fixture', 'Correction interrupted'))
        self.state = self.cycle.state = self.store.read()
        self.state.update(blocker=None, status='ready')
        self.correction_transport()
        self.step()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(self.corrections[0][2]['id'], identity)
        self.assertIsNone(self.state['pair_review'])

    def test_completed_correction_replays_once_after_crash_before_closure(self):
        pair = self.verification()
        self.cycle.invoke(self.role)  # Both original verification and correction finish.
        identity = self.state['pending']['id']
        self.state['pending'] = None
        self.cycle.save()
        self.state = self.cycle.state = self.store.read()
        self.step()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(len(self.corrections), 1)
        result = read_record(self.store, self.state['pair_handoff'][-1])
        self.assertEqual(read_record(self.store, result['sources'][-1])['invocation'], identity)

    def test_correction_cannot_change_proof_or_fabricate_fixes(self):
        pair = self.verification()
        self.correction_transport(lambda value: dict(value, resolutions=[]))
        with self.assertRaisesRegex(Blocked, 'preserve all checks'):
            self.step()
        self.assertEqual(pair['execution']['remaining'], ['check'])
        with self.assertRaisesRegex(Blocked, 'preserve all checks'):
            self.step()
        self.assertEqual(len(self.corrections), 1)
        self.assertEqual(self.state['pair_completed'], {})

    def test_invalid_correction_does_not_trigger_another_correction(self):
        self.verification()
        self.correction_transport(lambda value: dict(value, substantial=True))
        for attempt in range(2):
            with self.assertRaisesRegex(Blocked, 'substantial requires') as caught:
                self.step()
            if attempt == 0:
                self.cycle.handle_block(caught.exception)
                self.state.update(blocker=None, status='ready')
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(len(self.corrections), 1)

    def test_correction_cannot_edit_candidate(self):
        self.verification()
        def mutate(value):
            (self.root / 'source.txt').write_text('unexpected correction edit\n')
            return value
        self.correction_transport(mutate)
        with self.assertRaisesRegex(Blocked, 'Working files, HEAD or index'):
            self.step()
        self.assertEqual(self.state['pair_completed'], {})

    def test_malformed_correction_retry_never_reruns_successful_checks(self):
        self.verification()
        self.correction_transport(lambda value: dict(value, unexpected=True))
        with self.assertRaisesRegex(Blocked, 'unknown report fields') as caught:
            self.step()
        self.cycle.handle_block(caught.exception)
        self.state.update(blocker=None, status='ready')
        with self.assertRaisesRegex(Blocked, 'unknown report fields'):
            self.step()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(len(self.corrections), 1)

    def test_blocked_correction_retry_never_reruns_successful_checks(self):
        self.verification()
        self.correction_transport(lambda value: dict(value, status='blocked'))
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'reported-blocker')
        self.cycle.handle_block(caught.exception)
        self.state.update(blocker=None, status='ready')
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'reported-blocker')
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(len(self.corrections), 1)

    def test_original_report_remains_guarded_during_correction(self):
        self.verification()
        def corrupt(value):
            Path(self.state['pending']['report_repair']['source']).write_text('{}')
            return value
        self.correction_transport(corrupt)
        with self.assertRaisesRegex(Blocked, 'original review report changed'):
            self.step()
        self.assertEqual(self.state['pair_completed'], {})

    def test_correction_cannot_fabricate_fix_counts(self):
        self.verification()
        self.correction_transport(lambda value: dict(value, implementation_fixes=1))
        with self.assertRaisesRegex(Blocked, 'preserve all checks'):
            self.step()
        self.assertEqual(self.state['pair_completed'], {})

    def test_correction_cannot_stage_files(self):
        self.verification()
        def stage(value):
            self.repo.git('add', '--', 'source.txt')
            return value
        self.correction_transport(stage)
        with self.assertRaisesRegex(Blocked, 'Working files, HEAD or index'):
            self.step()
        self.assertEqual(self.state['pair_completed'], {})

    def test_noop_heal_keeps_rejected_original_available(self):
        pair, original = self.legacy_rejection()
        transport = self.cycle.transport
        self.cycle.transport = fixtures.FixtureTransport(self.root, [('heal', fixtures.report())])
        self.cycle.heal()
        self.cycle.transport = transport
        self.assertIs(self.state['pair_review'], pair)
        self.step()
        self.assertEqual(len(self.calls), 2)
        self.assertEqual(len(self.corrections), 1)
        self.assertTrue(pair['execution']['substantial'])

    def test_changed_invocation_is_not_eligible_for_zero_edit_correction(self):
        self.verification()
        normal = self.transport.handlers[self.role]
        def edit(c, h):
            value = normal(c, h)
            (self.root / 'journal.md').write_text('New evidence\n')
            return value
        self.transport.handlers[self.role] = edit
        # Not the zero-edit correction: the changed invocation must account for its edit.
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'report-repair-content')
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['substantial-accounting'])

    def test_quota_resumes_correction_without_repeating_verification(self):
        self.verification()
        self.correction_transport(lambda value: (_ for _ in ()).throw(ProviderQuota(1, no_work=True)))
        with self.assertRaises(ProviderQuota) as caught:
            self.step()
        identity = self.state['pending']['id']
        self.cycle.defer_quota(caught.exception)
        self.correction_transport()
        self.step()
        self.assertEqual(self.corrections[0][2]['id'], identity)
        self.assertEqual(len(self.calls), 2)

    def test_probe_rejects_other_defects_or_changed_work(self):
        self.prepare()
        snapshot = self.repo.snapshot()
        good = self.result([self.resolution('check', 'verified')], substantial=True)
        self.assertIsNotNone(repairable_executor_accounting(json.dumps(good), self.role, snapshot, snapshot))
        for bad in (dict(good, minor_edits=1), dict(good, implementation_fixes=False),
                    dict(good, evidence=['']), dict(good, resolutions=[self.resolution('check', 'unknown')]),
                    dict(good, status='blocked'), dict(good, alien=True)):
            self.assertIsNone(repairable_executor_accounting(json.dumps(bad), self.role, snapshot, snapshot))
        self.assertIsNone(repairable_executor_accounting(json.dumps(good), self.role, snapshot, dict(snapshot, index='changed')))
        self.assertIsNone(repairable_executor_accounting(json.dumps(good), 'code', snapshot, snapshot))

    def test_stale_binding_cannot_adopt_rejected_verification(self):
        pair, _ = self.legacy_rejection()
        self.state['pair_instructions'] = [{'id': 'later', 'text': 'New verification requirement'}]
        self.assertIsNone(self.cycle.saved_pair_execution(pair))

    def test_late_test_correction_preserves_two_clean_static_passes(self):
        for phase, destination in (('pair_b', 'final'), ('final', 'publish')):
            with self.subTest(phase=phase):
                pair = self.assign(phase, 'low', False)
                gate = pair['repair']
                execute = self.transport.dispatch
                def dispatch(role, prompt, heartbeat):
                    value = json.loads(execute(role, prompt, heartbeat))
                    if role == 'repair_execute' and not value['implementation_fixes']:
                        value['substantial'] = True
                    return json.dumps(value)
                self.transport.dispatch = dispatch
                self.correction_transport()
                self.until(lambda: self.state['phase'] == destination)
                self.assertEqual(gate['clean'], 2)
                self.assertEqual(len(self.corrections), 1)
                self.assertEqual([r for r, c in self.transport.calls].count('repair_execute'), 2)

    def test_saved_late_test_rejection_is_corrected_without_retesting(self):
        pair = self.assign('pair_b', 'low', False)
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        normal = self.transport.dispatch
        def dispatch(role, prompt, heartbeat):
            return json.dumps(dict(json.loads(normal(role, prompt, heartbeat)), substantial=True))
        self.transport.dispatch = dispatch
        self.correction_transport()
        with patch('cycle_workflow.repairable_executor_accounting', return_value=None), \
                patch('cycle_workflow.repairable_substantial_accounting', return_value=None):  # Older runtime.
            with self.assertRaisesRegex(Blocked, 'substantial requires') as caught:
                self.step()
        self.cycle.handle_block(caught.exception)
        self.state.update(blocker=None, status='ready')
        self.until(lambda: self.state['phase'] == 'final')
        self.assertEqual(gate['clean'], 2)
        self.assertEqual(len(self.corrections), 1)
        self.assertEqual([r for r, c in self.transport.calls].count('repair_execute'), 2)


if __name__ == '__main__':
    unittest.main()
