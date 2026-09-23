"""Durable, invocation-addressed operator messages; no provider side effects."""

import json
from pathlib import Path
import re
import threading
import time
import uuid

from cycle_state import Blocked, digest, encode
from focus_control import FocusStop


class MessagePending(FocusStop):
    """An operator delivery decision, never a reason to launch a healer."""


class Messages:
    def __init__(self, store):
        self.store = store
        self.lock = threading.RLock()

    def directory(self, iteration):
        path = self.store.directory / "messages" / f"{iteration:06d}"
        if not path.resolve().is_relative_to(self.store.directory.resolve()):
            raise Blocked("message-path", "Message storage resolves outside focus state.")
        return path

    def records(self, iteration, invocation=None):
        with self.lock:
            result = []
            for path in sorted(self.directory(iteration).glob("*.json")):
                try:
                    if path.is_symlink():
                        raise ValueError("symlink")
                    with path.open("rb") as source:
                        raw = source.read(1048577)
                    if len(raw) > 1048576:
                        raise ValueError("oversized record")
                    record = json.loads(raw)
                    identity = record["identity"]
                    if (path.stem != identity["id"] or not re.fullmatch(r"[0-9a-f]{32}", identity["id"])
                            or identity["iteration"] != iteration
                            or digest(encode(identity)) != record["sha256"]
                            or digest(encode({k: v for k, v in record.items() if k != "checksum"})) != record["checksum"]
                            or record["status"] not in ("queued", "sending", "accepted", "rejected", "discarded")):
                        raise ValueError("identity or checksum mismatch")
                except (OSError, ValueError, TypeError, KeyError) as error:
                    raise Blocked("message-drift", "A saved operator message is invalid or changed.") from error
                if invocation is None or identity["invocation"] == invocation:
                    result.append(record)
            return sorted(result, key=lambda item: (item["identity"].get("sequence", 0),
                                                   item["identity"]["created"], item["identity"]["id"]))

    def write(self, record):
        record = {key: value for key, value in record.items() if key != "checksum"}
        record["checksum"] = digest(encode(record))
        identity = record["identity"]
        path = self.directory(identity["iteration"]) / (identity["id"] + ".json")
        self.store.artifact(str(path.relative_to(self.store.directory)), encode(record))

    def add(self, target, text):
        if not text.strip() or len(text.encode("utf-8")) > 65536 or "\0" in text:
            raise ValueError("Use nonempty text without NUL, at most 64 KiB.")
        with self.lock:
            if target["role"] not in ("code", "sol", "claude", "astra", "coordinate", "heal"):
                raise ValueError("This role cannot receive operator instructions.")
            records = self.records(target["iteration"])
            if len(records) >= 128:
                raise ValueError("The stage has 128 saved messages; reconcile it before adding more.")
            identity = dict(target, text=text, id=uuid.uuid4().hex, created=time.time(), sequence=len(records) + 1)
            record = {"identity": identity, "sha256": digest(encode(identity)), "status": "queued"}
            self.write(record)
            return record

    def update(self, record, status, detail=""):
        with self.lock:
            record = dict(record, status=status, detail=detail[:4000], updated=time.time())
            self.write(record)
            return record

    def unresolved(self, iteration, invocation=None):
        return [item for item in self.records(iteration, invocation)
                if item["status"] not in ("accepted", "discarded")]

    def accepted(self, iteration, invocation=None):
        return [item for item in self.records(iteration, invocation) if item["status"] == "accepted"]

    def resolve(self, iteration, prefix, retry=False, invocation=None):
        if not re.fullmatch(r"[0-9a-f]{6,32}", prefix):
            raise ValueError("Supply an unambiguous message ID (at least six hex characters).")
        with self.lock:
            matches = [item for item in self.unresolved(iteration) if item["identity"]["id"].startswith(prefix)]
            if len(matches) != 1:
                raise ValueError("Message ID does not identify exactly one unresolved message.")
            record = matches[0]
            if retry and record["identity"]["invocation"] != invocation:
                raise ValueError("The target invocation is no longer pending; discard and use /correct instead.")
            return self.update(record, "queued" if retry else "discarded", "Explicit operator decision")


def message_text(record):
    identity = record["identity"]
    return (f"Operator instruction [focus-message:{identity['id']}] for this SAME invocation. "
            "Keep the current role, stage, permissions and structured report contract. "
            "If this changes a review's scope, perform the full pass against the updated scope.\n\n"
            + identity["text"])
