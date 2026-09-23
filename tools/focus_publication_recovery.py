"""Operator-only acceptance of a preserved, already-pushed publication scope."""

import copy
import os

from cycle_state import Blocked, digest, encode
from cycle_workflow import publication_history
from focus_reconcile import committed_base, read_plan, state_fingerprint
from focus_reconcile import write_plan as write_reconciliation_plan


SCHEMA = "orchestra/focus-publication-reconcile@1"


def prepare(cycle):
    state, repo = cycle.state, cycle.repo
    if (state["phase"] != "publish" or state.get("status") not in ("blocked", "interrupted", "paused")
            or not state.get("code_started") or not state.get("publication_started") or not state.get("reviewed")):
        raise Blocked("reconcile-publication-phase", "Publication recovery requires a stopped, already-started publication with a reviewed snapshot.")
    if cycle.messages.unresolved(state["iteration"]):
        raise Blocked("reconcile-messages", "Resolve queued/uncertain operator messages before publication recovery.")
    if repo.paused() or (cycle.control and cycle.control.boundary()):
        raise Blocked("recovery-paused", "Clear the operator PAUSE/stop before publication recovery.")
    cycle.validate_corrections()
    repo.assert_main()
    if hasattr(repo, "validate_state"):
        repo.validate_state(state)
    current = cycle.snapshot()
    if cycle.changes(state["reviewed"], current):
        raise Blocked("reconcile-publication-drift", "Working files differ from the reviewed publication; this recovery cannot accept new content.")
    protected = set(state["protected"])
    if protected & set(cycle.changes(state["baseline"], current)):
        raise Blocked("reconcile-publication-drift", "Protected working files changed; preserve their original content before publication recovery.")
    project = hasattr(repo, "repositories")
    if project:
        if any(repo.owner(path) is None for path in cycle.changes(state["baseline"], current)):
            raise Blocked("project-context-changed", "Publication recovery cannot accept changed shared context outside repositories.")
        cycle.validate_targets(current)
        members = repo.repositories
    else:
        members = {"": repo}
    owned = set(cycle.publication_paths())
    rows, repositories = [], []
    for name, member in members.items():
        if project and name not in state.get("publication_targets", {}):
            continue  # validate_targets already requires its unchanged HEAD.
        before = state["baseline"]["head"][name] if project else state["baseline"]["head"]
        head = current["head"][name] if project else current["head"]
        remote = state["publication_targets"][name]["remote"] if project else state["remote"]
        url = member.push_url(remote)
        pinned = state["publication_targets"][name]["push_url"] if project else state.get("publication_push_url", url)
        if member.remote() != remote or url != pinned:
            raise Blocked("remote-changed", "Publication recovery cannot change the prepared destination.")
        cycle.heartbeat()
        remote_head = member.remote_head(remote, progress=lambda *_: cycle.heartbeat())
        if remote_head != head:
            raise Blocked("reconcile-publication-remote", "Publication recovery requires each target HEAD to equal its live remote main.")
        committed = publication_history(member, before, head)
        prefix = name + "/" if name else ""
        extra = sorted(path for path in committed if prefix + path not in owned)
        if any(prefix + path not in protected for path in extra):
            raise Blocked("reconcile-publication-scope", "History contains extra paths outside protected work; they cannot be adopted by this recovery.")
        # Accept only the exact already-published bytes; unrelated staged work
        # on the adopted paths must not be silently folded into this consent.
        staged = {os.fsdecode(path) for path in member.git(
            "diff", "--cached", "--name-only", "-z", "--no-renames", "HEAD").stdout.split(b"\0") if path}
        if staged & set(extra):
            raise Blocked("reconcile-publication-index", "Adopted paths have staging beyond the published commit; preserve it before recovery.")
        local_snapshot = repo.member_snapshot(name, current) if project else current
        published_files = committed_base(member, extra, local_snapshot, head) if extra else {}
        bases = committed_base(member, extra, local_snapshot, before) if extra else {}
        for path in extra:
            full = prefix + path
            if published_files[path] != current["files"].get(full):
                raise Blocked("reconcile-publication-content", "Published adopted content differs from reviewed work: " + full)
            rows.append({"path": full, "action": "adopt-published-file", "before": state["baseline"]["files"].get(full),
                         "after": current["files"].get(full), "publication_base": bases[path]})
        repositories.append({"path": name or ".", "baseline_head": before, "head": head, "remote": remote,
                             "push_url": url, "remote_head": remote_head,
                             "committed_paths": sorted(prefix + path for path in committed)})
    adopted = {row["path"] for row in rows}
    actual = repo.index_entries(state["protected"])
    expected = state["protected_index"]
    changed_index = {path for path in actual.keys() | expected.keys() if actual.get(path) != expected.get(path)}
    if changed_index - adopted:
        raise Blocked("reconcile-publication-index", "Protected staging outside the proposed published scope changed; it cannot be accepted here.")
    if not adopted:
        raise Blocked("reconcile-empty", "No already-published protected files need ownership acceptance.")
    # Remote queries and filtered blob reads can take time. The first snapshot
    # must still describe the checkout when this plan is returned/accepted.
    cycle.heartbeat()
    if repo.paused() or (cycle.control and cycle.control.boundary()):
        raise Blocked("recovery-paused", "Publication recovery was stopped before acceptance.")
    if cycle.snapshot() != current:
        raise Blocked("reconcile-stale", "Work changed during publication verification; nothing was accepted.")
    for record in repositories:
        member = members[record["path"] if project else ""]
        if member.remote() != record["remote"] or member.push_url(record["remote"]) != record["push_url"]:
            raise Blocked("remote-changed", "Publication destination changed during verification.")
    return {"schema": SCHEMA, "root": str(repo.root), "iteration": state["iteration"], "task": state.get("task"),
            "state_sha256": state_fingerprint(state), "snapshot_sha256": digest(encode(current)),
            "repositories": repositories, "changes": sorted(rows, key=lambda row: row["path"]),
            "effect": "Accept exactly the listed already-published protected files into this SAME iteration. "
                      "Preserve all working files, index entries, commits, original baseline HEADs and sessions. "
                      "Archive the prior state, invalidate review/publication/CI credit and pause before first review. "
                      "All three review loops must run anew; remaining reviewed work still needs publication and exact-SHA CI. "
                      "This command starts no model, commits nothing, pushes nothing and never resumes the cycle."}


def write_plan(cycle, path):
    return write_reconciliation_plan(cycle, path, prepare_plan=prepare)


def apply(cycle, path):
    plan = read_plan(path, schema=SCHEMA)

    def validate():
        if encode(plan) != encode(prepare(cycle)):
            raise Blocked("reconcile-stale", "Publication, work or plan changed since preparation; nothing was accepted.")

    validate()
    current = cycle.snapshot()
    if digest(encode(current)) != plan["snapshot_sha256"]:
        raise Blocked("reconcile-stale", "Work changed during publication recovery; nothing was accepted.")
    candidate = copy.deepcopy(cycle.state)
    adopted = {row["path"] for row in plan["changes"]}
    for row in plan["changes"]:
        if row["publication_base"] is None:
            candidate["baseline"]["files"].pop(row["path"], None)
        else:
            candidate["baseline"]["files"][row["path"]] = row["publication_base"]
    candidate["protected"] = [path for path in candidate["protected"] if path not in adopted]
    candidate["protected_index"] = {path: value for path, value in candidate["protected_index"].items() if path not in adopted}
    candidate["publication_paths"] = sorted(set(cycle.publication_paths()) | adopted)
    candidate.pop("publication_prepared", None)
    candidate.update(published=None, display_ci=None)
    for record in candidate.get("publication_repositories", {}).values():
        record.update(published=None, display_ci=None, confirmed=False)
    text = ("The operator explicitly accepted the already-published protected files listed in this correction's "
            "publication_reconciliation archive. Preserve the current stage, all existing commits and the original "
            "baseline HEADs. Review the full adopted files and their committed history as part of the SAME stage. "
            "This accepts ownership only, not correctness or completion. All three review loops restart with zero clean "
            "credit. Do not repeat completed implementation, stage files, commit, push or rewrite history. The runtime "
            "will later reconcile actual remote HEADs, finish remaining reviewed publication and verify CI. "
            "Other protected files and staging remain protected. No model was started by this recovery.\n\n" +
            "\n".join("adopt-published-file: " + row["path"] for row in plan["changes"]))
    cycle.record_correction(text.encode("utf-8"), current, candidate=candidate,
                            metadata={"publication_reconciliation": plan}, validate=validate, resume_phase="sol")
