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
