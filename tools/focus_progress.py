"""Compact activity state plus optional live public output; never reasoning."""

import time
import unicodedata

from cycle_prompts import PROFILES
from cycle_state import encode
from focus_output import LiveOutput


def safe_text(value, limit=180):
    return " ".join("".join(c if not unicodedata.category(c).startswith("C") else " "
                            for c in str(value)).split())[:limit]


class Progress:
    def __init__(self, store, state, run_nonce=None, live=False):
        self.store, self.state, self.run_nonce = store, state, run_nonce
        self.started = time.monotonic()
        self.last_event = self.started
        self.last_print = self.started
        self.last_write = 0
        self.activity = "starting runtime"
        self.role = None
        self.events = 0
        self.report = None
        self.live = live
        self.output = None
        self.active = False
        self.operation = None
        self.elapsed = 0
        self.on_update = None

    def view(self):
        now = time.monotonic()
        return {"role": self.role, "active": self.active, "operation": self.operation,
                "activity": self.activity, "elapsed_seconds": int(now - self.started) if self.active or self.operation else self.elapsed,
                "event_age_seconds": int(now - self.last_event)}

    def finish(self):
        self.elapsed = int(time.monotonic() - self.started)
        self.active, self.operation = False, None
        if self.on_update:
            self.on_update()

    def runtime(self, operation):
        self.role, self.active, self.operation = None, False, operation
        self.started = self.last_event = time.monotonic()
        if self.on_update:
            self.on_update()

    def line(self, message):
        if self.output:
            self.output.boundary()
        print(time.strftime("[%H:%M:%S] ", time.gmtime()) + "cc-focus: " + safe_text(message, 500), flush=True)
        self.last_print = time.monotonic()

    def start(self, role, directory):
        if self.output:
            self.output.boundary()
        self.output = LiveOutput(role) if self.live else None
        self.role, self.report = role, str(directory / "result.json")
        self.active, self.operation = True, None
        self.started = self.last_event = time.monotonic()
        self.events, self.activity = 0, "starting provider / restoring session"
        provider, model, effort = PROFILES[role]
        review = ""
        if role in ("astra", "claude"):
            review = f" clean={self.state[role + '_clean']}/{'3' if role == 'astra' else '2'}"
            if role == "astra":
                review += f" pass={self.state['astra_passes'] + 1}"
        self.line(f"iteration={self.state['iteration']} phase={self.state['phase']} role={role} {provider}/{model} effort={effort}{review}")
        self.line(f"Protocol: {directory / 'protocol.jsonl'}; stop safely: cc-focus stop; emergency: cc-focus stop --now")
        self.pulse(force=True)

    def stderr(self, text):
        if self.output:
            self.output.feed("stderr", "stderr", text)

    def result(self, report):
        self.finish()
        if self.output:
            self.output.report(report)

    def note(self, message):
        self.activity = safe_text(message)
        self.line(self.activity)
        self.pulse(force=True)

    def pulse(self, force=False):
        now = time.monotonic()
        if self.on_update:
            self.on_update()
        if now - self.last_print >= 15:
            self.line(f"{self.role or self.state['phase']} active {int(now-self.started)}s; {self.activity}; last event {int(now-self.last_event)}s ago; events={self.events}")
        if force or now - self.last_write >= 2:
            self.store.artifact("progress.json", encode({"run_nonce": self.run_nonce, "updated": time.time(),
                "phase": self.state["phase"], "iteration": self.state["iteration"], "role": self.role,
                "profile": PROFILES.get(self.role), "elapsed_seconds": int(now-self.started),
                "event_age_seconds": int(now-self.last_event), "events": self.events,
                "activity": self.activity, "report": self.report, "coordination": self.state.get("coordination"),
                **self.view()}))
            self.last_write = now

    def event(self, event):
        if not isinstance(event, dict):
            return
        if self.output:
            try:
                self.output.event(event)
            except (AttributeError, KeyError, TypeError, ValueError):
                self.line("Unrecognized display event; original retained in protocol.jsonl.")
        self.events += 1
        self.last_event = time.monotonic()
        try:
            self.activity_event(event)
        except (AttributeError, KeyError, TypeError, ValueError):
            self.line("Unrecognized activity event; original retained in protocol.jsonl.")
        self.pulse()

    def activity_event(self, event):
        activity = None
        method, params = event.get("method", ""), event.get("params", {})
        if method in ("item/started", "item/completed"):
            item = params.get("item", {})
            kind = item.get("type")
            labels = {"commandExecution": "command", "fileChange": "file edit", "mcpToolCall": "tool",
                      "webSearch": "web search", "reasoning": "model processing", "agentMessage": "response"}
            if kind in labels:
                activity = labels[kind] + (" completed" if method.endswith("completed") else " running")
                if kind == "commandExecution" and item.get("exitCode") is not None:
                    activity += f" (exit {item['exitCode']})"
        elif method == "turn/plan/updated":
            plan = params.get("plan", [])
            current = next((p.get("step") for p in plan if p.get("status") == "inProgress"), None)
            if current:
                activity = "plan: " + safe_text(current)
        elif method.endswith("/requestApproval") or method.endswith("/requestUserInput"):
            activity = "waiting for operator input (no automatic approval)"
        elif method == "turn/started":
            activity = "model turn started"
        elif method == "turn/completed":
            activity = "model turn " + params.get("turn", {}).get("status", "finished")
        elif event.get("type") == "system" and event.get("subtype") == "init":
            activity = "session ready"
        elif event.get("type") == "tool_progress":
            activity = "tool running: " + safe_text(event.get("tool_name", "tool"), 60)
        elif event.get("type") == "user":
            if any(block.get("type") == "tool_result" for block in event.get("message", {}).get("content", []) if isinstance(block, dict)):
                activity = "tool result received"
        elif event.get("type") == "assistant":
            for block in event.get("message", {}).get("content", []):
                if block.get("type") == "tool_use":
                    activity = "tool running: " + safe_text(block.get("name", "tool"), 60)
                    path = block.get("input", {}).get("file_path")
                    if path:
                        activity += " " + safe_text(path, 100)
                elif block.get("type") == "thinking" and not activity:
                    activity = "model processing (reasoning content hidden)"
        elif event.get("type") == "stream_event":
            stream = event.get("event", {})
            block = stream.get("content_block", {})
            if stream.get("type") == "content_block_start":
                activity = {"thinking": "model processing (reasoning content hidden)",
                            "text": "composing response", "tool_use": "preparing tool call"}.get(block.get("type"))
        elif event.get("type") == "result":
            activity = "response received; checking completion"
        elif event.get("type") == "system" and event.get("subtype") == "compact_boundary":
            activity = "conversation compacted; continuing current stage"
        if activity and safe_text(activity) != self.activity:
            self.activity = safe_text(activity)
            if time.monotonic() - self.last_print >= 1:
                self.line(self.activity)
