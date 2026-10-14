"""Test-result replay and exact, independent audit of historical journal deltas."""

import json
import unittest

import test_cycle as fixtures
import test_focus_repair as repair_tests
from test_cycle import report
from cycle_state import Blocked, digest, encode
from cycle_transport import parse_report
from focus_pair_view import read_record, ViewInspector
from focus_pair_profile import pair_nodes, PAIR_READONLY
from focus_status import build_panel


class RepairEvidenceTests(unittest.TestCase):
    for _name in ('setUp', 'tearDown', 'edit', 'start', 'until', 'assign', 'writer', 'set_writer', 'step'):
        locals()[_name] = getattr(repair_tests.RepairTests, _name)

    def prepare(self, phase='pair_b', status='passed', verdict='evidence_only'):
        pair = self.assign(phase, 'low', False)
        execute = self.set_writer()
        def writer(context, heartbeat):
            value = execute(context, heartbeat)
            if context['operation'] == 'fix':
                (self.root / 'plan.md').write_text('# Plan\n\nImplementation requirements remain unchanged.\n')
            else:
                with (self.root / 'plan.md').open('a') as out:
                    out.write('\n## Completed verification\nTargeted guard test passed.\n')
                value['minor_edits'] = 1
                value['repair']['tests']['status'] = status
                for row in value['resolutions']:
                    row.update(outcome='verified', evidence=['Targeted test verified the earlier fix'])
            return value
        self.transport.handlers['repair_execute'] = writer
        self.transport.handlers['repair_evidence'] = lambda c, h: self.audit(c, verdict)
        self.until(lambda: pair['repair']['step'] == 'test')
        return pair

    def audit(self, context, verdict='evidence_only'):
        assignment = context['assignment']
        return report(evidence_delta={'before': assignment['before'], 'after': assignment['after'], 'files': [
            {'path': p, 'verdict': verdict, 'reason': 'Examined the exact historical delta',
             'evidence': ['Diff contains only completed-check history']} for p in assignment['paths']]})

    def roles(self):
        return [r for r, c in self.transport.calls]

    def legacy_result(self, pair):
        prompt = self.cycle.repair_writer_context()
        self.cycle.invoke('repair_execute')  # Persist a test result, without accepting it.
        identity = self.state['pending']['id']
        directory = self.store.directory / 'invocations' / identity
        intent = json.loads((directory / 'intent.json').read_text())
        intent.pop('repair_binding')
        (directory / 'intent.json').write_text(json.dumps(intent))
        (directory / 'prompt.txt').write_text(prompt)
        self.state['pending'] = None
        pair['repair'].pop('test_invocation', None)
        pair['repair'].pop('test_view', None)
        self.cycle.save()
        return directory

    def test_audited_journal_retains_original_two_passes_and_publishes_actual_snapshot(self):
        pair = self.prepare('final')
        candidate = pair['repair']['clean_candidate']
        self.until(lambda: self.state['phase'] == 'publish')
        gate = pair['repair']
        self.assertEqual(self.roles(), ['repair_execute', 'repair_self', 'repair_self', 'repair_execute', 'repair_evidence'])
        self.assertEqual([r['candidate'] for r in gate['reviews']], [candidate, candidate])
        self.assertEqual(gate['clean'], 2)
        self.assertNotEqual(digest(encode(gate['snapshot'])), candidate)
        self.assertEqual(self.state['reviewed'], self.repo.snapshot())
        sealed = read_record(self.store, pair['repair_seal'])
        self.assertEqual(len(sealed['evidence_changes']), 1)
        self.assertEqual(gate['resolutions']['assigned']['outcome'], 'fixed')
        last = read_record(self.store, gate['executions'][-1])
        self.assertEqual(last['report']['resolutions'][0]['outcome'], 'verified')
        self.assertEqual(last['accepted_resolutions'][0]['outcome'], 'fixed')
        self.assertEqual(len(last['accepted_resolutions'][0]['evidence']), 2)

    def test_audit_sees_exact_test_delta_and_has_only_frozen_inspection(self):
        pair = self.prepare()
        self.step()
        reader = pair['repair']['evidence_reader']
        def audit(c, h):
            view = read_record(self.store, reader['view'])
            self.assertEqual(view['stage_paths'], ['plan.md'])
            inspector = ViewInspector(view)
            diff = inspector.call({'tool': 'focus_inspect', 'arguments': {'operation': 'diff', 'path': 'plan.md', 'offset': 0, 'limit': 100}})
            self.assertIn('+Targeted guard test passed.', diff['contentItems'][0]['text'])
            self.assertNotIn('+Implementation requirements', diff['contentItems'][0]['text'])
            self.assertEqual(c['history'], [])
            return self.audit(c)
        self.transport.handlers['repair_evidence'] = audit
        self.step()
        self.assertIn('repair_evidence', PAIR_READONLY)
        self.assertEqual(pair['repair']['step'], 'complete')

    def test_behavioral_documentation_is_not_exempted(self):
        pair = self.prepare(verdict='behavioral')
        with self.assertRaisesRegex(Blocked, 'behavioral or uncertain'):
            self.until(lambda: self.state['phase'] == 'final')
        self.assertNotIn('repair_seal', pair)
        self.assertNotIn('evidence_changes', pair['repair'])

    def test_uncertain_claims_are_not_exempted(self):
        pair = self.prepare(verdict='uncertain')
        with self.assertRaises(Blocked):
            self.until(lambda: self.state['phase'] == 'final')
        self.assertNotIn('repair_seal', pair)

    def test_source_change_is_rejected_before_auditor(self):
        pair = self.prepare()
        prior = self.transport.handlers['repair_execute']
        def writer(c, h):
            result = prior(c, h)
            (self.root / 'source.py').write_text('behavior = 2\n')
            return result
        self.transport.handlers['repair_execute'] = writer
        with self.assertRaisesRegex(Blocked, 'Tests changed the candidate'):
            self.step()
        self.assertNotIn('repair_evidence', self.roles())
        self.assertNotIn('repair_seal', pair)

    def test_existing_expected_text_is_sent_to_audit_and_rejected(self):
        pair = self.prepare(verdict='behavioral')
        prior = self.transport.handlers['repair_execute']
        def writer(c, h):
            result = prior(c, h)
            (self.root / 'source.txt').write_text('new expected behavior\n')
            return result
        self.transport.handlers['repair_execute'] = writer
        with self.assertRaisesRegex(Blocked, 'behavioral or uncertain'):
            self.until(lambda: self.state['phase'] == 'final')
        context = [c for r, c in self.transport.calls if r == 'repair_evidence'][0]
        self.assertEqual(set(context['assignment']['paths']), {'plan.md', 'source.txt'})
        self.assertNotIn('repair_seal', pair)

    def test_concurrent_edit_before_audit_is_not_adopted(self):
        pair = self.prepare()
        self.step()
        (self.root / 'plan.md').write_text('Other edits after tests\n')
        with self.assertRaisesRegex(Blocked, 'after the saved tests'):
            self.step()
        self.assertNotIn('repair_evidence', self.roles())
        self.assertNotIn('repair_seal', pair)

    def test_audit_requires_exact_hashes_and_complete_unique_paths(self):
        pair = self.prepare()
        self.step()
        def invalid(c, h):
            result = self.audit(c)
            result['evidence_delta']['before'] = 'wrong'
            return result
        self.transport.handlers['repair_evidence'] = invalid
        with self.assertRaisesRegex(Blocked, 'Repeated invalid pair report'):
            self.until(lambda: self.state['phase'] == 'final')
        self.assertEqual(self.roles().count('repair_evidence'), 3)
        self.assertNotIn('repair_seal', pair)

    def test_resume_at_every_boundary_does_not_repeat_checks_or_audit(self):
        self.prepare()
        for _ in range(10):
            if self.state['phase'] == 'final':
                break
            self.step()
            self.state = self.store.read()
            self.cycle.state = self.state
        self.assertEqual(self.state['phase'], 'final')
        self.assertEqual(self.roles().count('repair_execute'), 2)
        self.assertEqual(self.roles().count('repair_evidence'), 1)

    def test_legacy_cached_result_replays_without_tests_even_after_healer_overwrites_last(self):
        pair = self.prepare()
        original = self.legacy_result(pair)
        before = (original / 'result.json').read_bytes()
        self.state['last'] = {'role': 'heal', 'report': '/unused/healer/result.json'}
        self.until(lambda: self.state['phase'] == 'final')
        self.assertEqual(self.roles().count('repair_execute'), 2)
        self.assertEqual(self.roles().count('repair_self'), 2)
        self.assertEqual(self.roles().count('repair_evidence'), 1)
        self.assertEqual((original / 'result.json').read_bytes(), before)

    def test_noop_heal_retains_pending_test_classification_and_static_credit(self):
        pair = self.prepare()
        self.legacy_result(pair)
        self.state['blocker'] = {'phase': 'pair_b', 'status': 'healing'}
        transport = self.cycle.transport
        self.cycle.transport = fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()
        self.cycle.transport = transport
        self.assertIs(self.state['pair_review'], pair)
        self.assertEqual(pair['repair']['clean'], 2)
        self.until(lambda: self.state['phase'] == 'final')
        self.assertEqual(self.roles().count('repair_execute'), 2)

    def test_noop_heal_during_audit_preserves_evidence_step(self):
        pair = self.prepare()
        self.step()
        self.state['blocker'] = {'phase': 'pair_b', 'status': 'healing'}
        transport = self.cycle.transport
        self.cycle.transport = fixtures.FixtureTransport(self.root, [('heal', report())])
        self.cycle.heal()
        self.cycle.transport = transport
        self.assertEqual(pair['repair']['step'], 'evidence')
        self.assertIs(self.state['pair_review'], pair)
        self.until(lambda: self.state['phase'] == 'final')

    def test_legacy_wrong_assignment_cannot_replay(self):
        pair = self.prepare()
        original = self.legacy_result(pair)
        (original / 'prompt.txt').write_text('Executor assignment:\n' + json.dumps({'operation': 'fix'}))
        self.assertIsNone(self.cycle.saved_repair_test(pair))
        with self.assertRaisesRegex(Blocked, 'candidate changed'):
            self.step()
        self.assertEqual(self.roles().count('repair_execute'), 2)

    def test_legacy_stale_result_does_not_adopt_later_changes(self):
        pair = self.prepare()
        self.legacy_result(pair)
        (self.root / 'source.txt').write_text('concurrent edit\n')
        self.assertIsNone(self.cycle.saved_repair_test(pair))
        with self.assertRaisesRegex(Blocked, 'candidate changed'):
            self.step()

    def test_legacy_intent_requires_same_role_iteration_revision_and_snapshot(self):
        pair = self.prepare()
        directory = self.legacy_result(pair)
        path = directory / 'intent.json'
        original = json.loads(path.read_text())
        for key, value in [('role', 'heal'), ('iteration', self.state['iteration'] + 1),
                           ('correction_revision', 'new'), ('restart_reviews', True),
                           ('before', dict(original['before'], files={}))]:
            with self.subTest(field=key):
                path.write_text(json.dumps(dict(original, **{key: value})))
                self.assertIsNone(self.cycle.saved_repair_test(pair))
        path.write_text(json.dumps(original))
        self.assertIsNotNone(self.cycle.saved_repair_test(pair))

    def test_binary_or_invalid_utf8_document_does_not_reach_auditor(self):
        pair = self.prepare()
        original = self.transport.handlers['repair_execute']
        def writer(c, h):
            result = original(c, h)
            (self.root / 'plan.md').write_bytes(b'not text\0\xff')
            return result
        self.transport.handlers['repair_execute'] = writer
        with self.assertRaisesRegex(Blocked, 'exact UTF-8 text'):
            self.step()
        self.assertNotIn('repair_evidence', self.roles())
        self.assertNotIn('repair_seal', pair)

    def test_staging_cannot_use_the_documentation_exception(self):
        self.prepare()
        original = self.transport.handlers['repair_execute']
        def writer(c, h):
            result = original(c, h)
            self.repo.git('add', '--', 'source.txt')
            return result
        self.transport.handlers['repair_execute'] = writer
        with self.assertRaisesRegex(Blocked, 'changed staging'):
            self.step()
        self.assertNotIn('repair_evidence', self.roles())

    def test_legacy_ambiguous_original_reports_are_not_selected_arbitrarily(self):
        pair = self.prepare()
        original = self.legacy_result(pair)
        duplicate = original.with_name('duplicate')
        duplicate.mkdir()
        for name in ('result.json', 'prompt.txt'):
            (duplicate / name).write_bytes((original / name).read_bytes())
        intent = json.loads((original / 'intent.json').read_text())
        intent['id'] = 'duplicate'
        (duplicate / 'intent.json').write_text(json.dumps(intent))
        self.state['last'] = None
        self.assertIsNone(self.cycle.saved_repair_test(pair))

    def test_missing_frozen_original_cannot_receive_audit(self):
        pair = self.prepare()
        gate = pair['repair']
        # The content hash, not the archived manifest's claim, authenticates bytes.
        import zipfile
        for path in self.store.directory.glob('pair-reviews/*/*/view-*/source.zip'):
            with zipfile.ZipFile(path) as archive:
                files = {name: archive.read(name) for name in archive.namelist()}
            if 'plan.md' in files:
                files['plan.md'] = b'tampered original'
                with zipfile.ZipFile(path, 'w') as archive:
                    for name, data in files.items():
                        archive.writestr(name, data)
        with self.assertRaisesRegex(Blocked, 'No exact frozen pre-test'):
            self.step()
        self.assertNotIn('evidence_changes', gate)

    def test_infrastructure_evidence_is_consumed_once_then_only_tests_retry(self):
        pair = self.prepare(status='infrastructure')
        with self.assertRaisesRegex(Blocked, 'Targeted check assessment'):
            self.until(lambda: self.state['phase'] == 'final')
        self.assertEqual(pair['repair']['clean'], 2)
        self.transport.handlers['repair_execute'] = lambda c, h: self.writer(c)
        self.until(lambda: self.state['phase'] == 'final')
        self.assertEqual(self.roles().count('repair_execute'), 3)
        self.assertEqual(self.roles().count('repair_self'), 2)
        self.assertEqual(self.roles().count('repair_evidence'), 1)

    def test_verification_cannot_stand_in_for_missing_original_fix(self):
        pair = self.prepare()
        pair['repair']['executions'] = []
        with self.assertRaisesRegex(Blocked, 'missing or disputed earlier fix'):
            self.step()
        self.assertNotIn('repair_seal', pair)

    def test_verification_without_delta_confirms_original_fix(self):
        pair = self.prepare()
        def writer(c, h):
            value = self.writer(c)
            value['resolutions'][0]['outcome'] = 'verified'
            return value
        self.transport.handlers['repair_execute'] = writer
        self.until(lambda: self.state['phase'] == 'final')
        self.assertEqual(pair['repair']['resolutions']['assigned']['outcome'], 'fixed')
        self.assertNotIn('repair_evidence', self.roles())

    def test_seal_detects_tampered_audit(self):
        pair = self.prepare()
        self.until(lambda: pair['repair']['step'] == 'complete')
        bridge = read_record(self.store, pair['repair']['evidence_changes'][0])
        (self.store.directory / bridge['audit']['path']).write_text('tampered')
        with self.assertRaisesRegex(Blocked, 'sealed pair artifact'):
            self.step()
        self.assertNotIn('repair_seal', pair)

    def test_audited_journal_then_escalation_requires_two_new_pair_passes(self):
        pair = self.prepare()
        execute = self.transport.handlers['repair_execute']
        def writer(c, h):
            result = execute(c, h)
            result['repair'].update(mode='pair', reason='Cross-component risk', risks=['cross_component'])
            return result
        self.transport.handlers['repair_execute'] = writer
        self.until(lambda: self.state['phase'] == 'final')
        self.assertEqual([r['mode'] for r in pair['repair']['reviews']], ['self', 'self', 'pair', 'pair'])
        self.assertEqual(self.roles().count('repair_execute'), 3)
        self.assertEqual(len(pair['repair']['evidence_changes']), 2)

    def test_auditor_failure_resumes_without_rerunning_tests(self):
        pair = self.prepare()
        first = [True]
        def audit(c, h):
            if first[0]:
                first[0] = False
                raise Blocked('fixture', 'Interrupted auditor')
            return self.audit(c)
        self.transport.handlers['repair_evidence'] = audit
        with self.assertRaisesRegex(Blocked, 'Interrupted auditor'):
            self.until(lambda: self.state['phase'] == 'final')
        self.state = self.store.read()
        self.cycle.state = self.state
        self.until(lambda: self.state['phase'] == 'final')
        self.assertEqual(self.roles().count('repair_execute'), 2)
        self.assertEqual(self.roles().count('repair_self'), 2)

    def test_new_static_passes_do_not_hide_corrupted_earlier_audit_history(self):
        pair = self.prepare()
        original = self.transport.handlers['repair_execute']
        def writer(c, h):
            result = original(c, h)
            result['repair'].update(mode='pair', reason='Cross-component risk', risks=['cross_component'])
            return result
        self.transport.handlers['repair_execute'] = writer
        self.until(lambda: pair['repair']['step'] == 'complete')
        first = read_record(self.store, pair['repair']['evidence_changes'][0])
        (self.store.directory / first['audit']['path']).write_text('corrupted old evidence')
        with self.assertRaisesRegex(Blocked, 'sealed pair artifact'):
            self.step()
        self.assertNotIn('repair_seal', pair)

    def test_evidence_reader_is_visible_to_retry_controls_and_panel(self):
        pair = self.prepare()
        self.step()
        self.assertIn(pair['repair']['evidence_reader'], list(pair_nodes(self.state)))
        panel = '\n'.join(build_panel(self.state).lines)
        self.assertIn('проверка журнальной записи', panel)
        self.assertIn('2/2 чистых', panel)

    def test_evidence_schema_rejects_fix_claims(self):
        value = report(implementation_fixes=1, evidence_delta={'before': 'a', 'after': 'b', 'files': [
            {'path': 'plan.md', 'verdict': 'evidence_only', 'reason': 'history', 'evidence': ['diff']} ]})
        with self.assertRaises(Blocked):
            parse_report(json.dumps(value), 'repair_evidence')


if __name__ == '__main__':
    unittest.main()
