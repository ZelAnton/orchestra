"""Check measurable style limits. This tool does not certify ASD-STE100 compliance."""

import ast
import json
from pathlib import Path
import re

# This map lists prose supplied to providers, including legacy recovery routes.
SOURCES = {
    'cycle_prompts.py': None,
    'cycle_workflow.py': {'context', 'report_repair_context'},
    'cycle_transport.py': {'_run', 'NEW_CONVERSATION', 'RECOVERY'},
    'focus_pairs.py': {'pair_prompt', 'pair_writer_context', 'pair_inspection_step', 'paired_review_step'},
    'focus_pair_repair.py': {'repair_writer_context', 'repair_reader', 'start_final_gate', 'FINAL_GATE_VERIFICATION', 'FULL_RUN_DONE',
                             'TEST_RISKS'},
    'focus_repair_evidence.py': {'queue_repair_evidence', 'repair_evidence_step'},
    'focus_pair_jobs.py': {'run_jobs'},
    'focus_review.py': {'final_context'},
    'focus_review_contract.py': {'CONTRACT'},
    'focus_review_run.py': {'context'},
    'focus_publication_scope.py': {'apply', 'prepare'},
    'focus_readonly.py': {'READ_TOOL', 'VIEW_TOOL'},
}


def instruction_nodes(node):
    if isinstance(node, ast.Raise):
        return  # Diagnostic errors are not provider instructions.
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == 'note':
        return  # Progress messages belong to the terminal UI.
    if isinstance(node, ast.Call) and isinstance(node.func, ast.Name) and node.func.id == 'print':
        return
    yield node
    for child in ast.iter_child_nodes(node):
        yield from instruction_nodes(child)


def prose(root):
    """Read source constants without executing runtime code or inspecting user data."""
    for filename, names in SOURCES.items():
        tree = ast.parse((Path(root) / 'tools' / filename).read_text(encoding='utf-8'))
        roots = []
        for node in ast.walk(tree):
            if names is None and isinstance(node, ast.Assign):
                if any(isinstance(t, ast.Name) and t.id in {
                        'PROMPTS', 'CONTRACT', 'PAIR_CONTRACT', 'CODE_IMPLEMENTATION_CONTRACT', 'COMMAND_EXECUTION_CONTRACT', 'WRITING_CONTRACT', 'EXECUTOR_ACCOUNTING_CONTRACT', 'DISCUSSION_CONSENSUS_CONTRACT', 'REPAIR_ASSIGNMENT_CONTRACT',
                        'PROJECT_BRIEF_RULE', 'BRIEF_CHANGE_CORRECTION', 'PROJECT_INSTRUCTIONS_RULE', 'PARALLEL_REPOSITORIES_RULE', 'REPORT_SCHEMA',
                        'READER_SEARCH_CONTRACT', 'COMPACTION_RULE', 'READER_COMPACTION_RULE'} for t in node.targets):
                    roots.append(node.value)
            elif names is not None and isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name in names:
                roots.extend(node.body[1:] if ast.get_docstring(node) else node.body)
            elif names is not None and isinstance(node, ast.Assign):
                if any(isinstance(t, ast.Name) and t.id in names for t in node.targets):
                    roots.append(node.value)
        seen = set()
        for start in roots:
            for node in instruction_nodes(start):
                if isinstance(node, ast.Constant) and isinstance(node.value, str):
                    text = node.value.strip()
                    if text not in seen and len(text.split()) >= 5:
                        seen.add(text)
                        yield f'{filename}:{node.lineno}', text


def mask_literals(text):
    return re.sub(r'`[^`\n]+`|"[^"\n]+"', 'TOKEN', text)


def sentences(text):
    # Mask exact literals before sentence splitting. Do not split paths or decimals.
    text = re.sub(r'\([^()]*\)', 'TOKEN', mask_literals(text))
    for paragraph in re.split(r'\n\s*\n', text):
        paragraph = re.sub(r'(?m)^\s*(?:[-*] )?', '', paragraph)
        paragraph = re.sub(r'(?m)^([^\n.!?]+):\s*$', '', paragraph)
        for sentence in re.split(r'(?<=[.!?])\s+|\n(?=[-*] )', paragraph):
            sentence = ' '.join(sentence.split())
            if sentence:
                yield sentence


def word_count(sentence):
    return sum(bool(re.search(r'\w', word)) for word in sentence.split())


def audit(root):
    rows = []
    for source, text in prose(root):
        items = list(sentences(text))
        long = [s for s in items if word_count(s) > 20]
        long_paragraphs = [p for p in re.split(r'\n\s*\n', text) if len(list(sentences(p))) > 6]
        ordinary = mask_literals(text)
        rows.append({'source': source, 'sentences': len(items), 'over_20_words': long,
                     'over_six_sentences': long_paragraphs,
                     'semicolon': ';' in ordinary,
                     'contraction': bool(re.search(r"\b\w+(?:n't|'ll|'re|'ve|'d)\b", ordinary)),
                     'non_english_prose': bool(re.search('[А-Яа-яЁё]', ordinary))})
    total = sum(r['sentences'] for r in rows)
    long_count = sum(len(r['over_20_words']) for r in rows)
    return {'scope': 'Canonical provider instruction prose. User data and immutable historical records are excluded.',
            'certification': False, 'sentence_limit': 20, 'blocks': len(rows), 'sentences': total,
            'short_sentences': total - long_count, 'short_sentence_percent': 100 * (total - long_count) / max(1, total),
            'findings': [r for r in rows if r['over_20_words'] or r['over_six_sentences']
                         or r['semicolon'] or r['contraction'] or r['non_english_prose']]}


if __name__ == '__main__':
    result = audit(Path(__file__).resolve().parents[1])
    print(json.dumps(result, ensure_ascii=False, indent=2))
    raise SystemExit(bool(result['findings']))
