"""Executor counter rules, one report-only correction, and recovery verification by pair progress."""

import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import test_focus_executor_accounting as accounting_tests
import test_focus_pair_execution as execution_tests
import test_focus_pairs as pairs
import test_focus_repair_evidence as evidence_tests
import test_focus_repair as repair_tests
import test_focus_snapshot_archive as archives
import test_cycle as fixtures
from test_cycle import report
from test_focus_pairs import finding
from cycle_state import Blocked
from cycle_prompts import EXECUTOR_ACCOUNTING_CONTRACT, PAIR_CONTRACT, PROFILES, role_contract
from cycle_transport import parse_report, repairable_substantial_accounting
from focus_pair_profile import PAIR_READONLY, PAIR_WRITERS


class CounterRuleTests(unittest.TestCase):
    def test_only_executors_receive_the_counter_rules(self):
        for role in PROFILES:
            with self.subTest(role=role):
                self.assertEqual(EXECUTOR_ACCOUNTING_CONTRACT in role_contract(role), role in PAIR_WRITERS)
        self.assertNotIn(EXECUTOR_ACCOUNTING_CONTRACT, PAIR_CONTRACT)  # Saved reader prompts stay unchanged.
        self.assertIn('implementation_fixes must be at least 1', EXECUTOR_ACCOUNTING_CONTRACT)
        # A correction changes no files, but it reports the original invocation.
        self.assertIn('"this invocation" means the ORIGINAL invocation', EXECUTOR_ACCOUNTING_CONTRACT)

    def test_recognizer_accepts_only_the_inconsistent_classification(self):
        def raw(**kwargs):
            return json.dumps(report(resolutions=[], handoff={'decisions': [], 'assumptions': [], 'checks': []}, **kwargs))
        inconsistent = raw(other_fixes=2, substantial=True)
        with self.assertRaisesRegex(Blocked, 'substantial requires'):
            parse_report(inconsistent, 'pair_cleanup')
        self.assertIsNotNone(repairable_substantial_accounting(inconsistent, 'pair_cleanup'))
        for role in ('code', 'publish', 'coordinate', 'heal', 'sol', 'opus', 'astra', 'opus_final', 'final_fix'):
            with self.subTest(role=role):
                # The report is valid for this role apart from the counters, so only the role
                # decides. Other roles keep the blocker. A publisher keeps its mutation guard.
                other = report(other_fixes=2, substantial=True)
                parse_report(json.dumps(dict(other, substantial=False)), role)
                self.assertIsNone(repairable_substantial_accounting(json.dumps(other), role))
        self.assertIsNone(repairable_substantial_accounting(raw(implementation_fixes=1, substantial=True), 'pair_cleanup'))
        self.assertIsNone(repairable_substantial_accounting(raw(substantial=True, summary=' '), 'pair_cleanup'))
        # A blocked report stops the cycle with its own reason, whatever its counters say.
        self.assertIsNone(repairable_substantial_accounting(raw(other_fixes=2, substantial=True, status='blocked'),
                                                            'pair_cleanup'))
        self.assertIsNone(repairable_substantial_accounting('not json', 'pair_cleanup'))


class SubstantialCorrectionTests(unittest.TestCase):
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'assign', 'until', 'step', 'resolution', 'result'):
        locals()[_name] = getattr(execution_tests.PairExecutionTests, _name)

    def prepare(self, correction):
        pair = self.assign(severity='low', blocking=False, effort='high')
        self.step()  # Complexity pins the cleanup executor.
        self.role = pair['executor_role']
        self.state['sessions'][self.role] = 'saved-writer-session'
        self.calls, self.corrections = [], []
        def writer(c, h):
            self.calls.append(copy.deepcopy(c))
            (self.root / 'source.txt').write_text('cleaned\n')
            return self.result([self.resolution(t['source_id']) for t in c['assignments']],
                               other_fixes=2, substantial=True)
        self.transport.handlers[self.role] = writer
        normal = self.transport.run
        def run(role, prompt, pending, directory):
            if not pending.get('report_repair'):
                return normal(role, prompt, pending, directory)
            self.corrections.append((role, prompt, copy.deepcopy(pending)))
            original = json.loads(json.loads(Path(pending['report_repair']['source']).read_text())['raw'])
            return json.dumps(correction(dict(original)))
        self.transport.run = run
        return pair

    def test_executor_corrects_its_own_counters_in_the_same_session(self):
        self.prepare(lambda value: dict(value, implementation_fixes=1, other_fixes=1))
        self.step()
        self.assertEqual((self.root / 'source.txt').read_text(), 'cleaned\n')  # Only the original edit exists.
        self.assertEqual(len(self.calls), 1)  # The cleanup work is not repeated.
        self.assertEqual(len(self.corrections), 1)
        role, prompt, pending = self.corrections[0]
        self.assertEqual((role, pending['report_repair']['reason']), (self.role, 'substantial-accounting'))
        self.assertIn('REPORT-ONLY CORRECTION', prompt)
        self.assertIn('source.txt', prompt)
        self.assertEqual(self.state['sessions'][self.role], 'saved-writer-session')
        self.assertIsNone(self.state['blocker'])
        self.assertIsNone(self.state['pending'])
        corrected = json.loads(Path(self.state['last']['report']).read_text())
        self.assertEqual(parse_report(corrected['raw'], self.role)['implementation_fixes'], 1)
        original = Path(pending['report_repair']['source']).parent.name
        self.assertEqual(self.cycle.with_correction_source(pending['id']), [pending['id'], original])

    def test_correction_cannot_change_resolutions_or_drop_all_counters(self):
        for change in (lambda value: dict(value, implementation_fixes=1, resolutions=[]),
                       lambda value: dict(value, other_fixes=0, substantial=False)):
            with self.subTest(change=change):
                self.tearDown()
                self.setUp()
                self.start('pair_a')
                self.prepare(change)
                with self.assertRaises(Blocked) as caught:
                    self.step()
                self.assertEqual(caught.exception.code, 'report-repair-content')
                self.assertEqual(len(self.corrections), 1)

    def test_unreported_executor_edits_get_the_same_bounded_correction(self):
        self.prepare(lambda value: dict(value, minor_edits=1))
        writer = self.transport.handlers[self.role]
        self.transport.handlers[self.role] = lambda c, h: dict(writer(c, h), other_fixes=0, substantial=False)
        self.step()
        self.assertEqual(self.corrections[0][2]['report_repair']['reason'], 'changed-file-accounting')
        prompt = self.corrections[0][1]
        # The executor sees the fields that the validator lets it change, and its original report.
        self.assertIn('Change only implementation_fixes, other_fixes, minor_edits, substantial, summary, and', prompt)
        self.assertIn('"original_report"', prompt)
        self.assertIn('count it as an implementation fix and set substantial=true', prompt)
        self.assertIsNone(self.state['blocker'])

    def unreported_edits(self, correction):
        """The executor edits a file but reports all three counters as 0."""
        self.prepare(correction)
        writer = self.transport.handlers[self.role]
        self.transport.handlers[self.role] = lambda c, h: dict(writer(c, h), other_fixes=0, substantial=False)

    def test_a_changed_file_correction_cannot_change_resolutions(self):
        self.unreported_edits(lambda value: dict(value, minor_edits=1, resolutions=[]))
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'report-repair-content')

    def test_an_interrupted_changed_file_correction_resumes_after_a_heal(self):
        attempts = []
        def correction(value):
            attempts.append(value)
            if len(attempts) == 1:
                raise Blocked('provider-eof', 'Provider closed stdout without a terminal result.')
            return dict(value, minor_edits=1)
        self.unreported_edits(correction)
        with self.assertRaises(Blocked) as caught:
            self.step()
        pair = self.state['pair_review']
        self.cycle.handle_block(caught.exception)
        transport, self.cycle.transport = self.cycle.transport, fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()
        self.cycle.transport = transport
        self.assertIs(self.state['pair_review'], pair)  # The pair is not reset.
        self.step()
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(len(self.calls), 1)  # The executor work ran once.
        self.assertEqual(len({c[2]['id'] for c in self.corrections}), 1)  # The same correction resumed.

    def test_second_invalid_report_uses_normal_recovery(self):
        self.prepare(lambda value: value)  # The correction repeats the same inconsistency.
        with self.assertRaisesRegex(Blocked, 'substantial requires'):
            self.step()
        self.assertEqual(len(self.corrections), 1)

    def test_a_failed_correction_of_edited_work_lets_the_heal_review_the_candidate_again(self):
        for change, code in ((lambda value: value, 'invalid-report'),
                             (lambda value: dict(value, status='blocked', implementation_fixes=1), 'reported-blocker'),
                             (lambda value: dict(value, implementation_fixes=1, resolutions=[]), 'report-repair-content')):
            with self.subTest(code=code):
                self.tearDown()
                self.setUp()
                self.start('pair_a')
                pair = self.prepare(change)
                with self.assertRaises(Blocked) as caught:
                    self.step()
                self.assertEqual(caught.exception.code, code)
                self.cycle.handle_block(caught.exception)
                self.assertIsNone(self.cycle.saved_pair_execution(pair))  # The failed correction is not replayed.
                transport, self.cycle.transport = self.cycle.transport, fixtures.FixtureTransport(self.root, [('heal', report())])
                self.cycle.heal()
                self.cycle.transport = transport
                self.assertIsNot(self.state['pair_review'], pair)  # The stale pair was reset.
                self.assertEqual(self.state['phase'], 'pair_a')
                self.assertEqual((self.root / 'source.txt').read_text(), 'cleaned\n')  # Work is kept.


class RepairModeTests(unittest.TestCase):
    """A repair report that lists risks but keeps self mode, in a fix and in the direct final gate."""
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'until', 'assign', 'writer', 'set_writer', 'step',
                  'request_final_gate', 'gate_tests'):
        locals()[_name] = getattr(repair_tests.RepairTests, _name)
    correction_transport = accounting_tests.ExecutorAccountingTests.correction_transport

    def test_a_fix_with_risks_in_self_mode_gets_one_correction_and_pair_reviews(self):
        pair = self.assign('pair_b', 'low', False)
        execute = self.set_writer()
        def risky(c, h):
            value = execute(c, h)
            if c['operation'] == 'fix':
                value['repair'].update(mode='self', risks=['storage'])
            return value
        self.transport.handlers['repair_execute'] = risky
        self.correction_transport(lambda value: dict(value, repair=dict(value['repair'], mode='pair', reason='Storage change')))
        gate = pair['repair']
        self.step()
        self.assertIsNone(self.state['blocker'])
        self.assertEqual([role for role, _ in self.transport.calls].count('repair_execute'), 1)
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['repair-mode'])
        self.assertTrue(self.corrections[0][2]['report_repair']['changed_paths'])
        self.assertEqual((gate['mode'], gate['step'], gate['clean']), ('pair', 'review', 0))

    def test_a_direct_final_gate_with_a_pair_choice_publishes_without_reviews_or_another_run(self):
        from focus_pair_repair import TEST_RISKS
        self.request_final_gate()
        normal = self.transport.dispatch
        def dispatch(role, prompt, heartbeat):
            value = json.loads(normal(role, prompt, heartbeat))
            if role == 'repair_execute':
                value['repair'].update(mode='self', risks=['cross_component'])
            return json.dumps(value)
        self.transport.dispatch = dispatch
        self.correction_transport(lambda value: dict(value, repair=dict(value['repair'], mode='pair', reason='Cross-component stage')))
        self.until(lambda: self.state['phase'] == 'publish')
        self.assertIsNone(self.state['blocker'])
        self.assertEqual([r for r, c in self.transport.calls], ['pair_final_opus', 'pair_final_fable', 'repair_execute'])
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['repair-mode'])
        self.assertTrue(self.gate_tests()[0]['verification'].endswith(TEST_RISKS))


class RepairModeEvidenceTests(unittest.TestCase):
    """A test run that changed a journal, reported zero counters and listed risks in self mode."""
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'until', 'assign', 'writer', 'set_writer', 'step', 'audit'):
        locals()[_name] = getattr(evidence_tests.RepairEvidenceTests, _name)
    correction_transport = accounting_tests.ExecutorAccountingTests.correction_transport

    def journal_test_run(self, correction):
        pair = self.assign('pair_b', 'low', False)
        execute = self.set_writer()
        self.test_runs = 0
        def writer(context, heartbeat):
            value = execute(context, heartbeat)
            if context['operation'] == 'fix':
                (self.root / 'plan.md').write_text('# Plan\n\nImplementation requirements remain unchanged.\n')
            else:
                self.test_runs += 1
                with (self.root / 'plan.md').open('a') as out:
                    out.write('\n## Completed verification\nTargeted guard test passed.\n')
                value['minor_edits'] = 0
                value['repair'].update(mode='self', risks=['cross_component'])
                for row in value['resolutions']:
                    row.update(outcome='verified', evidence=['Targeted test verified the earlier fix'])
            return value
        self.transport.handlers['repair_execute'] = writer
        self.transport.handlers['repair_evidence'] = lambda c, h: self.audit(c)
        self.correction_transport(correction)
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        return gate

    def test_counted_journal_changes_reach_the_evidence_audit(self):
        gate = self.journal_test_run(lambda value: dict(value, minor_edits=1, repair=dict(
            value['repair'], mode='pair', reason='Cross-component checks')))
        self.until(lambda: gate['step'] != 'test')
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.test_runs, 1)
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['repair-mode'])
        self.assertIn('Also count these changes', self.corrections[0][1])
        self.assertIn('"changed_paths": ["plan.md"]', self.corrections[0][1])

    def test_uncounted_journal_changes_are_refused_and_not_replayed_after_a_heal(self):
        gate = self.journal_test_run(lambda value: dict(value, repair=dict(
            value['repair'], mode='pair', reason='Cross-component checks')))
        with self.assertRaises(Blocked) as caught:
            self.until(lambda: gate['step'] != 'test')
        self.assertEqual(caught.exception.code, 'report-repair-content')
        self.cycle.handle_block(caught.exception)
        transport, self.cycle.transport = self.cycle.transport, fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()
        self.cycle.transport = transport
        # The failed correction of changed work is not adopted again. The heal resets the stale pair.
        self.assertFalse((self.state['pair_review'] or {}).get('repair'))
        self.assertEqual((self.state['phase'], self.test_runs, len(self.corrections)), ('pair_a', 1, 1))


class CorrectedOriginalTests(unittest.TestCase):
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'assign', 'until', 'step', 'resolution', 'result'):
        locals()[_name] = getattr(execution_tests.PairExecutionTests, _name)
    correction_transport = accounting_tests.ExecutorAccountingTests.correction_transport

    def test_a_corrected_test_run_is_not_adopted_again_after_a_heal(self):
        pair = self.assign('pair_b', 'low', False)
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        normal = self.transport.dispatch
        self.test_runs = 0
        def dispatch(role, prompt, heartbeat):
            value = json.loads(normal(role, prompt, heartbeat))
            if role == 'repair_execute':
                self.test_runs += 1
                value['repair']['tests'] = {'status': 'infrastructure', 'reason': 'Tool missing',
                                            'evidence': ['tool not found'], 'failures': []}
                value.update(substantial=True, minor_edits=1)  # Counters need a correction.
            return json.dumps(value)
        self.transport.dispatch = dispatch
        self.correction_transport(lambda value: dict(value, substantial=False, minor_edits=0))
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'repair-test-infrastructure')
        original = Path(self.corrections[0][2]['report_repair']['source']).parent.name
        self.assertIn(original, gate['consumed_tests'])
        self.cycle.handle_block(caught.exception)
        transport, self.cycle.transport = self.cycle.transport, fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()  # The healer repairs the tool. The heal result replaces `last`.
        self.cycle.transport = transport
        with self.assertRaises(Blocked):
            self.step()
        self.assertEqual(self.test_runs, 2)  # The tests run again. The old result is not replayed.
        sources = [Path(c[2]['report_repair']['source']).parent.name for c in self.corrections]
        self.assertEqual(len(set(sources)), 2)


    def risky_self_test_run(self, correction, copied=None):
        """A late test run lists a risk but keeps self mode; the checks passed and no file changed."""
        pair = self.assign('pair_b', 'low', False)
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        normal = self.transport.dispatch
        def dispatch(role, prompt, heartbeat):
            value = json.loads(normal(role, prompt, heartbeat))
            if role == 'repair_execute' and value['repair']['tests']['status'] != 'deferred':
                value['repair'].update(mode='self', risks=['cross_component'])
                value.update(copied or {})
            return json.dumps(value)
        self.transport.dispatch = dispatch
        self.correction_transport(correction)
        return gate

    def test_risks_in_self_mode_get_one_correction_without_another_test_run(self):
        for name, choice, mode, step in (('risk removed', dict(risks=[]), 'self', 'complete'),
                                         ('pair chosen', dict(mode='pair', reason='Cross-component checks'), 'pair', 'review')):
            with self.subTest(name=name):
                self.tearDown()
                self.setUp()
                gate = self.risky_self_test_run(lambda value: dict(value, repair=dict(value['repair'], **choice)))
                test_runs = [role for role, _ in self.transport.calls].count('repair_execute')
                self.until(lambda: gate['step'] != 'test')
                self.assertIsNone(self.state['blocker'])
                self.assertEqual([role for role, _ in self.transport.calls].count('repair_execute'), test_runs + 1)
                self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['repair-mode'])
                prompt = self.corrections[0][1]
                self.assertIn('lists repair.risks but sets repair.mode=self', prompt)
                self.assertIn('Do not run tools, tests, builds', prompt)
                # A pair choice promotes the gate. Independent reviews then precede the checks again.
                self.assertEqual((gate['mode'], gate['step'], len(gate['tests'])), (mode, step, 1))

    def test_copied_counters_and_risks_in_self_mode_get_one_correction(self):
        for name, counters, blocked in (('counters reset', 0, None), ('counters kept', 1, 'report-repair-content')):
            with self.subTest(name=name):
                self.tearDown()
                self.setUp()
                # The unchanged test run also copies a counter of its fix batch.
                gate = self.risky_self_test_run(lambda value: dict(value, implementation_fixes=counters, repair=dict(
                    value['repair'], risks=[])), copied=dict(implementation_fixes=1))
                test_runs = [role for role, _ in self.transport.calls].count('repair_execute')
                if blocked:
                    with self.assertRaises(Blocked) as caught:
                        self.until(lambda: False)
                    self.assertEqual(caught.exception.code, blocked)
                    continue
                self.until(lambda: gate['step'] != 'test')
                self.assertIsNone(self.state['blocker'])
                self.assertEqual([role for role, _ in self.transport.calls].count('repair_execute'), test_runs + 1)
                self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['repair-mode'])
                self.assertIn('Also set all three counters to 0', self.corrections[0][1])

    def test_a_repair_mode_correction_cannot_change_test_results(self):
        self.risky_self_test_run(lambda value: dict(value, repair=dict(
            value['repair'], risks=[], tests=dict(value['repair']['tests'], evidence=['Invented check']))))
        with self.assertRaises(Blocked) as caught:
            self.until(lambda: False)
        self.assertEqual(caught.exception.code, 'report-repair-content')

    def test_a_risky_self_test_run_rejected_by_an_older_runtime_is_corrected_after_a_heal(self):
        gate = self.risky_self_test_run(lambda value: dict(value, repair=dict(value['repair'], risks=[])))
        with patch('cycle_workflow.repairable_repair_mode', return_value=None):  # Older runtime.
            with self.assertRaisesRegex(Blocked, 'require pair review') as caught:
                self.until(lambda: False)
        test_runs = [role for role, _ in self.transport.calls].count('repair_execute')
        self.cycle.handle_block(caught.exception)
        transport, self.cycle.transport = self.cycle.transport, fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()
        self.cycle.transport = transport
        self.until(lambda: gate['step'] != 'test')
        self.assertIsNone(self.state['blocker'])
        # The saved test run is corrected in its session. Its successful checks do not run again.
        self.assertEqual([role for role, _ in self.transport.calls].count('repair_execute'), test_runs)
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['repair-mode'])

    def test_a_failed_late_pair_correction_is_not_started_again_after_a_heal(self):
        pair = self.assign('pair_b', 'low', False)
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        normal = self.transport.dispatch
        self.transport.dispatch = lambda role, prompt, heartbeat: json.dumps(
            dict(json.loads(normal(role, prompt, heartbeat)), substantial=True))
        self.correction_transport(lambda value: dict(value, substantial=True))  # The correction fails too.
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(gate['test_invocation'], self.corrections[0][2]['id'])  # Discovery finds the correction.
        self.cycle.handle_block(caught.exception)
        transport, self.cycle.transport = self.cycle.transport, fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()
        self.cycle.transport = transport
        with self.assertRaises(Blocked):
            self.step()  # The unchanged test run replays the failed correction.
        self.assertEqual(len(self.corrections), 1)


    def unchanged_test_run(self, correction):
        """A late test run changes no files but reports substantial=true with a minor edit."""
        pair = self.assign('pair_b', 'low', False)
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        normal = self.transport.dispatch
        self.transport.dispatch = lambda role, prompt, heartbeat: json.dumps(
            dict(json.loads(normal(role, prompt, heartbeat)), substantial=True, minor_edits=1))
        self.correction_transport(correction)
        return gate

    def test_a_correction_of_unchanged_work_sets_every_counter_to_zero(self):
        for name, correction in (('added fix', lambda value: dict(value, implementation_fixes=1)),
                                 ('kept edit', lambda value: value)):  # The base correction keeps minor_edits=1.
            with self.subTest(name=name):
                self.tearDown()
                self.setUp()
                self.unchanged_test_run(correction)
                with self.assertRaises(Blocked) as caught:
                    self.step()
                self.assertEqual(caught.exception.code, 'report-repair-content')
                role, prompt, pending = self.corrections[0]
                self.assertEqual((pending['report_repair']['reason'], pending['report_repair']['changed_paths']),
                                 ('substantial-accounting', []))
                self.assertIn('The original invocation changed no files. Set all three counters to 0', prompt)
                self.assertNotIn('count it as an implementation fix', prompt)
        test_runs = [role for role, _ in self.transport.calls].count('repair_execute')
        self.cycle.handle_block(caught.exception)
        transport, self.cycle.transport = self.cycle.transport, fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()
        self.cycle.transport = transport
        with self.assertRaises(Blocked):
            self.step()  # The failed correction replays. The completed tests do not run again.
        self.assertEqual([role for role, _ in self.transport.calls].count('repair_execute'), test_runs)
        self.assertEqual(len(self.corrections), 1)

    def test_copied_counters_of_an_unchanged_test_run_get_one_correction(self):
        for copied in (dict(implementation_fixes=1, substantial=True), dict(other_fixes=1)):
            with self.subTest(copied=copied):
                self.tearDown()
                self.setUp()
                pair = self.assign('pair_b', 'low', False)
                gate = pair['repair']
                self.until(lambda: gate['step'] == 'test')
                normal = self.transport.dispatch
                def dispatch(role, prompt, heartbeat):
                    value = json.loads(normal(role, prompt, heartbeat))
                    return json.dumps(dict(value, **copied) if role == 'repair_execute' else value)
                self.transport.dispatch = dispatch  # The test run copies the counters of the fix batch.
                self.correction_transport(lambda value: dict(value, implementation_fixes=0, other_fixes=0, minor_edits=0))
                self.step()
                self.assertIsNone(self.state['blocker'])  # Not repair-test-edit.
                self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['unchanged-accounting'])
                self.assertIn('The original invocation changed no files. Set all three counters to 0', self.corrections[0][1])
                self.assertNotIn('Return blocked', self.corrections[0][1])  # No changed paths can mismatch.
                self.assertEqual(len(gate['tests']), 1)

    def test_a_zero_count_correction_of_unchanged_work_is_accepted(self):
        gate = self.unchanged_test_run(lambda value: dict(value, minor_edits=0))
        self.step()
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(len(self.corrections), 1)
        self.assertEqual(len(gate['tests']), 1)

    def test_a_test_run_with_fixes_lets_the_heal_review_the_candidate_again(self):
        for direct, correction in ((None, lambda value: dict(value, implementation_fixes=1, substantial=True)),
                                   (dict(implementation_fixes=1, substantial=True), None),
                                   (dict(other_fixes=1), None)):  # Fixes without substantial impact.
            with self.subTest(direct=direct, corrected=correction is not None):
                self.tearDown()
                self.setUp()
                (self.root / 'journal.md').write_text('Journal\n')
                pair = self.assign('pair_b', 'low', False)
                gate = pair['repair']
                self.until(lambda: gate['step'] == 'test')
                normal = self.transport.dispatch
                def dispatch(role, prompt, heartbeat):
                    value = json.loads(normal(role, prompt, heartbeat))
                    if role == 'repair_execute':
                        (self.root / 'journal.md').write_text('Journal\nTargeted check passed\n')
                        value.update(dict(minor_edits=0, implementation_fixes=0, other_fixes=0, substantial=False), **(direct or {}))
                    return json.dumps(value)
                self.transport.dispatch = dispatch
                self.correction_transport(correction)
                with self.assertRaises(Blocked) as caught:
                    self.step()
                self.assertEqual(caught.exception.code, 'repair-test-edit')
                self.cycle.handle_block(caught.exception)
                transport, self.cycle.transport = self.cycle.transport, fixtures.FixtureTransport(self.root, [('heal', report())])
                self.cycle.heal()
                self.cycle.transport = transport
                # Tests changed the candidate, so the pair reviews it again instead of replaying the result.
                self.assertIsNot(self.state['pair_review'], pair)
                self.assertEqual(self.state['phase'], 'pair_a')
                self.assertEqual(len(self.corrections), 1 if correction else 0)


    def test_a_test_run_that_edits_more_than_documentation_is_not_replayed(self):
        for target, interrupted in (('module.py', False), ('notes/evidence.md', False), ('module.py', True)):
            # An existing source file or a new file. The correction can also stop before its result.
            with self.subTest(target=target, interrupted=interrupted):
                self.tearDown()
                self.setUp()
                (self.root / 'module.py').write_text('VALUE = 1\n')
                pair = self.assign('pair_b', 'low', False)
                gate = pair['repair']
                self.until(lambda: gate['step'] == 'test')
                normal = self.transport.dispatch
                def dispatch(role, prompt, heartbeat):
                    value = json.loads(normal(role, prompt, heartbeat))
                    if role == 'repair_execute':
                        (self.root / target).parent.mkdir(parents=True, exist_ok=True)
                        (self.root / target).write_text('written during tests\n')
                        value.update(minor_edits=0, implementation_fixes=0, other_fixes=0, substantial=False)
                    return json.dumps(value)
                self.transport.dispatch = dispatch
                def correction(value):
                    if interrupted:
                        raise Blocked('provider-eof', 'Provider closed stdout without a terminal result.')
                    return dict(value, minor_edits=1)
                self.correction_transport(correction)
                with self.assertRaises(Blocked) as caught:
                    self.step()  # The correction is accepted, but no evidence audit can accept the edit.
                self.assertEqual(caught.exception.code, 'provider-eof' if interrupted else 'repair-test-edit')
                self.cycle.handle_block(caught.exception)
                transport, self.cycle.transport = self.cycle.transport, fixtures.FixtureTransport(self.root, [('heal', report())])
                self.cycle.heal()
                self.cycle.transport = transport
                self.assertIsNot(self.state['pair_review'], pair)  # The stale pair was reset.
                self.assertEqual(self.state['phase'], 'pair_a')


class StorageRetryTests(unittest.TestCase):
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'until', 'assign', 'writer', 'set_writer', 'step'):
        locals()[_name] = getattr(repair_tests.RepairTests, _name)

    def test_a_corrected_infrastructure_result_still_retries_after_storage_repair(self):
        archives.SnapshotArchiveTests.view(self, legacy=True)
        pair = self.assign('final', 'low', False, action='verify')
        self.set_writer()
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        obstacle = dict(finding('workspace-copy'), kind='verification')
        def failed(c, h):
            result = self.writer(c, status='infrastructure', failures=[obstacle], substantial=True)
            result['resolutions'][0]['outcome'] = 'deferred'
            return result
        self.transport.handlers['repair_execute'] = failed
        # An older runtime saved and rejected this result before the storage repair.
        with patch('cycle_workflow.parse_report', side_effect=Blocked('invalid-report', 'old infrastructure schema')), \
                patch('cycle_workflow.repairable_executor_accounting', return_value=None), \
                patch('cycle_workflow.repairable_substantial_accounting', return_value=None):
            with self.assertRaisesRegex(Blocked, 'old infrastructure schema'):
                self.cycle.invoke('repair_execute')
        self.state['pending'] = None
        self.cycle.prepare_snapshot_storage()
        normal, corrections = self.transport.run, []
        def run(role, prompt, pending, directory):
            if not pending.get('report_repair'):
                return normal(role, prompt, pending, directory)
            corrections.append(pending['id'])
            original = json.loads(json.loads(Path(pending['report_repair']['source']).read_text())['raw'])
            return json.dumps(dict(original, substantial=False))
        self.transport.run = run
        self.step()  # The correction starts later, but the tests ran before the storage repair.
        self.assertEqual(len(corrections), 1)
        self.assertTrue(gate.get('storage_retry'))


class PairAConsumptionTests(unittest.TestCase):
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'assign', 'until', 'step', 'prepare', 'resolution', 'result'):
        locals()[_name] = getattr(execution_tests.PairExecutionTests, _name)
    correction_transport = accounting_tests.ExecutorAccountingTests.correction_transport
    verification = accounting_tests.ExecutorAccountingTests.verification

    def test_an_accepted_executor_result_verifies_a_recovery(self):
        self.prepare()
        self.state['recovery_unverified'] = True
        before = self.cycle.accepted_pair_results()
        self.cycle.pair_step()  # Only the executor runs. Its report is accepted.
        after = self.cycle.accepted_pair_results()
        self.assertEqual((after[0], after[1]), (before[0], before[1] + 1))
        self.assertFalse(self.state['recovery_unverified'])

    def test_a_corrected_continuation_is_not_adopted_again_after_a_heal(self):
        pair = self.verification()  # The fix is accepted. The check remains.
        self.transport.handlers[self.role] = lambda c, h: self.result([self.resolution('check', 'deferred')],
                                                                      substantial=True)
        self.step()  # The unchanged continuation gets one accepted correction.
        original = Path(self.corrections[-1][2]['report_repair']['source']).parent.name
        self.assertIn(original, pair['execution']['consumed'])
        self.cycle.handle_block(Blocked('fixture', 'Unrelated blocker before the next continuation'))
        transport, self.cycle.transport = self.cycle.transport, fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()
        self.cycle.transport = transport
        self.assertIsNone(self.cycle.saved_pair_execution(pair))


class RecoveryVerificationTests(unittest.TestCase):
    setUp = pairs.PairTests.setUp
    tearDown = pairs.PairTests.tearDown
    edit = pairs.PairTests.edit
    start = pairs.PairTests.start

    def test_accepted_pair_work_verifies_a_recovery(self):
        self.start('pair_a')
        self.state['recovery_unverified'] = True
        self.cycle.pair_step()  # Both readers complete and their reports are accepted.
        self.assertFalse(self.state['recovery_unverified'])

    def test_a_failed_pair_step_keeps_the_recovery_unverified(self):
        self.start('pair_a')
        self.state['recovery_unverified'] = True
        self.transport.handlers['pair_sol'] = lambda c, h: (_ for _ in ()).throw(Blocked('fixture', 'Reader failed'))
        with self.assertRaises(Blocked):
            self.cycle.pair_step()
        self.assertTrue(self.state['recovery_unverified'])
        self.assertTrue(self.cycle.accepted_pair_results()[0] <= 1)

    def test_a_rejected_reader_result_does_not_verify_a_recovery(self):
        self.start('pair_a')
        self.cycle.pair_step()  # Both readers are accepted.
        self.state['recovery_unverified'] = True
        def reject():
            job = next(j for j in self.state['pair_review']['jobs'].values() if j.get('result'))
            job.pop('result')  # The runtime removes a rejected report.
        with patch.object(self.cycle, 'paired_review_step', side_effect=reject):
            self.cycle.pair_step()
        self.assertTrue(self.state['recovery_unverified'])

    def test_recovery_still_escalates_without_progress(self):
        self.start('pair_a')
        self.state['recovery_unverified'] = True
        with patch.object(self.cycle, 'paired_review_step', return_value=None):
            self.cycle.pair_step()  # The step returns normally but accepts no provider result.
        self.assertTrue(self.state['recovery_unverified'])
        self.cycle.handle_block(Blocked('fixture', 'Same failure after recovery'))
        self.assertEqual(self.state['blocker']['escalation_reason'], 'verification-failed')


class ReportEnumTests(unittest.TestCase):
    """A writer report whose only invalid values are outside their allowed values, as a Claude writer can give."""
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'until', 'assign', 'writer', 'set_writer', 'step'):
        locals()[_name] = getattr(repair_tests.RepairTests, _name)
    correction_transport = accounting_tests.ExecutorAccountingTests.correction_transport

    def descriptive_fix(self, correction):
        """A pair-mode fix that describes its risks in words instead of allowed values."""
        pair = self.assign('pair_b', 'low', False)
        execute = self.set_writer('pair')
        def writer(c, h):
            value = execute(c, h)
            if c['operation'] == 'fix':
                value['repair']['risks'] = ['contracts', 'core algorithms', 'uncertainty: new fixtures are uncompiled']
            return value
        self.transport.handlers['repair_execute'] = writer
        self.correction_transport(correction)
        return pair['repair']

    def allowed(self, value):
        return dict(value, repair=dict(value['repair'], risks=['contracts', 'algorithm', 'uncertainty']))

    def test_the_recognizer_names_only_values_outside_their_allowed_values(self):
        from cycle_transport import enum_problems, field_name
        context = {'operation': 'fix', 'assignments': [{'source_id': 'p/pair_sol/f1', 'action': 'fix'}]}
        value = self.writer(context, 'pair')
        value['repair']['risks'] = ['contracts', 'core algorithms']
        value['resolutions'][0]['outcome'] = 'done'
        found = enum_problems(json.dumps(value), 'repair_execute')
        self.assertEqual([(field_name(p['path']), p['value']) for p in found[1]],
                         [('resolutions[0].outcome', 'done'), ('repair.risks[1]', 'core algorithms')])
        self.assertIn('algorithm', found[1][1]['allowed'])
        self.assertIsNone(enum_problems(json.dumps(dict(value, summary=' ')), 'repair_execute'))  # Another error.
        self.assertIsNone(enum_problems(json.dumps(dict(value, status='blocked')), 'repair_execute'))
        self.assertIsNone(enum_problems(json.dumps(value), 'code'))
        value['resolutions'][0]['outcome'] = 'fixed'
        value['repair']['risks'] = ['contracts']
        self.assertIsNone(enum_problems(json.dumps(value), 'repair_execute'))  # A valid report has no problem.
        # Mistakes that need another allowed value, a removal, or the other mode are recognized too.
        selfish = self.writer(context, 'self')
        for repair in ({'risks': ['none']}, {'risks': ['core algorithms', 'contracts']},
                       {'mode': 'pair review', 'risks': ['contracts']}):
            with self.subTest(repair=repair):
                self.assertIsNotNone(enum_problems(json.dumps(dict(selfish, repair=dict(selfish['repair'], **repair))),
                                                   'repair_execute'))

    def test_a_fix_with_descriptive_risks_gets_one_value_correction_in_its_session(self):
        gate = self.descriptive_fix(self.allowed)
        self.step()
        self.assertIsNone(self.state['blocker'])
        self.assertEqual([role for role, _ in self.transport.calls].count('repair_execute'), 1)
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['report-enum'])
        prompt = self.corrections[0][1]
        self.assertIn('values outside their allowed values', prompt)
        self.assertIn('"field": "repair.risks[1]"', prompt)
        self.assertIn('"value": "core algorithms"', prompt)
        self.assertIn('Do not run tools, tests, builds', prompt)
        self.assertEqual(gate['step'], 'review')
        corrected = json.loads(Path(self.state['last']['report']).read_text())
        self.assertEqual(parse_report(corrected['raw'], 'repair_execute')['repair']['risks'], ['contracts', 'algorithm', 'uncertainty'])

    def test_descriptive_risks_in_self_mode_can_also_change_the_mode(self):
        pair = self.assign('pair_b', 'low', False)
        execute = self.set_writer('self')
        def writer(c, h):
            value = execute(c, h)
            if c['operation'] == 'fix':
                value['repair']['risks'] = ['core algorithms']
            return value
        self.transport.handlers['repair_execute'] = writer
        self.correction_transport(lambda value: dict(value, repair=dict(
            value['repair'], risks=['algorithm'], mode='pair', reason='Algorithm change')))
        self.step()
        self.assertIsNone(self.state['blocker'])
        prompt = self.corrections[0][1]
        self.assertIn('Also set repair.mode and repair.reason to match the risks', prompt)
        self.assertEqual((pair['repair']['mode'], pair['repair']['step']), ('pair', 'review'))

    def test_a_value_correction_cannot_lower_pair_mode(self):
        self.descriptive_fix(lambda value: dict(value, repair=dict(value['repair'], risks=[], mode='self', reason='Local')))
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'report-repair-content')
        self.assertIn('Keep repair.mode=pair', self.corrections[0][1])

    def test_the_prompt_keeps_only_fields_that_are_not_listed(self):
        self.descriptive_fix(lambda value: dict(self.allowed(value), resolutions=[
            dict(row, outcome='fixed') for row in value['resolutions']]))
        writer = self.transport.handlers['repair_execute']
        def wrong_outcome(c, h):
            value = writer(c, h)
            if c['operation'] == 'fix':
                for row in value['resolutions']:
                    row['outcome'] = 'done'
            return value
        self.transport.handlers['repair_execute'] = wrong_outcome
        self.step()
        self.assertIsNone(self.state['blocker'])
        prompt = self.corrections[0][1]
        self.assertIn('"field": "resolutions[0].outcome"', prompt)
        keep = prompt.split('Keep every other field exactly', 1)[1].split('.', 1)[0]
        self.assertIn('evidence', keep)
        self.assertNotIn('resolutions', keep)

    def test_a_value_correction_cannot_change_other_fields(self):
        changes = (lambda value: dict(self.allowed(value), implementation_fixes=2),
                   lambda value: dict(self.allowed(value), repair=dict(self.allowed(value)['repair'], tests=dict(
                       value['repair']['tests'], reason='Another reason'))),
                   lambda value: dict(self.allowed(value), resolutions=[dict(row, resolution='Changed') for row in value['resolutions']]))
        for change in changes:
            with self.subTest(change=change):
                self.tearDown()
                self.setUp()
                self.descriptive_fix(change)
                with self.assertRaises(Blocked) as caught:
                    self.step()
                self.assertEqual(caught.exception.code, 'report-repair-content')
                self.assertEqual(len(self.corrections), 1)

    def test_a_fix_rejected_by_an_older_runtime_is_corrected_after_a_retry(self):
        gate = self.descriptive_fix(self.allowed)
        with patch('cycle_workflow.repairable_enum', return_value=None):  # The runtime that stopped the live stage.
            with self.assertRaisesRegex(Blocked, 'invalid finding enum') as caught:
                self.step()
        self.cycle.handle_block(caught.exception)
        # cc-focus --retry clears the blocker. The step then finds the saved run instead of a drift stop.
        self.state.update(blocker=None, pending=None, status='ready')
        self.step()
        self.assertIsNone(self.state['blocker'])
        self.assertEqual([role for role, _ in self.transport.calls].count('repair_execute'), 1)  # No second run.
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['report-enum'])
        self.assertEqual(gate['step'], 'review')

    def test_a_retry_after_another_saved_report_runs_the_executor_again(self):
        pair = self.assign('pair_b', 'low', False)
        execute = self.set_writer('pair')
        runs = []
        def writer(c, h):
            runs.append(c['operation'])
            if len(runs) == 1:
                return dict(self.writer(c, 'pair'), status='blocked')  # The blocked run changed nothing.
            return execute(c, h)
        self.transport.handlers['repair_execute'] = writer
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'reported-blocker')
        self.cycle.handle_block(caught.exception)
        self.state.update(blocker=None, pending=None, status='ready')
        self.assertIsNone(self.cycle.saved_repair_fix(pair))  # A blocked report is not replayed.
        self.step()
        self.assertEqual(runs, ['fix', 'fix'])
        self.assertEqual(pair['repair']['step'], 'review')



class DeferredFixTests(unittest.TestCase):
    """A B/final fix invocation returns a fix assignment deferred, as an assignment that waits for checks can ask."""
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'until', 'assign', 'writer', 'set_writer', 'step'):
        locals()[_name] = getattr(repair_tests.RepairTests, _name)
    correction_transport = accounting_tests.ExecutorAccountingTests.correction_transport

    def deferred_fix(self, correction, mode='self'):
        """The executor does the static part and defers the fix, as the assignment told it."""
        pair = self.assign('pair_b', 'low', False)
        execute = self.set_writer(mode)
        self.runs = []
        def writer(c, h):
            value = execute(c, h)
            self.runs.append(c['operation'])
            if c['operation'] == 'fix':
                for row in value['resolutions']:
                    row.update(outcome='deferred', resolution='Static part done. The check results come only from the test invocation.')
            return value
        self.transport.handlers['repair_execute'] = writer
        self.correction_transport(correction)
        return pair['repair']

    def outcome(self, outcome, resolution='Static part done. Recording the check results needs the test invocation; split it.'):
        return lambda value: dict(value, resolutions=[dict(row, outcome=outcome, resolution=resolution) for row in value['resolutions']])

    def test_a_deferred_fix_is_disputed_by_one_correction_and_goes_to_the_readers(self):
        gate = self.deferred_fix(self.outcome('disputed'))
        self.step()
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.runs, ['fix'])  # The correction does not run the executor again.
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['deferred-fix'])
        prompt = self.corrections[0][1]
        self.assertIn('a fix assignment closes as fixed or disputed', prompt)
        self.assertIn('"deferred_fix_assignments": ["assigned"]', prompt)
        self.assertIn('did all of the assignment except the "Later work:" part of its check field, return fixed.', prompt)
        self.assertIn('Do not run tools, tests, builds', prompt)
        # A disputed repair needs independent readers, who decide again with the arbiter.
        self.assertEqual((gate['mode'], gate['step']), ('pair', 'review'))
        self.assertEqual(gate['resolutions']['assigned']['outcome'], 'disputed')

    def test_a_fix_that_was_complete_continues_as_fixed_with_independent_readers(self):
        gate = self.deferred_fix(self.outcome('fixed', 'Every part of the assignment is done.'))
        self.step()
        self.assertIsNone(self.state['blocker'])
        # The executor deferred the fix first, so its own session does not review the claim.
        self.assertEqual((gate['mode'], gate['step']), ('pair', 'review'))
        self.assertEqual(gate['reason'], 'A corrected deferred fix requires independent reviewers')
        self.assertEqual(gate['resolutions']['assigned']['outcome'], 'fixed')

    def test_the_final_pair_and_a_pair_mode_report_get_the_same_correction(self):
        for phase, mode in (('final', 'self'), ('pair_b', 'pair')):
            with self.subTest(phase=phase, mode=mode):
                self.tearDown()
                self.setUp()
                pair = self.assign(phase, 'low', False)
                execute = self.set_writer(mode)
                def writer(c, h):
                    value = execute(c, h)
                    if c['operation'] == 'fix':
                        for row in value['resolutions']:
                            row['outcome'] = 'deferred'
                    return value
                self.transport.handlers['repair_execute'] = writer
                self.correction_transport(self.outcome('disputed'))
                self.step()
                self.assertIsNone(self.state['blocker'])
                self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['deferred-fix'])
                self.assertEqual((pair['repair']['mode'], pair['repair']['step']), ('pair', 'review'))

    def test_a_correction_that_returns_blocked_uses_normal_recovery(self):
        self.deferred_fix(lambda value: dict(value, status='blocked', summary='Cannot decide the outcome.'))
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'reported-blocker')
        self.assertEqual(len(self.corrections), 1)

    def test_the_fix_step_asks_for_fixed_or_disputed(self):
        self.deferred_fix(self.outcome('disputed'))
        prompts = []
        normal = self.transport.run
        def run(role, prompt, pending, directory):
            if not pending.get('report_repair'):
                prompts.append(prompt)
            return normal(role, prompt, pending, directory)
        self.transport.run = run
        self.step()
        self.assertIn('Return each fix assignment fixed or disputed. If a part of it waits for check results, '
                      'return disputed and name that part.', prompts[0])
        # The fix step does not dispute a part that the assignment names as later work.
        self.assertIn('A part of the check field after the label \\"Later work:\\" follows the tests. Do not do it, and do not return '
                      'disputed for it. Name it in your resolution after the same label.', prompts[0])

    def test_the_correction_may_change_only_the_listed_outcomes_and_their_text(self):
        changes = (lambda value: dict(self.outcome('disputed')(value), implementation_fixes=3),
                   lambda value: dict(self.outcome('disputed')(value), resolutions=[
                       dict(row, outcome='disputed', evidence=['Invented evidence']) for row in value['resolutions']]),
                   lambda value: dict(self.outcome('disputed')(value), repair=dict(value['repair'], mode='pair')),
                   self.outcome('deferred'))
        for change in changes:
            with self.subTest(change=change):
                self.tearDown()
                self.setUp()
                self.deferred_fix(change)
                with self.assertRaises(Blocked) as caught:
                    self.step()
                self.assertEqual(caught.exception.code, 'report-repair-content')
                self.assertEqual(len(self.corrections), 1)

    def test_a_deferred_fix_stopped_by_an_older_runtime_is_corrected_after_a_retry(self):
        gate = self.deferred_fix(self.outcome('disputed'))
        with patch('focus_pair_repair.deferred_fixes', return_value=[]):  # The runtime that stopped the live campaign.
            with self.assertRaises(Blocked) as caught:
                self.step()
        self.assertEqual(caught.exception.code, 'repair-closure')
        self.cycle.handle_block(caught.exception)
        # cc-focus --retry clears the blocker. The step adopts the saved run instead of running the executor again.
        self.state.update(blocker=None, pending=None, status='ready')
        self.step()
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.runs, ['fix'])
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['deferred-fix'])
        self.assertEqual((gate['mode'], gate['step']), ('pair', 'review'))

    def test_a_blocked_report_with_deferred_fixes_runs_the_executor_again_after_a_retry(self):
        pair = self.assign('pair_b', 'low', False)
        execute = self.set_writer('self')
        runs = []
        def writer(c, h):
            runs.append(c['operation'])
            if len(runs) == 1:  # The first run meets an obstacle, changes nothing, and defers its fix.
                value = self.writer(c, 'self')
                for row in value['resolutions']:
                    row['outcome'] = 'deferred'
                return dict(value, status='blocked')
            return execute(c, h)
        self.transport.handlers['repair_execute'] = writer
        self.correction_transport()
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'reported-blocker')
        self.cycle.handle_block(caught.exception)
        self.state.update(blocker=None, pending=None, status='ready')
        self.assertIsNone(self.cycle.saved_repair_fix(pair))  # A blocked report is not replayed.
        self.step()
        self.assertEqual(runs, ['fix', 'fix'])
        self.assertEqual(self.corrections, [])
        self.assertEqual(pair['repair']['step'], 'review')

    def chained(self):
        """A fix that defers its assignment and also lists a risk in self mode: two report-only corrections."""
        pair = self.assign('pair_b', 'low', False)
        execute = self.set_writer('self')
        self.runs = []
        def writer(c, h):
            value = execute(c, h)
            self.runs.append(c['operation'])
            if c['operation'] == 'fix':
                value['repair']['risks'] = ['contracts']  # Self mode with a risk needs a repair-mode correction.
                for row in value['resolutions']:
                    row['outcome'] = 'deferred'
            return value
        self.transport.handlers['repair_execute'] = writer
        def correction(value):
            if self.corrections[-1][2]['report_repair']['reason'] == 'repair-mode':
                return dict(value, repair=dict(value['repair'], mode='pair', reason='Contract change'))
            return self.outcome('disputed')(value)
        self.correction_transport(correction)
        return pair['repair']

    def test_a_deferred_fix_correction_follows_another_report_correction(self):
        gate = self.chained()
        self.step()
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.runs, ['fix'])
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['repair-mode', 'deferred-fix'])
        self.assertEqual((gate['mode'], gate['step']), ('pair', 'review'))
        self.assertEqual(gate['resolutions']['assigned']['outcome'], 'disputed')

    def test_a_chained_stop_by_an_older_runtime_is_corrected_after_a_retry(self):
        gate = self.chained()
        with patch('focus_pair_repair.deferred_fixes', return_value=[]):  # The older runtime stops after repair-mode.
            with self.assertRaises(Blocked) as caught:
                self.step()
        self.assertEqual(caught.exception.code, 'repair-closure')
        self.cycle.handle_block(caught.exception)
        self.state.update(blocker=None, pending=None, status='ready')
        self.step()
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.runs, ['fix'])
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['repair-mode', 'deferred-fix'])
        self.assertEqual((gate['mode'], gate['step']), ('pair', 'review'))

    def test_a_rejected_earlier_correction_does_not_replay_after_a_retry(self):
        pair = self.assign('pair_b', 'low', False)
        execute = self.set_writer('self')
        runs = []
        def writer(c, h):
            runs.append(c['operation'])
            if len(runs) == 1:  # No edits, a copied substantial flag, and a deferred fix.
                value = self.writer(c, 'self', substantial=True)
                for row in value['resolutions']:
                    row['outcome'] = 'deferred'
                return value
            return execute(c, h)
        self.transport.handlers['repair_execute'] = writer
        # The invocation-accounting correction changes evidence, which the runtime rejects.
        self.correction_transport(lambda value: dict(value, resolutions=[
            dict(row, evidence=['Invented evidence']) for row in value['resolutions']]))
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'report-repair-content')
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['invocation-accounting'])
        self.cycle.handle_block(caught.exception)
        self.state.update(blocker=None, pending=None, status='ready')
        self.assertIsNone(self.cycle.saved_repair_fix(pair))
        self.step()
        self.assertEqual(runs, ['fix', 'fix'])  # The retry runs the executor again.
        self.assertEqual(pair['repair']['step'], 'review')

    def test_a_correction_that_stopped_before_its_result_resumes_after_a_retry(self):
        failures = []
        def correction(value):
            if not failures:  # The provider fails once during the correction.
                failures.append(1)
                raise Blocked('claude-transient', 'Provider failed during the correction.')
            return self.outcome('disputed')(value)
        gate = self.deferred_fix(correction)
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'claude-transient')
        self.cycle.handle_block(caught.exception)
        self.state.update(blocker=None, pending=None, status='ready')
        self.step()  # The unfinished correction resumes; the changed files do not stop it as drift.
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.runs, ['fix'])
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['deferred-fix', 'deferred-fix'])
        self.assertEqual(self.corrections[0][2]['id'], self.corrections[1][2]['id'])  # The same correction.
        self.assertEqual((gate['mode'], gate['step']), ('pair', 'review'))

    def test_other_closure_problems_still_stop_without_a_correction(self):
        from focus_repair_evidence import deferred_fixes
        tasks = [{'source_id': 'f', 'action': 'fix'}, {'source_id': 'v', 'action': 'verify'}]
        def value(fix, verify, status='deferred', report_status='done'):
            return {'status': report_status, 'resolutions': [{'source_id': 'f', 'outcome': fix}, {'source_id': 'v', 'outcome': verify}],
                    'repair': {'tests': {'status': status}}}
        self.assertEqual(deferred_fixes(tasks, value('deferred', 'deferred')), ['f'])
        for fix, verify, status in (('fixed', 'deferred', 'deferred'), ('deferred', 'verified', 'deferred'),
                                    ('deferred', 'deferred', 'passed'), ('done', 'deferred', 'deferred')):
            with self.subTest(fix=fix, verify=verify, status=status):
                self.assertEqual(deferred_fixes(tasks, value(fix, verify, status)), [])
        self.assertEqual(deferred_fixes(tasks[:1], value('deferred', 'deferred')), [])  # An extra resolution.
        self.assertEqual(deferred_fixes(tasks, value('deferred', 'deferred', report_status='blocked')), [])
        # A verified outcome in the fix step is another problem: the runtime stops without a correction.
        pair = self.assign('pair_b', 'low', False, action='verify')
        execute = self.set_writer('self')
        def writer(c, h):
            value = execute(c, h)
            for row in value['resolutions']:
                row['outcome'] = 'verified'
            return value
        self.transport.handlers['repair_execute'] = writer
        self.correction_transport()
        with self.assertRaises(Blocked) as caught:
            self.step()
        self.assertEqual(caught.exception.code, 'repair-closure')
        self.assertEqual(self.corrections, [])

    def test_only_the_authors_of_repair_assignments_get_the_rule(self):
        from cycle_prompts import REPAIR_ASSIGNMENT_CONTRACT
        from focus_pair_profile import PAIR_DISCUSSERS
        for role in PROFILES:
            with self.subTest(role=role):
                self.assertEqual(REPAIR_ASSIGNMENT_CONTRACT in role_contract(role), role in PAIR_DISCUSSERS or role == 'pair_arbiter')
        self.assertNotIn(REPAIR_ASSIGNMENT_CONTRACT, PAIR_CONTRACT)  # Saved pair prompts keep their contract.
        self.assertIn('In a fix assignment, do not tell the executor to wait for check results or to return deferred.', REPAIR_ASSIGNMENT_CONTRACT)


class DeferredTestTests(unittest.TestCase):
    """A passed B/final test report leaves an assignment deferred for later work, as an assignment can ask."""
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'until', 'assign', 'writer', 'set_writer', 'step'):
        locals()[_name] = getattr(repair_tests.RepairTests, _name)
    correction_transport = accounting_tests.ExecutorAccountingTests.correction_transport

    def deferred_test(self, correction, repeat=True):
        # A medium finding repeats the outer pair after the gate. A low one only cleans up, without a repeat.
        pair = self.assign('pair_b', 'medium' if repeat else 'low', False)
        execute = self.set_writer('self')
        self.runs = []
        def writer(c, h):
            value = execute(c, h)
            self.runs.append(c['operation'])
            if c['operation'] == 'test':
                for row in value['resolutions']:
                    row.update(outcome='deferred', resolution='Checks passed. Later work: record the results in the plan.')
            return value
        self.transport.handlers['repair_execute'] = writer
        self.correction_transport(correction)
        return pair

    def closed(self, outcome='verified'):
        return lambda value: dict(value, resolutions=[dict(row, outcome=outcome, resolution=(
            'Checks passed. Later work for the outer pair: record the results in the plan.')) for row in value['resolutions']])

    def test_passed_tests_close_a_deferred_assignment_and_the_outer_pair_gets_its_later_work(self):
        pair = self.deferred_test(self.closed())
        self.until(lambda: pair.get('repair', {}).get('step') == 'test')
        self.assertTrue(pair['repair']['repeat_outer'])
        self.until(lambda: self.state.get('pair_review') is None)
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.runs.count('test'), 1)  # The correction does not run the checks again.
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['deferred-test'])
        prompt = self.corrections[0][1]
        self.assertIn('Its checks passed, so this report must close every assignment.', prompt)
        self.assertIn('"deferred_assignments": ["assigned"]', prompt)
        carried = {row['source_id']: row for row in self.state['pair_carry']}
        self.assertIn('Later work for the outer pair', carried['assigned']['resolution']['resolution'])
        self.assertEqual(carried['assigned']['resolution']['outcome'], 'fixed')  # verified confirms the earlier fix.

    def test_without_an_outer_repeat_the_gate_still_stops(self):
        self.deferred_test(self.closed(), repeat=False)
        prompts = []
        normal = self.transport.run
        def run(role, prompt, pending, directory):
            if role == 'repair_execute' and not pending.get('report_repair'):
                prompts.append(prompt)
            return normal(role, prompt, pending, directory)
        self.transport.run = run
        with self.assertRaises(Blocked) as caught:
            self.until(lambda: False)
        self.assertEqual(caught.exception.code, 'repair-closure')
        self.assertEqual(self.corrections, [])  # Later work would be lost, so the runtime does not correct.
        # The test step tells the executor to keep later work deferred, so the stop stays visible.
        test_prompt = next(p for p in prompts if '"operation": "test"' in p)
        self.assertIn('This gate cannot pass later work to the outer pair.', test_prompt)
        self.assertNotIn('When all checks pass, close every assignment', test_prompt)

    def test_the_final_pair_gets_the_same_correction(self):
        pair = self.assign('final', 'medium', False)
        execute = self.set_writer('self')
        def writer(c, h):
            value = execute(c, h)
            if c['operation'] == 'test':
                for row in value['resolutions']:
                    row['outcome'] = 'deferred'
            return value
        self.transport.handlers['repair_execute'] = writer
        self.correction_transport(self.closed())
        self.until(lambda: self.state.get('pair_review') is None)
        self.assertIsNone(self.state['blocker'])
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['deferred-test'])
        self.assertIn('Later work for the outer pair', self.state['pair_carry'][0]['resolution']['resolution'])

    def test_an_interrupted_test_correction_resumes_after_a_retry(self):
        failures = []
        def correction(value):
            if not failures:
                failures.append(1)
                raise Blocked('claude-transient', 'Provider failed during the correction.')
            return self.closed()(value)
        self.deferred_test(correction)
        with self.assertRaises(Blocked) as caught:
            self.until(lambda: False)
        self.assertEqual(caught.exception.code, 'claude-transient')
        self.cycle.handle_block(caught.exception)
        self.state.update(blocker=None, pending=None, status='ready')
        self.until(lambda: self.state.get('pair_review') is None)
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.runs.count('test'), 1)
        self.assertEqual([c[2]['id'] for c in self.corrections][0], [c[2]['id'] for c in self.corrections][1])

    def test_the_correction_may_only_close_the_listed_assignments(self):
        # A fix row closes as verified, so the runtime checks its earlier fixed record.
        changes = (self.closed('disputed'), self.closed('deferred'), self.closed('fixed'),
                   lambda value: dict(self.closed()(value), repair=dict(value['repair'], tests=dict(
                       value['repair']['tests'], reason='Another reason'))),
                   lambda value: dict(self.closed()(value), implementation_fixes=1))
        for change in changes:
            with self.subTest(change=change):
                self.tearDown()
                self.setUp()
                self.deferred_test(change)
                with self.assertRaises(Blocked) as caught:
                    self.until(lambda: False)
                self.assertEqual(caught.exception.code, 'report-repair-content')
                self.assertEqual(len(self.corrections), 1)

    def test_a_verify_assignment_closes_only_as_verified(self):
        self.assign('pair_b', 'medium', False, action='verify')
        execute = self.set_writer('self')
        def writer(c, h):
            value = execute(c, h)
            if c['operation'] == 'test':
                for row in value['resolutions']:
                    row['outcome'] = 'deferred'
            return value
        self.transport.handlers['repair_execute'] = writer
        self.correction_transport(self.closed('fixed'))
        with self.assertRaises(Blocked) as caught:
            self.until(lambda: False)
        self.assertEqual(caught.exception.code, 'report-repair-content')

    def test_a_test_stop_by_an_older_runtime_is_corrected_after_a_retry_without_new_checks(self):
        pair = self.deferred_test(self.closed())
        with patch.object(type(self.cycle), 'carries_later_work', return_value=False):  # The runtime that stopped.
            with self.assertRaises(Blocked) as caught:
                self.until(lambda: False)
        self.assertEqual(caught.exception.code, 'repair-closure')
        self.cycle.handle_block(caught.exception)
        self.state.update(blocker=None, pending=None, status='ready')
        self.until(lambda: self.state.get('pair_review') is None)
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.runs.count('test'), 1)  # The saved test result is replayed, not run again.
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['deferred-test'])

    def test_the_test_step_and_the_assignment_rule_name_later_work(self):
        from cycle_prompts import REPAIR_ASSIGNMENT_CONTRACT
        self.assertIn('Do not write an assignment that plans a fix after its own tests.', REPAIR_ASSIGNMENT_CONTRACT)
        self.assertIn('Write it after the label "Later work:" in the check field of the assignment that names those checks.',
                      REPAIR_ASSIGNMENT_CONTRACT)
        self.assertIn('An assignment with later work makes the outer pair repeat after its gate, also after minor-only corrections.',
                      REPAIR_ASSIGNMENT_CONTRACT)
        # A test report can raise the review mode. A defect of that review still gets a fix.
        self.assertIn('A defect that a later review in the gate finds still gets a fix.', REPAIR_ASSIGNMENT_CONTRACT)
        self.deferred_test(self.closed())
        prompts = []
        normal = self.transport.run
        def run(role, prompt, pending, directory):
            if role == 'repair_execute' and not pending.get('report_repair'):
                prompts.append(prompt)
            return normal(role, prompt, pending, directory)
        self.transport.run = run
        self.until(lambda: self.state.get('pair_review') is None)
        test_prompt = next(p for p in prompts if '"operation": "test"' in p)
        self.assertIn('When all checks pass, close every assignment as verified.', test_prompt)
        # Only labelled later work goes to the outer pair, so a record of each round does not repeat it without end.
        self.assertIn('Name later work only when the check field of an assignment names it.', test_prompt)
        self.assertIn('Name it in the resolution of that assignment, after the label \\"Later work:\\".', test_prompt)
        self.assertNotIn('This gate cannot pass later work to the outer pair.', test_prompt)
        self.assertIn('in its resolution after the label "Later work:".', self.corrections[0][1])
        # The repeated outer pair assigns the later work, although its row is closed.
        # A reset can also carry the rows to Pair A, so the rule names every outer pair.
        self.assertIn('Carried later work in an outer pair, not in an inner repair review:', REPAIR_ASSIGNMENT_CONTRACT)
        self.assertIn('Such later work is open, and the closure rules of the discussion and the arbitration do not apply to it.',
                      REPAIR_ASSIGNMENT_CONTRACT)
        self.assertIn('Decide such a carried assignment as fix, with the later work as its repair, unless the candidate '
                      'already contains it.', REPAIR_ASSIGNMENT_CONTRACT)
        # The outer pair gives the new fix executor the data, and the fix step does an unlabelled repair.
        self.assertIn('Copy into the repair the data that the later work needs, such as check results and their evidence.',
                      REPAIR_ASSIGNMENT_CONTRACT)
        self.assertIn('Do not copy the label "Later work:" into the new assignment, also not in a quote.', REPAIR_ASSIGNMENT_CONTRACT)

    def test_labelled_later_work_makes_a_cleanup_gate_repeat_the_outer_pair(self):
        original = pairs.decision
        def labelled(*args, **kwargs):
            value = original(*args, **kwargs)
            return dict(value, check=value['check'] + ' Later work: record the check results in the plan.')
        with patch.object(pairs, 'decision', labelled):
            pair = self.deferred_test(self.closed(), repeat=False)
        self.assertEqual(pair['repair_kind'], 'cleanup')  # A low row alone does not repeat the outer pair.
        self.assertTrue(pair['repair']['repeat_outer'])
        self.until(lambda: self.state.get('pair_review') is None)
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.state['phase'], 'pair_b')  # Not a cleanup finish: the outer pair repeats.
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['deferred-test'])
        carried = {row['source_id']: row for row in self.state['pair_carry']}
        self.assertIn('Later work for the outer pair', carried['assigned']['resolution']['resolution'])

    def test_later_work_that_comes_back_after_its_outer_pair_stops_for_the_operator(self):
        pair = self.deferred_test(lambda value: dict(value, resolutions=[dict(
            row, outcome='verified', resolution='Checks passed. Later work: record the results in the plan.')
            for row in value['resolutions']]))
        self.until(lambda: self.state.get('pair_review') is None)
        carried = copy.deepcopy(self.state['pair_carry'])
        pair['carry'] = carried  # The next outer pair received the row, and its gate named later work again.
        with self.assertRaises(Blocked) as caught:
            self.cycle.finish_repair(pair)
        self.assertEqual(caught.exception.code, 'later-work-repeat')
        self.assertIn('assigned', str(caught.exception))
        self.cycle.handle_block(caught.exception)
        self.assertEqual(self.state['blocker']['escalation_reason'], 'operator-decision')  # No recovery agent.
        self.assertEqual(self.state['status'], 'blocked')
        self.assertIn('cc-focus correct', str(caught.exception))
        gate = pair['repair']
        named = gate['resolutions']['assigned']
        gate['resolutions']['assigned'] = dict(named, resolution='Checks passed. Later work: none.')
        self.cycle.finish_repair(pair)  # A label without work names no work.
        gate['resolutions']['assigned'] = named
        # One round of later work is allowed: a carried row without it does not stop.
        pair['carry'] = [dict(row, resolution=dict(row['resolution'], resolution='Fixed earlier.')) for row in carried]
        self.cycle.finish_repair(pair)

    def test_only_the_check_field_names_later_work(self):
        from focus_pair_repair import names_later_work
        self.assertTrue(names_later_work({'check': 'Run T. Later work: record the results.'}))
        for key in ('title', 'body', 'repair', 'reason'):
            with self.subTest(key=key):  # A quote of a carried resolution does not repeat the outer pair again.
                self.assertFalse(names_later_work({key: 'The carried resolution names Later work: a record.', 'check': 'Run T.'}))
        self.assertFalse(names_later_work({'check': None}))
        for empty in ('Run T. Later work: none.', 'Run T. Later work:', 'Run T. Later work: n/a', 'Run T. Later work: нет',
                      'Run T. Later work: none required.', 'Run T. Later work: not needed.', 'Run T. Later work: no further work.',
                      'Run T. Later work: nothing further.', 'Run T. Later work: \u2014', 'Run T. Later work: No.',
                      'Run T. Later work: no', 'Run T. Later work: no\nEvidence: 42/42', 'Run T. Later work: not applicable.', 'Run T. Later work: Не требуется.'):
            with self.subTest(empty=empty):
                self.assertFalse(names_later_work({'check': empty}))
        for work in ('Run T. Later work: none\nLater work: record the results.', 'Run T. Later work:\nrecord the results.',
                     'Run T. Later work:\n- record the results', 'Run T. Later work: no record yet, write one.',
                     'Run T. Later work: No-op guard of the record.'):
            with self.subTest(work=work):  # Work on the next line, a list item, and a word that starts with "no".
                self.assertTrue(names_later_work({'check': work}))

    def test_a_correction_after_another_correction_uses_up_the_whole_chain(self):
        pair = self.deferred_test(None)
        normal = self.transport.handlers['repair_execute']
        def writer(c, h):
            value = normal(c, h)
            if c['operation'] == 'test':
                value['repair']['mode'] = 'solo'  # A value correction comes first and keeps the outcomes.
            return value
        self.transport.handlers['repair_execute'] = writer
        def correction(value):
            if self.corrections[-1][2]['report_repair']['reason'] == 'report-enum':
                return dict(value, repair=dict(value['repair'], mode='self'))
            return self.closed()(value)
        self.correction_transport(correction)
        self.until(lambda: pair.get('repair', {}).get('step') == 'complete' or self.state.get('pair_review') is None)
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.runs.count('test'), 1)
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['report-enum', 'deferred-test'])
        chain = self.cycle.with_correction_source(self.corrections[1][2]['id'])
        self.assertEqual(chain[:2], [self.corrections[1][2]['id'], self.corrections[0][2]['id']])
        self.assertEqual(len(chain), 3)  # The original test run is the last name.
        self.assertTrue(set(chain) <= set(pair['repair']['consumed_tests']))

class ReportEnumCounterTests(unittest.TestCase):
    """A value correction also fixes the counters of a test run, as the repair-mode correction does."""
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'assign', 'until', 'step', 'resolution', 'result'):
        locals()[_name] = getattr(execution_tests.PairExecutionTests, _name)
    correction_transport = accounting_tests.ExecutorAccountingTests.correction_transport

    def worded_test_run(self, correction, copied):
        """An unchanged late test run with a risk in words and counters copied from its fix batch."""
        pair = self.assign('pair_b', 'low', False)
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        normal = self.transport.dispatch
        def dispatch(role, prompt, heartbeat):
            value = json.loads(normal(role, prompt, heartbeat))
            if role == 'repair_execute' and value['repair']['tests']['status'] != 'deferred':
                value['repair'].update(mode='pair', risks=['generated output'], reason='Generated files')
                value.update(copied)
            return json.dumps(value)
        self.transport.dispatch = dispatch
        self.correction_transport(correction)
        return gate

    def test_copied_counters_and_a_risk_in_words_get_one_correction(self):
        gate = self.worded_test_run(lambda value: dict(value, implementation_fixes=0, substantial=False, repair=dict(
            value['repair'], risks=['contracts'])), dict(implementation_fixes=1))
        test_runs = [role for role, _ in self.transport.calls].count('repair_execute')
        self.until(lambda: gate['step'] != 'test')
        self.assertIsNone(self.state['blocker'])
        self.assertEqual([role for role, _ in self.transport.calls].count('repair_execute'), test_runs + 1)
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['report-enum'])
        prompt = self.corrections[0][1]
        self.assertIn('Also set all three counters to 0', prompt)
        keep = prompt.split('Keep every other field exactly', 1)[1].split('.', 1)[0]
        self.assertNotIn('counters', keep)

    def test_kept_copied_counters_are_refused(self):
        gate = self.worded_test_run(lambda value: dict(value, repair=dict(value['repair'], risks=['contracts'])),
                                    dict(implementation_fixes=1))
        with self.assertRaises(Blocked) as caught:
            self.until(lambda: gate['step'] != 'test')
        self.assertEqual(caught.exception.code, 'report-repair-content')


class ReportEnumEvidenceTests(unittest.TestCase):
    """A test run that changed a journal, counted nothing, and named a risk in words."""
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'until', 'assign', 'writer', 'set_writer', 'step', 'audit'):
        locals()[_name] = getattr(evidence_tests.RepairEvidenceTests, _name)
    correction_transport = accounting_tests.ExecutorAccountingTests.correction_transport

    def test_uncounted_journal_changes_are_counted_by_the_value_correction(self):
        pair = self.assign('pair_b', 'low', False)
        execute = self.set_writer()
        self.test_runs = 0
        def writer(context, heartbeat):
            value = execute(context, heartbeat)
            if context['operation'] == 'fix':
                (self.root / 'plan.md').write_text('# Plan\n\nImplementation requirements remain unchanged.\n')
            else:
                self.test_runs += 1
                with (self.root / 'plan.md').open('a') as out:
                    out.write('\n## Completed verification\nTargeted guard test passed.\n')
                value['minor_edits'] = 0
                value['repair'].update(mode='pair', risks=['generated output'], reason='Generated files')
                for row in value['resolutions']:
                    row.update(outcome='verified', evidence=['Targeted test verified the earlier fix'])
            return value
        self.transport.handlers['repair_execute'] = writer
        self.transport.handlers['repair_evidence'] = lambda c, h: self.audit(c)
        self.correction_transport(lambda value: dict(value, minor_edits=1, repair=dict(value['repair'], risks=['contracts'])))
        gate = pair['repair']
        self.until(lambda: gate['step'] == 'test')
        self.until(lambda: gate['step'] != 'test')
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.test_runs, 1)
        self.assertEqual([c[2]['report_repair']['reason'] for c in self.corrections], ['report-enum'])
        self.assertIn('Also count these changes', self.corrections[0][1])
        self.assertIn('"changed_paths": ["plan.md"]', self.corrections[0][1])


if __name__ == '__main__':
    unittest.main()
