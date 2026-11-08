"""Read provider metadata without exporting private content or changing cycle state."""

from collections import OrderedDict, deque
import hashlib
import json
import os
from pathlib import Path
import re

from cycle_state import Blocked


def short(value, limit=200):
    # Provider JSON and file paths can hold lone surrogates. Saved diagnostics must stay encodable.
    return value[:limit].encode("utf-8", "replace").decode("utf-8") if isinstance(value, str) else None


def payload_metadata(value):
    try:
        text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, sort_keys=True)
        data = text.encode("utf-8")
        return {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    except (TypeError, ValueError, RecursionError):
        return {"bytes": None, "sha256": None}  # Diagnostics cannot reject a provider response.


class ClaudeTrace:
    """Keep bounded public metadata; never retain message bodies or tool arguments."""

    def __init__(self):
        self.initialization = {}
        self.messages = OrderedDict()
        self.active_message = None
        self.actions = deque(maxlen=12)
        self.refusals = deque(maxlen=20)
        self.cli_events = deque(maxlen=32)
        self.result = {}
        self.active_tasks = set()
        self.events = 0
        self.usage = {"messages_observed": 0, "first_input_tokens": None,
                      "last_input_tokens": None, "peak_input_tokens": None}
        self.active_blocks = {}
        # Totals of the attempt for its usage record. One API message appears as several events with the same id,
        # so each id counts once, and its output is the largest count that an event of this id gave.
        self.totals = {"turns": 0, "input_tokens": 0, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0,
                       "cache_write_5m": 0, "cache_write_1h": 0, "output_tokens": 0, "peak_context": 0,
                       "compaction_count": 0, "compactions": []}
        self.counted = {}

    def message(self, message, event):
        identity = short(message.get("id"))
        if not identity:
            return {}
        if identity not in self.messages:
            if len(self.messages) >= 128:
                self.messages.popitem(last=False)
            self.messages[identity] = {}
            self.usage["messages_observed"] += 1
            self.messages[identity]["sequence"] = self.usage["messages_observed"]
            self.messages[identity]["first_event"] = self.events
        item = self.messages[identity]
        for key, value in (("id", identity), ("model", message.get("model")),
                           ("request_id", event.get("request_id")), ("session_id", event.get("session_id"))):
            if isinstance(value, str):
                item[key] = short(value)
        return item

    def record_usage(self, message, item):
        """Record input size only when all three provider counters are present."""
        usage = message.get("usage")
        if not item or not isinstance(usage, dict):
            return
        output = usage.get("output_tokens")
        if type(output) is int and output >= 0:
            item["output_tokens"] = output
        fields = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
        values = [usage.get(key) for key in fields]
        if any(type(value) is not int or value < 0 for value in values):
            return
        tokens = sum(values)
        if self.usage["first_input_tokens"] is None:
            self.usage["first_input_tokens"] = tokens
        self.usage["last_input_tokens"] = tokens
        self.usage["peak_input_tokens"] = max(self.usage["peak_input_tokens"] or 0, tokens)
        item["input_tokens"] = tokens
        item["input_counters"] = dict(zip(fields, values))

    def count(self, identity, model, usage):
        """Add one API message to the totals. CLI notes with the model <synthetic> are not model turns."""
        if not identity or not isinstance(usage, dict) or model == "<synthetic>":
            return
        entry = self.counted.get(identity)
        if entry is None:
            fields = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")
            values = [usage.get(key) for key in fields]
            if any(type(value) is not int or value < 0 for value in values):
                return  # A later event of this message gives the input counters.
            entry = self.counted[identity] = {"output": 0}
            totals = self.totals
            totals["turns"] += 1
            for key, value in zip(fields, values):
                totals[key] += value
            split = usage.get("cache_creation")
            if isinstance(split, dict):
                for key, name in (("ephemeral_5m_input_tokens", "cache_write_5m"), ("ephemeral_1h_input_tokens", "cache_write_1h")):
                    if type(split.get(key)) is int and split[key] >= 0:
                        totals[name] += split[key]
            totals["peak_context"] = max(totals["peak_context"], sum(values))
        output = usage.get("output_tokens")
        if type(output) is int and output > entry["output"]:
            self.totals["output_tokens"] += output - entry["output"]
            entry["output"] = output

    def record_blocks(self, item, content):
        if not item:
            return
        kinds = item.setdefault("block_types", [])
        for block in content:
            kind = block.get("type") if isinstance(block, dict) else None
            if kind in ("text", "thinking", "redacted_thinking", "tool_use") and kind not in kinds:
                kinds.append(kind)

    def feed(self, event):
        if not isinstance(event, dict):
            return None
        self.events += 1
        kind = event.get("type")
        message = event.get("message")
        message = message if isinstance(message, dict) else {}
        content = message.get("content")
        content = content if isinstance(content, list) else []
        part = event.get("event") if kind == "stream_event" and isinstance(event.get("event"), dict) else {}
        operator_turn = kind == "user" and (isinstance(message.get("content"), str) or any(
            isinstance(b, dict) and b.get("type") != "tool_result" for b in content))
        if self.result and (kind == "assistant" or part.get("type") == "message_start" or operator_turn):
            self.result = {}  # A later turn started. Only its own result completes the attempt.
        if kind == "system" and event.get("subtype") in ("task_started", "task_notification"):
            task = short(event.get("task_id"))
            if task and event["subtype"] == "task_started" and len(self.active_tasks) < 256:
                self.active_tasks.add(task)
            elif task and event.get("status") in ("completed", "failed", "stopped"):
                self.active_tasks.discard(task)
        if kind == "system" and event.get("subtype") == "init":
            self.initialization = {key: short(event.get(key)) for key in
                                   ("session_id", "model", "claude_code_version", "permissionMode")}
            for key in ("tools", "skills", "agents"):
                values = event.get(key)
                self.initialization[key] = [short(v) for v in values[:256] if isinstance(v, str)] if isinstance(values, list) else []
            plugins = event.get("plugins")
            self.initialization["plugins"] = [short(p.get("name")) for p in plugins[:128]
                                               if isinstance(p, dict) and isinstance(p.get("name"), str)] if isinstance(plugins, list) else []
        if kind == "system" and event.get("subtype") in ("compact_boundary", "informational", "model_refusal_no_fallback"):
            self.cli_event(event)
        if kind == "assistant":
            item = self.message(message, event)
            self.record_usage(message, item)
            self.count(short(message.get("id")), message.get("model"), message.get("usage"))
            self.record_blocks(item, content)
            if message.get("stop_reason") in ("end_turn", "tool_use", "refusal", "max_tokens", "stop_sequence"):
                item["stop_reason"] = message["stop_reason"]
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_use":
                    continue
                self.actions.append({"id": short(block.get("id")), "tool": short(block.get("name")),
                                     "event": self.events, "result_seen": False,
                                     "input": payload_metadata(block.get("input"))})
            if message.get("stop_reason") == "refusal":
                return self.refusal(event, item, message.get("stop_details"), "assistant")
        if kind == "user":
            for block in content:
                if not isinstance(block, dict) or block.get("type") != "tool_result":
                    continue
                identity = short(block.get("tool_use_id"))
                for action in self.actions:
                    if identity and action["id"] == identity:
                        action["result_seen"] = True
                        action["is_error"] = block.get("is_error") is True
                        action["result_event"] = self.events
                        action["result"] = payload_metadata(block.get("content"))
        if kind == "stream_event":
            part = event.get("event")
            part = part if isinstance(part, dict) else {}
            if part.get("type") == "message_start":
                start = part.get("message")
                start = start if isinstance(start, dict) else {}
                item = self.message(start, event)
                self.record_usage(start, item)
                self.count(short(start.get("id")), start.get("model"), start.get("usage"))
                self.active_message = dict(item)
                self.active_message["parent_tool_use_id"] = short(event.get("parent_tool_use_id"))
                self.active_blocks = {}
            if part.get("type") in ("content_block_start", "content_block_delta", "content_block_stop"):
                item = self.messages.get((self.active_message or {}).get("id"), {})
                index = part.get("index")
                if type(index) is int and 0 <= index < 128:
                    if part["type"] == "content_block_start":
                        block = part.get("content_block")
                        if isinstance(block, dict):
                            self.record_blocks(item, [block])
                            kind = block.get("type")
                            if kind in ("text", "thinking", "redacted_thinking", "tool_use"):
                                self.active_blocks[index] = {"type": kind, "closed": False}
                                item["last_block_type"] = kind
                    elif part["type"] == "content_block_delta":
                        delta = part.get("delta")
                        kind = delta.get("type") if isinstance(delta, dict) else None
                        if kind in ("text_delta", "thinking_delta", "input_json_delta", "signature_delta"):
                            item["last_delta_type"] = kind
                    elif index in self.active_blocks:
                        self.active_blocks[index]["closed"] = True
            if part.get("type") == "message_delta":
                delta = part.get("delta")
                stored = self.messages.get((self.active_message or {}).get("id"), {})
                self.record_usage({"usage": part.get("usage")}, stored)
                active = self.active_message or {}
                self.count(active.get("id"), active.get("model"), part.get("usage"))
                if stored and isinstance(delta, dict) and delta.get("stop_reason") in (
                        "end_turn", "tool_use", "refusal", "max_tokens", "stop_sequence"):
                    stored["stop_reason"] = delta["stop_reason"]
                if isinstance(delta, dict) and delta.get("stop_reason") == "refusal":
                    item = dict(self.active_message or {})
                    completed = self.messages.get(item.get("id"), {})
                    if all(completed.get(key) == item.get(key) for key in ("model", "session_id")):
                        item["request_id"] = completed.get("request_id")
                        item["input_tokens"] = completed.get("input_tokens")
                        for key in ("sequence", "output_tokens", "block_types", "last_block_type", "last_delta_type"):
                            if key in completed:
                                item[key] = completed[key]
                    return self.refusal(event, item, delta.get("stop_details"), "message_delta")
            if part.get("type") == "message_stop":
                self.active_message = None
        if kind == "result":
            self.result = {key: short(event.get(key)) for key in ("subtype", "terminal_reason", "stop_reason")}
            error = event.get("is_error")
            self.result["is_error"] = error if type(error) is bool else None
            # Like the transport, a result is not terminal while native tasks or queued turns remain.
            self.result["deferred"] = bool(self.active_tasks or event.get("queued_turn_count", 0))
        return None

    def cli_event(self, event):
        """Keep CLI compaction and refusal notices; they explain later context sizes."""
        record = {"event": self.events, "subtype": event["subtype"],
                  "messages_before": self.usage["messages_observed"]}
        if event["subtype"] == "compact_boundary":
            metadata = event.get("compact_metadata")
            metadata = metadata if isinstance(metadata, dict) else {}
            record["trigger"] = short(metadata.get("trigger"), 40)
            for key in ("pre_tokens", "post_tokens"):
                if type(metadata.get(key)) is int and metadata[key] >= 0:
                    record[key] = metadata[key]
            self.totals["compaction_count"] += 1
            if len(self.totals["compactions"]) < 64:
                self.totals["compactions"].append({key: record[key] for key in ("trigger", "pre_tokens", "post_tokens") if key in record})
        elif event["subtype"] == "informational":
            # CLI notices are public interface text, not model output.
            record["level"] = short(event.get("level"), 40)
            record["notice"] = short(event.get("content"), 200)
        else:
            record.update(category=short(event.get("api_refusal_category"), 120),
                          request_id=short(event.get("request_id")), model=short(event.get("original_model")))
        self.cli_events.append(record)

    def refusal(self, event, message, details, source):
        details = details if isinstance(details, dict) else {}
        record = {"source": source, "event": self.events,
                  "session_id": short(event.get("session_id")), "message_session_id": message.get("session_id"),
                  "message_parent_tool_use_id": message.get("parent_tool_use_id"),
                  "message_id": message.get("id"), "request_id": message.get("request_id"),
                  "model": message.get("model"), "category": short(details.get("category"), 120),
                  "input_tokens": message.get("input_tokens"),
                  "sequence": message.get("sequence"), "output_tokens": message.get("output_tokens"),
                  "block_types": list(message.get("block_types", [])),
                  "last_block_type": message.get("last_block_type"),
                  "last_delta_type": message.get("last_delta_type"),
                  "open_block_types": ([b["type"] for b in self.active_blocks.values() if not b["closed"]]
                                       if (self.active_message or {}).get("id") == message.get("id") else None),
                  "explanation": short(details.get("explanation"), 2000),
                  "last_action": dict(self.actions[-1]) if self.actions else None}
        self.refusals.append(record)
        return record

    def report(self):
        return {"version": 1, "events": self.events, "initialization": self.initialization,
                "input_usage": dict(self.usage),
                "messages": [dict(item) for item in self.messages.values()],
                "refusals": list(self.refusals), "recent_actions": list(self.actions), "result": self.result,
                "cli_events": list(self.cli_events), "usage_totals": self.usage_totals(),
                "limits": "Metadata only. This report does not identify the instruction that caused a refusal."}

    def usage_totals(self):
        return dict(self.totals, compactions=list(self.totals["compactions"]),
                    claude_code_version=self.initialization.get("claude_code_version"),
                    gap="The usage of a compaction call is not in the stream. Its pre_tokens estimate the read of that call.")


RESULT_FRAMES = (b'\\"type\\":\\"result\\"', b'\\"type\\": \\"result\\"')
# A bulk scan skips streamed deltas and tool results. These escaped patterns match the event
# type field itself, not a word inside message text, a path or a task description.
SKIPPED_FRAMES = (b'\\"type\\":\\"content_block_delta\\"', b'\\"type\\": \\"content_block_delta\\"',
                  b'\\"type\\":\\"tool_result\\"', b'\\"type\\": \\"tool_result\\"')
# Frames that a bulk scan must keep even if a path or a task description quotes a skip marker.
# Escaped like this, a pattern matches a real event field, not text inside a string value.
KEPT_FRAMES = (*RESULT_FRAMES, b'\\"subtype\\":\\"init\\"', b'\\"subtype\\": \\"init\\"',
               b'\\"subtype\\":\\"task_', b'\\"subtype\\": \\"task_', b'"stream":"runtime"', b'"stream": "runtime"')


def protocol_frames(path, skip=()):
    """Yield stdout events and runtime records; skip stderr and malformed/truncated frames without copying them."""
    with path.open("rb") as stream:
        while True:
            line = stream.readline(16 * 1024 * 1024 + 1)
            if not line:
                return
            if len(line) > 16 * 1024 * 1024:
                raise Blocked("diagnostic-size", "A protocol frame exceeds the diagnostic size limit.")
            if any(marker in line for marker in skip) and not any(frame in line for frame in KEPT_FRAMES):
                continue  # A bulk scan does not need streamed deltas or tool results.
            try:
                envelope = json.loads(line)
                if not isinstance(envelope, dict) or envelope.get("stream") not in ("stdout", "runtime"):
                    continue
                value = json.loads(envelope.get("line", ""))
                if isinstance(value, dict):
                    yield envelope["stream"], value
            except (ValueError, TypeError):
                continue


def protocol_events(path, skip=()):
    """Yield provider stdout events only."""
    for stream, event in protocol_frames(path, skip):
        if stream == "stdout":
            yield event


def component_metadata(value):
    """Fingerprint instruction text or a schema; export no text or matched phrases."""
    text = value if isinstance(value, str) else json.dumps(value, ensure_ascii=False, sort_keys=True)
    terms = {"reasoning": r"\breasoning\b", "thinking": r"\bthinking\b",
             "scratchpad": r"\bscratchpad\b", "chain_of_thought": r"\bchain[ -]of[ -]thought\b"}
    return {**payload_metadata(value),
            "term_lines": {name: [number for number, line in enumerate(text.splitlines(), 1)
                                   if re.search(pattern, line, re.I)][:32]
                           for name, pattern in terms.items()}}


def native_context(path, session, root):
    """Read only known instruction attachments from the explicitly selected native log."""
    path = Path(path)
    if path.is_symlink() or not path.is_file():
        raise Blocked("diagnostic-native-log", "Use a regular Claude session log, not a symbolic link.")
    if not isinstance(session, str) or not session:
        raise Blocked("diagnostic-native-session", "The protocol has no Claude session identity for this comparison.")
    snapshots, instructions, extras = deque(maxlen=8), deque(maxlen=128), deque(maxlen=32)
    matched = 0
    total = 0
    with path.open("rb") as stream:
        while True:
            line = stream.readline(16 * 1024 * 1024 + 1)
            if not line:
                break
            total += len(line)
            if len(line) > 16 * 1024 * 1024 or total > 256 * 1024 * 1024:
                raise Blocked("diagnostic-native-size", "The native log exceeds the diagnostic read limit.")
            try:
                event = json.loads(line)
            except (ValueError, TypeError):
                continue
            if not isinstance(event, dict) or event.get("sessionId") != session or event.get("isSidechain") is True:
                continue
            cwd = event.get("cwd")
            try:
                correct_root = isinstance(cwd, str) and Path(cwd).resolve() == Path(root).resolve()
            except (OSError, ValueError):
                correct_root = False
            if not correct_root:
                continue
            matched += 1
            if event.get("type") != "attachment":
                continue
            attachment = event.get("attachment")
            if not isinstance(attachment, dict):
                continue
            kind = attachment.get("type")
            if kind == "prompt_snapshot":
                blocks, tools = attachment.get("systemPrompt"), attachment.get("tools")
                snapshots.append({"system_blocks": [component_metadata(b) for b in blocks[:64]]
                                  if isinstance(blocks, list) else [],
                                  "tools": [{"name": short(t.get("name")), **component_metadata(t)}
                                            for t in tools[:128] if isinstance(t, dict)]
                                  if isinstance(tools, list) else []})
            elif kind == "instructions":
                files = attachment.get("files")
                if isinstance(files, list):
                    for file in files[:128]:
                        if isinstance(file, dict) and isinstance(file.get("content"), str):
                            instructions.append({"scope": short(file.get("type")),
                                "path": short(file.get("path"), 1000), **component_metadata(file["content"])})
            elif kind in ("skill_listing", "mcp_instructions_delta"):
                field = "content" if kind == "skill_listing" else "addedBlocks"
                value = attachment.get(field)
                if isinstance(value, (str, list)):
                    extras.append({"kind": kind, **component_metadata(value)})
    if not matched:
        raise Blocked("diagnostic-native-session", "The native log does not match this invocation's session and project.")
    return {"session_id": session, "prompt_snapshots": list(snapshots), "instruction_files": list(instructions),
            "additional_instructions": list(extras),
            "limits": "Hashes, sizes and term locations only. Term matches can be prohibitions or unrelated references, not requests or causes."}


def instruction_files(root, enabled=True):
    """Fingerprint instruction files that Claude Code can load; never copy their text."""
    if not enabled:
        return []
    root = Path(root)
    try:
        candidates = [("user", Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude") / "CLAUDE.md")]
    except RuntimeError:
        candidates = []  # No home directory: the CLI has no user instruction file either.
    for directory in (root, *root.parents):
        candidates += [("project", directory / "CLAUDE.md"), ("local", directory / "CLAUDE.local.md"),
                       ("project", directory / ".claude" / "CLAUDE.md")]
    files, seen = [], set()
    for scope, path in candidates:
        try:
            if not path.is_file() or path.resolve() in seen:
                continue  # Under the home directory, the user file is also a parent candidate.
            seen.add(path.resolve())
            with path.open("rb") as stream:
                data = stream.read(4 * 1024 * 1024 + 1)
        except (OSError, RuntimeError):
            continue  # An unreadable candidate is not evidence of a loaded instruction.
        complete = len(data) <= 4 * 1024 * 1024
        files.append({"scope": scope, "path": short(str(path), 1000), "bytes": len(data) if complete else None,
                      "sha256": hashlib.sha256(data).hexdigest() if complete else None})
    return files


def claude_attempts(protocol):
    """Split one protocol log into attempts; return (trace, boundary record) pairs.

    A retry can reuse the invocation directory and append another process.
    The transport marks each Claude process start with a runtime record.
    Older logs have no marks. There, an event with another session starts a new attempt.
    """
    attempts = [(ClaudeTrace(), None)]
    session = None
    for stream, value in protocol_frames(protocol, SKIPPED_FRAMES):
        trace, boundary = attempts[-1]
        if stream == "runtime":
            if value.get("type") == "attempt" and len(attempts) < 64:
                if trace.events or boundary:
                    attempts.append((ClaudeTrace(), value))
                else:
                    attempts[-1] = (trace, value)
                session = None
            continue
        named = value.get("session_id") if isinstance(value.get("session_id"), str) and value.get("session_id") else None
        if boundary is None and named and session and named != session and len(attempts) < 64:
            attempts.append((ClaudeTrace(), None))
        if named and (session is None or attempts[-1][0].events == 0):
            session = named
        attempts[-1][0].feed(value)
    return attempts


def trace_session(initialization, refusals, *fallbacks):
    """Name the native session; a refusal or the launch record still names it without an init event."""
    candidates = [initialization.get("session_id")]
    candidates += [r.get("session_id") for r in refusals if isinstance(r, dict)]
    candidates += [(item or {}).get("session_id") for item in fallbacks]
    return next((c for c in candidates if isinstance(c, str) and c), None)


def saved_claude_call(directory, invocation):
    """Return the native session and refusal flag of the last attempt of a Claude invocation, or None.

    The protocol log decides which attempt is the last one. A failed diagnostic
    write can leave the file of an earlier attempt, so the saved file counts only
    when its launch record names that attempt. When the log cannot prove the
    owner, both sources are combined for the same session.
    """
    if not isinstance(invocation, str) or not re.fullmatch(r"[0-9a-f]{32}", invocation):
        return None
    target = Path(directory) / "invocations" / invocation
    cached = None
    saved = target / "claude-diagnostics.json"
    try:
        if saved.is_file() and not saved.is_symlink() and saved.stat().st_size <= 1024 * 1024:
            value = json.loads(saved.read_bytes())
            refusals = value.get("refusals") if isinstance(value.get("refusals"), list) else []
            launch = value.get("launch") if isinstance(value.get("launch"), dict) else {}
            session = trace_session(value.get("initialization") or {}, refusals, launch)
            if session:
                attempt = launch.get("attempt") if isinstance(launch.get("attempt"), str) else None
                cached = {"session_id": session, "refused": bool(refusals), "attempt": attempt}
    except (OSError, ValueError, TypeError, AttributeError):
        pass  # Older invocations keep this evidence only in the protocol log.
    attempts = None
    protocol = target / "protocol.jsonl"
    if protocol.is_file() and not protocol.is_symlink():
        try:
            attempts = claude_attempts(protocol)
        except (OSError, Blocked):
            attempts = None
    if not attempts:
        return {"session_id": cached["session_id"], "refused": cached["refused"]} if cached else None
    trace, boundary = attempts[-1]
    session = trace_session(trace.initialization, trace.refusals, boundary)
    refused = bool(trace.refusals)
    if cached:
        marks = [(b or {}).get("attempt") for _, b in attempts]
        if cached["attempt"] is not None and marks[-1] == cached["attempt"]:
            stale = False  # The saved file belongs to the last attempt.
        elif cached["attempt"] is not None:
            stale = cached["attempt"] in marks  # A later attempt replaced it.
        else:
            stale = any(marks)  # An older file cannot describe a marked attempt.
        if not stale and (session is None or session == cached["session_id"]):
            session, refused = session or cached["session_id"], refused or cached["refused"]
    return {"session_id": session, "refused": refused} if session else None


def selected_refusals(directory, state, correction=False):
    """List refused Claude conversations that a plain retry would resume.

    With correction=True, list only conversations that survive `cc-focus correct`.
    A correction drops the pair review with its reader jobs. A new repair batch
    drops the repair_execute session, and the next outer pair drops the Pair A executor sessions.
    """
    from focus_pair_profile import PAIR_WRITERS
    blocker = (state or {}).get("blocker") or {}
    if blocker.get("code") != "claude-refusal":
        return []
    found = []
    interrupted = blocker.get("interrupted") or {}
    call = saved_claude_call(directory, interrupted.get("id"))
    if (call and (state.get("sessions") or {}).get(interrupted.get("role")) == call["session_id"]
            and not (correction and interrupted.get("role") in PAIR_WRITERS)):
        found.append({"invocation": interrupted["id"], "role": interrupted.get("role"), "session_id": call["session_id"]})
    if correction:
        return found
    from focus_pair_profile import pair_nodes
    for node in pair_nodes(state):
        # A pair blocker names its group. Each unfinished reader resumes its own job session.
        for job in (node.get("jobs") or {}).values():
            session = (job.get("sessions") or {}).get(job.get("role"))
            call = None if job.get("result") or not session else saved_claude_call(directory, job.get("id"))
            if call and call["refused"] and call["session_id"] == session:
                found.append({"invocation": job["id"], "role": job.get("role"), "session_id": session})
    return found


PROMPT_MARKERS = ("{", "[", "Runtime context:", "Runtime assignment:", "Executor assignment:",
                  "Report schema:", "Invocation marker:")


def paragraphs(text):
    """Map prompt paragraphs to their first lines; runtime JSON and marker lines are excluded."""
    lines = [line for line in text.splitlines() if not line.lstrip().startswith(PROMPT_MARKERS)]
    blocks = {}
    for block in re.split(r"\n\s*\n", "\n".join(lines)):
        block = block.strip()
        if block:
            blocks[hashlib.sha256(block.encode("utf-8", "replace")).hexdigest()] = short(block.splitlines()[0], 100)
    return blocks


def prompt_blocks(path):
    """Map the paragraphs of a saved prompt to their first lines."""
    try:
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 4 * 1024 * 1024:
            return {}
        return paragraphs(path.read_text(encoding="utf-8", errors="replace"))
    except OSError:
        return {}


def runtime_instruction_blocks():
    """Hash the paragraphs of the current runtime instructions.

    A prompt also embeds provider reports, plans and handoffs. Only paragraphs
    found here may be named by their first line.
    """
    try:
        import cycle_prompts
    except ImportError:
        return set()
    texts = [value for value in vars(cycle_prompts).values() if isinstance(value, str)]
    texts += [value for value in getattr(cycle_prompts, "PROMPTS", {}).values() if isinstance(value, str)]
    for role in getattr(cycle_prompts, "PROFILES", {}):
        try:
            texts.append(cycle_prompts.role_contract(role))
        except (KeyError, ValueError, TypeError):
            continue
    return {block for text in texts for block in paragraphs(text)}


def scan_claude_invocation(target):
    """Summarize each attempt of one Claude invocation from bounded metadata; return [] for other providers."""
    protocol = target / "protocol.jsonl"
    launch, completion = {}, {}
    saved = target / "claude-diagnostics.json"
    try:
        if saved.is_file() and not saved.is_symlink() and saved.stat().st_size <= 1024 * 1024:
            value = json.loads(saved.read_bytes())
            launch, completion = value.get("launch"), value.get("completion")
    except (OSError, ValueError, TypeError, AttributeError):
        pass  # The protocol log remains the source for refusals and results.
    launch = launch if isinstance(launch, dict) else {}
    completion = completion if isinstance(completion, dict) else {}
    try:
        if protocol.is_symlink() or not protocol.is_file():
            return []
        with protocol.open("rb") as stream:
            head = stream.read(256 * 1024)
        # Only the Claude transport writes a launch record or an attempt mark.
        if not (isinstance(launch.get("requested_model"), str) or b"claude_code_version" in head
                or b'"stream":"runtime"' in head or b'"stream": "runtime"' in head):
            return []
        attempts = claude_attempts(protocol)
    except (OSError, Blocked):
        return []
    if not (isinstance(launch.get("requested_model"), str)
            or any((boundary or {}).get("provider") == "claude" for _, boundary in attempts)
            or any(trace.initialization.get("claude_code_version") for trace, _ in attempts)):
        return []  # Another provider can quote Claude fields in its own output.
    role = short(launch.get("role"))
    intent = target / "intent.json"
    first_start = None
    if intent.is_file() and not intent.is_symlink():
        try:
            first_start = intent.stat().st_mtime  # The runtime writes the intent once, before the first attempt.
            if role is None and intent.stat().st_size <= 4 * 1024 * 1024:
                role = short(json.loads(intent.read_bytes()).get("role"))
        except (OSError, ValueError, TypeError, AttributeError):
            pass  # The role stays unknown.
    prompt = target / "prompt.txt"
    try:
        prompt_time = (prompt if prompt.is_file() else protocol).stat().st_mtime
        prompt_sha256 = (hashlib.sha256(prompt.read_bytes()).hexdigest()
                         if prompt.is_file() and not prompt.is_symlink() and prompt.stat().st_size <= 4 * 1024 * 1024 else None)
    except OSError:
        return []
    # The launch record belongs to the attempt that it names. The runtime writes
    # the prompt file just before each process, so the prompt is the last one.
    marks = [(b or {}).get("attempt") for _, b in attempts]
    owner = len(attempts)
    if isinstance(launch.get("attempt"), str):
        owner = next((n for n, mark in enumerate(marks, 1) if mark == launch["attempt"]), None)
    elif launch and any(marks):
        # An older launch record has no attempt ID. It can describe only an attempt before the first mark.
        owner = next(n for n, mark in enumerate(marks) if mark) or None
    rows = []
    for number, (trace, boundary) in enumerate(attempts, 1):
        report = trace.report()
        known = launch if number == owner else {}
        # A restart after a refusal keeps the refused attempt's launch record and prompt under its attempt ID.
        kept = kept_attempt(target, (boundary or {}).get("attempt"))
        row_completion, prompt_file, row_prompt = completion, "prompt.txt", prompt_sha256
        if kept:
            known, row_completion, prompt_file, row_prompt = kept
        started = (boundary or {}).get("started")
        estimated = False
        if type(started) not in (int, float) or not started > 0:
            if number == len(attempts):
                started = prompt_time  # The runtime writes the prompt file just before the process starts.
            elif number == 1 and first_start is not None:
                started, estimated = min(first_start, prompt_time), True
            else:
                started = None  # Unknown: the attempt is listed but not ordered.
        result = report["result"]
        # Only an explicit successful terminal result counts. The CLI reports some
        # refusals as subtype "success" with is_error=true.
        completed = (result.get("subtype") == "success" and result.get("is_error") is False
                     and not result.get("deferred") and result.get("stop_reason") != "refusal" and not report["refusals"]
                     and not any(e["subtype"] == "model_refusal_no_fallback" for e in report["cli_events"]))
        files = file_hashes(known.get("instruction_files"))
        # In older records, the runtime hashed the files at completion under the launch label. Their timing stays unknown.
        timing = "before-start" if files is not None and known.get("instruction_files_captured") == "before-start" else None
        final = file_hashes(row_completion.get("instruction_files")) if timing else None
        resumed = known.get("resumed", (boundary or {}).get("resumed"))
        row_role = role or short((boundary or {}).get("role"))
        loaded = known.get("instruction_files_enabled")
        if type(loaded) is not bool:
            from focus_pair_profile import PAIR_READONLY
            loaded = None if row_role is None or files is None else row_role not in PAIR_READONLY
        rows.append({"invocation": target.name, "attempt": number, "attempts": len(attempts),
            "started": round(started, 3) if started is not None else None, "start_time_estimated": estimated,
            "role": row_role, "session_id": trace_session(report["initialization"], report["refusals"], boundary, known),
            "cwd": short(known.get("cwd") or (boundary or {}).get("cwd"), 1000),
            "claude_code_version": report["initialization"].get("claude_code_version"),
            "model": report["initialization"].get("model"),
            "resumed": resumed if type(resumed) is bool else None,
            "messages": report["input_usage"]["messages_observed"],
            "first_input_tokens": report["input_usage"]["first_input_tokens"],
            "peak_input_tokens": report["input_usage"]["peak_input_tokens"],
            "compactions": sum(e["subtype"] == "compact_boundary" for e in report["cli_events"]),
            "usage": {key: value for key, value in report["usage_totals"].items() if key != "gap"},
            # A newer CLI can ignore the compaction window without a message. This shows it.
            "window_exceeded_without_compaction": window_ignored(report["usage_totals"]),
            "refusals": [{key: refusal.get(key) for key in ("sequence", "input_tokens", "category", "model",
                          "request_id", "message_id", "source")} for refusal in report["refusals"]],
            "cli_refusal_notices": sum(e["subtype"] != "compact_boundary" for e in report["cli_events"]),
            "role_contract_sha256": known.get("role_contract_sha256") if isinstance(known.get("role_contract_sha256"), str) else None,
            # A launch without a prompt hash is older; its prompt is the current file.
            "prompt_known": (bool(kept) or number == len(attempts)) and row_prompt is not None
                            and known.get("prompt_sha256", row_prompt) == row_prompt,
            "prompt_file": prompt_file,
            "result": {key: result.get(key) for key in ("subtype", "is_error", "stop_reason", "terminal_reason", "deferred")}
                      if result else None,
            "completed": completed,
            "instruction_files": files, "instruction_files_timing": timing or "unknown",
            "instruction_files_loaded": loaded,
            "instruction_files_changed_during_run": None if final is None else
                sorted(p for p in files.keys() | final.keys() if files.get(p) != final.get(p))})
    return rows


WINDOW_MARGIN = 50000  # The CLI compacts a little before the window. Above it plus this margin, it did not compact.


def window_ignored(totals):
    from cycle_prompts import CLAUDE_COMPACT_WINDOW
    return bool(totals["peak_context"] > CLAUDE_COMPACT_WINDOW + WINDOW_MARGIN and not totals["compaction_count"])


USAGE_FIELDS = ("turns", "input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens", "cache_write_5m",
                "cache_write_1h", "output_tokens", "compaction_count")


def usage_summary(store_directory, iteration):
    """Totals of the Claude usage records of one iteration in one run store, also for each role."""
    total = dict.fromkeys(("attempts", *USAGE_FIELDS, "peak_context", "compaction_pre_tokens"), 0)
    roles = {}
    folder = Path(store_directory) / "invocations"
    for path in sorted(folder.glob("*/usage-*.json")) if folder.is_dir() else ():
        try:
            if path.is_symlink() or path.stat().st_size > 256 * 1024:
                continue
            record = json.loads(path.read_bytes())
        except (OSError, ValueError):
            continue
        if not isinstance(record, dict) or record.get("iteration") != iteration:
            continue
        role = roles.setdefault(str(record.get("role")), dict.fromkeys(total, 0))
        for row in (total, role):
            row["attempts"] += 1
            for key in USAGE_FIELDS:
                value = record.get(key)
                row[key] += value if type(value) is int and value >= 0 else 0
            peak = record.get("peak_context")
            row["peak_context"] = max(row["peak_context"], peak if type(peak) is int else 0)
            # A compaction call is not in the stream. Its pre_tokens estimate its read.
            rows = record.get("compactions") if isinstance(record.get("compactions"), list) else []
            row["compaction_pre_tokens"] += sum(item["pre_tokens"] for item in rows
                                                if isinstance(item, dict) and type(item.get("pre_tokens")) is int and item["pre_tokens"] >= 0)
    return dict(total, roles=roles)


def kept_attempt(target, attempt):
    """Return the kept launch record, completion, prompt name and prompt hash of one refused attempt."""
    if not isinstance(attempt, str) or not re.fullmatch(r"[0-9a-f]{32}", attempt):
        return None
    saved, prompt = target / f"claude-diagnostics-{attempt}.json", target / f"prompt-{attempt}.txt"
    try:
        if saved.is_symlink() or not saved.is_file() or saved.stat().st_size > 1024 * 1024:
            return None
        value = json.loads(saved.read_bytes())
        launch, completion = value.get("launch"), value.get("completion")
        if not isinstance(launch, dict) or launch.get("attempt") != attempt:
            return None
        digest_value = None
        if prompt.is_file() and not prompt.is_symlink() and prompt.stat().st_size <= 4 * 1024 * 1024:
            digest_value = hashlib.sha256(prompt.read_bytes()).hexdigest()
        return launch, completion if isinstance(completion, dict) else {}, prompt.name, digest_value
    except (OSError, ValueError, TypeError, AttributeError):
        return None


def file_hashes(files):
    """Map saved instruction-file paths to hashes; return None for a missing or damaged list."""
    if not isinstance(files, list):
        return None
    return {f["path"]: f.get("sha256") if isinstance(f.get("sha256"), str) else None
            for f in files if isinstance(f, dict) and isinstance(f.get("path"), str)}


def session_holders(state):
    """Map native sessions to the roles that a plain retry resumes them with."""
    holders = {}
    state = state if isinstance(state, dict) else {}
    sessions = state.get("sessions") if isinstance(state.get("sessions"), dict) else {}
    pairs = list(sessions.items())
    try:
        from focus_pair_profile import pair_nodes
        for node in pair_nodes(state):
            for job in (node.get("jobs") or {}).values():
                if not job.get("result"):  # Unfinished readers resume their own job sessions.
                    pairs.append((job.get("role"), (job.get("sessions") or {}).get(job.get("role"))))
    except (AttributeError, TypeError):
        pass  # A damaged pair record leaves only the role sessions.
    for role, session in pairs:
        if isinstance(role, str) and isinstance(session, str):
            holders.setdefault(session, set()).add(role)
    return holders


def native_log_hint(row, root):
    """Name the likely native log; diagnose reads it only when the operator selects it."""
    if not row or root is None or not re.fullmatch(r"[0-9A-Fa-f-]{8,64}", row.get("session_id") or ""):
        return None
    try:
        config = Path(os.environ.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
    except RuntimeError:
        return None
    # Claude Code keys native logs by the process directory. Paired readers run in a frozen view.
    path = config / "projects" / re.sub(r"[^A-Za-z0-9]", "-", str(row.get("cwd") or root)) / (row["session_id"] + ".jsonl")
    return {"path": str(path), "exists": path.is_file(),
            "command": f"cc-focus diagnose --invocation {row['invocation']} --native-log {path}"}


def refusal_history(directory, state=None, root=None, limit=500):
    """Correlate Claude refusals with sessions and instruction changes, without message content."""
    base = Path(directory) / "invocations"
    entries = []
    if base.is_dir() and not base.is_symlink():
        for target in base.iterdir():
            if target.is_symlink() or not target.is_dir() or not re.fullmatch(r"[0-9a-f]{32}", target.name):
                continue
            marker = target / "prompt.txt"
            marker = marker if marker.is_file() else target / "protocol.jsonl"
            try:
                entries.append((marker.stat().st_mtime, target))
            except OSError:
                continue
    entries.sort(reverse=True)
    rows = []
    for _, target in entries:
        rows += scan_claude_invocation(target)
        if len(rows) >= limit:
            break
    rows.sort(key=lambda r: (r["started"] is None, r["started"] or 0))
    seen = set()
    for row in rows:
        if row["resumed"] is None and row["session_id"]:
            row["resumed"] = True if row["session_id"] in seen else None
        seen.add(row["session_id"])
    refused = [r for r in rows if r["refusals"]]
    sessions = {}
    holders = session_holders(state)
    refused_sessions = {r["session_id"] for r in refused if r["session_id"]}
    for row in rows:
        if row["session_id"] not in refused_sessions:
            continue
        item = sessions.setdefault(row["session_id"], {"session_id": row["session_id"], "invocations": set(),
            "refused_invocations": set(), "attempts": 0, "refused_attempts": 0, "first_refusal": None,
            "current_roles": sorted(holders.get(row["session_id"], ()))})
        item["invocations"].add(row["invocation"])
        item["attempts"] += 1
        if row["refusals"]:
            item["refused_invocations"].add(row["invocation"])
            item["refused_attempts"] += 1
            if item["first_refusal"] is None:
                item["first_refusal"] = {"invocation": row["invocation"], "started": row["started"],
                                         **row["refusals"][0]}
    onset = None
    ordered = [r for r in refused if r["started"] is not None]
    if ordered:
        first = ordered[0]
        # The reference is a completed provider invocation, not proof of runtime acceptance.
        earlier = [r for r in rows if r["started"] is not None and r["started"] < first["started"] and r["completed"]]
        same_role = [r for r in earlier if first["role"] is not None and r["role"] == first["role"]]
        reference = (same_role or earlier or [None])[-1]
        differences, unknown = {}, []
        if reference:
            for key in ("claude_code_version", "model", "role", "role_contract_sha256"):
                if reference[key] is None or first[key] is None:
                    unknown.append(key)  # Unknown is not a change.
                elif reference[key] != first[key]:
                    differences[key] = [reference[key], first[key]]
            if (reference["instruction_files"] is None or first["instruction_files"] is None
                    or not (reference["instruction_files_loaded"] and first["instruction_files_loaded"])):
                unknown.append("instruction_files")  # Paired inspectors load no instruction files.
            else:
                old, new = reference["instruction_files"], first["instruction_files"]
                changed = sorted(p for p in old.keys() | new.keys() if old.get(p) != new.get(p))
                if reference["instruction_files_timing"] == first["instruction_files_timing"] == "before-start":
                    if changed:
                        differences["instruction_files"] = changed
                else:
                    # Older records hashed at completion. That is weaker evidence about the launch.
                    unknown.append("instruction_files")
                    if changed:
                        differences["instruction_files_timing_unknown"] = changed
            # The prompt file belongs to the last attempt, or to a kept refused attempt. Its launch record must name the same prompt hash.
            old = prompt_blocks(base / reference["invocation"] / reference["prompt_file"]) if reference["prompt_known"] else {}
            new = prompt_blocks(base / first["invocation"] / first["prompt_file"]) if first["prompt_known"] else {}
            if old and new:
                known = runtime_instruction_blocks()
                for name, source, other in (("added", new, old), ("removed", old, new)):
                    changed = [h for h in source if h not in other]
                    differences[f"prompt_blocks_{name}"] = [source[h] for h in changed if h in known][:40]
                    differences[f"prompt_blocks_{name}_unrecognized"] = sum(h not in known for h in changed)
            else:
                unknown.append("prompt_blocks")
        onset = {"first_refusal": first, "last_completed_before": reference, "differences": differences,
                 "not_compared": unknown, "refusals_without_start_time": len(refused) - len(ordered),
                 "native_logs": [hint for hint in (native_log_hint(reference, root), native_log_hint(first, root)) if hint]}
    retry = None
    blocker = (state or {}).get("blocker") or {}
    if blocker.get("code") == "claude-refusal":
        interrupted = blocker.get("interrupted") or {}
        selected = selected_refusals(directory, state)
        for item in selected:
            # The selected conversation is the last attempt of its invocation, whatever its start time.
            saved = max((r for r in rows if r["invocation"] == item["invocation"]
                         and r["session_id"] == item["session_id"]), key=lambda r: r["attempt"], default=None)
            item["role_contract_changed"] = None
            if saved and saved["role_contract_sha256"]:
                try:
                    from cycle_prompts import role_contract
                    from focus_review_contract import review_contract
                    # In a review campaign, outer readers get the campaign form and repair readers the plain form.
                    current = role_contract(item["role"])
                    forms = {hashlib.sha256(review_contract(current, campaign).encode("utf-8")).hexdigest()
                             for campaign in (False, True)}
                    item["role_contract_changed"] = saved["role_contract_sha256"] not in forms
                except KeyError:
                    pass  # Unknown legacy role: the comparison stays unknown.
        retry = {"invocation": interrupted.get("id"), "role": interrupted.get("role"),
                 "selected_refusals": selected, "same_conversation": bool(selected),
                 "role_contract_changed": selected[0]["role_contract_changed"] if selected else None,
                 "guidance": ("A plain --retry resends a refused conversation, so the runtime rejects it. "
                              "Remove the cause from the instructions. Then use cc-focus --new-sessions --retry."
                              if selected else "No refused conversation is selected for a plain retry.")}
    return {"version": 2, "scanned": {"directories": len(entries),
                                      "claude_invocations": len({r["invocation"] for r in rows}),
                                      "claude_attempts": len(rows), "limit": limit, "truncated": len(rows) >= limit},
            "refusals": [dict(r, refusals=r["refusals"][:4]) for r in refused][-50:],
            "sessions": [dict(item, invocations=len(item["invocations"]), refused_invocations=len(item["refused_invocations"]))
                         for item in sessions.values()], "onset": onset, "retry": retry,
            "limits": ("Metadata, fingerprints and instruction first lines only. "
                       "Each Claude process in an invocation directory is a separate attempt. "
                       "Only the attempt that owns the saved launch record has its launch metadata. "
                       "A refused attempt before an automatic restart keeps its own launch record and prompt file. "
                       "The prompt file belongs to the last attempt. "
                       "An attempt without a start time is listed but not used for the onset. "
                       "The onset reference is the last earlier Claude attempt with a successful terminal result. "
                       "It does not prove runtime acceptance. "
                       "Only paragraphs of the current runtime instructions are named. Other prompt paragraphs are counted. "
                       "Instruction files are candidates, not confirmed loaded instructions. "
                       "Unknown timing marks older records hashed at completion. Their changes appear under "
                       "instruction_files_timing_unknown. "
                       "Correlation does not identify the cause of a provider refusal.")}


def saved_instruction_files(files):
    """Project saved instruction-file fingerprints; drop any other field."""
    if not isinstance(files, list):
        return None
    return [{"scope": short(f.get("scope"), 20), "path": short(f.get("path"), 1000),
             "bytes": f.get("bytes") if type(f.get("bytes")) is int else None,
             "sha256": f.get("sha256") if isinstance(f.get("sha256"), str)
                       and re.fullmatch(r"[0-9a-f]{64}", f["sha256"]) else None}
            for f in files[:64] if isinstance(f, dict)]


def diagnose(directory, invocation, public_output=False, native_log=None):
    """Inspect one invocation without a lease, state writes, Git, or provider calls."""
    if not re.fullmatch(r"[0-9a-f]{32}", invocation):
        raise Blocked("diagnostic-invocation", "Use the 32-character invocation ID from the cycle log.")
    base = Path(directory) / "invocations"
    target = base / invocation
    if target.is_symlink() or target.resolve().parent != base.resolve() or not target.is_dir():
        raise Blocked("diagnostic-invocation", "The invocation directory is missing or is a symbolic link.")
    protocol = target / "protocol.jsonl"
    if protocol.is_symlink() or not protocol.is_file():
        raise Blocked("diagnostic-log", "The invocation has no regular protocol log.")
    trace = ClaudeTrace()
    if public_output:
        from focus_output import LiveOutput
        output = LiveOutput("diagnostic")
    for event in protocol_events(protocol):
        trace.feed(event)
        if public_output:
            output.event(event)
    if public_output:
        output.boundary()
        return None
    result = trace.report()
    result["invocation"] = invocation
    # The fields above cover the whole log. A retry can append several processes to it.
    attempts = claude_attempts(protocol)
    result["attempts"] = [{"attempt": number, "session_id": trace_session(item.initialization, item.refusals, boundary),
                           "started": (boundary or {}).get("started") if type((boundary or {}).get("started")) in (int, float) else None,
                           "refusals": len(item.refusals), "result": item.result or None,
                           "usage": {key: value for key, value in item.usage_totals().items() if key != "gap"},
                           # A newer CLI can ignore the compaction window without a message. This shows it.
                           "window_exceeded_without_compaction": window_ignored(item.totals)}
                          for number, (item, boundary) in enumerate(attempts, 1)]
    saved = target / "claude-diagnostics.json"
    if saved.is_file() and not saved.is_symlink() and saved.stat().st_size <= 1024 * 1024:
        try:
            value = json.loads(saved.read_bytes())
            launch = value.get("launch") if isinstance(value, dict) else None
            if isinstance(launch, dict):
                result["launch"] = {k: short(launch.get(k)) for k in ("role", "requested_model", "effort")}
                for key in ("resumed", "standard_system_prompt"):
                    if type(launch.get(key)) is bool:
                        result["launch"][key] = launch[key]
                if isinstance(launch.get("attempt"), str) and re.fullmatch(r"[0-9a-f]{32}", launch["attempt"]):
                    result["launch"]["attempt"] = launch["attempt"]
                result["launch"]["session_id"] = short(launch.get("session_id"))
                result["launch"]["cwd"] = short(launch.get("cwd"), 1000)
                for key in ("role_contract_sha256", "prompt_sha256", "transport_sha256"):
                    if isinstance(launch.get(key), str) and re.fullmatch(r"[0-9a-f]{64}", launch[key]):
                        result["launch"][key] = launch[key]
                files = saved_instruction_files(launch.get("instruction_files"))
                if files is not None:
                    result["launch"]["instruction_files"] = files
                    # In older records, the runtime hashed these files at completion under the launch label.
                    result["launch"]["instruction_files_captured"] = (
                        "before-start" if launch.get("instruction_files_captured") == "before-start" else "unknown")
                    completion = value.get("completion")
                    files = saved_instruction_files(completion.get("instruction_files")) if isinstance(completion, dict) else None
                    if files is not None and result["launch"]["instruction_files_captured"] == "before-start":
                        result["completion"] = {"instruction_files": files}
        except (OSError, ValueError, TypeError):
            pass  # The raw protocol remains the source for refusal observations.
    if native_log is not None:
        # The saved launch names the session and directory of the process that wrote it,
        # normally the latest one, also when it ended before its init event. After a failed
        # diagnostic write it can describe an earlier attempt. Paired readers run in a frozen view.
        # Claude Code names a native log after its session. The file name selects the attempt with that
        # session: an earlier one, or the latest one when the saved launch is stale.
        launch = result.get("launch") or {}
        session = launch.get("session_id") or trace_session(result["initialization"], trace.refusals)
        cwd = launch.get("cwd")
        for (item, boundary), summary in zip(attempts, result["attempts"]):
            if summary["session_id"] and summary["session_id"] == Path(native_log).stem:
                session, cwd = summary["session_id"], short((boundary or {}).get("cwd"), 1000) or (
                    cwd if summary["session_id"] == launch.get("session_id") else None)
        result["native_context"] = native_context(native_log, session, cwd or Path(directory).parent.parent)
    prompt = target / "prompt.txt"
    if prompt.is_file() and not prompt.is_symlink():
        digest = hashlib.sha256()
        size = 0
        with prompt.open("rb") as stream:
            while chunk := stream.read(65536):
                digest.update(chunk)
                size += len(chunk)
        result["prompt"] = {"bytes": size, "sha256": digest.hexdigest()}
    return result
