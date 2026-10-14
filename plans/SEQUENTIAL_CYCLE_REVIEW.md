# Sequential cycle implementation review

## Scope and validation

Review the dedicated launcher, provider protocol adapters, persistent state,
cross-provider loop, publication/CI barriers, installation and operator contract.
Preserve unrelated local configuration and the existing project-config changes.
Use fixture providers and disposable repositories for mutation tests; do not run
the production autonomous cycle against this checkout.

## Initial implementation validation

The initial pass found and corrected incomplete-review counter retention,
publication recovery with an already committed stage, deletion fingerprints,
late changes during CI, same-named checks from different sources, the lease
acquire/acknowledgement crash window, and pending-step loss during clean-session
reset. Provider streams now close their handles and explicitly pin the requested
profile, including disabled native delegation and Claude ultracode.

Additional checks protect the operator's staged entries, detect modified handoff
copies, retain the same coding stage after an interrupted attempt, and avoid
feeding whole-repository fingerprints to the publishing coordinator.

The first complete launcher-suite run exercised an earlier cycle-test fixture
while implementation validation was still in progress: the other eleven suites
were green with zero survivors; the cycle fixture needed its reviewed snapshot
updated after introducing the final CI-content barrier. The corrected focused
suite is rerun separately and the final whole-suite result must supersede that
intermediate run.

## Final review sequence

Record consecutive substantive clean passes here after implementation settles.
Minor wording or formatting corrections do not reset the clean counter.

An initially clean state/ownership pass was followed by a provider review finding:
resuming a long-lived Codex conversation requested unbounded historical turns.
The adapter now resumes metadata-only and requests a single full recent turn only
for recovery or a missing terminal payload. Protocol fixtures assert this bound.
The final clean counter restarts after this implementation correction.
The same provider/recovery pass also tightened uncertain interrupted reviews:
without a durable final report the earlier clean streak is discarded, and
unclassified changes from an interrupted second review return to the first one.
This prevents pre-crash fixes from inheriting clean evidence for older content.
The zero-inference live protocol probe also established that a new thread is not
materialized before its first user message. Missing-rollout recovery now creates
a recorded clean continuation of the same phase; authentication/policy errors do
not select this path. A fixture covers that first-turn crash window.
Publication path comparison was also corrected to use NUL-delimited Git output,
so Unicode and quoted filenames retain their identity. The end-to-end fixture
now exercises the real publication-policy and no-configured-CI bridge as well.
CI configuration discovery now reads the published tree, not uncommitted drafts;
known external CI definitions fail closed unless covered by explicit required
GitHub checks. Focused fixtures cover both cases.
Remote verification and CI discovery use the configured push URL rather than
assuming the fetch URL is the publication destination; multiple push URLs are
rejected before publication. A separate-fetch/push fixture covers this boundary.

Two subsequent state/provider passes were clean, but the installation pass found
that a handoff filename equal to `status` selected the diagnostic launcher path.
Diagnostic dispatch now recognizes `status` only as the command, not an option
value. The regression invokes the actual PowerShell wrapper with an isolated
configuration and verifies that the required root-containment preflight runs.
The wrapper also pins UTF-8 for redirected Python output, so non-ASCII status and
reports cannot fail under a legacy pipe encoding; a real-wrapper fixture covers it.
The final counter restarts after this launcher correction.

A recovery follow-up reproduced Claude's first-turn history window without an
inference call (zero turns and zero usage). Its exact missing-conversation result
now records a clean same-phase continuation after closing the prior process.
Authentication and other failures do not replace sessions. Two fixtures cover
the recovery and refusal paths; the clean sequence starts after this correction.
The same follow-up prevents a recovery dependency fix from advancing unfinished
coding directly to review. Coding resumes its existing stage before either review.
Repeated failures before a recovered work step completes also stop when their
messages differ (for example, timestamps). A resolver's success claim or a
coordinator acknowledgement alone cannot sustain an idle recovery loop.

- [x] Clean pass 1: recovery, session identity, ownership and state transitions.
  Rechecked pending intent/result replay, both missing-history paths, clean-session
  reset, protected work/index entries, unfinished coding and bounded recovery.
  All 48 focused regression tests passed; no further defects or fixes.
- [x] Clean pass 2: provider profile, review evidence, publication and CI.
  Rechecked fixed models/efforts, genuine approval callbacks, one-pass reports,
  reset thresholds and cross-provider return, full coding handoff versus short
  coordination, reviewed-content publication, push destination and exact-SHA
  whole-set CI barriers. No defects or implementation corrections.
- [x] Clean pass 3: installation, cross-platform entry points, regression and scope.
  Rechecked shared runtime installation, launcher argument/UTF-8 handling, console
  configuration compatibility, fixed-profile isolation, generated-role stability
  and operator documentation. No defects or implementation corrections.

## Final validation

- Final focused cycle suite: 48 tests passed, using protocol fixtures and disposable
  repositories. No paid inference is part of the suite.
- The complete serial launcher run passed 12/12 eligible suites with zero survivors;
  POSIX launcher regression tests passed too. Subsequent cycle-only recovery fixes
  were validated by the final expanded focused suite above.
- Both new PowerShell files passed ScriptAnalyzer with no findings. The earlier
  repository-wide lint run had zero errors and 50 pre-existing warnings.
- Consistency checks, Windows launcher byte/line-ending checks, Bash syntax,
  actual shell help/status smoke checks and whitespace validation passed.
- Regeneration left the generated roles unchanged.
- Native Codex zero-inference probes verified the requested profiles; a native
  Claude missing-conversation probe reported zero turns and zero usage.
- Native Windows execution and a paid end-to-end production cycle were not run.
  No implementation commit or push was performed in this checkout.

The last three review passes required no error corrections. Earlier findings and
their fixes are retained above rather than counted as clean evidence.

## Project-plan and CI clarification

The handoff must identify the project plan that supplies stages. The shared prompt
now explicitly requires reading that plan's current state, preserving interrupted
work and reporting a blocker rather than substituting the queue or inventing work.
The existing exact-commit CI barrier remains unchanged. Added regression coverage
checks that failed CI cannot advance and that configured green CI advances only
after waiting; provider fixtures check the plan instruction on fresh and resumed
sessions.

Repeated validation exposed test-only clock leakage: patching the global sleep
function also intercepted subprocess waits. The CI fixture now replaces only the
workflow's time binding, preserving real subprocess timing. The clean sequence
restarts after this test implementation correction.

Final scoped review passes:

- [x] Source selection, exhausted-plan completion and same-stage recovery wording.
  All 50 tests passed after the fixture correction; no new findings.
- [x] CI failure/success coverage, isolated test clock and provider prompt delivery.
  The green-CI transition fixture passed 20 consecutive repetitions; no findings.
- [x] Contract/guide/plan/knowledge consistency and unchanged publication behavior.
  Final 50-test rerun, consistency checks and whitespace checks passed; no findings.

The expanded focused suite contains 50 tests; full-suite results above remain the
earlier integration baseline.

## Previous model profile (version 3)

That profile used Opus/xhigh for implementation, gpt-6.1-sol/xhigh for
three clean first-review passes, Astra/xhigh for two implementation-clean second
passes, Fable/xhigh for one clean final pass, and Luna/xhigh for read-only
publication preparation. Coordination and dedicated blocker recovery stay unchanged.

Implementation validation updated the old-order fixtures for ordinary, corrected,
multi-repository and publication-recovery cycles. Review corrections preserve coder
and publisher conversations rather than unnecessarily replacing them, and clarify
that behavior-changing documentation still counts as implementation work.

### First clean pass

Checked exact provider/model/effort routing, the 3/2/1 order, substantial-fix and
operator-intervention returns to Sol, strict report validation, profile migration
from both older versions, archived review credit, preserved work/session context,
and legacy publication seals. No further implementation findings or corrections.

Validation: the focused launcher passed 195 workflow tests, 56 terminal/input
tests, 21 status tests, 53 multi-repository tests, 14 publication-recovery tests
and launcher help. Total: 339 tests. Clean-pass streak: one.

### Second clean pass

Rechecked profile migration, preserved interrupted coding and publication,
provider model validation, review accounting, status displays and runtime sync
coverage. No implementation findings or corrections. Clean-pass streak: two.

Validation: all 12 eligible launcher/runtime suites completed successfully in
serial mode, including the 339 focused tests above. Every suite reported
`reason=ok`, `exit_code=0` and zero surviving child processes. Contract consistency,
generated-role drift and whitespace checks passed. The 18 Windows-only suites
were skipped on Linux; native Windows and paid-provider runs were not performed.

### Implementation effort follow-up

Raised implementation from Opus/high to Opus/xhigh. The CLI effort flag, inline
settings, environment, resumed sessions and displayed profile use the canonical
profile; no review thresholds or session migration rules changed. Two scoped
reviews found no defects in this follow-up. Four targeted workflow tests and all
21 status tests passed.

The full focused suite was retried twice: both attempts passed 194 of 195 workflow
tests but failed the unchanged `test_emergency_stop_recovers_leaf_after_root_crash`
with `stop-unconfirmed`. Four isolated reruns of that test passed. Its crash path
does not invoke a model or read the effort profile. The broader suite is therefore
not clean for this follow-up; the emergency-stop implementation was left unchanged.

## Four-review profile (version 4)

Opus implements the stage; a distinct Opus reviewer, Sol, Astra and Fable each
require two consecutive clean passes. Substantial fixes defer additional review
until the current loop completes: Sol adds Opus before Astra; Astra adds Opus
before Fable; Fable adds Astra and then Fable with a one-clean target. Extra Astra
can add Opus while preserving that one-clean Fable continuation. Small fixes stay
in the current loop, and Opus never adds another review. The durable route and
fix flag survive restart. Profile 1/2/3 migration restarts unfinished reviews at
Opus and preserves already-started publication/CI seals.

Prompts require impact-scoped builds and tests. Optional, risk-justified full runs
are permitted only in Astra/Fable after one clean pass in the current visit, and
deferred again if that invocation makes substantive fixes.

## Final inspection round and late Opus (profile 5)

Late Opus/xhigh requires two clean passes before the final round. Substantial fixes
complete that loop before repeating Astra (two clean); small fixes stay local.
The final round always runs Opus/max, Astra/max and Fable/xhigh read-only, followed
by Astra/xhigh disposition of every finding. Confirmed blockers go to Opus/xhigh
for repair and a new complete round. One blocker-free round finishes inspection;
remaining nonblockers go to a separate Opus/xhigh cleanup, then directly to publication
without another review. Every finding needs a documented closure; incomplete cleanup
blocks publication. The runtime seals the post-cleanup content and retains closure history. Reviews focus on the current stage diff. Builds
and tests are scoped; late Opus can justify a full test run, while final inspection
and triage never build, test or change project files. Profile 1–4 migration resets
unpublished review credit and preserves started publication/CI seals.

Validation includes serial ordering with findings, blocker repair/re-review,
nonblocking carry-forward/closure, direct post-cleanup publication, restart and cached-result recovery, complete
triage coverage, read-only state barriers, model/effort/tool profiles and migration.

## Paired review profile (version 6)

This historical implementation superseded the serial profile above. Pair A runs
Opus/xhigh and Sol/xhigh concurrently; pair B runs Astra/xhigh and Opus/max
concurrently. Both require two clean pair passes. Final runs Opus/max then
Fable/xhigh with independent initial inputs and needs one blocker-free pair pass.
All pairs use complete finding coverage, at most two discussion exchanges and
binding Astra/max arbitration. Only a separate Opus/xhigh executor edits or tests.
Substantial B fixes finish B2 then repeat A2; unchanged A keeps B's seal, edited A
requires B again. Final nonblockers are closed without another review.

Implementation boundaries: versioned source snapshots and limited inspection tools;
independent durable jobs and ProcessKit containment; shared operator instructions;
closure obligations after fixes; checksummed public handoffs and fresh final sessions;
profile migration preserving started publication/CI. Builds and tests are scoped,
with optional explicitly assigned full verification only in B.

Validation and review evidence for this change is recorded under
`.work/focus-paired-review/`. The regression suite uses disposable repositories and
fake provider protocols; it does not call paid models or mutate consuming projects.

## Complexity assessment and repair after every pair (version 7)

All A/B/final pairs now repeat after significant findings until none remain.
Significant means blocking or critical/high/medium; only low nonblocking findings
qualify for cleanup followed directly by the next stage. There are no fixed clean
streaks or cross-pair returns. No accepted assignments means no artificial repair.

A separate read-only Codex GPT-6-Sol/high assessor covers every accepted fix or
diagnostic and selects Opus/high or xhigh by maximum repair complexity, independently
of finding severity. The assessor is pinned to `gpt-6-sol/high`; no provider
substitution occurs at runtime.
The assessment is bound to candidate and assignment hashes, survives restart and
pins the executor role. Only Opus edits or tests; diagnostics and disputes retain
closure evidence. Unexpected substantial cleanup repeats the same pair. Existing
scoped build/test policy and optional risk-justified broad checks in B remain.

Profile migration preserves working files, carries open obligations and retains
started publication/CI. Status displays the assessor and chosen executor effort.
Validation and two clean self-review passes are recorded under
`.work/focus-complexity-review/`; regression tests use fake providers and disposable
Git repositories, with no consuming-project mutations.

## Inner validation of late-pair repairs (version 8)

B and final fix with Opus/xhigh. Its report selects self-review in the same native
session or independent Opus/xhigh + Astra/xhigh reviewers based on actual patch
risk. The mode can escalate, never downgrade; substantial/disputed repairs and
defects missed by self-review require the pair. Pair A retains its Sol/high assessor.

Fix, static review and tests are separate invocations. Both inner review modes have
inspection-only tools and compare the cumulative repair with the frozen pre-fix
candidate. The pair uses bounded communication and Astra/max arbitration. Two
clean passes on unchanged content precede targeted tests; edits reset credit.
Future verification obligations do not deadlock static review. Tests cannot edit
expected results or code; failures return to fixing and a fresh review/test cycle.
Repeated identical failures on unchanged source use autonomous recovery.

Only a completed inner gate can return significant repairs to the expensive outer
pair, or advance minor-only repairs. New significant inner findings retain that
outer obligation. Sealed reports, candidate hashes, native sessions and nested jobs
survive restart; status and explicit retry include the inner participants. Migration
archives earlier profiles and carries obligations while preserving started publication.

Implementation/review evidence is under `.work/focus-repair-gates/`. Tests use fake
provider protocols, actual Git snapshots and disposable repositories. The launcher
suite runs in an isolated candidate excluding unrelated cc-config work.
