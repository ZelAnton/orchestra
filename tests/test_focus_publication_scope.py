"""Publication selection, concurrent work preservation, and early review evidence."""

import copy
import json
from pathlib import Path
import subprocess
import unittest
from unittest.mock import patch

import test_cycle as fixtures
import test_focus_project as project_fixtures
import test_focus_pairs as pairs
from test_focus_pairs import PairTransport, finding, decision
from cycle_state import Blocked, digest, encode
from cycle_workflow import fresh_state
from focus_pair_protocol import assignment_key
from focus_pair_view import materialize
from focus_snapshot_archive import read_source
from focus_status import accept_task
import focus_publication_scope as scope
import focus_reconcile


class ScopeTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    remote = fixtures.CycleTests.remote
    edit = fixtures.CycleTests.edit

    def setup_scope(self):
        (self.root / 'PLAN.md').write_text('# Next stage\n')
        (self.root / 'foreign.md').write_text('Original document\n')
        self.repo.git('add', 'PLAN.md', 'foreign.md')
        self.repo.git('commit', '-m', 'Add documents')
        (self.root / 'operator.txt').write_text('Existing staged work\n')
        self.repo.git('add', 'operator.txt')
        self.state.clear()
        self.state.update(fresh_state(self.repo))
        self.state.update(phase='pair_a', code_started=True, status='blocked',
                          task={'id': 'old', 'title': 'Old task', 'plan': 'PLAN.md', 'iteration': 1},
                          blocker={'code': 'pair-no-progress'}, sessions={'pair_fix': 'preserved-session'})
        (self.root / 'source.txt').write_text('Stage implementation\n')
        (self.root / 'foreign.md').write_text('Concurrent plan design\n')
        self.state['last_snapshot'] = self.repo.snapshot()
        row = dict(finding('publication'), source_id='old/pair_opus/publication')
        self.state['pair_review'] = {'id': 'old', 'phase': 'pair_a', 'step': 'decide', 'round': 1,
            'snapshot': self.repo.snapshot(), 'issues': [row], 'carry': [], 'scans': {},
            'decisions': [decision(row, 'verify')], 'resolutions': [], 'jobs': {},
            'executed_assignments': [assignment_key(self.repo.snapshot(), [decision(row, 'verify')])]}
        self.request = {'schema': scope.REQUEST_SCHEMA, 'task': {'id': 'new', 'title': 'New stage', 'plan': 'PLAN.md'},
                        'paths': ['source.txt']}
        self.cycle.save()

    def write_scope(self):
        path = self.root / '.work/scope-plan.json'
        return path, focus_reconcile.write_plan(self.cycle, path, prepare_plan=lambda c: scope.prepare(c, self.request))

    def test_exact_selection_preserves_work_and_restarts_review_with_obligation(self):
        self.setup_scope()
        before = self.repo.snapshot()
        state = copy.deepcopy(self.state)
        path, plan = self.write_scope()
        self.assertEqual(self.state, state)
        self.assertEqual([r['path'] for r in plan['excluded']], ['foreign.md'])
        scope.apply(self.cycle, path)
        self.assertEqual(self.repo.snapshot(), before)
        self.assertEqual(self.state['sessions'], state['sessions'])
        self.assertEqual((self.state['phase'], self.state['status']), ('pair_a', 'paused'))
        self.assertIsNone(self.state['reviewed'])
        self.assertIsNone(self.state['pair_review'])
        self.assertIsNone(self.state['blocker'])
        self.assertEqual(self.state['pair_carry'][0]['source_id'], 'old/pair_opus/publication')
        self.assertEqual(self.state['task']['id'], 'new')
        self.assertEqual(set(self.state['protected']), {'operator.txt', 'foreign.md'})
        self.assertEqual(self.state['protected_index']['operator.txt'], state['protected_index']['operator.txt'])
        self.cycle.check_protected(before)
        self.state['publication_paths'] = ['foreign.md', 'operator.txt']
        self.assertEqual(self.cycle.publication_paths(), ['source.txt'])
        self.assertNotIn('publication_recovery', self.state['corrections'][-1])
        archive = json.loads(Path(self.state['corrections'][-1]['archive']).read_text())
        self.assertEqual(archive['previous_state'], state)
        self.assertEqual(archive['publication_selection'], plan)
        with self.assertRaisesRegex(Blocked, 'changed'):
            scope.apply(self.cycle, path)

    def test_manifest_exists_in_each_outer_pair_and_final_has_no_review_history(self):
        self.setup_scope()
        path, _ = self.write_scope()
        scope.apply(self.cycle, path)
        for phase in ('pair_a', 'pair_b', 'final'):
            self.state.update(phase=phase, pair_review=None)
            pair = self.cycle.new_pair()
            view = materialize(self.cycle, pair)
            value = json.loads(read_source(view, view['publication']))
            self.assertEqual(value['paths'], ['source.txt'])
            self.assertEqual(value['task']['id'], 'new')
            self.assertEqual(value['candidate'], digest(encode(pair['snapshot'])))
            self.assertEqual(value['status'], 'planned')
            self.assertEqual(value['selection'], 'operator-exact')
            if phase == 'final':
                self.assertEqual([n for n in view['files'] if n.startswith('__review__/')], ['__review__/publication.json'])

    def test_publication_commits_and_pushes_only_selected_paths_with_foreign_staging(self):
        self.setup_scope()
        self.remote()
        path, _ = self.write_scope()
        scope.apply(self.cycle, path)
        protected_index = dict(self.state['protected_index'])
        self.state.update(phase='publish', reviewed=self.repo.snapshot(), remote='origin')
        self.cycle.policy = lambda *a: subprocess.CompletedProcess([], 0, b'{}', b'')
        self.assertTrue(self.cycle.prepare_publish())
        # Hermetic Git runner: exercise the actual add/commit/push arguments.
        with patch('focus_commit.run_git', side_effect=lambda c, *a: c.repo.git('--literal-pathspecs', *a)):
            self.cycle.execute_publication('Publish scoped changes')
        self.assertEqual(self.repo.text('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'), 'source.txt')
        self.assertEqual(self.repo.index_entries(self.state['protected']), protected_index)
        self.assertEqual((self.root / 'foreign.md').read_text(), 'Concurrent plan design\n')
        self.assertEqual(self.state['phase'], 'ci')
        self.assertEqual(self.cycle.remote_head('origin'), self.repo.text('rev-parse', 'HEAD'))
        self.assertTrue(self.cycle.next_stage())
        self.assertNotIn('publication_scope', self.state)
        self.assertNotIn('task_source', self.state)
        self.assertIsNone(self.state['task'])
        self.assertIn('foreign.md', self.state['protected'])
        self.assertEqual(self.cycle.publication_paths(), [])

    def test_excluded_deletion_is_preserved(self):
        self.setup_scope()
        (self.root / 'foreign.md').unlink()
        path, _ = self.write_scope()
        scope.apply(self.cycle, path)
        self.cycle.check_protected(self.repo.snapshot())
        self.assertNotIn('foreign.md', self.state['baseline']['files'])
        self.assertIn('foreign.md', self.state['protected'])
        (self.root / 'foreign.md').write_text('restored')
        with self.assertRaisesRegex(Blocked, 'Pre-existing work'):
            self.cycle.check_protected(self.repo.snapshot())

    def test_excluded_untracked_file_is_preserved_without_index_entry(self):
        self.setup_scope()
        (self.root / 'draft.md').write_text('Unrelated design')
        path, _ = self.write_scope()
        scope.apply(self.cycle, path)
        self.assertIn('draft.md', self.state['protected'])
        self.assertNotIn('draft.md', self.state['protected_index'])
        self.cycle.check_protected(self.repo.snapshot())
        self.assertEqual(self.cycle.publication_paths(), ['source.txt'])

    def test_new_outside_changes_and_task_drift_block(self):
        self.setup_scope()
        path, _ = self.write_scope()
        scope.apply(self.cycle, path)
        (self.root / 'extra.txt').write_text('outside')
        with self.assertRaisesRegex(Blocked, 'outside the exact'):
            self.cycle.check_protected(self.repo.snapshot())
        self.state['task']['id'] = 'wrong'
        with self.assertRaisesRegex(Blocked, 'task identity'):
            self.cycle.check_protected(self.repo.snapshot())

    def test_stale_plan_and_changed_protected_work_rejected(self):
        self.setup_scope()
        path, _ = self.write_scope()
        original = copy.deepcopy(self.state)
        (self.root / 'source.txt').write_text('later edit')
        with self.assertRaisesRegex(Blocked, 'changed'):
            scope.apply(self.cycle, path)
        self.assertEqual(self.state, original)
        (self.root / 'operator.txt').write_text('changed staging worktree')
        with self.assertRaisesRegex(Blocked, 'Protected work changed'):
            scope.prepare(self.cycle, self.request)

    def test_edited_plan_and_changed_runtime_decision_rejected(self):
        self.setup_scope()
        path, plan = self.write_scope()
        edited = copy.deepcopy(plan)
        edited['selection']['paths'].append('foreign.md')
        path.write_bytes(encode(edited))
        with self.assertRaisesRegex(Blocked, 'changed'):
            scope.apply(self.cycle, path)
        path.write_bytes(encode(plan))
        self.state['pair_review']['decisions'][0]['check'] = 'New obligation'
        with self.assertRaisesRegex(Blocked, 'changed'):
            scope.apply(self.cycle, path)

    def test_save_failure_rolls_back_ownership(self):
        self.setup_scope()
        path, _ = self.write_scope()
        original = copy.deepcopy(self.state)
        with patch.object(self.cycle, 'save', side_effect=OSError('disk unavailable')):
            with self.assertRaises(OSError):
                scope.apply(self.cycle, path)
        self.assertEqual(self.state, original)
        self.assertEqual(self.store.read()['protected'], original['protected'])

    def test_reject_pending_published_or_changed_index(self):
        self.setup_scope()
        for key, value in [('pending', {'id': 'active'}), ('publication_started', True),
                           ('published', {'sha': 'commit'}), ('phase', 'code')]:
            original = self.state.get(key)
            self.state[key] = value
            with self.subTest(key=key), self.assertRaises(Blocked):
                scope.prepare(self.cycle, self.request)
            self.state[key] = original
        self.repo.git('add', 'foreign.md')
        with self.assertRaisesRegex(Blocked, 'staging changed'):
            scope.prepare(self.cycle, self.request)

    def test_bad_paths_and_nonchanged_or_protected_selection_rejected(self):
        self.setup_scope()
        for names in [['source.txt', 'source.txt'], ['../source.txt'], ['/tmp/path'],
                      ['.work/cycle/state.json'], ['x/.git/config'], [':(glob)*'], ['x\\y'],
                      ['source.txt/'], ['PLAN.md'], ['operator.txt'], ['missing.txt'], []]:
            with self.subTest(paths=names), self.assertRaises(Blocked):
                scope.prepare(self.cycle, dict(self.request, paths=names))

    def test_ignored_plan_cannot_supply_unsealed_task_identity(self):
        self.setup_scope()
        (self.root / '.git/info/exclude').write_text('ignored-plan.md\n')
        (self.root / 'ignored-plan.md').write_text('Unsealed instructions')
        request = dict(self.request, task=dict(self.request['task'], plan='ignored-plan.md'))
        with self.assertRaisesRegex(Blocked, 'candidate snapshot'):
            scope.prepare(self.cycle, request)

    def test_cli_scope_prepare_and_apply_start_no_model(self):
        import cc_focus
        self.setup_scope()
        request = self.root / '.work/selection.json'
        request.write_bytes(encode(self.request))
        destination = self.root / '.work/selection-plan.json'
        with patch('cc_focus.Path.cwd', return_value=self.root), patch('cc_focus.Lease') as lease, \
                patch('cycle_transport.Transport.run', side_effect=AssertionError('No provider allowed')):
            lease.return_value.__enter__.return_value.pwsh = 'pwsh'
            self.assertEqual(cc_focus.main(['reconcile', '--publication-scope', str(request), '--plan-out', str(destination)]), 0)
            self.assertEqual(self.store.read()['status'], 'blocked')
            self.assertEqual(cc_focus.main(['reconcile', '--apply-plan', str(destination)]), 0)
        saved = self.store.read()
        self.assertEqual((saved['phase'], saved['status']), ('pair_a', 'paused'))
        self.assertEqual(saved['publication_scope'], self.request)

    def test_code_report_replaces_provisional_label_but_later_reports_cannot_relabel(self):
        first = {'id': 'old', 'title': 'Previous stage', 'plan': 'source.txt'}
        selected = dict(first, id='new', title='Implemented stage')
        accept_task(self.state, {'task': first}, 'coordinate')
        accept_task(self.state, {'task': selected}, 'code')
        self.assertEqual(self.state['task']['id'], 'new')
        accept_task(self.state, {'task': first}, 'coordinate')
        accept_task(self.state, {'task': first}, 'code')
        self.assertEqual(self.state['task']['id'], 'new')

    def test_scope_transition_preserves_no_progress_guard(self):
        self.setup_scope()
        with self.assertRaisesRegex(Blocked, 'repeated an answered'):
            self.cycle.paired_review_step()
        path, _ = self.write_scope()
        scope.apply(self.cycle, path)
        transport = PairTransport(self.root)
        self.cycle.transport = transport
        def assess(context, heartbeat):
            assignment = context['assignment']
            if assignment['mode'] == 'independent_initial':
                return fixtures.report(findings=[])
            if assignment.get('proposal_hash'):
                return fixtures.report(assessments=[], new_findings=[], consensus=assignment['proposal_hash'], impact='minor')
            rows = [decision(r, 'reject', False) for r in assignment['registry']]
            return fixtures.report(assessments=rows, new_findings=[], consensus=None, impact='minor')
        transport.handlers.update(pair_opus=assess, pair_sol=assess, pair_arbiter=assess,
                                  pair_opus_discuss=assess, pair_sol_discuss=assess)
        pairs.PairTests.until(self, lambda: self.state['phase'] == 'pair_b')
        self.assertNotIn('pair_fix', [r for r, _ in transport.calls])
        self.assertTrue(all(c.get('publication_manifest') for _, c in transport.calls))

    def test_late_executor_receives_the_current_planned_manifest(self):
        pair = pairs.PairTests.assign(self, phase='pair_b')
        context = json.JSONDecoder().raw_decode(self.cycle.repair_writer_context().split('Executor assignment:\n', 1)[1])[0]
        self.assertEqual(context['publication_manifest']['candidate'], digest(encode(pair['repair']['snapshot'])))
        self.assertEqual(context['publication_manifest']['paths'], ['source.txt'])

    start = pairs.PairTests.start


class ProjectScopeTests(unittest.TestCase):
    setUp = project_fixtures.ProjectTests.setUp
    tearDown = project_fixtures.ProjectTests.tearDown

    def test_member_publication_retains_exact_paths_and_shared_task(self):
        (self.root / 'Core/source.txt').write_text('Stage work\n')
        (self.root / 'Specification/source.txt').write_text('Concurrent document\n')
        self.state.update(phase='pair_a', status='blocked', code_started=True)
        request = {'schema': scope.REQUEST_SCHEMA, 'task': {'id': 'stage', 'title': 'Stage', 'plan': 'Core/source.txt'},
                   'paths': ['Core/source.txt']}
        destination = self.root / '.work/scope-plan.json'
        focus_reconcile.write_plan(self.cycle, destination, prepare_plan=lambda c: scope.prepare(c, request))
        scope.apply(self.cycle, destination)
        self.state.update(phase='publish', reviewed=self.project.snapshot())
        self.assertTrue(self.cycle.prepare_publish())
        self.assertEqual(list(self.state['publication_targets']), ['Core'])
        member = self.cycle.member('Core')
        self.assertEqual(member.publication_paths(), ['source.txt'])
        member.check_protected(member.snapshot())
        self.assertIn('Specification/source.txt', self.state['protected'])
        self.assertEqual((self.root / 'Specification/source.txt').read_text(), 'Concurrent document\n')
        foreign_head = self.members['Specification'].text('rev-parse', 'HEAD')
        with patch('focus_commit.run_git', side_effect=lambda c, *a: c.repo.git('--literal-pathspecs', *a)):
            self.cycle.execute_publication('Publish scoped project changes')
        self.assertTrue(self.cycle.reconcile_publish())
        self.assertEqual(self.members['Specification'].text('rev-parse', 'HEAD'), foreign_head)
        self.assertEqual(self.members['Core'].text('show', 'HEAD:source.txt'), 'Stage work')


if __name__ == '__main__':
    unittest.main()
