"""Status projections and real workflow transitions; no external providers."""

import io
import json
from pathlib import Path
import time
import unittest
from unittest.mock import patch

import test_cycle as fixtures
from cycle_state import Blocked, encode
from cycle_transport import parse_report
from cycle_prompts import REPORT_SCHEMA
from focus_control import Control, status
from focus_input import Interaction
from focus_messages import Messages
from focus_progress import Progress
from focus_status import StatusPanel, accept_task, build_panel, new_reviews, review_event
from focus_terminal import Terminal, cell_width


class StatusTests(unittest.TestCase):
    setUp = fixtures.CycleTests.setUp
    tearDown = fixtures.CycleTests.tearDown
    edit = fixtures.CycleTests.edit
    remote = fixtures.CycleTests.remote
    commit_stage = fixtures.CycleTests.commit_stage

    def label(self):
        return {"id": "V9f-4", "title": "Раскрытие поставщика и повтор сообщений", "plan": "source.txt"}

    def panel_text(self, **kwargs):
        return "\n".join(build_panel(self.state, **kwargs).lines)

    def run_review(self, role="astra", **kwargs):
        self.transport.actions.append((role, fixtures.report(**kwargs)))
        self.cycle.review(role)

    def test_optional_labels_preserve_old_report_contract(self):
        self.assertEqual(set(REPORT_SCHEMA["required"]), set(REPORT_SCHEMA["properties"]))
        old = fixtures.report()
        self.assertEqual(parse_report(json.dumps(old), "code"), old)
        for task in (None, self.label(), "bad", {"id": "missing fields"}):
            parsed = parse_report(json.dumps(fixtures.report(task=task)), "code")
            accept_task(self.state, parsed, "code")
        self.assertEqual(self.state["task"]["id"], "V9f-4")
        with self.assertRaises(Blocked):
            parse_report(json.dumps(fixtures.report(unrecognized=True)), "code")
        with self.assertRaises(Blocked):
            parse_report(json.dumps(fixtures.report(task=self.label(), implementation_fixes=-1)), "code")

    def test_coordinator_supplies_title_without_extra_calls(self):
        self.transport.actions = [("coordinate", fixtures.report(task=self.label()))]
        self.cycle.invoke("coordinate")
        self.cycle.complete_invocation()
        self.assertIn("V9f-4", self.panel_text())
        self.assertIn("Раскрытие поставщика", self.cycle.context("astra"))
        self.assertEqual([role for role, _ in self.transport.calls], ["coordinate"])
        self.assertEqual(self.repo.snapshot(), self.state["baseline"])
        self.assertEqual(self.store.read()["task"]["plan"], "source.txt")

    def test_labels_cannot_escape_repository_or_switch_iteration_identity(self):
        outside = Path(self.temp.name) / "outside.md"
        outside.write_text("External", encoding="utf-8")
        for path in (str(outside), "../outside.md", "missing.md"):
            accept_task(self.state, {"task": dict(self.label(), plan=path)}, "coordinate")
            self.assertIsNone(self.state["task"])
        accept_task(self.state, {"task": self.label()}, "coordinate")
        accept_task(self.state, {"task": dict(self.label(), id="V10")}, "coordinate")
        accept_task(self.state, {"task": dict(self.label(), title="Wrong")}, "heal")
        self.assertEqual(self.state["task"]["id"], "V9f-4")
        self.assertNotIn("Wrong", self.panel_text())
        self.state["iteration"] += 1
        self.assertIn("Задача 2", self.panel_text())
        self.assertNotIn("V9f-4", self.panel_text())

    def test_review_progress_counts_completed_passes_and_resets_streak(self):
        self.state["phase"] = "astra"
        for _ in range(2):
            self.run_review()
        self.assertIn("серия 2/3", self.panel_text())
        self.run_review(implementation_fixes=1)
        self.assertIn("исправления · серия 0/3", self.panel_text())
        self.assertIn("завершено 3", self.panel_text())
        active = self.panel_text(live={"role": "astra", "active": True})
        self.assertIn("проход 4 выполняется", active)
        self.assertIn("нужно ≥3", active)
        for _ in range(3):
            self.run_review()
        self.assertEqual(self.state["phase"], "claude")
        self.assertIn("✓ зачтено 3/3 · завершено 6", self.panel_text())
        for _ in range(2):
            self.run_review("claude")
        self.assertEqual(self.state["phase"], "publish")
        self.assertIn("✓ зачтено 2/2", self.panel_text())
        self.assertIn("▶ Публикация", self.panel_text())

    def test_claude_return_keeps_totals_and_explains_both_resets(self):
        self.state["phase"] = "astra"
        for _ in range(3):
            self.run_review()
        self.run_review("claude")
        self.run_review("claude", implementation_fixes=1, substantial=True)
        self.assertEqual(self.state["phase"], "astra")
        self.assertIn("возврат к Astra", self.panel_text())
        self.assertEqual(self.state["display_reviews"]["astra"]["completed"], 3)
        self.assertEqual(self.state["display_reviews"]["claude"]["completed"], 2)
        self.assertEqual((self.state["astra_clean"], self.state["claude_clean"]), (0, 0))

    def test_rejected_pass_never_increments_display_count(self):
        self.state["phase"] = "astra"
        self.run_review()
        self.transport.actions = [("astra", fixtures.report(evidence=[]))]
        with self.assertRaises(Blocked) as caught:
            self.cycle.review("astra")
        self.cycle.handle_block(caught.exception)
        self.assertEqual(self.state["display_reviews"]["astra"]["completed"], 1)
        self.assertIn("не зачтено · серия 0/3", self.panel_text())

    def test_legacy_history_is_explicitly_incomplete_and_bounded(self):
        del self.state["display_reviews"]
        self.state.update(phase="astra", astra_passes=4, astra_clean=1, claude_clean=0)
        self.assertIn("завершено ≥4", self.panel_text())
        self.run_review()
        self.assertIn("завершено ≥5", self.panel_text())
        for _ in range(30):
            review_event(self.state, "astra", "прервано")
        self.assertEqual(len(self.state["display_review_events"]), 12)
        self.assertEqual(self.state["display_reviews"]["astra"]["completed"], 5)

    def test_next_stage_archives_labels_and_clears_current_display(self):
        self.remote()
        self.edit()()
        self.state.update(phase="publish", reviewed=self.repo.snapshot(), remote="origin")
        self.commit_stage()
        self.cycle.reconcile_publish()
        accept_task(self.state, {"task": self.label()}, "code")
        review_event(self.state, "astra", "чисто", completed=True)
        self.state["display_ci"] = {"sha": self.state["published"]["sha"], "status": "ready"}
        self.cycle.next_stage()
        archived = json.loads((self.store.directory / "iterations/000001.json").read_text())
        self.assertEqual(archived["task"]["id"], "V9f-4")
        self.assertEqual(self.state["display_reviews"], new_reviews())
        self.assertIsNone(self.state["display_ci"])
        self.assertIn("Задача 2", self.panel_text())

    def test_activity_priority_and_provider_lifetime(self):
        live = {"role": "astra", "active": True, "elapsed_seconds": 125, "event_age_seconds": 8}
        self.assertIn("02:05", self.panel_text(live=live))
        self.assertIn("8 с назад", self.panel_text(live=live))
        self.assertIn("Ревью Astra · high", self.panel_text(live=live))
        self.assertNotIn("high", self.panel_text(live=live, paused=True))
        self.assertNotIn("high", self.panel_text(live=dict(live, active=False)))
        self.assertIn("НУЖНО СОГЛАСИЕ", self.panel_text(live=live, approval=True, notice="Queued"))
        self.assertIn("/approve", self.panel_text(live=live, approval=True, notice="Queued"))
        self.state["blocker"] = {"status": "blocked", "message": "Network unavailable"}
        blocked = build_panel(self.state, live, paused=True, approval=True, notice="Queued")
        self.assertEqual(blocked.tone, "error")
        self.assertIn("Network unavailable", blocked.compact[-1])
        self.assertIn("БЛОКИРОВКА", blocked.compact[0])

    def test_coordination_healing_and_git_are_actual_activities(self):
        self.state["phase"] = "publish"
        self.assertIn("Координация → Публикация", self.panel_text(live={"role": "coordinate", "active": True}))
        self.assertIn("ВОССТАНОВЛЕНИЕ", self.panel_text(live={"role": "heal", "active": True}))
        text = self.panel_text(live={"operation": "git", "active": False, "role": None})
        self.assertIn("Проверка Git remote", text)
        self.assertNotIn("Luna", text)
        self.assertIn("модель не запущена", text)

    def test_ci_display_is_tied_to_publication_sha(self):
        self.state.update(phase="ci", published={"sha": "current"},
                          display_ci={"sha": "old", "status": "ready"})
        self.assertNotIn("✓ CI", self.panel_text())
        self.state["display_ci"] = {"sha": "current", "status": "not-configured"}
        self.assertIn("— CI не требуется", self.panel_text())
        self.state["display_ci"] = {"sha": "current", "status": "waiting", "total": 4, "passed": 2}
        self.assertIn("успешно 2/4", self.panel_text())
        self.state["display_ci"]["status"] = "ready"
        self.assertIn("✓ CI", self.panel_text())
        # A returned review must certify the next publication/CI again, even
        # while the preceding publication SHA is still preserved for recovery.
        self.state["phase"] = "astra"
        self.assertIn("○ CI", self.panel_text())
        self.assertNotIn("✓ CI", self.panel_text())

    def test_healer_during_ci_shows_its_command_instead_of_ci_waiting(self):
        self.state.update(phase="ci", blocker={"status": "healing"})
        text = self.panel_text(live={"role": "heal", "active": True, "activity": "command running"})
        self.assertIn("ВОССТАНОВЛЕНИЕ", text)
        self.assertIn("Команда выполняется", text)
        self.assertNotIn("ожидание проверок", text)

    def test_progress_callbacks_and_message_cache_do_not_read_history_on_tick(self):
        terminal = Terminal(stdout=io.StringIO())
        interaction = Interaction(terminal)
        control = Control(self.store)
        control.begin()
        interaction.bind(control, self.state, self.store.save)
        progress = Progress(self.store, self.state)
        interaction.progress, progress.on_update = progress, interaction.tick
        progress.start("code", self.store.directory)
        self.assertIn("Fable 5.1/high", terminal.panel.lines[1])
        interaction.message_states = {"queued-id": "queued"}
        interaction.update_message_notice()
        with patch.object(Messages, "records", side_effect=AssertionError("No I/O in status tick")):
            for _ in range(20):
                interaction.tick()
            self.assertIn("Сообщений в очереди: 1", terminal.panel.lines[-1])
            self.state["iteration"] = 2
            interaction.tick()
            self.assertNotIn("Сообщений в очереди", terminal.panel.lines[-1])
            progress.finish()
            self.assertNotIn("Fable", terminal.panel.lines[1])
            interaction.unbind()
            self.assertIn("ПАУЗА", terminal.panel.lines[1])

    def test_external_status_does_not_call_stale_provider_active(self):
        control = Control(self.store)
        control.begin()
        progress = {"run_nonce": control.active["nonce"], "updated": time.time() - 60,
                    "role": "astra", "active": True}
        self.store.artifact("progress.json", encode(progress))
        with patch("focus_control.runtime_active", return_value=True):
            current = status(self.store, self.state)
        self.assertTrue(current["progress"]["stale"])
        self.assertNotIn("Ревью Astra", "\n".join(current["dashboard"]))


class PanelRenderingTests(unittest.TestCase):
    def panel(self, **kwargs):
        state = {"root": "/tmp/Project", "phase": "astra", "iteration": 1, "astra_clean": 1,
                 "claude_clean": 0, "display_reviews": new_reviews()}
        state.update(kwargs)
        return build_panel(state, {"role": "astra", "active": True})

    def test_full_compact_and_resize_preserve_input_and_log_space(self):
        terminal = Terminal(stdout=io.StringIO())
        terminal.status(self.panel())
        terminal.write("Some output\n")
        terminal.key("Ж")
        for columns, rows in ((110, 24), (60, 14), (80, 8), (25, 6), (10, 4), (120, 32)):
            with self.subTest(columns=columns, rows=rows):
                terminal.render(columns, rows)
                self.assertEqual(len(terminal.frame_rows), rows)
                self.assertIn("Ж", terminal.frame_rows[-1])
                self.assertTrue(all(sum(cell_width(c) for c in line) < columns for line in terminal.frame_rows))
                self.assertEqual(terminal.render(columns, rows), "")
        terminal.render(110, 24)
        self.assertIn("Astra:", terminal.frame_rows[3])
        self.assertEqual(terminal.frame_rows[6], "─" * 109)
        terminal.render(60, 14)
        self.assertIn("Astra 1/3", terminal.frame_rows[1])
        self.assertIn("Claude 0/2", terminal.frame_rows[1])

    def test_typing_with_full_panel_does_not_revisit_long_scrollback(self):
        terminal = Terminal(stdout=io.StringIO())
        terminal.status(self.panel())
        terminal.write("".join(f"{index} " + "x" * 150 + "\n" for index in range(6000)))
        terminal.scroll = 1000000
        terminal.render(110, 30)
        with patch.object(terminal, "wrap_line", side_effect=AssertionError("Typing scanned history")):
            for char in "Проверить восстановление":
                terminal.key(char)
                frame = terminal.render(110, 30)
                self.assertIn("\x1b[30;1H> ", frame)
                self.assertEqual(frame.count("\x1b[K"), 1)
                self.assertNotIn("\x1b[2J", frame)

    def test_unicode_controls_truncation_and_tone_changes(self):
        terminal = Terminal(stdout=io.StringIO())
        dirty = "Задача 界é\x1b[2J\x1b]0;bad\x07\n\t" + "a" * 500
        panel = StatusPanel((dirty,) * 6, (dirty,) * 3)
        terminal.status(panel)
        terminal.render(80, 16)
        self.assertTrue(terminal.frame_rows[0].endswith("…"))
        self.assertNotIn("\x1b", "".join(terminal.frame_rows))
        self.assertNotIn("\t", "".join(terminal.frame_rows))
        terminal.status(StatusPanel(panel.lines, panel.compact, "error"))
        frame = terminal.render(80, 16)
        self.assertIn("\x1b[31m", frame)
        self.assertEqual(terminal.render(80, 16), "")


if __name__ == "__main__":
    unittest.main()
