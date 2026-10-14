# cc-focus diagnostic review findings

Review date: 2026-10-12.
Repository: `/srv/dev/projects/orchestra`.
Status: both findings are corrected in the working tree.
The resolution section lists the changes and the regression tests.

## Scope and conclusion

Both findings concern diagnostic accuracy in Claude's recent cc-focus changes.
They do not show that the main correction for repeated refusals failed.
The preceding review observed completed Opus coding invocations after that correction.
Those observations do not establish the provider's internal reason for the earlier refusals.

The proposed corrections preserve Opus, model efforts, review order, and existing refusal handling.
They do not require changes to Interlink files or runtime state.

| Finding | Priority | Evidence |
| --- | --- | --- |
| DIAG-01: A failed invocation can appear as the last success. | Medium | Reproduced with an isolated fixture. |
| DIAG-02: Instruction hashes recorded at completion appear under launch metadata. | Medium | Confirmed by source inspection. |

Line numbers below refer to the source inspected on the review date.

## DIAG-01: A failed invocation can appear as the last success

### Location

- [tools/focus_diagnostics.py](../tools/focus_diagnostics.py): `scan_claude_invocation`, lines 430-483.
- [tools/focus_diagnostics.py](../tools/focus_diagnostics.py): `refusal_history`, lines 546-563.
- [tests/test_focus_refusals.py](../tests/test_focus_refusals.py): `RefusalHistoryTests.fixture` and `test_history_names_onset_differences_without_content`.

### Observed behavior

`refusal_history` selects an earlier invocation when it has messages and no recorded refusal:

```python
earlier = [r for r in rows if r["started"] < first["started"] and not r["refusals"] and r["messages"]]
success = next((r for r in reversed(earlier) if r["role"] == first["role"]), earlier[-1] if earlier else None)
```

The returned field calls this invocation `last_success_before`.
However, the selection does not require a successful terminal result.
`ClaudeTrace.report()` contains result metadata, but `scan_claude_invocation` does not include it in the returned summary.

The selected invocation can have `is_error=true`, a truncated log, or no terminal result.
Absence of a safeguard refusal does not establish successful completion.

### Impact

The history can compare the first refusal with another failed or incomplete invocation.
The reported instruction differences can therefore suggest an incorrect explanation for the refusal onset.
This defect affects diagnostic interpretation. It does not directly grant review credit or advance a phase.

### Reproduction

The existing fixture creates an earlier invocation with messages but no terminal result.
The test already treats that incomplete invocation as a success.
The following example adds an explicit failed result and reproduces the same incorrect selection.

Run this command from the Orchestra repository:

```bash
python3 -B - <<'PY'
import json
import sys

sys.path.insert(0, "tests")
sys.path.insert(0, "tools")

from test_focus_refusals import RefusalHistoryTests
from focus_diagnostics import refusal_history

case = RefusalHistoryTests()
case.setUp()
try:
    case.fixture()
    failed_id = "b" * 32
    path = case.directory / "invocations" / failed_id / "protocol.jsonl"
    event = {
        "type": "result",
        "subtype": "error_during_execution",
        "is_error": True,
        "errors": ["fixture failure"],
    }
    with path.open("a") as stream:
        stream.write(json.dumps({
            "stream": "stdout",
            "line": json.dumps(event),
        }) + "\n")

    result = refusal_history(case.directory)
    selected = result["onset"]["last_success_before"]["invocation"]
    print({"failed_invocation": failed_id, "selected_as_success": selected})
    assert selected == failed_id  # Reproduces the current defect.
finally:
    case.doCleanups()
PY
```

Observed result: both output fields contain `bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb`.
The command uses temporary fixtures. It starts no provider and changes no consuming project.
After correction, this defect assertion must fail.

### Proposed correction

1. Define the success criterion for the diagnostic reference.
2. Include terminal result metadata in each invocation summary.
3. For provider completion, require an explicit successful terminal result and no refusal.
4. Treat missing, failed, or contradictory completion evidence as unknown or failed.
5. Preserve the same-role preference among eligible invocations.
6. If no eligible invocation exists, return `null` for the reference.

A successful provider response does not prove runtime acceptance, successful review, or publication.
If the field means runtime acceptance, also require the corresponding acceptance evidence.
Otherwise, describe the field as a completed provider invocation.

### Acceptance checks

- A valid terminal success can become the comparison reference.
- A later invocation with an error result cannot replace that success.
- An invocation without a terminal result cannot become the reference.
- A refusal followed by an apparent success remains ineligible.
- The same-role preference and fallback operate only on eligible invocations.
- When no eligible invocation exists, the reference is `null`.
- The existing successful fixture includes an explicit successful terminal result.

## DIAG-02: Completion-time hashes appear as launch metadata

### Location

- [tools/cycle_transport.py](../tools/cycle_transport.py): `Transport._claude`, process creation at line 480.
- [tools/cycle_transport.py](../tools/cycle_transport.py): diagnostic save in `finally`, lines 696-711.
- [tools/focus_diagnostics.py](../tools/focus_diagnostics.py): `instruction_files`, lines 334-358.
- [tools/focus_diagnostics.py](../tools/focus_diagnostics.py): instruction comparison in `refusal_history`, lines 553-557.

### Observed behavior

`Transport._claude` starts the provider before it records the instruction-file hashes.
After `process.close()`, its `finally` block constructs `metadata["launch"]`.
That block calls:

```python
"instruction_files": instruction_files(self.root, role not in PAIR_READONLY),
```

`instruction_files` reads the current filesystem contents at that time.
It does not reconstruct the files that existed at launch.
The stored field therefore describes completion-time files under a launch label.

This finding follows from source inspection. A live provider reproduction was not performed.

### Failure scenario and impact

1. A candidate `CLAUDE.md` file contains version A when the invocation starts.
2. During the invocation, an operator or project operation changes the file to version B.
3. At completion, `instruction_files` reads version B.
4. The runtime saves the hash of B under `launch.instruction_files`.
5. `refusal_history` compares that hash with other invocation records.

The comparison can attribute a refusal to instructions that were absent at launch.
Deletion during the invocation can also remove a file from the recorded launch list.
This error can hide or invent an instruction change between invocations.

A filesystem snapshot alone does not prove which instructions Claude actually loaded.
A resumed session can retain earlier context. Imports and later reads can also differ from the initial candidate files.
Diagnostic output must preserve this distinction after the timing correction.

### Proposed correction

1. Capture the candidate instruction-file hashes before process creation and before the first request.
2. Retain that snapshot for the lifetime of the invocation.
3. Save the retained snapshot under the launch metadata.
4. If completion-time comparison is useful, record it separately with explicit timing.
5. Keep the timing of legacy records unknown unless separate evidence establishes it.
6. Preserve bounded reads, metadata-only output, and the disabled collection for paired inspectors.
7. Keep diagnostic failures from replacing the original provider or containment error.

Do not describe candidate files as confirmed loaded instructions.
The native-log inspection can supply separate observations when those records exist.
No additional provider invocation is necessary to collect these file hashes.

### Acceptance checks

Use a fake process and temporary files for these checks:

- The process changes A to B. The launch record retains the hash of A.
- The process deletes the file. The launch record retains the original entry.
- An unchanged file has the same initial and final hash.
- Paired inspectors still record an empty candidate list.
- Saved diagnostics contain hashes and metadata, without instruction text or credentials.
- Refusals and incomplete runs preserve the initial snapshot when it is available.
- Diagnostic collection does not change the existing precedence of provider and containment failures.
- Legacy hashes do not acquire an unsupported claim about their collection time.

## Verification already completed

The preceding review completed 46 targeted tests:

| Test file | Passed |
| --- | ---: |
| `tests/test_focus_refusals.py` | 8 |
| `tests/test_focus_report_accounting.py` | 9 |
| `tests/test_focus_instructions.py` | 11 |
| `tests/test_focus_diagnostics.py` | 18 |

The instruction checker also passed for 64 blocks and 811 sentences.
These results describe the reviewed implementation before either proposed correction.
They do not establish coverage for these two defects.
DIAG-01 has an additional isolated counterexample above. DIAG-02 has source-level evidence and a proposed regression scenario.

## Handoff limits

The next change can address these two diagnostic findings within Orchestra.
Preserve the working correction that removed the duplicated Claude writing contract.
Do not restore that contract or change models, efforts, permissions, or review routes as part of these corrections.
Keep consuming projects and their `.work/cycle` records unchanged.
Use temporary repositories and fake providers for regression checks.

## Resolution

Resolution date: 2026-10-12.

DIAG-01 correction:

- `scan_claude_invocation` adds the terminal `result` metadata and a `completed` flag to each row.
- `completed` needs subtype `success`, `is_error=false`, no refusal stop reason, and no refusal record.
- The onset reference uses completed rows only. Its field is now `last_completed_before`.
- The same-role preference and the fallback use completed rows only. Without one, the reference is `null`.
- The report version is now 2. The report limits state that the reference is not runtime acceptance.
- The bulk scan keeps terminal result frames that quote a skipped marker.

DIAG-02 correction:

- `Transport.instruction_snapshot` hashes the candidate files before the process starts.
- The launch record keeps that snapshot and adds `instruction_files_captured: before-start`.
- A separate `completion` record hashes the candidates again after the process stops.
- A snapshot failure records `null`. It does not stop the run or replace a provider or containment error.
- Rows without the marker report `unknown` timing. Their completion-time hashes keep no launch claim.
- `diagnose` shows the capture timing and the completion hashes with the same strict projection.

Follow-up corrections from the review of these changes:

- Retained provider strings replace lone surrogates. A diagnostic failure cannot replace the run result.
- The runtime computes the transport hash before it starts the process.
- Each native conversation in a reused invocation directory is a separate attempt.
- A refusal before the init event still names its session.
- Named prompt paragraphs come only from the current runtime instructions.
- The session list names unfinished paired readers that hold a refused conversation.
- The transport writes an attempt record before each Claude process. The history splits the log at these records.
- The launch record names its attempt. Other attempts in the same directory get no launch metadata.
- A refusal before the init event appears in the history.
- An attempt without a known start time is not used for the onset part.
- Completion-time hashes of older records appear under `instruction_files_timing_unknown`.
- A comparison with a paired inspector, which loads no instruction files, compares no file hashes.
- A later turn without its own result makes the attempt incomplete.
- A result that waits for native tasks or queued turns is not a completion.
- An unknown role gets no same-role preference.
- Native log hints and checks use the process directory and the saved session of the attempt.
- The runtime also rejects `correct`, `recover` and `reconcile --apply-plan` while a refused role session that they keep is selected.
- The user instruction file appears once, also for a project under the home directory.
- A bulk scan keeps attempt records, init events and task events. A quoted skip marker cannot hide them.
- It skips only frames whose event type is a streamed delta or a tool result, not text that names them.
- The session list counts invocations and attempts separately.
- A native log named after the session of an earlier attempt selects that attempt.

The same review also covered the executor accounting correction in `cycle_workflow.py`:

- Only pair executors get the counter correction. Other roles keep the blocker and their guards.
- An accepted correction also consumes its original invocation, so discovery cannot adopt it again.
- A failed correction of changed files is not replayed. The heal resets the stale pair.
- The executor correction prompt names the editable fields and includes the original report.
- A correction of an original without changed files sets all counters to 0 and substantial=false.
- Discovery skips a changed late-pair test run whose valid report claims fixes. The heal then resets the stale pair.
- Discovery also skips any test run that changed more than existing documentation files.
- An executor without changed files but with counters gets one correction to zero counters.
- A failed correction of a test run without changed files still replays. The tests do not run again.
- The storage-repair retry dates a corrected test run by its original invocation.

Regression tests:

- `tests/test_focus_refusals.py` covers error results, missing results, refusal results, and refusal notices.
- The same file covers the role preference, the fallback, a `null` reference, quoted markers, and legacy timing.
- `tests/test_cycle.py` covers a changed file, a deleted file, an unchanged file, and a refusal with a change.
- It also covers empty lists for paired inspectors and a snapshot failure during a refusal.
- With the renamed field `last_completed_before`, the reproduction above now selects `null`.

## Writing assessment

This document follows the [repository style policy](instruction-style.md).
The assessment covers new prose. Exact code, paths, field names, and identifiers retain their machine meanings.
It uses the rule mapping in the [existing assessment](focus-instruction-style-audit.md).
It does not claim official certification or a complete dictionary review.

Result: **42 satisfied rules / 50 applicable rules = 84 percent**.
Eight unchecked applicable rules count as unsatisfied. Three rules do not apply.
Each listed rule has the status and evidence in its row.

| Rules | Status | Evidence or limitation |
| --- | --- | --- |
| 1.1, 1.2, 1.3, 1.4, 1.6 | Unchecked | A complete dictionary, meaning, part-of-speech, and inflection review remains incomplete. |
| 1.5 | Satisfied | Technical nouns identify software components, files, and protocol fields. |
| 1.7, 1.8 | Satisfied | Technical nouns retain established software meanings and noun use. |
| 1.9, 1.10, 1.11 | Satisfied | Terms remain short, consistent, and free of slang. |
| 1.12, 1.13 | Satisfied | Technical verbs describe software operations. Prose distinguishes operations from data. |
| 1.14 | Satisfied | Prose uses US forms, including behavior. Exact identifiers remain unchanged. |
| 2.1, 2.2 | Satisfied | Short noun groups and prepositions separate complex concepts. |
| 3.1, 3.5 | Unchecked | A complete review of verb inflections and participial forms remains incomplete. |
| 3.2, 3.3, 3.4 | Satisfied | Instructions use imperatives. Descriptions use simple forms and direct modifiers. |
| 3.6, 3.7 | Satisfied | Named functions perform actions. Correction steps use direct verbs. |
| 4.1, 4.2 | Satisfied | Short sentences retain necessary articles and conditions. Prose has no contractions. |
| 4.3, 4.4, 4.5 | Satisfied | Lists separate scenarios and checks. Repeated terms and articles connect related facts. |
| 5.1, 5.2, 5.3 | Satisfied | Instruction sentences contain one action and at most 20 words. |
| 5.4, 5.5 | Satisfied | Correction conditions precede actions. Observations remain separate from instructions. |
| 6.1, 6.2, 6.3 | Satisfied | Each finding starts with scope and evidence. Descriptive sentences have at most 25 words. |
| 6.4, 6.5, 6.6 | Satisfied | Paragraphs cover one subject and contain at most six sentences. |
| 7.1, 7.2, 7.3 | Not applicable | This report contains no physical hazard or equipment safety procedure. |
| 8.1, 8.2, 8.3, 8.4 | Satisfied | Prose has no semicolons. Modifiers, parentheses, and list boundaries have clear uses. |
| 8.5, 8.6, 8.7 | Satisfied | Word counts treat machine literals, numbers, and hyphenated terms as units. |
| 9.1 | Satisfied | The report separates observations, effects, correction proposals, and acceptance checks. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3, 9.4 | Satisfied | Instructions use direct verbs and the shared English writing policy. |

The resolution section uses the same rule mapping. It does not change the result.
The semantic check preserves both findings and their evidence limits.
It keeps proposed corrections distinct from completed work.
It preserves project boundaries and the existing workflow.
