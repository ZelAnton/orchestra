"""Public provider output, separate from protocol parsing and private reasoning."""

from collections import OrderedDict
import json
import sys
import unicodedata


def terminal_text(value):
    return "".join(c if c in "\n\t" or not unicodedata.category(c).startswith("C") else " "
                   for c in str(value))


def text_content(value):
    if isinstance(value, str):
        return value
    if isinstance(value, list):
        return "\n".join(block.get("text", "") for block in value
                         if isinstance(block, dict) and block.get("type") in ("text", "inputText")
                         and isinstance(block.get("text"), str))
    return ""


class LiveOutput:
    """Cap each displayed item; final snapshots fill gaps without echoing deltas."""

    LIMIT = 65536
    ITEMS = 256

    def __init__(self, role):
        self.role = role
        self.items = OrderedDict()
        self.open_key = None
        self.message_id = "message"
        self.blocks = {}

    def boundary(self):
        if self.open_key is not None:
            print(flush=True)
            self.open_key = None

    def write(self, key, label, value):
        text = terminal_text(value)
        if not text:
            return
        if self.open_key != key:
            self.boundary()
        for part in text.splitlines(keepends=True):
            if self.open_key is None:
                sys.stdout.write(f"  [{self.role}/{label}] ")
            sys.stdout.write(part)
            self.open_key = None if part.endswith("\n") else key
        sys.stdout.flush()

    def feed(self, key, label, value, final=False, message=False):
        if not isinstance(value, str):
            return
        if key not in self.items:
            if len(self.items) >= self.ITEMS:
                self.items.popitem(last=False)
            self.items[key] = {"text": "", "used": 0, "printed": 0, "limited": False, "json": None, "final": None}
        item = self.items[key]
        self.items.move_to_end(key)
        if item["limited"]:
            return
        previous = item["text"]
        if final:
            if value == item["final"]:
                return
            delta = value[len(previous):] if value.startswith(previous) else value
            item["final"] = value[:self.LIMIT]
        else:
            delta = value
        remaining = self.LIMIT - item["used"]
        chunk = delta[:remaining]
        item["used"] += len(chunk)
        item["text"] = value[:self.LIMIT] if final else previous + chunk
        if message and item["json"] is None and item["text"].strip():
            item["json"] = item["text"].lstrip().startswith(("{", "`"))
        visible = ""
        if not item["json"]:
            visible = chunk
        elif final:
            # Structured final reports are rendered only after workflow validation.
            raw = value.strip().removeprefix("```json").removeprefix("```").removesuffix("```").strip()
            try:
                report = json.loads(raw)
            except ValueError:
                report = None
            if not isinstance(report, dict) or not {"status", "summary", "description"} <= report.keys():
                visible = item["text"] if not item["printed"] else chunk
        printable = self.LIMIT - item["printed"]
        self.write(key, label, visible[:printable])
        item["printed"] += len(visible[:printable])
        if len(delta) > remaining or len(visible) > printable:
            self.write(key, label, "\n[display truncated; full output is in protocol.jsonl]\n")
            item["limited"] = True
        if final:
            self.boundary()

    def action(self, key, name, arguments):
        if isinstance(arguments, dict):
            detail = json.dumps(arguments, ensure_ascii=False)
        else:
            detail = str(arguments or "")
        self.feed("action:" + key, "action", f"{name} {detail}".rstrip(), final=True)

    def event(self, event):
        if not isinstance(event, dict):
            return
        method = event.get("method", "")
        params = event.get("params") or {}
        if not isinstance(params, dict):
            return
        if method in ("item/agentMessage/delta", "item/commandExecution/outputDelta"):
            agent = method == "item/agentMessage/delta"
            self.feed(("message:" if agent else "output:") + str(params.get("itemId", "unknown")),
                      "message" if agent else "output", params.get("delta", ""), message=agent)
        elif method in ("item/started", "item/completed"):
            item = params.get("item") or {}
            if not isinstance(item, dict):
                return
            key, kind = str(item.get("id", "unknown")), item.get("type")
            done = method == "item/completed"
            if kind == "agentMessage" and done:
                self.feed("message:" + key, "message", item.get("text", ""), final=True, message=True)
            elif kind == "commandExecution":
                self.action(key, "command", item.get("command", ""))
                if done:
                    self.feed("output:" + key, "output", item.get("aggregatedOutput") or "", final=True)
                    self.feed("exit:" + key, "command", f"exit={item.get('exitCode')} status={item.get('status')}", final=True)
            elif kind == "fileChange":
                changes = item.get("changes") or []
                self.action(key, "files", [c.get("path") for c in changes if isinstance(c, dict)])
                if done:
                    self.feed("output:" + key, "files", "\n".join(c.get("diff", "") for c in changes
                              if isinstance(c, dict) and isinstance(c.get("diff"), str)), final=True)
                    self.feed("exit:" + key, "files", str(item.get("status", "completed")), final=True)
            elif kind == "mcpToolCall":
                self.action(key, f"{item.get('server', '')}/{item.get('tool', 'tool')}", item.get("arguments"))
                if done:
                    result = item.get("result") or {}
                    self.feed("output:" + key, "tool", text_content(result.get("content")) if isinstance(result, dict) else "", final=True)
                    if isinstance(result, dict) and result.get("structuredContent") is not None:
                        self.feed("structured:" + key, "tool", json.dumps(result["structuredContent"], ensure_ascii=False), final=True)
                    if item.get("error"):
                        self.feed("error:" + key, "error", str(item["error"]), final=True)
                    self.feed("exit:" + key, "tool", str(item.get("status", "completed")), final=True)
            elif kind == "dynamicToolCall":
                self.action(key, item.get("tool", "tool"), item.get("arguments"))
                if done:
                    self.feed("output:" + key, "tool" if item.get("success") else "error", text_content(item.get("contentItems")), final=True)
            elif kind == "functionCallOutput" and done:
                self.feed("output:" + key, "tool", text_content(item.get("output")), final=True)
            elif kind == "imageView":
                self.action(key, "view image", item.get("path"))
            elif kind == "plan" and done:
                self.feed("plan:" + key, "plan", item.get("text", ""), final=True)
            elif kind == "webSearch":
                self.action(key, "search", item.get("action") or item.get("query"))
        elif method == "turn/plan/updated":
            self.feed("plan:" + str(params.get("turnId")), "plan", "\n".join(
                f"{p.get('status')}: {p.get('step')}" for p in params.get("plan", []) if isinstance(p, dict)), final=True)
        elif method == "error" or event.get("error"):
            self.feed("error", "error", str(params.get("error") or event.get("error")), final=True)
        elif method in ("warning", "configWarning"):
            self.feed("warning", "warning", str(params.get("message") or params.get("summary")) + " " + str(params.get("details") or ""), final=True)
        elif method == "turn/completed":
            turn = params.get("turn") or {}
            if turn.get("error"):
                self.feed("turn-error", "error", str(turn["error"]), final=True)
        elif event.get("type") == "stream_event":
            stream = event.get("event") or {}
            kind = stream.get("type")
            if kind == "message_start":
                self.message_id = str(stream.get("message", {}).get("id", "message"))
                self.blocks = {}
            index = stream.get("index", 0)
            if kind == "content_block_start":
                block = stream.get("content_block") or {}
                if block.get("type") == "tool_use":
                    if len(self.blocks) < self.ITEMS:
                        self.blocks[index] = {"type": "tool_use", "id": block.get("id"),
                                              "name": block.get("name", "tool"), "partial": ""}
                    self.feed("tool-start:" + str(block.get("id")), "action", str(block.get("name", "tool")), final=True)
                elif block.get("type") == "text":
                    self.feed(f"message:{self.message_id}:{index}", "message", block.get("text", ""), message=True)
            elif kind == "content_block_delta":
                delta = stream.get("delta") or {}
                if delta.get("type") == "text_delta":
                    self.feed(f"message:{self.message_id}:{index}", "message", delta.get("text", ""), message=True)
                elif delta.get("type") == "input_json_delta" and index in self.blocks:
                    block = self.blocks[index]
                    block["partial"] = (block["partial"] + delta.get("partial_json", ""))[:self.LIMIT]
            elif kind == "content_block_stop":
                block = self.blocks.pop(index, {})
                if block.get("type") == "tool_use" and block.get("partial"):
                    try:
                        arguments = json.loads(block["partial"])
                    except ValueError:
                        arguments = "[arguments incomplete; waiting for tool event]"
                    self.action(str(block.get("id")), block.get("name", "tool"), arguments)
                self.boundary()
        elif event.get("type") == "assistant":
            message = event.get("message") or {}
            for index, block in enumerate(message.get("content", [])):
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text":
                    self.feed(f"message:{message.get('id', self.message_id)}:{index}", "message", block.get("text", ""), final=True, message=True)
                elif block.get("type") == "tool_use":
                    self.action(str(block.get("id", index)), block.get("name", "tool"), block.get("input"))
        elif event.get("type") == "user":
            content = (event.get("message") or {}).get("content", [])
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "tool_result":
                        self.feed("result:" + str(block.get("tool_use_id")), "error" if block.get("is_error") else "output",
                                  text_content(block.get("content")), final=True)
        elif event.get("type") == "result" and event.get("is_error"):
            self.feed("result-error", "error", str(event.get("errors") or event.get("result")), final=True)
        elif event.get("type") == "system" and event.get("subtype") == "api_retry":
            self.feed("retry", "retry", f"attempt={event.get('attempt')} delay_ms={event.get('retry_delay_ms')} status={event.get('http_status')} {event.get('error', '')}", final=True)

    def report(self, report):
        self.feed("validated-report", "result", report["description"], final=True)
        self.feed("validated-evidence", "checks", "\n".join(report["evidence"]), final=True)
