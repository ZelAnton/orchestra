# Interactive terminal review

## Scope and method

Review the terminal, message journal, transport multiplexing, lifecycle integration,
workflow barriers and mirrored asset installation. Use hermetic provider fixtures
and disposable Git repositories, including a real POSIX pseudoterminal. Preserve
all pre-existing work; do not deploy to a consuming project or call paid providers.

## Pass 1 — findings corrected

- A provider failure with queued or uncertain input could replace the pending
  invocation with healing and orphan the message target. Preserve the original
  intent, stop for the operator, and do not mask unconfirmed process cleanup.
- A parked UI can survive processing, including failed cleanup. External emergency
  stop must still terminate the exact root/leaf containers after a failed epoch,
  while holding the identity lock against a newer epoch. A live ownership lock
  must not be described as released.
- Input EOF or terminal I/O failure must request cleanup and close the UI, not
  park forever without an input reader. A quit requested during startup must
  prevent the first provider invocation.
- Setup/progress persistence failures must unbind the input controller even when
  an exit-note write fails, so the operator can retry after fixing storage.

Added targeted regression cases for these paths. The clean-pass streak is zero;
subsequent passes must validate the final fixed snapshot.

## Pass 2 — clean

Re-read input ownership, invocation capture, durable send/ack transitions, delayed
Codex responses, Claude response aggregation, cached-result recovery, review
invalidation and publication exclusions. Checked the parked-UI lock/lease boundary,
external stop identity guard, input failure cleanup and mirrored module inventory.
No implementation findings and no corrections.

Validation: all 150 Python regression cases passed in 39.874 seconds. Canonical
role regeneration produced no generated-file drift. Whitespace and cross-agent
consistency checks passed. Clean-pass streak: one.

## Pass 3 — finding corrected

The parked terminal can retain an unconfirmed provider after releasing its local
lock (notably on Windows). A new run must check the previous live UI's exact leaf
exit before replacing its control identity. External emergency stop must also work
when that failed epoch no longer holds the local lock; safe stop must not call it
an already-stopped success. Added regression coverage for admission, read-only exit
confirmation, closed-UI recovery and external cleanup without a lock.
Native owner birth markers distinguish PID reuse from a surviving parked UI on
Linux and Windows; missing birth information stays conservative.
If process creation itself fails, clear its prepared provider address only when
no process ever existed. Otherwise the new admission check would wait on a run
that could never have registered; uncertain started-process cleanup stays guarded.

Clean-pass streak reset to zero. Two clean passes are still required.

## Pass 4 — clean

Rechecked post-failure admission against live, exited and reused owner identities;
unstarted provider intents; exact-run external emergency cleanup; queued-input
recovery; and the unchanged serial review/publication barriers. No implementation
findings and no corrections.

Validation: `test-cc-focus.ps1` passed all 110 workflow tests (34.651 seconds), all
44 terminal/input tests (3.823 seconds), and launcher help. Clean-pass streak: one.

## Pass 5 — finding corrected

Resume treated a scheduled healer like an already escalated blocker and could
clear it before its required recovery attempt. Preserve `healing` on UI resume;
only an explicitly escalated `blocked` state receives the operator retry option.
Added a routing regression for both states. Clean-pass streak reset to zero.

## Pass 6 — finding corrected

An oversized provider rejection could exceed the bounded journal reader and make
an otherwise valid message impossible to inspect or discard. Bound the stored and
displayed rejection detail; the original protocol log remains complete. Added a
two-megabyte rejection fixture that remains readable and discardable.

Clean-pass streak remains zero. Final validation must cover the corrected snapshot.

## Pass 7 — finding corrected

Wall-clock ordering could deliver a newer instruction before an older one after a
clock correction. Assign a durable per-stage sequence under the input-owner lock
and use timestamps only as secondary/legacy ordering. Added a clock-rollback test.
Clean-pass streak remains zero.

## Pass 8 — clean

Checked the final message-ordering and size bounds together with all prior fixes:
single input ownership, delivery/receipt distinction, late-result barriers,
same-invocation replay, healer routing, review reset, publication exclusion and
parked-process admission. No implementation findings and no corrections.

Validation: 110 workflow tests passed in 40.790 seconds; 47 input/terminal tests
passed in 3.686 seconds; launcher help, whitespace, generated-file consistency and
cross-agent contract checks passed. Clean-pass streak: one.

## Pass 9 — clean

Rechecked the final acceptance surface: automatic TTY/plain selection, one input
owner, terminal restoration, explicit approvals, ordered durable delivery, retry
and discard, pause/resume, same-stage corrections, preserved healer routing and
the protected publication window. Verified the mirrored module inventory and
operator documentation against the CLI and source. No implementation findings
and no corrections.

Validation: 110 workflow tests passed in 42.239 seconds; 47 input/terminal tests
passed in 5.223 seconds; launcher help and contract/whitespace checks passed.
Passes 8 and 9 are the two consecutive clean passes on the final implementation.

## Additional validation and limits

- Full eligible launcher suite: 12/12 terminal green, serial execution,
  max-parallel=1, wall=523757 ms, survivors=0. That run preceded the last Python-only
  fixes; the final focused launcher runs above cover those fixes and all 157 cases.
- POSIX pseudoterminal pause/resume/ownership lifecycle: five additional consecutive
  repetitions passed in 8.136 seconds.
- Canonical role regeneration produced no generated-file drift.
- Native Windows execution and paid provider end-to-end calls were not performed.
  Provider integration uses local protocol fixtures, not simulated claims of live
  model acceptance. The expected lock-denial stderr is a negative test case.
- No installed runtime, consuming project, user settings, commits or publication
  were changed. Existing unrelated workspace changes remain preserved.
