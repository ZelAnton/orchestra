# cc-focus instruction assessment

## Publication selection addition, 2026-10-14

The added corpus covers selection instructions, the publication manifest rule, the command guide, and knowledge paragraphs.
The rule table below applies with the same seven unchecked and three unsatisfied rules.
The internal result is 40 satisfied rules out of 50 applicable rules: 80 percent.
This result is not certification.

New prose uses short sentences and separate paragraphs for selection, acceptance, and continuation.
The mechanical checker includes `focus_publication_scope.py`.
Technical terms include manifest, selection, ownership, fingerprint, and the existing Git terms.
Dictionary checks remain incomplete and count as unsatisfied.

Semantic review checks exact file ownership, protected work, model authority, and retained evidence.
The new command requires explicit operator acceptance and grants no review or publication credit.
Models, efforts, pair targets, and the existing no-progress guard remain unchanged.

## Review campaign addition, 2026-10-14

The added corpus covers the review contract, coordinator prompt, menu help, review guide, and new knowledge paragraphs.
The existing rule table applies with the same seven unchecked and three unsatisfied rules.
The internal result remains 40 satisfied rules out of 50 applicable rules: 80 percent.
This assessment is not certification.

The mechanical checker includes `focus_review_contract.py` and `focus_review_run.py`.
New instructions use imperative clauses, short sentences, and separate paragraphs for scope, evidence, and execution.
Technical terms include campaign, target, coverage, ID, snapshot, and the existing Git terms.
A campaign is a saved queue of review targets. Coverage records inspected requirements, paths, checks, and limitations.
Dictionary checks remain incomplete and count as unsatisfied.

Semantic review distinguishes the new review scope from the repair diff.
It preserves independent initial reports, bounded agreement, arbitration, repair gates, and publication authority.
Inner inspections keep their original scope. Normal development prompts and schemas remain unchanged.
New scope coverage is required only for independent outer reports in review campaigns.

Assessment date: 2026-10-11.
Reference: [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf).
Method: [the repository instruction policy](instruction-style.md).

The scope includes canonical cc-focus contracts, role prompts, and additional runtime assignments.
It includes the new writing policy and the new user-level rule.
It excludes code syntax, operator input, historical fixtures, and unchanged documentation.
Existing Russian knowledge text does not acquire a compliance claim from this change.

Result: **40 satisfied rules / 50 applicable rules = 80 percent**.
Seven applicable rules remain unchecked and count as failures.
Three applicable rules have known deviations and also count as failures.
Three rules do not apply to this corpus.
This is an internal assessment, not certification or a complete dictionary audit.

## Evidence

- The mechanical checker covers 60 canonical instruction blocks and 749 sentences.
  All checked sentences meet its conservative 20-word limit.
  All checked paragraphs have at most six sentences.
  The checker finds no contractions, semicolons, or Russian prose in these blocks.
- Manual inspection checks structure, grammar, technical terms, and the policy additions.
  The table records incomplete checks explicitly.
- A semantic comparison preserves the existing requirements and exceptions.
  Models, efforts, phase targets, schema constraints, and protocol markers are unchanged.
  Regression tests cover review routes, recovery, reports, and publication boundaries.
- Saved-job tests permit only the known wording revision at fixed instruction fields.
  They reject changed task data, authority, candidates, and numeric types.
  A resumed job keeps its original prompt, native session, and completed result.

## Rule assessment

The rule numbers identify the reference requirements.
The evidence column describes this corpus, not a replacement definition of the standard.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Necessary technical nouns describe software, Git, data, roles, and named products. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns retain noun use. Established software operations have separate technical verb meanings. |
| 1.8 | Satisfied | Terms such as snapshot, schema, commit, and runtime retain established software meanings. |
| 1.9 | Satisfied | The glossary uses short terms for the main runtime concepts. |
| 1.10 | Satisfied | Technical nouns do not use regional variants, slang, or invented informal labels. |
| 1.11 | Satisfied | Stage, phase, invocation, finding, assignment, and resolution keep distinct meanings. |
| 1.12 | Satisfied | Compile, build, commit, and push describe software operations. |
| 1.13 | Satisfied | Operation nouns use established software meanings. Technical verbs do not replace ordinary descriptive nouns. |
| 1.14 | Satisfied | Prose uses US forms, including behavior, authorized, and artifact. Exact names remain unchanged. |
| 2.1 | Satisfied | Ordinary noun groups remain short. Necessary protocol identifiers remain exact. |
| 2.2 | Satisfied | Longer concepts use prepositions, hyphens, or a defined short technical term. |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use simple present, past, or future forms. |
| 3.3 | Satisfied | Forms such as supplied and retained modify the relevant data or evidence. |
| 3.4 | Satisfied | The prose avoids complex chains of auxiliary verbs. |
| 3.5 | Unsatisfied | Some clauses retain forms such as without claiming and without repeating. |
| 3.6 | Satisfied | Named roles perform actions. Limited passive descriptions concern an unknown interruption or lost response. |
| 3.7 | Unsatisfied | Some instructions retain nominal phrases, including make binding decisions. |
| 4.1 | Satisfied | Long original clauses are split into short sentences without loss of their conditions. |
| 4.2 | Satisfied | Prose retains articles and necessary words. The mechanical contraction check passes. |
| 4.3 | Satisfied | Lists and structured assignment fields separate branches, findings, and return routes. |
| 4.4 | Satisfied | Then, otherwise, before, and after connect related steps. |
| 4.5 | Satisfied | Articles and demonstratives identify the current stage, candidate, report, and invocation. |
| 5.1 | Satisfied | All 749 checked instruction sentences meet the 20-word limit. |
| 5.2 | Satisfied | Independent actions use separate sentences. Lists within one prohibition retain that single prohibition. |
| 5.3 | Satisfied | Procedural steps use direct commands. Runtime descriptions are distinct from commands. |
| 5.4 | Unsatisfied | Some conditions remain after their action, including only when and unless clauses. |
| 5.5 | Satisfied | Reference information is separate from procedural commands. No note conceals a required action. |
| 6.1 | Satisfied | The contracts introduce scope and roles before transitions, reports, and exceptions. |
| 6.2 | Satisfied | Repeated role names and protocol terms connect related explanations. |
| 6.3 | Satisfied | Checked descriptive sentences also meet the stricter 20-word limit. |
| 6.4 | Satisfied | Related paragraphs group scope, review, repair, testing, and publication rules. |
| 6.5 | Satisfied | Each paragraph covers one procedural subject or a closely related exception. |
| 6.6 | Satisfied | The paragraph check finds no block with more than six sentences. |
| 7.1 | Not applicable | The corpus contains software workflow rules, with no physical hazard or equipment safety procedure. |
| 7.2 | Not applicable | No safety-warning procedure is introduced. Software permission guards remain mandatory operational rules. |
| 7.3 | Not applicable | No physical hazard warning needs a consequence statement. This exclusion does not waive data protection. |
| 8.1 | Satisfied | The prose checker finds no semicolons outside exact literals. |
| 8.2 | Satisfied | Necessary modifiers include read-only, report-only, and six-hour. |
| 8.3 | Satisfied | Parentheses identify names, exact symbols, units, or short explanations. |
| 8.4 | Satisfied | List introductions and separate items have their own sentence boundaries. |
| 8.5 | Satisfied | The counter treats parenthetical content as one unit. |
| 8.6 | Satisfied | The counter preserves quoted text and machine literals as units. Numeric forms remain exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. A regression test covers this rule. |
| 9.1 | Satisfied | Clauses and paragraphs were reconstructed, with a separate semantic comparison. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | Phrasal commands such as account for were replaced with direct verbs. |
| 9.4 | Satisfied | Shared contracts and the user rule use the same English writing policy. |

## Semantic review

The rewrite preserves project boundaries, protected work, operator authority, and read-only roles.
It preserves the optional handoff, current-plan selection, and treatment of interrupted work.
It preserves paired review, arbitration, repair effort selection, and the inner two-pass gate.
It preserves targeted checks, full-suite conditions, deferred work, and evidence-only exceptions.
It preserves per-invocation counters, report-only correction, runtime publication, and completion criteria.

The three known style deviations retain clear meaning.
They do not grant new authority or remove a required operation.
The unchecked dictionary rules remain visible in the score.
Future instruction changes need a new assessment of their changed scope.

## Stage completion pause addendum

Assessment date: 2026-10-14.
The scope covers the new stage-pause instructions in `docs/sequential-cycle.md`, `knowledge.md`, and terminal and CLI help.
The rule table above applies to this added text with the same results.
The assessment remains **40 satisfied rules / 50 applicable rules = 80 percent**.
Unchecked dictionary rules and the three conservative deviations still count as failures.
This is an internal assessment, not certification.

Manual review checks short sentences, active verbs, command order, and paragraphs with at most six sentences.
The technical terms stage, iteration, publication, CI, runtime, and provider keep their established meanings.
The new command schedules a pause after the existing publication and CI gates.
It does not change review targets, model settings, permissions, approval handling, or CI requirements.
Safe stop, emergency stop, and operator PAUSE retain their existing behavior.
The instructions distinguish scheduling, completion, cancellation, and explicit resumption.

## Stage pause resume addendum

Assessment date: 2026-10-15.
The scope covers the new and changed sentences about the resume after a completed-stage pause.
The sentences are in `docs/sequential-cycle.md`, `knowledge.md`, and `docs/focus-review.md`.
The scope also covers five new runtime messages: four blocker messages and the `stage-boundary` reason.

In `docs/sequential-cycle.md`, one older sentence now says that the runtime checks the completed stage.
Its paragraph becomes two paragraphs, one for cancellation and one for the resume.
Five new paragraphs and one list describe the new resume rules.

One new sentence in the recovery rules tells that a failure at this transition skips recovery.
One new sentence after the terminal reasons names a stage transition that needs the operator.
One new sentence tells that a remote query failure at this transition stops for the operator.
Its older paragraph about remote queries becomes three paragraphs with one subject each.

In `knowledge.md`, three new paragraphs tell the `assert_stage_base` rule, the `stage-boundary` reason, and the review run rules.
One new sentence in the paragraph about the `heal` role tells the exception at this transition.
The second sentence in the list of escalation reasons now also names a stage transition.
It also says "a repeated blocker" instead of "an already-attempted blocker".
That sentence has 16 words.

An older `knowledge.md` sentence said that the next stage cannot accept a changed index.
It becomes three sentences without a semicolon, and they name the completed-stage pause.
Its older long paragraph becomes 15 paragraphs with one subject each.
Two short paragraphs move after the protected staging paragraph, so the admission paragraph follows the reconcile paragraphs.
Their other sentences keep their wording.

In `docs/focus-review.md`, three new paragraphs tell review admission, the review stage pause, and the handover after pushed commits.

`tools/check_focus_instructions.py` does not scan runtime messages, so a manual check covers the five messages.
Each blocker message names the problem in its first sentence.
Each later instruction sentence gives one action.
In the message about uncommitted changes, the list of paths counts as one word.
The `stage-boundary` reason has two sentences, and it gives no action.

A manual count found at most 18 words per sentence in the new and changed sentences.
Each new or changed paragraph has at most six sentences and one subject.
The new text has no semicolons, no parentheses, and no passive sentences.
Older sentences that keep their wording stay outside the sentence rules.

The rule table above applies to this text with the same results.
The assessment remains **40 satisfied rules / 50 applicable rules = 80 percent**.
Unchecked dictionary rules and the three conservative deviations still count as failures.
This is an internal assessment, not certification.

The semantic review found no change to roles, models, efforts, permissions, review targets, or CI requirements.
The resume now accepts pushed operator commits on top of the completed stage.
It still rejects lost stage history, unpublished local commits, and uncommitted changes outside protected work.
No recovery agent starts at this transition.
In a project, the new checks accept changed project context only at a completed-stage boundary.
A review run queues a completed target again when later changes reach its recorded paths or their directories.

## Test scope addendum

Assessment date: 2026-10-16.
The scope covers the new and changed sentences about the scope of tests, the Pair B full run, and the final gate.
In `tools/cycle_prompts.py`, it covers the test scope block in `COMMAND_EXECUTION_CONTRACT`.
It also covers two new paragraphs in `PAIR_CONTRACT` and one changed sentence in `CODE_IMPLEMENTATION_CONTRACT`.
In `tools/focus_review_contract.py`, it covers one new sentence about the review scope.

The scope also covers the new runtime texts.
In `tools/focus_pairs.py`, these are the `full_run` and `final_gate` rules of the pair assignment.
In `tools/focus_pair_repair.py`, these are `FINAL_GATE_VERIFICATION`, `FULL_RUN_DONE`, and the texts of the gate assignment.
In `tools/cycle_workflow.py`, these are the changed verification policy and one new sentence in `review_exit`.
One changed sentence in the B/final test text names each assigned `full_suite` check.
Four runtime messages are also in scope: the two `full_suite` refusals, the `not_needed` refusal, and the missing `final_gate` refusal.

In `docs/sequential-cycle.md`, the scope covers the changed `Builds and tests` section and the new `Final gate` section.
It also covers one new line of the flow diagram and one new upgrade paragraph.
In `knowledge.md`, it covers five new paragraphs, three new sentences about saved jobs, and one changed sentence.
One older `knowledge.md` sentence about optional full suites in pair B was removed.
In `docs/instruction-style.md`, it covers three changed sentences.
In `docs/focus-review.md`, it covers one new paragraph.

`tools/check_focus_instructions.py` now also scans `start_final_gate`, `FINAL_GATE_VERIFICATION`, and `FULL_RUN_DONE`.
It reports 0 findings in all scanned blocks.
A manual count found at most 19 words per sentence in the new and changed text.
Each new or changed paragraph has at most six sentences and one subject.
A manual check covers the four runtime messages, because the checker does not scan exceptions.

Three older sentences move into the new documentation section with their wording unchanged.
They are the sentence about inspection roles, the sentence about reused evidence, and the sentence about verification-only assignments.
The older sentence about B/final fix invocations becomes two sentences without a semicolon.
Older sentences that keep their wording stay outside the sentence rules.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name test suites, mutants, batteries, gates, candidates, and runtime fields. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns keep noun use. The verb run keeps its software meaning. |
| 1.8 | Satisfied | Full run, targeted check, and final gate keep one meaning in all texts. The variants full-run gate and full-run assignment were removed. |
| 1.9 | Satisfied | Short terms name the concepts: full run, final gate, test scope rules. |
| 1.10 | Satisfied | The text has no regional variants, slang, or informal labels. |
| 1.11 | Satisfied | Stage, phase, batch, assignment, and invocation keep distinct meanings. |
| 1.12 | Satisfied | Build, test, commit, and publish describe software operations. |
| 1.13 | Satisfied | Operation nouns keep established software meanings. |
| 1.14 | Satisfied | The prose uses US forms, for example behavior. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups stay short. Role and field names count as one unit. |
| 2.2 | Satisfied | Longer concepts use prepositions or hyphens, for example cross-component effects. |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use the simple present. |
| 3.3 | Satisfied | Past participles such as omitted, saved, passed, and retained modify nouns. |
| 3.4 | Satisfied | The text has no complex chains of auxiliary verbs. |
| 3.5 | Satisfied | The new sentences use no verb forms that end in -ing. |
| 3.6 | Satisfied | The new sentences are active. Named roles and the runtime do the actions. |
| 3.7 | Satisfied | The text uses run, set, assign, and request, not do or make with a noun. |
| 4.1 | Satisfied | Long rules become short sentences, and their conditions stay complete. |
| 4.2 | Satisfied | The text keeps articles and necessary words. It has no contractions. |
| 4.3 | Satisfied | A list separates the two exceptions in the documentation. |
| 4.4 | Satisfied | After, then, and if connect related steps. |
| 4.5 | Satisfied | Articles and demonstratives identify the stage, the batch, the run, and the candidate. |
| 5.1 | Satisfied | Each instruction sentence has at most 19 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action. The Pair B message has two sentences for two actions. |
| 5.3 | Satisfied | Procedures use direct commands. Runtime descriptions are separate from commands. |
| 5.4 | Satisfied | Conditions come first, for example "If the change type does not strictly require a full run". No new instruction ends with an only-when clause. |
| 5.5 | Satisfied | Reference facts are separate from commands. No note contains a required action. |
| 6.1 | Satisfied | Each block starts with its scope, then gives the exceptions and the gate. |
| 6.2 | Satisfied | Repeated terms connect the code role, Pair B, and the final gate. |
| 6.3 | Satisfied | Each description sentence has at most 19 words. |
| 6.4 | Satisfied | Paragraphs group the scope, the exceptions, the records, and the gate. |
| 6.5 | Satisfied | Each paragraph has one subject. |
| 6.6 | Satisfied | Each paragraph has at most six sentences. |
| 7.1 | Not applicable | The text has software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text has no safety warning. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The new text has no semicolons. |
| 8.2 | Satisfied | Hyphens join modifiers such as final-pair and cross-component. |
| 8.3 | Satisfied | The new text has no parentheses. |
| 8.4 | Satisfied | A colon introduces the list of exceptions. |
| 8.5 | Satisfied | No parenthetical content occurs. |
| 8.6 | Satisfied | Machine literals such as `full_suite` and `final_gate.full_run=true` stay exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | The text was written again for the style rules, with a separate semantic check. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs, for example "checks more than", "require", and "removes" instead of phrasal verbs. |
| 9.4 | Satisfied | The contracts, runtime texts, and documentation use the same terms. |

The assessment of this scope is **43 satisfied rules / 50 applicable rules = 86 percent**.
The seven unchecked rules count as failures.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements.
The earlier rule permitted full suites only through a Pair B assignment with a stated risk reason.
The new rule keeps that requirement and limits Pair B to one full run in each stage.
It adds the `final_gate` report field and at most one final-gate test step in each stage.
All other roles keep checks within the current changes.
Project requests for broader runs do not change these limits, and the report names each omitted check.

## Stage conversations and refusal restart addendum

Assessment date: 2026-10-17.
The scope covers the new text about new role conversations at a stage transition, the restart after a refusal, and the record of the published stage.
In `tools/cycle_workflow.py`, it covers the `previous_stage` rule, one operator note, and the new docstrings and comments.
In `tools/cycle_transport.py`, it covers the changed refusal sentence, the operator note, the refusal reasons, the resume stop message, and the new docstrings and comments.
`RECOVERY` and `NEW_CONVERSATION` keep the wording of the earlier inline text, and the checker scans both constants.

The scope also covers the new docstring, comment, and limit sentence in `tools/focus_diagnostics.py` and the new comments in `tools/focus_status.py`.
In `docs/sequential-cycle.md`, it covers the changed paragraphs about role conversations and refusal recovery.
It also covers the new paragraphs and the list about the restart, the resume stop, the operator action, and `previous_stage`.
In `knowledge.md`, it covers the new paragraphs about sessions, `previous_stage`, the restart, and the resume stop, and two changed sentences.
In `README.md`, it covers one changed phrase.

In `tools/cycle_prompts.py`, it covers the changed coordinator prompt, and in `tools/cycle_workflow.py`, the changed first sentence of `coding_recovery`.
The Russian panel title is interface text, so the English style rules do not apply to it.

`tools/check_focus_instructions.py` reports 0 findings in all scanned blocks.
It scans the appended refusal sentence in `_run` and both constants.
It does not scan notes that the runtime prints, exception messages, or the reasons in `restart_refused`.
A manual check covers those texts and the documentation.
It found at most 20 words per sentence and at most six sentences per paragraph in the new text.
The new text has no semicolons and no parentheses.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name conversations, sessions, invocations, stages, and runtime fields. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns keep noun use. |
| 1.8 | Satisfied | Conversation, session ID, invocation, and stage keep one meaning in all texts. |
| 1.9 | Satisfied | Short names identify the restart, the previous stage, and the new conversation. |
| 1.10 | Satisfied | The text has no regional variants, slang, or informal labels. |
| 1.11 | Satisfied | Conversation, session ID, attempt, and invocation keep distinct meanings, as in the earlier refusal text. |
| 1.12 | Satisfied | Resume, publish, and record describe software operations. |
| 1.13 | Satisfied | Operation nouns keep established software meanings. |
| 1.14 | Satisfied | The prose uses US spelling. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups stay short. Field and role names count as one unit. |
| 2.2 | Satisfied | Longer concepts use prepositions, for example "the first call of the code role in a new stage". |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use the simple present or past. |
| 3.3 | Satisfied | Past participles such as refused, resumed, and published modify nouns. |
| 3.4 | Satisfied | The text has no complex chains of auxiliary verbs. |
| 3.5 | Satisfied | The new sentences use no verb forms that end in -ing. |
| 3.6 | Satisfied | The runtime, the roles, and the operator do the actions. |
| 3.7 | Satisfied | Actions use verbs, such as continue, record, clear, and select. |
| 4.1 | Satisfied | Each sentence covers one topic. |
| 4.2 | Satisfied | The text keeps articles and necessary words. It has no contractions. |
| 4.3 | Satisfied | A list separates the cases in which the restart stops. |
| 4.4 | Satisfied | Thus, then, and after connect related statements. |
| 4.5 | Satisfied | Articles and demonstratives identify the conversation, the invocation, and the stage. |
| 5.1 | Satisfied | Each new instruction sentence has at most 20 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action. |
| 5.3 | Satisfied | The context rule uses direct commands. Descriptions are separate from commands. |
| 5.4 | Satisfied | Conditions come first, for example "If the published commits lack plan work of this stage". |
| 5.5 | Satisfied | Reference facts are separate from commands. |
| 6.1 | Satisfied | The documentation gives the session rule before the restart rule and its limits. |
| 6.2 | Satisfied | Repeated terms connect the stage transition, the restart, and the label rule. |
| 6.3 | Satisfied | Each description sentence has at most 20 words. |
| 6.4 | Satisfied | Paragraphs group sessions, the restart, the operator action, and the label rule. |
| 6.5 | Satisfied | Each paragraph has one subject. |
| 6.6 | Satisfied | Each paragraph has at most six sentences. |
| 7.1 | Not applicable | The text has software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text has no safety warning. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The new text has no semicolons. |
| 8.2 | Satisfied | Hyphens join modifiers such as report-only. |
| 8.3 | Satisfied | The new text has no parentheses. |
| 8.4 | Satisfied | A colon introduces the list of cases in which the restart stops. |
| 8.5 | Satisfied | No parenthetical content occurs. |
| 8.6 | Satisfied | Field names such as `refusal_restart` and `previous_stage` stay exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | The text was written for the style rules, with a separate semantic check. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs instead of phrasal verbs. |
| 9.4 | Satisfied | The documentation, knowledge text, and runtime messages use the same terms, including self-review. |

The assessment of this scope is **43 satisfied rules / 50 applicable rules = 86 percent**.
The seven unchecked rules count as failures.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements.
Each stage now starts new role conversations.
After a refusal with earlier history, the runtime makes one new conversation with the same role instructions.
A refusal of the first request of a new conversation and the other listed cases still stop for the operator.
A resume of a refused conversation now stops before a provider starts, also after a pause, a correction, or a retry.
After a restart in a serial review role, the clean passes of that role restart.
The coordinator and the code role get a new rule about the published stage.
The coordinator report recovery route now needs `coding_recovery`, and the coordinator names the stage of this iteration.
A coordinator label cannot name the published stage, but a code report can continue its unfinished work.

## Pair quota wait stop addendum

Assessment date: 2026-10-17.
The scope covers one new paragraph in `docs/sequential-cycle.md`, one new paragraph in `knowledge.md`, and the new docstring and comments in `tools/cc_focus.py` and `tools/focus_pair_jobs.py`.
The change adds no provider instruction.

A manual count found at most 20 words per sentence and at most six sentences per paragraph.
The new text has no semicolons, no parentheses, no passive sentences, and no verb forms that end in -ing.
Each sentence covers one topic. In instruction sentences, conditions come first.

The rule table of the stage conversations addendum applies to this text with the same results.
Its seven unchecked rules still count as failures, so the assessment remains **43 satisfied rules / 50 applicable rules = 86 percent**.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements.
A stop request now takes effect while a pair participant waits and no participant runs.
`/resume` now also retries the quota wait of a pair participant.

## Project brief addendum

Assessment date: 2026-10-18.
The scope covers two new provider texts in `tools/cycle_prompts.py`: `PROJECT_BRIEF_RULE` and `BRIEF_CHANGE_CORRECTION`.
It also covers the new runtime messages in `tools/focus_brief.py`, `tools/cc_focus.py`, `tools/cycle_workflow.py`, and `tools/focus_review_run.py`.
It covers the changed correction message of `record_correction` and the changed `refusal-retry` message.
Older messages that keep their wording stay outside the scope.

In `docs/sequential-cycle.md`, the scope covers the new `Project brief` section.
It also covers two new sentences and one changed sentence in the section about the final pair.
It covers two new paragraphs in `docs/focus-review.md`, two new terms in `docs/instruction-style.md`, and two new paragraphs in `knowledge.md`.
It also covers two new sentences in `README.md` and the comments of `project-brief.example.md`.

`tools/check_focus_instructions.py` now also scans `PROJECT_BRIEF_RULE` and `BRIEF_CHANGE_CORRECTION`.
It reports 0 findings in all scanned blocks.
The longest sentence of the two provider texts has 19 words. The paragraphs of the rule have 5, 2, and 6 sentences.

A manual count found at most 25 words in each new description and at most 20 words in each new instruction.
Each new paragraph and each new message has at most six sentences. The new text has no semicolons and no contractions.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name the brief, the pointer, the copy, the stage record, and runtime fields. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns keep noun use. Exact command names stay unchanged. |
| 1.8 | Satisfied | Project brief, pointer, and stage record keep one meaning in all texts. |
| 1.9 | Satisfied | Short terms name the concepts: brief, pointer, copy, notice. |
| 1.10 | Satisfied | The text has no regional variants, slang, or informal labels. |
| 1.11 | Satisfied | Set, restore, clear, show, and apply have distinct meanings. Direct update and correction are distinct paths. |
| 1.12 | Satisfied | Store, verify, capture, and restore describe software operations. |
| 1.13 | Satisfied | Operation nouns keep established software meanings. |
| 1.14 | Satisfied | The prose uses US forms. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups stay short. Role and field names count as one unit. |
| 2.2 | Satisfied | Longer concepts use prepositions, for example the stage record of an unfinished campaign. |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use the simple present. |
| 3.3 | Satisfied | Past participles such as saved, captured, and damaged modify nouns. |
| 3.4 | Satisfied | The text has no complex chains of auxiliary verbs. |
| 3.5 | Unsatisfied | The adjectives pending and missing remain, for example "a pending change". |
| 3.6 | Satisfied | The new messages name the actor, for example "The command started no model". Missing and damaged are adjectives of state. |
| 3.7 | Satisfied | The text uses direct verbs such as set, capture, and apply. |
| 4.1 | Satisfied | Long rules become short sentences, and their conditions stay complete. |
| 4.2 | Satisfied | The text keeps articles and necessary words. It has no contractions. |
| 4.3 | Satisfied | Lists separate the roles, the cases of `apply`, and the remedies. |
| 4.4 | Satisfied | Then, after, and if connect related steps. |
| 4.5 | Satisfied | Articles and demonstratives identify the stage, the pointer, the copy, and the run. |
| 5.1 | Satisfied | Each new instruction sentence has at most 20 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action. Command sequences use code blocks, numbered lists, or separate sentences. |
| 5.3 | Satisfied | Procedures use direct commands. Descriptions stay separate from commands. |
| 5.4 | Satisfied | Conditions come first, for example "After the fix, repeat the command" and "Unless the plan or the project instructions require them". |
| 5.5 | Satisfied | Reference facts are separate from commands. No note contains a required action. |
| 6.1 | Satisfied | The documentation section starts with the purpose, then gives the commands, the stage record, and the change path. |
| 6.2 | Satisfied | Repeated terms connect the import, the stage record, the delivery, and the integrity rules. |
| 6.3 | Satisfied | Each new description sentence has at most 25 words. |
| 6.4 | Satisfied | Paragraphs group the import, the record, the delivery, the change, and the integrity rules. |
| 6.5 | Satisfied | Each paragraph has one subject. |
| 6.6 | Satisfied | Each new paragraph and each new message has at most six sentences. |
| 7.1 | Not applicable | The text has software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text has no safety warning. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The new text has no semicolons. |
| 8.2 | Satisfied | Hyphens join modifiers such as long-term and required-contract. |
| 8.3 | Satisfied | Parentheses contain no hidden instructions. |
| 8.4 | Satisfied | A colon introduces each list. |
| 8.5 | Satisfied | The counter treats parenthetical expressions as units. |
| 8.6 | Satisfied | Machine literals such as `project_brief_notice` and `brief-drift` stay exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | The plan had a separate semantic review, and the change has a separate review of tests and documentation. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs, for example "obey" and "write each section", instead of phrasal verbs. |
| 9.4 | Satisfied | The provider texts, the runtime messages, and the documentation use the same terms. |

The assessment of this scope is **42 satisfied rules / 50 applicable rules = 84 percent**.
The seven unchecked rules and rule 3.5 count as failures.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements.
The brief is operator context. It adds no requirement, task, or stage, and the other sources take precedence over it.
The rule forbids use of the brief to select a stage or to decide that the plan is complete.
It also forbids use of the brief to dismiss a correctness, safety, security, or required-contract failure, or to lower its severity.

## Project instruction list addendum

Assessment date: 2026-10-21.
The scope covers the new provider text `PROJECT_INSTRUCTIONS_RULE` in `tools/cycle_prompts.py`.
It also covers the new runtime messages in `tools/focus_pairs.py`, `tools/focus_pair_view.py`, and `tools/cycle_workflow.py`.

In `docs/sequential-cycle.md`, the scope covers three new paragraphs in the project-mode text and the new section `Move plans and documentation to member repositories`.
It also covers a new paragraph of two sentences in the section about the paired review.
In the section about the final pair, it covers two new sentences and the changed list of the final arbiter inputs.
It also covers one new sentence about escalation output. In `knowledge.md`, it covers three new paragraphs and the changed escalation paragraph.
Older text without changes stays outside the scope.

`tools/check_focus_instructions.py` now also scans `PROJECT_INSTRUCTIONS_RULE`. It reports 0 findings in all scanned blocks.
The paragraphs of the rule have 4, 4, and 2 sentences. Each sentence of the rule has 8 to 18 words.

A manual count found at most 25 words in each new description and at most 20 words in each new instruction.
Each new paragraph has at most six sentences. The new text has no semicolons and no contractions.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name the instruction files, the project root, the members, the frozen view, and the runtime fields. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns keep noun use. Exact file names and command names stay unchanged. |
| 1.8 | Satisfied | Instruction file, project root, member, and stop point keep one meaning in all texts. |
| 1.9 | Satisfied | Short terms name the concepts: list, marker, target, archive. |
| 1.10 | Satisfied | The text has no regional variants, slang, or informal labels. |
| 1.11 | Satisfied | Copy, move, archive, and repair have distinct meanings in the guide. |
| 1.12 | Satisfied | Read, list, copy, and push describe software operations. |
| 1.13 | Satisfied | Operation nouns keep established software meanings. |
| 1.14 | Satisfied | The prose uses US forms. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups stay short. Field, file, and command names count as one unit. |
| 2.2 | Satisfied | Longer concepts use prepositions, for example the instruction files of the project root. |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use the simple present. |
| 3.3 | Satisfied | Past participles such as frozen, saved, and changed modify nouns. |
| 3.4 | Satisfied | The text has no complex chains of auxiliary verbs. |
| 3.5 | Satisfied | The new prose has no -ing forms. The status field `running` is a machine literal. |
| 3.6 | Satisfied | The text names the actor, for example "A pair reader gets the list from its frozen view". |
| 3.7 | Satisfied | The text uses direct verbs such as read, obey, copy, and check. |
| 4.1 | Satisfied | Long rules become short sentences, and their conditions stay complete. |
| 4.2 | Satisfied | The text keeps articles and necessary words. It has no contractions. |
| 4.3 | Satisfied | Numbered steps, lists, and code blocks separate the actions of the guide. |
| 4.4 | Satisfied | Before, after, then, and if connect related steps. |
| 4.5 | Satisfied | Articles and demonstratives identify the repository, the link, the store, and the archive. |
| 5.1 | Satisfied | Each new instruction sentence has at most 20 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action. Command sequences use code blocks or separate sentences. |
| 5.3 | Satisfied | Procedures use direct commands. Descriptions stay separate from commands. |
| 5.4 | Satisfied | Conditions come first, for example "If a repository instruction file gives a command, run the command in the root of that repository". |
| 5.5 | Satisfied | Reference facts are separate from commands. Each stop point is a fact, not a hidden action. |
| 6.1 | Satisfied | The guide starts with the purpose and the target layout, then gives the steps in order. |
| 6.2 | Satisfied | Repeated terms connect the list, the rule, the marker, and the guide. |
| 6.3 | Satisfied | Each new description sentence has at most 25 words. |
| 6.4 | Satisfied | Paragraphs group the list, the rule, the steps, and the advice after the migration. |
| 6.5 | Satisfied | Each paragraph and each step has one subject. |
| 6.6 | Satisfied | Each new paragraph has at most six sentences. |
| 7.1 | Not applicable | The text has software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text has no safety warning. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The new text has no semicolons. |
| 8.2 | Satisfied | Hyphens join modifiers such as project-root and local-only. |
| 8.3 | Satisfied | Parentheses contain no hidden instructions. |
| 8.4 | Satisfied | A colon introduces each list and each status check. |
| 8.5 | Satisfied | The counter treats parenthetical expressions as units. |
| 8.6 | Satisfied | Machine literals such as `project_instructions_version` and `project-layout-changed` stay exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | The plan had a separate semantic review and a separate review against the code. The change has its own review. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs, for example "finish" and "remove", instead of phrasal verbs. |
| 9.4 | Satisfied | The provider text, the runtime message, and the documentation use the same terms. |

The assessment of this scope is **43 satisfied rules / 50 applicable rules = 86 percent**.
The seven unchecked rules count as failures.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements.
The instruction files are project instructions. The role contract, operator messages and corrections, and the review scope have priority over them.
The project brief rule already names the project instructions as a source with priority over the brief.

## Parallel member addendum

Assessment date: 2026-10-22.
The scope covers the new provider text `PARALLEL_REPOSITORIES_RULE` in `tools/cycle_prompts.py`.
It also covers the new runtime messages in `tools/focus_parallel.py`, `tools/cycle_workflow.py`, `tools/focus_review_run.py`, and `tools/focus_publication_recovery.py`.

In `docs/sequential-cycle.md`, the scope covers the new section `Parallel member repositories` and the changed lines in the migration guide.
It also covers the new sentences in the project-mode text, the stage pause checks, the CI gate, and the escalation paragraph.
It covers two new sentences in `docs/focus-review.md`, two new paragraphs in `knowledge.md`, and the changed lines of the Interlink guide.
Older text without changes stays outside the scope.

`tools/check_focus_instructions.py` now also scans `PARALLEL_REPOSITORIES_RULE`. It reports 0 findings in all scanned blocks.
The paragraphs of the rule have 3, 4, and 1 sentences. Each sentence of the rule has 10 to 15 words.

A manual count found at most 25 words in each new description and at most 20 words in each new instruction.
Each new paragraph has at most six sentences. The new text has no semicolons and no contractions.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name the parallel member, the sync, the integration record, the base, and remote main. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns keep noun use. Exact Git commands and blocker codes stay unchanged. |
| 1.8 | Satisfied | Parallel member, exclusive member, sync, and integration keep one meaning in all texts. |
| 1.9 | Satisfied | Short terms name the concepts: sync, base, record, writer. |
| 1.10 | Satisfied | The text has no regional variants, slang, or informal labels. |
| 1.11 | Satisfied | Sync, merge, push, and fetch have distinct meanings. |
| 1.12 | Satisfied | Fetch, merge, push, and restore describe software operations. |
| 1.13 | Satisfied | Operation nouns keep established software meanings. |
| 1.14 | Satisfied | The prose uses US forms. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups stay short. Code and command names count as one unit. |
| 2.2 | Satisfied | Longer concepts use prepositions, for example the stage commits of each parallel member. |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use the simple present. |
| 3.3 | Satisfied | Past participles such as merged, published, and staged modify nouns. |
| 3.4 | Satisfied | The text has no complex chains of auxiliary verbs. |
| 3.5 | Satisfied | The new prose has no -ing forms. The progress text says "Fetch of remote main". |
| 3.6 | Satisfied | The text names the actor, for example "cc-focus merges the stage commits". |
| 3.7 | Satisfied | The text uses direct verbs such as merge, push, restore, and report. |
| 4.1 | Satisfied | Long rules become short sentences, and their conditions stay complete. |
| 4.2 | Satisfied | The text keeps articles and necessary words. It has no contractions. |
| 4.3 | Satisfied | Lists separate the rules for other writers, the stops, and the risks. |
| 4.4 | Satisfied | Before, after, then, and if connect related steps. |
| 4.5 | Satisfied | Articles and demonstratives identify the member, the commit, the record, and the base. |
| 5.1 | Satisfied | Each new instruction sentence has at most 20 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action. |
| 5.3 | Satisfied | Procedures use direct commands. Descriptions stay separate from commands. |
| 5.4 | Satisfied | Conditions come first, for example "If such a change stops your work, report a blocker". |
| 5.5 | Satisfied | Reference facts are separate from commands. The risk list contains no hidden action. |
| 6.1 | Satisfied | The section starts with the purpose and the manifest key, then gives the rules, the stops, CI, and the risks. |
| 6.2 | Satisfied | Repeated terms connect the sync, the remote rules, the integration, and the stops. |
| 6.3 | Satisfied | Each new description sentence has at most 25 words. |
| 6.4 | Satisfied | Paragraphs group the sync, the remote rules, the integration, the stops, CI, and the context. |
| 6.5 | Satisfied | Each paragraph has one subject. |
| 6.6 | Satisfied | Each new paragraph has at most six sentences. |
| 7.1 | Not applicable | The text has software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text has no safety warning. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The new text has no semicolons. |
| 8.2 | Satisfied | Hyphens join modifiers such as fast-forward and local-only. |
| 8.3 | Satisfied | Parentheses contain no hidden instructions. |
| 8.4 | Satisfied | A colon introduces each list. |
| 8.5 | Satisfied | The counter treats parenthetical expressions as units. |
| 8.6 | Satisfied | Machine literals such as `parallel-merge-conflict` and `commit.gpgSign` stay exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | The plan had a separate semantic review and a separate review against the code. The change has its own review. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs, for example "restore" and "merge", instead of phrasal verbs. |
| 9.4 | Satisfied | The provider text, the runtime messages, and the documentation use the same terms. |

The assessment of this scope is **43 satisfied rules / 50 applicable rules = 86 percent**.
The seven unchecked rules count as failures.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements.
The parallel rule has priority over the instruction files of the repositories. The role contract, operator messages and corrections, and the review scope keep their priority.

## Merge resolver addendum

Assessment date: 2026-11-01.
The scope covers the new runtime messages in `tools/focus_resolve.py` and the changed messages in `tools/focus_parallel.py` and `tools/focus_control.py`.
It also covers the report lines in `tools/focus_review_run.py`.

In `docs/sequential-cycle.md`, the scope covers the new section `Merge resolvers`.
It also covers the new paragraph in `README.md`, the three new paragraphs in `knowledge.md`, and the new paragraph in `docs/focus-review.md`.
Older text without changes stays outside the scope. The change adds no provider text, so `tools/check_focus_instructions.py` scans no new block.

A script count found at most 25 words in each new description and at most 20 words in each new instruction.
Each new paragraph has at most six sentences. The new text has no semicolons and no contractions.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name the resolver, the rule, the check command, the worktree, and the merged tree. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns keep noun use. Git commands, variables, and blocker codes stay unchanged. |
| 1.8 | Satisfied | Resolver, rule, check, and resolution keep one meaning in the messages and the documentation. |
| 1.9 | Satisfied | Short terms name the concepts: rule, check, worktree, record, entry. |
| 1.10 | Satisfied | The text has no regional variants, slang, or informal labels. |
| 1.11 | Satisfied | Resolve, merge, remove, and prune have distinct meanings. |
| 1.12 | Satisfied | Run, check, remove, and correct describe software operations. |
| 1.13 | Satisfied | Operation nouns keep established software meanings. |
| 1.14 | Satisfied | The prose uses US forms. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups stay short. Code and command names count as one unit. |
| 2.2 | Satisfied | Longer concepts use prepositions, for example the blob ids of the resolver files in the merged tree. |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use the simple present. |
| 3.3 | Satisfied | Past participles such as resolved, merged, and ignored modify nouns. |
| 3.4 | Satisfied | The text has no complex chains of auxiliary verbs. |
| 3.5 | Satisfied | The new prose has no -ing forms outside the step name `resolving`, which is a machine literal. |
| 3.6 | Satisfied | The text names the actor, for example "cc-focus saves the integration record". |
| 3.7 | Satisfied | The text uses direct verbs such as run, check, remove, and correct. |
| 4.1 | Satisfied | Long rules become short sentences and lists, and their conditions stay complete. |
| 4.2 | Satisfied | The text keeps articles and necessary words. It has no contractions. |
| 4.3 | Satisfied | Lists separate the values of the key, the steps, the variables, the checks, the stops, and the risks. |
| 4.4 | Satisfied | Then, after, otherwise, and because connect related steps. |
| 4.5 | Satisfied | Articles and demonstratives identify the rule, the path, the worktree, and the record. |
| 5.1 | Satisfied | Each new instruction sentence has at most 20 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action, or two actions in their order. |
| 5.3 | Satisfied | Procedures use direct commands. Descriptions stay separate from commands. |
| 5.4 | Satisfied | Conditions come first, for example "On Windows, name a program". |
| 5.5 | Satisfied | Reference facts are separate from commands. The risk list contains one marked command. |
| 6.1 | Satisfied | The section starts with the purpose and the example, then gives the values, the steps, the checks, the stops, and the risks. |
| 6.2 | Satisfied | Repeated terms connect the rules, the checks, the stops, and the cleanup. |
| 6.3 | Satisfied | Each new description sentence has at most 25 words. |
| 6.4 | Satisfied | Paragraphs group the key, the conflict types, the inputs, the checks, the cleanup, and the evidence. |
| 6.5 | Satisfied | Each paragraph has one subject. |
| 6.6 | Satisfied | Each new paragraph has at most six sentences. |
| 7.1 | Not applicable | The text has software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text has no safety warning. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The new text has no semicolons. |
| 8.2 | Satisfied | Hyphens join modifiers such as add/add, non-zero, and long-path. |
| 8.3 | Satisfied | Parentheses contain no hidden instructions. |
| 8.4 | Satisfied | A colon introduces each list. |
| 8.5 | Satisfied | The counter treats code spans as units. |
| 8.6 | Satisfied | Machine literals such as `parallel-resolver-scope` and `CC_FOCUS_MERGE_PATHS` stay exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | The plan had two clean passes of a semantic review and of a design review. The change has its own review. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs, for example "remove" and "correct", instead of phrasal verbs. |
| 9.4 | Satisfied | The runtime messages and the documentation use the same terms. |

The assessment of this scope is **43 satisfied rules / 50 applicable rules = 86 percent**.
The seven unchecked rules count as failures.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements. A resolver runs without a model.

## Parallel catch-up addendum

Assessment date: 2026-11-02.
The scope covers the changed provider text `PARALLEL_REPOSITORIES_RULE` in `tools/cycle_prompts.py` and the new runtime messages in `tools/focus_publication.py`.
It also covers the new `_STYLE_TEXT` comment in `tools/focus_pair_jobs.py`.
In `docs/sequential-cycle.md`, it covers the subsection `Catch-up for a blocked step`, the changed sentence about the sync timing, the new sentence about the rule, and the new risk.
It also covers the two new paragraphs in `knowledge.md` and the changed sentence in `docs/focus-review.md`.

`tools/check_focus_instructions.py` reports 0 findings in all scanned blocks. The paragraphs of the rule have 3, 4, 5, and 1 sentences.
A script count found at most 25 words in each new description and at most 20 words in each new instruction.
Each new paragraph has at most six sentences. The new text has no semicolons and no contractions.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name the catch-up, the blocked step, the stage base, and the recovery agent. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns keep noun use. Git commands, variables, and blocker codes stay unchanged. |
| 1.8 | Satisfied | Catch-up, sync, and integration keep one meaning in the provider text and the documentation. |
| 1.9 | Satisfied | Short terms name the concepts: catch-up, base, record, writer. |
| 1.10 | Satisfied | The text has no regional variants, slang, or informal labels. |
| 1.11 | Satisfied | Sync, catch-up, and merge have distinct meanings. |
| 1.12 | Satisfied | Fetch, move, and report describe software operations. |
| 1.13 | Satisfied | Operation nouns keep established software meanings. |
| 1.14 | Satisfied | The prose uses US forms. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups stay short. Code and command names count as one unit. |
| 2.2 | Satisfied | Longer concepts use prepositions, for example remote main of each parallel member. |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use the simple present. |
| 3.3 | Satisfied | Past participles such as blocked and merged modify nouns. |
| 3.4 | Satisfied | The text has no complex chains of auxiliary verbs. |
| 3.5 | Satisfied | The new prose has no -ing forms. |
| 3.6 | Satisfied | The text names the actor, for example "cc-focus fetches remote main". |
| 3.7 | Satisfied | The text uses direct verbs such as fetch, move, and report. |
| 4.1 | Satisfied | Long rules become short sentences and lists, and their conditions stay complete. |
| 4.2 | Satisfied | The text keeps articles and necessary words. It has no contractions. |
| 4.3 | Satisfied | The new subsection separates the cause, the condition, the result, and the exceptions. |
| 4.4 | Satisfied | Before, then, and because connect related steps. |
| 4.5 | Satisfied | Articles and demonstratives identify the member, the base, and the record. |
| 5.1 | Satisfied | Each new instruction sentence has at most 20 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action. |
| 5.3 | Satisfied | Procedures use direct commands. Descriptions stay separate from commands. |
| 5.4 | Satisfied | Conditions come first, for example "If your work needs commits ..., report a blocker". |
| 5.5 | Satisfied | Reference facts are separate from commands. The risk list contains no hidden action. |
| 6.1 | Satisfied | The subsection starts with the cause, then gives the condition, the result, and the exceptions. |
| 6.2 | Satisfied | Repeated terms connect the sync, the catch-up, and the integration. |
| 6.3 | Satisfied | Each new description sentence has at most 25 words. |
| 6.4 | Satisfied | Paragraphs group the move and its exceptions. |
| 6.5 | Satisfied | Each paragraph has one subject. |
| 6.6 | Satisfied | Each new paragraph has at most six sentences. |
| 7.1 | Not applicable | The text has software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text has no safety warning. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The new text has no semicolons. |
| 8.2 | Satisfied | Hyphens join the noun catch-up. |
| 8.3 | Satisfied | Parentheses contain no hidden instructions. |
| 8.4 | Satisfied | A colon introduces each list. |
| 8.5 | Satisfied | The counter treats code spans as units. |
| 8.6 | Satisfied | Machine literals such as `catch_up: true` stay exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | The change has its own semantic review and design review. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs, for example "fetch" and "move", instead of phrasal verbs. |
| 9.4 | Satisfied | The provider text, the runtime messages, and the documentation use the same terms. |

The assessment of this scope is **43 satisfied rules / 50 applicable rules = 86 percent**.
The seven unchecked rules count as failures.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements.

## Several scope files addendum

Assessment date: 2026-11-02.
The scope covers the new and changed messages in `tools/focus_review_scope.py` and `tools/focus_review_cli.py`.
It also covers the new text in `docs/focus-review.md` and the new sentence in `knowledge.md`.
The change adds no provider text, so `tools/check_focus_instructions.py` scans no new block.

A script count found at most 25 words in each new description and at most 20 words in each new instruction.
Each new paragraph has at most six sentences. The new text has no semicolons and no contractions.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name the scope file, the target, and the campaign. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns keep noun use. Git commands, variables, and blocker codes stay unchanged. |
| 1.8 | Satisfied | Scope, target, and campaign keep one meaning in the messages and the documentation. |
| 1.9 | Satisfied | Short terms name the concepts: scope, target, campaign. |
| 1.10 | Satisfied | The text has no regional variants, slang, or informal labels. |
| 1.11 | Satisfied | Scope, target, and selection have distinct meanings. |
| 1.12 | Satisfied | Review, give, and combine describe software operations. |
| 1.13 | Satisfied | Operation nouns keep established software meanings. |
| 1.14 | Satisfied | The prose uses US forms. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups stay short. Code and command names count as one unit. |
| 2.2 | Satisfied | Longer concepts use prepositions, for example the order of the arguments. |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use the simple present. |
| 3.3 | Satisfied | The new text has no past participles that modify nouns. |
| 3.4 | Satisfied | The text has no complex chains of auxiliary verbs. |
| 3.5 | Satisfied | The new prose has no -ing forms. |
| 3.6 | Satisfied | Instructions address the operator directly. Descriptions name the target or the file. |
| 3.7 | Satisfied | The text uses direct verbs such as give, review, and complete. |
| 4.1 | Satisfied | Long rules become short sentences and lists, and their conditions stay complete. |
| 4.2 | Satisfied | The text keeps articles and necessary words. It has no contractions. |
| 4.3 | Satisfied | The new text separates the rule, the example, and the limits. |
| 4.4 | Satisfied | Before connects the order of the targets. |
| 4.5 | Satisfied | Articles identify the file, the target, and the campaign. |
| 5.1 | Satisfied | Each new instruction sentence has at most 20 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action. |
| 5.3 | Satisfied | Procedures use direct commands. Descriptions stay separate from commands. |
| 5.4 | Satisfied | The new text has no conditional instruction. |
| 5.5 | Satisfied | Reference facts are separate from commands. The risk list contains no hidden action. |
| 6.1 | Satisfied | The new text gives the rule, then the example, then the limits. |
| 6.2 | Satisfied | Repeated terms connect the scope files and the targets. |
| 6.3 | Satisfied | Each new description sentence has at most 25 words. |
| 6.4 | Satisfied | Paragraphs group the rule and its limits. |
| 6.5 | Satisfied | Each paragraph has one subject. |
| 6.6 | Satisfied | Each new paragraph has at most six sentences. |
| 7.1 | Not applicable | The text has software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text has no safety warning. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The new text has no semicolons. |
| 8.2 | Satisfied | The new text has no hyphenated words. |
| 8.3 | Satisfied | Parentheses contain no hidden instructions. |
| 8.4 | Satisfied | A colon introduces each list. |
| 8.5 | Satisfied | The counter treats code spans as units. |
| 8.6 | Satisfied | Machine literals such as `--scope-file` and `--integration` stay exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | The change has its own semantic review and design review. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs, for example "give" and "review", instead of phrasal verbs. |
| 9.4 | Satisfied | The runtime messages and the documentation use the same terms. |

The assessment of this scope is **43 satisfied rules / 50 applicable rules = 86 percent**.
The seven unchecked rules count as failures.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements.

## Report value correction addendum

Assessment date: 2026-11-07.
The scope covers the new `report-enum` correction prompt and the new messages in `tools/cycle_workflow.py`.
It also covers the three new paragraphs in `docs/sequential-cycle.md` and the new paragraph in `knowledge.md`.
`tools/check_focus_instructions.py` scans the new prompt and reports 0 findings.

A script count found at most 25 words in each new description and at most 20 words in each new instruction.
Each new paragraph has at most six sentences. The new text has no semicolons and no contractions.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name the report, the field, the allowed value, and the fix run. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns keep noun use. Git commands, variables, and blocker codes stay unchanged. |
| 1.8 | Satisfied | Allowed value, correction, and fix run keep one meaning in the prompt and the documentation. |
| 1.9 | Satisfied | Short terms name the concepts: field, value, correction. |
| 1.10 | Satisfied | The text has no regional variants, slang, or informal labels. |
| 1.11 | Satisfied | Correction, retry, and replay have distinct meanings. |
| 1.12 | Satisfied | Choose, merge, remove, and adopt describe software operations. |
| 1.13 | Satisfied | Operation nouns keep established software meanings. |
| 1.14 | Satisfied | The prose uses US forms. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups stay short. Code and command names count as one unit. |
| 2.2 | Satisfied | Longer concepts use prepositions, for example a value outside its allowed values. |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use the simple present. |
| 3.3 | Satisfied | Past participles such as saved and allowed modify nouns. |
| 3.4 | Satisfied | The text has no complex chains of auxiliary verbs. |
| 3.5 | Satisfied | The new prose has no -ing forms. |
| 3.6 | Satisfied | The text names the actor, for example "The executor chooses the allowed values". |
| 3.7 | Satisfied | The text uses direct verbs such as choose, merge, and adopt. |
| 4.1 | Satisfied | Long rules become short sentences and lists, and their conditions stay complete. |
| 4.2 | Satisfied | The text keeps articles and necessary words. It has no contractions. |
| 4.3 | Satisfied | The new text separates the correction from the retry. |
| 4.4 | Satisfied | Then and so connect related steps. |
| 4.5 | Satisfied | Articles and demonstratives identify the field, the report, and the run. |
| 5.1 | Satisfied | Each new instruction sentence has at most 20 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action. |
| 5.3 | Satisfied | Procedures use direct commands. Descriptions stay separate from commands. |
| 5.4 | Satisfied | Conditions come first, for example "If every other field is valid". |
| 5.5 | Satisfied | Reference facts are separate from commands. The risk list contains no hidden action. |
| 6.1 | Satisfied | The new text gives the cause, then the correction, then the retry. |
| 6.2 | Satisfied | Repeated terms connect the report, the correction, and the retry. |
| 6.3 | Satisfied | Each new description sentence has at most 25 words. |
| 6.4 | Satisfied | Paragraphs group the correction and the retry. |
| 6.5 | Satisfied | Each paragraph has one subject. |
| 6.6 | Satisfied | Each new paragraph has at most six sentences. |
| 7.1 | Not applicable | The text has software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text has no safety warning. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The new text has no semicolons. |
| 8.2 | Satisfied | Hyphens join report-only. |
| 8.3 | Satisfied | Parentheses contain no hidden instructions. |
| 8.4 | Satisfied | A colon introduces each list. |
| 8.5 | Satisfied | The counter treats code spans as units. |
| 8.6 | Satisfied | Machine literals such as `repair.risks` and `report-enum` stay exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | The change has its own semantic review and design review. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs, for example "choose" and "adopt", instead of phrasal verbs. |
| 9.4 | Satisfied | The correction prompt, the runtime messages, and the documentation use the same terms. |

The assessment of this scope is **43 satisfied rules / 50 applicable rules = 86 percent**.
The seven unchecked rules count as failures.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements.

## Context budget addendum

Assessment date: 2026-11-08.
The scope covers the new provider text of the context budget change.
This text is `READER_SEARCH_CONTRACT`, `COMPACTION_RULE`, and `READER_COMPACTION_RULE` in `tools/cycle_prompts.py`.
It also includes the `VIEW_TOOL` description in `tools/focus_readonly.py`, and the `inspection` text and `stage_handoff_rule` in `tools/focus_pairs.py`.
It also covers the new paragraphs in `docs/sequential-cycle.md` and `knowledge.md`.
The change also rewrote two changed paragraphs of `docs/sequential-cycle.md`: the `focus_inspect` interface and the refused conversations.
`tools/check_focus_instructions.py` scans the new provider text and reports 0 findings.

A script count found at most 25 words in each new description and at most 20 words in each new instruction.
Each new or changed paragraph has at most six sentences. The new text has no semicolons and no contractions.
The recovery rule starts with "After a compaction of the conversation", so the condition uses the active voice.
The `inspection` text gives "Search first" and "Then read only the line ranges that you need" as two sentences.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name the compaction, the recovery copy, the stage handoff, and the search. |
| 1.6 | Unchecked | Nonapproved ordinary words have not all been separated from permitted technical nouns. |
| 1.7 | Satisfied | Technical nouns keep noun use. Tool names, paths, and variables stay unchanged. |
| 1.8 | Satisfied | Compaction, recovery copy, and stage handoff keep one meaning in the prompts and the documentation. |
| 1.9 | Satisfied | Short terms name the concepts: window, copy, handoff, match. |
| 1.10 | Satisfied | The text has no regional variants, slang, or informal labels. |
| 1.11 | Satisfied | Search, read, list, and diff have distinct meanings. |
| 1.12 | Satisfied | Search, read, and compact describe software operations. |
| 1.13 | Satisfied | Operation nouns keep established software meanings. |
| 1.14 | Satisfied | The prose uses US forms. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups stay short. Code, paths, and tool names count as one unit. |
| 2.2 | Satisfied | Longer concepts use prepositions, for example "the handoff records of this stage". |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use the simple present. |
| 3.3 | Satisfied | Past participles such as delivered and frozen modify nouns. |
| 3.4 | Satisfied | The text has no complex chains of auxiliary verbs. |
| 3.5 | Satisfied | The new prose has no -ing verb forms. Finding and heading are nouns. |
| 3.6 | Satisfied | The text names the actor, for example "The transport writes a recovery copy". |
| 3.7 | Satisfied | The text uses direct verbs such as search, read, and remove. |
| 4.1 | Satisfied | Long rules become short sentences, and their conditions stay complete. |
| 4.2 | Satisfied | The text keeps articles and necessary words. It has no contractions. |
| 4.3 | Satisfied | The text separates the writer session rule from the reader search rule. |
| 4.4 | Satisfied | Then and so connect related steps. |
| 4.5 | Satisfied | Articles and demonstratives identify the copy, the view, and the record. |
| 5.1 | Satisfied | Each new instruction sentence has at most 20 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action, or one action and its target. |
| 5.3 | Satisfied | The role contract uses direct commands. Descriptions stay separate from commands. |
| 5.4 | Satisfied | Conditions come first, for example "After a compaction of the conversation". |
| 5.5 | Satisfied | Reference facts are separate from commands. The tool description contains no hidden action. |
| 6.1 | Satisfied | The documentation gives the window, then the copy, then the rule. |
| 6.2 | Satisfied | Repeated terms connect the window, the copy, and the rule. |
| 6.3 | Satisfied | Each new description sentence has at most 25 words. |
| 6.4 | Satisfied | Paragraphs group the window, the copy, the sessions, the search, and the usage record. |
| 6.5 | Satisfied | Each paragraph has one subject. |
| 6.6 | Satisfied | Each new or changed paragraph has at most six sentences. |
| 7.1 | Not applicable | The text has software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text has no safety warning. |
| 7.3 | Not applicable | No physical hazard needs a consequence statement. |
| 8.1 | Satisfied | The new text has no semicolons. |
| 8.2 | Satisfied | Hyphens join case-sensitive, read-only, and report-only. |
| 8.3 | Satisfied | Parentheses contain no hidden instructions. |
| 8.4 | Satisfied | A colon introduces the guidance of the role contract and the list of each run store. |
| 8.5 | Satisfied | The counter treats code spans as units. |
| 8.6 | Satisfied | Machine literals such as `__runtime__/prompt.txt` and `CLAUDE_CODE_AUTO_COMPACT_WINDOW` stay exact. |
| 8.7 | Satisfied | The counter treats hyphenated forms as one word. |
| 9.1 | Satisfied | The change has its own semantic review and design review. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs, for example "remove" and "search", instead of phrasal verbs. |
| 9.4 | Satisfied | The role contract, the tool description, and the documentation use the same terms. |

The assessment of this scope is **43 satisfied rules / 50 applicable rules = 86 percent**.
The seven unchecked rules count as failures.
This is an internal assessment, not certification.

The change keeps roles, models, efforts, review targets, and CI requirements.
