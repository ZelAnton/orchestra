"""Member repositories with parallel writers: the sync at a stage start and the integration before a push.

Other writers push to remote main of a parallel member at any time. The runtime takes their commits
only at a stage start, and it merges the stage commits with remote main before a push.
"""

import copy
import os
import tempfile

from cycle_state import Blocked, atomic_write, command, digest, encode
from focus_commit import run_git
from focus_reconcile import committed_base
import focus_resolve
from focus_resolve import listing

# Git entry types that a snapshot can seal: a file, an executable file, and a symbolic link.
SEALED_MODES = ("100644", "100755", "120000")
INTEGRATIONS = 3  # Integrations of one member in one publication attempt.


def members(state):
    return list(state.get("parallel") or [])


def ancestor(repo, older, newer):
    result = repo.git("merge-base", "--is-ancestor", older, newer, check=False)
    if result.returncode not in (0, 1):
        raise Blocked("command-failed", f"git merge-base in {repo.root.name}: "
                      + result.stderr.decode("utf-8", errors="replace")[-2000:])
    return result.returncode == 0


def fetch(cycle, repo, remote):
    """Fetch remote main of a member. The fetch shows the progress of the run when a run exists."""
    def progress(attempt, attempts):
        if cycle and cycle.progress:
            cycle.progress.runtime("git")
            cycle.progress.note(f"Fetch of remote main for {repo.root.name} ({attempt}/{attempts}); no model is running.")
        if cycle:
            cycle.heartbeat()
    try:
        return repo.fetch_main(remote, progress=progress)
    finally:
        if cycle and cycle.progress:
            cycle.progress.finish()


def contains(cycle, repo, remote, sha):
    """The confirmation rule: remote main contains SHA."""
    return ancestor(repo, sha, fetch(cycle, repo, remote))


def check_boundary(cycle, repo, remote, known, head, name, retry):
    """At a stage boundary: a lost KNOWN commit is a rewritten remote. Local commits that remote main lacks have diverged."""
    target = fetch(cycle, repo, remote)
    if known and not ancestor(repo, known, target):
        raise rewritten(name, known, retry)
    if not ancestor(repo, head, target):
        raise diverged(name, retry)


def changed(repo, older, newer):
    output = repo.git("diff-tree", "-r", "-z", "--no-renames", "--name-only", older, newer).stdout
    return sorted(os.fsdecode(name) for name in output.split(b"\0") if name)


def unsealable(repo, older, newer):
    """Paths from OLDER to NEWER with an entry type that a snapshot cannot seal, for example a submodule."""
    fields = repo.git("diff-tree", "-r", "-z", "--no-renames", "--raw", older, newer).stdout.split(b"\0")
    paths = []
    # Each entry is ":<old mode> <new mode> <old object> <new object> <status>", then its path.
    for meta, name in zip(fields[0::2], fields[1::2]):
        if not meta:
            continue
        values = meta.decode("ascii").lstrip(":").split()
        if values[4] != "D" and values[1] not in SEALED_MODES:
            paths.append(os.fsdecode(name))
    return sorted(paths)


def dirty(repo):
    """Dirty paths and staged changes. A staged change can equal HEAD in the working tree."""
    paths = set(repo.dirty_paths())
    staged = repo.git("diff", "--cached", "--name-only", "-z", "--no-renames").stdout
    paths.update(name for name in (os.fsdecode(raw) for raw in staged.split(b"\0") if raw) if not repo.runtime_path(name))
    return sorted(paths)


def intent_path(cycle, name):
    return cycle.store.directory / "sync" / ("intent-" + digest(name.encode())[:16] + ".json")


def check_git(repo):
    """The integration needs merge-tree --write-tree, which Git 2.38 added."""
    if repo.git("merge-tree", "--write-tree", "HEAD", "HEAD", check=False).returncode:
        raise Blocked("parallel-git", f"{repo.root.name}: this Git has no merge-tree --write-tree. "
                      "Install Git 2.38 or later. Then run the same command again.")


def sync(cycle, name, retry):
    """Bring remote main of a clean parallel member into its checkout. Return the paths that changed."""
    repo = cycle.repo.repositories[name]
    intent = intent_path(cycle, name)
    paths = dirty(repo)
    if paths:
        note = (" The paths can come from an interrupted sync. Restore them to HEAD to complete it."
                if intent.exists() else "")
        raise Blocked("parallel-dirty", f"{name}: these paths are not committed: {listing(paths)}. "
                      f"This checkout belongs to cc-focus. Move the changes to another clone or remove them.{note} "
                      f"Then run {retry}.")
    remote = repo.remote()
    target = fetch(cycle, repo, remote)
    head = repo.text("rev-parse", "HEAD")
    if target == head:
        intent.unlink(missing_ok=True)
        return []
    if not ancestor(repo, head, target):
        raise diverged(name, retry)
    entries = unsealable(repo, head, target)
    if entries:
        raise Blocked("parallel-unsupported-path", f"{name}: a change of another writer added an entry that cc-focus "
                      f"cannot seal: {listing(entries)}. Remove the entry on remote main in another clone. Then run {retry}.")
    paths = changed(repo, head, target)
    atomic_write(intent, encode({"member": name, "from": head, "to": target}))
    run_git(cycle, "merge", "--ff-only", target, repo=repo, purpose="sync")
    intent.unlink()
    return paths


def diverged(name, retry):
    return Blocked("parallel-diverged", f"{name}: local main has commits that remote main does not have, "
                   "or the remote history changed. Save the local commits that you need, for example on a branch. "
                   f"Then make local main equal to remote main, and run {retry}.")


def rewritten(name, commit, retry):
    return Blocked("parallel-remote-rewritten", f"{name}: remote main no longer contains commit {commit[:12]}. "
                   "Restore remote main so that it contains this commit. Do not reset local main, because it holds "
                   f"the stage commits. Then run {retry}.")


def integrate(cycle, name):
    """Merge the stage commits of a parallel target with remote main, without a push.

    Return False when remote main already contains local main, so the member needs no push.
    """
    resume(cycle, name)
    state, repo = cycle.state, cycle.repo.repositories[name]
    check_git(repo)  # A run can resume in the middle of a stage, after its admission.
    focus_resolve.retry_cleanup(cycle)
    base = state["baseline"]["head"][name]
    head = repo.text("rev-parse", "HEAD")
    target = fetch(cycle, repo, state["publication_targets"][name]["remote"])
    if ancestor(repo, head, target):
        return False
    if target == base or (ancestor(repo, base, target) and ancestor(repo, target, head)):
        return True  # The second case follows an earlier partial push.
    if not ancestor(repo, base, target):
        raise rewritten(name, base, cycle.retry_command())
    merged = repo.git("merge-tree", "--write-tree", "--no-messages", "-z", target, head, check=False)
    resolution = None
    if merged.returncode == 1:
        tree, entries = focus_resolve.conflict_entries(merged.stdout)
        paths = sorted(entries)
        rules = ((state.get("resolvers") or {}).get(name) or {}).get("rules")
        if not entries:
            # Git names some conflicts only in its messages, for example a collision of directory renames.
            paths = focus_resolve.message_paths(repo.git("merge-tree", "--write-tree", "-z", target, head, check=False).stdout)
            raise focus_resolve.conflict(cycle, name, repo, base, head, paths, paths, bool(rules))
        plan, uncovered = focus_resolve.classify(repo, rules, target, head, tree, entries) if rules else ({}, paths)
        if uncovered:
            raise focus_resolve.conflict(cycle, name, repo, base, head, paths, uncovered, bool(rules))
        unclean = dirty(repo)
        if unclean:
            raise Blocked("parallel-dirty", f"{name}: these paths are not committed: {listing(unclean)}. "
                          "A merge resolver needs a clean checkout. This checkout belongs to cc-focus. "
                          f"Move the changes to another clone or remove them. Then run {cycle.retry_command()}.")
        tree, resolution = focus_resolve.resolve(cycle, name, repo, base, target, head, tree, plan)
    elif merged.returncode or not merged.stdout.split(b"\0")[0]:
        raise Blocked("publication-git", f"git merge-tree failed in {name}: "
                      + merged.stderr.decode("utf-8", errors="replace")[-2000:])
    else:
        tree = merged.stdout.split(b"\0")[0].decode("ascii")
    try:
        result = commit(cycle, repo, tree, target, head)
        stage = set(cycle.repo.local_paths(name, cycle.publication_paths()))
        outside = sorted(set(changed(repo, target, result)) - stage)
        if outside:
            raise Blocked("parallel-merge-conflict", f"{name}: the merge moves stage changes to paths outside the stage: "
                          f"{listing(outside)}. A rename by another writer can cause this. Change remote main in another "
                          f"clone so that the stage files keep their names. Then run {cycle.retry_command()}.")
        entries = unsealable(repo, base, target)
        if entries:
            raise Blocked("parallel-unsupported-path", f"{name}: a change of another writer added an entry that cc-focus "
                          f"cannot seal: {listing(entries)}. Remove the entry on remote main in another clone. "
                          f"Then run {cycle.retry_command()}.")
    except BaseException as error:
        if resolution is not None:
            # The record of the resolution must not stay: resume would remove it, but a recovery agent must not see it.
            resolution["error"] = f"{type(error).__name__}: {error}"
            focus_resolve.save_evidence(cycle, resolution)
            state["parallel_integrations"].pop(name, None)
            cycle.save()
        raise
    # The record comes before the checkout, so an interruption can complete or undo the integration.
    record = {"base": base, "upstream": target, "local": head, "result": result,
              "remote_paths": changed(repo, base, target), "step": "saved"}
    if resolution is not None:
        resolution["result"] = result
        record.update(resolved={path: item["rule"] for path, item in resolution["paths"].items()},
                      evidence=focus_resolve.save_evidence(cycle, resolution))
    state.setdefault("parallel_integrations", {})[name] = record  # It replaces a record of a resolution.
    cycle.save()
    resume(cycle, name)
    return True


def commit(cycle, repo, tree, parent, head):
    """One commit with the merged tree on PARENT. It has the message and the author of HEAD."""
    message = repo.git("log", "-1", "--format=%B", head).stdout
    name, email, date = repo.text("log", "-1", "--format=%an%x00%ae%x00%ad", "--date=raw", head).split("\0")
    env = dict(os.environ, GIT_AUTHOR_NAME=name, GIT_AUTHOR_EMAIL=email, GIT_AUTHOR_DATE=date)
    sign = []
    if repo.git("config", "--bool", "--get", "commit.gpgSign", check=False).stdout.decode().strip() == "true":
        key = repo.git("config", "--get", "user.signingKey", check=False).stdout.decode().strip()
        sign = ["-S" + key] if key else ["-S"]
    directory = cycle.store.directory / "publication"
    directory.mkdir(parents=True, exist_ok=True)
    # commit-tree runs no hook. A signature program gets the same timeout as a remote query.
    with tempfile.NamedTemporaryFile("wb", dir=directory, prefix="message-", delete=False) as stream:
        stream.write(message)
    try:
        result = command(["git", "commit-tree", tree, "-p", parent, "-F", stream.name, *sign],
                         repo.root, timeout=120, check=False, env=env)
    finally:
        os.unlink(stream.name)
    if result.returncode:
        raise Blocked("publication-git", f"git commit-tree failed in {repo.root.name}: "
                      + result.stderr.decode("utf-8", errors="replace")[-2000:])
    return result.stdout.decode().strip()


def resume(cycle, name):
    """Complete an open integration record. It runs before any publication check of the member."""
    record = cycle.state.get("parallel_integrations", {}).get(name)
    if not record or record["step"] == "complete":
        return
    repo = cycle.repo.repositories[name]
    if record["step"] == "resolving":
        # The member checkout did not change. The next integration starts again and runs the resolvers again.
        focus_resolve.discard(cycle, name, repo, record["worktree"])
        return
    head = repo.text("rev-parse", "HEAD")
    moved = cycle.state["baseline"]["head"][name] == record["upstream"]
    if head == record["local"] and not moved:
        run_git(cycle, "checkout", "-B", "main", record["result"], repo=repo)
        head = record["result"]
    if head != record["result"]:
        raise Blocked("parallel-integration-state", f"{name}: local main {head[:12]} is not a commit of the integration "
                      f"record. Restore local main to the stage commit {record['local'][:12]} or to the integration "
                      f"commit {record['result'][:12]}. Then run {cycle.retry_command()}.")
    if not moved:
        keys = ("baseline", "reviewed", "parallel_remote_files", "publication_prepared")
        before = {key: copy.deepcopy(cycle.state[key]) for key in keys if key in cycle.state}
        try:
            move_base(cycle, name, record)
        except BaseException:
            # Restore the state, also after a failed save. The next attempt integrates again from the stage commit.
            for key in keys:
                cycle.state.pop(key, None)
            cycle.state.update(before)
            run_git(cycle, "checkout", "-B", "main", record["local"], repo=repo)
            del cycle.state["parallel_integrations"][name]
            cycle.save()
            raise
    record["step"] = "complete"
    # A later integration of the same publication replaces the merged commit, also without a conflict, and its tree
    # keeps the earlier resolutions. One entry per member names all resolved paths and the last merged commit.
    resolutions = cycle.state.get("publication_resolutions", [])
    entry = next((entry for entry in resolutions if entry["member"] == name), None)
    if entry is None and record.get("resolved"):
        entry = {"member": name, "paths": {}, "evidence": []}
        cycle.state.setdefault("publication_resolutions", []).append(entry)
    if entry is not None:
        entry["result"] = record["result"]
        if record.get("resolved"):
            entry["paths"].update(record["resolved"])
            entry["evidence"].append(record.get("evidence"))
    cycle.save()


def move_base(cycle, name, record):
    """Move the base of the member from B to R. All values exist before the one save.

    A catch-up during the reviews has no reviewed snapshot yet. Then only the baseline moves.
    """
    state, repo = cycle.state, cycle.repo.repositories[name]
    current = cycle.repo.snapshot()
    paths = record["remote_paths"]
    upstream = committed_base(repo, paths, cycle.repo.member_snapshot(name, current), revision=record["upstream"])
    baseline = copy.deepcopy(state["baseline"])
    reviewed = copy.deepcopy(state["reviewed"]) if state.get("reviewed") else None
    baseline["head"][name] = record["upstream"]
    for path in paths:
        full = name + "/" + path
        for snapshot, value in ((baseline, upstream[path]), (reviewed, current["files"].get(full))):
            if snapshot is None:
                continue
            if value is None:
                snapshot["files"].pop(full, None)
            else:
                snapshot["files"][full] = value
    prepared = state.get("publication_prepared")
    if prepared and reviewed is not None:
        prepared = dict(prepared, reviewed_sha256=digest(encode(cycle.snapshot(reviewed))))
    state.update(baseline=baseline, reviewed=reviewed)
    if state.get("review_run"):
        # The values of R. A path with a change of the stage differs from them and still queues a target.
        state.setdefault("parallel_remote_files", {}).update({name + "/" + path: upstream[path] for path in paths})
    if prepared:
        state["publication_prepared"] = prepared
    cycle.save()


def catch_up(cycle, name):
    """During a stage: bring remote main into a parallel member, and move the stage base. Return the changed paths.

    A blocked step can need commits of other writers, for example when a check compares two members.
    The member moves only when its HEAD is in remote main and no remote change touches a local change.
    Otherwise it keeps its checkout, and the publication merges it. The integration record makes the move
    recoverable: resume completes or undoes it.
    """
    state, repo = cycle.state, cycle.repo.repositories[name]
    record = state.get("parallel_integrations", {}).get(name)
    if record and record["step"] != "complete":
        return []
    base, head = state["baseline"]["head"][name], repo.text("rev-parse", "HEAD")
    target = fetch(cycle, repo, repo.remote())
    if (ancestor(repo, target, head) or not ancestor(repo, head, target) or not ancestor(repo, base, target)
            or unsealable(repo, head, target)):
        return []
    paths = changed(repo, head, target)
    if set(paths) & set(dirty(repo)):
        return []
    state.setdefault("parallel_integrations", {})[name] = {
        "base": base, "upstream": target, "local": head, "result": target,
        "remote_paths": changed(repo, base, target), "step": "saved", "catch_up": True}
    cycle.save()
    return resume_catch_up(cycle, name)


def resume_catch_up(cycle, name):
    """Complete an open catch-up record. Return the paths that the move changed.

    When the checkout fails and HEAD did not move, nothing changed, so the record goes.
    """
    record = cycle.state["parallel_integrations"][name]
    repo = cycle.repo.repositories[name]
    try:
        resume(cycle, name)
    except Blocked:
        if record.get("step") == "saved" and repo.text("rev-parse", "HEAD") == record["local"]:
            cycle.state["parallel_integrations"].pop(name, None)
            cycle.save()
        raise
    return changed(repo, record["local"], record["result"])


def push(cycle, name):
    """Push a parallel target. A moved remote main gives another integration, at most three per attempt."""
    from focus_commit import push_reviewed
    repo = cycle.repo.repositories[name]
    remote = cycle.state["publication_targets"][name]["remote"]
    for _ in range(INTEGRATIONS):
        if integrate(cycle, name):
            try:
                push_reviewed(cycle.member(name))
                return
            except Blocked as error:
                if error.code != "publication-git":
                    raise
                target, head = fetch(cycle, repo, remote), repo.text("rev-parse", "HEAD")
                if ancestor(repo, head, target):
                    pass  # Another writer pushed on top of the stage commit. The confirmation follows.
                elif ancestor(repo, target, head):
                    raise  # Remote main did not move: for example credentials or branch protection.
                else:
                    continue
        if not cycle.member(name).reconcile_publish():
            raise Blocked("publication-unconfirmed", f"{name}: remote main does not contain the stage commit.")
        return
    raise Blocked("parallel-remote-busy", f"{name}: remote main changed {INTEGRATIONS} times during the publication. "
                  f"Run {cycle.retry_command()} later.")


def record_sync(cycle, paths_by_member):
    """Keep the values that syncs brought, so a review campaign does not requeue a target for them."""
    if not any(paths_by_member.values()) or not cycle.state.get("review_run"):
        return
    current = cycle.repo.snapshot()
    remote_files = cycle.state.setdefault("parallel_remote_files", {})
    for name, paths in paths_by_member.items():
        for path in paths:
            remote_files[name + "/" + path] = current["files"].get(name + "/" + path)
