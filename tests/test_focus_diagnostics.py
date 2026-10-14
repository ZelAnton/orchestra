"""Read-only diagnostic tests, without provider access."""

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "tools"))
from cc_focus import main
from cycle_state import Blocked
from focus_diagnostics import ClaudeTrace, diagnose, native_context, payload_metadata


class DiagnosticTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.directory = self.root / ".work/cycle"
        self.identity = "a" * 32
        self.target = self.directory / "invocations" / self.identity
        self.target.mkdir(parents=True)
        self.events = [
            {"type": "system", "subtype": "init", "session_id": "session", "model": "claude-opus-5-5",
             "claude_code_version": "2.1.296", "tools": ["Write"], "apiKey": "SECRET",
             "plugins": [{"name": "example", "path": "SECRET"}]},
            {"type": "stream_event", "session_id": "session", "event": {"type": "message_start",
                "message": {"id": "message", "model": "claude-opus-5-5"}}},
            {"type": "stream_event", "session_id": "session", "event": {"type": "content_block_delta",
                "index": 0, "delta": {"type": "thinking_delta", "thinking": "PRIVATE"}}},
            {"type": "assistant", "session_id": "session", "request_id": "request", "message": {
                "id": "message", "model": "claude-opus-5-5", "stop_reason": None, "content": [
                    {"type": "thinking", "thinking": "PRIVATE", "signature": "SECRET"},
                    {"type": "text", "text": "Public explanation"},
                    {"type": "tool_use", "id": "write", "name": "Write", "input": {"content": "source bytes"}}]}},
            {"type": "user", "message": {"content": [{"type": "tool_result", "tool_use_id": "write", "content": "Saved file"}]}},
            {"type": "stream_event", "session_id": "session", "event": {"type": "message_delta", "delta": {
                "stop_reason": "refusal", "stop_details": {"type": "refusal", "category": "reasoning_extraction",
                    "explanation": "public explanation", "unknown": "PRIVATE"}}}},
            {"type": "result", "subtype": "success", "is_error": False, "result": "PRIVATE final content"},
        ]
        self.write_log()

    def write_log(self):
        with (self.target / "protocol.jsonl").open("w") as stream:
            for event in self.events:
                stream.write(json.dumps({"stream": "stdout", "line": json.dumps(event)}) + "\n")

    def test_diagnosis_keeps_public_metadata_and_excludes_bodies(self):
        (self.target / "prompt.txt").write_bytes(b"SECRET prompt")
        result = diagnose(self.directory, self.identity)
        self.assertEqual(result["prompt"], {"bytes": 13, "sha256": hashlib.sha256(b"SECRET prompt").hexdigest()})
        refusal = result["refusals"][0]
        self.assertEqual((refusal["request_id"], refusal["message_id"]), ("request", "message"))
        self.assertTrue(refusal["last_action"]["result_seen"])
        self.assertEqual(result["initialization"]["plugins"], ["example"])
        for secret in ("SECRET", "PRIVATE", "source bytes", "Public explanation", "Saved file"):
            self.assertNotIn(secret, json.dumps(result))
        self.assertFalse(result["result"]["is_error"])
        self.assertEqual(result["recent_actions"][0]["result"]["sha256"], hashlib.sha256(b"Saved file").hexdigest())

    def test_public_output_omits_private_blocks_and_raw_envelopes(self):
        self.events.pop()  # Model final report is public content, unlike thinking blocks.
        self.write_log()
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertIsNone(diagnose(self.directory, self.identity, True))
        rendered = output.getvalue()
        for public in ("Public explanation", "Write", "source bytes", "Saved file"):
            self.assertIn(public, rendered)
        for private in ("PRIVATE", "SECRET", "thinking_delta", "stop_details"):
            self.assertNotIn(private, rendered)

    def test_cli_diagnosis_never_acquires_ownership_or_changes_state(self):
        (self.directory / "state.json").write_text("unreadable state remains preserved")
        (self.directory / "runtime.lock").write_text("active runtime")
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.LocalLock", side_effect=AssertionError), \
                patch("cc_focus.Transport", side_effect=AssertionError), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main(["diagnose", "--invocation", self.identity]), 0)
        self.assertEqual(json.loads(output.getvalue())["invocation"], self.identity)
        after = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    def test_invalid_cli_combinations_and_path_traversal_fail(self):
        for args in (["diagnose"], ["status", "--invocation", self.identity], ["--public-output"],
                     ["--native-log", "some.jsonl"],
                     ["diagnose", "--invocation", self.identity, "--native-log", "some.jsonl", "--public-output"],
                     ["diagnose", "--invocation", self.identity, "--retry"]):
            with self.subTest(args=args), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                main(args)
        with self.assertRaises(Blocked):
            diagnose(self.directory, "../elsewhere")

    @unittest.skipUnless(shutil.which("pwsh"), "PowerShell 7 is required for the launcher smoke")
    def test_launcher_diagnosis_does_not_create_process_records(self):
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        result = subprocess.run([shutil.which("pwsh"), "-NoProfile", "-File", str(ROOT / "tools/focus-runtime.ps1"),
                                 "diagnose", "--invocation", self.identity],
                                cwd=self.root, capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout)["invocation"], self.identity)
        after = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob("*") if p.is_file()}
        self.assertEqual(before, after)

    @unittest.skipIf(os.name == "nt", "symlink creation requires Windows privileges")
    def test_symlink_logs_are_rejected(self):
        (self.target / "protocol.jsonl").rename(self.root / "saved.jsonl")
        (self.target / "protocol.jsonl").symlink_to(self.root / "saved.jsonl")
        with self.assertRaises(Blocked) as caught:
            diagnose(self.directory, self.identity)
        self.assertEqual(caught.exception.code, "diagnostic-log")

    def test_stderr_malformed_and_partial_records_are_not_exported(self):
        with (self.target / "protocol.jsonl").open("a") as stream:
            stream.write(json.dumps({"stream": "stderr", "line": "PRIVATE"}) + '\n[]\n{"partial":')
        result = diagnose(self.directory, self.identity)
        self.assertEqual(result["events"], len(self.events))
        self.assertNotIn("PRIVATE", json.dumps(result))

    def test_message_ids_do_not_inherit_an_earlier_request_id(self):
        trace = ClaudeTrace()
        for event in self.events:
            trace.feed(event)
        trace.feed({"type": "stream_event", "session_id": "session", "event": {"type": "message_start",
                    "message": {"id": "different", "model": "claude-opus-5-5"}}})
        refusal = trace.feed(self.events[-2])
        self.assertEqual(refusal["message_id"], "different")
        self.assertIsNone(refusal["request_id"])

    def test_long_runs_keep_bounded_diagnostic_history(self):
        trace = ClaudeTrace()
        for index in range(1000):
            trace.feed({"type": "assistant", "message": {"id": str(index), "stop_reason": "refusal", "content": [
                {"type": "tool_use", "id": str(index), "name": "Read", "input": {"file_path": "PRIVATE"}}]}})
        self.assertEqual(len(trace.messages), 128)
        self.assertEqual(len(trace.refusals), 20)
        self.assertEqual(len(trace.actions), 12)

    def test_unknown_result_status_does_not_become_success(self):
        trace = ClaudeTrace()
        trace.feed({"type": "result"})
        self.assertIsNone(trace.report()["result"]["is_error"])

    def test_input_usage_counts_messages_once_and_keeps_refusal_size(self):
        trace = ClaudeTrace()
        start = {"type": "stream_event", "session_id": "session", "event": {
            "type": "message_start", "message": {"id": "one", "model": "claude-opus-5-5",
                "usage": {"input_tokens": 2, "cache_creation_input_tokens": 10,
                          "cache_read_input_tokens": 100}}}}
        trace.feed(start)
        trace.feed({"type": "assistant", "session_id": "session", "message": start["event"]["message"]})
        trace.feed({"type": "stream_event", "session_id": "session", "event": {
            "type": "message_start", "message": {"id": "two", "model": "claude-opus-5-5"}}})
        trace.feed({"type": "assistant", "session_id": "session", "request_id": "request-two", "message": {
            "id": "two", "model": "claude-opus-5-5", "usage": {
                "input_tokens": 2, "cache_creation_input_tokens": 300,
                "cache_read_input_tokens": 293627, "private_extra": "PRIVATE"}}})
        refusal = trace.feed(self.events[-2])
        self.assertEqual(refusal["input_tokens"], 293929)
        self.assertEqual(trace.report()["input_usage"], {
            "messages_observed": 2, "first_input_tokens": 112,
            "last_input_tokens": 293929, "peak_input_tokens": 293929})
        self.assertNotIn("PRIVATE", json.dumps(trace.report()))

    def test_missing_or_invalid_usage_stays_unknown_and_does_not_leak_between_messages(self):
        for invalid in (None, {}, {"input_tokens": 1},
                        {"input_tokens": True, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0},
                        {"input_tokens": -1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}):
            with self.subTest(invalid=invalid):
                trace = ClaudeTrace()
                trace.feed({"type": "assistant", "message": {"id": "one", "usage": invalid}})
                self.assertIsNone(trace.report()["input_usage"]["last_input_tokens"])
        trace = ClaudeTrace()
        trace.feed({"type": "assistant", "message": {"id": "one", "usage": {
            "input_tokens": 2, "cache_creation_input_tokens": 3, "cache_read_input_tokens": 4}}})
        trace.feed({"type": "stream_event", "session_id": "session", "event": {
            "type": "message_start", "message": {"id": "two", "model": "claude-opus-5-5"}}})
        refusal = trace.feed(self.events[-2])
        self.assertIsNone(refusal["input_tokens"])
        self.assertEqual(trace.report()["input_usage"]["last_input_tokens"], 9)

    def test_refusal_captures_stream_location_without_content(self):
        trace = ClaudeTrace()
        trace.feed(self.events[1])
        trace.feed({"type": "stream_event", "event": {"type": "content_block_start", "index": 0,
                    "content_block": {"type": "thinking", "thinking": "PRIVATE"}}})
        trace.feed(self.events[2])
        event = json.loads(json.dumps(self.events[-2]))
        event["event"]["usage"] = {"input_tokens": 2, "cache_creation_input_tokens": 3,
                                   "cache_read_input_tokens": 400, "output_tokens": 500}
        refusal = trace.feed(event)
        self.assertEqual(refusal["input_tokens"], 405)
        self.assertEqual(refusal["output_tokens"], 500)
        self.assertEqual(refusal["last_block_type"], "thinking")
        self.assertEqual(refusal["last_delta_type"], "thinking_delta")
        self.assertEqual(refusal["open_block_types"], ["thinking"])
        trace.feed({"type": "stream_event", "event": {"type": "content_block_stop", "index": 0}})
        self.assertEqual(trace.feed(event)["open_block_types"], [])
        self.assertNotIn("PRIVATE", json.dumps(trace.report()))
        self.assertEqual(trace.report()["messages"][0]["stop_reason"], "refusal")

    def native_log(self):
        path = self.root / "native.jsonl"
        def attachment(value, **overrides):
            return dict({"type": "attachment", "sessionId": "session", "cwd": str(self.root),
                         "isSidechain": False, "attachment": value, "rendered": "PRIVATE RENDERED"}, **overrides)
        events = [
            attachment({"type": "prompt_snapshot", "systemPrompt": ["Do not reveal private reasoning.\nSECRET"],
                        "tools": [{"name": "Read", "schema": {"description": "SECRET", "private_extra": "PRIVATE"}}]}),
            attachment({"type": "instructions", "files": [
                {"path": "AGENTS.md", "type": "Project", "content": "Keep thinking private.\nSECRET"}]}),
            attachment({"type": "skill_listing", "content": "SECRET"}),
            attachment({"type": "mcp_instructions_delta", "addedBlocks": ["SECRET"]}),
            attachment({"type": "prompt_snapshot", "systemPrompt": ["PRIVATE OTHER"]}, sessionId="other"),
            attachment({"type": "prompt_snapshot", "systemPrompt": ["PRIVATE CHILD"]}, isSidechain=True),
            {"type": "assistant", "sessionId": "session", "cwd": str(self.root),
             "message": {"content": [{"type": "thinking", "thinking": "PRIVATE ASSISTANT"}]}},
        ]
        path.write_text(''.join(json.dumps(e) + '\n' for e in events))
        return path

    def test_native_inventory_is_bound_to_session_and_project_and_excludes_contents(self):
        path = self.native_log()
        before = path.read_bytes()
        report = diagnose(self.directory, self.identity, native_log=path)
        native = report["native_context"]
        self.assertEqual(len(native["prompt_snapshots"]), 1)
        self.assertEqual(native["prompt_snapshots"][0]["system_blocks"][0]["term_lines"]["reasoning"], [1])
        self.assertEqual(native["prompt_snapshots"][0]["tools"][0]["name"], "Read")
        self.assertEqual(native["instruction_files"][0]["path"], "AGENTS.md")
        self.assertEqual(len(native["additional_instructions"]), 2)
        for body in ("SECRET", "PRIVATE", "Do not reveal", "Keep thinking"):
            self.assertNotIn(body, json.dumps(report))
        self.assertEqual(before, path.read_bytes())
        for session, root in (("other-session", self.root), ("session", self.root / "different")):
            with self.assertRaises(Blocked) as caught:
                native_context(path, session, root)
            self.assertEqual(caught.exception.code, "diagnostic-native-session")

    def test_cli_native_inventory_does_not_start_provider_or_write_state(self):
        path = self.native_log()
        before = {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()}
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Transport", side_effect=AssertionError), \
                patch("cc_focus.LocalLock", side_effect=AssertionError), contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(main(["diagnose", "--invocation", self.identity, "--native-log", str(path)]), 0)
        self.assertIn("native_context", json.loads(output.getvalue()))
        self.assertEqual(before, {p.relative_to(self.root): p.read_bytes() for p in self.root.rglob('*') if p.is_file()})

    def test_saved_launch_metadata_has_a_strict_projection(self):
        (self.target / "claude-diagnostics.json").write_text(json.dumps({"launch": {
            "role": "code", "requested_model": "opus", "effort": "xhigh", "resumed": False,
            "standard_system_prompt": True, "role_contract_sha256": "a" * 64,
            "prompt_sha256": "SECRET", "settings": "SECRET", "argv": "PRIVATE"}}))
        result = diagnose(self.directory, self.identity)
        self.assertEqual(result["launch"]["effort"], "xhigh")
        self.assertEqual(result["launch"]["role_contract_sha256"], "a" * 64)
        self.assertNotIn("SECRET", json.dumps(result))
        self.assertNotIn("PRIVATE", json.dumps(result))
        (self.target / "claude-diagnostics.json").write_text('{invalid')
        self.assertNotIn("launch", diagnose(self.directory, self.identity))

    def test_bad_payload_encoding_cannot_interrupt_refusal_processing(self):
        self.assertEqual(payload_metadata('\ud800'), {"bytes": None, "sha256": None})
        trace = ClaudeTrace()
        for event in self.events[:4]:
            trace.feed(event)
        trace.feed({"type": "user", "message": {"content": [{
            "type": "tool_result", "tool_use_id": "write", "content": '\ud800'}]}})
        refusal = trace.feed(self.events[-2])
        self.assertEqual(refusal["category"], "reasoning_extraction")
        self.assertIsNone(refusal["last_action"]["result"]["sha256"])

    @unittest.skipIf(os.name == "nt", "symlink creation requires Windows privileges")
    def test_native_log_symlink_is_rejected(self):
        original = self.native_log()
        alias = self.root / 'alias.jsonl'
        alias.symlink_to(original)
        with self.assertRaises(Blocked) as caught:
            native_context(alias, 'session', self.root)
        self.assertEqual(caught.exception.code, 'diagnostic-native-log')


if __name__ == "__main__":
    unittest.main()
