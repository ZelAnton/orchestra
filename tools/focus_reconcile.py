"""Explicit operator handover of changed protected files and project context."""

import copy
import json
import os
from pathlib import Path

from cycle_state import Blocked, Repository, digest, encode


SCHEMA = "orchestra/focus-reconcile@1"


def state_fingerprint(state):
    # Command admission saves a timestamp and fresh leases, without changing work.
    return digest(encode({key: value for key, value in state.items()
                          if key not in ("updated", "lease_owner", "lease_owners", "repository_leases")}))


def committed_base(repo, names, snapshot, revision="HEAD"):
    """Use checkout bytes at a Git revision for whole-file ownership transfer."""
    wanted, bases = set(names), dict.fromkeys(names)
    for raw in repo.git("ls-tree", "-r", "-z", revision).stdout.split(b"\0"):
        if not raw:
            continue
        metadata, raw_name = raw.split(b"\t", 1)
        name = os.fsdecode(raw_name)
        if name not in wanted:
            continue
        mode, kind, oid = metadata.decode("ascii").split()
        if kind != "blob" or mode not in ("100644", "100755", "120000"):
            raise Blocked("reconcile-path", "Cannot hand over a non-file Git entry: " + name)
        if mode == "120000":
            data = repo.git("cat-file", "blob", oid).stdout
            prefix = "link:"
        else:
            # Match checkout bytes (including eol/filter rules), not raw Git bytes.
            data = repo.git("cat-file", "--filters", "--path=" + name, oid).stdout
            prefix = "x:" if mode == "100755" else "f:"
            if os.name == "nt":
                # Windows stat exposes platform/extension permissions, not Git's bit.
                prefix = "x:" if snapshot["files"].get(name, "").startswith("x:") else "f:"
        bases[name] = prefix + digest(data)
    return bases


def prepare(cycle):
    state, repo = cycle.state, cycle.repo
    if (state.get("status") == "complete"
            or state["phase"] not in ("code", "astra", "claude")
            or (state["phase"] != "code" and not state.get("code_started"))
            or state.get("published") or state.get("publication_started")):
        raise Blocked("reconcile-phase", "Reconciliation requires a code/review iteration before publication; it cannot rewind commit, push or CI.")
    if cycle.messages.unresolved(state["iteration"]):
        raise Blocked("reconcile-messages", "Resolve queued/uncertain operator messages before reconciling their stage.")
    if repo.paused() or (cycle.control and cycle.control.boundary()):
        raise Blocked("recovery-paused", "Clear the operator PAUSE/stop before reconciling this stage.")
    cycle.validate_corrections()
    repo.assert_main()
    if hasattr(repo, "validate_state"):
        repo.validate_state(state)
    current = cycle.snapshot()
    if current["head"] != state["baseline"]["head"]:
        raise Blocked("reconcile-head", "Repository HEAD changed since this stage started; reconcile publication first.")
    if repo.index_entries(state["protected"]) != state["protected_index"]:
        raise Blocked("reconcile-index", "Protected index entries changed; preserve the original staging before handing over files.")
    rows = []
    for path in cycle.changes(state["baseline"], current):
        loose = hasattr(repo, "owner") and repo.owner(path) is None
        if not loose and path not in state["protected"]:
            continue
        before, after = state["baseline"]["files"].get(path), current["files"].get(path)
        if loose and any(value and value.startswith("link:") for value in (before, after)):
            raise Blocked("reconcile-symlink", "Shared context handover requires regular files, not symlinks: " + path)
        rows.append({"path": path, "action": "refresh-context" if loose else "adopt-file",
                     "before": before, "after": after})
    if not rows:
        raise Blocked("reconcile-empty", "No changed shared context or protected files need reconciliation.")
    adopted = [row["path"] for row in rows if row["action"] == "adopt-file"]
    if hasattr(repo, "repositories"):
        bases = {}
        for name, member in repo.repositories.items():
            local = repo.local_paths(name, adopted)
            if local:
                bases.update({name + "/" + path: value for path, value in
                              committed_base(member, local, repo.member_snapshot(name, current)).items()})
    else:
        bases = committed_base(repo, adopted, current) if adopted else {}
    for row in rows:
        if row["action"] == "adopt-file":
            row["publication_base"] = bases[row["path"]]
    continuation = ("Sessions and the current stage are preserved." if state.get("code_started") else
                    "Sessions and the current iteration are preserved. Coding has not begun: select work from the current project plan, not the previous published stage.")
    return {"schema": SCHEMA, "root": str(repo.root), "iteration": state["iteration"],
            "task": state.get("task"), "state_sha256": state_fingerprint(state),
            "snapshot_sha256": digest(encode(current)), "changes": rows,
            "effect": "refresh-context updates read-only expectations outside Git; adopt-file transfers the WHOLE protected file, "
                      "including pre-existing uncommitted content, into this iteration for coding, both reviews and publication. "
                      "No source, index or Git history is changed by reconciliation. " + continuation}


def write_plan(cycle, path, *, prepare_plan=prepare):
    path = Path(path).absolute()
    resolved = path.resolve()
    if resolved.is_relative_to(cycle.repo.root):
        relative = resolved.relative_to(cycle.repo.root).as_posix()
        if (resolved.parent != cycle.repo.root / ".work" or resolved.suffix != ".json"
                or Repository.runtime_path(relative)):
            raise Blocked("reconcile-output", "Write a .json plan directly in the project's .work directory or outside the project; source and runtime control files cannot be plan destinations.")
    if (resolved.is_relative_to(cycle.repo.root) and not hasattr(cycle.repo, "owner")
            and cycle.repo.git("check-ignore", "--quiet", "--", resolved.relative_to(cycle.repo.root).as_posix(), check=False).returncode):
        raise Blocked("reconcile-output", "This plan would be part of the Git work snapshot. Use an ignored .work JSON destination or a path outside the repository.")
    plan = prepare_plan(cycle)
    path.parent.mkdir(parents=True, exist_ok=True)
    # A plan is operator input. Never overwrite an existing file implicitly.
    with path.open("xb") as stream:
        stream.write(encode(plan) + b"\n")
    return plan


def read_plan(path, *, schema=SCHEMA):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError("duplicate plan key")
            value[key] = item
        return value
    try:
        with Path(path).open("rb") as stream:
            data = stream.read(2 * 1024 * 1024 + 1)
        if len(data) > 2 * 1024 * 1024:
            raise ValueError("plan exceeds 2 MiB")
        value = json.loads(data, object_pairs_hook=unique)
        if not isinstance(value, dict) or value.get("schema") != schema:
            raise ValueError("unsupported reconciliation plan")
        return value
    except (OSError, ValueError, TypeError) as error:
        raise Blocked("reconcile-plan", f"Cannot read reconciliation plan: {error}") from error


def apply(cycle, path):
    plan = read_plan(path)
    if encode(plan) != encode(prepare(cycle)):
        raise Blocked("reconcile-stale", "The plan or saved work changed since preparation. Prepare and review a new plan; nothing was accepted.")
    current = cycle.snapshot()
    if digest(encode(current)) != plan["snapshot_sha256"]:
        raise Blocked("reconcile-stale", "Files changed during reconciliation; prepare a new plan.")
    candidate = copy.deepcopy(cycle.state)
    adopted = set()
    for row in plan["changes"]:
        name = row["path"]
        if row["action"] == "adopt-file":
            adopted.add(name)
        baseline = row["after"] if row["action"] == "refresh-context" else row["publication_base"]
        if baseline is None:
            candidate["baseline"]["files"].pop(name, None)
        else:
            candidate["baseline"]["files"][name] = baseline
    candidate["protected"] = [name for name in candidate["protected"] if name not in adopted]
    candidate["protected_index"] = {name: value for name, value in candidate["protected_index"].items() if name not in adopted}
    continuation = ("Continue the SAME stage using the current instructions; implement any remaining authorized requirements. "
                    "Do not merely reconstruct the old coding report. " if cycle.state.get("code_started") else
                    "Coding has not begun in this iteration. Read the current project plan to select its next unfinished stage; "
                    "do not reopen the previous published stage from an older handoff, result or conversation. "
                    "If coding later starts but its report is interrupted, finish that iteration's selected stage instead of selecting another. ")
    reviews = ("Both review loops must run again. " if cycle.state.get("code_started") else
               "Any unpublished work requires coding and both reviews before publication. If the current plan is exhausted "
               "and only read-only context was refreshed, do not invent a new stage. ")
    text = ("The operator explicitly reconciled the saved context and handed over the listed protected files. "
            "Read the current versions of the listed context/instruction files; this correction supersedes older "
            "handoff task details within this iteration, not runtime or permission boundaries. " + continuation +
            "Review the full contents/diffs of adopted files, "
            "including their pre-existing uncommitted work, before publication. Other protected files remain protected. "
            "Shared files outside repositories remain read-only and are never publication targets. "
            + reviews + "The prior state and exact handover plan are in this correction's archive.\n\n" +
            "\n".join(row["action"] + ": " + row["path"] for row in plan["changes"]))
    cycle.record_correction(text.encode("utf-8"), current, candidate=candidate,
                            metadata={"reconciliation": plan}, validate=lambda: validate_current(cycle, plan))


def validate_current(cycle, plan):
    if encode(plan) != encode(prepare(cycle)):
        raise Blocked("reconcile-stale", "Work changed while recording reconciliation; the handover was not applied.")
