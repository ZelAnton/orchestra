"""Interactive input fixtures; all processes are local protocol simulators."""

import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import unittest
from unittest.mock import patch

import test_cycle as fixtures
from cycle_state import Blocked, LocalLock, encode
from cycle_transport import Process, Rpc, Transport
from focus_control import Control, FocusStop, check_parked_provider, owner_alive, request_stop, runtime_active
from focus_input import Interaction
from focus_messages import MessagePending, Messages, message_text
from focus_terminal import Terminal, clip

REPO, report = fixtures.REPO, fixtures.report


class Display(io.StringIO):
    interactive = True

    def status(self, value):
        self.label = value


class FocusInputTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown

    def setup_input(self, role="sol"):
        self.state.update(phase=role, coordinated=role)
        self.pending = {"id": "a" * 32, "iteration": 1, "role": role,
                        "before": self.repo.snapshot(), "started": time.time()}
        self.state["pending"] = self.pending
        self.control = Control(self.store)
        self.control.begin()
        self.display = Display()
        self.input = Interaction(self.display)
        self.input.bind(self.control, self.state, self.store.save)
        self.input.begin(self.pending)
        return self.input

    def run_transport(self, provider, mode=()):
        role = "sol" if provider == "codex" else "code"
        interaction = self.setup_input(role)
        interaction.submit("Check interrupted recovery as well.")
        transport = Transport(self.root, self.state, self.store.save, lambda: None, interaction=interaction)
        transport.commands[provider] = [sys.executable, str(REPO / "tests/test_cycle.py"), "fixture", provider, *mode]
        directory = self.store.directory / "invocations" / self.pending["id"]
        directory.mkdir(parents=True)
        return transport, directory

    def test_message_is_durable_bound_and_checksummed(self):
        interaction = self.setup_input()
        interaction.submit("Проверь перезапуск")
        record = Messages(self.store).records(1)[0]
        self.assertEqual(record["status"], "queued")
        self.assertEqual(record["identity"]["invocation"], self.pending["id"])
        self.assertEqual(record["identity"]["text"], "Проверь перезапуск")
        path = interaction.messages.directory(1) / (record["identity"]["id"] + ".json")
        record["identity"]["text"] = "Changed"
        path.write_bytes(encode(record))
        with self.assertRaisesRegex(Blocked, "invalid or changed"):
            Messages(self.store).records(1)

    def test_terminal_race_preserves_input_and_blocks_advancement(self):
        interaction = self.setup_input()
        interaction.submit("Late instruction")
        with self.assertRaises(MessagePending):
            interaction.finish()
        interaction.submit("Do not send to another invocation")
        self.assertEqual(len(interaction.messages.records(1)), 1)
        self.assertEqual(interaction.messages.unresolved(1)[0]["identity"]["role"], "sol")

    def test_uncertain_delivery_needs_explicit_decision_and_exact_target(self):
        interaction = self.setup_input()
        interaction.submit("Preserve this instruction")
        message = interaction.take()
        self.assertEqual(message["status"], "sending")
        with self.assertRaises(MessagePending):
            interaction.begin(self.pending)
        with self.assertRaises(ValueError):
            interaction.messages.resolve(1, message["identity"]["id"], True, "wrong")
        interaction.messages.resolve(1, message["identity"]["id"][:12], True, self.pending["id"])
        interaction.begin(self.pending)
        self.assertEqual(interaction.messages.unresolved(1)[0]["status"], "queued")

    def test_discard_does_not_delete_artifacts(self):
        interaction = self.setup_input()
        interaction.submit("Discard this delivery")
        message = interaction.take()
        interaction.messages.resolve(1, message["identity"]["id"], False)
        self.assertFalse(interaction.messages.unresolved(1))
        self.assertEqual(interaction.messages.records(1)[0]["status"], "discarded")
        interaction.finish()

    def test_old_messages_cannot_be_retargeted_on_another_invocation(self):
        interaction = self.setup_input()
        interaction.submit("Keep at this role")
        with self.assertRaises(MessagePending):
            interaction.begin(dict(self.pending, id="b" * 32, role="claude"))

    def test_later_review_instruction_invalidates_credit_and_returns_to_sol(self):
        for role in ('claude', 'astra'):
            with self.subTest(role=role):
                interaction = self.setup_input(role)
                self.state.update(sol_clean=3, claude_clean=1, astra_clean=0, reviewed={"head": "old"})
                interaction.submit("Also check restart")
                interaction.take()
                self.assertEqual([self.state[k + '_clean'] for k in ('sol', 'claude', 'astra')], [0, 0, 0])
                self.assertIsNone(self.state["reviewed"])
                self.assertTrue(self.pending["return_to_sol"])
                for record in interaction.messages.unresolved(1):
                    interaction.messages.update(record, 'discarded')

    def test_publication_and_publication_healing_reject_instructions(self):
        interaction = self.setup_input("publish")
        interaction.submit("Change scope")
        self.assertFalse(interaction.messages.records(1))
        self.state["publication_started"] = True
        interaction.begin(dict(self.pending, role="heal"))
        interaction.submit("Change files")
        self.assertFalse(interaction.messages.records(1))

    def test_accepted_messages_are_in_future_review_context(self):
        interaction = self.setup_input("code")
        interaction.submit("Respect this requirement")
        message = interaction.take()
        interaction.ack(message, True)
        self.assertIn(message["identity"]["id"], self.cycle.context("sol"))
        self.assertIn("focus-message:", message_text(message))

    def test_codex_steers_active_turn_and_correlates_acknowledgement(self):
        transport, directory = self.run_transport("codex", ("steer",))
        result = transport.run("sol", "Review", self.pending, directory)
        self.assertIn("Steered the active turn", result)
        self.assertEqual(self.input.messages.records(1)[0]["status"], "accepted")
        self.assertIsNone(self.input.target)

    def test_codex_waits_for_ack_after_terminal_event(self):
        transport, directory = self.run_transport("codex", ("steer", "late-ack"))
        result = transport.run("sol", "Review", self.pending, directory)
        self.assertIn("Steered", result)
        self.assertEqual(self.input.messages.records(1)[0]["status"], "accepted")

    def test_rejected_steer_cannot_advance_the_phase(self):
        transport, directory = self.run_transport("codex", ("steer", "error-ack"))
        with self.assertRaises(MessagePending):
            transport.run("sol", "Review", self.pending, directory)
        self.assertEqual(self.input.messages.records(1)[0]["status"], "rejected")

    def test_claude_waits_for_the_instruction_response_in_the_same_process(self):
        transport, directory = self.run_transport("claude")
        result = transport.run("code", "Implement", self.pending, directory)
        self.assertIn("handled in the same process", result)
        self.assertEqual(self.input.messages.records(1)[0]["status"], "accepted")
        log = (directory / "protocol.jsonl").read_text()
        events = [json.loads(json.loads(line)["line"]) for line in log.splitlines()]
        self.assertEqual(sum(event.get("type") == "result" for event in events), 2)

    def test_claude_result_without_acknowledgement_stops(self):
        transport, directory = self.run_transport("claude", ("no-ack",))
        with self.assertRaises(MessagePending):
            transport.run("code", "Implement", self.pending, directory)
        self.assertEqual(self.input.messages.records(1)[0]["status"], "sending")

    def test_claude_native_continuation_finishes_before_operator_delivery(self):
        transport, directory = self.run_transport("claude", ("native-fixes",))
        result = json.loads(transport.run("code", "Implement", self.pending, directory))
        self.assertEqual(result["implementation_fixes"], 2)
        self.assertTrue(result["substantial"])
        self.assertIn("handled in the same process", result["description"])
        self.assertEqual(self.input.messages.records(1)[0]["status"], "accepted")
        self.assertEqual(len(list(directory.glob("deferred-*.txt"))), 2)
        responses = list(directory.glob("response-*.json"))
        self.assertEqual(len(responses), 1)
        self.assertEqual(json.loads(responses[0].read_text())["implementation_fixes"], 2)

    def test_claude_final_response_cannot_erase_prior_fixes(self):
        transport, directory = self.run_transport("claude", ("prior-fix",))
        result = json.loads(transport.run("code", "Implement", self.pending, directory))
        self.assertEqual(result["implementation_fixes"], 1)
        self.assertTrue(result["substantial"])
        self.assertIn("Full coding result", result["description"])
        self.assertIn("handled in the same process", result["description"])

    def test_long_claude_summaries_preserve_delivery_and_aggregated_fixes(self):
        transport, directory = self.run_transport("claude", ("prior-fix", "long-summary"))
        result = json.loads(transport.run("code", "Implement", self.pending, directory))
        self.assertEqual(result["implementation_fixes"], 1)
        self.assertTrue(result["substantial"])
        self.assertEqual(result["summary"], "Final summary " * 100 + "final summary ending")
        self.assertIn("handled in the same process", result["description"])
        self.assertEqual(self.input.messages.records(1)[0]["status"], "accepted")
        responses = list(directory.glob("response-*.json"))
        self.assertEqual(len(responses), 1)
        self.assertEqual(json.loads(responses[0].read_text())["summary"],
                         "First summary " * 100 + "first summary ending")

    def test_partial_pipe_writes_do_not_truncate_a_protocol_record(self):
        received = bytearray()
        class Pipe:
            def write(self, data):
                received.extend(data[:3])
                return min(len(data), 3)
            def flush(self):
                pass
        process = Process.__new__(Process)
        from types import SimpleNamespace
        process.proc = SimpleNamespace(stdin=Pipe())
        process.send(b"a complete protocol record\n")
        self.assertEqual(received, b"a complete protocol record\n")

    def test_failed_process_creation_clears_only_its_unstarted_provider_intent(self):
        self.setup_input()
        self.control.active.update(processkit_cli=str(self.root / "processkit-fixture"),
                                   processkit_run_id="orchestra-focus-" + "c" * 32)
        with patch("cycle_transport.subprocess.Popen", side_effect=OSError("Fixture process creation failure")):
            with self.assertRaises(OSError):
                Process(["fixture"], self.root, self.store.directory / "fixture.jsonl", lambda: None, control=self.control)
        self.assertIsNone(self.control.active["provider_run"])

    def test_status_corruption_does_not_fabricate_delivery(self):
        interaction = self.setup_input()
        interaction.submit("Not accepted yet")
        record = interaction.messages.records(1)[0]
        record["status"] = "accepted"
        path = interaction.messages.directory(1) / (record["identity"]["id"] + ".json")
        path.write_bytes(encode(record))
        with self.assertRaises(Blocked):
            interaction.messages.accepted(1)

    def test_large_provider_error_cannot_make_a_message_unreadable_or_undiscardable(self):
        interaction = self.setup_input()
        interaction.submit("Please verify this")
        record = interaction.take()
        interaction.ack(record, False, "x" * (2 * 1024 * 1024))
        stored = interaction.messages.records(1)[0]
        self.assertEqual(len(stored["detail"]), 4000)
        interaction.messages.resolve(1, stored["identity"]["id"], False)
        self.assertFalse(interaction.messages.unresolved(1))

    def test_clock_rollback_does_not_reorder_operator_instructions(self):
        interaction = self.setup_input()
        with patch("focus_messages.time.time", side_effect=[200.0, 100.0]):
            interaction.submit("First instruction")
            interaction.submit("Second instruction")
        self.assertEqual([item["identity"]["text"] for item in interaction.messages.records(1)],
                         ["First instruction", "Second instruction"])

    def test_external_stop_acknowledges_a_parked_ui_without_waiting_for_ui_exit(self):
        self.setup_input()
        self.control.active["interactive"] = True
        self.state["status"] = "paused"
        self.control.finish(self.state, 0)
        with patch("focus_control.runtime_active", side_effect=[True, False]), \
                patch("focus_control.wait_container", side_effect=AssertionError("Parked UI is not a running provider")):
            self.assertEqual(request_stop(self.store, timeout=1), 0)

    def test_uncleared_provider_is_not_a_parked_ui(self):
        self.setup_input()
        self.control.active.update(interactive=True, provider_run={"processkit_run_id": "unknown"})
        self.control.finish(self.state, 3)
        self.assertFalse(self.control.active["ui_parked"])

    def test_correction_cannot_orphan_queued_messages(self):
        interaction = self.setup_input("code")
        self.state["code_started"] = True
        interaction.submit("Pending instruction")
        with self.assertRaisesRegex(Blocked, "Resolve queued"):
            self.cycle.correct("New scope")
        self.assertIs(self.state["pending"], self.pending)

    def test_duplicate_resume_is_not_queued_for_a_later_pause(self):
        interaction = self.setup_input()
        interaction.unbind()
        interaction.submit("/resume")
        interaction.submit("/resume")
        self.assertEqual(interaction.commands.qsize(), 1)

    def test_exit_during_ui_startup_prevents_provider_launch(self):
        import cc_focus
        interaction = Interaction(Display())
        interaction.submit("/exit")
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No model after input exit")):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main([], interaction), 130)
        self.assertTrue(interaction.paused)
        self.assertIsNone(interaction.control)

    def test_ui_resume_preserves_a_scheduled_healer_and_retries_only_escalated_blocks(self):
        import cc_focus
        class Screen(Display):
            def __enter__(self):
                return self
            def __exit__(self, *_):
                pass
        for status in ("healing", "blocked"):
            with self.subTest(status=status), patch("cc_focus.Interaction") as interaction, \
                    patch("cc_focus.Store") as store, patch("cc_focus.main", return_value=0) as run:
                interaction.return_value.wait_action.side_effect = [("/resume", ""), ("/exit", "")]
                store.return_value.read.return_value = {"blocker": {"status": status}}
                cc_focus.interactive_main([], Screen(), None)
                self.assertEqual("--retry" in run.call_args_list[1].args[0], status == "blocked")

    def test_failed_setup_unbinds_the_controller_for_an_operator_retry(self):
        import cc_focus
        interaction = Interaction(Display())
        original = self.store.__class__.artifact
        def fail(store, name, data):
            if name == "active.json" and json.loads(data).get("interactive"):
                raise OSError("Fixture disk failure after binding")
            return original(store, name, data)
        with patch("cc_focus.Path.cwd", return_value=self.root), patch("cycle_state.Store.artifact", fail), \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No model")), contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cc_focus.main([], interaction), 3)
        self.assertTrue(interaction.paused)
        self.assertIsNone(interaction.control)

    @unittest.skipIf(os.name == "nt", "POSIX PTY startup diagnostics")
    def test_invalid_checkout_exits_before_opening_the_ui(self):
        import pty
        empty = Path(self.temp.name) / "multi repo parent"
        empty.mkdir()
        nested = self.root / "subdirectory"
        nested.mkdir()
        handoff = empty / "HANDOFF.md"
        handoff.write_text("Use the existing project plan.", encoding="utf-8")
        cases = [(empty, "Cannot open a Git repository"), (nested, "repository root")]
        self.repo.git("checkout", "--detach")
        cases.append((self.root, "HEAD is detached"))
        for root, expected in cases:
            for ui in ("auto", "on", "off"):
                with self.subTest(root=root.name, ui=ui):
                    master, slave = pty.openpty()
                    process = subprocess.Popen(
                        [sys.executable, "-B", str(REPO / "tools/cc_focus.py"),
                         "--ui", ui, "--handoff", str(handoff)], cwd=root,
                        stdin=slave, stdout=slave, stderr=slave,
                        env=dict(os.environ, TERM="xterm"))
                    os.close(slave)
                    output = bytearray()
                    try:
                        process.wait(timeout=5)
                        while True:
                            try:
                                chunk = os.read(master, 65536)
                            except OSError:
                                break
                            if not chunk:
                                break
                            output.extend(chunk)
                        self.assertEqual(process.returncode, 3)
                        self.assertIn(expected, output.decode())
                        self.assertNotIn(b"\x1b[?1049h", output)
                        self.assertFalse((root / ".work/cycle").exists())
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait(timeout=5)
                        os.close(master)

    @unittest.skipIf(os.name == "nt", "POSIX PTY full lifecycle fixture")
    def test_interactive_pause_releases_ownership_and_resume_stays_in_the_same_ui(self):
        import pty
        import select
        master, slave = pty.openpty()
        process = subprocess.Popen([sys.executable, "-B", str(Path(__file__).resolve()), "fixture-ui"],
                                   cwd=self.root, stdin=slave, stdout=slave, stderr=slave,
                                   env=dict(os.environ, TERM="xterm"))
        os.close(slave)
        output = bytearray()
        def wait_text(needle, timeout=12):
            deadline = time.monotonic() + timeout
            while needle.encode() not in output:
                if time.monotonic() >= deadline:
                    self.fail(f"Timed out waiting for {needle}: {bytes(output[-5000:])!r}")
                if select.select([master], [], [], 0.1)[0]:
                    try:
                        output.extend(os.read(master, 65536))
                    except OSError:
                        self.fail(f"UI exited early: {bytes(output[-5000:])!r}")
        try:
            wait_text("role=code")
            os.write(master, b"/pause\r")
            wait_text("runtime ownership released")
            self.assertFalse(runtime_active(self.store))
            with LocalLock(self.store.directory):
                pass
            self.assertEqual(self.store.read()["phase"], "sol")
            old_nonce = self.control_nonce()
            output.clear()
            os.write(master, b"/resume\r")
            deadline = time.monotonic() + 10
            while self.control_nonce() == old_nonce:
                if time.monotonic() >= deadline:
                    self.fail("UI did not start a new processing epoch")
                time.sleep(0.02)
            os.write(master, b"/pause\r")
            deadline = time.monotonic() + 10
            while runtime_active(self.store):
                if time.monotonic() >= deadline:
                    self.fail("The second pause did not release ownership")
                if select.select([master], [], [], 0.05)[0]:
                    output.extend(os.read(master, 65536))
            self.assertNotEqual(self.control_nonce(), old_nonce)
            self.assertFalse(runtime_active(self.store))
            os.write(master, b"/exit\r")
            process.wait(timeout=5)
            self.assertEqual(process.returncode, 0)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            os.close(master)

    def control_nonce(self):
        return json.loads((self.store.directory / "active.json").read_text())["nonce"]

    def test_cached_result_cannot_skip_new_queued_input(self):
        interaction = self.setup_input()
        directory = self.store.directory / "invocations" / self.pending["id"]
        self.store.artifact(f"invocations/{self.pending['id']}/result.json", encode({"raw": json.dumps(report()),
                            "before": self.pending["before"], "after": self.repo.snapshot()}))
        interaction.submit("New instruction")
        self.transport.actions = [("sol", report())]
        with self.assertRaises(MessagePending):
            self.cycle.invoke("sol")
        self.assertEqual(len(self.transport.calls), 1)
        self.assertEqual(self.state["phase"], "sol")

    def test_uncertain_messages_stop_without_healer(self):
        interaction = self.setup_input()
        interaction.submit("Maybe sent")
        interaction.take()
        with self.assertRaises(MessagePending):
            self.cycle.run()
        self.assertFalse(self.transport.calls)
        self.assertIsNone(self.state["blocker"])

    def test_transport_failure_preserves_the_message_target_without_healing(self):
        interaction = self.setup_input()
        interaction.submit("Preserve the original target")
        self.transport.actions = [("sol", Blocked("provider-eof", "Disconnected"))]
        with self.assertRaises(MessagePending):
            self.cycle.run()
        self.assertEqual(self.state["pending"]["id"], self.pending["id"])
        self.assertIsNone(self.state["blocker"])
        self.assertEqual(len(self.transport.calls), 1)

    def test_uncertain_input_does_not_hide_unconfirmed_process_cleanup(self):
        interaction = self.setup_input()
        interaction.submit("Preserve this input")
        self.transport.actions = [("sol", Blocked("cleanup-incomplete", "Provider may still be running"))]
        with self.assertRaisesRegex(Blocked, "Provider may still"):
            self.cycle.run()
        self.assertEqual(self.state["pending"]["id"], self.pending["id"])

    def test_emergency_cleans_a_failed_ui_epoch_even_after_its_lock_was_released(self):
        self.setup_input()
        self.control.active.update(interactive=True, processkit_cli=str(self.root / "processkit-fixture"),
                                   processkit_run_id="orchestra-focus-" + "c" * 32,
                                   provider_run={"processkit_cli": str(self.root / "processkit-fixture"),
                                                 "processkit_run_id": "orchestra-focus-provider-" + "d" * 32})
        self.control.finish(self.state, 3)
        clock = [0]
        def sleep(_):
            clock[0] += 6
        with patch("focus_control.runtime_active", return_value=False), \
                patch("focus_control.time.monotonic", side_effect=lambda: clock[0]), \
                patch("focus_control.time.sleep", side_effect=sleep), \
                patch("focus_control.command") as command, patch("focus_control.wait_container"), \
                patch("focus_control.kill_provider", return_value=True):
            self.assertEqual(request_stop(self.store, now=True, timeout=60), 0)
            self.assertEqual(command.call_args.args[0][1:3], ["kill", "--run-id"])

    def test_live_ui_cannot_resume_before_prior_provider_exit_is_confirmed(self):
        import cc_focus
        self.setup_input()
        self.control.active.update(interactive=True, provider_run={"processkit_cli": str(self.root / "processkit-fixture"),
                                  "processkit_run_id": "orchestra-focus-provider-" + "e" * 32})
        self.control.finish(self.state, 3)
        nonce = self.control_nonce()
        with patch("cc_focus.Path.cwd", return_value=self.root), \
                patch("focus_control.wait_container", side_effect=Blocked("still-running", "No exit yet")), \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No new model")), \
                contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(cc_focus.main(["--ui", "off"]), 3)
        self.assertEqual(self.control_nonce(), nonce)
        with patch("focus_control.wait_container") as wait:
            check_parked_provider(self.store)
            self.assertEqual(wait.call_args.kwargs, {"timeout": 1})
        with patch("focus_control.owner_alive", return_value=False), \
                patch("focus_control.wait_container", side_effect=AssertionError("Closed UI is not a parked owner")):
            check_parked_provider(self.store)

    def test_safe_stop_cannot_claim_success_for_unconfirmed_ui_cleanup(self):
        self.setup_input()
        self.control.active.update(interactive=True, provider_run={"processkit_run_id": "unknown"})
        self.control.finish(self.state, 3)
        with self.assertRaisesRegex(Blocked, "unconfirmed cleanup"):
            request_stop(self.store, timeout=1)

    def test_reused_ui_pid_does_not_block_crash_recovery(self):
        with patch("focus_control.owner_stamp", return_value="new-boot:new-process"):
            self.assertFalse(owner_alive({"pid": os.getpid(), "owner_stamp": "old-boot:old-process"}))

    def test_stop_is_addressed_and_emergency_cannot_be_downgraded(self):
        interaction = self.setup_input()
        interaction.submit("/pause")
        self.assertEqual(self.control.request()["mode"], "safe")
        interaction.submit("/stop")
        interaction.submit("/pause")
        self.assertEqual(self.control.request()["mode"], "now")
        self.assertEqual(self.control.request()["nonce"], self.control.active["nonce"])

    def test_approval_has_one_input_owner_and_text_is_not_consent(self):
        interaction = self.setup_input()
        calls = []
        def heartbeat():
            calls.append(1)
            if len(calls) == 1:
                interaction.submit("y")
                self.assertIsNone(interaction.approval_answer)
                interaction.submit("/approve")
        with patch("builtins.input", side_effect=AssertionError("No second input reader")):
            self.assertTrue(interaction.approve({"command": "example"}, heartbeat))
        self.assertFalse(interaction.messages.records(1))
        interaction.submit("/approve")
        self.assertIn("no displayed approval", self.display.getvalue())

    def test_safe_stop_cancels_unanswered_approval(self):
        interaction = self.setup_input()
        interaction.submit("/pause")
        self.assertFalse(interaction.approve({"command": "example"}, lambda: None))

    def test_resume_and_correction_are_stopped_only(self):
        interaction = self.setup_input()
        interaction.submit("/resume")
        interaction.submit("/correct new scope")
        self.assertTrue(interaction.commands.empty())
        interaction.unbind()
        interaction.submit("/correct new scope")
        self.assertEqual(interaction.wait_action(), ("/correct", "new scope"))

    def test_rpc_async_ack_does_not_consume_synchronous_response(self):
        replies = [{"id": 1, "result": {"turnId": "t"}}, {"method": "item/started", "params": {}},
                   {"id": 2, "result": {"data": "expected"}}]
        class Fake:
            def send(self, data):
                pass
            def receive(self):
                return replies.pop(0)
        rpc = Rpc(Fake())
        accepted = []
        rpc.send_request("turn/steer", {}, accepted.append)
        self.assertEqual(rpc.request("other", {}), {"data": "expected"})
        self.assertEqual(len(accepted), 1)
        self.assertEqual(rpc.event()["method"], "focus/inputResponse")
        self.assertEqual(rpc.event()["method"], "item/started")

    def test_message_commands_are_model_free_and_obey_runtime_lock(self):
        import cc_focus
        interaction = self.setup_input()
        interaction.submit("Explicit retry")
        message = interaction.take()
        self.store.save(self.state)
        with patch("pathlib.Path.cwd", return_value=self.root), patch("cc_focus.Lease") as lease, \
                patch("cycle_transport.Transport.run", side_effect=AssertionError("No model")):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            self.assertEqual(cc_focus.main(["messages"]), 0)
            with LocalLock(self.store.directory):
                self.assertEqual(cc_focus.main(["retry-message", "--id", message["identity"]["id"]]), 3)
            self.assertEqual(cc_focus.main(["retry-message", "--id", message["identity"]["id"]]), 0)
            self.assertEqual(cc_focus.main(["discard-message", "--id", message["identity"]["id"]]), 0)

    @unittest.skipIf(os.name == "nt", "POSIX symlink fixture")
    def test_messages_cannot_escape_the_state_directory(self):
        interaction = self.setup_input()
        outside = self.root / "external"
        outside.mkdir()
        (self.store.directory / "messages").symlink_to(outside, target_is_directory=True)
        interaction.submit("No external write")
        self.assertFalse(list(outside.iterdir()))
        self.assertIn("outside focus state", self.display.getvalue())


class TerminalTests(unittest.TestCase):
    def test_typing_in_long_scrollback_reuses_output_and_only_repaints_input(self):
        terminal = Terminal(io.StringIO(), io.StringIO())
        terminal.write("\n".join(f"{index}: " + "длинная строка " * 8 for index in range(3000)))
        terminal.scroll = 1000000
        terminal.render(100, 30)
        visible = list(terminal.frame_rows[:-1])
        with patch.object(terminal, "wrap_line", side_effect=AssertionError("Typing must not scan output history")):
            for char in "проверка ввода":
                terminal.key(char)
                frame = terminal.render(100, 30)
                self.assertIn("\x1b[30;1H", frame)
                self.assertNotIn("\x1b[2J", frame)
                self.assertLess(len(frame.encode("utf-8")), 256)
                self.assertEqual(terminal.frame_rows[:-1], visible)
        self.assertEqual(terminal.text, "проверка ввода")
        self.assertEqual(terminal.render(100, 30), "")

    def test_unchanged_status_does_not_request_redraw(self):
        terminal = Terminal(io.StringIO(), io.StringIO())
        terminal.status("active")
        terminal.render(60, 12)
        for _ in range(100):
            terminal.status("active")
            self.assertFalse(terminal.changed)
        terminal.status("paused")
        self.assertTrue(terminal.changed)
        frame = terminal.render(60, 12)
        self.assertIn("\x1b[1;1Hpaused\x1b[K", frame)
        self.assertNotIn("\x1b[12;1H", frame)

    def test_output_and_resize_refresh_cached_scrollback_with_unicode(self):
        terminal = Terminal(io.StringIO(), io.StringIO())
        terminal.write("123456789\ne\u0301界abcd")
        terminal.render(8, 7)
        self.assertEqual(terminal.frame_rows[1:5], ["", "1234567", "89", "e\u0301界abcd"])
        terminal.write("Z")
        frame = terminal.render(8, 7)
        self.assertEqual(terminal.frame_rows[1:5], ["1234567", "89", "e\u0301界abcd", "Z"])
        self.assertIn("\x1b[5;1HZ\x1b[K", frame)
        frame = terminal.render(12, 8)
        self.assertIn("\x1b[2J", frame)
        self.assertEqual(terminal.frame_rows[1:6], ["", "", "", "123456789", "e\u0301界abcdZ"])
        self.assertEqual(terminal.wrap_line("e\u0301界abcdZ", 11), ("e\u0301界abcdZ",))
        terminal.render(7, 3)
        self.assertIn("\x1b[2J", terminal.render(12, 8))

    def test_shorter_composer_clears_stale_text_and_cursor_only_motion(self):
        terminal = Terminal(io.StringIO(), io.StringIO())
        for char in "abcdef":
            terminal.key(char)
        terminal.render(60, 12)
        terminal.key("\x01")
        self.assertEqual(terminal.render(60, 12), "\x1b[?25l\x1b[12;3H\x1b[?25h")
        terminal.key("\x15")
        self.assertIn("\x1b[12;1H> \x1b[K", terminal.render(60, 12))
        terminal.text = "a" + "\u0301" * 20 + "b"
        terminal.cursor = 0
        terminal.render(8, 7)
        self.assertEqual(terminal.frame_rows[-1], "> " + terminal.text)

    def test_wrapping_cache_stays_bounded_as_history_and_tail_change(self):
        terminal = Terminal(io.StringIO(), io.StringIO())
        for index in range(3500):
            terminal.write(f"line {index}\n")
            terminal.render(50, 6)
        self.assertEqual(len(terminal.lines), 3000)
        self.assertLessEqual(len(terminal.wrapped_lines), 3001)
        terminal.scroll = 1000000
        terminal.render(50, 6)
        self.assertEqual(terminal.frame_rows[1:4], ["line 500", "line 501", "line 502"])
        for _ in range(20):
            terminal.write("x")
            terminal.render(50, 6)
        self.assertLessEqual(len(terminal.wrapped_lines), 3001)
        terminal.scroll = 0
        terminal.render(50, 6)
        self.assertEqual(terminal.frame_rows[3], "x" * 20)

    def test_provider_text_sanitization_does_not_hold_the_input_lock(self):
        terminal = Terminal(io.StringIO(), io.StringIO())
        sanitizing, release, typed = threading.Event(), threading.Event(), threading.Event()
        def sanitize(text):
            sanitizing.set()
            release.wait(5)
            return text
        def type_char():
            terminal.key("я")
            typed.set()
        writer = threading.Thread(target=terminal.write, args=("provider output",))
        typer = threading.Thread(target=type_char)
        with patch("focus_terminal.terminal_text", side_effect=sanitize):
            writer.start()
            try:
                self.assertTrue(sanitizing.wait(2))
                typer.start()
                self.assertTrue(typed.wait(2), "Keyboard input is blocked behind output sanitization")
            finally:
                release.set()
                writer.join(timeout=3)
                if typer.ident:
                    typer.join(timeout=3)
        self.assertFalse(writer.is_alive())
        self.assertFalse(typer.is_alive())
        self.assertEqual(terminal.text, "я")

    def test_editing_unicode_history_and_scrollback(self):
        terminal = Terminal(io.StringIO(), io.StringIO())
        submitted = []
        terminal.callback = submitted.append
        for char in "Привет\x1b[D!\r":
            terminal.key(char)
        self.assertEqual(submitted, ["Приве!т"])
        for char in "\x1b[A":
            terminal.key(char)
        self.assertEqual(terminal.text, "Приве!т")
        terminal.write("\n".join(str(i) for i in range(100)))
        for char in "\x1b[5~":
            terminal.key(char)
        self.assertIn("scrollback", terminal.render(50, 10))

    def test_bracketed_paste_never_executes_embedded_newlines(self):
        terminal = Terminal(io.StringIO(), io.StringIO())
        submitted = []
        terminal.callback = submitted.append
        for char in "\x1b[200~hello\n/stop\x03\x1b[201~":
            terminal.key(char)
        self.assertFalse(submitted)
        self.assertEqual(terminal.text, "hello /stop")
        terminal.key("\r")
        self.assertEqual(submitted, ["hello /stop"])

    def test_terminal_render_is_bounded_and_sanitizes_provider_controls(self):
        terminal = Terminal(io.StringIO(), io.StringIO())
        terminal.write("\x1b[2J\x1b]52;c;secret\x07" + "x" * 70000 + "\n")
        frame = terminal.render(60, 12)
        self.assertNotIn("\x1b]52", frame)
        self.assertLess(len(frame), 1000)
        self.assertLessEqual(len(terminal.tail), 4000)
        self.assertEqual(clip("a界b", 3), "a界")
        terminal.text = "界" * 64000
        terminal.cursor = len(terminal.text)
        self.assertLess(len(terminal.render(60, 12)), 1000)
        self.assertIn("Resize", terminal.render(7, 3))

    def test_non_tty_never_starts_a_hidden_input_reader(self):
        terminal = Terminal(io.StringIO(), io.StringIO())
        self.assertFalse(terminal.available())
        with self.assertRaisesRegex(ValueError, "--ui off"):
            with terminal:
                self.fail("Non-TTY should fail before starting")

    @unittest.skipIf(os.name == "nt", "POSIX PTY restoration fixture")
    def test_terminal_restores_raw_mode_on_exception(self):
        import pty
        import termios
        master, slave = pty.openpty()
        before = termios.tcgetattr(slave)
        try:
            with os.fdopen(os.dup(slave), "r", encoding="utf-8") as source, \
                    os.fdopen(os.dup(slave), "w", encoding="utf-8") as sink, patch.dict(os.environ, {"TERM": "xterm"}):
                terminal = Terminal(source, sink)
                with self.assertRaisesRegex(RuntimeError, "fixture"):
                    with terminal:
                        self.assertNotEqual(termios.tcgetattr(slave), before)
                        raise RuntimeError("fixture")
                self.assertEqual(termios.tcgetattr(slave), before)
                self.assertFalse(terminal.thread.is_alive())
        finally:
            os.close(master)
            os.close(slave)


if __name__ == "__main__":
    if sys.argv[1:] == ["fixture-ui"]:
        import cc_focus
        original = Transport.__init__
        def fixture_init(self, *args, **kwargs):
            original(self, *args, **kwargs)
            self.commands = {name: [sys.executable, "-B", str(REPO / "tests/test_cycle.py"), "fixture", name,
                                    *(["slow-ui"] if name == "claude" else [])] for name in ("codex", "claude")}
        with patch("cc_focus.Lease") as lease, patch.object(Transport, "__init__", fixture_init):
            lease.return_value.__enter__.return_value.pwsh = "pwsh"
            sys.exit(cc_focus.main(["--ui", "on"]))
    else:
        unittest.main()
