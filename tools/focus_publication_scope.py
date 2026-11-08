"""Explicit pre-publication ownership and evidence available before paired review."""

import copy
from pathlib import PurePosixPath

from cycle_state import Blocked, digest, encode
from focus_pair_profile import PAIRS
from focus_reconcile import read_plan, state_fingerprint


SCHEMA = "orchestra/focus-publication-scope@1"
REQUEST_SCHEMA = "orchestra/focus-publication-selection@1"


def relative_path(value):
    if (not isinstance(value, str) or not value or "\\" in value or ":" in value
            or any(ord(c) < 32 for c in value) or value.startswith("/")
            or any(p in ("", ".", "..", ".git", ".jj", ".work") for p in value.split("/"))):
        raise Blocked("publication-selection", "Use literal project-relative file paths outside runtime and VCS directories.")
    return PurePosixPath(value).as_posix()


def selection(value):
    if not isinstance(value, dict) or set(value) != {"schema", "task", "paths"} or value["schema"] != REQUEST_SCHEMA:
        raise Blocked("publication-selection", "Expected a publication selection with schema, task, and paths.")
    task, paths = value["task"], value["paths"]
    if (not isinstance(task, dict) or set(task) != {"id", "title", "plan"}
            or any(not isinstance(v, str) or not v.strip() or v != v.strip()
                   or not all(c.isprintable() for c in v) for v in task.values())
            or len(task["id"]) > 80 or len(task["title"]) > 180 or len(task["plan"]) > 1000):
        raise Blocked("publication-selection", "Supply a task with a nonempty id, title, and plan path.")
    relative_path(task["plan"])
    if not isinstance(paths, list) or not paths or len(paths) > 10000:
        raise Blocked("publication-selection", "Select between 1 and 10000 changed files.")
    names = [relative_path(name) for name in paths]
    if len(names) != len(set(names)):
        raise Blocked("publication-selection", "The selection contains duplicate paths.")
    return {"schema": REQUEST_SCHEMA, "task": dict(task), "paths": sorted(names)}


def prepare(cycle, request):
    request = selection(request)
    state, repo = cycle.state, cycle.repo
    if (state.get("review_run") or state.get("status") == "complete"
            or state["phase"] not in PAIRS or not state.get("code_started")
            or state.get("pending") or state.get("publication_started") or state.get("published")
            or state.get("publication_repositories")):
        raise Blocked("publication-selection-phase", "Select scope in a stopped development review before publication, with no pending invocation.")
    if cycle.messages.unresolved(state["iteration"]):
        raise Blocked("reconcile-messages", "Resolve pending operator messages before selecting publication scope.")
    if repo.paused() or cycle.control and cycle.control.boundary():
        raise Blocked("recovery-paused", "Clear the operator PAUSE/stop before selecting publication scope.")
    cycle.validate_corrections()
    repo.assert_main()
    if hasattr(repo, "validate_state"):
        repo.validate_state(state)
    current = cycle.snapshot()
    if current["head"] != state["baseline"]["head"] or current["index"] != state["baseline"]["index"]:
        raise Blocked("publication-selection-git", "HEAD or staging changed. Reconcile those changes before selecting publication scope.")
    changed = set(cycle.changes(state["baseline"], current))
    protected = set(state["protected"])
    if changed & protected or repo.index_entries(protected) != state["protected_index"]:
        raise Blocked("publication-selection-protected", "Protected work changed. Reconcile it before selecting publication scope.")
    if hasattr(repo, "owner") and any(repo.owner(name) is None for name in changed):
        raise Blocked("project-context-changed", "Reconcile changed shared project context before selecting publication scope.")
    plan = repo.root / request["task"]["plan"]
    if (not plan.resolve().is_relative_to(repo.root) or not plan.is_file() or plan.is_symlink()
            or request["task"]["plan"] not in current["files"]):
        raise Blocked("publication-selection", "The task plan must be a regular project file included in the candidate snapshot.")
    paths = set(request["paths"])
    if not paths <= changed - protected:
        raise Blocked("publication-selection", "Select only changed files owned by this iteration: " + ", ".join(sorted(paths - (changed - protected))))
    parallel = [name for name in sorted(changed - paths) if hasattr(repo, "owner") and repo.owner(name) in state.get("parallel", [])]
    if parallel:
        # An excluded file becomes protected work. A parallel member has none, so its sync and integration stay possible.
        raise Blocked("publication-selection-parallel", "A parallel member cannot keep excluded files as protected work: "
                      + ", ".join(parallel[:20]) + ". Select these files too, or restore them first.")
    exclusions = [{"path": name, "before": state["baseline"]["files"].get(name),
                   "after": current["files"].get(name)} for name in sorted(changed - paths)]
    return {"schema": SCHEMA, "root": str(repo.root), "iteration": state["iteration"],
            "state_sha256": state_fingerprint(state), "snapshot_sha256": digest(encode(current)),
            "selection": request, "excluded": exclusions,
            "effect": "Publish only the selected files after all required reviews. Preserve excluded files as protected work. "
                      "Use the selected task identity. Restart Pair A with retained findings and evidence. "
                      "Do not change source files, staging, commits, or provider sessions. Pause before review."}


def apply(cycle, path):
    plan = read_plan(path, schema=SCHEMA)

    def validate():
        if encode(plan) != encode(prepare(cycle, plan.get("selection"))):
            raise Blocked("reconcile-stale", "The scope plan, state, or work changed. Prepare and inspect a new plan.")

    validate()
    current = cycle.snapshot()
    if digest(encode(current)) != plan["snapshot_sha256"]:
        raise Blocked("reconcile-stale", "Work changed during scope selection. Prepare a new plan.")
    candidate = copy.deepcopy(cycle.state)
    excluded = [row["path"] for row in plan["excluded"]]
    for row in plan["excluded"]:
        if row["after"] is None:
            candidate["baseline"]["files"].pop(row["path"], None)
        else:
            candidate["baseline"]["files"][row["path"]] = row["after"]
    candidate["protected"] = sorted(set(candidate["protected"]) | set(excluded))
    candidate["protected_index"].update(cycle.repo.index_entries(excluded))
    candidate["publication_scope"] = plan["selection"]
    candidate["task"] = dict(plan["selection"]["task"], iteration=candidate["iteration"])
    candidate["task_source"] = "operator"
    for key in ("publication_paths", "publication_prepared", "publication_targets", "publication_push_url"):
        candidate.pop(key, None)
    text = ("The operator selected the exact publication scope and corrected its task identity. "
            "Read the runtime publication manifest before checking publication findings. "
            "Preserve excluded files and protected work. Do not expand the selected file set.\n\n"
            "All required reviews must run on this scope. Retain prior findings and their recorded resolutions. "
            "Reuse valid evidence for unchanged code. Do not repeat successful tests without a new reason.\n\n"
            + encode(plan["selection"]).decode("utf-8"))
    cycle.record_correction(text.encode("utf-8"), current, candidate=candidate,
                            metadata={"publication_selection": plan}, validate=validate, resume_phase="pair_a")


def check_scope(cycle, snapshot):
    scope = cycle.state.get("publication_scope")
    if not scope:
        return
    selection(scope)
    task = cycle.state.get("task") or {}
    if any(task.get(k) != v for k, v in scope["task"].items()):
        raise Blocked("publication-selection-task", "The task identity differs from the accepted publication selection.")
    outside = (set(cycle.changes(cycle.state["baseline"], snapshot))
               - set(scope["paths"]) - set(cycle.state["protected"]))
    if outside:
        raise Blocked("publication-selection-drift", "Files changed outside the exact publication selection: " + ", ".join(sorted(outside)))


def manifest(cycle, snapshot, *, paths=None):
    """Runtime intent, not a claim that reviews, commit, push, or CI completed."""
    return {"schema": "orchestra/focus-publication-manifest@1", "status": "planned",
            "iteration": cycle.state["iteration"], "task": cycle.state.get("task"),
            "candidate": digest(encode(snapshot)), "paths": cycle.publication_paths() if paths is None else list(paths),
            "selection": "operator-exact" if cycle.state.get("publication_scope") else "runtime-diff",
            "protected_paths": sorted(cycle.state["protected"])}
