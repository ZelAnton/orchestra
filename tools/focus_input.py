"""Connect the terminal to one workflow owner and durable provider deliveries."""

import json
import queue
import threading
import time

from cycle_state import Blocked
from focus_messages import MessagePending, Messages
from focus_status import build_panel, reset_notice


HELP = """Text: save an instruction for the active invocation (not a shell command).
/pause: finish this invocation, then pause; publication includes CI.
/stop: interrupt now; partial work is preserved. Ctrl+C is equivalent.
/resume: continue from a stopped boundary; retry a preserved blocker.
/correct TEXT: while stopped, return this same stage to coding and fresh reviews.
/messages: list delivery states. /retry-message ID: explicitly resend uncertain input
(may repeat an already received instruction). /discard-message ID: abandon delivery.
/status: current state. /approve or /deny: answer the displayed approval only.
/exit: request a safe pause and close the terminal after ownership is released.
/help: this help. PageUp/PageDown: scrollback. Up/Down: input history.
Claude instructions wait for its current response before continuing the same role.
Codex instructions use active-turn steering. Accepted does not mean applied.
"""


class Interaction:
    def __init__(self, terminal):
        self.terminal = terminal
        self.interactive = getattr(terminal, "interactive", False)
        self.lock = threading.RLock()
        self.commands = queue.Queue()
        self.control = self.state = self.messages = self.target = None
        self.paused = True
        self.quit = False
        self.approval = None
        self.approval_answer = None
        self.action_pending = False
        self.progress = None
        self.message_states = {}
        self.message_notice = ""
        self.message_iteration = None
        terminal.callback = self.submit
        terminal.status_tick = self.tick

    def note(self, text):
        self.terminal.write("\ncc-focus: " + text + "\n")

    def bind(self, control, state, save):
        with self.lock:
            self.control, self.state, self.save = control, state, save
            self.messages = Messages(control.store)
            self.paused = False
        self.refresh_messages()
        self.tick()

    def refresh_messages(self):
        try:
            records = self.messages.records(self.state["iteration"]) if self.messages and self.state else []
            states = {item["identity"]["id"]: item["status"] for item in records}
        except (Blocked, OSError, ValueError):
            states = {}
        with self.lock:
            self.message_iteration = self.state["iteration"] if self.state else None
            self.message_states = states
            self.update_message_notice()

    def update_message_notice(self, record=None):
        if record:
            self.message_states[record["identity"]["id"]] = record["status"]
        counts = {name: sum(value == name for value in self.message_states.values())
                  for name in ("queued", "sending", "rejected")}
        self.message_notice = ""
        if counts["sending"] or counts["rejected"]:
            self.message_notice = f"Доставка требует проверки: {counts['sending'] + counts['rejected']} · /messages"
        elif counts["queued"]:
            self.message_notice = f"Сообщений в очереди: {counts['queued']} · /messages"

    def unbind(self):
        with self.lock:
            self.target = None
            self.control = None
            self.paused = True
            self.approval = self.approval_answer = None
        self.tick()

    def begin(self, pending):
        with self.lock:
            records = self.messages.unresolved(self.state["iteration"])
            if any(item["identity"]["invocation"] != pending["id"] or item["status"] != "queued" for item in records):
                raise MessagePending("Unresolved message delivery. Use /messages, then /retry-message ID or /discard-message ID; no automatic resend.")
            if self.state.get("publication_started") or self.state.get("published") or pending["role"] == "publish":
                self.target = None
            else:
                self.target = {"iteration": self.state["iteration"], "invocation": pending["id"], "role": pending["role"]}
            self.pending = pending

    def close_target(self):
        with self.lock:
            self.target = None

    def finish(self):
        with self.lock:
            self.target = None
            if self.messages.unresolved(self.state["iteration"], self.pending["id"]):
                raise MessagePending("The invocation ended with undelivered input. /messages shows what remains; /resume retries queued input in this SAME invocation.")

    def submit(self, text):
        try:
            with self.lock:
                if not text.startswith("/"):
                    if self.approval:
                        raise ValueError("An approval is pending. Use /approve or /deny; ordinary text is not approval.")
                    if not self.target:
                        raise ValueError("No writable active invocation. While stopped use /correct TEXT; publication/CI cannot be steered.")
                    record = self.messages.add(self.target, text)
                    self.update_message_notice(record)
                    self.note(f"You -> {self.target['role']}: {text}")
                    self.note(f"Message {record['identity']['id'][:12]} saved, queued for {self.target['role']} in this invocation.")
                    return
                command, _, argument = text.partition(" ")
                if command == "/help":
                    self.note(HELP)
                elif command in ("/approve", "/deny"):
                    if not self.approval or argument:
                        raise ValueError("There is no displayed approval to answer, or the command has extra arguments.")
                    self.approval_answer = command == "/approve"
                elif command == "/messages":
                    self.show_messages()
                elif command in ("/pause", "/stop", "/exit") and not argument:
                    if command == "/exit":
                        self.quit = True
                    if self.control:
                        self.control.submit_stop(now=command == "/stop")
                        self.note("Stop requested; waiting for contained cleanup." if command == "/stop"
                                  else "Safe pause requested; waiting for the boundary (publication includes CI).")
                    elif command != "/exit":
                        self.note("Already stopped; use /resume.")
                elif command in ("/resume", "/correct", "/retry-message", "/discard-message"):
                    if not self.paused:
                        raise ValueError("Wait for /pause or /stop to finish before using this command.")
                    if command != "/resume" and not argument.strip():
                        raise ValueError("This command requires text or a message ID.")
                    if command == "/resume" and argument:
                        raise ValueError("/resume takes no arguments.")
                    if self.action_pending:
                        raise ValueError("A stopped-state command is already pending; wait for its result.")
                    self.action_pending = True
                    self.commands.put((command, argument, True))
                elif command == "/status" and not argument:
                    if self.state:
                        self.note("\n".join(self.panel().lines))
                        self.note(json.dumps({"task": self.state.get("task"),
                                             "review_events": self.state.get("display_review_events", [])}, ensure_ascii=False, indent=2))
                else:
                    raise ValueError("Unknown command or unexpected arguments. Use /help. Shell commands are not executed here.")
        except (Blocked, OSError, ValueError) as error:
            self.note(str(error))

    def show_messages(self):
        records = self.messages.records(self.state["iteration"]) if self.messages else []
        self.note("\n".join(f"{item['identity']['id'][:12]} {item['status']} role={item['identity']['role']} "
                            f"invocation={item['identity']['invocation']}" for item in records) or "No messages in this stage.")

    def panel(self):
        if self.message_iteration != self.state.get("iteration"):
            self.message_iteration = self.state.get("iteration")
            self.message_states = {}
            self.message_notice = ""
        live = self.progress.view() if self.progress else {}
        stop = (self.control.announced if self.control else "") or ("safe" if self.quit and not self.paused else "")
        return build_panel(self.state, live, paused=self.paused, approval=bool(self.approval),
                           notice=self.message_notice, stop=stop)

    def tick(self):
        if self.state:
            with self.lock:
                self.terminal.status(self.panel())

    def take(self):
        with self.lock:
            if not self.target:
                return None
            records = self.messages.unresolved(self.target["iteration"], self.target["invocation"])
            if not records or any(item["status"] != "queued" for item in records):
                return None
            record = records[0]
            role = self.target["role"]
            # Earlier passes cannot certify a scope that changed during this pass.
            if role in ("sol", "claude", "astra"):
                reset_notice(self.state, "Новое указание для ревью")
                self.state.update(sol_clean=0, claude_clean=0, astra_clean=0, reviewed=None)
                if role in ("claude", "astra"):
                    self.pending["return_to_sol"] = True
            self.pending["operator_intervened"] = True
            self.save(self.state)
            record = self.messages.update(record, "sending")
            self.update_message_notice(record)
            self.note(f"Message {record['identity']['id'][:12]} sending to {role}.")
            return record

    def ack(self, record, accepted, detail=""):
        with self.lock:
            saved = self.messages.update(record, "accepted" if accepted else "rejected", detail)
            self.update_message_notice(saved)
            self.note(f"Message {record['identity']['id'][:12]} {'accepted by provider (not proof of application)' if accepted else 'rejected; /messages shows the pending delivery'}. {saved['detail']}")

    def approve(self, params, heartbeat):
        with self.lock:
            self.approval, self.approval_answer = params, None
            self.note("Codex requests this one operation:\n" + json.dumps(params, ensure_ascii=False, indent=2)
                      + "\nUse /approve or /deny. Text is never treated as consent.")
        try:
            while True:
                heartbeat()
                with self.lock:
                    if self.approval_answer is not None:
                        return self.approval_answer
                    # A safe pause cannot wait indefinitely for an unapproved operation.
                    if self.control.request():
                        return False
                time.sleep(0.05)
        finally:
            with self.lock:
                self.approval = self.approval_answer = None

    def wait_action(self):
        from focus_control import read_json, runtime_active
        active = read_json(self.messages.store.directory / "active.json") if self.messages else None
        if self.messages and (runtime_active(self.messages.store) or (active or {}).get("provider_run")):
            self.note("Processing returned but provider exit or ownership release is unconfirmed. Use cc-focus status or cc-focus stop --now in another terminal.")
        else:
            self.note("Processing stopped; runtime ownership released. Use /resume, /correct TEXT, /messages or /exit.")
        while not self.quit:
            try:
                command, argument, stopped = self.commands.get(timeout=0.1)
            except queue.Empty:
                continue
            if stopped and command in ("/resume", "/correct", "/retry-message", "/discard-message"):
                with self.lock:
                    self.action_pending = False
                return command, argument
        return "/exit", ""


class PlainTerminal:
    """Delivery recovery without an interactive composer or hidden input reader."""
    interactive = False

    def write(self, text):
        print(text, end="", flush=True)

    def status(self, text):
        pass
