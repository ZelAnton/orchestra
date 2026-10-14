"""Serial CLI transports. Codex approvals are answered only by the operator."""

from collections import deque
import json
import os
from pathlib import Path
import queue
import re
import signal
import shutil
import subprocess
import sys
import threading
import time
import uuid

from cycle_prompts import CONTRACT, PAIR_CONTRACT, PROFILES, REPORT_SCHEMA, READONLY_REVIEW_ROLES, role_contract
from focus_pair_profile import PAIR_ROLES, PAIR_READONLY, PAIR_WRITERS
from focus_pair_view import ViewInspector
from focus_review import report_schema, validate_findings
from focus_readonly import Inspector, READ_TOOL, READONLY_FEATURE_OVERRIDES
from cycle_state import Blocked, ProviderQuota, ProviderTransient, atomic_write, digest, encode
from focus_messages import MessagePending, message_text
from focus_diagnostics import ClaudeTrace, instruction_files


def claude_refusal(event):
    """Describe a structured refusal after the caller validates its source."""
    message = event["message"]
    details = message.get("stop_details")
    details = details if isinstance(details, dict) else {}
    category = details.get("category")
    category = category[:120] if isinstance(category, str) and category else "unspecified"
    explanation = details.get("explanation")
    explanation = explanation[:2000] if isinstance(explanation, str) else ""
    text = " ".join(block["text"] for block in (message.get("content") or [])
                    if isinstance(block, dict) and block.get("type") == "text"
                    and isinstance(block.get("text"), str))[:2000]
    identifiers = []
    for label, value in (("Request ID", event.get("request_id")), ("Response message ID", message.get("id"))):
        if isinstance(value, str) and value:
            identifiers.append(f"{label}: {value[:200]}")
    guidance = ("Check the request, instructions, and tool schemas for requests to disclose private reasoning. "
                "Use short explanations and observable evidence instead. "
                if category == "reasoning_extraction" else "Inspect the request and the provider's refusal guidance. ")
    return Blocked("claude-refusal", f"Claude refused the request ({category}). {explanation}\n{text}\n" +
                   "\n".join(identifiers) + "\n" + guidance +
                   "Contact provider support if a permitted request still appears to be misclassified. "
                   "The runtime will not retry automatically or change the model or session. "
                   "Existing work is preserved. This invocation is incomplete; no review credit is granted.")


class WindowsJob:
    """A per-invocation job; closing it terminates descendant processes as well."""
    def __init__(self, process):
        import ctypes
        from ctypes import wintypes as w
        self.ctypes = ctypes
        self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)

        class Basic(ctypes.Structure):
            _fields_ = [("ProcessTime", ctypes.c_int64), ("JobTime", ctypes.c_int64),
                        ("Flags", w.DWORD), ("MinWorkingSet", ctypes.c_size_t),
                        ("MaxWorkingSet", ctypes.c_size_t), ("ActiveProcesses", w.DWORD),
                        ("Affinity", ctypes.c_size_t), ("Priority", w.DWORD), ("Scheduling", w.DWORD)]

        class Io(ctypes.Structure):
            _fields_ = [(name, ctypes.c_uint64) for name in
                        ("ReadOps", "WriteOps", "OtherOps", "ReadBytes", "WriteBytes", "OtherBytes")]

        class Extended(ctypes.Structure):
            _fields_ = [("Basic", Basic), ("Io", Io), ("ProcessMemory", ctypes.c_size_t),
                        ("JobMemory", ctypes.c_size_t), ("PeakProcess", ctypes.c_size_t),
                        ("PeakJob", ctypes.c_size_t)]

        self.kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, w.LPCWSTR]
        self.kernel.CreateJobObjectW.restype = w.HANDLE
        self.kernel.SetInformationJobObject.argtypes = [w.HANDLE, ctypes.c_int, ctypes.c_void_p, w.DWORD]
        self.kernel.AssignProcessToJobObject.argtypes = [w.HANDLE, w.HANDLE]
        self.kernel.CloseHandle.argtypes = [w.HANDLE]
        self.handle = self.kernel.CreateJobObjectW(None, None)
        limits = Extended()
        limits.Basic.Flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        if (not self.handle or not self.kernel.SetInformationJobObject(
                self.handle, 9, ctypes.byref(limits), ctypes.sizeof(limits))
                or not self.kernel.AssignProcessToJobObject(self.handle, w.HANDLE(int(process._handle)))):
            if self.handle:
                self.kernel.CloseHandle(self.handle)
            raise Blocked("containment-failed", "Cannot contain the provider in a Windows Job Object.")

    def close(self):
        self.kernel.CloseHandle(self.handle)


class Process:
    def __init__(self, argv, root, log, heartbeat, lock_fd=None, env=None, deadline=21600, progress=None, control=None):
        resolved = shutil.which(argv[0])
        if os.name == "nt" and resolved and Path(resolved).suffix.lower() in (".cmd", ".bat"):
            raise Blocked("native-cli-required", "cc-focus needs the native provider executable on Windows, not a batch shim.")
        self.heartbeat, self.deadline = heartbeat, time.monotonic() + deadline
        self.progress = progress
        self.on_poll = None
        self.control = control
        prefix = control.prepare_provider(log) if control else None
        self.contained = bool(prefix)
        if prefix:
            argv = prefix + argv
        self.events = queue.Queue()
        self.job = None
        self.stderr_tail = ""
        log_fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        self.log = os.fdopen(log_fd, "ab")
        kwargs = {"cwd": root, "stdin": subprocess.PIPE, "stdout": subprocess.PIPE,
                  "stderr": subprocess.PIPE, "env": env, "bufsize": 0}
        if os.name != "nt":
            lock_fds = () if lock_fd is None else tuple(lock_fd) if isinstance(lock_fd, (tuple, list)) else (lock_fd,)
            kwargs.update(start_new_session=True, pass_fds=lock_fds)
        try:
            self.proc = subprocess.Popen(argv, **kwargs)
            if os.name == "nt":
                self.job = WindowsJob(self.proc)
        except (OSError, Blocked):
            if hasattr(self, "proc"):
                self.proc.kill()
                self.proc.wait()
            elif self.contained:
                # Popen failed before any process existed. Leaving its prepared
                # address would permanently block a parked UI on a nonexistent run.
                self.control.clear_provider()
            self.log.close()
            raise
        self.readers = []
        for label, pipe in (("stdout", self.proc.stdout), ("stderr", self.proc.stderr)):
            reader = threading.Thread(target=self._read, args=(label, pipe), daemon=True)
            reader.start()
            self.readers.append(reader)

    def _read(self, label, pipe):
        try:
            while True:
                line = pipe.readline(8 * 1024 * 1024 + 1)
                if not line:
                    break
                self.events.put((label, line))
        finally:
            self.events.put((label, None))

    def send(self, data):
        try:
            remaining = memoryview(data)
            while remaining:
                written = self.proc.stdin.write(remaining)
                if not written:
                    raise OSError("Provider input made no progress")
                remaining = remaining[written:]
            self.proc.stdin.flush()
        except (OSError, ValueError) as error:
            raise Blocked("provider-disconnected", "Provider stdin closed before the request was accepted.") from error

    def receive(self):
        while True:
            self.heartbeat()
            if self.on_poll:
                self.on_poll()
            if time.monotonic() >= self.deadline:
                raise Blocked("provider-timeout", "Provider exceeded the six-hour invocation deadline; work is preserved.")
            try:
                label, line = self.events.get(timeout=1)
            except queue.Empty:
                continue
            if line is None:
                if label == "stdout":
                    raise Blocked("provider-eof", "Provider closed stdout without a validated terminal result. " + self.stderr_tail)
                continue
            if len(line) > 8 * 1024 * 1024:
                raise Blocked("provider-output", "Provider emitted an oversized protocol record.")
            self.log.write(encode({"stream": label, "line": line.decode("utf-8", errors="replace")}) + b"\n")
            self.log.flush()
            if label == "stderr":
                self.stderr_tail = (self.stderr_tail + line.decode("utf-8", errors="replace"))[-4000:]
                if self.progress:
                    self.progress.stderr(line.decode("utf-8", errors="replace"))
                continue
            try:
                event = json.loads(line)
                if self.progress:
                    self.progress.event(event)
                return event
            except (ValueError, UnicodeError) as error:
                raise Blocked("provider-protocol", "Expected a JSON protocol record; inspect the invocation log.") from error

    def close(self):
        try:
            try:
                self.proc.stdin.close()
            except OSError:
                pass
            # EOF is the stdio server's normal shutdown path. Allow it to flush
            # conversation persistence before enforcing descendant cleanup.
            if sys.exc_info()[0] is None:
                try:
                    self.proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    pass
            if self.contained and self.proc.poll() is None:
                from focus_control import kill_provider
                cleanup_deadline = time.monotonic() + 15
                try:
                    while self.proc.poll() is None:
                        if kill_provider(self.control.store, self.control.active, timeout=5):
                            break
                        if time.monotonic() >= cleanup_deadline:
                            raise Blocked("cleanup-incomplete", "Provider container exit is unconfirmed; no further model may start.")
                        time.sleep(0.1)
                except Blocked as error:
                    raise Blocked("cleanup-incomplete", f"Provider containment cleanup failed: {error}") from error
            if os.name == "nt":
                self.job.close()
            else:
                try:
                    os.killpg(self.proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
            if os.name != "nt":
                try:
                    os.killpg(self.proc.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            for reader in self.readers:
                reader.join(timeout=5)
            if any(reader.is_alive() for reader in self.readers):
                raise Blocked("cleanup-incomplete", "Provider descendants still hold protocol pipes; refusing another step.")
            # Include trailing diagnostics queued after the terminal protocol frame.
            while not self.events.empty():
                label, line = self.events.get_nowait()
                if line is not None:
                    self.log.write(encode({"stream": label, "line": line.decode("utf-8", errors="replace")}) + b"\n")
                    if label == "stderr" and self.progress:
                        self.progress.stderr(line.decode("utf-8", errors="replace"))
            if self.contained:
                self.control.clear_provider()
        finally:
            if self.progress and self.progress.output:
                self.progress.output.boundary()
            for pipe in (self.proc.stdout, self.proc.stderr):
                pipe.close()
            self.log.close()


def report_object(raw):
    """Unwrap one final object without searching past malformed/ambiguous JSON."""
    if not isinstance(raw, str):
        raise TypeError("expected report text")
    body = raw.strip()
    start = body.find("{")
    prefix = body[:start] if start >= 0 else body
    fenced = False
    if prefix:
        # An object must start on its own line after prose. Never extract a
        # nested report, skip an earlier object, or interpret JSON in a quote.
        if start < 0 or "\n" not in prefix or prefix.rsplit("\n", 1)[1].strip():
            raise ValueError("expected one final JSON object")
        prose = prefix.rstrip()
        if prose.splitlines()[-1] in ("```", "```json"):
            fenced = True
            prose = prose.rsplit("\n", 1)[0] if "\n" in prose else ""
        if any(char in prose for char in "{}[]") or "```" in prose:
            raise ValueError("ambiguous report preamble")
        body = body[start:]
    if fenced:
        lines = body.rsplit("\n", 1)
        if len(lines) != 2 or lines[1].strip() != "```":
            raise ValueError("unclosed report fence")
        body = lines[0]

    def unique_fields(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("duplicate report field")
            result[key] = value
        return result

    report = json.loads(body, object_pairs_hook=unique_fields)
    if not isinstance(report, dict):
        raise ValueError("expected one final JSON object")
    return report


def parse_report(raw, role=None):
    try:
        report = report_object(raw)
        schema = report_schema(role)
        required = set(schema["required"]) - {"task"}
        if not required <= set(report) or set(report) - set(schema["properties"]):
            raise ValueError("missing or unknown report fields")
        if report["status"] not in ("done", "blocked", "complete"):
            raise ValueError("invalid status")
        for field in ("summary", "description"):
            if not isinstance(report[field], str) or not report[field].strip():
                raise ValueError(f"invalid {field}")
        for field in ("implementation_fixes", "other_fixes", "minor_edits"):
            if type(report[field]) is not int or report[field] < 0:
                raise ValueError(f"invalid {field}")
        if type(report["substantial"]) is not bool:
            raise ValueError("invalid substantial flag")
        if not isinstance(report["evidence"], list) or any(not isinstance(x, str) or not x.strip() for x in report["evidence"]):
            raise ValueError("invalid evidence")
        # Coding may create substantial new implementation without fixing any
        # review defects. Keep the consistency check for all other role reports.
        if role != "code" and report["substantial"] and not report["implementation_fixes"]:
            raise ValueError("substantial requires implementation fixes")
        validate_findings(report, role)
        return report
    except (ValueError, TypeError, KeyError) as error:
        raise Blocked("invalid-report", f"Provider final report is invalid: {error}") from error


def repairable_executor_accounting(raw, role, before, after):
    """Recognize, never accept, an unchanged executor's cumulative-impact mistake."""
    if role not in PAIR_WRITERS or before != after:
        return None
    try:
        original = report_object(raw)
        if (original.get("status") != "done" or original.get("substantial") is not True
                or any(type(original.get(k)) is not int or original[k] != 0
                       for k in ("implementation_fixes", "other_fixes", "minor_edits"))):
            return None
        # The strict parser must accept every other field. This in-memory probe
        # grants no closure; the original session must issue a corrected report.
        parse_report(json.dumps(dict(original, substantial=False)), role)
        return original
    except (ValueError, TypeError, KeyError, Blocked):
        return None


def repairable_substantial_accounting(raw, role):
    """Recognize, never accept, an executor's substantial=true without implementation fixes."""
    if role not in PAIR_WRITERS:
        return None  # Other roles keep the blocker, the healer and their own guards.
    try:
        original = report_object(raw)
        # A blocked report stops the cycle anyway; a counter correction would only delay it.
        if (original.get("status") != "done" or original.get("substantial") is not True
                or type(original.get("implementation_fixes")) is not int or original["implementation_fixes"] != 0):
            return None
        # Every other field must already be valid; only the classification is inconsistent.
        parse_report(json.dumps(dict(original, substantial=False)), role)
        return original
    except (ValueError, TypeError, KeyError, Blocked):
        return None


def concise_summary(summary):
    """Bound the coordinator/display projection without changing report evidence."""
    limit = 1200
    suffix = "... [summary shortened; full report saved]"
    if len(summary) <= limit:
        return summary
    return summary[:limit - len(suffix)].rstrip() + suffix


class Transport:
    def __init__(self, root, state, save, heartbeat, lock_fd=None, codex="codex", claude="claude", progress=None, control=None, interaction=None):
        self.root, self.state, self.save = Path(root), state, save
        self.heartbeat, self.lock_fd = heartbeat, lock_fd
        self.progress = progress
        self.control = control
        self.interaction = interaction
        self.commands = {"codex": [codex], "claude": [claude]}

    def fork(self, root, state, save, heartbeat, control=None, progress=None):
        child = Transport(root, state, save, heartbeat, self.lock_fd,
                          progress=progress, control=control)
        child.commands = dict(self.commands)
        return child

    def run(self, role, prompt, pending, directory):
        if self.interaction:
            self.interaction.begin(pending)
        try:
            raw = self._run(role, prompt, pending, directory)
            if self.interaction:
                self.interaction.finish()
            return raw
        finally:
            if self.interaction:
                self.interaction.close_target()
            if self.progress:
                self.progress.finish()

    def _run(self, role, prompt, pending, directory):
        provider, model, effort = PROFILES[role]
        session = self.state["sessions"].get(role)
        prompt += "\n\n" + role_contract(role) + "\nReport schema: " + json.dumps(report_schema(role))
        # Keep the durable marker compatible with conversations started as cc-cycle.
        prompt += "\nInvocation marker: cc-cycle/" + pending["id"]
        if pending.get("report_repair"):
            prompt += ("\nThis invocation is REPORT-ONLY CORRECTION. Keep all working files and staging unchanged. Do not repeat review, builds, or tests, including after an interruption. Correct only the original review's final JSON with existing evidence.")
        elif pending.get("attempts", 0):
            prompt += ("\nRECOVERY: the previous attempt of THIS SAME invocation was interrupted. Do not select the next stage or repeat a completed commit/push. Inspect retained files and public command results. If possible, reconstruct the prior stage and result. Finish ONLY that same work. Repeat an incomplete review as one complete pass.")
        prompt += ("\nUse saved reports and public command results for recovery. "
                   "Do not read raw provider transcripts or private content blocks. "
                   "For provider metadata, run `cc-focus diagnose --invocation INVOCATION_ID`. "
                   "Add `--public-output` to read public messages, tool calls, and results. "
                   "Replace INVOCATION_ID with the interrupted invocation ID. "
                   "These commands do not start a provider or change cycle state. "
                   "\n\nRead-only inspectors must use only their assigned inspection tools.")
        pending["attempts"] = pending.get("attempts", 0) + 1
        self.save(self.state)
        atomic_write(Path(directory) / "prompt.txt", prompt.encode("utf-8"))
        try:
            if provider == "claude":
                try:
                    return self._claude(role, model, effort, session, prompt, pending, directory)
                except Blocked as error:
                    if error.code != "claude-session-missing":
                        if error.code == "claude-refusal":
                            raise Blocked(error.code, f"{error}\nInspect public metadata: cc-focus diagnose --invocation {Path(directory).name}") from error
                        raise
                    self.state.setdefault("session_recoveries", []).append({"role": role, "missing": session,
                                                                           "invocation": pending["id"]})
                    self.state["sessions"].pop(role, None)
                    self.save(self.state)
                    print(f"cc-focus: {role} native history is missing; continuing the same phase from durable context.", flush=True)
                    prompt += ('\nThe prior native conversation is unavailable. This is a new conversation for the SAME runtime phase. Reconstruct context from handoffs and invocation artifacts. Keep existing work. Do not discard it. Do not advance to another stage.')
                    atomic_write(Path(directory) / "prompt.txt", prompt.encode("utf-8"))
                    return self._claude(role, model, effort, None, prompt, pending, directory)
            return self._codex(role, model, effort, session, prompt, pending, directory)
        except (OSError, ValueError, KeyError, TypeError, StopIteration) as error:
            raise Blocked("provider-protocol", f"{provider}: {error}") from error

    def mark_attempt(self, directory, role, session, resumed):
        """Mark where a Claude process starts in the shared protocol log.

        A retry can reuse the invocation directory and append another
        conversation. Diagnostics split the log at these records.
        """
        attempt = uuid.uuid4().hex
        record = {"type": "attempt", "attempt": attempt, "provider": "claude", "role": role,
                  "session_id": session, "resumed": resumed, "started": time.time(), "cwd": str(self.root)}
        try:
            descriptor = os.open(Path(directory) / "protocol.jsonl", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(descriptor, "ab") as log:
                log.write(encode({"stream": "runtime", "line": json.dumps(record)}) + b"\n")
        except OSError:
            return None  # The process log reports its own I/O failure.
        return attempt

    def instruction_snapshot(self, role):
        """Fingerprint candidate instruction files; a diagnostic failure never stops or masks a run."""
        try:
            return instruction_files(self.root, role not in PAIR_READONLY)
        except Exception:  # Diagnostics stay optional; the provider or containment result decides the run.
            return None

    def _claude(self, role, model, effort, session, prompt, pending, directory):
        resumed = bool(session)
        # A nonempty --agent prompt replaces Claude Code's standard instructions.
        # Writers need its coding/tool guidance plus the cycle's stricter contract.
        # An empty prompt without memory keeps the default (Claude Code 2.1.281+).
        preserve_default = role not in READONLY_REVIEW_ROLES
        # Enforce the serial profile in the CLI as well as the prompt. Its
        # default Bash timeout otherwise moves long tests to the background.
        command_env = {"CLAUDE_CODE_DISABLE_BACKGROUND_TASKS": "1",
                       "BASH_DEFAULT_TIMEOUT_MS": "1800000", "BASH_MAX_TIMEOUT_MS": "21600000"}
        argv = self.commands["claude"] + ["--permission-mode", "bypassPermissions", "--model", model,
                "--effort", effort, "--print", "--verbose", "--output-format", "stream-json", "--include-partial-messages",
                "--disallowedTools", "Agent,Task,TeamCreate,TeamDelete,Monitor,CronCreate,ScheduleWakeup,RemoteTrigger,Workflow",
                "--setting-sources", "user,project,local",
                "--settings", json.dumps({"effortLevel": effort, "disableAllHooks": True, "ultracode": False,
                                           "env": command_env}),
                "--agent", "cycle_worker", "--agents", json.dumps({"cycle_worker": {
                    "description": "Execute the current cycle invocation only.",
                    "prompt": "" if preserve_default else role_contract(role), "model": model}})]
        if preserve_default:
            argv += ["--append-system-prompt", role_contract(role)]
        if role in PAIR_READONLY:
            argv[argv.index("user,project,local")] = ""
            server = {"mcpServers": {"focus": {"command": sys.executable,
                "args": [str(Path(__file__).with_name("focus_pair_view.py")), self.state["inspection_path"]]}}}
            argv += ["--tools", "", "--strict-mcp-config", "--mcp-config", json.dumps(server),
                     "--allowedTools", "mcp__focus__inspect", "--disable-slash-commands"]
        elif role in READONLY_REVIEW_ROLES:
            argv += ["--tools", "Read,Glob,Grep", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                     "--disable-slash-commands"]
        if self.interaction:
            argv += ["--input-format", "stream-json", "--replay-user-messages"]
        if session:
            argv += ["--resume", session]
        else:
            session = str(uuid.uuid4())
            self.state["sessions"][role] = session
            self.save(self.state)
            argv += ["--session-id", session]
        env = dict(os.environ)
        env.update(command_env)
        env["CLAUDE_CODE_EFFORT_LEVEL"] = effort
        env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] = "0"
        # Hash the candidate files before Claude starts: an operator or the run itself can change them.
        # Paired inspectors start without user/project settings.
        launch_files = self.instruction_snapshot(role)
        diagnostic = ClaudeTrace()
        try:
            transport_digest = digest(Path(__file__).read_bytes())
        except OSError:
            transport_digest = None
        attempt = self.mark_attempt(directory, role, session, resumed)
        # No work may run between process creation and the try block that closes it.
        process = Process(argv, self.root, Path(directory) / "protocol.jsonl", self.heartbeat, self.lock_fd, env, progress=self.progress, control=self.control)
        try:
            def send_message(text, message_id):
                process.send(encode({"type": "user", "session_id": session, "uuid": message_id,
                                     "message": {"role": "user", "content": text}, "parent_tool_use_id": None}) + b"\n")
            if self.interaction:
                send_message(prompt, str(uuid.uuid4()))
            else:
                process.send(prompt.encode("utf-8"))
                process.proc.stdin.close()
            initialized = False
            resolved_model = None
            current_message = None
            earlier_reports = []
            active_tasks = set()
            deferred_reports = []
            quota_reset = None
            work_started = False
            sent_at = None
            def await_ack():
                if current_message and time.monotonic() - sent_at > 30:
                    raise MessagePending("Claude did not acknowledge the instruction within 30 seconds; explicitly retry or discard uncertain delivery.")
            process.on_poll = await_ack
            while True:
                event = process.receive()
                refusal = diagnostic.feed(event)
                if refusal and refusal["source"] == "message_delta":
                    if (not initialized or refusal["session_id"] != session
                            or refusal["message_session_id"] != session
                            or refusal["message_parent_tool_use_id"] is not None
                            or event.get("parent_tool_use_id") is not None):
                        raise Blocked("provider-profile", "Claude streamed refusal lacks the matching main session.")
                    answer_model = refusal["model"]
                    if model == "opus" and isinstance(answer_model, str):
                        answer_model = answer_model.removesuffix("[1m]")
                    if answer_model != resolved_model:
                        raise Blocked("model-rerouted", "Claude streamed refusal belongs to a different model.")
                    raise claude_refusal({"request_id": refusal["request_id"], "message": {
                        "id": refusal["message_id"], "stop_details": {
                            "category": refusal["category"], "explanation": refusal["explanation"]}}})
                if event.get("type") == "rate_limit_event":
                    if event.get("session_id") != session:
                        raise Blocked("provider-profile", "Claude quota event belongs to a different session.")
                    info = event.get("rate_limit_info")
                    reset = info.get("resetsAt") if isinstance(info, dict) else None
                    # Warning/allowed windows are telemetry, not refusal. Never
                    # infer a deadline from model prose or an overage setting.
                    quota_reset = (reset if isinstance(info, dict) and info.get("status") == "rejected"
                                   and type(reset) in (int, float) and 0 < reset <= 253402300799 else None)
                if (event.get("type") in ("stream_event", "tool_progress")
                        or event.get("type") == "system" and event.get("subtype") == "task_started"):
                    work_started = True
                if event.get("type") == "system" and event.get("subtype") in ("task_started", "task_notification"):
                    if event.get("session_id") != session:
                        raise Blocked("provider-profile", "Claude task event belongs to a different session.")
                    task_id = event.get("task_id")
                    if not isinstance(task_id, str) or not task_id:
                        raise Blocked("provider-protocol", "Claude task event lacks a task identifier.")
                    if event["subtype"] == "task_started":
                        active_tasks.add(task_id)
                    elif event.get("status") in ("completed", "failed", "stopped"):
                        active_tasks.discard(task_id)
                if event.get("type") == "system" and event.get("subtype") == "init":
                    if role in READONLY_REVIEW_ROLES and (
                            not isinstance(event.get("tools"), list)
                            or any(name not in (("mcp__focus__inspect",) if role in PAIR_READONLY else ("Read", "Glob", "Grep")) for name in event["tools"])):
                        raise Blocked("provider-profile", "Claude inspection exposed a tool outside the pinned read-only set.")
                    actual_model = event.get("model")
                    valid_model = (isinstance(actual_model, str) and bool(re.fullmatch(r"claude-opus-\d+(?:-\d+)*(?:\[1m\])?", actual_model))
                                   if model == "opus" else actual_model == model)
                    if (event.get("session_id") != session or not valid_model
                            or event.get("permissionMode") != "bypassPermissions"):
                        raise Blocked("provider-profile", "Claude session/model does not match the pinned profile.")
                    resolved = actual_model.removesuffix("[1m]") if model == "opus" else actual_model
                    if resolved_model is not None and resolved != resolved_model:
                        raise Blocked("model-rerouted", "Claude changed its resolved model during the invocation.")
                    resolved_model = resolved
                    if model == "opus":
                        if pending.get("resolved_model", resolved) != resolved:
                            raise Blocked("model-rerouted", "Claude changed the Opus model of an interrupted invocation.")
                        pending["resolved_model"] = resolved
                        self.save(self.state)
                    initialized = True
                if event.get("type") == "assistant":
                    message = event.get("message", {})
                    if message.get("model") == "<synthetic>" and event.get("is_api_error_message") is True:
                        # CLI-generated API refusals are not answers from a
                        # substituted model. Preserve the actual operator error.
                        if event.get("session_id") != session:
                            raise Blocked("provider-profile", "Claude API error belongs to a different session.")
                        if message.get("stop_reason") == "refusal":
                            raise claude_refusal(event)
                        code = event.get("error")
                        detail = " ".join(block["text"] for block in (message.get("content") or [])
                                          if isinstance(block, dict) and block.get("type") == "text"
                                          and isinstance(block.get("text"), str))
                        if code == "oauth_org_not_allowed":
                            raise Blocked("claude-access-denied", f"Claude rejected subscription access (oauth_org_not_allowed): {detail[:2000]} "
                                          "Check the active login and subscription/payment status on this machine. "
                                          "For managed access, ask the organization administrator; otherwise contact Anthropic support "
                                          "if access remains unavailable. Restore authorized access, then resume this same phase. "
                                          "This invocation did not complete; no review credit is granted.")
                        if code == "rate_limit" and quota_reset is not None:
                            raise ProviderQuota(quota_reset, no_work=not work_started)
                        if code in ("server_error", "overloaded_error"):
                            raise ProviderTransient(code, detail, no_work=not work_started)
                        raise Blocked("claude-api-error", f"Claude API error ({str(code)[:120]}): {detail[:2000]} "
                                      "Resolve the provider error, then resume this same phase; no review credit is granted.")
                    answer_model = message.get("model")
                    if model == "opus" and isinstance(answer_model, str):
                        answer_model = answer_model.removesuffix("[1m]")
                    if answer_model != (resolved_model if model == "opus" else model) or answer_model is None:
                        raise Blocked("model-rerouted", "Claude emitted an answer from a different model; refusing the result.")
                    if message.get("stop_reason") == "refusal":
                        if event.get("session_id") != session:
                            raise Blocked("provider-profile", "Claude refusal belongs to a different session.")
                        raise claude_refusal(event)
                    work_started = True
                if (current_message and event.get("type") == "user" and event.get("session_id") == session
                        and event.get("uuid") == str(uuid.UUID(current_message["identity"]["id"]))):
                    self.interaction.ack(current_message, True)
                    current_message = None
                if event.get("type") == "result":
                    if (resumed and not initialized and event.get("session_id") == session
                            and event.get("is_error") is True and event.get("num_turns") == 0
                            and event.get("subtype") == "error_during_execution"
                            and event.get("errors") == [f"No conversation found with session ID: {session}"]):
                        raise Blocked("claude-session-missing", "Claude has no native conversation for the saved identifier.")
                    if not initialized or event.get("session_id") != session:
                        raise Blocked("provider-profile", "Claude result lacks the matching initialization/session.")
                    if (event.get("is_error") is True and event.get("terminal_reason") == "api_error"
                            and event.get("api_error_status") == 429 and quota_reset is not None):
                        raise ProviderQuota(quota_reset, no_work=not work_started)
                    if (event.get("is_error") is True and event.get("terminal_reason") == "api_error"
                            and type(event.get("api_error_status")) is int
                            and event["api_error_status"] in (500, 502, 503, 504, 529)):
                        raise ProviderTransient(event["api_error_status"], str(event.get("errors") or event.get("result") or "Server failure"),
                                                no_work=not work_started)
                    if event.get("is_error") or event.get("subtype") != "success":
                        raise Blocked("claude-failed", str(event.get("errors") or event.get("result") or event)[-4000:])
                    raw = event.get("result", "")
                    work_started = True
                    if active_tasks or event.get("queued_turn_count", 0):
                        # Older conversations/CLI versions can yield a result
                        # while native tasks still own the turn. Keep reading
                        # completion events and the ensuing model response;
                        # neither close stdin nor dispatch operator input yet.
                        atomic_write(Path(directory) / f"deferred-{uuid.uuid4().hex}.txt", raw.encode("utf-8"))
                        try:
                            deferred_reports.append(parse_report(raw, role))
                        except Blocked:
                            pass  # A waiting message is not a review report.
                        if self.progress:
                            self.progress.note(f"Claude response deferred; waiting for native tasks ({len(active_tasks)}) and final report")
                        continue
                    if deferred_reports:
                        # Native continuation still accounts for the SAME
                        # response, unlike separately addressed operator input.
                        # Keep any reported fixes without counting them twice.
                        final = parse_report(raw, role)
                        reports = [*deferred_reports, final]
                        for field in ("implementation_fixes", "other_fixes", "minor_edits"):
                            final[field] = max(item[field] for item in reports)
                        final["substantial"] = any(item["substantial"] for item in reports)
                        final["description"] = "\n\n".join(item["description"] for item in reports)
                        final["evidence"] = list(dict.fromkeys(evidence for item in reports for evidence in item["evidence"]))
                        raw = json.dumps(final, ensure_ascii=False)
                        deferred_reports.clear()
                    if self.interaction:
                        if current_message:
                            raise MessagePending("Claude returned without acknowledging the operator message. Delivery is uncertain; explicitly retry or discard it.")
                        # Send one instruction only after the preceding response.
                        # Its acknowledgement and its own result must both arrive.
                        # This avoids treating an earlier result as completion of
                        # queued input and does not depend on undocumented batching.
                        with self.interaction.lock:
                            queued = self.interaction.messages.unresolved(self.state["iteration"], pending["id"])
                            if queued:
                                # Preserve intermediate reports for diagnostics even
                                # if a malformed report prevents delivery.
                                atomic_write(Path(directory) / f"response-{uuid.uuid4().hex}.json", raw.encode("utf-8"))
                                earlier_reports.append(parse_report(raw, role))
                            current_message = self.interaction.take()
                            if current_message:
                                sent_at = time.monotonic()
                                send_message(message_text(current_message) + "\nReturn the complete structured report. Count fixes made in THIS response only; the runtime aggregates earlier responses. Do not repeat prior implementation or publication.",
                                             str(uuid.UUID(current_message["identity"]["id"])))
                                continue
                            self.interaction.finish()
                        process.proc.stdin.close()
                        if earlier_reports:
                            final = parse_report(raw, role)
                            all_reports = [*earlier_reports, final]
                            for field in ("implementation_fixes", "other_fixes", "minor_edits"):
                                final[field] = sum(item[field] for item in all_reports)
                            final["substantial"] = any(item["substantial"] for item in all_reports)
                            final["description"] = "\n\n".join(item["description"] for item in all_reports)
                            final["evidence"] = list(dict.fromkeys(evidence for item in all_reports for evidence in item["evidence"]))
                            raw = json.dumps(final, ensure_ascii=False)
                    # A result frame is not a process exit. Give normal persistence a
                    # bounded grace before terminating any lingering descendants.
                    deadline = time.monotonic() + 30
                    while process.proc.poll() is None:
                        self.heartbeat()
                        if time.monotonic() >= deadline:
                            raise Blocked("claude-exit", "Claude emitted a result but did not terminate.")
                        time.sleep(0.05)
                    code = process.proc.returncode
                    if code:
                        raise Blocked("claude-exit", f"Claude exited with code {code} after its result.")
                    return raw
        finally:
            try:
                process.close()
            finally:
                try:
                    metadata = diagnostic.report()
                    metadata["launch"] = {
                        "role": role, "requested_model": model, "effort": effort, "resumed": resumed, "attempt": attempt,
                        "session_id": session, "cwd": str(self.root),
                        "standard_system_prompt": preserve_default,
                        "role_contract_sha256": digest(role_contract(role).encode("utf-8")),
                        "prompt_sha256": digest(prompt.encode("utf-8")),
                        "transport_sha256": transport_digest,
                        "instruction_files": launch_files,
                        "instruction_files_captured": "before-start",
                        # Paired inspectors start without user/project settings and load none of these files.
                        "instruction_files_enabled": role not in PAIR_READONLY,
                    }
                    metadata["completion"] = {"instruction_files": self.instruction_snapshot(role)}
                    atomic_write(Path(directory) / "claude-diagnostics.json", encode(metadata))
                except Exception:
                    # Diagnostics must not turn a result or refusal into a recoverable
                    # error, or hide a containment failure. The raw log remains.
                    print("cc-focus: Could not save Claude diagnostic metadata; use cc-focus diagnose on the invocation.", file=sys.stderr)

    def _codex(self, role, model, effort, session, prompt, pending, directory):
        readonly = role in READONLY_REVIEW_ROLES
        sandbox = "read-only" if readonly else "danger-full-access"
        argv = self.commands["codex"] + ["-s", sandbox, "-a", "on-request", "app-server",
            "--listen", "stdio://", "-c", f'sandbox_mode="{sandbox}"',
            "-c", 'approval_policy="on-request"', "-c", 'approvals_reviewer="user"',
            "-c", "features.multi_agent=false", "-c", "features.memories=false",
            "-c", f'model_reasoning_effort="{effort}"']
        if readonly:
            for feature, enabled in READONLY_FEATURE_OVERRIDES.items():
                argv += ["-c", "features." + feature + "=" + str(enabled).lower()]
            argv += ["-c", 'web_search="disabled"', "-c", "mcp_servers={}"]
        process = Process(argv, self.root, Path(directory) / "protocol.jsonl", self.heartbeat, self.lock_fd, progress=self.progress, control=self.control)
        rpc = Rpc(process, self.interaction, (ViewInspector(self.state["inspection"]) if role in PAIR_READONLY else Inspector(self.root, self.state)) if readonly else None)
        try:
            rpc.request("initialize", {"clientInfo": {"name": "orchestra_cycle", "version": "1.0.0"},
                                       "capabilities": {"experimentalApi": True}})
            rpc.notify("initialized", {})
            models, cursor, cursors = [], None, set()
            while True:
                page = rpc.request("model/list", {"includeHidden": True, "cursor": cursor})
                models.extend(page["data"])
                cursor = page.get("nextCursor")
                if not cursor:
                    break
                if cursor in cursors:
                    raise Blocked("provider-protocol", "Codex model pagination did not advance.")
                cursors.add(cursor)
            if not any(m.get("model") == model and any(e.get("reasoningEffort") == effort
                    for e in m.get("supportedReasoningEfforts", [])) for m in models):
                raise Blocked("model-unavailable", f"Codex does not advertise {model}/{effort}; no fallback is allowed.")
            params = {"model": model, "cwd": str(self.root), "approvalPolicy": "on-request",
                      "approvalsReviewer": "user", "sandbox": sandbox,
                      # Memory consolidation can start an independent tool-using
                      # agent even when ordinary delegation is disabled. Pin the
                      # feature at process startup AND for resumed/new threads.
                      "config": {"features.multi_agent": False, "features.memories": False,
                                 "model_reasoning_effort": effort},
                      "developerInstructions": role_contract(role)}
            if readonly:
                params["config"].update({"features." + key: enabled for key, enabled in READONLY_FEATURE_OVERRIDES.items()})
                params["config"]["web_search"] = "disabled"
                params["config"]["mcp_servers"] = {}
                # Replace the inherited map at process and thread scope. Do not
                # request/copy operator configuration (which may contain tokens)
                # into the protocol log just to disable these servers.
            created = not session
            if session:
                params["threadId"] = session
                params["excludeTurns"] = True
                try:
                    reply = rpc.request("thread/resume", params)
                except Blocked as error:
                    # A thread ID can be acknowledged before the first user turn
                    # materializes its native rollout. Auth/policy failures must
                    # never be treated as missing conversation history.
                    if error.code != "codex-rpc" or "no rollout found" not in str(error).lower():
                        raise
                    self.state.setdefault("session_recoveries", []).append({"role": role, "missing": session,
                                                                           "invocation": pending["id"]})
                    print(f"cc-focus: {role} native history is missing; continuing the same phase from durable context.", flush=True)
                    params.pop("threadId")
                    params.pop("excludeTurns")
                    created = True
                    prompt += ('\nThe prior native conversation is unavailable. This is a new conversation for the SAME runtime phase. Reconstruct context from handoffs and invocation artifacts. Keep existing work. Do not discard it. Do not advance to another stage.')
            if created:
                params.update(ephemeral=False, allowProviderModelFallback=False)
                if readonly:
                    params["dynamicTools"] = [READ_TOOL]
                reply = rpc.request("thread/start", params)
                session = reply["thread"]["id"]
                self.state["sessions"][role] = session
                self.save(self.state)
            if (reply["model"] != model or reply["approvalPolicy"] != "on-request"
                    or reply.get("approvalsReviewer") != "user"
                    or reply.get("reasoningEffort") != effort
                    or reply["sandbox"].get("type") != ("readOnly" if readonly else "dangerFullAccess")
                    or Path(reply["cwd"]).resolve() != self.root
                    or reply["thread"]["id"] != session):
                raise Blocked("provider-profile", "Codex effective model, root or permission policy differs from the requested profile.")
            # Recover an acknowledged turn or locate an unacknowledged turn by its
            # durable marker. Do not repeat completed publication/model work.
            marker = "cc-cycle/" + pending["id"]
            turns = []
            if not created and (pending.get("turn_id") or pending.get("attempts", 0) > 1):
                turns = rpc.request("thread/turns/list", {"threadId": session, "limit": 1,
                                    "sortDirection": "desc", "itemsView": "full"})["data"]
            for turn in turns:
                matches = turn.get("id") == pending.get("turn_id") or any(
                    item.get("type") == "userMessage" and marker in json.dumps(item, ensure_ascii=False)
                    for item in turn.get("items", []))
                if matches and turn.get("status") == "completed":
                    messages = self.interaction.messages if self.interaction else None
                    records = messages.accepted(self.state["iteration"], pending["id"]) if messages else []
                    undelivered = messages.unresolved(self.state["iteration"], pending["id"]) if messages else []
                    history_text = json.dumps(turn.get("items", []), ensure_ascii=False)
                    if not undelivered and all("focus-message:" + item["identity"]["id"] in history_text for item in records):
                        return final_text(turn)
                if matches and turn.get("status") == "inProgress":
                    raise Blocked("turn-active", "The prior Codex turn is still active; refusing a duplicate.")
            request = {"threadId": session, "input": [{"type": "text", "text": prompt}],
                       "model": model, "effort": effort, "cwd": str(self.root),
                       "approvalPolicy": "on-request", "approvalsReviewer": "user",
                       "sandboxPolicy": {"type": "readOnly"} if readonly else {"type": "dangerFullAccess"}, "outputSchema": report_schema(role)}
            turn = rpc.request("turn/start", request)["turn"]
            pending["turn_id"] = turn["id"]
            self.save(self.state)
            completed = None
            sent_at = None

            def steer():
                nonlocal sent_at
                if rpc.callbacks:
                    if time.monotonic() - sent_at > 30:
                        raise MessagePending("Codex did not acknowledge the message within 30 seconds; delivery is uncertain. Explicitly retry or discard it.")
                    return
                if not self.interaction or completed is not None:
                    return
                record = self.interaction.take()
                if record:
                    sent_at = time.monotonic()
                    def acknowledge(reply):
                        result = reply.get("result")
                        accepted = ("error" not in reply and isinstance(result, dict) and result.get("turnId") == turn["id"])
                        self.interaction.ack(record, accepted, "" if accepted else str(reply.get("error", "Unexpected turn ID")))
                    rpc.send_request("turn/steer", {"threadId": session, "expectedTurnId": turn["id"],
                        "input": [{"type": "text", "text": message_text(record)}]}, acknowledge)

            process.on_poll = steer
            work_started, requests_before = False, rpc.server_requests
            while True:
                event = rpc.event()
                if event.get("method") == "model/rerouted":
                    raise Blocked("model-rerouted", "Codex rerouted the pinned model; refusing a substituted result.")
                if event.get("method") in ("item/started", "item/completed"):
                    item = (event.get("params") or {}).get("item")
                    if isinstance(item, dict) and item.get("type") != "userMessage":
                        work_started = True  # Model output or a tool call: a retry is not a clean repeat.
                work_started = work_started or rpc.server_requests > requests_before
                if event.get("method") == "turn/completed":
                    data = event["params"]
                    if data["threadId"] != session or data["turn"]["id"] != turn["id"]:
                        continue
                    if data["turn"]["status"] != "completed":
                        error = data["turn"].get("error")
                        reason = codex_transient(error)
                        if reason:
                            # Like a Claude server error: bounded retries of the same invocation and thread.
                            raise ProviderTransient(reason, str(error.get("message") or reason),
                                                    no_work=not work_started, provider="codex")
                        raise Blocked("codex-failed", str(error or data["turn"]["status"])[-4000:])
                    completed = data["turn"]
                    if self.interaction:
                        self.interaction.close_target()
                if completed is not None and not rpc.callbacks:
                    if not completed.get("items"):
                        history = rpc.request("thread/turns/list", {"threadId": session, "limit": 1,
                                              "sortDirection": "desc", "itemsView": "full"})
                        completed = next(t for t in history["data"] if t["id"] == turn["id"])
                    return final_text(completed)
        finally:
            process.close()


# Codex app-server error kinds (codexErrorInfo) for a server failure that a later retry can fix.
CODEX_SERVER_ERRORS = ("serverOverloaded", "internalServerError")
CODEX_HTTP_ERRORS = ("httpConnectionFailed", "responseStreamConnectionFailed",
                     "responseStreamDisconnected", "responseTooManyFailedAttempts")
SERVER_STATUSES = (500, 502, 503, 504, 529)


def codex_transient(error):
    """Name a Codex server failure that a later retry can fix, or return None."""
    info = error.get("codexErrorInfo") if isinstance(error, dict) else None
    if isinstance(info, str) and info in CODEX_SERVER_ERRORS:
        return info
    if isinstance(info, dict) and len(info) == 1:
        kind, value = next(iter(info.items()))
        status = value.get("httpStatusCode") if isinstance(value, dict) else None
        if kind in CODEX_HTTP_ERRORS and type(status) is int and status in SERVER_STATUSES:
            return f"{kind} {status}"
    return None


def final_text(turn):
    messages = [item for item in turn.get("items", []) if item.get("type") == "agentMessage"]
    finals = [item for item in messages if item.get("phase") == "final_answer"]
    if not (finals or messages):
        raise Blocked("missing-final", "Completed Codex turn has no final message.")
    return (finals or messages)[-1]["text"]


class Rpc:
    def __init__(self, process, interaction=None, inspector=None):
        self.inspector = inspector
        self.process = process
        self.sequence = 0
        self.notifications = deque()
        self.callbacks = {}
        self.interaction = interaction
        self.server_requests = 0  # Tool calls and approval requests that the turn loop does not see.

    def notify(self, method, params):
        self.process.send(encode({"method": method, "params": params}) + b"\n")

    def request(self, method, params):
        request_id = self.send_request(method, params)
        while True:
            message = self._receive()
            if message.get("id") == request_id and "method" not in message:
                if "error" in message:
                    raise Blocked("codex-rpc", f"{method}: {message['error']}")
                return message["result"]
            self.notifications.append(message)

    def send_request(self, method, params, callback=None):
        self.sequence += 1
        request_id = self.sequence
        if callback:
            self.callbacks[request_id] = callback
        self.process.send(encode({"id": request_id, "method": method, "params": params}) + b"\n")
        return request_id

    def event(self):
        return self.notifications.popleft() if self.notifications else self._receive()

    def _receive(self):
        while True:
            message = self.process.receive()
            if "method" not in message and message.get("id") in self.callbacks:
                self.callbacks.pop(message["id"])(message)
                return {"method": "focus/inputResponse", "params": {}}
            if "id" not in message or "method" not in message:
                return message
            method, params = message["method"], message.get("params", {})
            self.server_requests += 1
            if self.inspector:
                if method != "item/tool/call":
                    raise Blocked("readonly-tool", "Final review cannot execute commands, change files or request execution approval.")
                result = self.inspector.call(params)
                self.process.send(encode({"id": message["id"], "result": result}) + b"\n")
                continue
            if method in ("item/commandExecution/requestApproval", "item/fileChange/requestApproval"):
                if self.interaction and self.interaction.interactive:
                    answer = "y" if self.interaction.approve(params, self.process.heartbeat) else "n"
                elif not sys.stdin.isatty():
                    raise Blocked("approval-required", f"Operator approval is required: {json.dumps(params, ensure_ascii=False)}")
                else:
                    from focus_output import terminal_text
                    print("\nCodex requests approval:\n" + terminal_text(json.dumps(params, ensure_ascii=False, indent=2)), flush=True)
                    answer = input("Approve this one operation? [y/N] ").strip().lower()
                decision = "accept" if answer == "y" else "cancel"
                self.process.send(encode({"id": message["id"], "result": {"decision": decision}}) + b"\n")
                if decision == "cancel":
                    raise Blocked("approval-denied", "The operator did not approve the requested operation.")
            else:
                raise Blocked("operator-input", f"Operator input is required for {method}: {json.dumps(params, ensure_ascii=False)}")
