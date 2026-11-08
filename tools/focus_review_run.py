"""Review campaigns share the development engine, ownership, repairs, and publication gates."""

import copy
import json
from pathlib import Path
import time
import uuid

from cycle_state import Blocked, Store, digest, encode
from cycle_workflow import Cycle, fresh_state
from focus_publication import ProjectCycle
from focus_pair_view import artifact, read_record
from focus_review_contract import review_contract
from focus_review_scope import verify_plan
import focus_brief


def runs(root):
    directory = Store(root).directory / "review-runs"
    found = []
    if directory.exists():
        for path in sorted(directory.iterdir()):
            if not path.is_dir() or not (path / "state.json").exists():
                continue
            store = Store(root, path.name)
            state = store.read()
            if not state or state.get("review_run", {}).get("id") != path.name:
                raise Blocked("review-state", "Review run identity does not match its state directory.")
            found.append((store, state))
    return found


def pending_run(root):
    pending = [(store, state) for store, state in runs(root) if state["status"] != "complete"]
    if len(pending) > 1:
        raise Blocked("review-state", "Multiple unfinished review runs exist. Preserve their records for reconciliation.")
    return pending[0] if pending else None


def choose_store(root, review_id=None, current=False, require_state=True):
    if review_id:
        store = Store(root, review_id)
        if not require_state:
            return store
        state = store.read()
        if not state:
            raise Blocked("review-state", "Review run does not exist: " + review_id)
        if state.get("review_run", {}).get("id") != review_id:
            raise Blocked("review-state", "Review identity does not match the selected run.")
        return store
    if current:
        from focus_control import read_json
        active = read_json(Store(root).directory / "active.json") or {}
        if active.get("review_id"):
            return choose_store(root, active["review_id"], require_state=require_state)
    return Store(root)


def context_changes(cycle, before, after):
    """Changed project context outside the member repositories. Only a completed stage pause accepts it."""
    if not hasattr(cycle.repo, "owner"):
        return []
    return [path for path in cycle.changes(before, after) if cycle.repo.owner(path) is None]


def create_run(repo, request):
    if pending_run(repo.root):
        raise Blocked("review-active", "Resume the unfinished review run before starting another one.")
    verify_plan(repo.root, request)
    if repo.dirty_paths():
        raise Blocked("review-work", "Start a new review from a clean published checkpoint. Existing work was preserved.")
    development = Store(repo.root).read()
    snapshot = repo.snapshot()
    repositories = getattr(repo, "repositories", {"": repo})
    parallel = getattr(repo, "parallel", [])
    open_development = development and not (
        (development.get("stage_completed") or development.get("status") == "complete"
         or development.get("phase") == "code" and not development.get("code_started"))
        and not development.get("pending") and not development.get("blocker"))
    for name, member in repositories.items():
        expected = snapshot["head"][name] if name else snapshot["head"]
        if name in parallel:
            # An unpushed stage commit of an open development stage is not diverged history.
            if open_development:
                raise Blocked("review-development", "Finish the development stage through publication and CI first. Use /finish-stage.")
            # Other writers push to a parallel member. The run admission syncs it before the first pair.
            import focus_parallel
            published = ((development or {}).get("published") or {}).get("repositories", {}).get(name, {}).get("sha")
            known = published or ((development or {}).get("baseline") or {}).get("head", {}).get(name)
            focus_parallel.check_boundary(None, member, member.remote(), known, expected, name, "the same cc-focus review command")
        elif member.remote_head(member.remote()) != expected:
            raise Blocked("review-baseline", "Publish the current main revision before starting review: " + (name or "."))
    if development:
        if hasattr(repo, "validate_state"):
            repo.validate_state(development)
        factory = ProjectCycle if hasattr(repo, "repositories") else Cycle
        prior = factory(repo, Store(repo.root), development, None, lambda: None, Path(__file__).parent, "pwsh")
        boundary = (development.get("stage_completed") or development.get("status") == "complete"
                    or development.get("phase") == "code" and not development.get("code_started"))
        changed = prior.snapshot(development["last_snapshot"]) != prior.snapshot()
        if changed and boundary and not development.get("pending") and not development.get("blocker"):
            # Pushed commits after a development boundary are operator work.
            prior.retry_command = lambda: "the same cc-focus review command"  # A development retry starts no review.
            if prior.stage_completed():
                prior.assert_stage_base()
            else:
                if context_changes(prior, development["last_snapshot"], snapshot):
                    raise Blocked("review-context", "Project context outside the member repositories changed after "
                                  "the development boundary. Restore it before review. Development can also accept it first.")
                prior.assert_checkpoint_base(development["last_snapshot"])
            changed = False
        if not boundary or development.get("pending") or development.get("blocker") or changed:
            raise Blocked("review-development", "Finish the development stage through publication and CI first. Use /finish-stage.")
    identity = uuid.uuid4().hex
    store = Store(repo.root, identity)
    state = fresh_state(repo)
    if state["baseline"] != snapshot or state["protected"] or repo.snapshot() != snapshot:
        raise Blocked("review-start-drift", "The checkout changed during review admission. No review run was started.")
    state["review_run"] = {"id": identity, "request": artifact(store, "request.json", request),
        "current": 0, "target_count": len(request["targets"]), "remaining": list(range(1, len(request["targets"]))), "results": {}, "history": [],
        "started": time.time(), "development": artifact(store, "development.json", development) if development else None}
    activate(state, request)
    store.save(state)
    return store, state


def activate(state, request):
    run = state["review_run"]
    target = request["targets"][run["current"]]
    state.update(phase="pair_a", status="ready", coordinated=None,
                 task={"id": target["id"], "title": target["title"], "plan": (request.get("plan") or {}).get("path", ""),
                       "iteration": state["iteration"]},
                 sessions={}, pair_clean={"pair_a": 0, "pair_b": 0}, pair_completed={})


class ReviewMode:
    def reset_reviews(self, reason="Review target requires fresh inspection"):
        run = self.state["review_run"]
        run.pop("recorded_iteration", None)
        run["results"].pop(str(run["current"]), None)
        return super().reset_reviews(reason)

    def inspection_scope(self):
        run = self.state["review_run"]
        request = read_record(self.store, run["request"])
        target = request["targets"][run["current"]]
        return dict(target, plan=request.get("plan"), integration=request["integration"],
                    coverage_ids=[row["id"] for row in target["items"]] or ["scope"])

    def context(self, role):
        if role == "code":
            raise Blocked("review-route", "A review run cannot start an implementation phase.")
        if role == "coordinate":
            return ("Confirm the supplied review phase without selecting another plan item.\n"
                    "The runtime selected an existing-implementation review scope.\n"
                    "There is no initial coding phase. Do not change files or run checks.\n"
                    "\nReturn done. The runtime decides when the selected queue is complete.\n"
                    "An empty repair diff can complete without a commit.\n"
                    "Runtime context:\n" + json.dumps({"phase": self.state["phase"], "task": self.state["task"],
                        "review_scope": self.inspection_scope()}, ensure_ascii=False))
        return review_contract(super().context(role), True) + "\nReview target:\n" + json.dumps(self.inspection_scope(), ensure_ascii=False)

    def run(self):
        if self.state["phase"] == "code":
            raise Blocked("review-route", "The saved review run has an invalid implementation phase.")
        read_record(self.store, self.state["review_run"]["request"])
        return super().run()

    def correct(self, message):
        state = self.state
        if (state["status"] == "complete" or state.get("published") or state.get("publication_started")
                or state["phase"] in ("ci", "publish")):
            raise Blocked("correction-publication", "Complete publication and CI before changing the review scope.")
        if self.messages.unresolved(state["iteration"]):
            raise Blocked("correction-messages", "Resolve pending messages before correcting the review scope.")
        current = self.snapshot()
        if current["head"] != state["baseline"]["head"]:
            raise Blocked("correction-head", "HEAD changed since this review target started.")
        self.check_protected(current)
        self.record_correction(message.encode(), current, resume_phase="pair_a")

    def publish(self):
        if self.publication_paths():
            return super().publish()
        current = self.snapshot()
        if not self.state.get("reviewed") or current != self.state["reviewed"] or current != self.state["baseline"]:
            raise Blocked("review-empty-drift", "A review without changes must retain its exact reviewed baseline.")
        self.check_protected(current)
        repositories = getattr(self.repo, "repositories", {"": self.repo})
        observed, targets, records = {}, {}, {}
        for name, repo in repositories.items():
            remote = repo.remote()
            sha = current["head"][name] if name else current["head"]
            if name in self.state.get("parallel", []):
                import focus_parallel
                if not focus_parallel.contains(self, repo, remote, sha):
                    raise focus_parallel.rewritten(name, sha, self.retry_command())
            elif repo.remote_head(remote) != sha:
                raise Blocked("review-remote", "The unchanged reviewed revision must already be published: " + (name or "."))
            observed[name] = {"sha": sha, "at": time.time(), "remote": remote, "unchanged": True}
            if name:
                targets[name] = {"remote": remote, "push_url": repo.push_url(remote)}
                records[name] = {"remote": remote, "published": observed[name], "confirmed": True, "display_ci": None}
        if "" in observed:
            published = observed[""]
            self.state["remote"] = published["remote"]
        else:
            published = {"sha": digest(encode({n: r["sha"] for n, r in observed.items()})),
                         "repositories": observed, "at": time.time(), "unchanged": True}
            self.state.update(publication_targets=targets, publication_repositories=records)
        self.state.update(published=published, phase="ci", pending=None, coordinated=None, last_snapshot=current)
        self.save()

    def target_coverage(self):
        paths, coverage = set(), []
        for ref in self.state.get("pair_handoff", []):
            conclusion = read_record(self.store, ref)
            for report_ref in conclusion.get("sources", []):
                report = read_record(self.store, report_ref)
                for row in report.get("coverage", []):
                    coverage.append(row)
                    paths.update(row["paths"])
        paths.update(self.publication_paths())
        return sorted(paths), coverage

    def record_target(self):
        run = self.state["review_run"]
        if run.get("recorded_iteration") == self.state["iteration"]:
            return
        snapshot = self.snapshot()
        paths, coverage = self.target_coverage()
        if not coverage:
            raise Blocked("review-coverage", "Completed review has no scope coverage records.")
        self.requeue_changed_targets(snapshot, keep=run["current"])
        result = {"target": self.inspection_scope(), "iteration": self.state["iteration"], "snapshot": snapshot,
                  "paths": paths, "coverage": coverage, "pairs": self.state["pair_completed"],
                  "handoff": list(self.state.get("pair_handoff", [])), "decisions": list(self.state.get("pair_decisions", [])),
                  "published": self.state["published"], "ci": self.state.get("display_ci"),
                  "corrections": self.state.get("corrections", []),
                  "resolutions": list(self.state.get("publication_resolutions", [])), "at": time.time(), **self.target_brief()}
        ref = artifact(self.store, f"targets/{self.state['iteration']:06d}/{uuid.uuid4().hex}.json", result)
        run["results"][str(run["current"])] = ref
        run["history"].append(ref)
        run["recorded_iteration"] = self.state["iteration"]
        self.save()

    def finding_lines(self, result):
        """(status, key, line) for each finding of the outer pairs: the last decision and the last executor result.

        The key is the title and the location paths. It identifies a finding across reviews, which have new source ids.
        """
        def text(value):
            value = " ".join(str(value).split())
            return value if len(value) <= 300 else value[:297] + "..."
        decided, results = {}, {}
        phases = {ref["path"]: phase for phase, ref in result.get("pairs", {}).items()}
        for ref in result.get("handoff", []):
            record = read_record(self.store, ref)
            # A pair conclusion holds batches of results, an executor record holds rows, and a repair seal a mapping.
            rows = record.get("resolutions") or []
            for entry in (rows.values() if isinstance(rows, dict) else rows):
                for row in (entry if isinstance(entry, list) else [entry]):
                    results[row["source_id"]] = row
            # Conclusions come first. A runtime update during a target saved decision records only after it,
            # and each later conclusion repeats the last decision record of its pair.
            for row in record.get("decisions", []):
                decided[row["source_id"]] = (phases.get(ref["path"], "pair"), row)
        for ref in result.get("decisions", []):
            record = read_record(self.store, ref)
            for row in record["decisions"]:
                decided[row["source_id"]] = (record["phase"], row)
        lines = []
        for source, (phase, row) in decided.items():
            outcome = results.get(source)
            earlier = f" Earlier executor result: {outcome['outcome']}. {text(outcome['resolution'])}" if outcome else ""
            if outcome and outcome["outcome"] in ("fixed", "verified") and row["action"] in ("fix", "verify", "reject"):
                status, detail = outcome["outcome"], text(outcome["resolution"])  # A later pair can close a fixed finding.
            elif row["action"] in ("fix", "verify"):
                status = row["action"]
                detail = f"Executor result: {outcome['outcome']}. {text(outcome['resolution'])}" if outcome else "No executor result."
            elif row["action"] == "duplicate":
                status, detail = "duplicate", f"Duplicate of {row['duplicate_of']}. {text(row['reason'])}{earlier}"
            else:
                status, detail = row["action"], text(row["reason"]) + earlier
            where = ", ".join(f"{place['path']}:{place['line']}" for place in row.get("locations", [])[:3])
            key = (row["title"], tuple(sorted({place["path"] for place in row.get("locations", [])})))
            lines.append((status, key, f"- {phase}, {row['severity']}, {status}: {text(row['title'])} ({source}). "
                                          + (f"Locations: {where}. " if where else "") + detail))
        return lines

    def target_brief(self):
        """The brief that the reviewers of this target used, also null. Publication and CI never stop on the brief."""
        try:
            return {"project_brief_sha256": focus_brief.stage_hash(self.state)}
        except Blocked as error:
            # The pair conclusions keep the hashes that the reviewers used.
            return {"project_brief_sha256": None, "project_brief_error": str(error)}

    def requeue_changed_targets(self, snapshot, keep=None):
        """Queue a completed target again when later changes reach its recorded paths."""
        run = self.state["review_run"]
        for key, reference in list(run["results"].items()):
            previous = read_record(self.store, reference)
            # A path keeps the value that a sync or an integration brought: only other writers changed it.
            remote_files = self.state.get("parallel_remote_files", {})
            changes = {path for path in self.changes(previous["snapshot"], snapshot)
                       if not (path in remote_files and snapshot["files"].get(path) == remote_files[path])}
            watched = set(previous["paths"])
            directories = {str(Path(p).parent) for p in watched}
            affected = changes & watched or bool(changes and "." in directories) or any(
                any(p.startswith(d + "/") for d in directories) for p in changes)
            if affected and int(key) != keep:
                if int(key) not in run["remaining"]:
                    run["remaining"].append(int(key))
                del run["results"][key]

    def next_stage(self):
        if not self.stage_completed():
            self.assert_publication_current()
            self.record_target()
        return super().next_stage()  # After a stage pause, the base engine checks main with assert_stage_base.

    def advance_stage(self, baseline, protected, protected_index):
        run = self.state["review_run"]
        if self.stage_completed():
            # Pushed commits after a stage pause are operator work. The targets they reach need another review.
            # The exact new baseline is compared, so a commit during the checks cannot skip this step.
            self.requeue_changed_targets(baseline)
        if not run["remaining"]:
            self.state.update(status="complete", last_snapshot=baseline)
            run["completed"] = time.time()
            self.store.artifact("result.json", encode({"review_id": run["id"], "targets": run["results"],
                "history": run["history"], "snapshot": baseline, "completed": run["completed"]}))
            request = read_record(self.store, run["request"])
            lines = ["# Review results", "", "Run: " + run["id"], "", "All selected targets completed the required review and CI gates.",
                     "A finding status is the executor result (fixed, verified) or the last pair decision "
                     "(fix, verify, reject, duplicate, defer).", ""]
            deferred = []
            for key, ref in sorted(run["results"].items(), key=lambda row: int(row[0])):
                result = read_record(self.store, ref)
                title = request["targets"][int(key)]["title"]
                lines.extend(["## " + title, "", "Evidence: " + ref["path"], "",
                    "Publication: " + ("No changes. The reviewed revision was already published." if result["published"].get("unchanged") else "Reviewed corrections published."), ""])
                resolved = [f"- {entry['member']}/{path}: {rule}, merge commit {entry['result'][:12]}"
                            for entry in result.get("resolutions", []) for path, rule in sorted(entry["paths"].items())]
                if resolved:
                    lines.extend(["Merge conflicts that resolvers of focus-project.json resolved without a review:", "",
                                  *resolved, ""])
                for item in result["coverage"]:
                    lines.extend("- " + check.replace("\n", " ") for check in item["checks"])
                lines.append("")
                # The list is a summary. Damaged or unexpected evidence must not stop the campaign from completing.
                try:
                    findings = self.finding_lines(result)
                except Exception as error:
                    findings = [("error", None, f"- Findings could not be listed: {type(error).__name__}: {error}")]
                try:
                    # A target that was reviewed again keeps the deferrals of its earlier reviews. A new review has
                    # new source ids, so a repeated finding is matched by its title and location paths.
                    seen = {key for _, key, _ in findings}
                    for earlier in run["history"]:
                        if earlier == ref:
                            continue
                        old = read_record(self.store, earlier)
                        if old.get("target") != result["target"]:
                            continue
                        for status, key, line in self.finding_lines(old):
                            if status == "defer" and key not in seen:
                                seen.add(key)
                                findings.append((status, key, line + " Earlier review of this target."))
                except Exception as error:
                    findings.append(("error", None, f"- Earlier findings could not be listed: {type(error).__name__}: {error}"))
                if findings:
                    lines.extend(["Findings:", "", *(line for _, _, line in findings), ""])
                deferred.extend(f"- {title}: {line[2:]}" for status, _, line in findings if status == "defer")
            if deferred:
                lines.extend(["## Deferred findings", "", "The pairs deferred these findings. A pair can defer only a finding that is "
                              "not significant. Plan them separately if they still apply.", "", *deferred, ""])
            self.store.artifact("report.md", ("\n".join(lines) + "\n").encode())
            self.store.save(self.state)
            return
        previous = copy.deepcopy(self.state)
        try:
            super().advance_stage(baseline, protected, protected_index)
        except BaseException:
            # The CLI saves an interrupted state after setup or persistence errors.
            # Do not let that save persist the base engine's provisional code phase.
            self.state.clear()
            self.state.update(previous)
            raise

    def prepare_next_stage(self):
        run = self.state["review_run"]
        run["current"] = run["remaining"].pop(0)
        activate(self.state, read_record(self.store, run["request"]))


class ReviewCycle(ReviewMode, Cycle):
    pass


class ProjectReviewCycle(ReviewMode, ProjectCycle):
    pass


def hand_back(repo, scripts):
    """Accept only runtime-certified review publications at a saved development boundary."""
    development_store = Store(repo.root)
    development = development_store.read()
    if not development:
        return
    completed = [(s, v) for s, v in runs(repo.root) if v["status"] == "complete" and v["review_run"].get("development")]
    completed.sort(key=lambda pair: pair[1]["review_run"]["started"])
    for store, state in completed:
        run = state["review_run"]
        if development.get("review_handover", {}).get("id") == run["id"]:
            continue
        original = read_record(store, run["development"])
        if development != original:
            continue  # A prior run or an independently changed development state grants no handover.
        if hasattr(repo, "validate_state"):
            repo.validate_state(development)
        current = repo.snapshot()
        if repo.dirty_paths():
            raise Blocked("review-handover-drift", "The checkout changed after review. Preserve it before resuming development.")
        read_record(store, run["results"][str(run["current"])])  # The completion record must exist and match its hash.
        factory = ProjectReviewCycle if hasattr(repo, "repositories") else ReviewCycle
        completed_cycle = factory(repo, store, state, None, lambda: None, scripts, "pwsh")
        if not development.get("stage_completed"):
            # Compare with the development checkpoint: a review stage pause also accepts project context.
            prior = (ProjectCycle if hasattr(repo, "repositories") else Cycle)(
                repo, development_store, development, None, lambda: None, scripts, "pwsh")
            if context_changes(prior, development["last_snapshot"], current):
                raise Blocked("review-handover-drift", "The checkout changed after review. Preserve it before resuming development.")
        # Pushed commits after the last review publication are operator work, as after a stage pause.
        # The same check names a remote that moved ahead of an unchanged checkout.
        completed_cycle.retry_command = lambda: "the same cc-focus command"
        completed_cycle.assert_stage_base()
        if repo.snapshot() != current:  # The checks read main live; the new baseline must be that checkout.
            raise Blocked("review-handover-drift", "The checkout changed after review. Preserve it before resuming development.")
        archive = artifact(development_store, "review-handovers/" + run["id"] + ".json",
                           {"before": development, "review": str(store.directory / "result.json"), "snapshot": current})
        development["review_handover"] = {"id": run["id"], "evidence": archive}
        if development.get("stage_completed"):
            factory = ProjectCycle if hasattr(repo, "repositories") else Cycle
            cycle = factory(repo, development_store, development, None, lambda: None, scripts, "pwsh")
            cycle.retry_command = lambda: focus_brief.BEFORE_RUN  # This stage start comes before the run.
            cycle.advance_stage(current, [], {})
        else:
            development.update(baseline=current, last_snapshot=current, protected=[], protected_index={})
            development_store.save(development)
