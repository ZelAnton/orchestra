"""Fixed pair identities; independent of runtime and report modules."""

PAIRS = {"pair_a": ("pair_opus", "pair_sol"),
         "pair_b": ("pair_astra", "pair_opus_max"),
         "final": ("pair_final_opus", "pair_final_fable")}
REPAIR_SCANNERS = ("repair_self", "repair_opus", "repair_astra")
PAIR_SCANNERS = (*tuple(role for roles in PAIRS.values() for role in roles), *REPAIR_SCANNERS)
PAIR_DISCUSSERS = tuple(role + "_discuss" for role in PAIR_SCANNERS)
PAIR_READONLY = (*PAIR_SCANNERS, *PAIR_DISCUSSERS, "pair_arbiter", "pair_complexity", "repair_evidence")
PAIR_WRITERS = ("pair_fix", "pair_cleanup", "pair_fix_high", "pair_cleanup_high", "repair_execute")
PAIR_ROLES = (*PAIR_READONLY, *PAIR_WRITERS)


def significant(decision):
    """Severity and required verification are independent of repair complexity."""
    return decision["blocking"] or decision["severity"] in ("critical", "high", "medium")


def pair_nodes(state):
    """Outer and active inner readers share retry/control ownership."""
    pair = state.get("pair_review")
    if pair:
        yield pair
        reader = (pair.get("repair") or {}).get("reader")
        if reader:
            yield reader
        auditor = (pair.get("repair") or {}).get("evidence_reader")
        if auditor:
            yield auditor
