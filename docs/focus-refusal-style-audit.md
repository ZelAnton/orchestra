# cc-focus refusal diagnostics assessment

Assessment date: 2026-10-11.
Reference: [ASD-STE100 Issue 9](https://www.asd-ste100.org/assets/files/ASD-STE100_ISSUE9.pdf).
Method: [the repository instruction policy](instruction-style.md).

The scope is the changed prose of the refusal diagnostics change.
It includes new passages in `docs/sequential-cycle.md` and `knowledge.md`.
It includes the refusal retry message in `tools/cc_focus.py` and the retry guidance in `tools/focus_diagnostics.py`.
It includes new code comments in the changed modules.
It excludes code syntax, tests, unchanged passages, and other changes in the same files.

Result: **42 satisfied rules / 50 applicable rules = 84 percent**.
Seven applicable rules remain unchecked and count as failures.
One applicable rule has a known deviation and also counts as a failure.
Three rules do not apply to this text.
This is an internal assessment, not certification or a complete dictionary audit.

## Evidence

- A script measured 84 changed sentences in seven text groups.
  All sentences have at most 20 words, with machine literals counted as one word.
  All paragraphs have at most six sentences.
  The script found no semicolons or contractions in the changed prose.
- Manual inspection checked terms, sentence structure, conditions, and paragraph topics.
  The text uses "conversation" for a provider dialogue and "session ID" for its identifier.
- A semantic review compared the changed behavior with the text.
  The result is in the last section.

## Rule assessment

The rule numbers identify the reference requirements.
The evidence column describes this text, not a replacement definition of the standard.

| Rule | Result | Evidence or limitation |
| --- | --- | --- |
| 1.1 | Unchecked | A full dictionary check of every ordinary word remains incomplete. |
| 1.2 | Unchecked | Every word occurrence has not been checked against its approved part of speech. |
| 1.3 | Unchecked | Every occurrence has not been checked against its approved dictionary meaning. |
| 1.4 | Unchecked | A complete check of approved inflections remains incomplete. |
| 1.5 | Satisfied | Technical nouns name software items, such as session ID, lease, hash, blocker, and role contract. |
| 1.6 | Unchecked | Nonapproved ordinary words, such as bills, have not all been separated from technical nouns. |
| 1.7 | Satisfied | Technical nouns such as hash, lease, and session keep noun use. |
| 1.8 | Satisfied | Load, run, and read keep their software meanings. |
| 1.9 | Satisfied | Short names identify the refusal history, the onset part, and the retry part. |
| 1.10 | Satisfied | The text uses no slang or informal labels for technical items. |
| 1.11 | Satisfied | Conversation, session ID, invocation, and role keep distinct meanings in all changed passages. |
| 1.12 | Satisfied | Technical verbs describe software operations only. |
| 1.13 | Satisfied | Operation nouns such as compaction keep their established software meanings. |
| 1.14 | Satisfied | The prose uses US spelling. Exact names stay unchanged. |
| 2.1 | Satisfied | Noun groups have at most three words. A hyphenated modifier counts as one word. |
| 2.2 | Satisfied | Longer concepts use prepositions, such as "the first lines of added or removed instruction paragraphs". |
| 3.1 | Unchecked | Every verb inflection has not been checked against the dictionary. |
| 3.2 | Satisfied | Instructions use imperatives. Descriptions use simple present or past forms. |
| 3.3 | Satisfied | Past participles such as refused and saved modify nouns. |
| 3.4 | Satisfied | The text uses no complex chains of auxiliary verbs. |
| 3.5 | Unsatisfied | The text keeps -ing modifiers, such as "Claude writing roles" and "Claude coding run". |
| 3.6 | Satisfied | Named roles and commands do the actions. One passive sentence states that work is preserved. |
| 3.7 | Satisfied | Actions use verbs, such as compare, read, and remove, not nominal phrases. |
| 4.1 | Satisfied | Each sentence covers one topic. |
| 4.2 | Satisfied | Sentences keep articles and other necessary words. |
| 4.3 | Satisfied | Separate items of the report have separate sentences. |
| 4.4 | Satisfied | Then and also connect related steps and items. |
| 4.5 | Satisfied | Articles and demonstratives identify the blocker, session ID, role, and report. |
| 5.1 | Satisfied | All instruction sentences have at most 20 words. |
| 5.2 | Satisfied | Each instruction sentence gives one action, for example "Remove the cause from the instructions." |
| 5.3 | Satisfied | Instructions use direct commands. Descriptions are separate. |
| 5.4 | Satisfied | Conditions come before their actions, as in "If a changed request is still refused, contact provider support". |
| 5.5 | Satisfied | No note contains a required action. |
| 6.1 | Satisfied | The text gives the policy change first, then the retry check, then the diagnostic command. The unknown-cause case follows the known-cause case. |
| 6.2 | Satisfied | Repeated key words such as refusal, retry, and session ID connect the paragraphs. |
| 6.3 | Satisfied | All descriptive sentences have at most 20 words. |
| 6.4 | Satisfied | Paragraphs group the policy change, the retry check, the launch record, and the report parts. |
| 6.5 | Satisfied | Each paragraph covers one subject. |
| 6.6 | Satisfied | The measured paragraphs have at most six sentences. |
| 7.1 | Not applicable | The text contains software workflow rules, with no physical hazard. |
| 7.2 | Not applicable | The text introduces no safety-warning procedure. |
| 7.3 | Not applicable | No physical hazard warning needs a consequence statement. |
| 8.1 | Satisfied | The changed prose contains no semicolons. |
| 8.2 | Satisfied | Hyphens join modifiers such as role-contract and instruction-file. |
| 8.3 | Satisfied | The changed prose contains no parentheses. |
| 8.4 | Satisfied | A colon introduces the list of Claude Code events. |
| 8.5 | Satisfied | No parenthetical text affects a word count. |
| 8.6 | Satisfied | The count treats commands, paths, and numbers as single units. |
| 8.7 | Satisfied | The count treats hyphenated forms as one word. |
| 9.1 | Satisfied | The new text describes new behavior and keeps the existing passages unchanged. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3 | Satisfied | The text uses direct verbs, without phrasal verbs. |
| 9.4 | Satisfied | The style matches the existing English passages of the cc-focus guide. |

## Semantic review

Codex roles receive the same writing contract as before.
Claude roles no longer receive it in their prompts or system prompt additions.
Claude writing roles still load the user policy through their user settings.
Claude paired inspectors start without user settings and write findings only.

The retry check adds a stop for one blocker type. It grants no permission and skips no review.
`--new-sessions --retry` keeps work, phase, and review state, as before.
The diagnostic commands read saved artifacts only and change no state.

## Executor accounting addendum

Assessment date: 2026-10-12.
The addendum scope is `EXECUTOR_ACCOUNTING_CONTRACT`, the new correction prompt, and the new passages in `docs/sequential-cycle.md` and `knowledge.md`.
`tools/check_focus_instructions.py` now audits the new contract block. It reports 811 sentences in 64 blocks and no findings.
The rule results in the table above also apply to this text, with the same seven unchecked rules and rule 3.5 deviation.
The result stays **42 satisfied rules / 50 applicable rules = 84 percent**.

The semantic review found no change to roles, models, efforts, permissions, or review gates.
The new contract repeats counter rules that the parser already enforced.
The correction can change only counters, substantial, summary, and description. It cannot change status, evidence, or resolutions.

## Diagnostic timing addendum

Assessment date: 2026-10-12.
The addendum scope is the new passages about capture timing and the onset reference.
They are in `docs/sequential-cycle.md`, `knowledge.md`, and the resolution section of `docs/focus-diagnostics-review-findings.md`.
It also includes the new code comments and the report limits text in the changed modules.
It also includes the passages and comments from the corrections after the code review.
The rule results above also apply to this text. Seven rules stay unchecked, and rule 3.5 keeps its deviation.
The result stays **42 satisfied rules / 50 applicable rules = 84 percent**.

The semantic review found no change to roles, models, efforts, permissions, or review gates.
The changes affect diagnostic records and reports only. They do not grant review credit or clear a blocker.

## Discussion consensus addendum

Assessment date: 2026-10-13.
The addendum scope is `DISCUSSION_CONSENSUS_CONTRACT`, the new error messages and `--retry` handling, and the new passages in `docs/sequential-cycle.md` and `knowledge.md`.
`tools/check_focus_instructions.py` audits the new contract block. It reports no findings.
The checker does not scan error messages. A manual count found at most 20 words per sentence and no semicolons in them.
The rule results above also apply to this text. Seven rules stay unchecked, and rule 3.5 keeps its deviation.
The result stays **42 satisfied rules / 50 applicable rules = 84 percent**.

The semantic review found no change to roles, models, efforts, permissions, or review gates.
The new rule repeats the exact-match check that the runtime already enforced.
Saved discussion prompts are unchanged, so in-flight discussions can resume.

## Stale diagnostics addendum

Assessment date: 2026-10-13.
The addendum scope is the DIAG-03 resolution section and the new passages in `docs/sequential-cycle.md` and `knowledge.md`.
The rule results above also apply to this text. Seven rules stay unchecked, and rule 3.5 keeps its deviation.
The result stays **42 satisfied rules / 50 applicable rules = 84 percent**.

The semantic review found no change to roles, models, efforts, permissions, or review gates.
The change makes the retry check stricter. It starts no model and clears no blocker.

## Codex server error addendum

Assessment date: 2026-10-13.
The scope is the new Codex server error passages and one new runtime message.
The passages are in `docs/sequential-cycle.md` and `knowledge.md`.
The other runtime messages keep their wording, except for the provider name.

The change also splits the existing transient-retry passages into paragraphs with one subject each.
The split sentences keep their wording, with two exceptions.
The sentences about exhausted retries are new.
The sentence about the saved deadline now names the sequential roles.

Outside these passages, the change makes four small edits.
Two older `knowledge.md` sentences change: the healer routing sentence and the list of escalation reasons.
Two short sentences in `docs/sequential-cycle.md` are new.
One is in the recovery rules, and one follows the list of terminal reasons.
The count below includes the two new sentences. It does not include the two older sentences.

The new message follows exhausted server-error retries.
The run then stops for the operator, and no healer reads the message.
The two instruction sentences address the operator, and each gives one action.
Sequential roles and pair participants get the same instruction sentences, and the pair text names the participant role.
`tools/check_focus_instructions.py` does not scan runtime messages, so a manual check covers this message.
The new escalation text has two sentences with at most 11 words each.

A manual count found at most 18 words per sentence in the new passages and the new message.
Each changed paragraph has at most six sentences.
The new text has no semicolons, no parentheses, and no passive sentences.
The rule results above also apply to this text. Seven rules stay unchecked, and rule 3.5 keeps its deviation.
The result stays **42 satisfied rules / 50 applicable rules = 84 percent**.

The semantic review found no change to roles, models, efforts, or permissions.
Codex server errors now use the bounded retries that Claude server errors already use.
Other Codex errors still use the usual blocker handling.
One recovery rule changed on the operator's decision.
Exhausted server-error retries of either provider now stop the run and start no healer.
