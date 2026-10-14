"""Durable two-pass validation of late-pair repairs, before expensive re-review."""

import copy
import json
import time
import uuid

from cycle_state import Blocked, digest, encode
from cycle_prompts import PAIR_CONTRACT
from focus_pair_protocol import validate_decisions
from focus_pair_profile import significant
from focus_pair_view import artifact, materialize, read_record
from focus_repair_evidence import RepairEvidence


class RepairReview(RepairEvidence):
    def start_repair(self, pair):
        # Freeze the pre-fix candidate while it still exists. Inner reviews compare
        # the cumulative repair to this view, not to the whole iteration baseline.
        materialize(self, pair)
        pair["repair"] = {"snapshot": pair["snapshot"], "base": pair["view"], "step": "fix",
            "mode": "self", "reason": "Awaiting the executor's assessment of the actual patch",
            "clean": 0, "clean_candidate": None, "round": 0, "reader": None,
            "tasks": copy.deepcopy(pair["tasks"]), "accepted": copy.deepcopy(pair["tasks"]),
            "issues": copy.deepcopy(pair["issues"]), "resolutions": {}, "reviews": [],
            "executions": [], "repeat_outer": pair["repair_kind"] == "fix" or pair["impact"] == "substantial",
            "started": time.time(), "choices": [], "tests": []}
        pair.update(step="repair", executor_role="repair_execute")
        # One native executor conversation per repair batch, reused for self review
        # and tests. Independent pair reviewers always have fresh job sessions.
        self.state["sessions"].pop("repair_execute", None)
        self.save()

    def repair_writer_context(self):
        pair = self.state["pair_review"]
        gate = pair["repair"]
        testing = gate["step"] == "test"
        retained = []
        if testing:
            for reference in gate["tests"]:
                record = read_record(self.store, reference)
                if record["after"] == digest(encode(gate["snapshot"])):
                    retained.append({"record": reference, "tests": record["report"]["repair"]["tests"],
                                     "resolutions": record["accepted_resolutions"]})
        return PAIR_CONTRACT + "\nExecutor assignment:\n" + json.dumps({
            "task": self.state.get("task"), "phase": pair["phase"], "operation": gate["step"],
            "candidate": digest(encode(gate["snapshot"])), "assignments": gate["accepted"] if testing else gate["tasks"],
            "prior_resolutions": list(gate["resolutions"].values()), "clean_passes": gate["clean"],
            "retained_test_results": retained,
            "runtime_storage_repair": gate.get("storage_retry"),
            "minimum_review_mode": gate["mode"], "review_mode_reason": gate["reason"],
            "repair_paths": self.changes(pair["snapshot"], gate["snapshot"]),
            "protected_paths": self.state["protected"], "stage_paths": self.publication_paths(),
            "operator_instructions": self.pair_operator_instructions(),
            "corrections": [self.pair_correction_text(c) for c in self.state.get("corrections", [])],
            "verification": ((
                'Two static passes are complete. Run applicable targeted checks. Build only affected '
                'projects and necessary dependencies. Do not edit project files or journals. Put '
                'completed-check evidence in this JSON report. A verified resolution can confirm an '
                'earlier fixed assignment.\n\nIt cannot replace a missing repair. Report actual test '
                'defects as failed. Report external failures as infrastructure. If no checks apply, '
                'report not_needed with evidence. For infrastructure, failures can contain '
                'kind=verification obstacles, never kind=defect. Keep unfinished verification '
                'resolutions deferred.\n\nReuse retained successful checks on this candidate. Repeat '
                'only failed or incomplete checks and necessary prerequisites. A runtime storage '
                'repair archives review copies without changes to the candidate or tests. This repair '
                'does not prove that a failed check now passes. Close every deferred verification. Do '
                'not use not_needed while a required diagnostic remains.'
            )
                             if testing else (
                                 'Correct only the supplied assignments. Do NOT build or run tests in this invocation. '
                                 'Return tests.status=deferred. Mark verify assignments deferred with the exact planned'
                                 ' check. Select self or pair from actual patch risk, separately from finding severity.'
                                 ' Contracts, storage, security, concurrency, cross-component effects, algorithms, or '
                                 'uncertainty require pair.\n\nThe runtime can keep a stricter mode. Do not review your '
                                 'corrections in this writing invocation.'
                             ))},
            ensure_ascii=False, sort_keys=True)

    def repair_reader(self, pair):
        gate = pair["repair"]
        gate["round"] += 1
        roles = ["repair_self"] if gate["mode"] == "self" else ["repair_opus", "repair_astra"]
        disputed = [dict(row, resolution=gate["resolutions"][row["source_id"]]) for row in gate["issues"]
                    if gate["resolutions"].get(row["source_id"], {}).get("outcome") == "disputed"]
        reader = {"id": uuid.uuid4().hex, "phase": pair["phase"], "snapshot": gate["snapshot"],
            "step": "scan", "round": gate["round"], "roles": roles, "scans": {}, "jobs": {},
            "discussion": 0, "issues": [], "positions": [], "resolutions": [], "carry": disputed,
            "repair_base": gate["base"], "repair_snapshot": pair["snapshot"],
            "repair_context": {"mode": gate["mode"], "pass": gate["clean"] + 1,
                "focus": "Closure and completeness" if gate["clean"] == 0 else "Check regressions and side effects. Independently recheck closure.",
                "assignments": gate["accepted"], "resolutions": list(gate["resolutions"].values()),
                "rule": (
                    'Review only the cumulative repair diff and necessary surrounding source. Do not '
                    'build, test, or edit. Every confirmed relevant defect, including low severity, '
                    'requires correction. Describe future tests as verification obligations. Their '
                    'scheduled execution is not itself a static defect. Keep initial opinions independent.'
                    '\n\nDiscuss findings. Endorse the exact common proposal. After two exchanges, Astra/max'
                    ' arbitrates.'
                )}}
        if gate["mode"] == "self":
            reader["session_owner"] = "repair_execute"
            reader["allow_new_self_session"] = gate.get("new_session_requested", False)
        gate["reader"] = reader
        self.save()
        return reader

    def repair_step(self, pair):
        gate = pair["repair"]
        if gate["step"] == "evidence":
            self.repair_evidence_step(pair)
            return
        saved = self.saved_repair_test(pair) if gate["step"] == "test" else None
        if saved and not self.state.get("pending"):
            self.state["pending"] = copy.deepcopy(saved[0])
            gate["test_invocation"] = saved[0]["id"]
            self.save()  # Reuse the exact result; never repeat its successful tests.
        if gate["step"] != "fix" and self.snapshot() != gate["snapshot"] and not saved:
            raise Blocked("repair-drift", "Repair candidate changed; no clean review or test credit can be reused.")
        if gate["step"] == "fix":
            self.repair_execute(pair)
        elif gate["step"] == "review":
            reader = gate["reader"] or self.repair_reader(pair)
            if reader["step"] in ("scan", "discuss", "arbitrate"):
                self.pair_inspection_step(reader)
                return
            self.repair_review_result(pair, reader)
        elif gate["step"] == "test":
            if gate["clean"] != 2 or not self.repair_clean_matches(gate, gate["snapshot"]):
                raise Blocked("repair-test-gate", "Tests require two clean static passes on this exact repair candidate.")
            self.repair_execute(pair, testing=True)
        elif gate["step"] == "complete":
            self.finish_repair(pair)
        else:
            raise Blocked("repair-route", "Unknown repair verification step.")

    def repair_execute(self, pair, testing=False):
        gate = pair["repair"]
        # Normal invoke owns durable results and VCS/protected-work checks.
        # Unexplained changes before a fresh writer are never adopted as its work.
        if not self.state.get("pending") and self.snapshot() != gate["snapshot"]:
            raise Blocked("repair-drift", "Source changed before the repair executor started.")
        report, before, after, _ = self.invoke("repair_execute")
        if (self.state.get("pending") or {}).get("restart_reviews"):
            self.reset_reviews("Оператор изменил задание исполнителю; пары проверяются заново")
            self.state.update(pending=None, last_snapshot=after)
            self.save()
            return
        self.accept_repair_result(pair, report, before, after, testing, (self.state.get("pending") or {}).get("id"))

    def accept_repair_result(self, pair, report, before, after, testing, invocation, evidence_approval=None):
        gate = pair["repair"]
        tasks = gate["accepted"] if testing else gate["tasks"]
        resolutions = {r["source_id"]: r for r in report["resolutions"]}
        if set(resolutions) != {t["source_id"] for t in tasks}:
            raise Blocked("repair-closure", "Executor must account for every assigned finding.")
        repair, tests = report["repair"], report["repair"]["tests"]
        if testing:
            if report["substantial"] or any(report[k] for k in ("implementation_fixes", "other_fixes")):
                raise Blocked("repair-test-edit", "Tests changed the candidate; repairs require a new static review cycle.")
            if tests["status"] == "deferred":
                raise Blocked("repair-tests", "The test invocation must report actual checks or an explicit applicability assessment.")
            if tests["status"] == "not_needed" and any(t["action"] == "verify" for t in tasks):
                raise Blocked("repair-tests", "Required diagnostic assignments cannot be skipped as inapplicable.")
        elif tests["status"] != "deferred":
            raise Blocked("repair-early-tests", "Fixing and testing are separate invocations; tests follow two clean passes.")
        for task in tasks:
            outcome = resolutions[task["source_id"]]["outcome"]
            if testing and task["action"] == "fix" and outcome == "verified":
                resolutions[task["source_id"]] = self.verified_fix_resolution(gate, resolutions[task["source_id"]])
                outcome = "fixed"
            expected = "verified" if task["action"] == "verify" else "fixed"
            allowed = {expected, "disputed"}
            if (not testing and task["action"] == "verify") or (testing and tests["status"] in ("failed", "infrastructure")):
                allowed.add("deferred")
            if not testing and task["action"] == "verify":
                allowed.discard("verified")
            if outcome not in allowed:
                raise Blocked("repair-closure", "Resolution contradicts the fix/verification assignment or the current gate.")
        if testing and tests["status"] in ("passed", "not_needed") and any(r["outcome"] in ("disputed", "deferred") for r in resolutions.values()):
            raise Blocked("repair-closure", "Successful test completion cannot leave unresolved assignments.")
        if testing and before != after and not evidence_approval:
            self.queue_repair_evidence(pair, report, before, after, invocation)
            return
        record = artifact(self.store, f"pair-reviews/{self.state['iteration']}/{pair['id']}/repair/execution-{len(gate['executions'])}.json",
                          {"report": report, "before": digest(encode(before)), "after": digest(encode(after)),
                           "operation": "test" if testing else "fix", "at": time.time(), "invocation": invocation,
                           "evidence_approval": evidence_approval, "accepted_resolutions": list(resolutions.values())})
        gate["executions"].append(record)
        gate["choices"].append({"mode": repair["mode"], "reason": repair["reason"], "risks": repair["risks"], "report": record})
        if repair["mode"] == "pair" or report["substantial"] or any(r["outcome"] == "disputed" for r in resolutions.values()):
            gate.update(mode="pair", reason=repair["reason"] if repair["mode"] == "pair" else "Substantial or disputed repair requires independent reviewers")
        elif gate["mode"] == "self":
            gate["reason"] = repair["reason"]
        gate["resolutions"].update(resolutions)
        gate["repeat_outer"] |= report["substantial"]
        gate["snapshot"] = after
        self.state.update(pending=None, last_snapshot=after)
        if not testing:
            gate.update(clean=0, clean_candidate=None, reader=None, step="review")
        else:
            gate["step"] = "test"
            gate.setdefault("consumed_tests", []).extend(self.with_correction_source(invocation))
            gate.pop("test_invocation", None)
            gate.pop("test_receipt", None)
            gate.pop("evidence_reader", None)
            gate["tests"].append(record)
            if tests["status"] == "failed":
                # Tests found a defect missed by static review. Never downgrade
                # back to self review in this batch, even after a small fix.
                gate.update(mode="pair", reason="Tests exposed a defect missed by static review", clean=0,
                            clean_candidate=None, reader=None, step="fix")
                tasks = []
                for finding in tests["failures"]:
                    row = dict(finding, source_id=f"{pair['id']}/tests-{len(gate['tests'])}/{finding['id']}")
                    gate["issues"].append(row)
                    tasks.append({"source_id": row["source_id"], **{k: row[k] for k in ("title", "body", "severity", "locations")},
                        "action": "fix", "duplicate_of": None, "blocking": True, "reason": tests["reason"],
                        "repair": row["body"], "check": "Repeat the failed targeted check after two clean static passes", "full_suite": False})
                gate["accepted"].extend(tasks)
                gate["tasks"] = tasks
                gate["repeat_outer"] = True
                normalized = [{k: f[k] for k in ("title", "body", "locations")} for f in tests["failures"]]
                key = digest(encode({"candidate": self.repair_evidence_hash(gate, digest(encode(after))),
                                     "failures": sorted(normalized, key=lambda f: encode(f))}))
                if key in gate.get("failed_candidates", []):
                    self.save()
                    raise Blocked("pair-no-progress", "Targeted tests repeated the same failure on an unchanged repair; recovery must inspect the retained evidence.")
                gate.setdefault("failed_candidates", []).append(key)
            elif tests["status"] == "infrastructure":
                if before == after and self.retry_after_storage_repair(gate, invocation):
                    self.save()
                    print("cc-focus: Review snapshot storage was repaired after these tests; retrying only outstanding verification with retained evidence.", flush=True)
                    return
                self.save()
                raise Blocked("repair-test-infrastructure", tests["reason"])
            else:
                # A test-only invocation may discover risks without editing.
                # If it promotes self -> pair, collect the missing independent
                # reviews and repeat checks before giving completion credit.
                last_mode = gate["reviews"][-1]["mode"]
                if gate["mode"] != last_mode:
                    gate.update(clean=0, clean_candidate=None, reader=None, step="review")
                else:
                    gate["step"] = "complete"
        self.save()

    def retry_after_storage_repair(self, gate, invocation):
        reference = self.state.get("snapshot_storage")
        if not reference or gate.get("storage_retry") == reference:
            return False
        receipt = read_record(self.store, reference)
        try:
            # A report-only correction starts later. The tests ran in the original invocation.
            original = self.with_correction_source(invocation)[-1]
            intent = json.loads((self.store.directory / "invocations" / original / "intent.json").read_text(encoding="utf-8"))
            started = intent["started"]
            if type(started) not in (int, float) or not 0 < started < receipt["at"]:
                return False
        except (OSError, ValueError, KeyError, TypeError):
            return False
        gate["storage_retry"] = reference
        return True

    def repair_review_result(self, pair, reader):
        gate = pair["repair"]
        decisions = validate_decisions(reader["issues"], reader["decisions"], pair["phase"])
        if any(d["action"] == "defer" for d in decisions):
            raise Blocked("repair-deferral", "Relevant repair findings must be fixed; unrelated suggestions must be rejected with a scope reason.")
        tasks = [d for d in decisions if d["action"] in ("fix", "verify")]
        fixes = [d for d in tasks if d["action"] == "fix"]
        gate["repeat_outer"] |= any(significant(t) for t in tasks)
        gate["repeat_outer"] |= reader["impact"] == "substantial"
        seen = {r["source_id"] for r in gate["issues"]}
        gate["issues"].extend(r for r in reader["issues"] if r["source_id"] not in seen)
        accepted = {d["source_id"]: d for d in gate["accepted"]}
        accepted.update({d["source_id"]: d for d in tasks})
        gate["accepted"] = list(accepted.values())
        for d in decisions:
            if d["action"] == "reject" and gate["resolutions"].get(d["source_id"], {}).get("outcome") == "disputed":
                gate["resolutions"][d["source_id"]] = {"source_id": d["source_id"], "outcome": "verified",
                    "resolution": "Rejected after inspection: " + d["reason"], "evidence": [d["reason"]]}
                gate["accepted"] = [r for r in gate["accepted"] if r["source_id"] != d["source_id"]]
        record = artifact(self.store, f"pair-reviews/{self.state['iteration']}/{pair['id']}/repair/review-{gate['round']}.json",
            {"candidate": digest(encode(reader["snapshot"])), "mode": gate["mode"], "decisions": decisions,
             "sources": [j["result"] for j in reader["jobs"].values() if j.get("result")], "view": reader["view"], "at": time.time()})
        gate["reviews"].append({"record": record, "mode": gate["mode"], "clean": not fixes,
                                "candidate": digest(encode(reader["snapshot"]))})
        if fixes:
            # Scan-local IDs change each pass; they must not defeat no-progress
            # detection for the same candidate and repeated substantive finding.
            normalized = [{k: d[k] for k in ("title", "body", "locations", "action", "repair", "check")} for d in fixes]
            key = digest(encode({"candidate": reader["snapshot"], "tasks": sorted(normalized, key=lambda d: encode(d))}))
            if key in gate.get("executed_assignments", []):
                raise Blocked("pair-no-progress", "Inner reviewers repeated an answered repair without new evidence.")
            gate.setdefault("executed_assignments", []).append(key)
            gate.update(tasks=fixes, clean=0, clean_candidate=None, step="fix")
            if reader["impact"] == "substantial":
                gate.update(mode="pair", reason="Inner review identified substantial repair risk", repeat_outer=True)
        else:
            if reader["impact"] == "substantial" and gate["mode"] == "self":
                gate.update(mode="pair", reason="Static review identified substantial risk", repeat_outer=True,
                            clean=0, clean_candidate=None, reader=None, step="review")
                self.save()
                return
            candidate = digest(encode(reader["snapshot"]))
            gate["clean"] = gate["clean"] + 1 if gate["clean_candidate"] == candidate else 1
            gate["clean_candidate"] = candidate
            gate["step"] = "test" if gate["clean"] == 2 else "review"
            if gate["clean"] == 2:
                gate["test_view"] = reader["view"]
        gate["reader"] = None
        self.save()

    def finish_repair(self, pair):
        gate = pair["repair"]
        for approval in gate.get("evidence_changes", []):
            self.validate_evidence_bridge(approval)
        if gate["clean"] != 2 or not self.repair_clean_matches(gate, gate["snapshot"]):
            raise Blocked("repair-seal", "Repair validation is incomplete or belongs to another candidate.")
        recent = gate["reviews"][-2:]
        if len(recent) != 2 or any(not r["clean"] or r["candidate"] != gate["clean_candidate"] or r["mode"] != gate["mode"] for r in recent):
            raise Blocked("repair-seal", "Both clean passes must cover the current candidate and review mode.")
        for review in gate["reviews"]:
            value = read_record(self.store, review["record"])
            for source in value["sources"]:
                read_record(self.store, source)
        for execution in gate["executions"]:
            read_record(self.store, execution)
        if not gate["tests"]:
            raise Blocked("repair-seal", "The separate test/applicability invocation is missing.")
        test = read_record(self.store, gate["tests"][-1])
        if (test["operation"] != "test"
                or self.repair_evidence_hash(gate, test["before"], gate["clean_candidate"]) != gate["clean_candidate"]
                or self.repair_evidence_hash(gate, test["after"], gate["clean_candidate"]) != gate["clean_candidate"]
                or test["report"]["repair"]["tests"]["status"] not in ("passed", "not_needed")):
            raise Blocked("repair-seal", "The last test evidence does not certify this candidate.")
        seal = artifact(self.store, f"pair-reviews/{self.state['iteration']}/{pair['id']}/repair/seal.json",
                        {**gate, "executor_reports": len(gate["executions"]), "static_passes": len(gate["reviews"]),
                         "elapsed_seconds": time.time() - gate["started"]})
        pair["repair_seal"] = seal
        pair["resolutions"].append(list(gate["resolutions"].values()))
        self.state.setdefault("pair_handoff", []).append(seal)
        if not gate["repeat_outer"]:
            self.finish_pair(pair, gate["snapshot"], cleanup=True)
        else:
            by_id = {r["source_id"]: r for r in gate["issues"]}
            carry = [dict(by_id[t["source_id"]], previous_decision=t, resolution=gate["resolutions"][t["source_id"]])
                     for t in gate["accepted"]]
            self.state.update(pair_carry=carry, pair_review=None, last_snapshot=gate["snapshot"])
            self.save()
