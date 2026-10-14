# cc-focus instruction assessment

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
