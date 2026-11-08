"""Refusal history diagnostics, without provider access or private content."""

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import re
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))
from cc_focus import main
from focus_diagnostics import (ClaudeTrace, diagnose, instruction_files, refusal_history, saved_claude_call,
                               selected_refusals)
from cycle_prompts import WRITING_CONTRACT


class RefusalHistoryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / ".work/cycle"
        (self.directory / "invocations").mkdir(parents=True)

    SUCCESS = {"type": "result", "subtype": "success", "is_error": False, "stop_reason": "end_turn",
               "terminal_reason": "completed", "result": "PRIVATE final report"}

    def claude_invocation(self, identity, session, started, prompt, refused=False, launch=None, result=None,
                          completion=None, extra=(), intent=True):
        target = self.directory / "invocations" / identity
        target.mkdir()
        events = [
            {"type": "system", "subtype": "init", "session_id": session, "model": "claude-opus-5-5",
             "claude_code_version": "2.1.296", "tools": []},
            {"type": "stream_event", "session_id": session, "event": {"type": "message_start", "message": {
                "id": identity + "-message", "model": "claude-opus-5-5",
                "usage": {"input_tokens": 1, "cache_creation_input_tokens": 9, "cache_read_input_tokens": 90}}}},
            {"type": "stream_event", "session_id": session, "event": {"type": "content_block_delta", "index": 0,
                "delta": {"type": "thinking_delta", "thinking": "PRIVATE"}}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "x",
                                                      "content": "PRIVATE output"}]}},
        ]
        if refused:
            events += [
                {"type": "stream_event", "session_id": session, "event": {"type": "message_delta", "delta": {
                    "stop_reason": "refusal", "stop_details": {"category": "reasoning_extraction",
                                                               "explanation": "public"}}}},
                {"type": "system", "subtype": "informational", "level": "notice",
                 "content": "Safeguards stopped the response"}]
        events += list(extra)
        if result is not None:
            events.append(dict(result, session_id=session))
        with (target / "protocol.jsonl").open("w") as stream:
            for event in events:
                stream.write(json.dumps({"stream": "stdout", "line": json.dumps(event)}) + "\n")
        (target / "prompt.txt").write_text(prompt)
        if intent:  # Pair reader job directories have no intent file.
            (target / "intent.json").write_text(json.dumps({"id": identity, "role": "code"}))
        if launch is not None:
            saved = {"initialization": {"session_id": session}, "launch": launch}
            if completion is not None:
                saved["completion"] = completion
            (target / "claude-diagnostics.json").write_text(json.dumps(saved))
        os.utime(target / "prompt.txt", (started, started))
        return target

    def fixture(self):
        codex = self.directory / "invocations" / ("d" * 32)
        codex.mkdir()
        (codex / "protocol.jsonl").write_text(json.dumps({"stream": "stdout", "line": json.dumps(
            {"jsonrpc": "2.0", "method": "turn/started", "params": {"text": "PRIVATE codex"}})}) + "\n")
        context = 'Runtime context:\n{"secret": "PRIVATE context"}\n\n'
        self.claude_invocation("b" * 32, "11111111-1111-1111-1111-111111111111", 1000,
            "Implement the stage.\n\n" + context + "Shared rule.\n\nOld rule.\nOld detail.\n",
            launch={"role": "code", "resumed": False, "role_contract_sha256": "a" * 64,
                    "instruction_files": [{"path": "/user/CLAUDE.md", "sha256": "1" * 64}]}, result=self.SUCCESS)
        # The coder's report is embedded prompt data, not a runtime instruction.
        self.claude_invocation("c" * 32, "22222222-2222-2222-2222-222222222222", 2000,
            "Implement the stage.\n\n" + context + "Shared rule.\n\n" + WRITING_CONTRACT
            + "\n\nPRIVATE coder report line\nSECRET report detail\n",
            refused=True, result=self.SUCCESS,
            launch={"role": "code", "resumed": False, "role_contract_sha256": "a" * 64,
                    "instruction_files": [{"path": "/user/CLAUDE.md", "sha256": "2" * 64}]})
        return {"sessions": {"code": "22222222-2222-2222-2222-222222222222"},
                "blocker": {"code": "claude-refusal", "interrupted": {"id": "c" * 32, "role": "code"}}}

    def test_history_names_onset_differences_without_content(self):
        state = self.fixture()
        result = refusal_history(self.directory, state, self.root)
        self.assertEqual(result["scanned"]["claude_invocations"], 2)
        self.assertEqual([r["invocation"] for r in result["refusals"]], ["c" * 32])
        refusal = result["refusals"][0]["refusals"][0]
        self.assertEqual((refusal["category"], refusal["sequence"], refusal["input_tokens"]),
                         ("reasoning_extraction", 1, 100))
        self.assertEqual(result["refusals"][0]["cli_refusal_notices"], 1)
        onset = result["onset"]
        self.assertEqual(onset["last_completed_before"]["invocation"], "b" * 32)
        self.assertEqual(onset["last_completed_before"]["result"]["subtype"], "success")
        self.assertEqual(onset["first_refusal"]["instruction_files_timing"], "unknown")  # Saved before the fix.
        self.assertFalse(onset["first_refusal"]["completed"])  # A later success result does not erase a refusal.
        self.assertEqual(onset["differences"]["prompt_blocks_added"][0], "Instruction and knowledge writing rules:")
        self.assertEqual(onset["differences"]["prompt_blocks_added_unrecognized"], 1)
        self.assertEqual(onset["differences"]["prompt_blocks_removed"], [])
        self.assertEqual(onset["differences"]["prompt_blocks_removed_unrecognized"], 1)
        self.assertEqual(onset["not_compared"], ["instruction_files"])
        # These records have no capture marker, so the hashes come from completion.
        self.assertEqual(onset["differences"]["instruction_files_timing_unknown"], ["/user/CLAUDE.md"])
        self.assertNotIn("instruction_files", onset["differences"])
        self.assertNotIn("role_contract_sha256", onset["differences"])
        self.assertEqual(result["sessions"][0]["current_roles"], ["code"])
        self.assertTrue(result["retry"]["same_conversation"])
        self.assertTrue(result["retry"]["role_contract_changed"])
        # The current contract in its plain or review-campaign form is unchanged.
        from cycle_prompts import role_contract
        from focus_review_contract import review_contract
        diagnostics = self.directory / "invocations" / ("c" * 32) / "claude-diagnostics.json"
        original = diagnostics.read_text()
        for campaign in (False, True):
            with self.subTest(campaign=campaign):
                saved = json.loads(original)
                saved["launch"]["role_contract_sha256"] = hashlib.sha256(
                    review_contract(role_contract("code"), campaign).encode("utf-8")).hexdigest()
                diagnostics.write_text(json.dumps(saved))
                self.assertIs(refusal_history(self.directory, state, self.root)["retry"]["role_contract_changed"], False)
        diagnostics.write_text(original)
        for private in ("PRIVATE", "SECRET", "Old rule", "Old detail"):
            self.assertNotIn(private, json.dumps(result))
        state["sessions"] = {}
        self.assertFalse(refusal_history(self.directory, state, self.root)["retry"]["same_conversation"])
        self.assertIsNone(refusal_history(self.directory)["retry"])

    def test_only_a_successful_terminal_result_becomes_the_onset_reference(self):
        state = self.fixture()  # "b" (code) completed at 1000. "c" (code) is the first refusal at 2000.
        session = "66666666-6666-6666-6666-666666666666"
        error = {"type": "result", "subtype": "error_during_execution", "is_error": True, "errors": ["PRIVATE"]}
        refused_result = dict(self.SUCCESS, is_error=True, stop_reason="refusal", terminal_reason="api_error")
        notice = {"type": "system", "subtype": "model_refusal_no_fallback", "api_refusal_category": "cyber"}
        ineligible = [("1" * 32, 1100, error, ()), ("2" * 32, 1200, None, ()), ("3" * 32, 1300, refused_result, ()),
                      ("4" * 32, 1400, self.SUCCESS, (notice,)), ("5" * 32, 1500, dict(self.SUCCESS, is_error=None), ())]
        for identity, started, result, extra in ineligible:
            self.claude_invocation(identity, session, started, "Implement.\n", result=result, extra=extra,
                                   launch={"role": "code"})
        self.assertEqual(refusal_history(self.directory, state)["onset"]["last_completed_before"]["invocation"], "b" * 32)
        self.claude_invocation("6" * 32, session, 1600, "Review.\n", result=self.SUCCESS, launch={"role": "review"})
        onset = refusal_history(self.directory, state)["onset"]
        self.assertEqual(onset["last_completed_before"]["invocation"], "b" * 32)  # Same role first.
        self.assertFalse(any(r["completed"] for r in refusal_history(self.directory, state)["refusals"]))
        (self.directory / "invocations" / ("b" * 32)).rename(self.root / "removed")
        onset = refusal_history(self.directory, state)["onset"]
        self.assertEqual(onset["last_completed_before"]["invocation"], "6" * 32)  # Other eligible role.
        self.assertEqual(onset["differences"]["role"], ["review", "code"])
        (self.directory / "invocations" / ("6" * 32)).rename(self.root / "removed-review")
        onset = refusal_history(self.directory, state)["onset"]
        self.assertIsNone(onset["last_completed_before"])
        self.assertEqual(onset["differences"], {})

    def test_a_result_that_quotes_skipped_markers_still_counts(self):
        self.claude_invocation("b" * 32, "11111111-1111-1111-1111-111111111111", 1000, "Implement.\n",
                               result=dict(self.SUCCESS, result='{"type":"tool_result","content_block_delta":1}'),
                               launch={"role": "code"})
        self.claude_invocation("c" * 32, "22222222-2222-2222-2222-222222222222", 2000, "Implement.\n",
                               refused=True, launch={"role": "code"})
        self.assertEqual(refusal_history(self.directory)["onset"]["last_completed_before"]["invocation"], "b" * 32)

    def test_instruction_hash_timing_is_explicit(self):
        files = lambda digit: [{"scope": "user", "path": "/user/CLAUDE.md", "sha256": digit * 64}]
        self.claude_invocation("b" * 32, "11111111-1111-1111-1111-111111111111", 1000, "Implement.\n",
                               result=self.SUCCESS, launch={"role": "code", "instruction_files": files("1")},
                               completion={"instruction_files": files("2")})  # Older record: no capture marker.
        self.claude_invocation("c" * 32, "22222222-2222-2222-2222-222222222222", 2000, "Implement.\n", refused=True,
                               launch={"role": "code", "instruction_files": files("1"),
                                       "instruction_files_captured": "before-start"},
                               completion={"instruction_files": files("3")})
        onset = refusal_history(self.directory)["onset"]
        legacy, current = onset["last_completed_before"], onset["first_refusal"]
        self.assertEqual((legacy["instruction_files_timing"], legacy["instruction_files_changed_during_run"]),
                         ("unknown", None))
        self.assertEqual((current["instruction_files_timing"], current["instruction_files_changed_during_run"]),
                         ("before-start", ["/user/CLAUDE.md"]))
        self.assertNotIn("instruction_files", onset["differences"])  # Both launch records name hash 1.
        self.assertEqual(diagnose(self.directory, "b" * 32)["launch"]["instruction_files_captured"], "unknown")
        self.assertNotIn("completion", diagnose(self.directory, "b" * 32))
        result = diagnose(self.directory, "c" * 32)
        self.assertEqual(result["launch"]["instruction_files_captured"], "before-start")
        self.assertEqual(result["completion"]["instruction_files"][0]["sha256"], "3" * 64)

    def test_refused_pair_reader_session_blocks_a_plain_retry(self):
        refused = self.claude_invocation("f" * 32, "44444444-4444-4444-4444-444444444444", 4000, "Inspect.\n",
                                         refused=True, launch={"role": "pair_opus_max", "role_contract_sha256": "a" * 64})
        (refused / "claude-diagnostics.json").unlink()  # Older runs keep the evidence only in the protocol.
        self.claude_invocation("9" * 32, "55555555-5555-5555-5555-555555555555", 4001, "Inspect.\n")
        jobs = {"scan/pair_opus_max": {"id": "f" * 32, "role": "pair_opus_max",
                                       "sessions": {"pair_opus_max": "44444444-4444-4444-4444-444444444444"}},
                "scan/pair_astra": {"id": "9" * 32, "role": "pair_astra", "result": "saved",
                                    "sessions": {"pair_astra": "55555555-5555-5555-5555-555555555555"}}}
        state = {"sessions": {}, "pair_review": {"jobs": jobs},
                 "blocker": {"code": "claude-refusal", "interrupted": {"id": "8" * 32, "role": "pair_group"}}}
        history = refusal_history(self.directory, state, self.root)
        self.assertEqual(history["sessions"][0]["current_roles"], ["pair_opus_max"])
        retry = history["retry"]
        self.assertTrue(retry["same_conversation"])
        self.assertEqual([(s["invocation"], s["role"]) for s in retry["selected_refusals"]], [("f" * 32, "pair_opus_max")])
        jobs["scan/pair_opus_max"]["sessions"] = {}  # --new-sessions clears unfinished reader sessions.
        self.assertFalse(refusal_history(self.directory, state, self.root)["retry"]["same_conversation"])
        jobs["scan/pair_opus_max"]["sessions"] = {"pair_opus_max": "44444444-4444-4444-4444-444444444444"}
        self.assertEqual(len(selected_refusals(self.directory, state)), 1)
        # A correction drops the pair review with its reader jobs, so it resends nothing.
        self.assertEqual(selected_refusals(self.directory, state, correction=True), [])
        state.update(sessions={"repair_execute": "44444444-4444-4444-4444-444444444444"},
                     blocker={"code": "claude-refusal", "interrupted": {"id": "f" * 32, "role": "repair_execute"}})
        self.assertEqual(len(selected_refusals(self.directory, state)), 2)
        self.assertEqual(selected_refusals(self.directory, state, correction=True), [])  # A new batch drops it.
        state["blocker"]["code"] = "claude-failed"
        self.assertEqual(selected_refusals(self.directory, state), [])

    def write_protocol(self, target, frames):
        with (target / "protocol.jsonl").open("w") as stream:
            for stream_name, value in frames:
                stream.write(json.dumps({"stream": stream_name, "line": json.dumps(value)}) + "\n")

    def test_attempt_marks_separate_processes_in_a_reused_directory(self):
        refused, retried = "77777777-7777-7777-7777-777777777777", "88888888-8888-8888-8888-888888888888"
        target = self.directory / "invocations" / ("a" * 32)
        target.mkdir()
        init = lambda session: {"type": "system", "subtype": "init", "session_id": session,
                                "model": "claude-opus-5-5", "claude_code_version": "2.1.296"}
        mark = lambda attempt, session, started: {"type": "attempt", "attempt": attempt, "provider": "claude",
                                                  "session_id": session, "resumed": False, "started": started}
        refusal = {"type": "assistant", "session_id": refused, "message": {
            "id": "m1", "model": "claude-opus-5-5", "stop_reason": "refusal", "content": []}}
        org_error = {"type": "assistant", "session_id": retried, "is_api_error_message": True,
                     "error": "oauth_org_not_allowed", "message": {"model": "<synthetic>", "content": []}}
        # The retry fails before its init event. It must not take over the refused conversation.
        self.write_protocol(target, [("runtime", mark("1" * 32, refused, 1100)), ("stdout", init(refused)),
                                     ("stdout", refusal), ("runtime", mark("2" * 32, retried, 2000)),
                                     ("stdout", org_error)])
        (target / "prompt.txt").write_text("Inspect.\n")
        files = [{"scope": "user", "path": "/user/CLAUDE.md", "sha256": "2" * 64}]
        (target / "claude-diagnostics.json").write_text(json.dumps({"initialization": {}, "refusals": [], "launch": {
            "role": "pair_opus_max", "requested_model": "opus", "attempt": "2" * 32, "role_contract_sha256": "a" * 64,
            "session_id": retried, "cwd": str(self.root),  # The runtime always records both.
            "instruction_files": files, "instruction_files_captured": "before-start"}}))
        self.claude_invocation("b" * 32, "11111111-1111-1111-1111-111111111111", 1000, "Inspect.\n",
                               result=self.SUCCESS, launch={"role": "pair_opus_max", "requested_model": "opus",
                               "role_contract_sha256": "a" * 64, "instruction_files": files,
                               "instruction_files_captured": "before-start"}, intent=False)
        result = refusal_history(self.directory)
        first = result["onset"]["first_refusal"]
        self.assertEqual((first["session_id"], first["attempt"], first["attempts"]), (refused, 1, 2))
        self.assertEqual((first["started"], first["start_time_estimated"]), (1100, False))
        self.assertIsNone(first["role_contract_sha256"])  # The saved launch belongs to the retry.
        self.assertEqual(result["onset"]["last_completed_before"]["invocation"], "b" * 32)
        self.assertEqual(result["onset"]["differences"], {})
        self.assertEqual(result["onset"]["not_compared"], ["role_contract_sha256", "instruction_files", "prompt_blocks"])
        self.assertEqual([s["session_id"] for s in result["sessions"]], [refused])
        self.assertEqual(saved_claude_call(self.directory, "a" * 32)["session_id"], retried)
        attempts = diagnose(self.directory, "a" * 32)["attempts"]
        self.assertEqual([(a["session_id"], a["started"], a["refusals"]) for a in attempts],
                         [(refused, 1100, 1), (retried, 2000, 0)])
        # The native log of the refused attempt is named after its session, not the latest one.
        native = self.root / "native" / (refused + ".jsonl")
        native.parent.mkdir()
        native.write_text(json.dumps({"sessionId": refused, "cwd": str(self.root), "type": "attachment",
                                      "attachment": {"type": "instructions", "files": []}}) + "\n")
        self.assertEqual(diagnose(self.directory, "a" * 32, native_log=native)["native_context"]["session_id"], refused)

    def test_older_logs_split_at_a_new_session_even_before_init(self):
        first_session, retried = "77777777-7777-7777-7777-777777777777", "88888888-8888-8888-8888-888888888888"
        target = self.directory / "invocations" / ("a" * 32)
        target.mkdir()
        refusal = {"type": "assistant", "session_id": retried, "is_api_error_message": True, "message": {
            "id": "m", "model": "<synthetic>", "stop_reason": "refusal", "content": []}}
        self.write_protocol(target, [("stdout", {"type": "system", "subtype": "init", "session_id": first_session,
                                                 "model": "claude-opus-5-5", "claude_code_version": "2.1.296"}),
                                     ("stdout", dict(self.SUCCESS, session_id=first_session)), ("stdout", refusal)])
        (target / "prompt.txt").write_text("Inspect.\n")
        os.utime(target / "prompt.txt", (2000, 2000))
        self.assertEqual(saved_claude_call(self.directory, "a" * 32), {"session_id": retried, "refused": True})
        rows = refusal_history(self.directory)
        first = rows["onset"]["first_refusal"]
        self.assertEqual((first["session_id"], first["attempt"], first["started"]), (retried, 2, 2000))
        self.assertIsNone(rows["onset"]["last_completed_before"])  # Attempt 1 has no known start time.
        self.assertEqual((rows["scanned"]["claude_invocations"], rows["scanned"]["claude_attempts"]), (1, 2))

    def test_paired_readers_load_no_instruction_files_so_none_are_compared(self):
        files = [{"scope": "user", "path": "/user/CLAUDE.md", "sha256": "1" * 64}]
        self.claude_invocation("b" * 32, "11111111-1111-1111-1111-111111111111", 1000, "Implement.\n",
                               result=self.SUCCESS, launch={"role": "code", "instruction_files": files,
                               "instruction_files_captured": "before-start", "instruction_files_enabled": True})
        self.claude_invocation("c" * 32, "22222222-2222-2222-2222-222222222222", 2000, "Inspect.\n", refused=True,
                               launch={"role": "pair_opus_max", "instruction_files": [],
                                       "instruction_files_captured": "before-start", "instruction_files_enabled": False})
        onset = refusal_history(self.directory)["onset"]
        self.assertEqual(onset["last_completed_before"]["invocation"], "b" * 32)  # Fallback to another role.
        self.assertNotIn("instruction_files", onset["differences"])
        self.assertIn("instruction_files", onset["not_compared"])

    def test_a_later_turn_without_a_result_is_not_completed(self):
        trace = ClaudeTrace()
        trace.feed(dict(self.SUCCESS, session_id="s"))
        self.assertEqual(trace.report()["result"]["subtype"], "success")
        trace.feed({"type": "stream_event", "session_id": "s", "event": {"type": "message_start",
                    "message": {"id": "turn-2", "model": "claude-opus-5-5"}}})
        self.assertEqual(trace.report()["result"], {})  # The process stopped during the second turn.

    def test_a_deferred_result_is_not_a_completed_attempt(self):
        task = lambda subtype, **extra: dict({"type": "system", "subtype": subtype, "task_id": "t1",
                                              "session_id": "s"}, **extra)
        trace = ClaudeTrace()
        trace.feed(task("task_started"))
        trace.feed(dict(self.SUCCESS, session_id="s"))  # The process ends while the native task runs.
        self.assertTrue(trace.report()["result"]["deferred"])
        trace.feed(task("task_notification", status="completed"))
        trace.feed(dict(self.SUCCESS, session_id="s", queued_turn_count=1))
        self.assertTrue(trace.report()["result"]["deferred"])
        trace.feed(dict(self.SUCCESS, session_id="s", queued_turn_count=0))
        self.assertFalse(trace.report()["result"]["deferred"])
        trace.feed({"type": "user", "session_id": "s", "message": {"role": "user", "content": "Operator message"}})
        self.assertEqual(trace.report()["result"], {})  # A replayed operator message starts a new turn.
        self.claude_invocation("b" * 32, "11111111-1111-1111-1111-111111111111", 1000, "Implement.\n",
                               extra=[task("task_started", session_id="11111111-1111-1111-1111-111111111111")],
                               result=self.SUCCESS, launch={"role": "code"})
        self.claude_invocation("c" * 32, "22222222-2222-2222-2222-222222222222", 2000, "Implement.\n",
                               refused=True, launch={"role": "code"})
        onset = refusal_history(self.directory)["onset"]
        self.assertIsNone(onset["last_completed_before"])  # The runtime rejected that attempt as provider-eof.

    def test_an_operator_message_that_quotes_a_skip_marker_still_starts_a_turn(self):
        session = "11111111-1111-1111-1111-111111111111"
        echo = {"type": "user", "session_id": session,
                "message": {"role": "user", "content": "Please also cover the tool_result parser"}}
        self.claude_invocation("b" * 32, session, 1000, "Implement.\n", launch={"role": "code"},
                               extra=[dict(self.SUCCESS, session_id=session), echo])
        self.claude_invocation("c" * 32, "22222222-2222-2222-2222-222222222222", 2000, "Implement.\n",
                               refused=True, launch={"role": "code"})
        # The process stopped before the model answered the operator message.
        self.assertIsNone(refusal_history(self.directory)["onset"]["last_completed_before"])

    def test_an_unknown_role_gets_no_same_role_preference(self):
        anonymous = dict(intent=False)
        self.claude_invocation("a" * 32, "11111111-1111-1111-1111-111111111111", 1000, "Inspect.\n",
                               result=self.SUCCESS, **anonymous)
        self.claude_invocation("b" * 32, "33333333-3333-3333-3333-333333333333", 1500, "Implement.\n",
                               result=self.SUCCESS, launch={"role": "code"})
        self.claude_invocation("c" * 32, "22222222-2222-2222-2222-222222222222", 2000, "Inspect.\n",
                               refused=True, **anonymous)
        onset = refusal_history(self.directory)["onset"]
        self.assertIsNone(onset["first_refusal"]["role"])
        self.assertEqual(onset["last_completed_before"]["invocation"], "b" * 32)  # The latest completed attempt.

    def test_native_log_hints_and_checks_use_the_process_directory(self):
        session, view = "99999999-9999-9999-9999-999999999999", self.root / "frozen-view"
        view.mkdir()
        target = self.directory / "invocations" / ("a" * 32)
        target.mkdir()
        # Only the saved launch record names the session here.
        refusal = {"type": "assistant", "is_api_error_message": True,
                   "message": {"id": "m", "model": "<synthetic>", "stop_reason": "refusal", "content": []}}
        self.write_protocol(target, [("runtime", {"type": "attempt", "attempt": "1" * 32, "provider": "claude",
                                                  "started": 1500, "cwd": str(view)}),
                                     ("stdout", refusal)])
        (target / "claude-diagnostics.json").write_text(json.dumps({"initialization": {}, "refusals": [], "launch": {
            "role": "pair_opus_max", "requested_model": "opus", "attempt": "1" * 32, "session_id": session,
            "cwd": str(view)}}))
        config = self.root / "config"
        native = config / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(view)) / (session + ".jsonl")
        native.parent.mkdir(parents=True)
        native.write_text(json.dumps({"sessionId": session, "cwd": str(view), "type": "attachment",
                                      "attachment": {"type": "instructions", "files": []}}) + "\n")
        with patch.dict(os.environ, CLAUDE_CONFIG_DIR=str(config)):
            hint = refusal_history(self.directory, root=self.root)["onset"]["native_logs"][0]
        self.assertEqual((hint["path"], hint["exists"]), (str(native), True))
        # The process ended before its init event. The launch record still names the session and directory.
        # A copy with another file name cannot select an attempt, so the launch record decides.
        copy = self.root / "copy.jsonl"
        copy.write_text(native.read_text())
        self.assertEqual(diagnose(self.directory, "a" * 32, native_log=copy)["native_context"]["session_id"], session)

    def test_quoted_skip_markers_do_not_hide_attempts_or_tasks(self):
        first, second = "77777777-7777-7777-7777-777777777777", "88888888-8888-8888-8888-888888888888"
        cwd = str(self.root / "tool_result_viewer")  # A real project path can quote a skip marker.
        target = self.directory / "invocations" / ("a" * 32)
        target.mkdir()
        mark = lambda attempt, session, started: {"type": "attempt", "attempt": attempt, "provider": "claude",
                                                  "session_id": session, "started": started, "cwd": cwd}
        init = lambda session: {"type": "system", "subtype": "init", "session_id": session, "cwd": cwd,
                                "model": "claude-opus-5-5", "claude_code_version": "2.1.296"}
        task = {"type": "system", "subtype": "task_started", "task_id": "t", "session_id": first,
                "description": "Run tests for tool_result parsing"}
        refusal = {"type": "assistant", "session_id": second,
                   "message": {"id": "m", "model": "claude-opus-5-5", "stop_reason": "refusal", "content": []}}
        self.write_protocol(target, [("runtime", mark("1" * 32, first, 1000)), ("stdout", init(first)),
                                     ("stdout", task), ("stdout", dict(self.SUCCESS, session_id=first)),
                                     ("runtime", mark("2" * 32, second, 2000)), ("stdout", init(second)),
                                     ("stdout", refusal)])
        (target / "prompt.txt").write_text("Inspect.\n")
        (target / "claude-diagnostics.json").write_text(json.dumps({"initialization": {}, "refusals": [], "launch": {
            "role": "code", "requested_model": "opus", "attempt": "2" * 32, "role_contract_sha256": "a" * 64}}))
        result = refusal_history(self.directory)
        refused = result["onset"]["first_refusal"]
        self.assertEqual((refused["attempt"], refused["attempts"], refused["claude_code_version"]), (2, 2, "2.1.296"))
        self.assertEqual(refused["role_contract_sha256"], "a" * 64)  # The launch record found its attempt.
        self.assertIsNone(result["onset"]["last_completed_before"])  # The first result waited for a task.
        self.assertEqual((result["sessions"][0]["invocations"], result["sessions"][0]["attempts"]), (1, 1))

    def test_session_counts_separate_invocations_and_attempts(self):
        session = "77777777-7777-7777-7777-777777777777"
        target = self.claude_invocation("a" * 32, session, 1000, "Implement.\n", refused=True, launch={"role": "code"})
        with (target / "protocol.jsonl").open("a") as stream:  # The same conversation resumes in a new process.
            stream.write(json.dumps({"stream": "runtime", "line": json.dumps(
                {"type": "attempt", "attempt": "3" * 32, "provider": "claude", "session_id": session, "started": 1500})}) + "\n")
            stream.write(json.dumps({"stream": "stdout", "line": json.dumps(dict(self.SUCCESS, session_id=session))}) + "\n")
        item = refusal_history(self.directory)["sessions"][0]
        self.assertEqual((item["invocations"], item["refused_invocations"], item["attempts"], item["refused_attempts"]),
                         (1, 1, 2, 1))

    def test_a_refusal_before_any_init_event_is_listed(self):
        session = "99999999-9999-9999-9999-999999999999"
        target = self.directory / "invocations" / ("a" * 32)
        target.mkdir()
        self.write_protocol(target, [("runtime", {"type": "attempt", "attempt": "1" * 32, "provider": "claude",
                                                  "session_id": session, "started": 1500}),
                                     ("stdout", {"type": "assistant", "session_id": session, "is_api_error_message": True,
                                                 "message": {"id": "m", "model": "<synthetic>", "stop_reason": "refusal",
                                                             "content": []}})])
        result = refusal_history(self.directory)
        self.assertEqual(result["onset"]["first_refusal"]["session_id"], session)
        self.assertEqual(result["onset"]["first_refusal"]["started"], 1500)

    def stale_cache_case(self, first_session, latest_session, first_refused, latest_refused, marked_first=True,
                         marked_latest=True):
        """Attempt 1 saved its diagnostics. Attempt 2 refused or completed, but its diagnostic write failed."""
        target = self.directory / "invocations" / ("a" * 32)
        target.mkdir()
        init = lambda session: {"type": "system", "subtype": "init", "session_id": session,
                                "model": "claude-opus-5-5", "claude_code_version": "2.1.296"}
        refusal = lambda session: {"type": "assistant", "session_id": session, "message": {
            "id": "m-" + session[:4], "model": "claude-opus-5-5", "stop_reason": "refusal", "content": []}}
        frames = []
        for number, session, refused in ((1, first_session, first_refused), (2, latest_session, latest_refused)):
            if marked_first if number == 1 else marked_latest:
                frames.append(("runtime", {"type": "attempt", "attempt": str(number) * 32, "provider": "claude",
                                           "session_id": session, "started": 1000 * number}))
            frames.append(("stdout", init(session)))
            frames.append(("stdout", refusal(session) if refused else dict(self.SUCCESS, session_id=session)))
        self.write_protocol(target, frames)
        launch = {"role": "pair_opus", "requested_model": "opus", "session_id": first_session}
        if marked_first:
            launch["attempt"] = "1" * 32
        (target / "claude-diagnostics.json").write_text(json.dumps({
            "initialization": {"session_id": first_session}, "launch": launch,
            "refusals": [{"session_id": first_session}] if first_refused else []}))
        return saved_claude_call(self.directory, "a" * 32)

    def test_a_stale_saved_file_cannot_describe_a_later_attempt(self):
        same, other = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
        cases = (  # (first session, latest session, first refused, latest refused, marked first) -> expected
            ((same, same, False, True, True), {"session_id": same, "refused": True}),
            ((same, same, False, True, False), {"session_id": same, "refused": True}),  # Older saved file.
            ((same, other, False, True, True), {"session_id": other, "refused": True}),
            ((same, other, True, False, True), {"session_id": other, "refused": False}),
            # A stale refused file in the same session cannot mark the later completed attempt as refused.
            ((same, same, True, False, True), {"session_id": same, "refused": False}),
            ((same, same, True, False, False), {"session_id": same, "refused": False}),
            # Without attempt marks, a saved file cannot hide a refusal that the log records.
            ((same, same, False, True, False, False), {"session_id": same, "refused": True}),
        )
        for arguments, expected in cases:
            with self.subTest(arguments=arguments):
                self.tearDown()
                self.setUp()
                self.assertEqual(self.stale_cache_case(*arguments), expected)

    def test_an_older_launch_record_is_not_credited_to_a_later_refused_attempt(self):
        session = "11111111-1111-1111-1111-111111111111"
        # An older runtime saved this file. A newer runtime then resumed the invocation, the provider
        # refused, and the diagnostic write failed.
        target = self.claude_invocation("a" * 32, session, 1000, "Implement.\n", result=self.SUCCESS, launch={
            "role": "code", "requested_model": "opus", "role_contract_sha256": "0" * 64,
            "instruction_files": [{"scope": "user", "path": "/user/CLAUDE.md", "sha256": "1" * 64}]})
        with (target / "protocol.jsonl").open("a") as stream:
            for frame, event in (("runtime", {"type": "attempt", "attempt": "2" * 32, "provider": "claude",
                                              "session_id": session, "started": 2000}),
                                 ("stdout", {"type": "assistant", "session_id": session, "message": {
                                     "id": "refused", "model": "claude-opus-5-5", "stop_reason": "refusal", "content": []}})):
                stream.write(json.dumps({"stream": frame, "line": json.dumps(event)}) + "\n")
        state = {"sessions": {"code": session},
                 "blocker": {"code": "claude-refusal", "interrupted": {"id": "a" * 32, "role": "code"}}}
        result = refusal_history(self.directory, state)
        first = result["onset"]["first_refusal"]
        self.assertEqual((first["attempt"], first["attempts"]), (2, 2))
        self.assertIsNone(first["role_contract_sha256"])  # The older record describes attempt 1 only.
        self.assertIsNone(first["instruction_files"])
        reference = result["onset"]["last_completed_before"]
        self.assertEqual((reference["attempt"], reference["role_contract_sha256"]), (1, "0" * 64))
        self.assertTrue(first["prompt_known"])  # The runtime wrote the prompt file just before attempt 2.
        self.assertIsNone(result["retry"]["selected_refusals"][0]["role_contract_changed"])

    def test_a_named_launch_record_describes_only_its_own_attempt(self):
        session = "11111111-1111-1111-1111-111111111111"
        self.stale_cache_case(session, session, False, True)  # Attempt 2 refused. Its diagnostic write failed.
        target = self.directory / "invocations" / ("a" * 32)
        (target / "prompt.txt").write_text("Inspect.\n")
        saved = json.loads((target / "claude-diagnostics.json").read_text())
        saved["launch"]["role_contract_sha256"] = "0" * 64
        (target / "claude-diagnostics.json").write_text(json.dumps(saved))
        state = {"sessions": {}, "pair_review": {"jobs": {"scan/pair_opus": {
                     "id": "a" * 32, "role": "pair_opus", "sessions": {"pair_opus": session}}}},
                 "blocker": {"code": "claude-refusal", "interrupted": {"id": "b" * 32, "role": "pair_group"}}}
        result = refusal_history(self.directory, state)
        first = result["onset"]["first_refusal"]
        self.assertEqual((first["attempt"], first["role_contract_sha256"], first["prompt_known"]), (2, None, True))
        self.assertEqual(result["onset"]["last_completed_before"]["role_contract_sha256"], "0" * 64)  # Attempt 1.
        self.assertIsNone(result["retry"]["selected_refusals"][0]["role_contract_changed"])

    def test_a_saved_file_of_the_last_attempt_still_counts(self):
        session = "11111111-1111-1111-1111-111111111111"
        target = self.directory / "invocations" / ("a" * 32)
        target.mkdir()
        self.write_protocol(target, [("runtime", {"type": "attempt", "attempt": "1" * 32, "provider": "claude",
                                                  "session_id": session, "started": 1000})])
        (target / "claude-diagnostics.json").write_text(json.dumps({"initialization": {}, "refusals": [{"session_id": session}],
            "launch": {"role": "pair_opus", "attempt": "1" * 32, "session_id": session}}))
        # The process stopped before it wrote its events. Only the saved file records the refusal.
        self.assertEqual(saved_claude_call(self.directory, "a" * 32), {"session_id": session, "refused": True})
        saved = (target / "claude-diagnostics.json").read_text()
        (target / "claude-diagnostics.json").write_text("{damaged")
        self.assertEqual(saved_claude_call(self.directory, "a" * 32), {"session_id": session, "refused": False})
        (target / "protocol.jsonl").unlink()
        self.assertIsNone(saved_claude_call(self.directory, "a" * 32))
        (target / "claude-diagnostics.json").write_text(saved)  # Without a protocol log, the file is the evidence.
        self.assertEqual(saved_claude_call(self.directory, "a" * 32), {"session_id": session, "refused": True})

    def test_a_refusal_before_the_init_event_still_names_its_session(self):
        session = "99999999-9999-9999-9999-999999999999"
        target = self.directory / "invocations" / ("a" * 32)
        target.mkdir()
        refusal = {"type": "assistant", "session_id": session, "is_api_error_message": True, "message": {
            "id": "m", "model": "<synthetic>", "stop_reason": "refusal", "content": []}}
        (target / "protocol.jsonl").write_text(json.dumps({"stream": "stdout", "line": json.dumps(refusal)}) + "\n")
        self.assertEqual(saved_claude_call(self.directory, "a" * 32), {"session_id": session, "refused": True})
        (target / "claude-diagnostics.json").write_text(json.dumps(
            {"initialization": {}, "refusals": [{"session_id": session}]}))
        self.assertEqual(saved_claude_call(self.directory, "a" * 32), {"session_id": session, "refused": True})
        state = {"sessions": {"code": session}, "blocker": {"code": "claude-refusal",
                 "interrupted": {"id": "a" * 32, "role": "code"}}}
        self.assertEqual(len(selected_refusals(self.directory, state)), 1)

    def test_lone_surrogates_in_provider_metadata_stay_encodable(self):
        trace = ClaudeTrace()
        trace.feed(json.loads('{"type": "system", "subtype": "informational", "content": "notice \\ud83d"}'))
        json.dumps(trace.report(), ensure_ascii=False).encode("utf-8")

    def test_other_provider_logs_that_quote_claude_fields_are_ignored(self):
        target = self.directory / "invocations" / ("7" * 32)
        target.mkdir()
        quoted = {"jsonrpc": "2.0", "method": "item/completed", "params": {
            "text": '{"type":"system","subtype":"init","claude_code_version":"2.1.296"}'}}
        (target / "protocol.jsonl").write_text(json.dumps({"stream": "stdout", "line": json.dumps(quoted)}) + "\n")
        self.assertEqual(refusal_history(self.directory)["scanned"]["claude_invocations"], 0)

    def test_cli_history_tolerates_damaged_state_and_writes_nothing(self):
        self.fixture()
        (self.directory / "state.json").write_text("unreadable state remains preserved")
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.LocalLock", side_effect=AssertionError), \
                patch("cc_focus.Transport", side_effect=AssertionError), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main(["diagnose", "--refusals"]), 0)
        result = json.loads(output.getvalue())
        self.assertEqual(result["onset"]["first_refusal"]["invocation"], "c" * 32)
        self.assertIsNone(result["retry"])
        self.assertEqual(before, {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()})

    def test_refusal_option_rejects_other_diagnostic_targets(self):
        for args in (["--refusals"], ["diagnose", "--refusals", "--invocation", "a" * 32],
                     ["diagnose", "--refusals", "--public-output"],
                     ["diagnose", "--refusals", "--native-log", "x.jsonl"], ["status", "--refusals"]):
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                main(args)

    def test_cli_events_keep_compaction_and_refusal_notices_without_payloads(self):
        trace = ClaudeTrace()
        trace.feed({"type": "stream_event", "session_id": "session", "event": {"type": "message_start",
                    "message": {"id": "message", "model": "claude-opus-5-5"}}})
        trace.feed({"type": "system", "subtype": "compact_boundary", "session_id": "session", "compact_metadata": {
            "trigger": "auto", "pre_tokens": 969704, "post_tokens": 7967,
            "preserved_segment": {"head_uuid": "PRIVATE"}, "summary": "PRIVATE"}})
        trace.feed({"type": "system", "subtype": "informational", "level": "notice",
                    "content": "Opus safeguards stopped the response above", "uuid": "PRIVATE"})
        trace.feed({"type": "system", "subtype": "model_refusal_no_fallback", "api_refusal_category": "reasoning_extraction",
                    "request_id": "request", "original_model": "claude-opus-5-5", "content": "PRIVATE",
                    "api_refusal_explanation": "PRIVATE explanation"})
        events = trace.report()["cli_events"]
        self.assertEqual([e["subtype"] for e in events],
                         ["compact_boundary", "informational", "model_refusal_no_fallback"])
        self.assertEqual((events[0]["pre_tokens"], events[0]["post_tokens"], events[0]["messages_before"]),
                         (969704, 7967, 1))
        self.assertEqual(events[1]["notice"], "Opus safeguards stopped the response above")
        self.assertEqual(events[2]["category"], "reasoning_extraction")
        self.assertNotIn("PRIVATE", json.dumps(trace.report()))
        for index in range(100):
            trace.feed({"type": "system", "subtype": "informational", "content": str(index)})
        self.assertEqual(len(trace.report()["cli_events"]), 32)

    def test_instruction_files_record_fingerprints_only(self):
        config, project = self.root / "config", self.root / "project" / "member"
        (project / ".claude").mkdir(parents=True)
        config.mkdir()
        (config / "CLAUDE.md").write_bytes(b"SECRET user rule")
        (self.root / "project" / "CLAUDE.md").write_bytes(b"SECRET project rule")
        (project / ".claude" / "CLAUDE.md").write_bytes(b"SECRET nested rule")
        (project / "CLAUDE.local.md").write_bytes(b"SECRET local rule")
        with patch.dict(os.environ, CLAUDE_CONFIG_DIR=str(config)):
            files = [f for f in instruction_files(project) if f["path"].startswith(str(self.root))]
            self.assertEqual(instruction_files(project, enabled=False), [])
        self.assertEqual({(f["scope"], Path(f["path"]).relative_to(self.root).as_posix()) for f in files}, {
            ("user", "config/CLAUDE.md"), ("project", "project/CLAUDE.md"),
            ("project", "project/member/.claude/CLAUDE.md"), ("local", "project/member/CLAUDE.local.md")})
        user = next(f for f in files if f["scope"] == "user")
        self.assertEqual(user["sha256"], hashlib.sha256(b"SECRET user rule").hexdigest())
        self.assertEqual(user["bytes"], 16)
        self.assertNotIn("SECRET", json.dumps(files).replace(str(self.root), ""))

    def test_the_user_file_is_listed_once_for_a_project_under_home(self):
        home = self.root / "home"
        project = home / "work" / "repo"
        project.mkdir(parents=True)
        (home / ".claude").mkdir()
        (home / ".claude" / "CLAUDE.md").write_bytes(b"User rule")
        environment = {k: v for k, v in os.environ.items() if k != "CLAUDE_CONFIG_DIR"}
        with patch.dict(os.environ, dict(environment, HOME=str(home)), clear=True):
            files = [f for f in instruction_files(project) if f["path"].startswith(str(self.root))]
        self.assertEqual([(f["scope"], f["path"]) for f in files], [("user", str(home / ".claude" / "CLAUDE.md"))])

    def test_saved_instruction_files_have_a_strict_projection(self):
        target = self.claude_invocation("e" * 32, "33333333-3333-3333-3333-333333333333", 3000, "Rule.\n",
            launch={"role": "code", "instruction_files": [
                {"scope": "user", "path": "/home/CLAUDE.md", "bytes": 9, "sha256": "b" * 64, "content": "SECRET"},
                "PRIVATE", {"scope": "project", "path": "/repo/CLAUDE.md", "bytes": "9", "sha256": "not-a-hash"}]})
        result = diagnose(self.directory, target.name)
        self.assertEqual(result["launch"]["instruction_files"], [
            {"scope": "user", "path": "/home/CLAUDE.md", "bytes": 9, "sha256": "b" * 64},
            {"scope": "project", "path": "/repo/CLAUDE.md", "bytes": None, "sha256": None}])
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertNotIn("PRIVATE", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
