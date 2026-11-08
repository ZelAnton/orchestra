"""Versioned, read-only pair reports and binding autonomous arbitration."""

import json

from cycle_state import Blocked, digest, encode
from focus_review import DETAILS, TEXT, object_schema, validate_shape

from focus_pair_profile import PAIRS, PAIR_SCANNERS, PAIR_DISCUSSERS, PAIR_READONLY, PAIR_WRITERS, PAIR_ROLES, significant

ISSUE = object_schema({"id": TEXT, **DETAILS, "kind": {"type": "string", "enum": ["defect", "verification"]}})
DECISION = object_schema({"source_id": TEXT, **DETAILS,
    "action": {"type": "string", "enum": ["fix", "reject", "duplicate", "verify", "defer"]},
    "duplicate_of": {"type": ["string", "null"]}, "blocking": {"type": "boolean"},
    "reason": TEXT, "repair": TEXT, "check": TEXT, "full_suite": {"type": "boolean"}})
RESOLUTION = object_schema({"source_id": TEXT,
    "outcome": {"type": "string", "enum": ["fixed", "verified", "disputed", "deferred"]},
    "resolution": TEXT, "evidence": {"type": "array", "minItems": 1, "items": TEXT}})
HANDOFF = object_schema({"decisions": {"type": "array", "items": TEXT},
                        "assumptions": {"type": "array", "items": TEXT},
                        "checks": {"type": "array", "items": TEXT}})
EFFORT = {"type": "string", "enum": ["high", "xhigh"]}
COMPLEXITY = object_schema({"assignment_sha256": TEXT, "effort": EFFORT, "reason": TEXT,
    "assignments": {"type": "array", "minItems": 1, "items": object_schema({
        "source_id": TEXT, "effort": EFFORT, "reason": TEXT})}})
REPAIR = object_schema({
    "mode": {"type": "string", "enum": ["self", "pair"]}, "reason": TEXT,
    "risks": {"type": "array", "items": {"type": "string", "enum": [
        "contracts", "storage", "security", "concurrency", "cross_component", "algorithm", "uncertainty"]}},
    "tests": object_schema({"status": {"type": "string", "enum": ["deferred", "passed", "not_needed", "failed", "infrastructure"]},
        "reason": TEXT, "evidence": {"type": "array", "items": TEXT},
        "failures": {"type": "array", "items": ISSUE}})})
# A final-pair inspector requests the optional full run before publication.
FINAL_GATE = object_schema({"full_run": {"type": "boolean"}, "reason": TEXT})
EVIDENCE_DELTA = object_schema({"before": TEXT, "after": TEXT,
    "files": {"type": "array", "minItems": 1, "items": object_schema({"path": TEXT,
        "verdict": {"type": "string", "enum": ["evidence_only", "behavioral", "uncertain"]},
        "reason": TEXT, "evidence": {"type": "array", "minItems": 1, "items": TEXT}})}})


def extend_schema(schema, role):
    extra = {}
    if role in PAIR_SCANNERS:
        extra = {"findings": {"type": "array", "items": ISSUE}}
        if role in PAIRS["final"]:
            extra["final_gate"] = FINAL_GATE
    elif role == "pair_complexity":
        extra = {"complexity": COMPLEXITY}
    elif role == "repair_evidence":
        extra = {"evidence_delta": EVIDENCE_DELTA}
    elif role in PAIR_DISCUSSERS or role == "pair_arbiter":
        extra = {"assessments": {"type": "array", "items": DECISION},
                 "new_findings": {"type": "array", "items": ISSUE},
                 "consensus": {"type": ["string", "null"]},
                 "impact": {"type": "string", "enum": ["minor", "substantial"]}}
    elif role in PAIR_WRITERS:
        extra = {"resolutions": {"type": "array", "items": RESOLUTION}, "handoff": HANDOFF}
        if role == "repair_execute":
            import copy
            extra = copy.deepcopy(extra)
            extra["repair"] = REPAIR
    schema["properties"].update(extra)
    schema["required"].extend(extra)
    return schema


def validate_report(report, role):
    schema = extend_schema({"properties": {}, "required": []}, role)
    for key, child in schema["properties"].items():
        if key == "final_gate" and key not in report:
            continue  # A report saved before this field requests no final gate.
        validate_shape(report[key], child)
    if role in PAIR_READONLY and (report["substantial"] or any(report[k] for k in
            ("implementation_fixes", "other_fixes", "minor_edits"))):
        raise ValueError("pair inspectors, assessor and arbiter cannot edit, build or test")
    collections = [(field, identity, report.get(field, [])) for field, identity in
                   (("findings", "id"), ("new_findings", "id"), ("assessments", "source_id"), ("resolutions", "source_id"))]
    collections.append(("test failures", "id", report.get("repair", {}).get("tests", {}).get("failures", [])))
    for field, identity, rows in collections:
        if len({r[identity] for r in rows}) != len(rows):
            raise ValueError("duplicate " + field + " identity")
        for row in rows:
            for loc in row.get("locations", []):
                from pathlib import PurePosixPath
                p = PurePosixPath(loc["path"])
                if p.is_absolute() or ".." in p.parts or "\\" in loc["path"] or ":" in loc["path"]:
                    raise ValueError("locations must be project-relative")
    if role in PAIR_DISCUSSERS or role == "pair_arbiter":
        if report["consensus"] is not None and (report["assessments"] or report["new_findings"]):
            raise ValueError("endorsement cannot also propose changes. "
                             "To disagree, set consensus to null and assess every supplied source_id.")
        if role == "pair_arbiter" and report["consensus"] is not None:
            raise ValueError("The arbiter cannot endorse a proposal. Set consensus to null and decide every supplied source_id.")
    if role == "repair_execute":
        repair = report["repair"]
        if repair["risks"] and repair["mode"] != "pair":
            raise ValueError("risky or uncertain repairs require pair review")
        tests = repair["tests"]
        if tests["status"] == "infrastructure":
            if any(r["kind"] != "verification" for r in tests["failures"]):
                raise ValueError("infrastructure may record verification obstacles, never candidate defects")
        elif (tests["status"] == "failed") != bool(tests["failures"]):
            raise ValueError("test defects require concrete failures, other test statuses cannot hide defects")
        if tests["status"] == "failed" and any(r["kind"] != "defect" for r in tests["failures"]):
            raise ValueError("failed tests must identify defects, not merely scheduled verification")
        if tests["status"] in ("passed", "not_needed") and not tests["evidence"]:
            raise ValueError("test completion requires actual evidence or a justified applicability assessment")


def validate_decisions(issues, decisions, phase, full_run_used=False):
    by_id = {row["source_id"]: row for row in decisions}
    if set(by_id) != {row["source_id"] for row in issues} or len(by_id) != len(decisions):
        raise Blocked("pair-coverage", "Every finding requires exactly one disposition; no omission is accepted.")
    for row in decisions:
        if row["action"] == "defer" and significant(row):
            raise Blocked("pair-decision", "Significant findings cannot be deferred to bypass repair and re-review.")
        if row["action"] not in ("fix", "verify") and row["blocking"]:
            raise Blocked("pair-decision", "Only a defect or required verification may block publication.")
        if (row["action"] == "duplicate") != (row["duplicate_of"] is not None):
            raise Blocked("pair-decision", "Duplicate requires exactly one reference.")
        if row["action"] == "duplicate" and (row["duplicate_of"] not in by_id or
                by_id[row["duplicate_of"]]["action"] not in ("fix", "verify", "defer")):
            raise Blocked("pair-decision", "A duplicate must identify a retained finding.")
        if row["action"] == "duplicate" and significant(row) and not significant(by_id[row["duplicate_of"]]):
            raise Blocked("pair-decision", "A significant duplicate must retain significance in its canonical finding.")
        if row["full_suite"] and (phase != "pair_b" or row["action"] not in ("fix", "verify")):
            raise Blocked("pair-verification", "Only a Pair B fix or verify assignment can set full_suite=true. Set full_suite to false.")
        if row["full_suite"] and full_run_used:
            raise Blocked("pair-verification", "Pair B already used its one full run for this stage. Set full_suite to false. Assign targeted checks.")
    return decisions


# Older runtimes stored this correction text. It asked readers to name the impact in consensus.
LEGACY_CONSENSUS_ERROR = "Endorsement must name the exact candidate proposal and its impact."
# Older runtimes refused every new arbiter finding with this parser error. The registry now takes them.
LEGACY_ARBITER_ERROR = "Provider final report is invalid: arbiter must decide the complete supplied registry"


def consensus_error(proposal_hash, impact):
    """Tell a discussion reader the exact endorsement values, or to disagree when no proposal exists."""
    if not proposal_hash:
        return "No proposal is supplied in this exchange. Set consensus to null. Assess every supplied source_id."
    return (f"An endorsement must set consensus to exactly {json.dumps(proposal_hash)} with no other text. "
            f"Its impact must be {json.dumps(impact)}. "
            "Put reasons in summary or description. To disagree, set consensus to null.")


def proposal_key(decisions, impact, candidate):
    # Prose remains in the proposed document and requires explicit endorsement.
    return digest(encode({"candidate": candidate, "decisions": sorted(decisions, key=lambda r: r["source_id"]), "impact": impact}))


def assignment_key(snapshot, tasks):
    return digest(encode({"candidate": snapshot, "tasks": sorted(tasks, key=lambda r: r["source_id"])}))


def validate_complexity(assessment, snapshot, tasks):
    if assessment["assignment_sha256"] != assignment_key(snapshot, tasks):
        raise Blocked("pair-complexity", "Complexity assessment belongs to another candidate or assignment.")
    rows = assessment["assignments"]
    if len(rows) != len(tasks) or {r["source_id"] for r in rows} != {t["source_id"] for t in tasks}:
        raise Blocked("pair-complexity", "Complexity must cover every accepted assignment exactly once.")
    required = "xhigh" if any(r["effort"] == "xhigh" for r in rows) else "high"
    if assessment["effort"] != required:
        raise Blocked("pair-complexity", "Batch effort must match its most complex assignment.")
    return assessment
