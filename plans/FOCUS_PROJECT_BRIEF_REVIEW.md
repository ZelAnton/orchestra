# Project brief plan review

Scope: revisions 8 through 13 of [the implementation plan](FOCUS_PROJECT_BRIEF_PLAN.md).
This review changes the plan only. Runtime implementation and runtime acceptance tests remain pending.
The sections before "Review after revision 8" describe the review of revision 8.

The input was revision 7, with SHA-256 `dd14258ed3d3dac8de070a261c6033c0598bae74b09af97ffc5777676f34c953`.
Its header reported two clean passes from each of two earlier reviewers.
This record describes the additional sequential review of that input. It does not repeat or certify the earlier reviews.

## Findings and corrections

| ID | Finding | Correction |
| --- | --- | --- |
| B1 | A wrong stage iteration silently removed the brief. | D3 and D9 distinguish an absent legacy field from an invalid present record. D4 defines explicit replacement. |
| B2 | The failure guarantee ignored lease saves and automatic development handover. | D4 separates acceptance from workflow startup. It preserves workflow fields while allowing existing lease bookkeeping. |
| B3 | The refusal recovery commands selected development during an unfinished review campaign. | D4 supplies the campaign commands and keeps the run ID throughout recovery. |
| B4 | A completed-run handoff could reuse conversations with a replaced brief. | D3 retires those sessions when the effective hash changes. Equal hashes retain existing behavior. |
| B5 | Pointer formats, concurrent writes, and interrupted storage lacked exact acceptance rules. | D6 and D9 define schemas, limits, path checks, atomic ordering, and restoration of exact bytes. |
| B6 | Pair writers and completed evidence had no explicit brief binding. | D5 and D10 bind writers to their pair hash and record the hash in new evidence. |
| B7 | Source inspection and status before the first run were underspecified. | D6 separates source observations from copy integrity. Ordinary status never reads the source. |
| B8 | Future direction could affect current acceptance criteria. The severity rule also needed a clearer boundary. | D2 and D7 separate aspirations from obligations. Actual effects and binding requirements determine severity. |
| B9 | The byte limit was described as an approximate maximum token count. | The risk section states that the token count depends on content and language. |
| B10 | The equal-hash refusal could prevent replacement of a malformed stage record. | D4 applies this refusal only to a valid stage record. The tests include an invalid iteration with the same hash. |

The second review refined B2 and B4.
An explicit correction can retire a pending wait, but it must not retry a provider or shorten that wait.
A handoff restart with the same brief must retain the existing session behavior.
That review also removed the token-count claim in B9.

## Source checks

These checks inspect existing code. They do not imply that the planned feature exists.

| Source | Checked behavior |
| --- | --- |
| [cc_focus.py](../tools/cc_focus.py) | Admission, handover, leases, session replacement, campaign selection, and error handlers. |
| [cycle_state.py](../tools/cycle_state.py) | Atomic file replacement, state envelopes, lease saves, and control-store paths. |
| [cycle_workflow.py](../tools/cycle_workflow.py) | Stage starts, corrections, report reuse, phase boundaries, and session generations. |
| [focus_review_run.py](../tools/focus_review_run.py) | Campaign creation, target transitions, evidence, and development handover. |
| [focus_project.py](../tools/focus_project.py) | Project membership, member ownership, locks, and snapshot exclusions. |
| [focus_pairs.py](../tools/focus_pairs.py) | Pair inputs, separate jobs, conclusions, and final-pair independence. |
| [focus_pair_repair.py](../tools/focus_pair_repair.py) | Inner readers, the final gate, writer context, and repair seals. |
| [focus_pair_jobs.py](../tools/focus_pair_jobs.py) | Saved prompt equality, session ownership, and report corrections. |
| [focus-runtime.ps1](../tools/focus-runtime.ps1) | Direct commands and contained workflow commands. |

## Review passes

| Pass | Scope | Result |
| --- | --- | --- |
| 1 | Authority, stage capture, persistence, role delivery, and recovery commands. | Findings B1 through B8 corrected. |
| 2 | Failure paths, compatibility, and the revised requirements. | B2 and B4 refined. B9 corrected. |
| 3 | Stage transitions, old records, role delivery, and publication boundaries. | Clean. No new findings. |
| 4 | Recovery remedies against every refusal condition. | B10 corrected. The clean-pass count restarts. |
| 5 | Complete lifecycle, command routing, compatibility, and the future prompt constants. | Clean. No new findings. |
| 6 | Concurrency, failed persistence, role boundaries, recovery remedies, and acceptance coverage. | Clean. No new findings. |

Passes 5 and 6 meet the requested two consecutive clean passes.
The final document check covers local links, whitespace, changed prose, and the future prompt constants.

No provider, project workflow, build, or application test was started for this plan review.
Implementation tests in the plan are future acceptance requirements.

## Instruction style assessment

The scope is the added and replaced prose in revision 8, including this review record.
Unchanged revision 7 prose, exact commands, identifiers, and user text are outside this changed corpus.
The reference is ASD-STE100 Issue 9, under [the repository policy](../docs/instruction-style.md).
The local Issue 9 reference and the existing rule assessment supplied the rule definitions.

The assessment below records all 53 rules.
Unchecked applicable rules count as unsatisfied. Physical safety-warning rules do not apply to this software design document.
The internal score is 40 satisfied rules out of 50 applicable rules: 80 percent.
This is not certification or a complete dictionary audit.

Technical nouns include brief, pointer, hash, runtime, stage, pair, campaign, lease, snapshot, schema, and invocation.
A pointer selects the default brief for future stages. A stage record identifies the brief captured for one stage.
A pair record identifies the input shared by its reviewers and executor.
These terms retain the meanings in the plan and the existing runtime documentation.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A complete dictionary check is pending. |
| 1.2 | Unchecked | Approved parts of speech were not checked for every word. |
| 1.3 | Unchecked | Approved meanings were not checked for every word. |
| 1.4 | Unchecked | Approved word forms were not checked completely. |
| 1.5 | Satisfied | Technical nouns describe software state, storage, and agent roles. |
| 1.6 | Unchecked | Every ordinary word was not classified against the dictionary. |
| 1.7 | Satisfied | Technical nouns retain noun use. Software actions use established verbs. |
| 1.8 | Satisfied | Terms match the repository runtime and its documentation. |
| 1.9 | Satisfied | Short terms such as brief, hash, pointer, and stage identify the main concepts. |
| 1.10 | Satisfied | The changed prose uses no slang or regional technical nouns. |
| 1.11 | Satisfied | Pointer, stage record, pair record, and copy have distinct meanings. |
| 1.12 | Satisfied | Store, decode, verify, and synchronize describe relevant technical operations. |
| 1.13 | Satisfied | Operation nouns retain their established software meanings. |
| 1.14 | Satisfied | Changed prose uses US spelling. Machine identifiers remain exact. |
| 2.1 | Satisfied | Added prose uses short noun groups. Exact identifiers are marked as code. |
| 2.2 | Satisfied | Longer relationships use prepositions and complete technical names. |
| 3.1 | Unchecked | A complete check of approved verb forms is pending. |
| 3.2 | Satisfied | Descriptions use simple tenses. Instructions use the imperative. |
| 3.3 | Satisfied | Past participles modify their related records, inputs, and results. |
| 3.4 | Satisfied | Changed prose avoids complex auxiliary chains. |
| 3.5 | Unsatisfied | Some conditions retain forms such as before constructing and after decoding. |
| 3.6 | Satisfied | Instructions name the actor or use the imperative. Passive descriptions concern saved evidence. |
| 3.7 | Unsatisfied | Technical nominal forms such as atomic replacement remain. |
| 4.1 | Satisfied | Changed passages use short sentences and separate conditions. |
| 4.2 | Satisfied | Articles and necessary words remain. No contractions were added. |
| 4.3 | Satisfied | Lists and tables separate commands, branches, fields, and checks. |
| 4.4 | Satisfied | Before, after, then, and when connect related actions. |
| 4.5 | Satisfied | Articles and demonstratives identify the applicable stage, record, and copy. |
| 5.1 | Satisfied | Added instruction sentences meet the conservative 20-word check. |
| 5.2 | Satisfied | Separate sentences identify separate commands. |
| 5.3 | Satisfied | Instructions use direct commands. Design descriptions remain separate. |
| 5.4 | Unsatisfied | Some timing conditions follow the action, such as before any read or write. |
| 5.5 | Satisfied | No note conceals a required command. |
| 6.1 | Satisfied | Goals precede commands, persistence, delivery, and acceptance checks. |
| 6.2 | Satisfied | The same stage, pair, and pointer terms connect the sections. |
| 6.3 | Satisfied | Added descriptions meet the 25-word limit. |
| 6.4 | Satisfied | Separate paragraphs describe capture, replacement, recovery, and evidence. |
| 6.5 | Satisfied | Each added paragraph covers one subject. |
| 6.6 | Satisfied | Added paragraphs have at most six sentences. |
| 7.1 | Not applicable | The document specifies no physical safety-warning procedure. |
| 7.2 | Not applicable | No physical safety command is introduced. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. Data-preservation requirements remain mandatory. |
| 8.1 | Satisfied | Changed prose has no semicolons. |
| 8.2 | Satisfied | Necessary compound modifiers retain conventional forms. |
| 8.3 | Satisfied | Parentheses do not contain hidden instructions. |
| 8.4 | Satisfied | List items separate conditions and acceptance checks. |
| 8.5 | Satisfied | The local counter treats parenthetical expressions as units. |
| 8.6 | Satisfied | Quoted machine literals remain exact and count as units. |
| 8.7 | Satisfied | The local counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | A separate semantic review checks requirements and compatibility. |
| 9.2 | Unchecked | The full lexical and meaning assessment remains incomplete. |
| 9.3 | Satisfied | Direct verbs replace avoidable abstract expressions in changed instructions. |
| 9.4 | Satisfied | Changed instructions and knowledge use the same English style policy. |

The semantic review preserves operator ownership, independent final inputs, and the existing model and test policies.
It adds explicit recovery and persistence requirements without granting provider roles new authority.

## Review after revision 8

Scope: the changes after revision 8, and complete reviews of the later revisions.
The input was revision 8, with SHA-256 `e93ffa5fc8041b494f0450869b79748aa04ac46994d230c4b849c44d4b6796b9`.
Revision 9 has SHA-256 `42fbb10b6fe2ada90bd57bb37ea641647e89ce66028472ffdaca80540f893ece`.
Revision 10 has SHA-256 `b433051d895acf6de2043e0236c76afb3c6bc5f534c0569fb7e8d32613952945`.
Revision 11 has SHA-256 `84a35c7ddf1977863ef147e9578ff23ae1298d2d2e3d4434f524756f3ad4c7fb`.
Revision 12 has SHA-256 `60332342ef3daae84342bd34b25026dde0f69c080e7eebbdb85151e3c2784dc3`.

R1 through R4 are defects in revision 8.
Thus the clean result of passes 5 and 6 above applies to revision 8 only. It does not apply to the later revisions.

### Findings in revision 8, corrected in revision 9

| ID | Finding | Correction |
| --- | --- | --- |
| R1 | `apply` without the review handover changed the development state. `hand_back` then skipped the completed campaign permanently. | D4 runs the existing handover of `main` first, as `correct` does. |
| R2 | A handler that saves the old status could overwrite a committed correction after a failed directory synchronization. | For `apply`, the inner error handlers of `main` do not save the workflow state. |
| R3 | After a handover started a stage with the current pointer, `apply` refused an already active brief. | An equal hash of a valid record changes nothing and exits with code 0. |
| R4 | The `--handoff` restart did not define the comparison with an absent or malformed stage record. | An absent legacy record counts as null. A malformed record counts as a different hash. |
| R5 | The rule sentence "The brief cannot excuse" described a capability in a list of commands. | The rule uses a command that forbids dismissal and a lower severity. |

### Findings in revision 9, corrected in revision 10

| ID | Finding | Correction |
| --- | --- | --- |
| S1 | The direct update ignored saved role sessions that still contained the old brief. | The direct update also requires no saved session of a role that receives the brief. |
| S2 | A `brief_change` correction in the code phase set `correction_pending`. A later `complete` report was then refused. | The `brief_change` key suppresses `correction_pending`. |
| S3 | The restore of a damaged copy through `set` also replaced a pending default. | The new action `brief restore` writes only a copy whose hash a pointer or stage record names. |
| S4 | `show` followed `active.json` and could not show the development record after a campaign. | `show` prints the development record and the record of an unfinished campaign. |
| S5 | In a campaign, the refusal message of `apply` named the development command. | The message names the campaign commands. |
| S6 | The precedence list did not name the review scope. | The rule and the Goal name the review scope. |
| S7 | Corrections remain for the iteration. A removal text could disagree with a brief after a later restart. | One conditional text, `BRIEF_CHANGE_CORRECTION`, replaces the two texts. |
| S8 | The order of the equal-hash exit and the refusals was not defined. | D4 defines the order of all checks. |
| S9 | The relaxed root check seemed to cover `apply`. | The relaxed check covers only `set`, `restore`, `clear`, and `show`. |
| S10 | `brief-drift` used the consent and account reason of `MANUAL_BLOCKERS`. | `brief-drift` has its own escalation reason `brief-input`. |
| S11 | A FIFO source could block `set` before the regular-file check. | `set` checks with `lstat`, opens with `O_NONBLOCK`, and verifies with `fstat`. |
| S12 | `status` printed JSON without terminal escaping. | `show` and `status` apply `terminal_text` to paths and operator text. |
| S13 | The tests did not cover many stated requirements, and the risk text was broader than the rule. | The tests cover the listed requirements. The risk text uses the exact rule scope. |
| S14 | Revision 9 prose had semicolons and paragraphs with seven sentences. | Revision 10 has no semicolons and at most six sentences in each paragraph. |

Revision 10 also has smaller changes without a row.
They cover the lease-release rule, the rollback text, the damaged-record remedy, the D6 stop points, the D3 legacy write, and step 2.

### Findings in revision 10, corrected in revision 11

| ID | Finding | Correction |
| --- | --- | --- |
| T1 | The suppression of `correction_pending` could clear the guard of an earlier operator correction. | A brief change sets no new ID and keeps an existing value. |
| T2 | A brief entry recorded after coding started could give a restarted stage the same-stage selection text. | Brief entries have `brief_change: true`. Selection text, instructions, and `publication_recovery` use only task corrections. Brief entries arrive as `project_brief_notice`. |
| T3 | The read flags `O_NOFOLLOW` and `O_NONBLOCK` do not exist on Windows. | D9 defines a POSIX path and a Windows path with the same `lstat` and `fstat` identity check. |
| T4 | Some changed instruction sentences joined two commands with "then". | Each instruction sentence gives one command. Command sequences use numbered lists. |
| T5 | The order of checks omitted the admission checks and the place of the equal-hash exit. | Step 0 lists the admission checks. Step 4 runs before `control.begin()`. |
| T6 | `restore` with an unreadable source or a malformed pointer was not defined. | `restore` skips an unreadable source with a notice. It refuses only when no readable source names the hash. |
| T7 | Some tests and record details were missing, and the coordination text named `correct` instead of `record_correction`. | The tests, the record, and the D4 text are corrected. |

### Cosmetic corrections in revision 12

Revision 12 applies the cosmetic findings of pass 3. They do not change the clean-pass count.

- D4 defines task corrections. `operator_corrections` lists only task corrections.
- Pair contexts keep the `corrections` key, also as an empty list. Step 6 names the changed pair contexts.
- D6 names the review-handover exception for a malformed pointer.
- D7 requires a `_STYLE_TEXT` entry before a later change of the two constants.
- D6 splits one sentence with two prohibitions.

### Follow-up work outside this plan

- `correct` and `reconcile` can save an earlier state after a failed directory synchronization.
- `recover` does not restore its in-memory change after a failed save. The handler then saves the recovered state as `interrupted`.
- `correct` on a completed state saves `interrupted`. On a completed campaign, the campaign then counts as unfinished.
- In a campaign, the `refusal-retry` message of `correct` named the development command. The implementation fixes it for every command that keeps sessions.

### Review passes

| Pass | Scope | Result |
| --- | --- | --- |
| 1 | Revision 9: design against the code, and semantics with text. | Not clean. Findings S1 through S14. |
| 2 | Revision 10: design against the code, and semantics with text. | Not clean. Findings T1 through T7. |
| 3 | Revision 11: design against the code, and semantics with text. | Clean. Cosmetic findings only. |
| 4 | Revision 12: design against the code, and semantics with text. | Clean. The design review had no findings. The semantic review had cosmetic findings only. |

Passes 3 and 4 give two consecutive clean passes for each reviewer.
Revision 13 applies the cosmetic findings of pass 4:

- D4 says that non-pair contexts omit `operator_corrections` and `correction_pending` without a task correction.
- Step 6 gives the two pair-context edits in separate sentences.
- This record gives the hashes of revisions 11 and 12.

### Instruction style assessment for revisions 9 through 13

The scope is the added and replaced prose after revision 8, including this section.
Unchanged prose, exact commands, identifiers, and quoted user text are outside this changed corpus.
The reference and the counting method are the same as in the revision 8 assessment above.
The internal score is 40 satisfied rules out of 50 applicable rules: 80 percent.
This is not certification or a complete dictionary audit.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A complete dictionary check is pending. |
| 1.2 | Unchecked | Approved parts of speech were not checked for every word. |
| 1.3 | Unchecked | Approved meanings were not checked for every word. |
| 1.4 | Unchecked | Approved word forms were not checked completely. |
| 1.5 | Satisfied | Technical nouns describe runtime state, storage, commands, and roles. |
| 1.6 | Unchecked | Every ordinary word was not classified against the dictionary. |
| 1.7 | Satisfied | Technical nouns keep their noun use. Commands keep their exact names. |
| 1.8 | Satisfied | Terms match the runtime code and the earlier sections of the plan. |
| 1.9 | Satisfied | Short terms such as restore, pointer, record, and handover name the main concepts. |
| 1.10 | Satisfied | The changed prose uses no slang or regional technical nouns. |
| 1.11 | Satisfied | Restore, set, and clear have distinct meanings. Direct update and correction are distinct paths. |
| 1.12 | Satisfied | Verbs such as store, verify, and reread describe the technical operations. |
| 1.13 | Satisfied | Operation nouns keep their established software meanings. |
| 1.14 | Satisfied | The changed prose uses US spelling. |
| 2.1 | Satisfied | Noun groups are short. Exact identifiers are marked as code. |
| 2.2 | Satisfied | Longer relations use prepositions, for example the stage record of an unfinished campaign. |
| 3.1 | Unchecked | A complete check of approved verb forms is pending. |
| 3.2 | Satisfied | Descriptions use simple tenses. Instructions use the imperative. |
| 3.3 | Satisfied | Past participles modify their nouns, for example saved blocker and captured hash. |
| 3.4 | Satisfied | The changed prose has no complex auxiliary chains. |
| 3.5 | Unsatisfied | Some forms such as "without workflow startup" and "after the lease is acquired" remain. |
| 3.6 | Satisfied | Instructions name the actor or use the imperative. |
| 3.7 | Unsatisfied | Nominal forms such as "pointer capture" and "acceptance route" remain. |
| 4.1 | Satisfied | Sentences are short, and lists separate the conditions. |
| 4.2 | Satisfied | Articles and necessary words remain. There are no contractions. |
| 4.3 | Satisfied | Numbered lists give the order of checks and the recovery commands. |
| 4.4 | Satisfied | Then, before, and after connect related actions. |
| 4.5 | Satisfied | Articles and demonstratives identify the stage, record, copy, and run. |
| 5.1 | Satisfied | The changed instruction sentences have at most 20 words. |
| 5.2 | Satisfied | Each changed instruction sentence gives one command. Command sequences use numbered lists. |
| 5.3 | Satisfied | Instructions use direct commands. Descriptions stay separate. |
| 5.4 | Unchecked | A complete check of condition placement in every changed instruction is pending. |
| 5.5 | Satisfied | No note contains a required command. |
| 6.1 | Satisfied | Each D4 subsection starts with its subject and then gives the details. |
| 6.2 | Satisfied | The same terms connect D1, D4, D6, D9, and the tests. |
| 6.3 | Satisfied | The changed descriptions have at most 25 words. |
| 6.4 | Satisfied | Subsections separate scope, checks, messages, persistence, and paths. |
| 6.5 | Satisfied | Each paragraph and list item covers one subject. |
| 6.6 | Satisfied | Each paragraph and list item has at most six sentences. |
| 7.1 | Not applicable | The document specifies no physical safety-warning procedure. |
| 7.2 | Not applicable | No physical safety command is introduced. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The plan has no semicolons. |
| 8.2 | Satisfied | Compound modifiers keep conventional forms. |
| 8.3 | Satisfied | Parentheses contain no hidden instructions. |
| 8.4 | Satisfied | List items separate conditions, checks, and tests. |
| 8.5 | Satisfied | The local counter treats parenthetical expressions as units. |
| 8.6 | Satisfied | Quoted machine literals stay exact and count as units. |
| 8.7 | Satisfied | The local counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | A separate semantic review checks requirements and compatibility. |
| 9.2 | Unchecked | The full lexical and meaning assessment is incomplete. |
| 9.3 | Satisfied | Direct verbs replace avoidable abstract expressions in the changed instructions. |
| 9.4 | Satisfied | The changed plan and this record use the same English style policy. |
