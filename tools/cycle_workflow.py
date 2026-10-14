"""Deterministic barriers around the sequential coordinator's decisions."""

import copy
import json
import os
from pathlib import Path
import re
import time
import threading
import uuid

from cycle_prompts import (PROMPTS, REVIEW_PROFILE_VERSION, REVIEW_ROLES, REVIEW_TARGETS, review_target,
                           FINAL_ROLES, READONLY_REVIEW_ROLES)
from focus_review import FinalReview
from focus_pairs import PairedReview
from focus_pair_profile import PAIRS, PAIR_ROLES, PAIR_WRITERS
from focus_pair_view import read_record, artifact
from focus_snapshot_archive import compact_legacy_views
from cycle_state import Blocked, ProviderQuota, ProviderTransient, transient_exhausted, changed, command, digest, encode
from cycle_transport import (concise_summary, parse_report, report_object, repairable_executor_accounting,
                             repairable_substantial_accounting)
from focus_status import accept_task, new_reviews, reset_notice, review_event
from focus_output import terminal_text
from focus_messages import MessagePending, Messages


MANUAL_BLOCKERS = {"claude-access-denied", "approval-required", "approval-denied"}
UNSAFE_PROVIDER_BLOCKERS = {"cleanup-incomplete", "turn-active"}
# Server-error retries are exhausted. A recovery agent cannot retry a provider.
PROVIDER_UNAVAILABLE_BLOCKERS = {"claude-transient", "codex-transient"}
ACCOUNTING_REPAIRS = ("invocation-accounting", "substantial-accounting", "changed-file-accounting", "unchanged-accounting")
PROVIDER_RETRY_DELAYS = (15, 30, 60)
ESCALATION_REASONS = {
    "manual-action": "This action requires the operator; the recovery agent cannot supply consent or account access.",
    "provider-refusal": "Claude refused the request. Inspect the provider detail; automatic recovery cannot clear this refusal.",
    "unsafe-provider": "A prior provider may still be active; recovery cannot safely start another agent.",
    "provider-unavailable": "The provider still has a server failure after the automatic retries. Recovery cannot retry a provider.",
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
            "review_plan": [], "review_substantial": False, "review_targets": dict(REVIEW_TARGETS),
            "opus_final_clean": 0, "final_review": None, "backlog": [],
            "opus_clean": 0, "sol_passes": 0, "sol_clean": 0, "claude_clean": 0, "astra_clean": 0,
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


class Cycle(PairedReview, FinalReview):
    def __init__(self, repository, store, state, transport, heartbeat, scripts, pwsh, control=None, progress=None):
        self.repo, self.store, self.state = repository, store, state
        self.transport, self.heartbeat = transport, heartbeat
        self.scripts, self.pwsh = Path(scripts), pwsh
        self.control, self.progress = control, progress
        self.messages = Messages(store)
        self.state_lock = threading.RLock()

    def save(self):
        with self.state_lock:
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
        self.state["final_review"] = None
        self.state.update(sol_passes=0, claude_clean=0, **{role + "_clean": 0 for role in REVIEW_ROLES},
                          reviewed=None, coordinated=None, phase="opus",
                          review_plan=[{"role": role, "target": REVIEW_TARGETS[role]} for role in REVIEW_ROLES],
                          review_targets=dict(REVIEW_TARGETS), review_substantial=False)
        self.reset_pairs()

    def review_route(self, role):
        """Persist remaining visits; a repeat inserts a visit, never rewinds the plan."""
        if not self.state.get("review_plan"):
            self.state["review_plan"] = [{"role": name, "target": REVIEW_TARGETS[name]}
                                         for name in REVIEW_ROLES[REVIEW_ROLES.index(role):]]
        route = self.state["review_plan"]
        if route[0]["role"] != role:
            raise Blocked("review-route", "The saved review route does not match the current role; work was preserved.")
        return route

    def finish_review_loop(self, role, after):
        route = self.review_route(role)
        route.pop(0)
        if self.state.get("review_substantial"):
            extra = ([{"role": "opus", "target": 2, "repeat_for": role}] if role in ("sol", "astra") else
                     [{"role": "astra", "target": 2, "repeat_for": role}] if role == "opus_final" else [])
            route[:0] = extra
            for visit in extra:
                name = visit["role"]
                reset_notice(self.state, "Дополнительное ревью после " + role, (name,))
                self.state[name + "_clean"] = 0
                self.state.setdefault("review_targets", dict(REVIEW_TARGETS))[name] = visit["target"]
        self.state.update(review_substantial=False, coordinated=None)
        if route:
            visit = route[0]
            next_role = visit["role"]
            self.state.update(phase=next_role, **{next_role + "_clean": 0})
            self.state.setdefault("review_targets", dict(REVIEW_TARGETS))[next_role] = visit["target"]
        else:
            self.state.update(phase="final", final_review=None, reviewed=None)

    def upgrade_review_profile(self):
        """Archive legacy credit/sessions before using the current review profile.

        Called only with runtime ownership and no unresolved message delivery.
        An already-started publication retains its original seal through CI;
        changing it would strand partial pushes and operator reconciliation.
        Before that boundary, the current work receives the new review sequence.
        """
        state = self.state
        if state.get("review_profile") == REVIEW_PROFILE_VERSION:
            return
        old_profile = state.get("review_profile", 1)
        if type(old_profile) is not int or old_profile not in (1, 2, 3, 4, 5, 6, 7):
            raise Blocked("review-profile-version", "This saved review profile requires a newer runtime; work was preserved.")
        if self.messages.unresolved(state["iteration"]):
            raise MessagePending("Resolve pending messages before changing the review profile.")
        previous = copy.deepcopy(state)
        archive = self.store.artifact(f"review-profiles/{uuid.uuid4().hex}.json", encode(previous))
        pending = state.get("pending")
        publishing = state["phase"] == "publish" and state.get("publication_started")
        restart = state["phase"] in (*REVIEW_ROLES, "claude", *PAIRS, "publish") and not publishing
        # Reviewer conversations describe the previous order and review credit.
        # Coding and publication keep their same-stage context; their effective
        # model and effort are explicitly selected and checked by the transport.
        for role in (*REVIEW_ROLES, *FINAL_ROLES):
            state["sessions"].pop(role, None)
        if restart:
            legacy_rows = list((state.get("final_review") or {}).get("confirmed", []))
            for entry in state.get("backlog", []):
                if entry.get("iteration") == state["iteration"]:
                    legacy_rows.extend(entry.get("findings", []))
            carry = {row["source_id"]: row for row in self.pair_obligations()}
            for row in legacy_rows:
                if row.get("verdict") in (None, "confirmed") and all(k in row for k in ("source_id", "title", "body", "severity", "locations")):
                    identity = "legacy/" + row["source_id"]
                    carry[identity] = {"source_id": identity, "id": identity, "kind": "defect",
                                       **{k: row[k] for k in ("title", "body", "severity", "locations")}}
            state["pair_carry"] = list(carry.values())
        state.update(review_profile=REVIEW_PROFILE_VERSION, sol_passes=0,
                     opus_clean=0, sol_clean=0, claude_clean=0, astra_clean=0, opus_final_clean=0, final_review=None,
                     review_plan=[], review_targets=dict(REVIEW_TARGETS), review_substantial=False,
                     display_reviews=new_reviews(), display_review_events=[])
        state.pop("astra_passes", None)
        if publishing or state["phase"] == "ci":
            state.setdefault("publication_review_profile", old_profile)
        if restart:
            self.reset_reviews("Новый профиль: два чистых прохода проверки исправлений в B и финале")
            if pending and pending["role"] != "heal":
                state["pending"] = None
            if state.get("blocker"):
                state["blocker"]["phase"] = "pair_a"
            state.pop("publication_prepared", None)
        elif pending and pending["role"] == "code":
            # Opus replaces Fable for new coding responses, while a completed
            # cached result remains valid work for the same implementation stage.
            pending.pop("resolved_model", None)
            pending["attempts"] = max(1, pending.get("attempts", 0))
        state["review_profile_archive"] = str(archive)
        try:
            self.save()
        except BaseException:
            state.clear()
            state.update(previous)
            raise
        print(f"cc-focus: profile updated to parallel pairs A/B and the independent final pair; previous state and reviewer sessions archived: {archive}", flush=True)
        if publishing or state["phase"] == "ci":
            print("cc-focus: the already-started publication retains its original review seal through CI; new work uses all required reviews.", flush=True)

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
        if role in PAIR_WRITERS:
            return self.pair_writer_context(role)
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
                   "opus_clean": state.get("opus_clean", 0), "sol_passes": state["sol_passes"], "sol_clean": state["sol_clean"],
                   "claude_clean": state["claude_clean"], "astra_clean": state.get("astra_clean", 0),
                   "review_order": list(PAIRS) if state.get("review_profile", 0) >= 6 else list(REVIEW_ROLES), "published": state["published"]}
        context["review_route"] = state.get("review_plan", [])
        context["review_targets"] = state.get("review_targets", REVIEW_TARGETS)
        context["review_substantial"] = state.get("review_substantial", False)
        context["verification"] = {
            "full_run_allowed": role == "opus_final" or (role == "astra" and state.get("astra_clean", 0) >= 1),
            "builds_tests_allowed": role not in READONLY_REVIEW_ROLES,
            "policy": (
                'Limit builds and tests to affected areas. Final inspections and finding evaluation '
                'must not build or test. Late Opus permits justified full runs. Astra full runs need a'
                ' risk reason and an eligible clean streak. Substantive corrections in this invocation'
                ' remove that permission until a later clean pass.'
            )}
        context["handoff_instructions"] = (
            (
                "Handoffs are optional historical context. Read each imported 'path'. The 'source' "
                'identifies its origin, not a required file. Do not require or recreate HANDOFF.md. '
                'Use the current project plan and instructions. For an interrupted stage, also use the'
                ' saved task.\n\nKeep imported snapshots unchanged.'
            ))
        if state.get("review_profile") == REVIEW_PROFILE_VERSION and role in ("code", "coordinate", "heal", "publish"):
            for key in ("opus_clean", "sol_passes", "sol_clean", "claude_clean", "astra_clean", "review_substantial"):
                context.pop(key, None)
            context.update(review_route=list(PAIRS), review_targets={"pair_a": 1, "pair_b": 1, "final": 1},
                           pair_completed=state.get("pair_completed", {}),
                           review_exit=(
                               'Each pair repeats after significant findings. B/final repairs first require two clean'
                               ' inner passes and targeted tests. Minor-only repairs advance after that gate. Do not '
                               'return across pairs.'
                           ))
            context["verification"] = {
                "full_run_allowed": False, "builds_tests_allowed": role in ("code", "heal"),
                "policy": (
                    'Limit builds and tests to affected areas. B/final fix invocations must not test. Only'
                    ' the separate test invocation after two clean static passes can run checks. All '
                    'inspectors and arbiters are read-only. An explicit pair_b assignment can require a '
                    'full suite after the inner gate, with a stated risk reason.'
                )}
        if state.get("publication_review_profile") in (1, 2, 3, 4, 5, 6, 7):
            context["publication_review_profile"] = (
                (
                    'This publication started under a previous review profile. Its original reviewed '
                    'snapshot and publication/CI reconciliation remain valid. Do not require new-model '
                    'reviews to finish this existing publication. New work or changed reviewed content '
                    'must pass Pair A, Pair B, and the independent final pair. Original review evidence is'
                    ' at '
                ) + state["review_profile_archive"])
        if hasattr(self.repo, "handoff_sources"):
            context["optional_handoff_sources"] = sorted(self.repo.handoff_sources(state))
        accepted = self.messages.accepted(state["iteration"])
        if accepted:
            context["operator_messages"] = [{"id": item["identity"]["id"], "role": item["identity"]["role"],
                "path": str(self.messages.directory(state["iteration"]) / (item["identity"]["id"] + ".json")),
                "sha256": item["sha256"]} for item in accepted]
            context["message_instructions"] = (
                (
                    'Read identity.text in the accepted operator-message artifacts, from oldest to newest.'
                    ' They clarify this SAME stage, not role or permission boundaries. Include their '
                    'effect in the current result and later reviews. Accepted means received, not proof of'
                    ' implementation.'
                ))
        if corrections:
            context["operator_corrections"] = corrections
            context["correction_pending"] = state.get("correction_pending")
            before_code = corrections[-1].get("before_code", False)
            selection = (
                (
                    'The latest handover occurred BEFORE coding began in this iteration. Read the current '
                    'listed instruction files and project plan. If coding already selected or started a '
                    'stage in THIS iteration, finish that stage, including a lost report. Otherwise, '
                    'select the next unfinished stage. The last result or an older session can describe a '
                    'previous published stage. Do not reopen it.\n\n'
                )
                if before_code else
                'The operator stopped this SAME project stage. Do not select the next unfinished stage. If saved evidence cannot identify the original stage, report blocked. ')
            context["correction_instructions"] = (
                selection + (
                    'The operator supplied corrections from oldest to newest. Read the immutable '
                    'correction files. Later corrections replace conflicting task details, not role or '
                    'permission boundaries. Archive paths retain the original iteration and interrupted '
                    "invocation. In code, apply corrections to this iteration's work. Do not only "
                    'reconstruct the old report.\n\nIdentify correction IDs and their treatment in evidence.'
                    ' Coordinate confirms this route without implementation. Reviews check the corrected '
                    'stage again. Only a done coding result can acknowledge pending corrections. Complete '
                    'cannot skip them. Handover before coding does not mean that a stage started.\n\n'
                    'Complete still requires an exhausted plan and no unpublished changes, including '
                    'transferred files. Listed optional_handoff_sources can be absent after import. Their '
                    'absence does not block this correction. Follow current project instructions and '
                    'plans. Do not restore those transfer files.'
                ))
            if corrections[-1].get("publication_recovery"):
                context["publication_recovery"] = (
                    (
                        'The operator accepted the exact committed protected files in the latest correction '
                        'archive. Keep the original baseline HEAD and existing commits. Repeat all required '
                        'reviews of the SAME stage, including complete transferred files and publication '
                        'history. Ownership acceptance gives no review or CI credit. Do not repeat completed '
                        'implementation or do Git writes. The runtime will check existing pushes and finish '
                        'the remaining reviewed publication.'
                    ))
        pending = state.get("pending") or {}
        if (state["phase"] == "code" and state.get("code_started")
                and (pending.get("resume_code", True) or pending.get("attempts", 0))):
            context["coding_recovery"] = (
                'This stage already started. The code phase includes recovery of its lost or rejected '
                'final report. Do not repeat completed implementation. Pending reviews do not require '
                'another stage. Only the runtime advances the phase after it validates the coding '
                'result.'
            )
        if role == "publish":
            context.update(remote=state["remote"], ref="refs/heads/main",
                           reviewed={"head": state["reviewed"]["head"], "files_sha256": digest(encode(state["reviewed"]["files"]))},
                           stage_paths=self.publication_paths())
        if role in ("publish", "heal"):
            context["publication_executor"] = 'The runtime owns publication. Provider roles must not stage, commit, or push.'
            context["publication_artifacts"] = str(self.store.directory / "publication")
        if role == "heal":
            context["blocker"] = state["blocker"]
        if role == "code" and (state.get("pending") or {}).get("resume_code"):
            context["recovery"] = (
                'Coding for this iteration already started. Finish that SAME stage. Do not select '
                'another stage, even if prior conversation text calls it complete. If only the final '
                'response was lost, reconstruct its result. Then report that result.'
            )
        prompt = PROMPTS[role]
        if role in ("opus", "sol"):
            prompt = prompt.replace("%%DESCRIPTION%%", state["code_report"] or (
                'The coding role did not complete a report. Review the retained work in progress and '
                'handoff.'
            ))
        context["task"] = state.get("task")
        if role in (*REVIEW_ROLES, *FINAL_ROLES):
            stage_paths = self.publication_paths()
            current_files = self.snapshot()["files"]
            context["stage_scope"] = {"baseline_head": state["baseline"]["head"],
                                      "paths": stage_paths,
                                      "new_paths": sorted(name for name in stage_paths
                                                          if name not in state["baseline"]["files"] and name in current_files),
                                      "instructions": 'Review this stage diff, including untracked new files. Read dependencies when necessary. Do not audit the whole solution.'}
        if role in FINAL_ROLES and role not in PAIR_ROLES:
            context["final_review"] = self.final_context(role)
        return prompt + "\n\nRuntime context:\n" + json.dumps(context, ensure_ascii=False)

    def report_repair_context(self, pending):
        """A completed pass may correct its accounting once, against frozen work."""
        self.context(pending["role"])  # Keep immutable handoff/correction guards during report-only work.
        repair = pending["report_repair"]
        source = Path(repair["source"])
        try:
            valid = (source.resolve().is_relative_to(self.store.directory.resolve())
                     and digest(source.read_bytes()) == repair["sha256"])
        except OSError:
            valid = False
        if not valid:
            raise Blocked("report-repair-source", "The original review report changed or disappeared; repair cannot certify it.")
        if self.snapshot(repair["after"]) != self.snapshot():
            raise Blocked("report-repair-drift", "Working files, HEAD or index changed during report-only correction; no review credit granted.")
        self.check_protected(self.snapshot(repair["after"]))
        executor_counts = (repair.get("reason") == "unchanged-accounting"
                           or repair.get("reason") == "changed-file-accounting" and pending["role"] in PAIR_WRITERS)
        if repair.get("reason") == "substantial-accounting" or executor_counts:
            result = json.loads(source.read_text(encoding="utf-8"))
            if executor_counts:
                try:
                    original = report_object(result["raw"])
                except ValueError:
                    original = None
                problem = ('The original invocation changed the listed paths, but its report set all three '
                           'edit counters to 0. The runtime rejects that report.'
                           if repair["reason"] == "changed-file-accounting" else
                           'The original invocation changed no files, but its report has edit counters or '
                           'substantial=true. The runtime rejects that report.')
            else:
                original = repairable_substantial_accounting(result["raw"], pending["role"])
                problem = ('The original report set substantial=true and implementation_fixes=0. The '
                           'runtime rejects that combination.')
            if original is None or self.snapshot(result["after"]) != self.snapshot(repair["after"]):
                raise Blocked("report-repair-source", "Original report accounting no longer matches the frozen correction.")
            return ((
                'REPORT-ONLY CORRECTION of the ORIGINAL invocation. This is not another execution or '
                'review. ' + problem + ' Classify the changes of the original invocation again.'
                ' Use its existing evidence and the listed changed paths.\n\nCount changes to source '
                'behavior, executable checks, test expectations, acceptance rules, configuration, or '
                'instructions as implementation_fixes. If no change alters contracts, core algorithms, '
                'workflows, permission boundaries, or intended test outcomes, set substantial=false. '
                'Change only implementation_fixes, other_fixes, minor_edits, substantial, summary, and '
                'description.\n\nKeep every other field and array exactly, including status, evidence, '
                'resolutions, findings, handoff, and repair. Do not invent fixes. Do not run tools, tests,'
                ' builds, or formatting. Do not edit files, journals, staging, or runtime records.\n\n' + (
                'If you are not sure how to classify a change, count it as an implementation fix and set '
                'substantial=true. Return blocked only if the original invocation did not make the listed '
                'changes.' if repair.get("changed_paths") else
                'The original invocation changed no files. Set all three counters to 0 and substantial=false.'
            ) + ' This call gives no extra review credit. '
            ) + json.dumps({"source": str(source), "changed_paths": repair.get("changed_paths", []),
                            "original_report": original}, ensure_ascii=False))
        if repair.get("reason") == "invocation-accounting":
            result = json.loads(source.read_text(encoding="utf-8"))
            original = repairable_executor_accounting(result["raw"], pending["role"],
                self.snapshot(result["before"]), self.snapshot(result["after"]))
            if original is None or self.snapshot(result["after"]) != self.snapshot(repair["after"]):
                raise Blocked("report-repair-source", "Original executor accounting no longer matches the frozen correction.")
            return ((
                'REPORT-ONLY CORRECTION of the ORIGINAL executor invocation. This is not another '
                'execution or review. Its files/HEAD/index are unchanged, and all three edit counters '
                'are zero. Its substantial=true incorrectly describes an earlier batch. Set '
                'substantial=false. In description/summary, distinguish this invocation from '
                'cumulative impact.\n\nPreserve EVERY other JSON field and array exactly, including '
                'evidence, resolutions, counters, and deferred work. Do not invent fixes. The runtime '
                'keeps earlier substantial impact and required outer review separately. Return the '
                'full corrected JSON from the supplied original only. Do not run tools, tests, builds,'
                ' mutation runs, or formatting. Do not edit files, journals, staging, or runtime '
                'records.\n\nIf you cannot correct the report accurately, return blocked. This call '
                'gives no extra review credit. '
            ) +
                json.dumps({"source": str(source), "original_report": original}, ensure_ascii=False))
        return (
            (
                (
                    'REPORT-ONLY CORRECTION, not another review pass. Your completed invocation changed files '
                    'but reported implementation_fixes=other_fixes=minor_edits=0. Read the original '
                    'result. Describe EVERY listed changed path. Use existing evidence. Do not repeat '
                    'builds, tests, or review.\n\nDo not write files, update journals/indexes, stage, '
                    'commit, or push. Return only the full corrected JSON report for the ORIGINAL pass. '
                    'Keep its checks, findings, and deferred work. New records of completed checks are '
                    'minor_edits. Behavioral corrections, including executable checks or instructions, '
                    'require implementation_fixes and an accurate substantial assessment. Do not classify '
                    'a change as minor from its directory or extension.\n\nDo not invent counters to pass '
                    'validation. If existing evidence cannot establish classification or completion, '
                    'report blocked. This invocation gives no additional review pass. '
                )
            ) + json.dumps({k: v for k, v in repair.items() if k != "after"}, ensure_ascii=False))

    def executor_result_candidate(self, directory, intent):
        """Return saved result metadata, or the frozen source of an unfinished correction.

        Only discovery uses this. invoke() still runs/resumes the correction when
        its own result does not exist; source evidence is never accepted as its output.
        """
        path = directory / "result.json"
        if path.exists():
            return json.loads(path.read_text(encoding="utf-8"))
        if intent.get("report_repair", {}).get("reason") in ACCOUNTING_REPAIRS:
            self.report_repair_context(intent)
            result = json.loads(Path(intent["report_repair"]["source"]).read_text(encoding="utf-8"))
            # invoke() reruns the correction. Messages already accepted for it stay with it.
            accepted = [m["identity"]["id"] for m in self.messages.accepted(self.state["iteration"], intent["id"])]
            return dict(result, operator_messages=accepted)
        raise FileNotFoundError(path)

    def validate_executor_correction(self, pending, report):
        repair = pending.get("report_repair", {})
        if repair.get("reason") not in ACCOUNTING_REPAIRS or report["status"] == "blocked":
            return
        if repair["reason"] == "changed-file-accounting" and pending["role"] not in PAIR_WRITERS:
            return  # Review accounting keeps its existing validation in invoke().
        original = report_object(json.loads(Path(repair["source"]).read_text(encoding="utf-8"))["raw"])
        if repair["reason"] in ("substantial-accounting", "changed-file-accounting", "unchanged-accounting"):
            counters = ("implementation_fixes", "other_fixes", "minor_edits")
            mutable = {"summary", "description", "substantial", *counters}
            if ({k: v for k, v in original.items() if k not in mutable}
                    != {k: v for k, v in report.items() if k not in mutable}):
                raise Blocked("report-repair-content", "Accounting correction must preserve status, evidence, resolutions and every other field; only counters, substantial and explanatory prose may change.")
            if repair.get("changed_paths") and not sum(report[k] for k in counters):
                raise Blocked("report-repair-content", "The original invocation changed files, so the corrected report needs at least one positive edit counter.")
            if not repair.get("changed_paths") and (report["substantial"] or any(report[k] for k in counters)):
                raise Blocked("report-repair-content", "The original invocation changed no files, so every counter must be 0 and substantial must be false.")
            return
        mutable = {"summary", "description", "substantial"}
        if (report["substantial"] or {k: v for k, v in original.items() if k not in mutable}
                != {k: v for k, v in report.items() if k not in mutable}):
            raise Blocked("report-repair-content", "Accounting correction must preserve all checks, resolutions and zero counters; only substantial and explanatory prose may change.")

    def executor_candidate_report(self, intent, result):
        """Discover an invocation to resume; this is never closure validation."""
        if intent.get("report_repair", {}).get("reason") in ACCOUNTING_REPAIRS:
            self.report_repair_context(intent)
            original = json.loads(Path(intent["report_repair"]["source"]).read_text(encoding="utf-8"))
            if "report_repair" in result and intent["report_repair"].get("changed_paths"):
                # The original edited the candidate. A failed correction is not replayed forever:
                # discovery fails, so recovery reviews the edited candidate again.
                report = parse_report(result["raw"], intent["role"])
                self.validate_executor_correction(intent, report)
                if report["status"] != "done":
                    raise Blocked("report-repair-content", "The correction did not complete the report.")
            # A failed correction of unchanged work replays its own failure. It does
            # not fall back to re-executing the completed original checks.
            return report_object(original["raw"])
        try:
            return parse_report(result["raw"], intent["role"])
        except Blocked:
            report = (repairable_executor_accounting(result["raw"], intent["role"],
                          self.snapshot(result["before"]), self.snapshot(result["after"]))
                      or repairable_substantial_accounting(result["raw"], intent["role"]))
            if report is None:
                raise
            return report

    def with_correction_source(self, identity):
        """Name an invocation and, for a report-only correction, the original that it corrects.

        Discovery must not adopt a corrected original again, for example after a heal.
        """
        names = [identity]
        try:
            intent = json.loads((self.store.directory / "invocations" / identity / "intent.json").read_text(encoding="utf-8"))
            source = Path(intent["report_repair"]["source"])
            if source.parent.parent.resolve() == (self.store.directory / "invocations").resolve():
                names.append(source.parent.name)
        except (OSError, ValueError, KeyError, TypeError):
            pass  # A normal invocation has no correction source.
        return names

    def begin_report_repair(self, role, pending, result, result_path, reason="changed-file-accounting"):
        if self.messages.unresolved(self.state["iteration"]):
            raise MessagePending("Resolve pending delivery before correcting this review report.")
        replacement = {"id": uuid.uuid4().hex, "role": role, "iteration": self.state["iteration"],
                       "before": pending["before"], "started": time.time(),
                       "correction_revision": pending.get("correction_revision"),
                       "report_repair": {"source": str(result_path), "sha256": digest(result_path.read_bytes()),
                                         "after": result["after"],
                                         "reason": reason,
                                         "changed_paths": self.changes(pending["before"], result["after"])}}
        for name in ("restart_reviews", "operator_intervened"):
            if pending.get(name):
                replacement[name] = pending[name]
        for name in ("pair_execution_binding", "repair_binding"):
            if name in pending:
                replacement[name] = copy.deepcopy(pending[name])
        if role in PAIR_WRITERS:
            pair = self.state["pair_review"]
            if role != "repair_execute":
                replacement.setdefault("pair_execution_binding", self.pair_execution_binding(pair))
                pair["writer_invocation"] = replacement["id"]
            else:
                replacement.setdefault("repair_binding", self.repair_binding(pair))
                if pair["repair"]["step"] == "test":
                    pair["repair"]["test_invocation"] = replacement["id"]
        self.state["pending"] = replacement
        self.save()  # Separate durable marker prevents replay of the rejected native response.
        print(f"cc-focus: {role} report accounting needs correction ({reason}); requesting one report-only correction "
              f"in the same session ({len(replacement['report_repair']['changed_paths'])} changed files). "
              "Work and completed checks must remain unchanged.", flush=True)
        return self.invoke(role)

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
            if role in PAIR_WRITERS and role != "repair_execute":
                pair = state["pair_review"]
                pending["pair_execution_binding"] = self.pair_execution_binding(pair)
                pair["writer_invocation"] = pending["id"]
            if role == "repair_execute":
                pair = state["pair_review"]
                pending["repair_binding"] = self.repair_binding(pair)
                if pair["repair"]["step"] == "test":
                    pair["repair"]["test_invocation"] = pending["id"]
            self.save()  # The intent is durable before a provider can do any work.
        directory = self.store.directory / "invocations" / pending["id"]
        directory.mkdir(parents=True, exist_ok=True)
        if not (directory / "intent.json").exists():
            self.store.artifact(f"invocations/{pending['id']}/intent.json", encode(pending))
        result_path = directory / "result.json"
        print(f"cc-focus: iteration={state['iteration']} role={role}", flush=True)
        if self.progress:
            self.progress.start(role, directory)
        prompt = self.report_repair_context(pending) if pending.get("report_repair") else self.context(role)
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
            transient = pending.get("transient_wait")
            unchanged_refusal = False
            if quota or transient:
                current = self.snapshot()
                self.check_protected(current)
                if self.snapshot(pending["before"])["head"] != current["head"]:
                    raise Blocked("unauthorized-commit", "HEAD changed across the provider wait; work was preserved.")
                if transient and self.snapshot(pending["before"])["index"] != current["index"]:
                    raise Blocked("unauthorized-staging", "Staging changed across the server-error wait; preserve and reconcile it before retrying.")
                unchanged_refusal = (quota or transient)["no_work"] and self.snapshot(
                    pending.get("report_repair", {}).get("after", pending["before"])) == current
                pending.pop("quota_wait", None)
                pending.pop("transient_wait", None)
            if pending.get("attempts", 0) and role in REVIEW_ROLES and not unchanged_refusal and not pending.get("report_repair"):
                # An interrupted pass may have fixed implementation before its
                # final report was lost. Earlier clean passes cannot certify that
                # new content, even if the resumed pass itself makes no fixes.
                reset_notice(state, "Прерванный проход повторяется", (role,))
                self.state[role + "_clean"] = 0
                if self.changes(pending["before"], self.snapshot()):
                    state["review_substantial"] = True
                self.save()
            if quota or transient:
                self.save()  # A later interruption is not an admission refusal.
            # Retry invalidation changes review/test eligibility; send the updated context.
            prompt = self.report_repair_context(pending) if pending.get("report_repair") else self.context(role)
            raw = self.transport.run(role, prompt, pending, directory)
            if self.messages.unresolved(state["iteration"], pending["id"]):
                raise MessagePending("Input remains undelivered; the saved invocation cannot advance yet.")
            if cached:
                self.store.artifact(f"invocations/{pending['id']}/prior-result-{uuid.uuid4().hex}.json", encode(cached))
            result = {"raw": raw, "before": pending["before"], "after": self.snapshot(),
                      "operator_messages": [item["identity"]["id"] for item in self.messages.accepted(state["iteration"], pending["id"])]}
            if pending.get("report_repair"):
                result["report_repair"] = pending["report_repair"]
            self.store.artifact(f"invocations/{pending['id']}/result.json", encode(result))
        if pending.get("report_repair"):
            self.report_repair_context(pending)  # Includes resumed/cached corrections and index drift.
        if pending.get("correction_revision") != state.get("correction_revision"):
            raise Blocked("correction-stale-result", "This invocation predates the latest operator correction; its result cannot advance the stage.")
        try:
            report = parse_report(result["raw"], role)
        except Blocked:
            if pending.get("report_repair"):
                raise  # One correction only. A second invalid report uses normal recovery.
            if repairable_executor_accounting(result["raw"], role, self.snapshot(pending["before"]),
                                              self.snapshot(result["after"])) is not None:
                reason = "invocation-accounting"
            elif repairable_substantial_accounting(result["raw"], role) is not None:
                # The healer cannot rewrite a provider report. The author corrects its own counters.
                reason = "substantial-accounting"
            else:
                raise
            self.check_protected(self.snapshot(result["after"]))
            return self.begin_report_repair(role, pending, result, result_path, reason)
        self.validate_executor_correction(pending, report)
        if (role in PAIR_WRITERS and not pending.get("report_repair") and report["status"] == "done"
                and self.snapshot(pending["before"]) == self.snapshot(result["after"])
                and (report["substantial"] or any(report[k] for k in ("implementation_fixes", "other_fixes", "minor_edits")))):
            # The contract requires zero counters when the invocation changed no files. Copied
            # batch counters would otherwise block a test step or force an extra outer review.
            self.check_protected(self.snapshot(result["after"]))
            return self.begin_report_repair(role, pending, result, result_path, "unchanged-accounting")
        if state.get("correction_pending") and role in ("coordinate", "code") and report["status"] == "complete":
            raise Blocked("correction-unfinished", "The current stage has an operator correction pending; complete cannot bypass coding and reviews.")
        before, after = self.snapshot(pending["before"]), self.snapshot(result["after"])
        self.check_protected(after)
        if role != "publish" and before["head"] != after["head"]:
            raise Blocked("unauthorized-commit", f"{role} changed HEAD outside publication; work was preserved.")
        if role in PAIR_WRITERS and before["index"] != after["index"]:
            raise Blocked("unauthorized-staging", "Pair executor changed staging; only the publication runtime may stage files.")
        if role == "coordinate" and before != after:
            raise Blocked("coordinator-mutation", "The coordinator changed repository state; its role is read-only.")
        if (role == "publish" and pending.get("publication_readonly")
                and self.snapshot(pending.get("publication_before", pending["before"])) != after):
            raise Blocked("publisher-mutation", "The publisher changed repository state; only the runtime may stage, commit or push.")
        if role in READONLY_REVIEW_ROLES and before != after:
            raise Blocked("final-review-mutation", "Final inspections and triage are read-only; no review credit granted.")
        if report["status"] == "blocked":
            raise Blocked("reported-blocker", report["summary"] + "\n" + report["description"])
        if role in (*REVIEW_ROLES, *FINAL_ROLES):
            if report["status"] != "done" or not report["evidence"]:
                raise Blocked("incomplete-review", "A review requires a completed pass and actual verification evidence.")
            if self.changes(before, after) and not sum(report[k] for k in ("implementation_fixes", "other_fixes", "minor_edits")):
                if (role in REVIEW_ROLES or role in PAIR_WRITERS) and not pending.get("report_repair"):
                    return self.begin_report_repair(role, pending, result, result_path)
                raise Blocked("unreported-fix", "Review changed files but reported no changes, even after report-only correction. "
                              "Account for every changed file: record new verification evidence/journal writes in minor_edits; "
                              "report actual defects as implementation_fixes or other_fixes. Minor edits do not reset clean passes.")
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

    def accepted_pair_results(self):
        """Count accepted pair results; a rejected report removes its result instead."""
        from focus_pair_profile import pair_nodes
        pair = self.state.get("pair_review") or {}
        repair = pair.get("repair") or {}
        return (sum(1 for node in pair_nodes(self.state) for job in (node.get("jobs") or {}).values() if job.get("result")),
                len((pair.get("execution") or {}).get("reports", [])), len(repair.get("executions", [])),
                len(repair.get("reviews", [])), len(self.state.get("pair_handoff", [])), self.state["phase"])

    def pair_step(self):
        accepted = self.accepted_pair_results()
        self.paired_review_step()
        after = self.accepted_pair_results()
        if self.state.get("recovery_unverified") and (after[-1] != accepted[-1]
                or any(new > old for new, old in zip(after[:-1], accepted[:-1]))):
            # Accepted provider work after a heal verifies that recovery.
            self.state["recovery_unverified"] = False
            self.save()

    def complete_invocation(self):
        if self.state["pending"]["role"] == "code":
            self.state["correction_pending"] = None
        if self.state["pending"]["role"] in ("code", *REVIEW_ROLES, *FINAL_ROLES):
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
        if (state["phase"] not in ("code", *REVIEW_ROLES, *PAIRS, "publish") or state.get("published") or state.get("publication_started")
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
        if resume_phase not in ("code", "opus", "pair_a"):
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
        if resume_phase in ("opus", "pair_a"):
            corrections[-1]["publication_recovery"] = True
        if validate:
            validate()
        previous = copy.deepcopy(state)
        try:
            if candidate is not None:
                state.clear()
                state.update(candidate)
            self.reset_reviews("Оператор согласовал область публикации" if resume_phase in ("opus", "pair_a") else "Оператор изменил требования")
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
        continuation = ("Paused before first review of the SAME stage; all required review loops must run again." if resume_phase in ("opus", "pair_a") else
                        "Paused before coding the SAME stage; all required reviews must run again." if state.get("code_started") else
                        "Paused before stage selection from the current plan; any unpublished work requires coding and all required reviews.")
        print(f"cc-focus: correction {correction_id[:12]} saved for iteration {state['iteration']}. "
              + continuation + " Sessions and work preserved.", flush=True)
        print("Run cc-focus to apply the correction and continue. No model was started.", flush=True)

    def recover_review(self, source):
        """Operator-selected recovery of a completed, unpublished coding result."""
        state = self.state
        if self.messages.records(state["iteration"]):
            raise Blocked("recovery-messages", (
                'This stage has operator-message history. Resume the saved invocation or apply a '
                'stopped-stage correction; an older coding report cannot bypass those instructions.'
            ))
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
        print(f"cc-focus: recovered coding result; paused before Opus review. No review credit or publication was granted. Backup: {archive}", flush=True)
        print("Run cc-focus to start the required reviews; native sessions and project files were preserved.", flush=True)

    def review(self, role):
        self.review_route(role)
        report, before, after, _ = self.invoke(role)
        counted = report["implementation_fixes"] + report["other_fixes"]
        review_event(self.state, role, "исправления" if counted else "чисто",
                     f"Зачитываемых исправлений: {counted}" if counted else "", completed=True)
        if role == "sol":
            self.state["sol_passes"] += 1
        if self.state["pending"].get("restart_reviews"):
            self.reset_reviews("Новое указание требует повторного ревью с Opus")
        else:
            self.state[role + "_clean"] = 0 if counted else self.state.get(role + "_clean", 0) + 1
            self.state["review_substantial"] = self.state.get("review_substantial", False) or report["substantial"]
            if self.state[role + "_clean"] >= self.review_route(role)[0]["target"]:
                self.finish_review_loop(role, after)
        self.complete_invocation()
        if self.progress:
            counts = ", ".join(f"{name} clean={self.state[name + '_clean']}/{review_target(self.state, name)}" for name in REVIEW_ROLES)
            self.progress.note(f"Review complete: {counts}; next={self.state['phase']}")

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
            raise Blocked("publish-drift", "Publication changed reviewed content; all required reviews must run again.")
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
            if role in FINAL_ROLES and state["pending"].get("restart_reviews"):
                self.reset_reviews("Новое указание требует повторного ревью с Opus")
            if role in REVIEW_ROLES:
                review_event(state, role, "не зачтено", error.code)
                state[role + "_clean"] = 0
                if state["pending"].get("restart_reviews"):
                    self.reset_reviews("Новое указание требует повторного ревью с Opus")
                elif self.changes(state["pending"]["before"], self.snapshot()):
                    state["review_substantial"] = True
        signature = digest(encode({"code": error.code, "message": str(error)}))
        if state.get("blocker") and state["blocker"]["status"] == "healing":
            state["blocker"].update(status="blocked", resolution=str(error), escalation_reason="healer-failed")
        else:
            state["blocker"] = {"code": error.code, "message": str(error), "signature": signature,
                                "phase": state["phase"], "status": "healing", "at": time.time()}
            reason = ("provider-refusal" if error.code == "claude-refusal" else
                      "manual-action" if error.code in MANUAL_BLOCKERS else
                      "unsafe-provider" if error.code in UNSAFE_PROVIDER_BLOCKERS else
                      "provider-unavailable" if error.code in PROVIDER_UNAVAILABLE_BLOCKERS else
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
        paired = self.state.get("pair_review")
        saved_test = self.saved_repair_test(paired)
        saved_execution = self.saved_pair_execution(paired)
        if saved_test:
            paired["repair"]["test_invocation"] = saved_test[0]["id"]
        if saved_execution:
            paired["writer_invocation"] = saved_execution[0]["id"]
        report, before, after, _ = self.invoke("heal")
        if report["status"] != "done":
            raise Blocked("unresolved", report["summary"])
        blocker = self.state["blocker"]
        paired = self.state.get("pair_review")
        candidate = ((read_record(self.store, paired["repair"]["test_receipt"])["after"]
                      if paired.get("repair", {}).get("step") == "evidence" else
                      paired.get("repair", {}).get("snapshot") or paired.get("execution", {}).get("snapshot") or paired["snapshot"]) if paired else None)
        stale_pair = bool(candidate and candidate["head"] == after["head"] and candidate["index"] == after["index"]
                          and self.changes(candidate, after))
        if saved_test and self.snapshot(saved_test[1]["after"]) == after:
            stale_pair = False  # Classification is still required; no credit is granted here.
        if saved_execution and self.snapshot(saved_execution[1]["after"]) == after:
            stale_pair = False  # Still requires exhaustive executor closure, then the usual pair review.
        if self.changes(before, after) or stale_pair:
            self.reset_reviews("Восстановление требует ревью текущего содержимого")
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
        if pending.get("report_repair"):
            self.report_repair_context(pending)
        no_work = error.no_work and self.snapshot(pending.get("report_repair", {}).get("after", pending["before"])) == current
        if not no_work and pending["role"] in REVIEW_ROLES and not pending.get("report_repair"):
            reset_notice(self.state, "Квота прервала начатый проход", (pending["role"],))
            self.state[pending["role"] + "_clean"] = 0
            if self.changes(pending["before"], current):
                self.state["review_substantial"] = True
        # A stale reset or repeated rejection must not create a tight retry loop.
        pending["quota_wait"] = {"resets_at": error.resets_at,
                                 "retry_at": max(error.resets_at + 5, time.time() + 60),
                                 "no_work": no_work}
        self.save()
        retry = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(pending["quota_wait"]["retry_at"]))
        print(f"cc-focus: quota wait until {retry}; same phase/session will retry automatically. No review credit earned.", flush=True)

    def defer_transient(self, error):
        pending = self.state["pending"]
        current, before = self.snapshot(), self.snapshot(pending["before"])
        self.check_protected(current)
        if current["head"] != before["head"]:
            raise Blocked("unauthorized-commit", "The provider changed HEAD before its server error; work was preserved.")
        if current["index"] != before["index"]:
            raise Blocked("unauthorized-staging", "The provider changed staging before its server error; preserve and reconcile it before retrying.")
        if pending.get("report_repair"):
            self.report_repair_context(pending)
        no_work = error.no_work and self.snapshot(pending.get("report_repair", {}).get("after", pending["before"])) == current
        if not no_work and pending["role"] in REVIEW_ROLES and not pending.get("report_repair"):
            reset_notice(self.state, "Серверная ошибка прервала проход", (pending["role"],))
            self.state[pending["role"] + "_clean"] = 0
            if self.changes(before, current):
                self.state["review_substantial"] = True
        retries = pending.get("transient_retries", 0)
        if retries >= len(PROVIDER_RETRY_DELAYS):
            return False
        delay = PROVIDER_RETRY_DELAYS[retries]
        pending["transient_retries"] = retries + 1
        provider = getattr(error, "provider", "claude").capitalize()
        pending["transient_wait"] = {"retry_at": time.time() + delay, "no_work": no_work, "provider": provider,
                                     "attempt": retries + 1, "limit": len(PROVIDER_RETRY_DELAYS)}
        self.save()
        print(f"cc-focus: {provider} server error; automatic retry {retries + 1}/{len(PROVIDER_RETRY_DELAYS)} "
              f"in {delay}s in the same phase/session; no model is running.", flush=True)
        return True

    def wait_transient(self):
        wait = (self.state.get("pending") or {}).get("transient_wait")
        if not wait or time.time() >= wait["retry_at"]:
            return False
        if self.progress:
            if self.progress.operation != "provider-retry":
                self.progress.runtime("provider-retry")
            remaining = max(0, int(wait["retry_at"] - time.time()))
            self.progress.activity = (f"Waiting to retry {wait.get('provider', 'Claude')} after server error "
                                      f"({wait['attempt']}/{wait['limit']}); "
                                      f"retry in {remaining}s; no model is running")
            self.progress.pulse()
        time.sleep(min(0.25, max(0, wait["retry_at"] - time.time())))
        return True

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

    def prepare_snapshot_storage(self):
        receipts = compact_legacy_views(self.store, self.heartbeat)
        if not receipts:
            return
        value = {"views": receipts, "at": max(r["at"] for r in receipts)}
        reference = artifact(self.store, "snapshot-storage/" + digest(encode(value)) + ".json", value)
        if self.state.get("snapshot_storage") != reference:
            self.state["snapshot_storage"] = reference
            self.save()
            print(f"cc-focus: Archived {len(receipts)} legacy review snapshots; original manifests and review evidence preserved.", flush=True)

    def run(self):
        storage_checked = False
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
                    print((
                        'If coding completed but its report was rejected: cc-focus recover --review-from '
                        '.work/cycle/invocations/CODE_INVOCATION_ID/result.json (see the recovery guide; never'
                        ' use the healer report).'
                    ), flush=True)
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
                if not storage_checked:
                    self.prepare_snapshot_storage()
                    storage_checked = True
                # A saved provider wait also holds a healer that hit a server error.
                if self.wait_quota() or self.wait_transient():
                    continue
                if blocker:
                    self.heal()
                    continue
                if phase == "ci":
                    if self.progress:
                        self.progress.role = None
                        self.progress.note("Waiting for CI on the published commit; no model is running.")
                    self.wait_ci()
                    self.next_stage()
                    continue
                pending = self.state["pending"]
                if not pending and phase in (*REVIEW_ROLES, *PAIRS, "publish"):
                    current = self.snapshot()
                    if self.changes(self.state["last_snapshot"], current):
                        self.check_protected(current)
                        self.reset_reviews("Файлы изменились после ревью")
                        self.state["last_snapshot"] = current
                        self.save()
                        continue
                if phase not in PAIRS and self.state["coordinated"] != phase and (not pending or pending["role"] == "coordinate"):
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
                elif phase in REVIEW_ROLES:
                    self.review(phase)
                elif phase in PAIRS:
                    self.pair_step()
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
                if isinstance(error, ProviderTransient) and not self.messages.unresolved(self.state["iteration"]):
                    try:
                        if self.defer_transient(error):
                            continue
                        # handle_block stops the run for the operator. It starts no healer.
                        error = Blocked(error.code, str(error) +
                                        f" The runtime used all {len(PROVIDER_RETRY_DELAYS)} automatic retries. "
                                        + transient_exhausted())
                    except Blocked as guard_error:
                        error = guard_error
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
                          sol_passes=0, opus_clean=0, sol_clean=0, claude_clean=0, astra_clean=0, opus_final_clean=0, final_review=None, coordinated=None,
                          last_snapshot=self.snapshot(), code_started=False, healed=[], recovery_unverified=False,
                          corrections=[], correction_revision=None, correction_pending=None, coordination=None,
                          publication_started=False)
        for key in ("pair_review", "pair_clean", "pair_completed", "pair_return", "pair_b_substantial", "pair_return_changed", "pair_carry", "pair_handoff", "pair_instructions", "pair_round"):
            self.state.pop(key, None)
        self.state.pop("publication_prepared", None)
        self.state.pop("publication_push_url", None)
        self.state.pop("publication_paths", None)
        self.state.pop("publication_review_profile", None)
        self.state.update(review_plan=[], review_substantial=False, review_targets=dict(REVIEW_TARGETS),
                          task=None, display_reviews=new_reviews(), display_review_events=[], display_ci=None)
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
