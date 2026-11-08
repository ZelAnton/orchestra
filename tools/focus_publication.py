"""One reviewed project iteration, independently reconciled repository pushes."""

import os
import time

from cycle_prompts import PARALLEL_PUBLICATION_RULE, PARALLEL_REPOSITORIES_RULE, PROJECT_INSTRUCTIONS_RULE
from cycle_state import Blocked, Store, digest, encode
from cycle_workflow import Cycle


class MemberCycle(Cycle):
    """Reuse the single-repository publication/CI barriers, never its model loop."""
    def save(self):
        if (self.state.get("display_ci") and self.state.get("published") and
                self.state["display_ci"].get("sha") != self.state["published"]["sha"]):
            self.state["display_ci"] = None
        record = self.parent.state.setdefault("publication_repositories", {}).setdefault(self.name, {})
        record.update({key: self.state.get(key) for key in ("remote", "published", "display_ci")})
        self.parent.update_ci_display()
        self.parent.save()


class ProjectCycle(Cycle):
    def check_protected(self, snapshot):
        loose = [path for path in self.changes(self.state["baseline"], snapshot) if self.repo.owner(path) is None]
        if loose:
            raise Blocked("project-context-changed", "Files outside member repositories are read-only cycle context: " + ", ".join(loose) +
                          ". If these are intentional operator changes, prepare an explicit handover with "
                          "cc-focus reconcile --plan-out .work/focus-reconcile.json, review it, then use "
                          "cc-focus reconcile --apply-plan .work/focus-reconcile.json. "
                          "Provider roles must not approve their own changes.")
        super().check_protected(snapshot)

    def context(self, role):
        prompt = super().context(role)
        details = {"project_root": str(self.repo.root), "repositories": list(self.repo.repositories),
                   "instructions": "Paths are relative to the project root. Work only inside the listed repositories. "
                   "Files outside them are read-only context. Review the entire iteration across all affected repositories. "
                   "Each repository retains its own main, protected work, commit, remote and CI. "
                   "Only the runtime commits and pushes the publication_targets; provider roles are read-only during publication. "
                   "A partial publication is not an atomic project publication: reconcile each repository before retrying."}
        if role == "publish":
            details["publication_targets"] = [{"path": name, "remote": target["remote"],
                "push_url": target["push_url"], "ref": "refs/heads/main",
                "baseline_head": self.state["baseline"]["head"][name],
                "stage_paths": self.repo.local_paths(name, self.publication_paths()),
                "parallel": name in self.state.get("parallel", []),
                "published": (self.state.get("publication_repositories", {}).get(name, {}).get("published")
                              if self.state.get("publication_repositories", {}).get(name, {}).get("confirmed") else None)}
                for name, target in self.state["publication_targets"].items()]
        files = self.repo.instruction_entries()
        if files:
            details["project_instructions"] = {"files": files, "rule": PROJECT_INSTRUCTIONS_RULE}
        if self.state.get("parallel"):
            details["parallel_repositories"] = {"repositories": self.state["parallel"], "rule": PARALLEL_REPOSITORIES_RULE}
            if role in ("publish", "heal"):
                details["parallel_publication"] = PARALLEL_PUBLICATION_RULE
        if role in ("publish", "heal"):
            details["publication_artifacts"] = {name: str(self.store.directory / "repositories" / name / "publication")
                                                for name in self.state.get("publication_targets", {})}
        import json
        return prompt + "\n\nProject context:\n" + json.dumps(details, ensure_ascii=False)

    def sync_parallel(self, retry):
        """At a stage transition: sync the parallel members of the finished stage and of the next stage."""
        import focus_parallel
        import focus_resolve
        from focus_project import parallel_config
        focus_resolve.retry_cleanup(self, stage_start=True)
        self.stage_parallel = parallel_config(self.repo.root)  # advance_stage records these values.
        names = sorted(set(self.state.get("parallel", [])) | set(self.stage_parallel[0]))
        changed = {name: focus_parallel.sync(self, name, retry) for name in names}
        focus_parallel.record_sync(self, changed)
        return changed

    def catch_up_parallel(self):
        """A reported blocker: bring remote main into each parallel member that is behind. Return the changed paths.

        A member with publication evidence keeps its checkout, because its published commit is the stage result.
        A member that cannot move keeps its checkout. A failure of one member does not stop the others.
        """
        import focus_parallel
        self.resume_catch_ups()
        changed = {}
        for name in focus_parallel.members(self.state):
            if (self.state.get("publication_repositories", {}).get(name) or {}).get("published"):
                continue
            try:
                paths = focus_parallel.catch_up(self, name)
            except Blocked as error:
                print(f"cc-focus: {name}: remote main was not brought in: {error.code}.", flush=True)
                continue
            if paths:
                changed[name] = paths
        if changed:
            self.after_catch_up(changed)
            print("cc-focus: brought remote main into " + ", ".join(f"{name} ({len(paths)} paths)" for name, paths in changed.items())
                  + "; the blocked step runs again before any recovery agent.", flush=True)
        return changed

    def resume_catch_ups(self):
        """Complete a catch-up that an interruption left open, before any other step uses the checkout."""
        import focus_parallel
        names = [name for name, record in self.state.get("parallel_integrations", {}).items()
                 if record.get("catch_up") and record["step"] != "complete"]
        changed = {name: focus_parallel.resume_catch_up(self, name) for name in names}
        if changed:
            self.after_catch_up(changed)

    def after_catch_up(self, changed):
        """The runtime moved these members. The next pass must not treat the move as an external change.

        Only HEAD, the index, and the paths of the move get their current values. Another change of a member,
        for example an edit of the blocked role, still resets the reviews. A pair in progress froze the candidate
        before the move, so its phase starts a new pair on the current candidate with all open obligations.
        Completed pairs keep their credit: the stage diff did not change.
        """
        current, last = self.snapshot(), self.state["last_snapshot"]
        for name, paths in changed.items():
            last["head"][name], last["index"][name] = current["head"][name], current["index"][name]
            for path in (name + "/" + path for path in paths):
                if path in current["files"]:
                    last["files"][path] = current["files"][path]
                else:
                    last["files"].pop(path, None)
        if self.state.get("pair_review"):
            phase = self.state["pair_review"]["phase"]
            self.state.update(pair_carry=self.pair_obligations(), pair_review=None, pending=None, reviewed=None)
            self.state.setdefault("pair_clean", {})[phase] = 0
        self.save()

    def admit_parallel(self):
        """The run admission sync, inside the lease block. It runs only at a stage start without an open invocation."""
        import focus_parallel
        import focus_resolve
        from focus_brief import BEFORE_RUN
        from focus_project import parallel_config
        state = self.state
        # A campaign target before its first pair has no pair_round. A review reset keeps pair_round.
        start = ((state["phase"] == "code" and not state.get("code_started"))
                 or (state.get("review_run") and state["phase"] == "pair_a"
                     and not state.get("pair_review") and "pair_round" not in state))
        if not start or state.get("pending") or state.get("blocker") or state.get("status") == "complete":
            return
        focus_resolve.retry_cleanup(self, stage_start=True)
        parallel, resolvers = parallel_config(self.repo.root)
        names = sorted(set(state.get("parallel", [])) | set(parallel))
        if not names:
            return
        for name in parallel:
            focus_parallel.check_git(self.repo.repositories[name])
        review = (state.get("review_run") or {}).get("id")
        retry = f"cc-focus review --resume {review}" if review else BEFORE_RUN
        changed = {name: focus_parallel.sync(self, name, retry) for name in names}
        current = self.snapshot()
        # Take the parallel entries again, also when main did not move. The sync found each member clean.
        # Exclusive members and the root keep their entries, so a handover with reconcile stays valid.
        for key in ("baseline", "last_snapshot"):
            snapshot = state[key]
            for name in names:
                snapshot["head"][name], snapshot["index"][name] = current["head"][name], current["index"][name]
                snapshot["files"] = {path: value for path, value in snapshot["files"].items() if self.repo.owner(path) != name}
                snapshot["files"].update({path: value for path, value in current["files"].items() if self.repo.owner(path) == name})
        state["protected"] = [path for path in state["protected"] if self.repo.owner(path) not in names]
        state["protected_index"] = {path: value for path, value in state["protected_index"].items()
                                    if self.repo.owner(path) not in names}
        state.update(parallel=parallel, resolvers=resolvers)
        if any(changed.values()):
            state["coordinated"] = None  # The coordinator reads the current plan.
        focus_parallel.record_sync(self, changed)
        self.save()

    def member(self, name):
        repo = self.repo.repositories[name]
        store = Store(self.repo.root)
        store.directory = self.store.directory / "repositories" / name
        if not store.directory.resolve().is_relative_to(self.store.directory.resolve()):
            raise Blocked("external-state-path", f"{name}: CI artifacts resolve outside project state.")
        store.path = store.directory / "state.json"
        record = self.state.get("publication_repositories", {}).get(name, {})
        state = dict(self.state)
        for key in ("baseline", "reviewed", "last_snapshot"):
            if self.state.get(key):
                state[key] = self.repo.member_snapshot(name, self.state[key])
        state.update(root=str(repo.root), protected=self.repo.local_paths(name, self.state["protected"]),
                     protected_index={path[len(name) + 1:]: value for path, value in self.state["protected_index"].items()
                                      if self.repo.owner(path) == name},
                     remote=self.state["publication_targets"][name]["remote"],
                     publication_push_url=self.state["publication_targets"][name]["push_url"],
                     publication_paths=self.repo.local_paths(name, self.publication_paths()),
                     published=record.get("published"), display_ci=record.get("display_ci"), pending=None,
                     parallel_member=name in self.state.get("parallel", []))
        if self.state.get("publication_scope"):
            state["publication_scope"] = dict(self.state["publication_scope"],
                paths=self.repo.local_paths(name, self.state["publication_scope"]["paths"]))
        member = MemberCycle(repo, store, state, self.transport, self.heartbeat, self.scripts, self.pwsh,
                             control=self.control, progress=self.progress)
        member.parent, member.name = self, name
        return member

    def update_ci_display(self):
        if not self.state.get("published"):
            return
        statuses = {name: self.state.get("publication_repositories", {}).get(name, {}).get("display_ci")
                    for name in self.state["publication_targets"]}
        finished = sum(bool(item and item.get("status") in ("ready", "not-configured")) for item in statuses.values())
        status = "waiting"
        if finished == len(statuses):
            status = "not-configured" if all(item["status"] == "not-configured" for item in statuses.values()) else "ready"
        self.state["display_ci"] = {"sha": self.state["published"]["sha"], "status": status,
                                    "total": len(statuses), "passed": finished, "repositories": statuses}

    def validate_targets(self, current):
        targets = self.state.get("publication_targets", {})
        for name, repo in self.repo.repositories.items():
            if name not in targets:
                if current["head"][name] != self.state["baseline"]["head"][name]:
                    raise Blocked("unreviewed-commit", f"{name}: HEAD changed in a repository outside this iteration's publication.")
                continue
            target = targets[name]
            if repo.remote() != target["remote"] or repo.push_url(target["remote"]) != target["push_url"]:
                raise Blocked("remote-changed", f"{name}: publication remote or push URL changed.")

    def resume_integrations(self):
        """An open integration record is resolved before any publication check of its member."""
        import focus_parallel
        for name in sorted(self.state.get("parallel_integrations", {})):
            focus_parallel.resume(self, name)

    def prepare_publish(self):
        self.resume_integrations()
        reviewed, current = self.state["reviewed"], self.snapshot()
        if not reviewed or self.changes(reviewed, current):
            self.state["pending"] = None
            self.reset_reviews("Файлы изменились после ревью")
            self.save()
            return False
        self.check_protected(current)
        names = {self.repo.owner(path) for path in self.changes(self.state["baseline"], reviewed)}
        # A reviewed revert can erase the final diff of an already committed
        # member. Keep that member, while still detecting withdrawn work in a
        # member whose publication never produced a commit.
        names.update(self.repo.owner(path) for path in self.publication_paths()
                     if current["head"][self.repo.owner(path)] != self.state["baseline"]["head"][self.repo.owner(path)])
        names = sorted(names)
        if not names:
            raise Blocked("empty-stage", "No repository changes to publish in this iteration.")
        old = self.state.get("publication_targets")
        if old is not None and sorted(old) != names:
            removed = set(old) - set(names)
            if self.state.get("publication_started") and removed:
                raise Blocked("publication-scope-changed", "A repository was removed after publication started; reconcile the preserved iteration.")
            for name in removed:
                self.state.get("publication_repositories", {}).pop(name, None)
        if old is None or sorted(old) != names:
            targets = {name: target for name, target in (old or {}).items() if name in names}
            for name in names:
                if name in targets:
                    continue
                repo = self.repo.repositories[name]
                remote = repo.remote()
                targets[name] = {"remote": remote, "push_url": repo.push_url(remote)}
            targets = dict(sorted(targets.items()))
            self.state["publication_targets"] = targets
            self.state["remote"] = {name: target["remote"] for name, target in targets.items()}
            self.save()
        self.validate_targets(current)
        # Every repository passes its policy and live-remote check before the
        # runtime publishes any member. Completed pushes reconcile independently.
        for name in names:
            if not self.member(name).prepare_publish():
                self.reset_reviews("Файлы изменились после ревью")
                self.save()
                return False
        self.state["publication_paths"] = self.publication_paths()
        self.save()
        return True

    def reconcile_publish(self):
        self.resume_integrations()
        current = self.snapshot()
        self.check_protected(current)
        if self.changes(self.state["reviewed"], current):
            raise Blocked("publish-drift", "Publication changed reviewed project content; all required reviews must run again.")
        self.validate_targets(current)
        complete = True
        for name in self.state["publication_targets"]:
            # Do not short-circuit: preserve evidence for later members even if
            # an earlier member has not yet reached its remote.
            reconciled = self.member(name).reconcile_publish()
            record = self.state.setdefault("publication_repositories", {}).setdefault(name, {})
            record["confirmed"] = reconciled
            if not reconciled:
                record["display_ci"] = None
            self.save()
            complete = reconciled and complete
        if not complete:
            return False
        repositories = {name: self.state["publication_repositories"][name]["published"]
                        for name in self.state["publication_targets"]}
        self.state["published"] = {"sha": digest(encode({name: item["sha"] for name, item in repositories.items()})),
                                   "repositories": repositories, "at": time.time()}
        self.state.update(phase="ci", pending=None, coordinated=None, last_snapshot=current, recovery_unverified=False)
        self.update_ci_display()
        self.save()
        return True

    def publication_paths(self):
        paths = set(super().publication_paths())
        if not self.state.get("publication_scope") and not self.state.get("publication_paths"):
            for name, record in self.state.get("publication_repositories", {}).items():
                if not record.get("published"):
                    continue
                paths.update(name + "/" + os.fsdecode(path) for path in self.repo.repositories[name].git(
                    "diff", "--name-only", "-z", "--no-renames", self.state["baseline"]["head"][name], record["published"]["sha"]
                ).stdout.split(b"\0") if path)
        return sorted(paths)

    def validate_publication_commit(self):
        current = self.snapshot()
        self.check_protected(current)
        if self.changes(self.state["reviewed"], current):
            raise Blocked("publish-drift", "Publication changed reviewed project content.")
        self.validate_targets(current)
        ready = True
        for name in self.state["publication_targets"]:
            ready = self.member(name).validate_publication_commit() and ready
        return ready

    def execute_publication(self, subject):
        from focus_commit import commit_reviewed, push_reviewed
        import focus_parallel
        for name in self.state["publication_targets"]:
            commit_reviewed(self.member(name), subject)
        parallel = [name for name in self.state["publication_targets"] if name in self.state.get("parallel", [])]
        # Every parallel target integrates before the first push, so a merge conflict stops before any push.
        for name in parallel:
            focus_parallel.integrate(self, name)
        # All members must validate before the first push. A commit hook in one
        # member may have touched another member's reviewed or protected work.
        for name in self.state["publication_targets"]:
            if not self.validate_publication_commit():
                raise Blocked("uncommitted-stage", "Every target must be committed before project publication.")
            self.validate_targets(self.snapshot())
            if name in parallel:
                focus_parallel.push(self, name)
            else:
                push_reviewed(self.member(name))

    def assert_publication_current(self):
        current = self.snapshot()
        self.check_protected(current)
        if self.changes(self.state["reviewed"], current):
            raise Blocked("ci-head-drift", "Reviewed project content changed during publication/CI.")
        self.validate_targets(current)
        published = self.state["published"]["repositories"]
        if set(published) != set(self.state["publication_targets"]):
            raise Blocked("publication-unconfirmed", "Publication evidence does not cover the iteration's repositories.")
        for name in published:
            member = self.member(name)
            if member.state["published"] != published[name]:
                raise Blocked("publication-unconfirmed", f"{name}: publication evidence changed.")
            member.assert_publication_current()

    def assert_stage_base(self):
        self.repo.assert_main()
        self.repo.validate_state(self.state)  # An added or removed repository is not pushed operator work.
        published = self.state["published"]["repositories"]
        for name, repo in self.repo.repositories.items():
            label = name + ": "
            parallel = name in self.state.get("parallel", [])
            if name in published:
                self.check_stage_base(repo, published[name]["sha"], published[name]["remote"], label, parallel=parallel)
            elif repo.text("rev-parse", "HEAD") != self.state["baseline"]["head"][name]:
                # A repository outside the publication may also get pushed operator commits.
                self.check_stage_base(repo, self.state["baseline"]["head"][name], repo.remote(), label, parallel=parallel)
        self.check_stage_dirty()

    def wait_ci(self):
        self.assert_publication_current()
        for name in self.state["publication_targets"]:
            if self.progress:
                self.progress.note(f"Checking publication and CI for repository {name}; no model is running.")
            self.member(name).wait_ci()
        self.assert_publication_current()
