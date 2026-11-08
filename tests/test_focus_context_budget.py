"""Context budget of Claude roles: compaction window, recovery copy, usage records, writer sessions, and view search."""

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
import uuid

import test_cycle as fixtures
import test_focus_pair_execution as execution
import test_focus_refusals as refusals
import test_focus_terminal as terminal
from cycle_state import Blocked, digest
from cycle_prompts import (CLAUDE_COMPACT_WINDOW, COMPACTION_RULE, PAIR_CONTRACT, PROFILES, READER_COMPACTION_RULE,
                           READER_SEARCH_CONTRACT, role_contract)
from cycle_transport import Transport, parse_report, readable_prompt
from focus_control import status
from focus_diagnostics import (ClaudeTrace, WINDOW_MARGIN, diagnose, selected_refusals, usage_summary,
                               window_ignored)
import focus_pair_jobs
from focus_pair_jobs import run_jobs, same_pair_prompt
from focus_pair_profile import PAIR_A_WRITERS, PAIR_READONLY, PAIR_WRITERS
import focus_pair_view
from focus_pair_view import PAGE, PART, RUNTIME_PROMPT, ViewInspector, artifact, materialize, read_record
from focus_readonly import READ_TOOL, VIEW_TOOL

FIXTURE = [sys.executable, str(fixtures.REPO / "tests/test_cycle.py"), "fixture"]
# The current inspection text of a pair assignment, and the hashes of the two earlier texts.
INSPECTION = ("Use focus_inspect search/read/list/diff. Search first. Then read only the line ranges that you need. "
              "In Claude, use mcp__focus__inspect. Read new files even if their diff is empty.")


def stream(identity, usage, output=None, model="claude-opus-5-5"):
    """One assistant event of the Claude stream."""
    value = dict(usage) if output is None else dict(usage, output_tokens=output)
    return {"type": "assistant", "session_id": "s", "message": {"id": identity, "model": model, "usage": value,
                                                                 "content": [{"type": "text", "text": "Fixture"}]}}


class UsageTraceTests(unittest.TestCase):
    USAGE = {"input_tokens": 3, "cache_creation_input_tokens": 50, "cache_read_input_tokens": 900,
             "cache_creation": {"ephemeral_5m_input_tokens": 20, "ephemeral_1h_input_tokens": 30}}

    def trace(self):
        trace = ClaudeTrace()
        events = [
            {"type": "system", "subtype": "init", "session_id": "s", "model": "claude-opus-5-5",
             "claude_code_version": "2.1.319"},
            {"type": "stream_event", "session_id": "s", "event": {"type": "message_start", "message": {
                "id": "m1", "model": "claude-opus-5-5", "usage": dict(self.USAGE, output_tokens=1)}}},
            # With partial messages, each assistant event repeats the usage of its message with an interim output count.
            stream("m1", self.USAGE, 4), stream("m1", self.USAGE, 4), stream("m1", self.USAGE, 4),
            {"type": "stream_event", "session_id": "s", "event": {"type": "message_delta",
                                                                  "delta": {"stop_reason": "tool_use"},
                                                                  "usage": {"output_tokens": 25}}},
            {"type": "stream_event", "session_id": "s", "event": {"type": "message_stop"}},
            stream("m2", {"input_tokens": 2, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 1200}, 6),
            stream("m2", {"input_tokens": 2, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 1200}, 6),
            # A CLI note is not a model turn.
            stream("m3", {"input_tokens": 0, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}, 0,
                   model="<synthetic>"),
            # An event without input counters waits for a later event of the same message.
            stream("m4", {}, 3),
            stream("m4", {"input_tokens": 1, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 10}, 3),
            {"type": "system", "subtype": "compact_boundary", "session_id": "s",
             "compact_metadata": {"trigger": "auto", "pre_tokens": 500000, "post_tokens": 8000}},
        ]
        for event in events:
            trace.feed(event)
        return trace

    def test_each_message_counts_once_and_the_delta_gives_its_output(self):
        totals = self.trace().usage_totals()
        expected = {"turns": 3, "input_tokens": 6, "cache_creation_input_tokens": 50, "cache_read_input_tokens": 2110,
                    "cache_write_5m": 20, "cache_write_1h": 30, "output_tokens": 34, "peak_context": 1202,
                    "compaction_count": 1, "claude_code_version": "2.1.319",
                    "compactions": [{"trigger": "auto", "pre_tokens": 500000, "post_tokens": 8000}]}
        self.assertEqual({key: totals[key] for key in expected}, expected)
        self.assertIn("pre_tokens", totals["gap"])

    def test_session_totals_of_the_result_do_not_count(self):
        trace = self.trace()
        before = copy.deepcopy(trace.usage_totals())
        # A resumed session reports all its invocations in the result. The attempt counts only its own messages.
        trace.feed({"type": "result", "subtype": "success", "is_error": False, "session_id": "s", "total_cost_usd": 99.0,
                    "usage": {"input_tokens": 10 ** 6, "output_tokens": 10 ** 6},
                    "modelUsage": {"claude-opus-5-5": {"inputTokens": 10 ** 6, "outputTokens": 10 ** 6}}})
        self.assertEqual(trace.usage_totals(), before)
        self.assertEqual(trace.report()["usage_totals"], before)

    def test_window_warning_needs_a_peak_above_the_margin_without_compaction(self):
        limit = CLAUDE_COMPACT_WINDOW + WINDOW_MARGIN
        self.assertFalse(window_ignored({"peak_context": limit, "compaction_count": 0}))
        self.assertTrue(window_ignored({"peak_context": limit + 1, "compaction_count": 0}))
        self.assertFalse(window_ignored({"peak_context": limit + 1, "compaction_count": 1}))

    def test_usage_summary_adds_the_records_of_one_iteration_by_role(self):
        with tempfile.TemporaryDirectory() as temp:
            store = Path(temp)
            def write(invocation, attempt, value):
                folder = store / "invocations" / invocation
                folder.mkdir(parents=True, exist_ok=True)
                (folder / f"usage-{attempt}.json").write_text(json.dumps(value) if isinstance(value, dict) else value)
                return folder / f"usage-{attempt}.json"
            row = {"iteration": 2, "role": "code", "turns": 2, "cache_read_input_tokens": 100, "output_tokens": 7,
                   "peak_context": 300, "compaction_count": 1, "compactions": [{"pre_tokens": 1000}, {"trigger": "auto"}]}
            write("a", "1", row)
            write("a", "2", dict(row, peak_context=900, compactions=[{"pre_tokens": 5}]))
            write("b", "1", dict(row, role="pair_opus", turns=1, compactions="malformed"))
            write("c", "1", dict(row, iteration=1, turns=50))
            write("d", "1", "{not json")
            write("e", "1", dict(row, turns=-4, output_tokens="7"))
            link = store / "invocations" / "f"
            link.mkdir()
            try:
                (link / "usage-1.json").symlink_to(write("g", "x", dict(row, iteration=9)))
            except OSError:
                pass  # The platform does not allow links. The other rows still cover the scan.
            summary = usage_summary(store, 2)
        self.assertEqual((summary["attempts"], summary["turns"], summary["output_tokens"]), (4, 5, 21))
        self.assertEqual((summary["peak_context"], summary["compaction_pre_tokens"]), (900, 2005))
        self.assertEqual(summary["roles"]["code"]["attempts"], 3)
        self.assertEqual(summary["roles"]["pair_opus"]["compaction_pre_tokens"], 0)
        self.assertEqual(usage_summary(Path(temp) / "missing", 2)["attempts"], 0)

    def test_recovery_copy_indents_the_json_after_each_marker(self):
        assignment, schema = {"task": "Fix", "rows": [1, {"id": "x"}]}, {"type": "object"}
        prompt = ("Read the plan.\nRuntime assignment: " + json.dumps(assignment) + "\n\nThen act.\n"
                  "Executor assignment: {broken\nReport schema: " + json.dumps(schema))
        text = readable_prompt(prompt)
        self.assertTrue(text.startswith("Read the plan.\nRuntime assignment:\n{\n \"task\": \"Fix\","))
        self.assertIn("\n\nThen act.\nExecutor assignment: {broken\n", text)
        self.assertTrue(text.endswith("Report schema:\n" + json.dumps(schema, indent=1)))
        decoded = json.JSONDecoder().raw_decode(text.split("Runtime assignment:\n", 1)[1])[0]
        self.assertEqual(decoded, assignment)
        self.assertEqual(readable_prompt("No marker."), "No marker.")


class TransportBudgetTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown

    def launcher(self, provider, *variant):
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands[provider] = FIXTURE + [provider, *variant]
        return transport

    def run_role(self, transport, role, prompt, directory, log=None):
        directory.mkdir(parents=True, exist_ok=True)
        provider, model, effort = PROFILES[role]
        values = dict(ORCHESTRA_FIXTURE_MODEL=model, ORCHESTRA_FIXTURE_EFFORT=effort, ORCHESTRA_FIXTURE_ROLE=role)
        if log:
            values["ORCHESTRA_FIXTURE_SYSTEM_LOG"] = str(log)
        with patch.dict(os.environ, values):
            return parse_report(transport.run(role, prompt, {"id": directory.name}, directory), role)

    def inspection(self):
        self.state["inspection"] = {"root": str(self.root), "files": {
            "source.txt": hashlib.sha256((self.root / "source.txt").read_bytes()).hexdigest()},
            "stage_paths": ["source.txt"], "diffs": {}}
        self.state["inspection_path"] = str(self.root / "manifest.json")
        return self.state["inspection"]

    def test_a_writer_gets_the_window_a_stable_rule_and_one_usage_record_per_attempt(self):
        log = self.store.directory / "system.log"
        transport = self.launcher("claude", "usage-stream")
        first, second = (self.store.directory / "invocations" / uuid.uuid4().hex for _ in range(2))
        # The fixture checks the window in the environment and in --settings.
        self.run_role(transport, "code", 'Runtime assignment: {"step": 1}', first, log)
        session = self.state["sessions"]["code"]
        self.run_role(transport, "code", 'Runtime assignment: {"step": 2}', first, log)  # A retry in the same directory.
        self.run_role(transport, "code", 'Runtime assignment: {"step": 3}', second, log)
        self.assertEqual(self.state["sessions"]["code"], session)
        recovery = self.store.directory / "prompts" / "code.txt"
        prompts = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(prompts), 3)
        # A resumed session sends the same system prompt, so its cached history stays valid.
        self.assertEqual(len(set(prompts)), 1)
        self.assertTrue(prompts[0].endswith("\n\n" + COMPACTION_RULE.format(path=recovery)))
        self.assertIn('Runtime assignment:\n{\n "step": 3\n}', recovery.read_text(encoding="utf-8"))
        self.assertIn('Runtime assignment: {"step": 3}', (second / "prompt.txt").read_text(encoding="utf-8"))
        records = {folder: [json.loads(p.read_text()) for p in sorted(folder.glob("usage-*.json"))] for folder in (first, second)}
        self.assertEqual([len(rows) for rows in records.values()], [2, 1])
        rows = sorted(records[first] + records[second], key=lambda row: row["at"])
        self.assertEqual(len({row["attempt"] for row in rows}), 3)
        for row in rows:
            self.assertEqual((row["role"], row["iteration"], row["store"], row["session_id"]),
                             ("code", self.state.get("iteration"), str(self.store.directory), session))
            # Each attempt counts only its own two messages, not the earlier invocations of its session.
            self.assertEqual((row["turns"], row["output_tokens"], row["cache_write_5m"], row["cache_write_1h"]), (2, 47, 100, 200))
            self.assertEqual((row["peak_context"], row["compaction_count"]), (9005, 1))
            self.assertEqual(row["compactions"], [{"trigger": "auto", "pre_tokens": 390000, "post_tokens": 9000}])
        self.assertEqual([row["resumed"] for row in rows], [False, True, True])
        summary = status(self.store, self.state)["usage"]
        self.assertEqual((summary["attempts"], summary["output_tokens"], summary["compaction_pre_tokens"]), (3, 141, 1170000))
        self.assertEqual(summary["roles"]["code"]["turns"], 6)
        attempts = diagnose(self.store.directory, first.name)["attempts"]
        self.assertEqual([a["usage"]["turns"] for a in attempts], [2, 2])
        self.assertEqual([a["window_exceeded_without_compaction"] for a in attempts], [False, False])

    def test_a_pair_reader_reads_its_recovery_copy_only_through_the_view(self):
        manifest = self.inspection()
        log = self.store.directory / "system.log"
        directory = self.store.directory / "invocations" / uuid.uuid4().hex
        self.run_role(self.launcher("claude"), "pair_opus", "Runtime context: {\"scope\": \"source.txt\"}", directory, log)
        prompt = json.loads(log.read_text(encoding="utf-8"))
        self.assertTrue(prompt.endswith("\n\n" + READER_COMPACTION_RULE))
        self.assertIn(READER_SEARCH_CONTRACT, prompt)
        self.assertNotIn(str(self.store.directory), prompt)
        recovery = self.store.directory / "prompts" / "pair_opus.txt"
        reader = ViewInspector(manifest, recovery)
        result = reader.call({"tool": "focus_inspect", "arguments": {
            "operation": "read", "path": RUNTIME_PROMPT, "pattern": None, "offset": 0, "limit": 20}})
        self.assertTrue(result["success"], result)
        self.assertIn('"scope": "source.txt"', result["contentItems"][0]["text"])

    def test_codex_view_readers_get_search_and_other_readers_keep_the_old_tool(self):
        self.inspection()
        # The fixture checks that the thread starts with VIEW_TOOL only for a pair reader.
        for role in ("pair_sol", "sol"):
            with self.subTest(role=role):
                directory = self.store.directory / "invocations" / uuid.uuid4().hex
                self.assertEqual(self.run_role(self.launcher("codex"), role, "Inspect", directory)["status"], "done")
        self.assertNotIn("search", READ_TOOL["inputSchema"]["properties"]["operation"]["enum"])
        self.assertNotIn("pattern", READ_TOOL["inputSchema"]["properties"])
        schema = VIEW_TOOL["inputSchema"]
        self.assertEqual(schema["properties"]["operation"]["enum"], ["read", "search", "list", "diff"])
        self.assertEqual(set(schema["required"]), set(schema["properties"]))
        self.assertEqual(schema["properties"]["pattern"]["type"], ["string", "null"])


class OperatorMessageTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    setup_input = terminal.FocusInputTests.setup_input
    run_transport = terminal.FocusInputTests.run_transport

    def test_a_delivered_message_joins_the_recovery_copy(self):
        transport, directory = self.run_transport("claude")
        result = transport.run("code", "Implement", self.pending, directory)
        self.assertIn("handled in the same process", result)
        copy_text = (self.store.directory / "prompts" / "code.txt").read_text(encoding="utf-8")
        self.assertIn("\n\nOperator messages:\n", copy_text)
        self.assertIn("Check interrupted recovery as well.", copy_text.split("Operator messages:", 1)[1])
        self.assertNotIn("Operator messages:", (directory / "prompt.txt").read_text(encoding="utf-8"))


class ViewSearchTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown

    def view(self, files, links=()):
        for name, data in files.items():
            path = self.root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data if isinstance(data, bytes) else data.encode("utf-8"))
        for name, target in links:
            (self.root / name).symlink_to(target)
        pair = {"id": uuid.uuid4().hex, "phase": "final", "snapshot": self.repo.snapshot()}
        return pair, materialize(self.cycle, pair)

    def call(self, reader, operation, path, pattern=None, offset=0, limit=50, **extra):
        arguments = {"operation": operation, "path": path, "pattern": pattern, "offset": offset, "limit": limit, **extra}
        return reader.call({"tool": "focus_inspect", "arguments": arguments})

    def text(self, reader, *args, **kwargs):
        result = self.call(reader, *args, **kwargs)
        self.assertTrue(result["success"], result)
        return result["contentItems"][0]["text"]

    def test_search_finds_literal_text_in_path_and_line_order(self):
        _, view = self.view({"docs/b.md": "needle b\n", "docs/a.md": "one\nNeedle\nthe needle here\n",
                             "src/c.txt": "needle c\n", "bin.dat": b"needle\0needle\n"}, [("link.md", "docs/a.md")])
        reader = ViewInspector(view)
        rows = self.text(reader, "search", ".", "needle").splitlines()
        self.assertEqual(rows[0], "Matches shown: 3; offset: 0")
        self.assertEqual(rows[1:], ["docs/a.md:3 (row 2): the needle here", "docs/b.md:1 (row 0): needle b",
                                    "src/c.txt:1 (row 0): needle c"])
        self.assertEqual(self.text(reader, "search", "docs/b.md", "needle").splitlines()[1:], ["docs/b.md:1 (row 0): needle b"])
        self.assertEqual(len(self.text(reader, "search", "docs", "needle").splitlines()), 3)
        # A link entry holds the link target as text. A search does not show it.
        self.assertEqual(self.text(reader, "search", ".", "(not followed)").splitlines(), ["Matches shown: 0; offset: 0"])
        for path in ("../source.zip", "/etc", "docs\\a.md", "missing", "doc"):
            with self.subTest(path=path):
                self.assertFalse(self.call(reader, "search", path, "needle")["success"])

    def test_search_pages_by_matches_and_by_the_page_budget(self):
        _, view = self.view({"many.txt": "".join(f"match {i}\n" for i in range(7)),
                             "wide.txt": "".join(f"match {'w' * 380} {i}\n" for i in range(150))})
        reader = ViewInspector(view)
        text = self.text(reader, "search", "many.txt", "match", offset=2, limit=3)
        self.assertEqual(text.splitlines(), ["Matches shown: 3; offset: 2; more matches exist; next offset: 5",
                                             "many.txt:3 (row 2): match 2", "many.txt:4 (row 3): match 3",
                                             "many.txt:5 (row 4): match 4",
                                             "[The page stops before match 5. Continue at offset 5.]"])
        self.assertEqual(self.text(reader, "search", "many.txt", "match", offset=5, limit=3).splitlines()[0],
                         "Matches shown: 2; offset: 5")
        text = self.text(reader, "search", "wide.txt", "match", limit=200)
        self.assertLessEqual(len(text.encode("utf-8")), PAGE)
        stop = int(text.splitlines()[0].rsplit("next offset: ", 1)[1])
        self.assertEqual(len(text.splitlines()), stop + 2)
        # The header counts the rows of this page, not the matches that the limit allowed.
        self.assertEqual(text.splitlines()[0], f"Matches shown: {stop}; offset: 0; more matches exist; next offset: {stop}")
        self.assertTrue(text.endswith(f"[The page stops before match {stop}. Continue at offset {stop}.]"))
        rest = self.text(reader, "search", "wide.txt", "match", offset=stop, limit=200)
        self.assertIn(f"wide.txt:{stop + 1} (row {stop}): match", rest)

    def test_a_match_in_a_long_line_names_the_row_of_its_part(self):
        line = "x" * (PART * 2 + 10) + "needle" + "y" * 1000
        _, view = self.view({"long.txt": "first\n" + line + "\n"})
        reader = ViewInspector(view)
        row = self.text(reader, "search", "long.txt", "needle").splitlines()[1]
        self.assertTrue(row.startswith("long.txt:2 (row 3): …"), row[:40])
        window = row.split(": ", 1)[1]
        self.assertLessEqual(len(window), 402)
        self.assertIn("needle", window)
        self.assertIn("2 part 3/3: " + "x" * 10 + "needle", self.text(reader, "read", "long.txt", offset=3, limit=1))

    def test_invalid_search_arguments_are_refused(self):
        _, view = self.view({"a.txt": "needle\n"})
        reader = ViewInspector(view)
        for pattern in ("", "x" * 201, "a\nb", "a\rb", "a\0b", 5, None):
            with self.subTest(pattern=pattern):
                self.assertFalse(self.call(reader, "search", "a.txt", pattern)["success"])
        self.assertTrue(self.call(reader, "search", "a.txt", "x" * 200)["success"])
        self.assertFalse(self.call(reader, "search", "a.txt", "needle", limit=201)["success"])
        for operation in ("read", "list", "diff"):
            with self.subTest(operation=operation):
                self.assertFalse(self.call(reader, operation, "a.txt", "needle")["success"])
        self.assertFalse(self.call(reader, "read", "a.txt", extra=1)["success"])
        # The legacy inspector of the other read-only roles has no search.
        from focus_readonly import Inspector
        legacy = Inspector(self.root, self.state)
        for arguments in ({"operation": "search", "path": "a.txt", "offset": 0, "limit": 5},
                          {"operation": "read", "path": "a.txt", "pattern": None, "offset": 0, "limit": 5}):
            with self.subTest(arguments=arguments):
                self.assertFalse(legacy.call({"tool": "focus_inspect", "arguments": arguments})["success"])
        # A resumed Codex thread keeps its old tool and sends four fields.
        old = reader.call({"tool": "focus_inspect", "arguments": {"operation": "read", "path": "a.txt", "offset": 0, "limit": 5}})
        self.assertTrue(old["success"], old)
        old = reader.call({"tool": "focus_inspect", "arguments": json.dumps({"operation": "list", "path": ".", "offset": 0, "limit": 5})})
        self.assertTrue(old["success"], old)

    def test_the_runtime_prompt_is_readable_only_as_one_file(self):
        _, view = self.view({"a.txt": "needle\n"})
        recovery = self.store.directory / "prompts" / "pair_opus.txt"
        recovery.parent.mkdir(parents=True)
        recovery.write_text("Runtime context:\nneedle in the prompt\n", encoding="utf-8")
        self.assertFalse(self.call(ViewInspector(view), "read", RUNTIME_PROMPT)["success"])
        reader = ViewInspector(view, recovery)
        self.assertIn("2: needle in the prompt", self.text(reader, "read", RUNTIME_PROMPT))
        self.assertNotIn("__runtime__", self.text(reader, "list", "."))
        self.assertEqual(self.text(reader, "search", ".", "in the prompt").splitlines(), ["Matches shown: 0; offset: 0"])
        for operation, path in (("read", "__runtime__/other.txt"), ("search", "__runtime__"), ("search", RUNTIME_PROMPT),
                                ("diff", RUNTIME_PROMPT)):
            with self.subTest(operation=operation, path=path):
                self.assertFalse(self.call(reader, operation, path, "needle" if operation == "search" else None)["success"])

    def test_a_project_file_cannot_take_the_runtime_prompt_path(self):
        with self.assertRaises(Blocked) as caught:
            self.view({RUNTIME_PROMPT: "project text\n"})
        self.assertEqual(caught.exception.code, "pair-input")

    def test_the_text_cache_keeps_below_its_limit(self):
        _, view = self.view({f"f{i}.txt": f"needle {i}\n" + "z" * 40 + "\n" for i in range(6)} | {"big.txt": "needle\n" + "b" * 400})
        with patch.object(focus_pair_view, "TEXT_CACHE", 120):
            reader = ViewInspector(view)
            for _ in range(2):
                self.assertEqual(len(self.text(reader, "search", ".", "needle").splitlines()), 8)
                self.assertLessEqual(reader.cached, 120)
                self.assertEqual(reader.cached, sum(size for _, size in reader.texts.values()))
                self.assertNotIn("big.txt", reader.texts)

    def test_the_mcp_server_serves_search_and_the_runtime_prompt(self):
        pair, _ = self.view({"a.txt": "needle\n"})
        recovery = self.store.directory / "prompts" / "pair_opus.txt"
        recovery.parent.mkdir(parents=True)
        recovery.write_text("Report schema: {}\n", encoding="utf-8")
        requests = [{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                    {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}]
        for index, (operation, path, pattern) in enumerate((("search", ".", "needle"), ("read", RUNTIME_PROMPT, None)), 3):
            requests.append({"jsonrpc": "2.0", "id": index, "method": "tools/call", "params": {"name": "inspect", "arguments": {
                "operation": operation, "path": path, "pattern": pattern, "offset": 0, "limit": 20}}})
        result = subprocess.run([sys.executable, str(fixtures.REPO / "tools/focus_pair_view.py"),
                                 str(self.store.directory / pair["view"]["path"]), str(recovery)],
                                input="".join(json.dumps(r) + "\n" for r in requests), capture_output=True, text=True, timeout=60)
        replies = [json.loads(line)["result"] for line in result.stdout.splitlines()]
        self.assertEqual(replies[1]["tools"][0]["inputSchema"], VIEW_TOOL["inputSchema"])
        self.assertEqual(replies[2]["content"][0]["text"].splitlines()[1], "a.txt:1 (row 0): needle")
        self.assertIn("1: Report schema: {}", replies[3]["content"][0]["text"])


class WriterSessionTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    edit = fixtures.CycleTests.edit
    start = execution.PairExecutionTests.start
    assign = execution.PairExecutionTests.assign
    until = execution.PairExecutionTests.until
    step = execution.PairExecutionTests.step
    prepare = execution.PairExecutionTests.prepare
    resolution = execution.PairExecutionTests.resolution
    result = execution.PairExecutionTests.result

    def test_a_new_outer_pair_drops_only_the_pair_a_writer_sessions(self):
        self.start("pair_a")
        roles = (*PAIR_WRITERS, "code", "pair_opus")
        self.state["sessions"].update({role: "old-" + role for role in roles})
        self.cycle.new_pair()
        for state in (self.state, self.store.read()):
            self.assertEqual(set(state["sessions"]) & set(PAIR_A_WRITERS), set())
            self.assertEqual({role: state["sessions"][role] for role in ("repair_execute", "code", "pair_opus")},
                             {"repair_execute": "old-repair_execute", "code": "old-code", "pair_opus": "old-pair_opus"})

    def test_the_next_executor_starts_a_new_session(self):
        self.start("pair_a")
        self.state["sessions"]["pair_fix"] = "old-pair_fix"
        self.cycle.new_pair()
        transport = Transport(self.root, self.state, self.store.save, lambda: None)
        transport.commands["claude"] = FIXTURE + ["claude"]
        directory = self.store.directory / "invocations" / uuid.uuid4().hex
        directory.mkdir(parents=True)
        provider, model, effort = PROFILES["pair_fix"]
        with patch.dict(os.environ, ORCHESTRA_FIXTURE_MODEL=model, ORCHESTRA_FIXTURE_EFFORT=effort, ORCHESTRA_FIXTURE_ROLE="pair_fix"):
            parse_report(transport.run("pair_fix", "Fix", {"id": directory.name}, directory), "pair_fix")
        self.assertNotIn(self.state["sessions"]["pair_fix"], ("old-pair_fix", None))
        launch = json.loads((directory / "claude-diagnostics.json").read_text())["launch"]
        self.assertIs(launch.get("resumed"), False)

    def test_a_disputed_execution_runs_again_in_the_same_session(self):
        pair = self.prepare()
        calls = []
        def disputed(c, h):
            calls.append(c)
            (self.root / "source.txt").write_text("partially fixed\n")
            return self.result([self.resolution("assigned", "disputed")], implementation_fixes=1)
        self.transport.handlers[self.role] = disputed
        self.step()  # The executor disputes the assignment.
        def fixed(c, h):
            calls.append(c)
            return self.result([self.resolution(t["source_id"], "verified" if t["action"] == "verify" else "fixed")
                                for t in c["assignments"]])
        self.transport.handlers[self.role] = fixed
        for _ in range(3):  # Arbitration, then the changed candidate permits the assignment, then its complexity.
            self.step()
            self.assertIs(self.state["pair_review"], pair)
            self.assertEqual(self.state["sessions"][self.role], "saved-writer-session")
        self.step()  # The execution runs again inside the same pair.
        self.assertEqual(len(calls), 2)
        self.assertEqual(self.state["sessions"][self.role], "saved-writer-session")

    def test_the_continuation_inside_one_pair_keeps_the_writer_session(self):
        pair = self.prepare()
        self.step()  # The first report leaves the check open.
        self.assertIs(self.state["pair_review"], pair)
        self.assertEqual(self.state["sessions"][self.role], "saved-writer-session")
        self.step()
        self.assertEqual(len(self.calls), 2)
        self.assertIn("continuation", self.calls[1])
        self.assertEqual(self.state["sessions"][self.role], "saved-writer-session")

    def test_the_writer_context_lists_the_stage_handoff(self):
        pair = self.prepare()
        legacy = artifact(self.store, "pair-reviews/legacy-handoff.json", {"role": "pair_fix", "sources": []})
        self.state["pair_handoff"] = [legacy]  # An older record has no phase or round.
        context = json.loads(self.cycle.pair_writer_context(self.role).split("Executor assignment:\n", 1)[1])
        self.assertEqual(context["stage_handoff"], [{"path": str(self.store.directory / legacy["path"])}])
        self.assertTrue(context["stage_handoff_rule"].startswith("Read the stage handoff when you need an earlier decision"))
        def disputed(c, h):
            (self.root / "source.txt").write_text("partially fixed\n")
            return self.result([self.resolution("assigned", "disputed")], implementation_fixes=1)
        self.transport.handlers[self.role] = disputed
        self.step()
        refs = self.state["pair_handoff"]
        self.assertEqual(len(refs), 2)
        record = read_record(self.store, refs[-1])
        self.assertEqual((record["phase"], record["round"]), ("pair_a", pair["round"]))
        rows = self.cycle.stage_handoff()
        self.assertEqual([row["path"] for row in rows], [str(self.store.directory / ref["path"]) for ref in refs])
        self.assertTrue(all(Path(row["path"]).is_absolute() and Path(row["path"]).is_file() for row in rows))
        self.assertEqual(rows[-1], {"path": rows[-1]["path"], "phase": "pair_a", "round": pair["round"]})
        # A repair seal keeps its inner review rounds. Its outer round is pair_round.
        seal = artifact(self.store, "pair-reviews/seal.json", {"phase": "pair_b", "round": 3, "pair_round": 2})
        old_seal = artifact(self.store, "pair-reviews/old-seal.json", {"round": 3})
        self.state["pair_handoff"] += [seal, old_seal]
        self.assertEqual(self.cycle.stage_handoff()[-2:], [
            {"path": str(self.store.directory / seal["path"]), "phase": "pair_b", "round": 2},
            {"path": str(self.store.directory / old_seal["path"])}])
        (self.store.directory / legacy["path"]).write_text("{}")
        with self.assertRaises(Blocked) as caught:
            self.cycle.stage_handoff()
        self.assertEqual(caught.exception.code, "pair-evidence")


class CorrectionTests(unittest.TestCase):
    setUp = refusals.RefusalHistoryTests.setUp
    claude_invocation = refusals.RefusalHistoryTests.claude_invocation

    def test_a_correction_after_a_refused_pair_a_writer_starts_a_new_session(self):
        session = "44444444-4444-4444-4444-444444444444"
        self.claude_invocation("f" * 32, session, 4000, "Fix.\n", refused=True, launch={"role": "pair_fix"})
        for role in (*PAIR_A_WRITERS, "repair_execute", "code"):
            with self.subTest(role=role):
                state = {"sessions": {role: session},
                         "blocker": {"code": "claude-refusal", "interrupted": {"id": "f" * 32, "role": role}}}
                self.assertEqual(len(selected_refusals(self.directory, state)), 1)
                # The next pair or repair batch drops a writer session. The code role keeps its session.
                self.assertEqual(len(selected_refusals(self.directory, state, correction=True)), int(role == "code"))

    def test_diagnose_warns_when_a_session_passes_the_window_without_compaction(self):
        # An older log without attempt marks starts a new attempt at an event of another session.
        big = lambda session: {"type": "assistant", "session_id": session, "message": {"id": "big", "model": "claude-opus-5-5", "usage": {
            "input_tokens": 1, "cache_creation_input_tokens": 0,
            "cache_read_input_tokens": CLAUDE_COMPACT_WINDOW + WINDOW_MARGIN, "output_tokens": 1}}}
        compacted = {"type": "system", "subtype": "compact_boundary", "compact_metadata": {"trigger": "auto", "pre_tokens": 1}}
        first, second = "11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"
        self.claude_invocation("a" * 32, first, 1000, "Fix.\n", result=refusals.RefusalHistoryTests.SUCCESS, extra=[big(first)])
        self.claude_invocation("b" * 32, second, 2000, "Fix.\n", result=refusals.RefusalHistoryTests.SUCCESS,
                               extra=[big(second), dict(compacted, session_id=second)])
        warned = diagnose(self.directory, "a" * 32)["attempts"][0]
        self.assertTrue(warned["window_exceeded_without_compaction"])
        self.assertEqual(warned["usage"]["peak_context"], CLAUDE_COMPACT_WINDOW + WINDOW_MARGIN + 1)
        self.assertFalse(diagnose(self.directory, "b" * 32)["attempts"][0]["window_exceeded_without_compaction"])


class ContractTests(unittest.TestCase):
    def test_only_pair_readers_get_the_reading_guidance(self):
        for role in PROFILES:
            with self.subTest(role=role):
                self.assertEqual(READER_SEARCH_CONTRACT in role_contract(role), role in PAIR_READONLY)
        self.assertNotIn(READER_SEARCH_CONTRACT, PAIR_CONTRACT)

    def test_saved_reader_jobs_with_both_earlier_inspection_texts_still_match(self):
        source = (fixtures.REPO / "tools/focus_pairs.py").read_text(encoding="utf-8")
        self.assertIn(INSPECTION, source)
        previous = json.loads((fixtures.REPO / "tests/fixtures/focus_v8_instruction_style.json").read_text())
        row = next(r for r in previous["changes"] if r["path"] == ["inspection"])
        targets = {(old, new) for path, old, new in focus_pair_jobs._STYLE_TEXT if path == ("inspection",)}
        current = digest(INSPECTION.encode())
        for text in (row["old"], row["new"]):
            with self.subTest(text=text[:40]):
                self.assertIn((digest(text.encode()), current), targets)
                context = {"candidate": "same", "assignment": {"mode": "independent_initial"}}
                render = lambda value: PAIR_CONTRACT + "\nRuntime assignment:\n" + json.dumps(dict(context, inspection=value))
                self.assertTrue(same_pair_prompt(render(text), render(INSPECTION)))
                self.assertFalse(same_pair_prompt(render(text), render(INSPECTION + " Run a shell.")))
                self.assertFalse(same_pair_prompt(render(text), render(INSPECTION).replace('"same"', '"other"')))


class ReaderCorrectionTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    edit = fixtures.CycleTests.edit
    start = execution.PairExecutionTests.start

    def test_an_invalid_reader_report_gets_the_full_job_prompt_again(self):
        self.start()
        (self.root / "source.txt").write_text("initial\n")
        self.state["last_snapshot"] = self.repo.snapshot()
        native = Transport(self.root, self.state, self.store.save, lambda: None)
        native.commands["codex"] = FIXTURE + ["codex", "paired-report-once"]
        self.cycle.transport = native
        pair = self.cycle.new_pair()
        view = materialize(self.cycle, pair)
        with patch.dict(os.environ, ORCHESTRA_FIXTURE_ROLE="pair_sol"):
            reports = run_jobs(self.cycle, pair, [("scan/pair_sol", "pair_sol", "Review this exact candidate")], view)
        self.assertEqual(reports[0]["status"], "done")
        job = pair["jobs"]["scan/pair_sol"]
        self.assertEqual(job["report_repairs"], 1)
        correction = (self.store.directory / "invocations" / job["id"] / "prompt.txt").read_text()
        # A reader that lost its prompt in a compaction gets all of it again with the correction.
        self.assertIn("Review this exact candidate", correction)
        self.assertIn("Previous public report to correct:", correction)

    def test_a_compacted_claude_reader_with_an_invalid_report_gets_the_full_job_prompt_again(self):
        self.start()
        (self.root / "source.txt").write_text("initial\n")
        self.state["last_snapshot"] = self.repo.snapshot()
        native = Transport(self.root, self.state, self.store.save, lambda: None)
        native.commands["claude"] = FIXTURE + ["claude", "usage-stream", "paired-report-once"]
        self.cycle.transport = native
        pair = self.cycle.new_pair()
        view = materialize(self.cycle, pair)
        with patch.dict(os.environ, ORCHESTRA_FIXTURE_ROLE="pair_opus"):
            reports = run_jobs(self.cycle, pair, [("scan/pair_opus", "pair_opus", "Review this exact candidate")], view)
        self.assertEqual(reports[0]["status"], "done")
        job = pair["jobs"]["scan/pair_opus"]
        self.assertEqual(job["report_repairs"], 1)
        folder = self.store.directory / "invocations" / job["id"]
        correction = (folder / "prompt.txt").read_text()
        self.assertIn("Review this exact candidate", correction)
        self.assertIn("Previous public report to correct:", correction)
        # The recovery copy holds the correction prompt, so a later compaction loses neither part.
        recovery = (self.store.directory / "prompts" / "pair_opus.txt").read_text(encoding="utf-8")
        self.assertIn("Review this exact candidate", recovery)
        self.assertIn("Previous public report to correct:", recovery)
        usage = [json.loads(p.read_text()) for p in folder.glob("usage-*.json")]
        self.assertEqual(sorted(row["compaction_count"] for row in usage), [1, 1])


if __name__ == "__main__":
    unittest.main()
