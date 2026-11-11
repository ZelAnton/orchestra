"""Exact, audited journal deltas and replay of completed late-repair tests.

No path is excluded from snapshots. An evidence verdict relates two full candidate
hashes; it cannot waive an unrelated edit, HEAD/index drift or another test run.
"""

import json
from pathlib import Path
import uuid

from cycle_state import Blocked, digest, encode
from cycle_transport import (parse_report, repairable_enum, repairable_executor_accounting, repairable_repair_mode,
                             repairable_substantial_accounting)
from focus_pair_protocol import assignment_key
from focus_pair_view import artifact, read_record
from focus_snapshot_archive import SnapshotWriter, read_source


def deferred_fixes(tasks, report):
    """The fix assignments that a B/final fix invocation returned deferred, if no other outcome breaks the gate.

    The fix invocation cannot build or test, so it cannot defer a fix. A report-only correction decides
    these assignments again: fixed, or disputed for the readers and the arbiter. Other cases return [].
    """
    outcomes = {row["source_id"]: row["outcome"] for row in report["resolutions"]}
    # A blocked report defers its work for another reason. Its retry runs the executor again.
    if (report["status"] != "done" or set(outcomes) != {task["source_id"] for task in tasks}
            or report["repair"]["tests"]["status"] != "deferred"):
        return []
    # The allowed outcomes of the fix step, as in accept_repair_result.
    wrong = [task for task in tasks if outcomes[task["source_id"]] not in (
        ("disputed", "deferred") if task["action"] == "verify" else ("fixed", "disputed"))]
    if not wrong or any(task["action"] != "fix" or outcomes[task["source_id"]] != "deferred" for task in wrong):
        return []
    return [task["source_id"] for task in wrong]


class RepairEvidence:
    @staticmethod
    def earlier_views(reader):
        """Name the legacy views where kept jobs began. A kept job that runs again
        reads the renewed view; its first prompt stays in `frozen_prompt`."""
        views = []
        for job in reader["jobs"].values():
            if job.get("frozen_view") and job["frozen_view"] not in views:
                views.append(job["frozen_view"])
        return {"earlier_views": views} if views else {}

    def repair_binding(self, pair):
        gate = pair["repair"]
        return {"pair": pair["id"], "operation": gate["step"],
                "candidate": digest(encode(gate["snapshot"])),
                "assignments": assignment_key(gate["snapshot"], gate["accepted"] if gate["step"] == "test" else gate["tasks"])}

    def saved_repair_fix(self, pair):
        """The intent of the last executor run of this fix step that a retry can continue.

        This is a run whose report only a report-only correction can save, a valid report with deferred fix
        assignments, or an unfinished correction without its result. The step then starts or resumes the
        correction instead of a drift stop. Any other saved result is not adopted, so a retry runs the executor again.
        """
        gate = pair["repair"]
        if gate["step"] != "fix" or self.state.get("pending"):
            return None
        binding, latest = self.repair_binding(pair), None
        folder = self.store.directory / "invocations"
        for directory in (folder.iterdir() if folder.is_dir() else ()):
            try:
                intent = json.loads((directory / "intent.json").read_text(encoding="utf-8"))
            except (OSError, ValueError):
                continue
            if (isinstance(intent, dict) and intent.get("role") == "repair_execute" and intent.get("id") == directory.name
                    and intent.get("iteration") == self.state["iteration"] and intent.get("repair_binding") == binding
                    and (latest is None or intent.get("started", 0) > latest[0].get("started", 0))):
                latest = (intent, directory)
        if latest is None:
            return None
        intent, directory = latest
        reason = (intent.get("report_repair") or {}).get("reason")
        if intent.get("restart_reviews") or intent.get("correction_revision") != self.state.get("correction_revision"):
            return None  # An operator change runs the executor again.
        try:
            if reason and not (directory / "result.json").exists():
                # A correction that stopped before its result, for example on a provider failure, resumes against
                # its unchanged source and files. Without this, the changed files would stop the retry as drift.
                repair = intent["report_repair"]
                unchanged = (digest(Path(repair["source"]).read_bytes()) == repair["sha256"]
                             and self.snapshot(repair["after"]) == self.snapshot() and self.snapshot(intent["before"]) == gate["snapshot"])
                return intent if unchanged else None
            if reason == "deferred-fix":
                return None  # Each completed correction runs once.
            result = json.loads((directory / "result.json").read_text(encoding="utf-8"))
            if self.snapshot(intent["before"]) != gate["snapshot"] or self.snapshot(result["after"]) != self.snapshot():
                return None
            try:
                report = parse_report(result["raw"], "repair_execute")
            except Blocked:
                report = None
            if report is not None:
                # A valid report replays only when its fix assignments wait for checks. The step then requests
                # the report-only correction. Another valid report is not replayed, and the retry runs the executor.
                # The corrected report of another correction can also replay, because a deferred-fix correction can follow it.
                # A correction that invoke() rejected does not replay, so its retry runs the executor again.
                if not deferred_fixes(gate["tasks"], report):
                    return None
                if reason:
                    try:
                        self.validate_executor_correction(intent, report)
                    except Blocked:
                        return None
                return intent
            if reason:
                return None  # Another correction of a correction is not possible.
            # The same recognizers as in invoke(), in the same order.
            correctable = (repairable_executor_accounting(result["raw"], "repair_execute",
                                                          self.snapshot(result["before"]), self.snapshot(result["after"]))
                           or repairable_substantial_accounting(result["raw"], "repair_execute")
                           or repairable_repair_mode(result["raw"], "repair_execute")
                           or repairable_enum(result["raw"], "repair_execute"))
        except (OSError, ValueError, KeyError, TypeError):
            return None
        return intent if correctable is not None else None

    def saved_repair_test(self, pair):
        """Read-only discovery; callers may replay only this exact completed result."""
        if not pair or pair.get("step") != "repair" or pair["repair"]["step"] != "test":
            return None
        gate = pair["repair"]
        pending = self.state.get("pending") or {}
        identity = pending.get("id") if pending.get("role") == "repair_execute" else gate.get("test_invocation")
        if not identity and (self.state.get("last") or {}).get("role") == "repair_execute":
            identity = Path(self.state["last"]["report"]).parent.name
        if identity:
            return self.read_saved_repair_test(pair, identity)
        if pending:
            return None
        # Legacy recovery can overwrite `last` with the healer. Discover only a
        # unique original test result with the same snapshot and assignments.
        matches = []
        for directory in (self.store.directory / "invocations").iterdir():
            if directory.is_dir():
                saved = self.read_saved_repair_test(pair, directory.name)
                if saved:
                    matches.append(saved)
                    if len(matches) > 1:
                        return None
        return matches[0] if matches else None

    def read_saved_repair_test(self, pair, identity):
        gate = pair["repair"]
        if not identity or identity in gate.get("consumed_tests", []) or Path(identity).name != identity:
            return None
        directory = self.store.directory / "invocations" / identity
        if not directory.resolve().is_relative_to(self.store.directory.resolve()):
            return None
        try:
            intent = json.loads((directory / "intent.json").read_text(encoding="utf-8"))
            if (intent.get("id") != identity or intent.get("role") != "repair_execute"
                    or intent.get("iteration") != self.state["iteration"]
                    or intent.get("correction_revision") != self.state.get("correction_revision")
                    or intent.get("restart_reviews") or self.snapshot(intent["before"]) != gate["snapshot"]):
                return None
            result = self.executor_result_candidate(directory, intent)
            report = self.executor_candidate_report(intent, result)
            if (self.snapshot(result["before"]) != gate["snapshot"]
                    or self.snapshot(result["after"]) != self.snapshot() or report["status"] != "done"
                    or report["repair"]["tests"]["status"] == "deferred"):
                return None
            before, after = self.snapshot(result["before"]), self.snapshot(result["after"])
            # The test step can never accept a test run that changed more than existing documentation,
            # or one whose final report claims fixes or substantial impact. Such a run is not replayed,
            # so recovery reviews the changed candidate again. Unchanged work replays: invoke()
            # corrects its counters or replays a failed correction.
            if before != after and not self.evidence_eligible(before, after):
                return None  # No counter correction can make this edit acceptable.
            if before != after and (not intent.get("report_repair") or "report_repair" in result):
                try:
                    final = parse_report(result["raw"], "repair_execute")
                except Blocked:
                    final = None  # An invalid report keeps its own correction or replay path.
                if final and (final["substantial"] or final["implementation_fixes"] or final["other_fixes"]):
                    return None
            if self.messages.unresolved(self.state["iteration"]):
                return None
            accepted = [m["identity"]["id"] for m in self.messages.accepted(self.state["iteration"], identity)]
            if result.get("operator_messages", []) != accepted:
                return None
            if "repair_binding" in intent:
                if intent["repair_binding"] != self.repair_binding(pair):
                    return None
            else:
                # Profile-8 reports predate the explicit binding. Require their
                # saved executor prompt, never the healer's diagnosis or summary.
                prompt = (directory / "prompt.txt").read_text(encoding="utf-8")
                context = json.JSONDecoder().raw_decode(prompt.split("Executor assignment:\n", 1)[1])[0]
                if (context.get("operation") != "test" or context.get("phase") != pair["phase"]
                        or context.get("candidate") != digest(encode(gate["snapshot"]))
                        or context.get("assignments") != gate["accepted"] or context.get("clean_passes") != 2):
                    return None
            return intent, result
        except (OSError, ValueError, KeyError, IndexError, TypeError, Blocked):
            return None

    def repair_evidence_hash(self, gate, candidate, stop=None):
        """Follow only sealed, exact full-snapshot equivalences; no file filtering."""
        for reference in reversed(gate.get("evidence_changes", [])):
            if candidate == stop:
                break
            bridge = self.validate_evidence_bridge(reference)
            if bridge["after"] != candidate:
                continue
            candidate = bridge["before"]
        return candidate

    def validate_evidence_bridge(self, reference):
        bridge = read_record(self.store, reference)
        audit = read_record(self.store, bridge["audit"])["evidence_delta"]
        receipt = read_record(self.store, bridge["receipt"])
        paths = self.changes(receipt["before"], receipt["after"])
        if (audit["before"] != bridge["before"] or audit["after"] != bridge["after"]
                or digest(encode(receipt["before"])) != bridge["before"] or digest(encode(receipt["after"])) != bridge["after"]
                or len(audit["files"]) != len(paths) or {r["path"] for r in audit["files"]} != set(paths)
                or any(r["verdict"] != "evidence_only" for r in audit["files"])):
            raise Blocked("repair-evidence", "The evidence audit no longer certifies this exact candidate delta.")
        return bridge

    def repair_clean_matches(self, gate, snapshot):
        return self.repair_evidence_hash(gate, digest(encode(snapshot)), gate["clean_candidate"]) == gate["clean_candidate"]

    def evidence_base(self, pair, before, paths, identity):
        """Recover byte-exact pre-test documentation from frozen views, not Git HEAD."""
        gate = pair["repair"]
        candidates = []
        if gate.get("test_view"):
            candidates.append(read_record(self.store, gate["test_view"]))
        # Legacy interrupted tests did not retain the second pass's view pointer.
        # Candidate hash and EACH original document fingerprint authenticate bytes.
        for path in (self.store.directory / "pair-reviews" / str(self.state["iteration"])).glob("*/view-*/view.json"):
            try:
                value = json.loads(path.read_text(encoding="utf-8"))
                if value.get("candidate") == digest(encode(before)):
                    candidates.append(value)
            except (OSError, ValueError):
                continue
        data = {}
        for name in paths:
            for view in candidates:
                if view.get("candidate") != digest(encode(before)):
                    continue
                if not isinstance(view.get("root"), str):
                    continue
                source = Path(view["root"]) / name
                if source.is_symlink() or not source.resolve().is_relative_to(self.store.directory.resolve()):
                    continue
                try:
                    content = read_source(view, name)
                    if "f:" + digest(content) != before["files"][name]:
                        continue
                    if b"\0" in content:
                        continue
                    content.decode("utf-8")
                    data[name] = content
                    break
                except (OSError, ValueError, KeyError):
                    continue
            if name not in data:
                raise Blocked("repair-evidence", "No exact frozen pre-test document is available: " + name)
        base = f"pair-reviews/{self.state['iteration']}/{pair['id']}/evidence-{identity}"
        root = self.store.directory / base / "before"
        writer = SnapshotWriter(root)
        try:
            for name, content in data.items():
                writer.write(name, content)
            writer.finish()
        finally:
            writer.close()
        return artifact(self.store, base + "/before.json", {"root": str(root), "storage": "zip", "candidate": digest(encode(before)),
            "files": {n: digest(v) for n, v in data.items()}, "diffs": {}, "stage_paths": paths, "phase": pair["phase"]})

    def evidence_eligible(self, before, after):
        """Narrow eligibility is only a prefilter. Behavioral Markdown and expected
        text output still require an explicit negative/uncertain audit verdict."""
        paths = self.changes(before, after)
        return bool(paths) and dict(before, files={}) == dict(after, files={}) and all(
            Path(n).suffix.lower() in (".md", ".rst", ".txt", ".adoc")
            and before["files"].get(n, "").startswith("f:")
            and after["files"].get(n, "").startswith("f:") for n in paths)

    def queue_repair_evidence(self, pair, report, before, after, invocation):
        paths = self.changes(before, after)
        if not self.evidence_eligible(before, after):
            raise Blocked("repair-test-edit", "Tests changed the candidate; only existing historical documentation can receive an evidence audit.")
        for name in paths:
            try:
                content = (self.repo.root / name).read_bytes()
                content.decode("utf-8")
                if b"\0" in content or "f:" + digest(content) != after["files"][name]:
                    raise ValueError("not the recorded text")
            except (OSError, ValueError) as error:
                raise Blocked("repair-test-edit", "Evidence classification requires the exact UTF-8 text after tests: " + name) from error
        identity = uuid.uuid4().hex
        base = self.evidence_base(pair, before, paths, identity)
        receipt = artifact(self.store, f"pair-reviews/{self.state['iteration']}/{pair['id']}/evidence-{identity}/receipt.json",
                           {"report": report, "before": before, "after": after, "invocation": invocation})
        pair["repair"].update(step="evidence", test_receipt=receipt,
            evidence_reader={"id": identity, "phase": pair["phase"], "snapshot": after, "round": 1, "step": "audit",
                "jobs": {}, "roles": ["repair_evidence"], "repair_base": base, "repair_snapshot": before,
                "repair_context": {"scope": 'Inspect only the exact documentation changes from the test invocation. Keep all static review credit until classification.'},
                **self.pair_instruction_record(pair)})
        self.state["pending"] = None
        self.save()

    def repair_evidence_step(self, pair):
        gate = pair["repair"]
        receipt = read_record(self.store, gate["test_receipt"])
        if self.snapshot() != receipt["after"]:
            raise Blocked("repair-evidence-drift", "Files, HEAD or index changed after the saved tests; the evidence audit cannot adopt later edits.")
        reader = gate["evidence_reader"]
        assignment = {"mode": "test_evidence_delta", "before": digest(encode(receipt["before"])),
            "after": digest(encode(receipt["after"])), "paths": self.changes(receipt["before"], receipt["after"]),
            "completed_report": receipt["report"],
            "rule": (
                'Inspect EVERY changed hunk with focus_inspect diff/read. Only factual historical '
                'records of these completed checks are evidence_only. Changes to behavior in source or'
                ' documentation are behavioral. Changes to requirements, instructions, permissions, '
                'acceptance rules, test oracles, expected outputs, or future obligations are also '
                'behavioral. Conflicting claims or claims without evidence are uncertain. No filename,'
                ' minor_edits count, or author claim grants an exception.\n\nDo not build, test, or '
                'write files. Return done with one verdict per changed path and exact before/after '
                'candidate hashes. This also applies to negative verdicts.'
            )}
        reports = self.pair_call(reader, [("evidence", "repair_evidence", assignment)])
        if reports is None:
            return
        audit = reports[0]["evidence_delta"]
        if (audit["before"] != assignment["before"] or audit["after"] != assignment["after"]
                or len(audit["files"]) != len(assignment["paths"])
                or {r["path"] for r in audit["files"]} != set(assignment["paths"])):
            self.reject_pair_report(reader, "evidence", Blocked("repair-evidence", "Audit must cover every exact changed path and candidate."))
            return
        if any(r["verdict"] != "evidence_only" for r in audit["files"]):
            raise Blocked("repair-test-edit", "Test-time documentation is behavioral or uncertain; no evidence exception granted.")
        reference = artifact(self.store, f"pair-reviews/{self.state['iteration']}/{pair['id']}/evidence-{reader['id']}/approval.json",
            {"before": audit["before"], "after": audit["after"], "audit": reader["jobs"]["evidence"]["result"], "receipt": gate["test_receipt"],
             **self.earlier_views(reader)})
        gate.setdefault("evidence_changes", []).append(reference)
        gate["test_view"] = reader["view"]
        self.accept_repair_result(pair, receipt["report"], receipt["before"], receipt["after"],
                                  testing=True, invocation=receipt["invocation"], evidence_approval=reference)

    def verified_fix_resolution(self, gate, resolution):
        for ref in reversed(gate["executions"]):
            record = read_record(self.store, ref)
            if record["operation"] != "fix":
                continue
            previous = next((r for r in record["report"]["resolutions"] if r["source_id"] == resolution["source_id"]), None)
            if previous:
                if previous["outcome"] != "fixed":
                    break
                return dict(resolution, outcome="fixed", resolution=previous["resolution"] + "\nVerified afterwards: " + resolution["resolution"],
                            evidence=list(dict.fromkeys([*previous["evidence"], *resolution["evidence"]])))
        raise Blocked("repair-closure", "Verification cannot replace a missing or disputed earlier fix for this assignment.")
