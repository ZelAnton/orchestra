"""Runtime-owned publication of exact reviewed paths; providers never write Git."""

import os
from pathlib import Path
import queue
import tempfile
import time
import uuid

from cycle_state import Blocked, digest, encode
from cycle_transport import Process


# A sync of a parallel member has its own logs, progress text, and codes. It publishes nothing.
PURPOSES = {"publication": ("publication", "Publishing", "publication-git", "publication-timeout"),
            "sync": ("sync", "Sync of", "parallel-sync-git", "parallel-sync-timeout")}


def run_git(cycle, *args, repo=None, purpose="publication", cwd=None, options=()):
    """Keep Git hooks inside the same stop/heartbeat/process containment contract.

    CWD runs the command in another worktree of REPO. OPTIONS come before the Git command.
    """
    repo = repo or cycle.repo
    folder, caption, failed, timeout = PURPOSES[purpose]
    directory = cycle.store.directory / folder
    directory.mkdir(parents=True, exist_ok=True)
    if cycle.progress:
        cycle.progress.runtime("publish" if purpose == "publication" else "git")
        cycle.progress.note(f"{caption} {repo.root.name}: git {args[0]}; no model is running")
    try:
        code, tail = run_contained(cycle, ["git", "--literal-pathspecs", *options, "-C", str(cwd or repo.root), *args],
                                   repo.root, directory / (uuid.uuid4().hex + ".jsonl"),
                                   lambda: Blocked(timeout, f"Git {purpose} exceeded its deadline; work was preserved."))
    finally:
        if cycle.progress:
            cycle.progress.finish()
    if code:
        raise Blocked(failed, f"git {args[0]} failed ({code}): {tail}")


def run_contained(cycle, argv, cwd, log, timed_out, deadline=21600, env=None, control=None):
    """Run ARGV under the stop request, the heartbeat, and the process containment of the run.

    Return the exit code and the end of the output. TIMED_OUT gives the error at the deadline.
    CONTROL is the process control, by default the control of the run.
    """
    process = Process(argv, cwd, log, cycle.heartbeat, getattr(cycle.transport, "lock_fd", None), env=env,
                      deadline=deadline, control=control or cycle.control)
    tail = ""
    try:
        process.proc.stdin.close()
        while process.proc.poll() is None or not process.events.empty():
            cycle.heartbeat()
            if time.monotonic() >= process.deadline:
                raise timed_out()
            try:
                label, line = process.events.get(timeout=0.25)
            except queue.Empty:
                continue
            if line is not None:
                text = line.decode("utf-8", errors="replace")
                tail = (tail + text)[-4000:]
                process.log.write(encode({"stream": label, "line": text}) + b"\n")
                process.log.flush()
        return process.proc.returncode, tail
    finally:
        process.close()  # Failed containment must override any retryable error.


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
    if cycle.state.get("parallel_member"):
        from focus_parallel import contains
        needed = not contains(cycle, cycle.repo, remote, head)  # Other writers can push on top of the stage commit.
    else:
        needed = cycle.remote_head(remote) != head
    if needed:
        run_git(cycle, "push", "--no-follow-tags", "--recurse-submodules=no",
                cycle.state["publication_push_url"], head + ":refs/heads/main")
    if not cycle.reconcile_publish():
        raise Blocked("publication-unconfirmed", "Remote main did not confirm the reviewed commit.")
