# Focus output and correction review

Scope: live provider output, stopped-stage operator corrections, durable recovery,
CLI/install integration and regression tests. No deployment or publication.

## Pass 1: findings corrected

- Cached coding results and manual report recovery did not revalidate immutable
  correction context. Validate text and archived context before either replay path;
  a stale revision cannot be replayed or receive review credit.
- Repeated complete JSON messages and updated plan snapshots could be displayed
  more than once. Track the final snapshot separately from the per-item display
  budget; regression tests cover streamed and completed output from both providers.
- Tool display omitted structured-only MCP results and dynamic tool text. Cover
  these protocol variants, retaining text only and excluding binary payloads and
  private reasoning. Unknown display events must not break protocol processing.

Verification after fixes: 109 hermetic tests passed, including the real ProcessKit
root/shared-lease correction wrapper with providers forbidden, protocol fixtures,
terminal-control neutralization, file and archive drift, fresh-session retention,
old-result rejection and all mandatory review passes before publication.

## Pass 2: display bound corrected

An updated JSON-looking public message could print its full final snapshot after
earlier output, exceeding the shared per-item display limit. Track displayed
characters separately from retained input and test two large, different snapshots.
Also retain only bounded tool-input assembly metadata, never thinking blocks.

## Pass 3: clean

Rechecked correction acceptance, immutable text/context, crash-before-save behavior,
stale-result rejection, native-session preservation, publication refusal and
review-counter transitions. Rechecked CLI default/compact routing, per-item output
limits, terminal controls and shared installation inventory.

Validation: all 110 hermetic tests passed; the cross-agent/runtime consistency
check passed. No implementation defects found or fixed in this pass.

## Pass 4: clean

Reviewed protocol boundaries and shutdown: Claude partial/final messages and tool
results, Codex deltas and authoritative item snapshots, trailing stderr retention,
structured-report validation, private-content exclusion and malformed display
events. Checked installation paths, CLI help, documentation examples and unchanged
generated role outputs.

Validation: all 110 hermetic tests passed again; whitespace and generated-drift
checks passed. No implementation defects found or fixed in this pass.

## Pass 5: clean

Reviewed the complete operator path and lifecycle: safe/emergency stop, exclusive
correction acceptance, same-stage coding, mandatory cross-provider reviews,
publication/CI barriers and next-iteration cleanup of active correction context.
Checked ownership boundaries, preserved WIP, installed module inventory and public
instructions against the final CLI.

Validation: all 110 hermetic tests passed a third consecutive time after the last
fix. POSIX launchers passed. The full serial launcher suite completed with 12/12
eligible test files green, 12 launches, maximum parallelism 1 and survivors 0
(552631 ms). That suite ran the earlier 100-test focus snapshot; the subsequent
110-test runs cover every final Python change. Eighteen Windows-only launcher
tests were skipped on Linux. Generated files and whitespace checks were clean.

Consecutive clean passes: 3. Review requirement satisfied. No paid provider turns,
installation changes, external-project mutations, commits or pushes were performed.
