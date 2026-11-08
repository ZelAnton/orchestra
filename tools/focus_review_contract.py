"""Existing-implementation review contracts. Normal development prompts stay unchanged."""

from cycle_state import Blocked
from focus_pair_profile import PAIRS


SCANNERS = tuple(role for roles in PAIRS.values() for role in roles)
CONTRACT = """Review the existing implementation of the supplied review_scope.
The scope contains completed plan items or an explicit operator request.
Review their current requirements, behavior, dependencies, and integration scenarios.
The repair diff contains only corrections made during this review run.
An empty repair diff does not mean that inspection is complete.
Do not select another plan item or start an implementation phase.

Read the selected requirements and the necessary source, tests, and contracts.
Keep the focus on the supplied scope.
Correct missing promised behavior through accepted findings and the normal repair loop.
Keep unrelated improvements separate.
Do not change protected work or expand explicit operator exclusions.
Record checks and findings in the report, without writing project journals.

During an outer independent inspection, return coverage for each supplied coverage ID.
Record inspected paths and specific checks in coverage.
Include relevant dependencies in those paths.
List limitations honestly. Static inspection does not prove that tests passed.

Report missing required verification as a finding with kind=verification.
Return blocked if the required inspection cannot be completed.
The existing pair, arbitration, repair, and test rules still apply.
For the test scope rules, the supplied review_scope counts as the current changes.
"""


def review_contract(text, enabled):
    if not enabled:
        return text
    text = text.replace("Review only the stage diff and necessary surrounding source across all listed repositories.",
                        "Review the supplied existing-implementation scope and necessary surrounding source.")
    return text + "\n\n" + CONTRACT


def coverage_schema():
    from focus_review import TEXT, object_schema
    return {"type": "array", "minItems": 1, "items": object_schema({
        "id": TEXT, "paths": {"type": "array", "items": TEXT},
        "checks": {"type": "array", "minItems": 1, "items": TEXT},
        "limitations": {"type": "array", "items": TEXT}})}


def validate_coverage(report, scope, files):
    from focus_review import validate_shape
    try:
        rows = report["coverage"]
        validate_shape(rows, coverage_schema())
        ids = [row["id"] for row in rows]
        if len(ids) != len(set(ids)) or set(ids) != set(scope["coverage_ids"]):
            raise ValueError("Each selected requirement needs exactly one coverage entry")
        if any(len(row["paths"]) != len(set(row["paths"])) for row in rows):
            raise ValueError("Each coverage entry lists a path only once")
        if report.get("status") == "done" and any(not row["paths"] for row in rows):
            raise ValueError("Completed inspection requires source paths for each requirement")
        if any(name not in files or name.startswith("__review__/") for row in rows for name in row["paths"]):
            raise ValueError("Coverage paths must identify source or requirement files in this snapshot")
    except (ValueError, TypeError, KeyError) as error:
        raise Blocked("review-coverage", str(error)) from error
