"""Runtime-owned publication of exact reviewed paths; providers never write Git."""

import os
from pathlib import Path
import queue
import tempfile
import time
import uuid

from cycle_state import Blocked, digest, encode
from cycle_transport import Process


def run_git(cycle, *args):
    """Keep Git hooks inside the same stop/heartbeat/process containment contract."""
    directory = cycle.store.directory / "publication"
    directory.mkdir(parents=True, exist_ok=True)
    if cycle.progress:
        cycle.progress.runtime("publish")
        cycle.progress.note(f"Publishing {cycle.repo.root.name}: git {args[0]}; no model is running")
    process = Process(["git", "--literal-pathspecs", "-C", str(cycle.repo.root), *args],
                      cycle.repo.root, directory / (uuid.uuid4().hex + ".jsonl"), cycle.heartbeat,
                      getattr(cycle.transport, "lock_fd", None), control=cycle.control)
    tail = ""
    try:
        process.proc.stdin.close()
        while process.proc.poll() is None or not process.events.empty():
            cycle.heartbeat()
            if time.monotonic() >= process.deadline:
                raise Blocked("publication-timeout", "Git publication exceeded its deadline; work was preserved.")
            try:
                label, line = process.events.get(timeout=0.25)
            except queue.Empty:
                continue
            if line is not None:
                text = line.decode("utf-8", errors="replace")
                tail = (tail + text)[-4000:]
                process.log.write(encode({"stream": label, "line": text}) + b"\n")
                process.log.flush()
        if process.proc.returncode:
            raise Blocked("publication-git", f"git {args[0]} failed ({process.proc.returncode}): {tail}")
    finally:
        process.close()  # Failed containment must override any retryable Git error.
        if cycle.progress:
            cycle.progress.finish()


def commit_reviewed(cycle, subject):
    cycle.validate_publication_commit()
    owned = set(cycle.publication_paths())
    paths = sorted(set(cycle.repo.dirty_paths()) - set(cycle.state["protected"]))
    if not paths:
        return
    if not set(paths) <= owned:
        raise Blocked("unreviewed-staging", "Publication contains paths outside the reviewed stage.")
    directory = cycle.store.directory / "publication"
    directory.mkdir(parents=True, exist_ok=True)
    cycle.store.artifact("publication/scope-" + uuid.uuid4().hex + ".json", encode({
        "paths": paths, "head": cycle.repo.text("rev-parse", "HEAD"),
        "reviewed_sha256": digest(encode(cycle.snapshot(cycle.state["reviewed"])))}))
    with tempfile.TemporaryDirectory(prefix="paths-", dir=directory) as temporary:
        pathfile = Path(temporary) / "paths"
        pathfile.write_bytes(b"".join(os.fsencode(name) + b"\0" for name in paths))
        pathspec = ["--pathspec-from-file=" + str(pathfile), "--pathspec-file-nul"]
        run_git(cycle, "add", "-A", *pathspec)
        cycle.validate_publication_commit()
        # --only ignores unrelated staged work. Literal NUL-delimited file names
        # cannot expand into sibling directories, wildcards or Git pathspec magic.
        run_git(cycle, "commit", "--only", "-m", subject, *pathspec)
    if not cycle.validate_publication_commit():
        raise Blocked("uncommitted-stage", "Git did not commit the complete reviewed stage.")


def push_reviewed(cycle):
    if not cycle.validate_publication_commit():
        raise Blocked("uncommitted-stage", "Review scope must be fully committed before push.")
    head = cycle.repo.text("rev-parse", "HEAD")
    remote = cycle.state["remote"]
    if cycle.repo.remote() != remote or cycle.repo.push_url(remote) != cycle.state["publication_push_url"]:
        raise Blocked("remote-changed", "The prepared publication destination changed before push.")
    if cycle.remote_head(remote) != head:
        run_git(cycle, "push", "--no-follow-tags", "--recurse-submodules=no",
                cycle.state["publication_push_url"], head + ":refs/heads/main")
    if not cycle.reconcile_publish():
        raise Blocked("publication-unconfirmed", "Remote main did not confirm the reviewed commit.")
