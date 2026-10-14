# Stale diagnostics can hide a refused pair session

Review date: 2026-10-13.
Finding: DIAG-03.
Priority: P2, medium.
Status: corrected in the working tree. The resolution section lists the change and its tests.
Repository: `/srv/dev/projects/orchestra`.

## Summary

`saved_claude_call()` can return metadata from an earlier attempt in the same invocation directory.
It does not check whether the saved diagnostic file describes the latest protocol attempt.
If a new refusal occurs and its diagnostic write fails, the previous file remains.
For an unfinished pair reader, the retry check can then miss the refusal.

The earlier findings, DIAG-01 and DIAG-02, were corrected.
This finding concerns the retry check's use of the diagnostic cache.
It does not invalidate those earlier corrections.

## Source locations

Line numbers refer to the source inspected on the review date.

| Source | Relevant behavior |
| --- | --- |
| [tools/focus_diagnostics.py](../tools/focus_diagnostics.py), `saved_claude_call`, lines 431-455 | Returns cached session and refusal metadata before it checks the protocol. |
| [tools/focus_diagnostics.py](../tools/focus_diagnostics.py), `selected_refusals`, lines 477-483 | Requires `call["refused"]` for an unfinished pair reader. |
| [tools/cycle_transport.py](../tools/cycle_transport.py), lines 732-749 | Records the attempt ID, but tolerates diagnostic write failures. An older file can remain. |
| [tools/cc_focus.py](../tools/cc_focus.py), lines 138-154 | Rejects a plain retry only when `selected_refusals()` identifies a retained refused session. |

## Failure sequence

1. A pair reader completes a provider attempt without a refusal.
2. The runtime saves that attempt's `claude-diagnostics.json`.
3. The reader needs another attempt, for example to correct an invalid report.
4. The next attempt reuses the invocation directory and native session.
5. The provider refuses this attempt. The protocol records the refusal.
6. The new diagnostic write fails. The earlier diagnostic file remains.
7. `saved_claude_call()` returns `refused=false` from that earlier file.
8. `selected_refusals()` omits the unfinished reader, although its session still contains the refusal.

The pair blocker identifies `pair_group`, rather than the individual reader.
The check therefore depends on the unfinished job's own refusal metadata.
A plain `--retry` can pass this check and resend the same refused conversation.
The likely consequence is another provider refusal and avoidable delay or cost.
No review credit is granted by this diagnostic defect.

## Reproduction

The review reproduced this with two fixture-provider processes through `Transport.run()`.
The first attempt saved its diagnostics. The second emitted a structured refusal.
An injected `OSError` affected only the second write to `claude-diagnostics.json`.
The actual provider error remained `claude-refusal`, but the subsequent retry check missed the refused session.

The smaller reproduction below creates the equivalent saved files directly.
It uses an existing test fixture and a temporary directory.
It starts no provider and changes no consuming project.

Run this command from `/srv/dev/projects/orchestra`:

```bash
PYTHONDONTWRITEBYTECODE=1 PYTHONPATH=tools:tests python3 -B - <<'PY'
import json

from test_focus_refusals import RefusalHistoryTests
from focus_diagnostics import saved_claude_call, selected_refusals, refusal_history

case = RefusalHistoryTests()
case.setUp()
try:
    identity = "b" * 32
    session = "11111111-1111-1111-1111-111111111111"
    role = "pair_opus"
    target = case.claude_invocation(
        identity, session, 1000, "Inspect.\n", result=case.SUCCESS,
        launch={"role": role, "requested_model": "opus", "session_id": session},
    )
    frames = [
        ("runtime", {
            "type": "attempt", "provider": "claude", "attempt": "f" * 32,
            "session_id": session, "started": 2000,
        }),
        ("stdout", {
            "type": "assistant", "session_id": session,
            "message": {
                "id": "refused-response", "model": "claude-opus-5-5",
                "stop_reason": "refusal",
                "stop_details": {"category": "reasoning_extraction"},
                "content": [],
            },
        }),
    ]
    with (target / "protocol.jsonl").open("a") as stream:
        for channel, event in frames:
            stream.write(json.dumps({
                "stream": channel, "line": json.dumps(event),
            }) + "\n")

    # The previous diagnostic file remains, as after an optional write failure.
    state = {
        "sessions": {},
        "blocker": {
            "code": "claude-refusal",
            "interrupted": {"id": "a" * 32, "role": "pair_group"},
        },
        "pair_review": {"jobs": {"scan/" + role: {
            "id": identity, "role": role, "sessions": {role: session},
        }}},
    }
    history = refusal_history(case.directory, state)
    observed = {
        "protocol_has_refusal": bool(history["refusals"]),
        "cached_call": saved_claude_call(case.directory, identity),
        "selected_refusals": selected_refusals(case.directory, state),
        "same_conversation": history["retry"]["same_conversation"],
    }
    print(json.dumps(observed, indent=2))
    assert observed["protocol_has_refusal"]
    assert not observed["cached_call"]["refused"]
    assert observed["selected_refusals"] == []  # Current defect.
    assert observed["same_conversation"] is False
finally:
    case.doCleanups()
PY
```

Current output:

```json
{
  "protocol_has_refusal": true,
  "cached_call": {
    "session_id": "11111111-1111-1111-1111-111111111111",
    "refused": false
  },
  "selected_refusals": [],
  "same_conversation": false
}
```

Expected behavior: the check identifies the latest refused attempt and its selected reader session.
The guard then rejects a plain retry of that retained conversation.
After correction, the assertions that describe the current defect must fail.

## Proposed correction

1. Determine the latest attempt from the protocol before trusting cached refusal metadata.
2. Compare the cached `launch.attempt` with the latest recorded attempt ID.
3. If they differ or ownership is uncertain, derive session and refusal metadata from the protocol.
4. Preserve support for legacy logs that have no attempt markers.
5. Keep missing or damaged evidence explicit. An empty stale refusal list is not evidence about a newer attempt.

The session ID alone cannot establish cache ownership.
Several attempts can use the same native session.
The existing `claude_attempts()` parser already separates recorded attempts.
The correction can reuse that parser instead of introducing another interpretation of the log.

Diagnostic write failures must remain secondary to the provider or containment outcome.
The correction must not convert an optional diagnostic write into a new workflow failure.
It must not erase the blocker, change models, or automatically start a new session.

## Acceptance checks

- An earlier non-refused cache cannot hide a later refused attempt in the same session.
- The same case works when the later attempt uses a different session.
- A cache for an older refused session cannot replace the latest attempt's session metadata.
- Matching current metadata continues to produce the correct result.
- Legacy logs without attempt markers still support refusal detection.
- Missing or malformed diagnostic files use the available protocol evidence.
- `selected_refusals()` identifies the refused unfinished pair job after the injected write failure.
- The CLI rejects a plain `--retry` before it starts a provider for that retained refused session.
- Completed peers remain reusable. Existing work and review credit remain unchanged.
- Explicit session replacement keeps its existing operator-controlled behavior.
- Diagnostic collection failures do not mask the original provider or containment failure.

The regression should include the transport write failure, not only a manually stale cache.
Use temporary fixtures and fake providers for these checks.
Do not modify Interlink, Orbit, or their runtime records.

## Review evidence

The preceding review passed 262 targeted tests across diagnostics, transport, paired review, repair, and report accounting.
The instruction checker passed for 72 blocks and 826 sentences.
The stale-cache counterexample is additional evidence. The existing suite does not cover that combination.
The reviewed installed runtime modules matched their Orchestra source files.
No implementation correction was made during that review or this handoff.

## Resolution

Resolution date: 2026-10-13.

- `saved_claude_call` now reads the attempts of the protocol log with `claude_attempts` first.
- The last attempt supplies the session and the refusal flag.
- The saved file counts only when its `launch.attempt` names the last attempt.
- A saved file is stale when a later attempt mark follows its attempt.
- An older saved file without an attempt ID is stale when the log has attempt marks.
- When the log cannot decide, both sources are combined for the same session. A refusal in either source counts.
- Without a protocol log, the saved file stays the only evidence.
- Diagnostic write failures stay secondary. The provider outcome and the blocker are unchanged.

Regression tests:

- `tests/test_focus_refusals.py` covers a later refusal in the same session and in another session.
- It also covers an older saved file, an older refused session and a matching saved file.
- A damaged or missing file uses the protocol evidence.
- `tests/test_cycle.py` runs two fixture processes through `Transport.run`. The second write of the diagnostics fails.
- The test then checks that `selected_refusals` finds the reader and that a plain `--retry` stops before the lease.
- The reproduction above now prints `refused: true`, one selected refusal, and `same_conversation: true`.

## Writing assessment

This document uses the [repository instruction policy](instruction-style.md).
The rule mapping follows the [existing assessment](focus-instruction-style-audit.md).
The scope is new prose. Code, paths, protocol fields, and exact identifiers retain their machine meanings.
Technical terms include invocation, attempt, session, provider, protocol, cache, fixture, and diagnostic metadata.

Result: **42 satisfied rules / 50 applicable rules = 84 percent**.
Eight unchecked applicable rules count as unsatisfied. Three rules do not apply.
This is an internal assessment, not official certification or a complete dictionary review.

| Rules | Status | Evidence or limitation |
| --- | --- | --- |
| 1.1, 1.2, 1.3, 1.4, 1.6 | Unchecked | A complete dictionary, meaning, part-of-speech, and inflection review remains incomplete. |
| 1.5 | Satisfied | Technical nouns identify software components, files, and protocol fields. |
| 1.7, 1.8 | Satisfied | Technical nouns retain established software meanings and noun use. |
| 1.9, 1.10, 1.11 | Satisfied | Short terms distinguish invocations, attempts, and sessions consistently. Prose has no slang. |
| 1.12, 1.13 | Satisfied | Technical verbs describe software operations. Prose distinguishes operations from data. |
| 1.14 | Satisfied | Prose uses US forms, including behavior. Exact identifiers remain unchanged. |
| 2.1, 2.2 | Satisfied | Short noun groups and prepositions separate complex concepts. |
| 3.1, 3.5 | Unchecked | A complete review of verb inflections and participial forms remains incomplete. |
| 3.2, 3.3, 3.4 | Satisfied | Instructions use imperatives. Descriptions use simple forms and direct modifiers. |
| 3.6, 3.7 | Satisfied | Named functions perform actions. Correction steps use direct verbs. |
| 4.1, 4.2 | Satisfied | Short sentences retain necessary articles and conditions. Prose has no contractions. |
| 4.3, 4.4, 4.5 | Satisfied | Lists separate the failure sequence and checks. Repeated terms connect related facts. |
| 5.1, 5.2, 5.3 | Satisfied | Instruction sentences contain one action and at most 20 words. |
| 5.4, 5.5 | Satisfied | Conditions precede procedural actions. Observations remain separate from instructions. |
| 6.1, 6.2, 6.3 | Satisfied | Scope precedes evidence and corrections. Descriptive sentences contain at most 25 words. |
| 6.4, 6.5, 6.6 | Satisfied | Paragraphs cover one subject and contain at most six sentences. |
| 7.1, 7.2, 7.3 | Not applicable | This report contains no physical hazard or equipment safety procedure. |
| 8.1, 8.2, 8.3, 8.4 | Satisfied | Prose has no semicolons. Modifiers, parentheses, and list boundaries have clear uses. |
| 8.5, 8.6, 8.7 | Satisfied | Word counts treat machine literals, numbers, and hyphenated terms as units. |
| 9.1 | Satisfied | Observations, consequences, correction proposals, and acceptance checks remain distinct. |
| 9.2 | Unchecked | A complete lexical and meaning audit remains incomplete. |
| 9.3, 9.4 | Satisfied | Instructions use direct verbs and the shared English writing policy. |

The resolution section uses the same rule mapping. It does not change the result.
The semantic check preserves the defect's conditions, observed results, and evidence limits.
It preserves project boundaries and the existing refusal policy.
