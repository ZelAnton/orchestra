"""Instruction style and saved-job compatibility, without provider calls."""

import copy
import json
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / 'tools'))
from check_focus_instructions import audit, prose, sentences, word_count
from cycle_prompts import (COMMAND_EXECUTION_CONTRACT, CONTRACT, PAIR_CONTRACT, PARALLEL_REPOSITORIES_RULE, PROFILES,
                           PROJECT_INSTRUCTIONS_RULE, WRITING_CONTRACT, role_contract)
from focus_pair_jobs import same_pair_prompt


class InstructionTests(unittest.TestCase):
    def setUp(self):
        self.old = json.loads((ROOT / 'tests/fixtures/focus_v8_instruction_style.json').read_text())

    def prompts(self):
        before = {'phase': 'pair_b', 'candidate': 'exact-snapshot', 'task': {'id': 'stage', 'plan': 'plan.md'},
                  'stage_paths': ['src/main.cs'], 'role': 'pair_astra', 'operator_instructions': [],
                  'corrections': [], 'assignment': {'round': 1, 'findings': []}}
        after = copy.deepcopy(before)
        for row in self.old['changes']:
            # Each rule variant gets a separate direct test below.
            left, right = before, after
            for part in row['path'][:-1]:
                left = left.setdefault(part, {})
                right = right.setdefault(part, {})
            left[row['path'][-1]] = row['old']
            right[row['path'][-1]] = row['new']
        return before, after

    def render(self, value, old=False):
        return (self.old['pair_contract'] if old else PAIR_CONTRACT) + '\nRuntime assignment:\n' + json.dumps(value)

    def test_canonical_prose_meets_mechanical_limits(self):
        result = audit(ROOT)
        self.assertGreater(result['blocks'], 40)
        self.assertGreater(result['sentences'], 500)
        self.assertFalse(result['certification'])
        self.assertEqual(result['findings'], [])

    def test_the_checker_scans_the_project_instructions_rule(self):
        self.assertIn(PROJECT_INSTRUCTIONS_RULE.strip(), {text for _, text in prose(ROOT)})

    def test_the_checker_scans_the_parallel_repositories_rule(self):
        self.assertIn(PARALLEL_REPOSITORIES_RULE.strip(), {text for _, text in prose(ROOT)})

    def test_word_counter_keeps_machine_literals_and_does_not_split_paths(self):
        parts = list(sentences('Use `git diff --check`. Read .work/cycle/state.json. Keep (the old version) unchanged.'))
        self.assertEqual(len(parts), 3)
        self.assertEqual([word_count(s) for s in parts], [2, 2, 3])
        self.assertEqual(word_count('Use a read-only tool.'), 4)

    def test_exact_literals_do_not_trigger_prose_rewrites(self):
        text = 'Keep `данные;don\'t` unchanged. Preserve "Не удалять; don\'t" as quoted evidence.'
        with patch('check_focus_instructions.prose', return_value=[('example', text)]):
            self.assertEqual(audit(ROOT)['findings'], [])

    def test_checker_rejects_long_paragraphs_and_ordinary_prose_errors(self):
        text = ('Read the file. ' * 7) + "\n\nDon't change this; проверьте текст.\n\n" + ('word ' * 21) + '.'
        with patch('check_focus_instructions.prose', return_value=[('example', text)]):
            result = audit(ROOT)
        self.assertEqual(len(result['findings']), 1)
        row = result['findings'][0]
        self.assertEqual(len(row['over_six_sentences']), 1)
        self.assertEqual(len(row['over_20_words']), 1)
        for key in ('contraction', 'semicolon', 'non_english_prose'):
            self.assertTrue(row[key], key)

    def test_writing_rule_reaches_codex_roles_but_not_claude_instructions(self):
        # Claude writers load the user policy from settings; see the transport fixture.
        for role, (provider, _, _) in PROFILES.items():
            with self.subTest(role=role):
                if provider == 'claude':
                    self.assertNotIn(WRITING_CONTRACT, role_contract(role))
                    self.assertTrue(role_contract(role).startswith(COMMAND_EXECUTION_CONTRACT))
                else:
                    self.assertTrue(role_contract(role).startswith(WRITING_CONTRACT))
                    self.assertIn('Preserve every requirement', role_contract(role))

    def test_coding_instructions_keep_guards_without_assigning_review_roles(self):
        code = role_contract('code')
        self.assertIn(CONTRACT.split('The outer runtime owns the loop.', 1)[0], code)
        self.assertIn(CONTRACT[CONTRACT.index('No provider role may stage, commit or push.'):], code)
        self.assertNotIn(PAIR_CONTRACT, code)
        self.assertNotIn('Use only focus_inspect', code)
        self.assertNotIn('action=verify', code)
        self.assertIn('New implementation can be substantial with zero implementation_fixes.', code)
        self.assertIn('Do not start a full run in the code role.', code)
        self.assertNotIn('Full suites require an explicit late-pair assignment', code)
        self.assertIn('Do not skip required checks', code)
        self.assertIn('All required review phases still follow coding.', code)
        for role in ('pair_opus', 'pair_sol', 'repair_execute', 'pair_arbiter'):
            self.assertIn(PAIR_CONTRACT, role_contract(role))

    def test_every_role_receives_the_test_scope_rules(self):
        for role in PROFILES:
            with self.subTest(role=role):
                contract = role_contract(role)
                self.assertIn('Test scope rules for every cc-focus role:', contract)
                self.assertIn('Only two cases permit a full run.', contract)
                self.assertIn('In the report, name each omitted broader check and the reason.', contract)
        self.assertIn('After the one Pair B full run of a stage, the runtime rejects full_suite assignments.', PAIR_CONTRACT)
        self.assertIn('State the change type and the risk in the reason of the assignment.', PAIR_CONTRACT)
        self.assertIn('The first run of the new checks and mutants of a stage is not a full run.', COMMAND_EXECUTION_CONTRACT)
        self.assertIn('Without full_suite=true, do not request a full run in the check text of an assignment.', COMMAND_EXECUTION_CONTRACT)
        self.assertIn('Each stage also permits one final gate after the passed final pair, with one full run.', COMMAND_EXECUTION_CONTRACT)
        self.assertIn('If the changes justify a full run before publication, set final_gate.full_run=true.', PAIR_CONTRACT)
        self.assertNotIn('Full test suites are optional.', PAIR_CONTRACT)

    def test_known_revision_keeps_saved_job_bytes_and_context(self):
        before, after = self.prompts()
        saved, current = self.render(before, True), self.render(after)
        original = copy.deepcopy(before)
        self.assertTrue(same_pair_prompt(saved, current))
        self.assertEqual(before, original)
        self.assertEqual(saved, self.render(before, True))
        self.assertTrue(same_pair_prompt(current, current))

    def test_each_known_instruction_revision_is_accepted(self):
        for row in self.old['changes']:
            with self.subTest(path=row['path'], text=row['old'][:40]):
                before, after = {}, {}
                left, right = before, after
                for part in row['path'][:-1]:
                    left = left.setdefault(part, {})
                    right = right.setdefault(part, {})
                left[row['path'][-1]] = row['old']
                right[row['path'][-1]] = row['new']
                self.assertTrue(same_pair_prompt(self.render(before, True), self.render(after)))

    def test_revision_never_accepts_changed_task_or_authority(self):
        before, after = self.prompts()
        mutations = [
            lambda v: v.update(candidate='different'),
            lambda v: v.update(role='pair_opus'),
            lambda v: v.update(phase='final'),
            lambda v: v.update(stage_paths=['secret.txt']),
            lambda v: v['task'].update(id='next'),
            lambda v: v['assignment'].update(round=True),
            lambda v: v['assignment'].update(round=1.0),
            lambda v: v['assignment'].update(findings=[{'id': 'new'}]),
            lambda v: v['operator_instructions'].append({'text': 'New authority'}),
            lambda v: v['corrections'].append('New correction'),
            lambda v: v.update(inspection='Run a shell instead'),
        ]
        for mutate in mutations:
            value = copy.deepcopy(after)
            mutate(value)
            self.assertFalse(same_pair_prompt(self.render(before, True), self.render(value)))

    def test_translation_does_not_apply_to_operator_content(self):
        row = self.old['changes'][0]
        before = {'operator_instructions': [{'text': row['old']}]}
        after = {'operator_instructions': [{'text': row['new']}]}
        self.assertFalse(same_pair_prompt(self.render(before, True), self.render(after)))

    def test_unknown_contract_malformed_json_and_duplicate_keys_are_rejected(self):
        before, after = self.prompts()
        current = self.render(after)
        self.assertFalse(same_pair_prompt('unknown\nRuntime assignment:\n' + json.dumps(before), current))
        self.assertFalse(same_pair_prompt(self.render(before, True) + 'extra', current))
        self.assertFalse(same_pair_prompt(self.render(before, True).replace('"round": 1', '"round": 2, "round": 1'), current))
        self.assertFalse(same_pair_prompt(self.render([], True), current))


if __name__ == '__main__':
    unittest.main()
