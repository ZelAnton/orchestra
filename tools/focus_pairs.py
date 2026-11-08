"""Paired reviews, bounded agreement, autonomous arbitration and one serial fixer."""

import copy
import json
import uuid

from cycle_state import Blocked, digest, encode
from cycle_prompts import BRIEF_CHANGE_CORRECTION, PAIR_CONTRACT, PARALLEL_REPOSITORIES_RULE, PROJECT_INSTRUCTIONS_RULE
import focus_brief
from focus_pair_profile import PAIRS, PAIR_WRITERS, significant
from focus_pair_protocol import (assignment_key, consensus_error, proposal_key, validate_complexity,
                                 validate_decisions)
from focus_pair_view import artifact, materialize, read_record, view_instructions
from focus_pair_jobs import run_jobs, renew_report_marker
from focus_pair_repair import RepairReview, final_gate_row
from focus_pair_execution import PairExecution


def assignment_context(prompt):
    """Read the runtime assignment of a saved pair prompt. An unreadable prompt has no context."""
    try:
        context = json.JSONDecoder().raw_decode(prompt.split("\nRuntime assignment:\n", 1)[1])[0]
    except (IndexError, ValueError):
        return {}
    return context if isinstance(context, dict) else {}


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
        # A later final pair decides about the final gate again.
        return [row for row in rows.values() if not final_gate_row(row)]

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
                   "inspection": 'Use focus_inspect search/read/list/diff. Search first. Then read only the line ranges that you need. In Claude, use mcp__focus__inspect. Read new files even if their diff is empty.',
                   "independence": 'Keep initial reports independent. The partner report is unavailable until both inspections finish.',
                   "history": [n for n in view["files"] if n.startswith("__review__/")
                               and (pair["phase"] != "final" or n.startswith("__review__/gate"))]}
        if view.get("publication"):
            context["publication_manifest"] = view["publication"]
            context["publication_rule"] = "Read the runtime manifest before checking publication findings. It records planned scope, not completed publication."
        # Explicit operator corrections are normative, not agent judgments. Never
        # expose archived runtime state or old review/coding descriptions here.
        context["corrections"] = self.pair_corrections()
        context.update(self.pair_brief_context(pair, role))
        context.update(self.pair_instruction_context(pair, view))
        if pair.get("repair_base"):
            context["repair_review"] = pair["repair_context"]
        scope = view.get("review_scope") if not pair.get("repair_base") else None
        if scope:
            context["review_scope"] = scope
        if pair["phase"] == "pair_b":
            context["full_run"] = {"available": not self.full_run_used("pair_b"), "rule": (
                'A full_suite assignment is an exception. If the change type does not strictly require '
                'a full run, do not use it. The benefit must justify the long wait. State the change '
                'type and the risk in the reason. Each stage permits one Pair B full run. After that '
                'run, assign only targeted checks.'
            )}
        if pair["phase"] == "final" and not pair.get("repair_base") and role in PAIRS["final"]:
            context["final_gate"] = {"available": not self.full_run_used("final"),
                                     "full_runs": self.full_run_facts(view["candidate"]), "rule": (
                'If the changes justify a full run before publication, set final_gate.full_run=true. The '
                'threshold for this request is lower than for a Pair B full_suite assignment. These '
                'reasons can justify it: shared or cross-component effects, build or test configuration, '
                'or a project rule. Specific risks that targeted checks do not cover can also justify it.'
                ' Local changes that targeted checks cover do not justify it. Explain the decision in '
                'final_gate.reason.\n\nEach stage permits one final gate. If available is false, set '
                'final_gate.full_run=false. The full_runs field lists the passed full runs of this stage. If'
                ' a full run passed on this candidate, do not request the gate. If a full run passed on an '
                'earlier candidate, evaluate only the later changes.'
            )}
        from focus_review_contract import review_contract
        return review_contract(PAIR_CONTRACT, bool(scope)) + "\nRuntime assignment:\n" + json.dumps(context, ensure_ascii=False, sort_keys=True)

    def pair_operator_instructions(self):
        rows = {}
        for record in self.messages.accepted(self.state["iteration"]):
            identity = record["identity"]
            rows[identity["id"]] = {"id": identity["id"], "text": identity["text"]}
        for row in self.state.get("pair_instructions", []):
            rows.setdefault(row["id"], row)
        return list(rows.values())

    def full_run_used(self, phase):
        """Pair B and the final gate each permit one full run in a stage. The runtime records each run after its tests."""
        return phase in ("pair_b", "final") and any(run["phase"] == phase for run in self.state.get("pair_full_runs", []))

    def full_run_facts(self, candidate):
        # Only passed runs are relevant to the gate request. A failed run is review history.
        return [{"phase": run["phase"], "this_candidate": run["candidate"] == candidate}
                for run in self.state.get("pair_full_runs", []) if run["status"] == "passed"]

    def pair_correction_text(self, correction):
        from pathlib import Path
        return Path(correction["path"]).read_text(encoding="utf-8")

    def pair_corrections(self):
        # Saved pair prompts contain this key, also as an empty list. A brief change arrives only as its notice.
        return [self.pair_correction_text(c) for c in self.state.get("corrections", []) if not c.get("brief_change")]

    def pair_brief_context(self, pair, role=None):
        """The brief fields of a pair context. A pair from an older runtime has no hash and no brief."""
        fields = {}
        if any(c.get("brief_change") for c in self.state.get("corrections", [])):
            fields["project_brief_notice"] = BRIEF_CHANGE_CORRECTION
        brief = focus_brief.pair_hash(pair)
        if brief and role not in focus_brief.EXCLUDED_READERS:
            fields["project_brief"] = focus_brief.delivery(self.repo.root, brief, self.brief_prompt_remedy())
        return fields

    @staticmethod
    def pair_brief_record(pair):
        """The brief hash for conclusions and seals. An older pair adds no field."""
        return {"project_brief_sha256": pair["project_brief_sha256"]} if "project_brief_sha256" in pair else {}

    def pair_instruction_context(self, pair, view):
        """The instruction fields of every reader. A pair from an older runtime has no marker and no field.

        Version 1 gives the instruction list. Version 2 also gives the parallel repositories of the pair.
        """
        if "project_instructions_version" not in pair:
            return {}
        if pair["project_instructions_version"] not in (1, 2):
            # A recovery agent cannot install a runtime, so the operator gets this blocker.
            # The state checksum detects a manual edit, so another version comes from a newer runtime or a defect.
            review_id = (self.state.get("review_run") or {}).get("id")
            correct = (f"cc-focus correct --review-run {review_id} --message TEXT" if review_id
                       else "cc-focus correct --message TEXT")
            # A correction cannot reopen a stage after its publication started.
            remedy = ("" if self.state.get("published") or self.state.get("publication_started") else
                      f" To continue, run {correct}. In the terminal of the run, /correct TEXT also works. "
                      "A correction starts the work of this stage again.")
            raise Blocked("instruction-version", "A pair record has an unsupported project instruction version. "
                          "A newer runtime wrote it, or the runtime has a defect. If a newer runtime wrote it, "
                          "install that runtime with cc-sync. Otherwise, report the defect." + remedy)
        files = view_instructions(view, pair["snapshot"]["repositories"])
        fields = {"project_instructions": {"files": files, "rule": PROJECT_INSTRUCTIONS_RULE}} if files else {}
        if pair["project_instructions_version"] == 2 and pair.get("parallel_repositories"):
            fields["parallel_repositories"] = {"repositories": pair["parallel_repositories"], "rule": PARALLEL_REPOSITORIES_RULE}
        return fields

    @staticmethod
    def pair_instruction_record(pair):
        """The instruction marker and its data for a pair that continues PAIR. An older pair adds no field."""
        return {key: pair[key] for key in ("project_instructions_version", "parallel_repositories") if key in pair}

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
                   "corrections": self.pair_corrections(),
                   "verification": (
                       'PAIR A: make the assigned corrections now. Then run the assigned targeted checks. '
                       'Build only affected projects and necessary dependencies. The B/final two-clean-pass '
                       'gate does not apply here, even if an assignment incorrectly refers to it. Return one '
                       'resolution for every assigned source_id, including deferred work. Do not claim that '
                       'unrun tests passed.'
                   ),
                   "complexity": self.pair_assessment(pair),
                   "cleanup": pair["step"] == "cleanup",
                   "stage_handoff": self.stage_handoff(),
                   "stage_handoff_rule": ('Read the stage handoff when you need an earlier decision, assumption, or check. '
                                          'The current assignment, operator corrections, and operator messages have priority.'),
                   **self.pair_brief_context(pair)}
        from focus_publication_scope import manifest as publication_manifest
        context["publication_manifest"] = publication_manifest(self, execution["snapshot"] if execution else pair["snapshot"])
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

    def stage_handoff(self):
        """The handoff records of this stage, for a writer that starts a new session in each pair.

        Executor records, pair conclusions, and repair seals are in the list. Each entry reads its record,
        so a changed record stops the writer with pair-evidence. Older records have no phase.
        A repair seal keeps its inner review rounds in round and the outer pair round in pair_round.
        """
        rows = []
        for ref in self.state.get("pair_handoff", []):
            record = read_record(self.store, ref)
            row = {"path": str(self.store.directory / ref["path"])}
            if "phase" in record:
                row.update(phase=record["phase"], round=record["pair_round"] if "pair_round" in record else record.get("round"))
            rows.append(row)
        return rows

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
                "issues": [], "positions": [], "resolutions": [], "carry": state.get("pair_carry", []),
                # Peers, inner readers, writers, and the final gate use this hash, not the current pointer.
                "project_brief_sha256": focus_brief.stage_hash(state)}
        if hasattr(self.repo, "repositories"):
            # Readers list the instruction files of their frozen view. Inner readers and the final gate copy the marker.
            # The pair keeps the parallel members of its stage, so a saved reader prompt does not change.
            pair.update(project_instructions_version=2, parallel_repositories=list(state.get("parallel", [])))
        state.update(pair_review=pair, pair_round=pair["round"])
        # Each outer pair starts the Pair A executor sessions again, so a session does not grow over the whole stage.
        # The writer gets the earlier work of the stage as stage_handoff.
        from focus_pair_profile import PAIR_A_WRITERS
        for role in PAIR_A_WRITERS:
            state["sessions"].pop(role, None)
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
            for role, report in zip(todo, reports):
                # A job saved before the final_gate rule has no such context and requests no gate.
                if "final_gate" not in report and "final_gate" in assignment_context(pair["jobs"]["scan/" + role]["prompt"]):
                    self.reject_pair_report(pair, "scan/" + role, Blocked(
                        "pair-report", "The report has no final_gate field. Add final_gate with full_run and reason."))
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
                        validate_decisions(pair["issues"], report["assessments"], pair["phase"], self.full_run_used(pair["phase"]))
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
            # The previous arbitration added findings to the registry. This one decides them and adds none.
            extended = pair.get("arbiter_extension") == attempt - 1
            rule = (
                'Make binding decisions. Disagreement is not an operator blocker. Do not repeat an '
                'answered diagnostic without new evidence. For a closed defect, explicitly return '
                'reject with proof of closure.'
            )
            if extended:
                rule += ('\n\nThe previous arbitration added findings to the registry. Decide the complete '
                         'registry. Return new_findings=[].')
            assignment = {"mode": "binding_arbitration", "registry": pair["issues"], "reports": pair["scans"],
                          "positions": pair["positions"], "proposal": pair.get("proposal"),
                          "prior_rulings": pair.get("rulings", []), "executor_evidence": pair["resolutions"],
                          "reports_candidate": pair.get("reports_candidate", digest(encode(pair["snapshot"]))),
                          "fresh_inspection_required": pair.get("needs_inspection", False),
                          "rule": rule}
            reports = self.pair_call(pair, [(f"arbitrate/{attempt}", "pair_arbiter", assignment)])
            if reports is None:
                return
            report = reports[0]
            try:
                validate_decisions(pair["issues"], report["assessments"], pair["phase"], self.full_run_used(pair["phase"]))
                if extended and report["new_findings"]:
                    raise Blocked("pair-report", "The previous arbitration already added findings. "
                                  "Return new_findings=[] and decide every supplied source_id.")
            except Blocked as error:
                self.reject_pair_report(pair, f"arbitrate/{attempt}", error)
                return
            pair.setdefault("rulings", []).append(report)
            if report["new_findings"]:
                # Like discussion findings, new arbiter findings join the registry. The next arbitration decides them.
                pair["issues"].extend(dict(finding, source_id=f"{pair['id']}/pair_arbiter/arbitrate-{attempt}/{finding['id']}")
                                      for finding in report["new_findings"])
                pair["arbiter_extension"] = attempt
                self.save()
                return
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
            decisions = validate_decisions(pair["issues"], pair["decisions"], pair["phase"], self.full_run_used(pair["phase"]))
            key = digest(encode(decisions))
            if state.get("review_run") and key not in pair.setdefault("recorded_decisions", []):
                # The campaign report lists the decisions of every round. A round with fixes ends without a conclusion.
                pair["recorded_decisions"].append(key)
                state.setdefault("pair_decisions", []).append(artifact(
                    self.store, f"pair-reviews/{state['iteration']}/{pair['id']}/decisions-{len(pair['recorded_decisions'])}.json",
                    {"phase": pair["phase"], "pair": pair["id"], "decisions": decisions}))
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
                           "sources": [job["result"] for job in pair["jobs"].values() if job.get("result")],
                           "phase": phase, "round": pair.get("round"), **self.pair_brief_record(pair)})
        state.setdefault("pair_handoff", []).append(record)
        state.setdefault("pair_completed", {})[phase] = record
        state.update(pair_carry=[], pair_review=None, last_snapshot=snapshot)
        if phase == "final":
            if not self.start_final_gate(pair, snapshot, record):
                self.seal_pair_publication(pair, snapshot)
            return
        clean = state.setdefault("pair_clean", {"pair_a": 0, "pair_b": 0})
        clean[phase] = 0 if cleanup else 1
        state.update(phase="pair_b" if phase == "pair_a" else "final", coordinated=None)
        self.save()

    def seal_pair_publication(self, pair, snapshot):
        self.check_protected(snapshot)
        # A final gate pair made no correction. A cleanup before it is in the final-pair conclusion.
        gate = pair.get("final_gate")
        cleanup = (read_record(self.store, gate["review"])["cleanup_without_rereview"] if gate
                   else pair["step"] == "cleanup" or bool(pair.get("repair") and not pair["repair"]["repeat_outer"]))
        artifact(self.store, f"pair-reviews/{self.state['iteration']}/{pair['id']}/seal.json",
                 {"snapshot": snapshot, "decisions": pair["decisions"], "resolutions": pair["resolutions"],
                  "cleanup_without_rereview": cleanup,
                  "final_gate": gate,
                  "assessment": pair.get("assessment"),
                  "repair_gate": pair.get("repair_seal"),
                  "reviewed_candidate": digest(encode(pair["snapshot"])),
                  "reports": [job["result"] for job in pair["jobs"].values() if job.get("result")],
                  **self.pair_brief_record(pair)})
        self.state.update(reviewed=snapshot, last_snapshot=snapshot, phase="publish", pending=None,
                          coordinated=None, pair_review=None, pair_carry=[], recovery_unverified=False)
        self.save()
