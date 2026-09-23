"""Deterministic barriers around the sequential coordinator's decisions."""

import copy
import json
import os
from pathlib import Path
import re
import time
import uuid

from cycle_prompts import PROMPTS, REVIEW_PROFILE_VERSION, REVIEW_ROLES
from cycle_state import Blocked, ProviderQuota, changed, command, digest, encode
from cycle_transport import concise_summary, parse_report
from focus_status import accept_task, new_reviews, reset_notice, review_event
from focus_output import terminal_text
from focus_messages import MessagePending, Messages


MANUAL_BLOCKERS = {"claude-access-denied", "approval-required", "approval-denied"}
UNSAFE_PROVIDER_BLOCKERS = {"cleanup-incomplete", "turn-active"}
ESCALATION_REASONS = {
    "manual-action": "This action requires the operator; the recovery agent cannot supply consent or account access.",
    "unsafe-provider": "A prior provider may still be active; recovery cannot safely start another agent.",
    "healer-failed": "Astra/xhigh attempted recovery and could not complete it.",
    "verification-failed": "Astra/xhigh reported a repair, but the next work step could not verify recovery.",
    "repeated-blocker": "This blocker already received an Astra/xhigh recovery attempt in the current iteration.",
}


def fresh_state(repository):
    baseline = repository.snapshot()
    protected = repository.dirty_paths()
    return {"version": 1, "root": str(repository.root), "phase": "code", "iteration": 1,
            "sessions": {}, "session_generation": 1, "handoffs": [], "baseline": baseline,
            "protected": protected, "protected_index": repository.index_entries(protected), "pending": None, "blocker": None,
            "healed": [], "coordinated": None, "last": None, "code_report": "",
            "review_profile": REVIEW_PROFILE_VERSION,
            "sol_passes": 0, "sol_clean": 0, "claude_clean": 0, "astra_clean": 0,
            "reviewed": None, "published": None, "status": "ready", "last_snapshot": baseline,
            "code_started": False, "task": None, "display_reviews": new_reviews(), "display_review_events": []}


def publication_history(repo, baseline, head):
    """Inspect every new commit, including paths hidden by a later revert."""
    if repo.git("merge-base", "--is-ancestor", baseline, head, check=False).returncode:
        raise Blocked("rewritten-history", "Published history is not a descendant of the stage baseline.")
    committed = set()
    for revision in repo.text("rev-list", "--parents", baseline + ".." + head).splitlines():
        fields = revision.split()
        if len(fields) != 2:
            raise Blocked("publication-history", "Publication requires serial commits, not merge history.")
        committed.update(os.fsdecode(name) for name in repo.git(
            "diff-tree", "--no-commit-id", "--name-only", "-r", "-z", "--no-renames", fields[0]
        ).stdout.split(b"\0") if name)
    return committed


class Cycle:
    def __init__(self, repository, store, state, transport, heartbeat, scripts, pwsh, control=None, progress=None):
        self.repo, self.store, self.state = repository, store, state
        self.transport, self.heartbeat = transport, heartbeat
        self.scripts, self.pwsh = Path(scripts), pwsh
        self.control, self.progress = control, progress
        self.messages = Messages(store)

    def save(self):
        self.store.save(self.state)
        if self.progress and self.progress.on_update:
            self.progress.on_update()

    def snapshot(self, recorded=None):
        """Compare work independently of original, already-imported loose inputs.

        Project snapshots on disk may predate this distinction. Project their
        comparison view without rewriting immutable results or saved baselines.
        """
        sources = self.repo.handoff_sources(self.state) if hasattr(self.repo, "handoff_sources") else set()
        current = recorded if recorded is not None else (
            self.repo.snapshot(exclude_context=sources) if sources else self.repo.snapshot())
        return dict(current, files={name: value for name, value in current["files"].items()
                                    if name not in sources}) if sources else current

    def changes(self, before, after):
        return changed(self.snapshot(before), self.snapshot(after))

    def policy(self, verb, *args):
        return command([self.pwsh, "-NoProfile", "-File", str(self.scripts / "policy.ps1"),
                        verb, "--work", str(self.repo.root / ".work"), *args], self.repo.root, check=False)

    def reset_reviews(self, reason="Реализация завершена; ревью требуется заново"):
        reset_notice(self.state, reason)
        self.state.pop("publication_review_profile", None)
        self.state.update(sol_passes=0, sol_clean=0, claude_clean=0, astra_clean=0,
                          reviewed=None, coordinated=None, phase="sol")

    def upgrade_review_profile(self):
        """Archive legacy credit/sessions before using the three-review profile.

        Called only with runtime ownership and no unresolved message delivery.
        An already-started publication retains its original seal through CI;
        changing it would strand partial pushes and operator reconciliation.
        Before that boundary, the current work receives all three new reviews.
        """
        state = self.state
        if state.get("review_profile") == REVIEW_PROFILE_VERSION:
            return
        if state.get("review_profile", 1) != 1:
            raise Blocked("review-profile-version", "This saved review profile requires a newer runtime; work was preserved.")
        if self.messages.unresolved(state["iteration"]):
            raise MessagePending("Resolve pending messages before changing the review profile.")
        previous = copy.deepcopy(state)
        archive = self.store.artifact(f"review-profiles/{uuid.uuid4().hex}.json", encode(previous))
        pending = state.get("pending")
        publishing = state["phase"] == "publish" and state.get("publication_started")
        restart = state["phase"] in (*REVIEW_ROLES, "publish") and not publishing
        # A fresh conversation is essential: the old Astra was the first
        # reviewer, and the old Claude conversation used Fable.
        for role in REVIEW_ROLES:
            state["sessions"].pop(role, None)
        state.update(review_profile=REVIEW_PROFILE_VERSION, sol_passes=0,
                     sol_clean=0, claude_clean=0, astra_clean=0,
                     display_reviews=new_reviews(), display_review_events=[])
        state.pop("astra_passes", None)
        if publishing or state["phase"] == "ci":
            state["publication_review_profile"] = 1
        if restart:
            self.reset_reviews("Новый профиль: Sol → Opus → Astra")
            if pending and pending["role"] != "heal":
                state["pending"] = None
            if state.get("blocker"):
                state["blocker"]["phase"] = "sol"
            state.pop("publication_prepared", None)
        state["review_profile_archive"] = str(archive)
        try:
            self.save()
        except BaseException:
            state.clear()
            state.update(previous)
            raise
        print(f"cc-focus: review profile updated to Sol/Opus/Astra; old review credit archived: {archive}", flush=True)
        if publishing or state["phase"] == "ci":
            print("cc-focus: the already-started publication retains its original review seal through CI; new work uses all three reviews.", flush=True)

    def check_protected(self, snapshot):
        touched = set(self.changes(self.state["baseline"], snapshot)) & set(self.state["protected"])
        if touched:
            raise Blocked("protected-work", "Pre-existing work was changed; preserve and reconcile it: " + ", ".join(sorted(touched)) +
                          ". For intentional operator changes, prepare and inspect a cc-focus reconcile plan, then explicitly "
                          "accept it with --apply-plan. --retry alone does not transfer ownership; provider roles must not approve their own changes.")
        if self.repo.index_entries(self.state["protected"]) != self.state["protected_index"]:
            actual = self.repo.index_entries(self.state["protected"])
            expected = self.state["protected_index"]
            paths = sorted(name for name in actual.keys() | expected.keys() if actual.get(name) != expected.get(name))
            detail = ", ".join(paths[:12]) + (f" (+{len(paths) - 12} more)" if len(paths) > 12 else "")
            recovery = (" For operator acceptance of an already-pushed scope, inspect a cc-focus reconcile --publication "
                        "--plan-out plan, then explicitly use --publication --apply-plan. Providers must not accept their own scope changes."
                        if self.state["phase"] == "publish" and self.state.get("publication_started") else "")
            raise Blocked("protected-index", "Pre-existing index entries changed; preserve the operator's staging before resuming: "
                          + detail + ". If HEAD changed, inspect the committed/pushed scope; --retry does not authorize extra files." + recovery)

    def validate_corrections(self):
        state = self.state
        corrections = state.get("corrections", [])
        for correction in corrections:
            try:
                valid = (correction["iteration"] == state["iteration"]
                         and digest(Path(correction["path"]).read_bytes()) == correction["sha256"]
                         and digest(Path(correction["archive"]).read_bytes()) == correction["archive_sha256"])
            except OSError:
                valid = False
            if not valid:
                raise Blocked("correction-drift", "An immutable operator correction changed or disappeared; restore its saved copy before continuing.")

    def context(self, role):
        state = self.state
        self.validate_corrections()
        corrections = state.get("corrections", [])
        if role != "heal":
            for handoff in state["handoffs"]:
                try:
                    valid = digest(Path(handoff["path"]).read_bytes()) == handoff["sha256"]
                except OSError:
                    valid = False
                if not valid:
                    raise Blocked("handoff-drift", "An imported handoff snapshot changed or disappeared; restore the immutable copy before resuming.")
        context = {"phase": state["phase"], "iteration": state["iteration"],
                   "handoffs": state["handoffs"], "last": state["last"],
                   "protected_paths": state["protected"],
                   "sol_passes": state["sol_passes"], "sol_clean": state["sol_clean"],
                   "claude_clean": state["claude_clean"], "astra_clean": state.get("astra_clean", 0),
                   "review_order": list(REVIEW_ROLES), "published": state["published"]}
        context["handoff_instructions"] = (
            "Handoffs are optional historical transfer context. Read each imported 'path'; 'source' is provenance, "
            "not a required file. Do not require or recreate HANDOFF.md to continue. Use the current project plan "
            "and instructions, plus the saved task for an interrupted stage. Imported snapshots remain immutable.")
        if state.get("publication_review_profile") == 1:
            context["publication_review_profile"] = (
                "This publication already started under the previous two-review profile. Its original reviewed "
                "snapshot and publication/CI reconciliation remain valid. Do not require retrospective new-model "
                "review passes to finish this existing publication. New work or changed reviewed content must "
                "pass Sol, Opus and Astra. Original review evidence is archived at " + state["review_profile_archive"])
        if hasattr(self.repo, "handoff_sources"):
            context["optional_handoff_sources"] = sorted(self.repo.handoff_sources(state))
        accepted = self.messages.accepted(state["iteration"])
        if accepted:
            context["operator_messages"] = [{"id": item["identity"]["id"], "role": item["identity"]["role"],
                "path": str(self.messages.directory(state["iteration"]) / (item["identity"]["id"] + ".json")),
                "sha256": item["sha256"]} for item in accepted]
            context["message_instructions"] = (
                "Read identity.text in these accepted operator-message artifacts, oldest first. "
                "They clarify this SAME stage, not role/permission boundaries. Account for them in the "
                "current result and subsequent reviews. Accepted means received, not proof of implementation.")
        if corrections:
            context["operator_corrections"] = corrections
            context["correction_pending"] = state.get("correction_pending")
            before_code = corrections[-1].get("before_code", False)
            selection = (
                "The latest handover occurred BEFORE coding began in this iteration. Read the current versions of its listed "
                "instruction files and the current project plan. Select the next unfinished stage only if coding has not "
                "already selected/started a stage in THIS iteration; otherwise finish that selected stage, including a lost report. "
                "The last result or an older session may describe a previous published stage: do not reopen it. "
                if before_code else
                "The operator stopped this SAME project stage. Do not select the next unfinished project-plan stage. "
                "If the original stage cannot be identified from saved evidence, report blocked. ")
            context["correction_instructions"] = (
                selection + "The operator supplied corrections, oldest to newest. "
                "Read the immutable correction files; later corrections supersede earlier conflicting task details, "
                "not role or permission boundaries. The archive paths preserve the original iteration and "
                "interrupted invocation. In code, apply the corrections to this iteration's work; "
                "do not merely reconstruct the old report. Identify the correction IDs and disposition in evidence. "
                "Coordinate confirms this route without implementing it. Reviews verify the corrected stage anew. "
                "Only a done coding result can acknowledge pending corrections; complete cannot skip them. "
                "A handover before coding carries no claim that a stage started; complete still requires an exhausted plan "
                "and no unpublished changes, including adopted files. "
                "Listed optional_handoff_sources may have been removed after import; their absence does not block "
                "this correction. Follow current project instructions and plans instead of restoring those transfer files.")
            if corrections[-1].get("publication_recovery"):
                context["publication_recovery"] = (
                    "The operator accepted the exact already-committed protected files listed in the latest correction archive. "
                    "The original baseline HEAD and existing commits are preserved. Review the SAME stage, including the "
                    "full adopted files and publication history, through all three review loops anew. Ownership acceptance earns "
                    "no review or CI credit. Do not repeat completed implementation or perform Git writes. "
                    "The runtime will reconcile existing pushes and finish remaining reviewed publication afterward.")
        pending = state.get("pending") or {}
        if (state["phase"] == "code" and state.get("code_started")
                and (pending.get("resume_code", True) or pending.get("attempts", 0))):
            context["coding_recovery"] = "This stage already started. The code phase includes reconstructing its lost/rejected final report without repeating completed implementation. Pending reviews do not require choosing another stage. Only the runtime advances the phase after validating the coding result."
        if role == "publish":
            context.update(remote=state["remote"], ref="refs/heads/main",
                           reviewed={"head": state["reviewed"]["head"], "files_sha256": digest(encode(state["reviewed"]["files"]))},
                           stage_paths=self.publication_paths())
        if role in ("publish", "heal"):
            context["publication_executor"] = "runtime; provider roles must not stage, commit or push"
            context["publication_artifacts"] = str(self.store.directory / "publication")
        if role == "heal":
            context["blocker"] = state["blocker"]
        if role == "code" and (state.get("pending") or {}).get("resume_code"):
            context["recovery"] = "Coding for this iteration already started. Finish that SAME stage; do not select another stage, even if prior conversation text says it was completed. Reconstruct and report its result if only the final response was lost."
        prompt = PROMPTS[role]
        if role == "sol":
            prompt = prompt.replace("%%DESCRIPTION%%", state["code_report"] or "No coding report was completed; review the preserved in-progress changes and handoff.")
        context["task"] = state.get("task")
        return prompt + "\n\nRuntime context:\n" + json.dumps(context, ensure_ascii=False)

    def invoke(self, role):
        state = self.state
        pending = state["pending"]
        if pending and pending["role"] != role:
            raise Blocked("state-phase", f"Pending {pending['role']} cannot be replaced by {role}.")
        if pending and pending.get("correction_revision") != state.get("correction_revision"):
            raise Blocked("correction-stale-result", "This invocation predates the latest operator correction; it must not be replayed.")
        if not pending:
            pending = {"id": uuid.uuid4().hex, "role": role, "iteration": state["iteration"],
                       "before": self.snapshot(), "started": time.time(),
                       "correction_revision": state.get("correction_revision")}
            if role == "code":
                pending["resume_code"] = self.state.get("code_started", False)
                self.state["code_started"] = True
            if role == "publish":
                self.state["publication_started"] = True
                pending["publication_readonly"] = True
            state["pending"] = pending
            self.save()  # The intent is durable before a provider can do any work.
        directory = self.store.directory / "invocations" / pending["id"]
        directory.mkdir(parents=True, exist_ok=True)
        if not (directory / "intent.json").exists():
            self.store.artifact(f"invocations/{pending['id']}/intent.json", encode(pending))
        result_path = directory / "result.json"
        print(f"cc-focus: iteration={state['iteration']} role={role}", flush=True)
        if self.progress:
            self.progress.start(role, directory)
        prompt = self.context(role)
        unresolved = self.messages.unresolved(state["iteration"])
        if any(item["identity"]["invocation"] != pending["id"] or item["status"] != "queued" for item in unresolved):
            raise MessagePending("Unresolved message delivery; use cc-focus messages and explicitly retry or discard it.")
        accepted_ids = [item["identity"]["id"] for item in self.messages.accepted(state["iteration"], pending["id"])]
        cached = json.loads(result_path.read_text(encoding="utf-8")) if result_path.exists() else None
        if cached and not unresolved and cached.get("operator_messages", []) == accepted_ids:
            result = cached
            if self.snapshot(result["after"]) != self.snapshot():
                raise Blocked("result-drift", "Repository changed after the recorded result; review evidence is stale.")
        else:
            if role == "publish":
                pending["publication_readonly"] = True
                pending["publication_before"] = self.snapshot()
                self.save()
            quota = pending.get("quota_wait")
            unchanged_refusal = False
            if quota:
                current = self.snapshot()
                self.check_protected(current)
                if self.snapshot(pending["before"])["head"] != current["head"]:
                    raise Blocked("unauthorized-commit", "HEAD changed across the quota wait; work was preserved.")
                unchanged_refusal = quota["no_work"] and self.snapshot(pending["before"]) == current
                pending.pop("quota_wait")
            if pending.get("attempts", 0) and role in ("sol", "claude", "astra") and not unchanged_refusal:
                # An interrupted pass may have fixed implementation before its
                # final report was lost. Earlier clean passes cannot certify that
                # new content, even if the resumed pass itself makes no fixes.
                reset_notice(state, "Прерванный проход повторяется", (role,))
                self.state[role + "_clean"] = 0
                if role in ("claude", "astra") and self.changes(pending["before"], self.snapshot()):
                    pending["return_to_sol"] = True
                self.save()
            if quota:
                self.save()  # A later interruption is not an admission refusal.
            raw = self.transport.run(role, prompt, pending, directory)
            if self.messages.unresolved(state["iteration"], pending["id"]):
                raise MessagePending("Input remains undelivered; the saved invocation cannot advance yet.")
            if cached:
                self.store.artifact(f"invocations/{pending['id']}/prior-result-{uuid.uuid4().hex}.json", encode(cached))
            result = {"raw": raw, "before": pending["before"], "after": self.snapshot(),
                      "operator_messages": [item["identity"]["id"] for item in self.messages.accepted(state["iteration"], pending["id"])]}
            self.store.artifact(f"invocations/{pending['id']}/result.json", encode(result))
        report = parse_report(result["raw"], role)
        if pending.get("correction_revision") != state.get("correction_revision"):
            raise Blocked("correction-stale-result", "This invocation predates the latest operator correction; its result cannot advance the stage.")
        if state.get("correction_pending") and role in ("coordinate", "code") and report["status"] == "complete":
            raise Blocked("correction-unfinished", "The current stage has an operator correction pending; complete cannot bypass coding and reviews.")
        before, after = self.snapshot(pending["before"]), self.snapshot(result["after"])
        self.check_protected(after)
        if role != "publish" and before["head"] != after["head"]:
            raise Blocked("unauthorized-commit", f"{role} changed HEAD outside publication; work was preserved.")
        if role == "coordinate" and before != after:
            raise Blocked("coordinator-mutation", "The coordinator changed repository state; its role is read-only.")
        if (role == "publish" and pending.get("publication_readonly")
                and self.snapshot(pending.get("publication_before", pending["before"])) != after):
            raise Blocked("publisher-mutation", "The publisher changed repository state; only the runtime may stage, commit or push.")
        if report["status"] == "blocked":
            raise Blocked("reported-blocker", report["summary"] + "\n" + report["description"])
        if role in ("sol", "claude", "astra"):
            if report["status"] != "done" or not report["evidence"]:
                raise Blocked("incomplete-review", "A review requires a completed pass and actual verification evidence.")
            if self.changes(before, after) and not sum(report[k] for k in ("implementation_fixes", "other_fixes", "minor_edits")):
                raise Blocked("unreported-fix", "Review changed files but reported no changes.")
        summary = concise_summary(report["summary"])
        accept_task(state, report, role)
        if role != "coordinate":
            state["last"] = {"role": role, "summary": summary, "report": str(result_path)}
        else:
            state["coordination"] = {"phase": state["phase"], "summary": summary, "report": str(result_path)}
        state["last_snapshot"] = after
        if self.progress and self.progress.output:
            self.progress.output.boundary()
        print(terminal_text(summary), flush=True)
        if self.progress:
            self.progress.result(report)
            self.progress.note(f"{role} result validated; report: {result_path}")
        return report, before, after, result["raw"]

    def complete_invocation(self):
        if self.state["pending"]["role"] == "code":
            self.state["correction_pending"] = None
        if self.state["pending"]["role"] in ("code", "sol", "claude", "astra"):
            self.state["recovery_unverified"] = False
        self.state["pending"] = None
        self.save()

    def correct(self, message):
        """Accept operator text under the exclusive runtime lock and shared lease."""
        state = self.state
        if self.messages.unresolved(state["iteration"]):
            raise Blocked("correction-messages", "Resolve queued/uncertain messages first (retry or discard); a correction must not orphan their invocation.")
        data = message.encode("utf-8")
        if not message.strip() or len(data) > 65536 or "\0" in message:
            raise Blocked("correction-text", "Supply nonempty UTF-8 correction text without NUL, at most 64 KiB.")
        if not state.get("code_started") or state["status"] == "complete":
            raise Blocked("correction-stage", "No started stage is available to correct. Use a handoff for new work; a completed publication cannot be reopened here.")
        pending = state.get("pending")
        if (state["phase"] not in ("code", "sol", "claude", "astra", "publish") or state.get("published") or state.get("publication_started")
                or (state["phase"] == "publish" and (pending or state.get("blocker")))):
            raise Blocked("correction-publication", "Publication may have started. Resume/reconcile commit, push and CI before new work; this command cannot rewind that window.")
        current = self.snapshot()
        if current["head"] != state["baseline"]["head"]:
            raise Blocked("correction-head", "HEAD changed since this stage started; reconcile publication before applying a correction.")
        self.check_protected(current)
        self.record_correction(data, current)

    def record_correction(self, data, current, *, candidate=None, metadata=None, validate=None, resume_phase="code"):
        """Persist an already-validated operator transition; never a provider action."""
        state = self.state
        if resume_phase not in ("code", "sol"):
            raise ValueError("An operator correction must resume coding or first review.")
        if not data.strip() or len(data) > 65536 or b"\0" in data:
            raise Blocked("correction-text", "Correction text must be nonempty UTF-8 without NUL, at most 64 KiB.")
        corrections = list(state.get("corrections", []))
        if len(corrections) >= 32:
            raise Blocked("correction-limit", "This stage already has 32 corrections; finish or reconcile it before adding more.")
        directory = self.store.directory / "corrections"
        if not directory.resolve().is_relative_to(self.store.directory.resolve()):
            raise Blocked("correction-path", "The correction directory resolves outside focus state; no correction was accepted.")
        correction_id = uuid.uuid4().hex
        archive_bytes = encode({"action": "operator-correction", "at": time.time(), "previous_state": state, **(metadata or {})})
        archive = self.store.artifact(f"corrections/{correction_id}.json", archive_bytes)
        path = self.store.artifact(f"corrections/{correction_id}.md", data)
        corrections.append({"id": correction_id, "iteration": state["iteration"],
                            "path": path, "sha256": digest(data), "archive": archive,
                            "archive_sha256": digest(archive_bytes), "before_code": not state.get("code_started", False)})
        if resume_phase == "sol":
            corrections[-1]["publication_recovery"] = True
        if validate:
            validate()
        previous = copy.deepcopy(state)
        try:
            if candidate is not None:
                state.clear()
                state.update(candidate)
            self.reset_reviews("Оператор согласовал область публикации" if resume_phase == "sol" else "Оператор изменил требования")
            if not state.get("code_started"):
                # A coordinator's provisional label must not pin the old plan's
                # stage before the operator's updated instructions are read.
                state["task"] = None
            state.update(phase=resume_phase, status="paused", pending=None, blocker=None,
                         healed=[], recovery_unverified=False, coordination=None,
                         corrections=corrections, correction_revision=correction_id,
                         correction_pending=correction_id if state.get("code_started") and resume_phase == "code" else None, last_snapshot=current)
            self.save()
        except BaseException:
            # The CLI may save an interrupted status while handling this error.
            # It must not accidentally accept the failed ownership transition.
            state.clear()
            state.update(previous)
            raise
        continuation = ("Paused before first review of the SAME stage; all three review loops must run again." if resume_phase == "sol" else
                        "Paused before coding the SAME stage; all three reviews must run again." if state.get("code_started") else
                        "Paused before stage selection from the current plan; any unpublished work requires coding and all three reviews.")
        print(f"cc-focus: correction {correction_id[:12]} saved for iteration {state['iteration']}. "
              + continuation + " Sessions and work preserved.", flush=True)
        print("Run cc-focus to apply the correction and continue. No model was started.", flush=True)

    def recover_review(self, source):
        """Operator-selected recovery of a completed, unpublished coding result."""
        state = self.state
        if self.messages.records(state["iteration"]):
            raise Blocked("recovery-messages", "This stage has operator-message history. Resume the saved invocation or apply a stopped-stage correction; an older coding report cannot bypass those instructions.")
        self.validate_corrections()
        if (state["phase"] != "code" or not state.get("code_started")
                or state.get("published") or state["status"] not in ("blocked", "interrupted", "paused")):
            raise Blocked("recovery-phase", "Review recovery requires a stopped, already-started code phase with no publication.")
        path = Path(source).resolve(strict=True)
        if (path.name != "result.json" or not re.fullmatch(r"[0-9a-f]{32}", path.parent.name)
                or not path.is_relative_to(self.store.directory.resolve())
                or path.parent.parent != (self.store.directory / "invocations").resolve()):
            raise Blocked("recovery-source", "Use this repository's saved code invocation result.json, not a healer report or an external file.")
        try:
            intent = json.loads((path.parent / "intent.json").read_text(encoding="utf-8"))
            result_bytes = path.read_bytes()
            result = json.loads(result_bytes)
            if (intent["role"] != "code" or intent["id"] != path.parent.name
                    or intent.get("iteration", state["iteration"]) != state["iteration"]
                    or intent.get("correction_revision") != state.get("correction_revision")
                    or result["before"] != intent["before"]):
                raise ValueError("the artifact is not a coding result for the current iteration")
            report = parse_report(result["raw"], "code")
            if report["status"] != "done":
                raise ValueError("coding did not report a completed stage")
            current = self.snapshot()
            if self.snapshot(result["after"]) != current:
                raise ValueError("files, HEAD or index differ from the saved coding result; do not overwrite them")
            if not (result["before"]["head"] == current["head"] == state["baseline"]["head"]):
                raise ValueError("HEAD changed; this recovery must not bypass publication reconciliation")
        except (ValueError, KeyError, TypeError) as error:
            raise Blocked("recovery-evidence", f"Cannot recover review from this report: {error}") from error
        self.check_protected(current)
        if not (self.store.directory / "recoveries").resolve().is_relative_to(self.store.directory.resolve()):
            raise Blocked("recovery-archive", "The recovery archive directory resolves outside focus state; no transition was applied.")
        archive = self.store.artifact(f"recoveries/{uuid.uuid4().hex}.json", encode({
            "action": "operator-review-from", "at": time.time(), "source": str(path),
            "source_sha256": digest(result_bytes), "previous_state": state}))
        self.reset_reviews("Восстановлен отчёт; ревью требуется заново")
        state.update(status="paused", blocker=None, pending=None, recovery_unverified=False,
                     correction_pending=None,
                     code_report=result["raw"], last_snapshot=current, coordination=None,
                     last={"role": "code", "summary": concise_summary(report["summary"]), "report": str(path)})
        self.save()
        print(f"cc-focus: recovered coding result; paused before Sol review. No review credit or publication was granted. Backup: {archive}", flush=True)
        print("Run cc-focus to start the required reviews; native sessions and project files were preserved.", flush=True)

    def review(self, role):
        report, before, after, _ = self.invoke(role)
        counted = report["implementation_fixes"] + (report["other_fixes"] if role == "astra" or
                   role == "sol" and self.state["sol_passes"] < 3 else 0)
        review_event(self.state, role, "исправления" if counted else "чисто",
                     f"Зачитываемых исправлений: {counted}" if counted else "", completed=True)
        if role == "sol":
            self.state["sol_passes"] += 1
            count = report["implementation_fixes"]
            if self.state["sol_passes"] <= 3:
                count += report["other_fixes"]
            self.state["sol_clean"] = 0 if count else self.state["sol_clean"] + 1
            if self.state["sol_clean"] >= 3:
                self.state.update(phase="claude", claude_clean=0, coordinated=None)
        elif role == "claude":
            count = report["implementation_fixes"]
            self.state["claude_clean"] = 0 if count else self.state["claude_clean"] + 1
            if (count and report["substantial"]) or self.state["pending"].get("return_to_sol"):
                self.reset_reviews("Opus изменил реализацию; возврат к Sol")
            elif self.state["claude_clean"] >= 2:
                self.state.update(phase="astra", astra_clean=0, coordinated=None)
        elif role == "astra":
            self.state["astra_clean"] = 0 if counted else self.state.get("astra_clean", 0) + 1
            if report["substantial"] or self.state["pending"].get("return_to_sol"):
                self.reset_reviews("Astra изменила реализацию; возврат к Sol")
            elif self.state["astra_clean"] >= 1:
                self.state.update(phase="publish", reviewed=after, coordinated=None)
        self.complete_invocation()
        if self.progress:
            self.progress.note(f"Review complete: Sol clean={self.state['sol_clean']}/3, Opus clean={self.state['claude_clean']}/2, Astra clean={self.state['astra_clean']}/1; next={self.state['phase']}")

    def remote_head(self, remote):
        def progress(attempt, attempts):
            if self.progress:
                self.progress.runtime("git")
                self.progress.note(f"Checking remote main at the push URL ({attempt}/{attempts}); no model is running.")
            self.heartbeat()
        try:
            return self.repo.remote_head(remote, progress=progress)
        finally:
            if self.progress:
                self.progress.finish()

    def prepare_publish(self):
        reviewed = self.state["reviewed"]
        current = self.snapshot()
        if not reviewed or self.changes(reviewed, current):
            # Abandon only the invalidated publication intent; its artifacts remain.
            self.state["pending"] = None
            self.reset_reviews("Файлы изменились после ревью")
            self.save()
            return False
        self.check_protected(current)
        self.validate_publication_commit()
        remote = self.state.get("remote") or self.repo.remote()
        if self.repo.remote() != remote:
            raise Blocked("remote-changed", "The publication remote changed since the stage was reviewed.")
        self.state["remote"] = remote
        push_url = self.repo.push_url(remote)
        if self.state.get("publication_push_url", push_url) != push_url:
            raise Blocked("remote-changed", "The publication push URL changed since preparation.")
        self.state["publication_push_url"] = push_url
        remote_head = self.remote_head(remote)
        known_heads = {self.state["baseline"]["head"], current["head"]}
        if self.state.get("published"):
            known_heads.add(self.state["published"]["sha"])
        if remote_head not in known_heads:
            raise Blocked("remote-drift", "Remote main differs from the stage baseline; reconcile it without force or discarding WIP.")
        policy = self.policy("check-publish", "--branch", "main", "--remote", remote)
        if policy.returncode:
            raise Blocked("publish-policy", policy.stderr.decode("utf-8", errors="replace")[-3000:])
        if not self.publication_paths():
            raise Blocked("empty-stage", "No stage changes to publish. Report complete only when the stage source is exhausted.")
        self.state["publication_paths"] = self.publication_paths()
        self.save()
        return True

    def publication_paths(self):
        paths = set(self.state.get("publication_paths", [])) | set(self.changes(self.state["baseline"], self.state["reviewed"]))
        published = self.state.get("published")
        if not self.state.get("publication_paths") and published and isinstance(self.state["baseline"]["head"], str):
            # Legacy state already certified this commit. Preserve its owned
            # paths when a newly reviewed CI fix restores their baseline bytes.
            paths.update(os.fsdecode(name) for name in self.repo.git(
                "diff", "--name-only", "-z", "--no-renames", self.state["baseline"]["head"], published["sha"]
            ).stdout.split(b"\0") if name)
        return sorted(paths)

    def validate_publication_commit(self):
        current = self.snapshot()
        reviewed = self.state["reviewed"]
        self.check_protected(current)
        if self.changes(reviewed, current):
            raise Blocked("publish-drift", "Publication changed reviewed content; all three reviews must run again.")
        if current["head"] == self.state["baseline"]["head"]:
            return False
        committed = publication_history(self.repo, self.state["baseline"]["head"], current["head"])
        owned = set(self.publication_paths())
        if not committed or not committed <= owned:
            raise Blocked("unreviewed-commit", "Publication includes files outside the reviewed stage.")
        remaining = set(self.repo.dirty_paths()) - set(self.state["protected"])
        if remaining - owned:
            raise Blocked("uncommitted-stage", "Reviewed stage files remain uncommitted: " + ", ".join(sorted(remaining)))
        if remaining:
            return False
        return True

    def reconcile_publish(self):
        if not self.validate_publication_commit():
            return False
        current = self.snapshot()
        if self.remote_head(self.state["remote"]) != current["head"]:
            return False
        self.state["published"] = {"sha": current["head"], "at": time.time(), "remote": self.state["remote"]}
        self.state.update(phase="ci", pending=None, coordinated=None, last_snapshot=current, recovery_unverified=False)
        self.save()
        return True

    def publish(self):
        if not self.prepare_publish():
            return
        # Reconcile before the model is allowed to repeat a possibly completed push.
        if self.reconcile_publish():
            return
        prepared = self.state.get("publication_prepared")
        fingerprint = digest(encode(self.snapshot(self.state["reviewed"])))
        if not prepared or prepared["reviewed_sha256"] != fingerprint:
            report, _, _, _ = self.invoke("publish")
            if report["status"] != "done":
                raise Blocked("publication-unconfirmed", "The publisher did not confirm readiness for publication.")
            subject = " ".join("".join(c if c.isprintable() else " " for c in report["summary"]).split())[:160]
            prepared = {"reviewed_sha256": fingerprint, "subject": subject or "Publish reviewed changes"}
            self.state["publication_prepared"] = prepared
            self.complete_invocation()
        # Revalidate policy, remote, work and ownership after the read-only model.
        if not self.prepare_publish():
            return
        self.execute_publication(prepared["subject"])
        if not self.reconcile_publish():
            raise Blocked("publication-unconfirmed", "Commit/push did not produce the reviewed stage at remote main.")

    def execute_publication(self, subject):
        from focus_commit import commit_reviewed, push_reviewed
        commit_reviewed(self, subject)
        push_reviewed(self)

    def handle_block(self, error):
        state = self.state
        if state.get("pending"):
            role = state["pending"]["role"]
            if role in ("sol", "claude", "astra"):
                review_event(state, role, "не зачтено", error.code)
                state[role + "_clean"] = 0
                if role in ("claude", "astra") and self.changes(state["pending"]["before"], self.snapshot()):
                    self.reset_reviews("Прерванное ревью изменило файлы; возврат к Sol")
        signature = digest(encode({"code": error.code, "message": str(error)}))
        if state.get("blocker") and state["blocker"]["status"] == "healing":
            state["blocker"].update(status="blocked", resolution=str(error), escalation_reason="healer-failed")
        else:
            state["blocker"] = {"code": error.code, "message": str(error), "signature": signature,
                                "phase": state["phase"], "status": "healing", "at": time.time()}
            reason = ("manual-action" if error.code in MANUAL_BLOCKERS else
                      "unsafe-provider" if error.code in UNSAFE_PROVIDER_BLOCKERS else
                      "verification-failed" if state.get("recovery_unverified") else
                      "repeated-blocker" if signature in state["healed"] else None)
            if reason:
                state["blocker"].update(status="blocked", escalation_reason=reason)
            else:
                state["healed"].append(signature)
        interrupted = state["pending"]
        state["blocker"]["interrupted"] = ({"id": interrupted["id"], "role": interrupted["role"],
            "artifacts": str(self.store.directory / "invocations" / interrupted["id"])} if interrupted else None)
        state["pending"] = None
        state["status"] = state["blocker"]["status"]
        self.save()
        if state["status"] == "healing":
            print("cc-focus: routing blocker to the separate Astra/xhigh recovery agent; no operator action needed yet.", flush=True)

    def heal(self):
        report, before, after, _ = self.invoke("heal")
        if report["status"] != "done":
            raise Blocked("unresolved", report["summary"])
        blocker = self.state["blocker"]
        if self.changes(before, after):
            self.reset_reviews("Восстановитель изменил файлы")
            if blocker["phase"] == "code":
                # Resolving a coding dependency is not a completed coding stage.
                self.state["phase"] = "code"
        else:
            self.state["phase"] = blocker["phase"]
            self.state["coordinated"] = None
        self.state.update(blocker=None, status="ready", recovery_unverified=True)
        self.complete_invocation()

    def defer_quota(self, error):
        pending = self.state["pending"]
        current = self.snapshot()
        self.check_protected(current)
        if self.snapshot(pending["before"])["head"] != current["head"]:
            raise Blocked("unauthorized-commit", "Claude changed HEAD before its quota refusal; work was preserved.")
        no_work = error.no_work and self.snapshot(pending["before"]) == current
        if not no_work and pending["role"] in ("sol", "claude", "astra"):
            reset_notice(self.state, "Квота прервала начатый проход", (pending["role"],))
            self.state[pending["role"] + "_clean"] = 0
            if pending["role"] in ("claude", "astra") and self.changes(pending["before"], current):
                pending["return_to_sol"] = True
        # A stale reset or repeated rejection must not create a tight retry loop.
        pending["quota_wait"] = {"resets_at": error.resets_at,
                                 "retry_at": max(error.resets_at + 5, time.time() + 60),
                                 "no_work": no_work}
        self.save()
        retry = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(pending["quota_wait"]["retry_at"]))
        print(f"cc-focus: quota wait until {retry}; same phase/session will retry automatically. No review credit earned.", flush=True)

    def wait_quota(self):
        quota = (self.state.get("pending") or {}).get("quota_wait")
        if not quota or time.time() >= quota["retry_at"]:
            return False
        if self.progress:
            if self.progress.operation != "quota":
                self.progress.runtime("quota")
            retry = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(quota["retry_at"]))
            self.progress.activity = f"Waiting for Claude quota until {retry}; automatic retry; no model is running"
            self.progress.pulse()
        # Re-enter the normal boundary for stop, PAUSE, lease and input checks.
        time.sleep(min(0.25, max(0, quota["retry_at"] - time.time())))
        return True

    def run(self):
        while self.state["status"] != "complete":
            self.heartbeat()
            unresolved = self.messages.unresolved(self.state["iteration"])
            pending_id = (self.state.get("pending") or {}).get("id")
            if any(item["status"] != "queued" or item["identity"]["invocation"] != pending_id for item in unresolved):
                raise MessagePending("Message delivery needs an operator decision. Use cc-focus messages; retry-message --id ID may resend, discard-message --id ID abandons delivery.")
            if self.state.get("review_profile") != REVIEW_PROFILE_VERSION:
                self.upgrade_review_profile()
                continue
            blocker = self.state.get("blocker")
            if blocker and blocker["status"] == "blocked":
                reason = ESCALATION_REASONS.get(blocker.get("escalation_reason"))
                if reason:
                    print("cc-focus: " + reason, flush=True)
                print(terminal_text("cc-focus: blocked: " + blocker.get("resolution", blocker["message"])), flush=True)
                print("Resolve the problem, then run cc-focus --retry. Work and sessions are preserved.", flush=True)
                if self.state["phase"] == "code" and self.state.get("code_started"):
                    print("If coding completed but its report was rejected: cc-focus recover --review-from .work/cycle/invocations/CODE_INVOCATION_ID/result.json (see the recovery guide; never use the healer report).", flush=True)
                return 3
            phase = self.state["phase"]
            # Publication and CI are a single window, including recovery inside it.
            publication_window = phase == "ci" or (phase == "publish" and self.state.get("pending"))
            if self.control and self.control.boundary(publication_window):
                self.state["status"] = "paused"
                self.save()
                print(f"cc-focus: safe stop before {phase}; state saved. Run cc-focus to continue.", flush=True)
                return 0
            if not publication_window and self.repo.paused():
                self.state["status"] = "paused"
                self.save()
                print(f"cc-focus: paused before {phase}; PAUSE was left unchanged.", flush=True)
                return 0
            if self.state["status"] in ("paused", "interrupted"):
                self.state["status"] = "ready"
                self.save()
            try:
                if blocker:
                    self.heal()
                    continue
                if self.wait_quota():
                    continue
                if phase == "ci":
                    if self.progress:
                        self.progress.role = None
                        self.progress.note("Waiting for CI on the published commit; no model is running.")
                    self.wait_ci()
                    self.next_stage()
                    continue
                pending = self.state["pending"]
                if not pending and phase in ("sol", "claude", "astra", "publish"):
                    current = self.snapshot()
                    if self.changes(self.state["last_snapshot"], current):
                        self.check_protected(current)
                        self.reset_reviews("Файлы изменились после ревью")
                        self.state["last_snapshot"] = current
                        self.save()
                        continue
                if self.state["coordinated"] != phase and (not pending or pending["role"] == "coordinate"):
                    report, _, after, _ = self.invoke("coordinate")
                    if report["status"] == "complete":
                        if phase != "code" or self.changes(self.state["baseline"], after):
                            raise Blocked("premature-completion", "The coordinator cannot skip unfinished review/publication.")
                        self.state["status"] = "complete"
                    self.state["coordinated"] = phase
                    self.complete_invocation()
                    continue
                if phase == "code":
                    report, _, after, raw = self.invoke("code")
                    if report["status"] == "complete":
                        if self.changes(self.state["baseline"], after):
                            raise Blocked("premature-completion", "Coding left changes; review and publication are still required.")
                        self.state["status"] = "complete"
                    else:
                        self.state["code_report"] = raw
                        self.reset_reviews()
                    self.complete_invocation()
                elif phase in ("sol", "claude", "astra"):
                    self.review(phase)
                elif phase == "publish":
                    self.publish()
                else:
                    raise Blocked("invalid-phase", f"Unknown phase: {phase}")
            except Blocked as error:
                print(terminal_text(f"cc-focus: {error.code}: {error}"), flush=True)
                if isinstance(error, ProviderQuota):
                    try:
                        self.defer_quota(error)
                    except Blocked as guard_error:
                        error = guard_error
                    else:
                        continue
                if self.messages.unresolved(self.state["iteration"]) and self.state.get("pending"):
                    # Retain the exact delivery target across transport failure.
                    # A healer/new intent must not orphan queued or uncertain input.
                    if error.code == "cleanup-incomplete":
                        raise
                    raise MessagePending(f"{error.code}: {error}. The original invocation and operator messages were preserved; inspect delivery before resuming.") from error
                self.handle_block(error)
                if self.control and self.control.request():
                    self.state["status"] = "paused"
                    self.save()
                    print("cc-focus: stopped at a preserved blocker; recovery will run only after continuation.", flush=True)
                    return 0
        print("cc-focus: stage source complete.", flush=True)
        return 0

    def next_stage(self):
        self.assert_publication_current()
        self.store.artifact(f"iterations/{self.state['iteration']:06d}.json", encode(self.state))
        self.state.update(iteration=self.state["iteration"] + 1, phase="code", status="ready",
                          baseline=self.snapshot(), protected=self.repo.dirty_paths(),
                          protected_index=self.repo.index_entries(self.repo.dirty_paths()),
                          code_report="", reviewed=None, published=None, pending=None,
                          sol_passes=0, sol_clean=0, claude_clean=0, astra_clean=0, coordinated=None,
                          last_snapshot=self.snapshot(), code_started=False, healed=[], recovery_unverified=False,
                          corrections=[], correction_revision=None, correction_pending=None, coordination=None,
                          publication_started=False)
        self.state.pop("publication_prepared", None)
        self.state.pop("publication_push_url", None)
        self.state.pop("publication_paths", None)
        self.state.pop("publication_review_profile", None)
        self.state.update(task=None, display_reviews=new_reviews(), display_review_events=[], display_ci=None)
        if self.state["baseline"].get("repositories"):
            for key in ("publication_targets", "publication_repositories", "remote"):
                self.state.pop(key, None)
        self.save()

    def ci_gate(self, sha, records, elapsed):
        checks = self.store.artifact("ci/checks.json", encode(records))
        response = self.policy("check-gate", "--sha", sha, "--checks-from", checks,
                               "--elapsed-sec", str(int(elapsed)), "--deadline-sec", "1800",
                               "--backoff-sec", "30", "--json")
        try:
            gate, _ = json.JSONDecoder().raw_decode(response.stdout.decode("utf-8").lstrip())
            if response.returncode not in (0, 9, 10) or "verdict" not in gate:
                raise ValueError("invalid gate")
            return gate
        except ValueError as error:
            raise Blocked("ci-policy", "Cannot evaluate configured CI requirements.") from error

    def github(self, remote):
        url = self.repo.push_url(remote)
        match = re.fullmatch(r"(?:https://|ssh://git@|git@)([^/:]+)[:/]([^/]+/[^/]+?)(?:\.git)?", url)
        if not match:
            raise Blocked("unsupported-ci-host", "Automatic CI requires a GitHub remote and gh authentication.")
        return match.group(1), match.group(2)

    def gh_records(self, host, repo, sha):
        def query(suffix, selector):
            result = command(["gh", "api", "--hostname", host, "--paginate",
                              f"repos/{repo}/{suffix}", "--jq", selector], self.repo.root)
            decoder, raw, values = json.JSONDecoder(), result.stdout.decode("utf-8"), []
            try:
                while raw.strip():
                    page, offset = decoder.raw_decode(raw.lstrip())
                    if not isinstance(page, list):
                        raise ValueError("expected an array")
                    values.extend(page)
                    raw = raw.lstrip()[offset:]
            except ValueError as error:
                raise Blocked("ci-protocol", f"Invalid GitHub CI response: {error}") from error
            return values
        checks = query(f"commits/{sha}/check-runs?per_page=100", ".check_runs")
        statuses = query(f"commits/{sha}/statuses?per_page=100", ".")
        runs = query(f"actions/runs?head_sha={sha}&event=push&per_page=100", ".workflow_runs")
        records = [{"name": c["name"], "head_sha": c["head_sha"], "status": c["status"],
                    "conclusion": c.get("conclusion"), "run_id": c["id"], "source": "check"} for c in checks]
        records += [{"name": c["context"], "head_sha": sha,
                     "status": "in_progress" if c["state"] == "pending" else "completed",
                     "conclusion": c["state"], "run_id": c["id"], "source": "status"} for c in statuses]
        records += [{"name": c["name"], "head_sha": c["head_sha"], "status": c["status"],
                     "conclusion": c.get("conclusion"), "run_id": c["id"], "source": "workflow"} for c in runs]
        return records

    def assert_publication_current(self):
        published = self.state["published"]
        current = self.snapshot()
        self.check_protected(current)
        if (current["head"] != published["sha"] or self.changes(self.state["reviewed"], current)
                or self.remote_head(published["remote"]) != published["sha"]):
            raise Blocked("ci-head-drift", "Local/remote main or reviewed content changed during the publication window.")

    def wait_ci(self):
        published = self.state["published"]
        sha = published["sha"]
        self.assert_publication_current()
        if self.progress:
            self.progress.runtime("ci")
        gate = self.ci_gate(sha, [], 0)
        ci_paths = {os.fsdecode(name) for name in self.repo.git(
            "ls-tree", "-r", "--name-only", "-z", sha).stdout.split(b"\0") if name}
        has_workflows = any(name.startswith(".github/workflows/") and name.endswith((".yml", ".yaml")) for name in ci_paths)
        external_ci = ci_paths & {".gitlab-ci.yml", ".gitlab-ci.yaml", "Jenkinsfile", "azure-pipelines.yml",
                                  ".circleci/config.yml", ".buildkite/pipeline.yml", ".drone.yml", ".woodpecker.yml"}
        if external_ci and gate["verdict"] == "no-required-checks":
            raise Blocked("unsupported-ci", "External CI configuration detected: " + ", ".join(sorted(external_ci))
                          + ". Automatic waiting currently supports GitHub checks; external CI must not be silently skipped.")
        configured = gate["verdict"] != "no-required-checks" or has_workflows
        if not configured:
            self.store.artifact("ci/result.json", encode({"sha": sha, "verdict": "not-configured"}))
            self.state["display_ci"] = {"sha": sha, "status": "not-configured"}
            self.save()
            return
        host, repo = self.github(published["remote"])
        # Authentication is read-only; never change credentials to unblock a run.
        command(["gh", "auth", "status", "--hostname", host], self.repo.root)
        previous_green = None
        while True:
            self.heartbeat()
            elapsed = time.time() - published["at"]
            records = self.gh_records(host, repo, sha)
            gate = self.ci_gate(sha, records, elapsed)
            latest = {}
            for record in records:
                key = record.get("source", "check") + ":" + record["name"]
                if record["head_sha"] == sha and record["run_id"] > latest.get(key, {}).get("run_id", -1):
                    latest[key] = record
            terminal = bool(latest) and all(c["status"] == "completed" for c in latest.values())
            if has_workflows and not any(c.get("source") == "workflow" for c in latest.values()):
                terminal = False
            red = [c["name"] for c in latest.values() if c["status"] == "completed"
                   and c["conclusion"] not in ("success", "neutral", "skipped")]
            self.state["display_ci"] = {"sha": sha, "status": "waiting", "total": len(latest),
                                        "passed": sum(c["status"] == "completed" and c["conclusion"] in ("success", "neutral", "skipped") for c in latest.values())}
            self.save()
            if red or gate["verdict"] in ("failed", "timeout"):
                raise Blocked("ci-failed", f"CI is not green at {sha}: {', '.join(red)}; {gate['verdict']}")
            fingerprint = digest(encode(latest))
            if terminal and gate["verdict"] in ("ready", "no-required-checks"):
                if previous_green == fingerprint:
                    self.store.artifact("ci/result.json", encode({"sha": sha, "verdict": "ready", "checks": list(latest)}))
                    self.state["display_ci"]["status"] = "ready"
                    self.save()
                    return
                previous_green = fingerprint
            else:
                previous_green = None
            if elapsed >= 1800 and not (terminal and gate["verdict"] in ("ready", "no-required-checks")):
                raise Blocked("ci-timeout", f"Configured CI did not produce a complete green result at {sha} within 30 minutes.")
            print(f"cc-focus: waiting for CI at {sha[:12]} ({int(elapsed)}s); no model is running.", flush=True)
            if self.control:
                deadline = time.monotonic() + 30
                while time.monotonic() < deadline:
                    self.heartbeat()
                    time.sleep(min(1, max(0, deadline - time.monotonic())))
            else:
                time.sleep(30)
