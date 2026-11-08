"""Operator selection before ownership or provider startup."""

import json
from pathlib import Path

from cycle_state import Blocked
from focus_output import terminal_text
from focus_review_scope import load_request, make_request, plan_index, save_request, select, verify_plan


def arguments(parser):
    parser.add_argument("--review-run", help="Address a saved review run for status, control, or corrections.")
    parser.add_argument("--plan", type=Path, help="With review: Markdown plan inside the project.")
    parser.add_argument("--stages", action="append", default=[], help="With review: IDs or inclusive document-order ranges, separated by commas.")
    parser.add_argument("--section", action="append", default=[], help="With review: completed descendants of this ID.")
    parser.add_argument("--completed", action="store_true", help="With review: select all completed leaf items.")
    parser.add_argument("--scope", help="With review: additional scope or a standalone review request.")
    parser.add_argument("--scope-file", type=Path, nargs="+", action="extend", default=[],
                        help="With review: read a UTF-8 scope, at most 64 KiB. Several files give one target for each file, in this order.")
    parser.add_argument("--selection-file", type=Path, help="With review: load a saved selection.")
    parser.add_argument("--save-selection", type=Path, help="With review: save the exact selection to a new file.")
    parser.add_argument("--integration", action="store_true", help="With review: review the selected items together.")
    parser.add_argument("--pick", action="store_true", help="With review: select completed items in a keyboard menu.")
    parser.add_argument("--preview", action="store_true", help="With review: display scope without starting a run.")
    parser.add_argument("--resume", help="With review: resume this saved review run ID.")
    parser.add_argument("--list", action="store_true", help="With review: list saved review runs.")
    parser.add_argument("--install-ui", action="store_true", help="With review: install pinned optional menu dependencies in a user virtual environment.")


def validate(parser, args):
    selection = bool(args.plan or args.stages or args.section or args.completed or args.scope is not None
                     or args.scope_file or args.selection_file or args.save_selection or args.integration or args.pick or args.preview)
    if args.command != "review" and (selection or args.resume or args.list or args.install_ui):
        parser.error("Review selection options require the review command")
    if args.command == "review":
        if sum(bool(x) for x in (args.resume, args.list, args.install_ui)) > 1 or selection and (args.resume or args.list or args.install_ui):
            parser.error("Select a new review, resume a run, list runs, or install the menu separately")
        if args.review_run:
            parser.error("Use review --resume ID, not --review-run")
        if not args.resume and (args.retry or args.new_sessions):
            parser.error("Review retries and session replacement require --resume RUN_ID")
        if args.scope is not None and args.scope_file:
            parser.error("Use --scope or --scope-file")
        if len(args.scope_file) > 1 and (args.plan or args.stages or args.section or args.completed or args.integration or args.pick):
            parser.error("Several scope files are separate targets. Do not combine them with plan items, --integration, or --pick")
        if len({path.resolve() for path in args.scope_file}) != len(args.scope_file):
            parser.error("Give each scope file one time")
        if args.selection_file and (args.plan or args.stages or args.section or args.completed or args.scope or args.scope_file or args.integration or args.pick):
            parser.error("A saved selection cannot be combined with new selection options")
        if (args.stages or args.section or args.completed or args.pick) and not args.plan:
            parser.error("Item selection requires --plan")
    if args.handoff and (args.command == "review" or args.review_run):
        parser.error("A review run uses its saved scope, not a development handoff")
    if args.review_run and args.command in ("recover", "reconcile"):
        parser.error("Use correct --review-run ID for review campaigns; coding/publication recovery imports are not supported")


def prepare(root, args):
    if args.selection_file:
        request = load_request(args.selection_file)
        verify_plan(root, request)
    else:
        index = plan_index(root, args.plan) if args.plan else None
        selected, excluded = select(index, args.stages, args.section) if index else ([], [])
        if args.completed:
            selected = [r["id"] for r in index["items"] if r["completed"] and not r["children"]]
        scope = args.scope or ""
        scopes = []
        for path in args.scope_file:
            if path.stat().st_size > 65536:
                raise Blocked("review-scope", f"Scope file exceeds 64 KiB: {path}")
            scopes.append(path.read_text(encoding="utf-8-sig"))
        if len(scopes) == 1:
            scope, scopes = scopes[0], []
        if args.pick:
            from focus_picker import pick
            result = pick(index, selected, scope, args.integration)
            if result is None:
                return None
            selected, scope, integration = result
        else:
            integration = args.integration
        request = make_request(index, selected, scope, integration, excluded, scopes=scopes)
    if args.save_selection:
        destination = args.save_selection.resolve()
        if destination.is_relative_to(Path(root).resolve()) and (
                destination.parent != Path(root).resolve() / ".work/cycle/selections" or destination.suffix != ".json"):
            raise Blocked("review-selection-path", "Save selection JSON directly in .work/cycle/selections or outside the project.")
        save_request(args.save_selection, request)
    preview = {"plan": request["plan"], "mode": "integration" if request["integration"] else "separate targets",
        "targets": [{"id": target["id"], "title": target["title"], "items": [row["id"] for row in target["items"]],
                     "scope": target["scope"]} for target in request["targets"]], "excluded": request["excluded"]}
    print(terminal_text(json.dumps(preview, ensure_ascii=False, indent=2)), flush=True)
    return request
