"""Paired reviews, bounded agreement, autonomous arbitration and one serial fixer."""

import copy
import json
import uuid

from cycle_state import Blocked, digest, encode
from cycle_prompts import PAIR_CONTRACT
from focus_pair_profile import PAIRS, PAIR_WRITERS, significant
from focus_pair_protocol import (assignment_key, consensus_error, proposal_key, validate_complexity,
                                 validate_decisions)
from focus_pair_view import artifact, materialize, read_record
from focus_pair_jobs import run_jobs, renew_report_marker
from focus_pair_repair import RepairReview
from focus_pair_execution import PairExecution


class PairedReview(PairExecution, RepairReview):
    def pair_obligations(self, pair=None):
        pair = pair if pair is not None else self.state.get("pair_review") or {}
        rows = {row["source_id"]: copy.deepcopy(row)
                for row in [*self.state.get("pair_carry", []), *pair.get("carry", []), *pair.get("issues", [])]}
        # Steering/recovery may interrupt scanning before the registry exists.
        for role, report in pair.get("scans", {}).items():
            for finding in report["findings"]:
                identity = pair["id"] + "/" + role + "/" + finding["id"]
                rows.setdefault(identity, dict(copy.deepcopy(finding), source_id=identity))
        repair = pair.get("repair") or {}
        for row in repair.get("issues", []):
            rows.setdefault(row["source_id"], copy.deepcopy(row))
        if repair.get("reader"):
            for row in self.pair_obligations(repair["reader"]):
                rows.setdefault(row["source_id"], row)
        return list(rows.values())

    def reset_pairs(self):
        carried = self.pair_obligations()
        self.state.update(phase="pair_a", pair_review=None, pair_clean={"pair_a": 0, "pair_b": 0},
                          pair_return=None, pair_b_substantial=False, pair_return_changed=False,
                          pair_carry=carried, pair_completed={}, review_plan=[], reviewed=None)

    def pair_prompt(self, pair, role, assignment):
        view = materialize(self, pair)
        self.validate_corrections()
        context = {"phase": pair["phase"], "candidate": view["candidate"], "task": self.state.get("task"),
                   "stage_paths": view["stage_paths"], "role": role, "assignment": assignment,
                   "operator_instructions": self.pair_operator_instructions(),
                   "inspection": 'Use focus_inspect list/read/diff. In Claude, use mcp__focus__inspect. Read new files even if their diff is empty.',
                   "independence": 'Keep initial reports independent. The partner report is unavailable until both inspections finish.',
                   "history": [] if pair["phase"] == "final" else [n for n in view["files"] if n.startswith("__review__/")]}
        # Explicit operator corrections are normative, not agent judgments. Never
        # expose archived runtime state or old review/coding descriptions here.
        context["corrections"] = [self.pair_correction_text(c) for c in self.state.get("corrections", [])]
        if pair.get("repair_base"):
            context["repair_review"] = pair["repair_context"]
        return PAIR_CONTRACT + "\nRuntime assignment:\n" + json.dumps(context, ensure_ascii=False, sort_keys=True)

    def pair_operator_instructions(self):
        rows = {}
        for record in self.messages.accepted(self.state["iteration"]):
            identity = record["identity"]
            rows[identity["id"]] = {"id": identity["id"], "text": identity["text"]}
        for row in self.state.get("pair_instructions", []):
            rows.setdefault(row["id"], row)
        return list(rows.values())

    def pair_correction_text(self, correction):
        from pathlib import Path
        return Path(correction["path"]).read_text(encoding="utf-8")

    def pair_writer_context(self, role):
        if role == "repair_execute":
            return self.repair_writer_context()
        pair = self.state["pair_review"]
        tasks = self.pair_execution_tasks(pair)
        execution = pair.get("execution")
        context = {"task": self.state.get("task"), "phase": pair["phase"], "candidate": digest(encode(pair["snapshot"])),
                   "assignments": tasks, "prior_resolutions": pair.get("resolutions", []),
                   "protected_paths": self.state["protected"], "stage_paths": self.publication_paths(),
                   "operator_instructions": self.pair_operator_instructions(),
                   "corrections": [self.pair_correction_text(c) for c in self.state.get("corrections", [])],
                   "verification": (
                       'PAIR A: make the assigned corrections now. Then run the assigned targeted checks. '
                       'Build only affected projects and necessary dependencies. The B/final two-clean-pass '
                       'gate does not apply here, even if an assignment incorrectly refers to it. Return one '
                       'resolution for every assigned source_id, including deferred work. Do not claim that '
                       'unrun tests passed.'
                   ),
                   "complexity": self.pair_assessment(pair),
                   "cleanup": pair["step"] == "cleanup"}
        if execution:
            context["candidate"] = digest(encode(execution["snapshot"]))
            context["continuation"] = {
                "completed_resolutions": list(execution["resolutions"].values()),
                "previous_reports": [read_record(self.store, r) for r in execution["reports"]],
                "errors": execution["errors"],
                "rule": (
                    'Complete ONLY the outstanding assignments on this unchanged candidate in this SAME '
                    'executor session. Read saved evidence first. Do not repeat completed changes or '
                    'successful checks. If proof exists, reconstruct an omitted resolution from that '
                    'proof. Otherwise, do the missing work. Pair A can run deferred verification now.\n\n'
                    'There is no inner static gate. For each unfinished obligation, give outcome=deferred '
                    'and a specific reason. Do not omit it. Deferred work cannot advance the pair. New '
                    'changes invalidate earlier verification unless you repeat it on the new candidate.'
                )}
        return PAIR_CONTRACT + "\nExecutor assignment:\n" + json.dumps(context, ensure_ascii=False, sort_keys=True)

    def pair_assessment(self, pair):
        assessment = read_record(self.store, pair["assessment"])["complexity"]
        validate_complexity(assessment, pair["snapshot"], pair["tasks"])
        return assessment

    def accept_pair_input(self, pair, pending):
        # Called only after both child processes have exited. The durable message
        # remains queued until the new shared instruction has been saved.
        records = [r for r in self.messages.records(self.state["iteration"], pending["id"]) if r["status"] in ("queued", "accepted")]
        texts = self.state.setdefault("pair_instructions", [])
        for record in records:
            entry = {"id": record["identity"]["id"], "text": record["identity"]["text"]}
            if entry not in texts:
                texts.append(entry)
        self.state["pair_input_pending"] = pending["id"]
        self.save()
        for record in records:
            self.messages.update(record, "accepted", "Runtime accepted for BOTH pair participants; prior endorsements invalidated.")
        obligations = {r["source_id"]: r for r in [*self.pair_obligations(), *self.pair_obligations(pair)]}
        self.state.update(pair_review=None, pair_carry=list(obligations.values()), pending=None, reviewed=None,
                          pair_clean={"pair_a": 0, "pair_b": 0}, phase="pair_a", coordinated=None,
                          pair_return=None, pair_b_substantial=False, pair_return_changed=False, pair_completed={})
        self.state.pop("pair_input_pending", None)
        self.save()

    def new_pair(self):
        state = self.state
        pair = {"id": uuid.uuid4().hex, "phase": state["phase"], "snapshot": self.snapshot(), "step": "scan",
                "round": state.get("pair_round", 0) + 1, "scans": {}, "jobs": {}, "discussion": 0,
                "issues": [], "positions": [], "resolutions": [], "carry": state.get("pair_carry", [])}
        state.update(pair_review=pair, pair_round=pair["round"])
        self.check_protected(pair["snapshot"])
        self.save()
        return pair

    def pair_call(self, pair, requests):
        view = materialize(self, pair)
        return run_jobs(self, pair, [(key, role, self.pair_prompt(pair, role, assignment))
                                     for key, role, assignment in requests], view)

    def reject_pair_report(self, pair, key, error):
        job = pair["jobs"][key]
        job["report_source"] = job.pop("result")
        job.setdefault("rejected_reports", []).append(job["report_source"])
        job.update(report_error=str(error), status="ready", report_repairs=job.get("report_repairs", 0) + 1)
        renew_report_marker(job)
        self.save()
        if job["report_repairs"] > 2:
            raise Blocked("pair-report", "Repeated invalid pair report: " + str(error))

    def pair_registry(self, pair):
        issues = list(copy.deepcopy(pair["carry"]))
        for role, report in pair["scans"].items():
            for finding in report["findings"]:
                issues.append(dict(finding, source_id=pair["id"] + "/" + role + "/" + finding["id"]))
        pair["issues"] = issues

    def pair_inspection_step(self, pair):
        roles = pair.get("roles", PAIRS[pair["phase"]])
        if pair["step"] == "scan":
            todo = [r for r in roles if r not in pair["scans"]]
            if pair["phase"] == "final" and not pair.get("repair_base"):
                todo = todo[:1]  # Sequential, but neither initial input contains its peer's result.
            reports = self.pair_call(pair, [("scan/" + r, r, {"mode": "independent_initial"}) for r in todo])
            if reports is None:
                return
            pair["scans"].update(zip(todo, reports))
            if len(pair["scans"]) == len(roles):
                self.pair_registry(pair)
                pair["step"] = "discuss" if pair["issues"] else "decide"
                if not pair["issues"]:
                    pair["decisions"], pair["impact"] = [], "minor"
            self.save()
            return
        if pair["step"] == "discuss":
            turn = pair["discussion"] + 1
            assignment = {"mode": "discussion", "exchange": turn, "reports": pair["scans"],
                          "registry": pair["issues"], "positions": pair["positions"],
                          "proposal": pair.get("proposal"), "proposal_hash": pair.get("proposal_hash"),
                          "closure_rule": (
                              'Carried findings include repair evidence. Explicitly reject a closed defect with its '
                              'proof. Do not assign a successful diagnostic again without NEW evidence.'
                          )}
            reports = self.pair_call(pair, [(f"discuss/{turn}/{r}", r + "_discuss", assignment) for r in roles])
            if reports is None:
                return
            key = pair.get("proposal_hash")
            for role, report in zip(roles, reports):
                try:
                    if report["consensus"] is not None:
                        if not key or report["consensus"] != key or report["impact"] != pair["proposal"]["impact"]:
                            raise Blocked("pair-consensus", consensus_error(key, key and pair["proposal"]["impact"]))
                    else:
                        validate_decisions(pair["issues"], report["assessments"], pair["phase"])
                except Blocked as error:
                    self.reject_pair_report(pair, f"discuss/{turn}/{role}", error)
                    return
            if key and all(r["consensus"] == key for r in reports):
                pair.update(decisions=pair["proposal"]["decisions"], impact=pair["proposal"]["impact"], step="decide")
            else:
                new = []
                for role, report in zip(roles, reports):
                    for finding in report["new_findings"]:
                        new.append(dict(finding, source_id=f"{pair['id']}/{role}/discussion-{turn}/{finding['id']}"))
                pair["issues"].extend(new)
                pair["positions"].append(reports)
                proposals = [r for r in reports if r["consensus"] is None]
                if proposals and not new:
                    proposed = {"decisions": proposals[0]["assessments"], "impact": proposals[0]["impact"]}
                    pair.update(proposal=proposed, proposal_hash=proposal_key(proposed["decisions"], proposed["impact"], digest(encode(pair["snapshot"]))))
                else:
                    pair.pop("proposal", None)
                    pair.pop("proposal_hash", None)
                pair["step"] = "arbitrate" if turn >= 2 else "discuss"
            pair["discussion"] = turn
            self.save()
            return
        if pair["step"] == "arbitrate":
            attempt = len(pair.get("rulings", [])) + 1
            assignment = {"mode": "binding_arbitration", "registry": pair["issues"], "reports": pair["scans"],
                          "positions": pair["positions"], "proposal": pair.get("proposal"),
                          "prior_rulings": pair.get("rulings", []), "executor_evidence": pair["resolutions"],
                          "reports_candidate": pair.get("reports_candidate", digest(encode(pair["snapshot"]))),
                          "fresh_inspection_required": pair.get("needs_inspection", False),
                          "rule": (
                              'Make binding decisions. Disagreement is not an operator blocker. Do not repeat an '
                              'answered diagnostic without new evidence. For a closed defect, explicitly return '
                              'reject with proof of closure.'
                          )}
            reports = self.pair_call(pair, [(f"arbitrate/{attempt}", "pair_arbiter", assignment)])
            if reports is None:
                return
            report = reports[0]
            try:
                validate_decisions(pair["issues"], report["assessments"], pair["phase"])
            except Blocked as error:
                self.reject_pair_report(pair, f"arbitrate/{attempt}", error)
                return
            pair.setdefault("rulings", []).append(report)
            pair.update(decisions=report["assessments"], impact=report["impact"], step="decide")
            self.save()
            return

    def paired_review_step(self):
        state = self.state
        pair = state.get("pair_review") or self.new_pair()
        if state.get("pair_input_pending"):
            self.accept_pair_input(pair, {"id": state["pair_input_pending"]})
            return
        if pair["phase"] != state["phase"]:
            raise Blocked("pair-route", "Saved pair belongs to another phase.")
        if pair["step"] == "repair":
            self.repair_step(pair)
            return
        # A writer's pending/result is validated by normal invoke, including its
        # entry snapshot. Readers must never use a snapshot after a concurrent edit.
        if pair["step"] not in ("fix", "cleanup") and self.snapshot() != pair["snapshot"]:
            raise Blocked("pair-drift", "The frozen candidate changed; reconcile it before granting pair credit.")
        if pair["step"] in ("scan", "discuss", "arbitrate"):
            self.pair_inspection_step(pair)
            return
        if pair["step"] == "decide":
            decisions = validate_decisions(pair["issues"], pair["decisions"], pair["phase"])
            tasks = [r for r in decisions if r["action"] in ("fix", "verify")]
            if not tasks and pair.get("needs_inspection"):
                state.update(pair_review=None, pair_carry=pair["issues"], last_snapshot=pair["snapshot"])
                self.save()
                return
            if not tasks:
                self.finish_pair(pair)
                return
            # A repeated unchanged diagnostic/dispute is escalated for recovery,
            # never treated as consensus or quietly allowed to loop forever.
            signature = assignment_key(pair["snapshot"], tasks)
            if signature in pair.get("executed_assignments", []):
                raise Blocked("pair-no-progress", "The arbiter repeated an answered assignment without new evidence; autonomous recovery must inspect its retained proof.")
            pair.setdefault("executed_assignments", []).append(signature)
            pair["tasks"] = tasks
            pair["repair_kind"] = "fix" if any(significant(t) for t in tasks) else "cleanup"
            if pair["phase"] in ("pair_b", "final"):
                self.start_repair(pair)
                return
            pair["step"] = "complexity"
            self.save()
            return
        if pair["step"] == "complexity":
            key = assignment_key(pair["snapshot"], pair["tasks"])
            assignment = {"mode": "repair_complexity", "assignment_sha256": key,
                          "tasks": pair["tasks"], "repair_kind": pair["repair_kind"],
                          "impact": pair["impact"], "prior_resolutions": pair["resolutions"],
                          "rule": (
                              'Evaluate repair difficulty only. Do not change accepted findings, severity, blocking '
                              'status, or scope. Choose Opus high for clear local repairs. Choose xhigh for complex '
                              'or uncertain repairs. Cover every assignment.'
                          )}
            job_key = "complexity/" + key
            reports = self.pair_call(pair, [(job_key, "pair_complexity", assignment)])
            if reports is None:
                return
            try:
                assessment = validate_complexity(reports[0]["complexity"], pair["snapshot"], pair["tasks"])
            except Blocked as error:
                self.reject_pair_report(pair, job_key, error)
                return
            pair.update(assessment=pair["jobs"][job_key]["result"], step=pair["repair_kind"],
                        executor_role="pair_" + pair["repair_kind"] + ("_high" if assessment["effort"] == "high" else ""))
            self.save()
            return
        if pair["step"] in ("fix", "cleanup"):
            self.pair_executor_step(pair)
            return
        raise Blocked("pair-route", "Unknown pair step: " + str(pair["step"]))

    def finish_pair(self, pair, snapshot=None, cleanup=False):
        state, phase = self.state, pair["phase"]
        snapshot = pair["snapshot"] if snapshot is None else snapshot
        self.check_protected(snapshot)
        record = artifact(self.store, f"pair-reviews/{state['iteration']}/{pair['id']}/conclusion.json",
                          {"candidate": digest(encode(pair["snapshot"])), "decisions": pair["decisions"],
                           "candidate_after": digest(encode(snapshot)), "impact": pair["impact"],
                           "cleanup_without_rereview": cleanup, "resolutions": pair["resolutions"],
                           "assessment": pair.get("assessment"),
                           "repair_gate": pair.get("repair_seal"),
                           "checks": list(dict.fromkeys(check for report in pair["scans"].values() for check in report["evidence"])),
                           "sources": [job["result"] for job in pair["jobs"].values() if job.get("result")]})
        state.setdefault("pair_handoff", []).append(record)
        state.setdefault("pair_completed", {})[phase] = record
        state.update(pair_carry=[], pair_review=None, last_snapshot=snapshot)
        if phase == "final":
            self.seal_pair_publication(pair, snapshot)
            return
        clean = state.setdefault("pair_clean", {"pair_a": 0, "pair_b": 0})
        clean[phase] = 0 if cleanup else 1
        state.update(phase="pair_b" if phase == "pair_a" else "final", coordinated=None)
        self.save()

    def seal_pair_publication(self, pair, snapshot):
        self.check_protected(snapshot)
        artifact(self.store, f"pair-reviews/{self.state['iteration']}/{pair['id']}/seal.json",
                 {"snapshot": snapshot, "decisions": pair["decisions"], "resolutions": pair["resolutions"],
                  "cleanup_without_rereview": pair["step"] == "cleanup" or bool(pair.get("repair") and not pair["repair"]["repeat_outer"]),
                  "assessment": pair.get("assessment"),
                  "repair_gate": pair.get("repair_seal"),
                  "reviewed_candidate": digest(encode(pair["snapshot"])),
                  "reports": [job["result"] for job in pair["jobs"].values() if job.get("result")] })
        self.state.update(reviewed=snapshot, last_snapshot=snapshot, phase="publish", pending=None,
                          coordinated=None, pair_review=None, pair_carry=[], recovery_unverified=False)
        self.save()
