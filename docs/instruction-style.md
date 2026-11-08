# Instruction and knowledge style

Use [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf) as the writing reference.
Apply this policy to new instructions and knowledge text, including changed passages in existing files.
Write that text in English unless the user explicitly requests another language.
Keep the user's language for ordinary conversation.
Do not translate exact quotes, code, identifiers, or required labels.

## Preserve behavior

Keep every requirement, prohibition, condition, exception, sequence, owner, and numeric limit.
Keep commands, paths, model names, efforts, JSON fields, and protocol markers exact.
Style rules do not grant authority or change role boundaries.
Do not remove necessary meaning to improve a style score.
Record a necessary style exception instead.

## Write clear prose

Give one action in each instruction sentence.
Use direct command verbs and active voice.
Put a necessary condition before its action.
Use at most 20 words in instruction sentences and 25 words in descriptions.
Do not omit articles or other necessary words to reduce length.
Do not use contractions or semicolons in prose.

Use one term for one concept.
Prefer approved words and their approved meanings.
Use technical nouns and technical verbs only for their documented technical meanings.
Do not use a technical noun as a verb.
Avoid long noun groups, idioms, and ambiguous pronouns.

Keep each paragraph on one subject, with at most six sentences.
Use lists for branches, alternatives, and separate steps.
Keep information in the order that the reader needs it.
Use notes for information, not commands.
Rewrite a sentence when word substitution cannot make it clear.

## Assess the 80 percent target

STE does not define a universal percentage score.
This repository uses an internal rule assessment, not an official certificate.
Assess all 53 Issue 9 rules against the changed instruction corpus.
For each rule, record satisfied, unsatisfied, unchecked, or not applicable.
Give evidence for satisfied rules and reasons for exclusions.

Calculate the score as satisfied rules divided by applicable rules, multiplied by 100.
Count unchecked applicable rules as unsatisfied.
Do not exclude a rule merely because it is difficult to check.
The minimum score is 80 percent.
A lost requirement or changed permission fails acceptance regardless of the language score.

Keep the rule assessment with the change evidence.
See the [initial cc-focus assessment](focus-instruction-style-audit.md) for the rule table and known limitations.
List technical terms and any necessary deviations.
Do not report sentence length alone as STE compliance.
A dictionary review can remain incomplete only if the score still meets the target with those rules unsatisfied.
For another required language, apply the clarity rules without claiming English compliance.

## Technical terms

Use these terms consistently in cc-focus instructions.
Exact identifiers retain their runtime definitions.

| Term | Meaning |
| --- | --- |
| stage | A project-plan unit selected for the current development work. |
| phase | A runtime step within that work, such as code, review, or publication. |
| invocation | One recorded call to a provider role. |
| candidate | The exact project snapshot under review or verification. |
| snapshot | A recorded file set, content fingerprints, HEAD, and index state. |
| finding | A reported defect or verification obligation. |
| assignment | An accepted action for one finding. |
| resolution | An executor's account of that assignment's result. |
| evidence | Recorded observations that support a claim. |
| clean pass | A completed review that meets its existing runtime criteria. |
| significant | Blocking, or with critical, high, or medium severity in paired review. |
| substantial | A change to contracts, core algorithms, workflows, permission boundaries, or intended test outcomes. |
| handoff | Recorded context transferred between work steps. |
| pair | The assigned reviewers and their communication protocol. |
| inner gate | Required static review and tests before a late repair returns to its outer pair. |
| publication | Runtime-controlled staging, commit, push, and subsequent CI handling. |
| schema | The exact structure and constraints of a machine-readable object. |
| project brief | Operator text about the purpose, direction, users, priorities, limits, and milestone goal of a project. It adds no requirement, task, or stage. |
| milestone goal | The intended result of the current milestone and its reason, without status or dates. |
| fingerprint, hash, digest | Exact algorithm-specific content identifiers. Preserve existing protocol names. |
| diff, commit, push, rebase, staging, worktree | Git concepts or operations with their existing Git meanings. |
| build, test, runtime, provider, executor, arbiter | Software operations and roles with their existing runtime meanings. |

Use technical verbs such as compile, build, commit, and push only for those software operations.
Do not use these terms as general substitutes for ordinary verbs.

## Check cc-focus changes

Run `python3 -B tools/check_focus_instructions.py` for the measurable prose checks.
The checker covers canonical contracts and additional provider assignments, including recovery and report correction.
It excludes operator content, project data, terminal messages, diagnostic errors, and immutable historical records.
It uses a conservative 20-word limit for both instructions and descriptions.
It does not validate the full dictionary, grammar, semantic equivalence, or official certification.

Review semantic equivalence separately.
Run affected workflow and transport tests.
Check models, efforts, schemas, markers, permission boundaries, and saved-session behavior.
A wording-only change must not erase review credit or restart a completed operation.

The compatibility map in `focus_pair_jobs.py` accepts only known earlier pair contracts.
The style revision can also change named instruction fields.
The test scope revision adds only the `full_run` and `final_gate` assignment fields.
All task data, operator messages, corrections, role identities, and numeric types must still match.
The runtime keeps the saved prompt unchanged.
New jobs use the current text.
Historical fixtures retain the original text as evidence, not as instructions for new work.

## User rules

The operator's global rules apply to future work across repositories.
Codex loads them from its user-level AGENTS.md file.
Claude uses its user-level CLAUDE.md file.
Keep existing user rules when you add this policy.
Do not change permission settings to install a writing rule.

See the [Codex instruction guide](https://developers.openai.com/codex/guides/agents-md) for global instruction discovery.
