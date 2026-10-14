"""Executor counter rules, one report-only correction, and recovery verification by pair progress."""

import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import test_focus_executor_accounting as accounting_tests
import test_focus_pair_execution as execution_tests
import test_focus_pairs as pairs
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


if __name__ == '__main__':
    unittest.main()
