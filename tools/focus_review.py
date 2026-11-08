"""Final serial inspection, triage and repair. Only the runtime writes findings."""

import copy
import json
from pathlib import PurePosixPath

from cycle_prompts import FINAL_SCANNERS, READONLY_REVIEW_ROLES, REPORT_SCHEMA
from cycle_state import Blocked, digest, encode


def object_schema(properties):
    return {"type": "object", "properties": properties, "required": list(properties), "additionalProperties": False}


TEXT = {"type": "string", "minLength": 1}
LOCATION = object_schema({"path": TEXT, "line": {"type": "integer", "minimum": 1}})
DETAILS = {"title": TEXT, "body": TEXT,
           "severity": {"type": "string", "enum": ["critical", "high", "medium", "low"]},
           "locations": {"type": "array", "minItems": 1, "maxItems": 20, "items": LOCATION}}
FINDING = object_schema({"id": TEXT, **DETAILS})
ASSESSMENT = object_schema({"source_id": TEXT, "verdict": {"type": "string", "enum": ["confirmed", "rejected", "duplicate"]},
                            "duplicate_of": {"type": ["string", "null"]}, "blocking": {"type": "boolean"},
                            "reason": TEXT, **DETAILS})
RESOLUTION = object_schema({"source_id": TEXT, "resolution": TEXT,
                            "evidence": {"type": "array", "minItems": 1, "items": TEXT}})


def report_schema(role, existing_review=False):
    schema = copy.deepcopy(REPORT_SCHEMA)
    if existing_review:
        from focus_review_contract import SCANNERS, coverage_schema
        if role in SCANNERS:
            schema["properties"]["coverage"] = coverage_schema()
            schema["required"].append("coverage")
    from focus_pair_profile import PAIR_ROLES
    if role in PAIR_ROLES:
        from focus_pair_protocol import extend_schema
        return extend_schema(schema, role)
    if role in READONLY_REVIEW_ROLES:
        name, item = ("assessments", ASSESSMENT) if role == "final_triage" else ("findings", FINDING)
        schema["properties"][name] = {"type": "array", "items": item}
        schema["required"].append(name)
    elif role == "final_cleanup":
        schema["properties"]["resolutions"] = {"type": "array", "items": RESOLUTION}
        schema["required"].append("resolutions")
    from focus_pair_protocol import extend_schema
    return extend_schema(schema, role)


def validate_shape(value, schema):
    """Small strict validator for the final-review extension, including cached reports."""
    kind = schema.get("type")
    if isinstance(kind, list):
        if value is None and "null" in kind:
            return
        kind = next(k for k in kind if k != "null")
    if kind == "object":
        if not isinstance(value, dict) or set(value) != set(schema["properties"]):
            raise ValueError("missing or unknown finding fields")
        for key, child in schema["properties"].items():
            validate_shape(value[key], child)
    elif kind == "array":
        if not isinstance(value, list) or not schema.get("minItems", 0) <= len(value) <= schema.get("maxItems", len(value)):
            raise ValueError("invalid finding array")
        for item in value:
            validate_shape(item, schema["items"])
    elif kind == "string":
        if not isinstance(value, str) or not value.strip() or len(value) > 32000:
            raise ValueError("invalid finding text")
    elif kind == "integer":
        if type(value) is not int or value < schema.get("minimum", 0):
            raise ValueError("invalid finding line")
    elif kind == "boolean" and type(value) is not bool:
        raise ValueError("invalid finding blocking flag")
    if "enum" in schema and value not in schema["enum"]:
        raise ValueError("invalid finding enum")


def validate_findings(report, role):
    from focus_pair_profile import PAIR_ROLES
    if role in PAIR_ROLES:
        from focus_pair_protocol import validate_report
        return validate_report(report, role)
    if role == "final_cleanup":
        rows = report["resolutions"]
        validate_shape(rows, report_schema(role)["properties"]["resolutions"])
        if len({row["source_id"] for row in rows}) != len(rows):
            raise ValueError("duplicate resolution identity")
        return
    if role not in READONLY_REVIEW_ROLES:
        return
    if report["substantial"] or any(report[k] for k in ("implementation_fixes", "other_fixes", "minor_edits")):
        raise ValueError("read-only reviewers cannot claim edits or fixes")
    field, identity = ("assessments", "source_id") if role == "final_triage" else ("findings", "id")
    rows = report[field]
    validate_shape(rows, report_schema(role)["properties"][field])
    if len({row[identity] for row in rows}) != len(rows):
        raise ValueError("duplicate finding identity")
    for row in rows:
        for location in row["locations"]:
            path = PurePosixPath(location["path"])
            if path.is_absolute() or ".." in path.parts or "\\" in location["path"] or ":" in location["path"]:
                raise ValueError("finding locations must be project-relative paths")
        if role == "final_triage" and row["verdict"] != "confirmed" and row["blocking"]:
            raise ValueError("only confirmed findings can block publication")
        if role == "final_triage" and (row["verdict"] == "duplicate") != (row["duplicate_of"] is not None):
            raise ValueError("duplicate verdict requires exactly one duplicate_of reference")


class FinalReview:
    """Mixed into Cycle to share invocation, containment and snapshot barriers."""

    def final_context(self, role):
        final = self.state.get("final_review") or {}
        context = {"round": final.get("round", 1), "step": final.get("step", FINAL_SCANNERS[0]),
                   "order": list(FINAL_SCANNERS), "completion": "one complete round without confirmed blockers",
                   "read_only": role in READONLY_REVIEW_ROLES}
        if final.get("diff"):
            record = final["diff"]
            path = self.store.directory / record["path"]
            try:
                valid = (path.resolve().is_relative_to(self.store.directory.resolve())
                         and digest(path.read_bytes()) == record["sha256"])
            except OSError:
                valid = False
            if not valid:
                raise Blocked("final-review-evidence", "The final round's stage diff changed or disappeared.")
            context["stage_diff"] = str(path)
            context["diff_instructions"] = (
                'Read this Git diff from the runtime baseline to the candidate, and the current stage_paths. Git diff excludes untracked files. Inspect every new stage file directly. During final repair, this diff describes the candidate before correction. Use current files for the repair.')
        if final.get("repair"):
            report = self.final_record(final["repair"])
            context["preceding_repair"] = {"summary": report["summary"],
                                           "report": str(self.store.directory / final["repair"]["path"])}
        if role == "final_triage":
            context["findings"] = self.final_sources(final)
        elif role in ("final_fix", "final_cleanup"):
            context["findings"] = self.confirmed_findings(final)
            if role == "final_cleanup":
                context["after_success"] = 'Publish the cleanup changes directly. Do not repeat reviews.'
        return context

    def validate_final_cleanup(self, final, report):
        findings = self.confirmed_findings(final)
        if not findings or any(row["blocking"] for row in findings):
            raise Blocked("final-review-route", "Final cleanup requires only confirmed nonblocking findings.")
        validate_findings(report, "final_cleanup")
        if {row["source_id"] for row in report["resolutions"]} != {row["source_id"] for row in findings}:
            raise Blocked("final-review-coverage", "Opus cleanup must close every confirmed nonblocking finding exactly once.")

    def record_final_backlog(self, final, snapshot):
        """Keep open findings until closure, and retain their sealed closure history."""
        entry = {"iteration": self.state["iteration"], "task": self.state.get("task"), "round": final["round"],
                 "candidate_sha256": digest(encode(snapshot)), "triage": final["triage"],
                 "findings": final["confirmed"]}
        if final.get("cleanup"):
            entry.update(findings=[], closed_findings=final["confirmed"], cleanup=final["cleanup"])
        backlog = [row for row in self.state.get("backlog", []) if row["iteration"] != self.state["iteration"]] + [entry]
        # Idempotent after a crash between artifact and state persistence.
        self.store.artifact("backlog.json", encode({"version": 1, "stages": backlog}))
        self.state["backlog"] = backlog

    def finish_final_review(self, final, after):
        self.record_final_backlog(final, after)
        # The operator explicitly permits publishing nonblocking cleanup without a
        # fresh review. Seal its actual result, not the pre-cleanup candidate.
        self.state.update(reviewed=after, phase="publish", coordinated=None)
        final["step"] = "done"

    def confirmed_findings(self, final):
        if "triage" not in final:
            raise Blocked("final-review-evidence", "Final repair has no completed triage record.")
        confirmed = [row for row in self.final_record(final["triage"])["assessments"] if row["verdict"] == "confirmed"]
        if confirmed != final.get("confirmed"):
            raise Blocked("final-review-evidence", "The saved findings differ from the completed triage record.")
        return confirmed

    def final_sources(self, final):
        rows = list(final.get("carried", []))
        for item in final.get("scans", []):
            rows.extend(dict(row, source_id=f"r{final['round']}:{item['role']}:{row['id']}")
                        for row in self.final_record(item)["findings"])
        return rows

    def final_record(self, record):
        path = self.store.directory / record["path"]
        try:
            data = path.read_bytes()
            if not path.resolve().is_relative_to(self.store.directory.resolve()) or digest(data) != record["sha256"]:
                raise ValueError("changed record")
            return json.loads(data)
        except (OSError, ValueError, KeyError) as error:
            raise Blocked("final-review-evidence", "Final review evidence changed or disappeared; work was preserved.") from error

    def save_final_record(self, final, role, report):
        relative = f"final-reviews/{self.state['iteration']}/{final['generation']}/round-{final['round']}/{role}.json"
        data = encode(report)
        self.store.artifact(relative, data)
        return {"role": role, "path": relative, "sha256": digest(data), "invocation": self.state["pending"]["id"],
                "findings": len(report.get("findings", []))}

    def prepare_final_diff(self, final):
        """Claude's read-only tool set needs a diff it can read without running Git."""
        if final.get("diff"):
            return
        paths = self.publication_paths()
        repositories = getattr(self.repo, "repositories", {"": self.repo})
        parts = []
        for member, repo in repositories.items():
            names = [path[len(member) + 1:] for path in paths if path.startswith(member + "/")] if member else paths
            baseline = self.state["baseline"]["head"]
            revision = baseline[member] if member else baseline
            parts.append(("Repository: " + (member or ".") + "\n").encode())
            for offset in range(0, len(names), 100):
                parts.append(repo.git("--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                                      revision, "--", *names[offset:offset + 100]).stdout)
        if self.snapshot(final["snapshot"]) != self.snapshot():
            raise Blocked("final-review-drift", "The candidate changed while preparing its stage diff.")
        data = b"\n".join(parts)
        relative = f"final-reviews/{self.state['iteration']}/{final['generation']}/round-{final['round']}/stage.diff"
        self.store.artifact(relative, data)
        final["diff"] = {"path": relative, "sha256": digest(data)}
        self.save()

    def final_review_step(self):
        import uuid
        state = self.state
        final = state.get("final_review")
        if final is None:
            carried = []
            for entry in state.get("backlog", []):
                if entry["iteration"] == state["iteration"]:
                    previous = self.final_record(entry["triage"])
                    if entry.get("cleanup"):
                        self.validate_final_cleanup({"triage": entry["triage"],
                            "confirmed": [row for row in previous["assessments"] if row["verdict"] == "confirmed"]},
                            self.final_record(entry["cleanup"]))
                        continue
                    carried = [dict(row, source_id="carried:" + digest(encode([entry["triage"]["sha256"], row["source_id"]])))
                               for row in previous["assessments"] if row["verdict"] == "confirmed"]
            final = {"generation": uuid.uuid4().hex, "round": 1, "step": FINAL_SCANNERS[0],
                     "snapshot": self.snapshot(), "scans": [], "carried": carried}
            state["final_review"] = final
            self.save()
        role = final["step"]
        if role not in (*READONLY_REVIEW_ROLES, "final_fix", "final_cleanup"):
            raise Blocked("final-review-route", "Unknown final review step; work was preserved.")
        # A fix may resume its own partial work; all inspections certify one exact candidate.
        if role in READONLY_REVIEW_ROLES and self.snapshot(final["snapshot"]) != self.snapshot():
            raise Blocked("final-review-drift", "The final round candidate changed between inspections; restart reviews before publication.")
        if role == "final_cleanup":
            findings = self.confirmed_findings(final)
            if not findings or any(row["blocking"] for row in findings):
                raise Blocked("final-review-route", "Final cleanup requires only confirmed nonblocking findings.")
        self.prepare_final_diff(final)
        report, before, after, _ = self.invoke(role)
        self.final_context(role)  # Recheck sealed inputs after provider execution too.
        if state["pending"].get("restart_reviews"):
            self.reset_reviews("Новое указание требует повторного ревью с Opus")
            self.complete_invocation()
            return
        if role in FINAL_SCANNERS:
            expected = list(FINAL_SCANNERS[:FINAL_SCANNERS.index(role)])
            if [item["role"] for item in final["scans"]] != expected:
                raise Blocked("final-review-route", "A scanner cannot skip another scanner in this round.")
            final["scans"].append(self.save_final_record(final, role, report))
            final["step"] = (*FINAL_SCANNERS, "final_triage")[FINAL_SCANNERS.index(role) + 1]
        elif role == "final_triage":
            if [item["role"] for item in final["scans"]] != list(FINAL_SCANNERS):
                raise Blocked("final-review-route", "Triage requires all three completed inspections.")
            sources = {row["source_id"]: row for row in self.final_sources(final)}
            assessments = {row["source_id"]: row for row in report["assessments"]}
            if set(sources) != set(assessments):
                raise Blocked("final-review-coverage", "Astra triage must assess every source finding exactly once.")
            for row in assessments.values():
                if row["verdict"] == "duplicate":
                    target = assessments.get(row["duplicate_of"])
                    if not target or target["verdict"] != "confirmed":
                        raise Blocked("final-review-coverage", "A duplicate must refer to a confirmed finding in this triage.")
            final["triage"] = self.save_final_record(final, role, report)
            final["confirmed"] = [row for row in assessments.values() if row["verdict"] == "confirmed"]
            if any(row["blocking"] for row in final["confirmed"]):
                final["step"] = "final_fix"
            elif final["confirmed"]:
                self.record_final_backlog(final, after)
                final["step"] = "final_cleanup"
            else:
                self.finish_final_review(final, after)
        elif role == "final_cleanup":
            self.validate_final_cleanup(final, report)
            final["cleanup"] = self.save_final_record(final, role, report)
            self.finish_final_review(final, after)
        else:
            if not any(row["blocking"] for row in self.confirmed_findings(final)):
                raise Blocked("final-review-route", "Final repair requires confirmed blocking findings.")
            final["fix"] = self.save_final_record(final, role, report)
            # Carry both blocker and nonblocker dispositions so triage must explicitly
            # verify resolution, even if the next scanners do not rediscover an issue.
            state["final_review"] = {"generation": final["generation"], "round": final["round"] + 1,
                                     "step": FINAL_SCANNERS[0], "snapshot": after, "scans": [],
                                     "carried": final["confirmed"], "repair": final["fix"]}
        self.complete_invocation()
