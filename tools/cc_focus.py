"""Entry point for cc-focus; Python 3.10+, standard-library core and an optional menu."""

import argparse
import contextlib
import hashlib
import json
from pathlib import Path
import sys
import time
import uuid

from cycle_prompts import REVIEW_ROLES, FINAL_ROLES
from cycle_state import Blocked, Lease, LocalLock, Repository, Store, encode
from cycle_transport import Transport
from cycle_workflow import Cycle, fresh_state
import focus_brief
from focus_control import Control, FocusStop, check_parked_provider, request_stop, request_stage_stop, status
from focus_progress import Progress
from focus_output import terminal_text
from focus_input import Interaction, PlainTerminal
from focus_messages import MessagePending, Messages
from focus_terminal import Terminal
from focus_status import review_event
from focus_project import Project, ProjectLease, check_project_owner, lock_members, open_project, project_owner_status, register_members
from focus_publication import ProjectCycle
from focus_review_run import ReviewCycle, ProjectReviewCycle, choose_store, create_run, hand_back, pending_run, runs


def runtime_fingerprint():
    root = Path(__file__).resolve().parent
    paths = sorted({root / "cc_focus.py", *root.glob("cycle_*.py"), *root.glob("focus_*.py")})
    try:
        return tuple((p.name, hashlib.sha256(p.read_bytes()).hexdigest()) for p in paths)
    except OSError:
        return None  # Missing/partially installed files also require a fresh process.


LOADED_RUNTIME = runtime_fingerprint()
RUNTIME_UPDATED = "Runtime обновлён на диске: /exit, затем новый запуск cc-focus --retry."


def runtime_changed():
    return LOADED_RUNTIME is None or runtime_fingerprint() != LOADED_RUNTIME


def resume_retries(state):
    """Tell if /resume retries a preserved blocker or a quota wait, also a wait of a pair participant."""
    if not state:
        return False
    from focus_pair_profile import pair_nodes
    participant_quota = any(job.get("status") == "waiting" and job.get("wait_reason") == "claude-quota" and not job.get("result")
                            for node in pair_nodes(state) for job in (node.get("jobs") or {}).values())
    return bool((state.get("blocker") or {}).get("status") == "blocked"
                or (state.get("pending") or {}).get("quota_wait") or participant_quota)


def main(argv=None, interaction=None, review_request=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(prog="cc-focus", description="Sequential main-branch Claude/Codex cycle with durable local sessions.")
    parser.add_argument("command", nargs="?", choices=("run", "review", "status", "diagnose", "stop", "finish-stage", "recover", "correct", "reconcile", "messages", "retry-message", "discard-message", "brief"), default="run")
    parser.add_argument("brief_action", nargs="?", metavar="ACTION", help="With brief: set FILE, restore FILE, clear, show, or apply.")
    parser.add_argument("brief_file", nargs="?", type=Path, metavar="FILE", help="With brief set or brief restore: the UTF-8 brief file.")
    parser.add_argument("--invocation", help="With diagnose: read public metadata for this invocation ID; no state or provider changes.")
    parser.add_argument("--public-output", action="store_true", help="With diagnose: display public messages and tool results instead of metadata.")
    parser.add_argument("--native-log", type=Path, help="With diagnose: inspect instruction and tool-schema metadata in this matching native Claude session log.")
    parser.add_argument("--refusals", action="store_true", help="With diagnose: correlate saved Claude refusals with sessions and instruction changes; no state or provider changes.")
    parser.add_argument("--handoff", type=Path, help="Import a UTF-8 handoff file (no session ID import).")
    parser.add_argument("--new-sessions", action="store_true", help="Start clean conversations, preserving work and phase progress.")
    parser.add_argument("--retry", action="store_true", help="Retry a preserved blocker or immediately recheck a saved Claude quota wait after changing accounts.")
    parser.add_argument("--now", action="store_true", help="With stop: interrupt now instead of waiting for a safe boundary.")
    parser.add_argument("--timeout", type=float, help="With stop: maximum wait in seconds; the stop request survives timeout.")
    parser.add_argument("--cancel", action="store_true", help="With finish-stage: cancel the scheduled pause without starting processing.")
    parser.add_argument("--review-from", type=Path, help="With recover: validate a saved coding result and pause before mandatory reviews; starts no model.")
    parser.add_argument("--output", choices=("live", "compact"), help="With run: live public messages/actions/results (default), or compact activity only.")
    parser.add_argument("--ui", choices=("auto", "on", "off"), help="With run: persistent terminal composer (auto on a capable TTY); off preserves plain output.")
    parser.add_argument("--id", help="With retry-message/discard-message: an unambiguous saved message ID.")
    correction = parser.add_mutually_exclusive_group()
    correction.add_argument("--message", help="With correct: save an operator correction for the stopped current stage.")
    correction.add_argument("--file", type=Path, help="With correct: import a UTF-8 correction file, at most 64 KiB.")
    reconciliation = parser.add_mutually_exclusive_group()
    parser.add_argument("--publication", action="store_true", help="With reconcile: explicitly accept a preserved already-pushed protected scope and restart all required reviews.")
    parser.add_argument("--publication-scope", type=Path, help="With reconcile: prepare an exact pre-publication file selection from JSON; accepts no changes.")
    reconciliation.add_argument("--plan-out", type=Path, help="With reconcile: write a reviewable handover plan to a new file; accept no changes yet.")
    reconciliation.add_argument("--apply-plan", type=Path, help="With reconcile: accept the exact plan and pause before its required coding or review continuation.")
    from focus_review_cli import arguments, validate, prepare
    arguments(parser)
    args = parser.parse_args(argv)
    validate(parser, args)
    if args.command == "brief":
        if args.brief_action not in ("set", "restore", "clear", "show", "apply"):
            parser.error("brief requires set FILE, restore FILE, clear, show, or apply")
        if (args.brief_action in ("set", "restore")) != (args.brief_file is not None):
            parser.error("brief set and brief restore require one FILE. The other brief actions take no file.")
        allowed = {"command", "brief_action", "brief_file", *(("review_run",) if args.brief_action in ("show", "apply") else ())}
        if any(value != parser.get_default(name) for name, value in vars(args).items() if name not in allowed):
            parser.error("brief accepts no other options. Only show and apply accept --review-run.")
    elif args.brief_action is not None or args.brief_file is not None:
        parser.error("Only the brief command accepts an action or a file argument")
    if (args.command == "diagnose") != bool(args.invocation or args.refusals) or args.public_output and args.command != "diagnose":
        parser.error("diagnose requires --invocation or --refusals; these options and --public-output are only valid with diagnose")
    if args.refusals and (args.invocation or args.public_output or args.native_log is not None):
        parser.error("--refusals cannot combine with --invocation, --public-output or --native-log")
    if args.native_log is not None and (args.command != "diagnose" or args.public_output):
        parser.error("--native-log requires diagnose and cannot combine with --public-output")
    if args.command != "stop" and (args.now or args.timeout is not None):
        parser.error("--now and --timeout require stop")
    if args.cancel and args.command != "finish-stage":
        parser.error("--cancel requires finish-stage")
    if args.timeout is not None and (not 0 < args.timeout < float("inf")):
        parser.error("--timeout must be a finite positive number")
    if args.command not in ("run", "review") and (args.handoff or args.new_sessions or args.retry or args.output or args.ui):
        parser.error("Only run or review accepts --new-sessions, --retry, --output or --ui; --handoff requires run")
    if (args.command == "recover") != bool(args.review_from):
        parser.error("recover requires --review-from; that option is only valid with recover")
    if (args.command == "correct") != (args.message is not None or args.file is not None):
        parser.error("correct requires --message or --file; those options are only valid with correct")
    if (args.command in ("retry-message", "discard-message")) != bool(args.id):
        parser.error("retry-message/discard-message require --id; that option is only valid with these commands")
    if args.command != "reconcile" and (args.plan_out or args.apply_plan or args.publication or args.publication_scope):
        parser.error("Reconciliation options require reconcile")
    if args.publication_scope and (args.publication or args.apply_plan):
        parser.error("--publication-scope prepares a plan; use --apply-plan separately")
    repo = Repository(Path.cwd())
    try:
        root_store = Store(repo.root)
        if args.command == "brief" and args.brief_action != "apply":
            # No lock, no state change, and no provider. These commands work while a run is active.
            return focus_brief.command(repo.root, args.brief_action, args.brief_file, args.review_run)
        if args.command == "review" and args.install_ui:
            from focus_picker import install
            install()
            return 0
        if args.command == "review" and args.list:
            print(terminal_text(json.dumps([{"id": s.review_id, "status": v["status"], "phase": v["phase"],
                "task": v["task"], "completed": len(v["review_run"]["results"]),
                "report": str(s.directory / "report.md")} for s, v in runs(repo.root)], ensure_ascii=False, indent=2)))
            return 0
        store = choose_store(repo.root, args.resume or args.review_run,
                             current=args.command in ("status", "messages", "diagnose", "stop", "finish-stage"),
                             require_state=args.command not in ("stop", "diagnose"))
        if args.command == "diagnose":
            from focus_diagnostics import diagnose, refusal_history
            if args.refusals:
                try:
                    saved = store.read()
                except Blocked:
                    saved = None  # Damaged state does not prevent read-only log analysis.
                result = refusal_history(store.directory, saved, repo.root)
            else:
                result = diagnose(store.directory, args.invocation, args.public_output, args.native_log)
            if result is not None:
                print(terminal_text(json.dumps(result, ensure_ascii=False, indent=2)))
            return 0
        if args.command == "status":
            state = store.read()
            if state:
                brief = project_owner_status(store) or status(store, state)
            else:
                brief = project_owner_status(store) or {"status": "not-started", "project_brief": focus_brief.status_entry(repo.root, None)}
            print(json.dumps(brief, ensure_ascii=False, indent=2))
            return 0
        if args.command == "messages":
            state = store.read()
            records = Messages(store).records(state["iteration"]) if state else []
            print(terminal_text(json.dumps(records, ensure_ascii=False, indent=2)))
            return 0
        if args.command == "stop":
            check_project_owner(root_store)
            return request_stop(store, args.now, args.timeout)
        if args.command == "finish-stage":
            check_project_owner(root_store)
            print(terminal_text("cc-focus: " + request_stage_stop(store, args.cancel)), flush=True)
            return 0
        repo = open_project(repo.root)
        repo.assert_main()
        if args.command == "review" and not args.resume and review_request is None:
            review_request = prepare(repo.root, args)
            if review_request is None or args.preview:
                return 0
        # Repository errors must remain in normal terminal scrollback. Opening
        # the composer first leaves a failed admission parked at "starting".
        # The inner main call checks again before taking ownership.
        if interaction is None and args.command in ("run", "review") and args.ui != "off":
            terminal = Terminal()
            if args.ui == "on" or terminal.available():
                return interactive_main(argv, terminal, args.output, review_request, store.review_id)
        with contextlib.ExitStack() as ownership:
            local_lock = ownership.enter_context(LocalLock(root_store.directory))
            check_project_owner(root_store)
            check_parked_provider(root_store)
            member_fds = lock_members(repo, ownership)
            unfinished = pending_run(repo.root)
            if unfinished and store.review_id != unfinished[0].review_id:
                if args.command == "brief":
                    raise Blocked("review-active", "Apply the brief to the unfinished review with cc-focus brief apply --review-run " + unfinished[0].review_id)
                raise Blocked("review-active", "Resume the unfinished review with cc-focus review --resume " + unfinished[0].review_id)
            if not store.review_id:
                hand_back(repo, Path(__file__).resolve().parent)
            if review_request is not None:
                store, _ = create_run(repo, review_request)
                print("cc-focus: review run " + store.review_id + "; resume with cc-focus review --resume " + store.review_id, flush=True)
            if interaction:
                interaction.review_run_id = store.review_id
            state = store.read()
            if isinstance(repo, Project):
                repo.validate_state(state)
            elif state and state.get("baseline", {}).get("repositories"):
                raise Blocked("project-layout-changed", "A saved multi-repository cycle cannot resume as a single repository.")
            blocker = (state or {}).get("blocker") or {}
            keeps_sessions = args.command in ("correct", "recover", "brief") or args.command == "reconcile" and args.apply_plan
            if blocker.get("code") == "claude-refusal" and (keeps_sessions or args.retry and not args.new_sessions):
                # The provider sees the whole saved history again. Do not bill a known refusal.
                from focus_diagnostics import selected_refusals
                if keeps_sessions:
                    # These commands record an operator correction: they reset reviews and pairs but keep role sessions.
                    if selected_refusals(store.directory, state, correction=True):
                        replace = ("cc-focus review --resume " + store.review_id + " --new-sessions" if store.review_id
                                   else "cc-focus --new-sessions")
                        repeat = ("Then run cc-focus brief apply" + (" --review-run " + store.review_id if store.review_id else "") + "."
                                  if args.command == "brief" else "Then repeat this command.")
                        raise Blocked("refusal-retry", (
                            "Claude refused the saved conversation of a role. This command keeps role sessions, "
                            "and the next run of that role sends the refused history again. Run " + replace +
                            " first. It starts new conversations and keeps work, phase and blocker. " + repeat))
                elif selected_refusals(store.directory, state):
                    raise Blocked("refusal-retry", (
                        "Claude refused this saved conversation. A plain --retry sends the same history again, "
                        "and the provider bills each repeated refusal. Remove the cause from the instructions. "
                        "Then run cc-focus --new-sessions --retry. To compare sessions and instructions, run "
                        "cc-focus diagnose --refusals. Work, phase and blocker are preserved."))
            if args.command == "brief" and not state:
                raise Blocked("recovery-state", "No saved focus state exists, so no stage can take the brief. "
                              "The next stage start captures the pointer.")
            if args.command in ("recover", "correct", "reconcile", "retry-message", "discard-message") and not state:
                raise Blocked("recovery-state", "No saved focus state exists; there is no coding result to recover.")
            applied = restart = None
            if args.command == "brief":
                # Saved-state refusals and one pointer capture come before the run starts.
                focus_brief.refuse_apply(state, Messages(store))
                applied = focus_brief.capture(repo.root, focus_brief.start_remedy(focus_brief.BEFORE_RUN))
                target = "review " + store.review_id if store.review_id else "development"
                if focus_brief.unchanged(state, applied):
                    print(f"cc-focus: the current {target} stage already uses the brief {focus_brief.label(applied)}. "
                          "The command changed nothing and started no model.", flush=True)
                    return 0
            elif args.handoff and state and state["status"] == "complete":
                # A bad pointer stops before any change, so a repeat still sees status complete.
                restart = focus_brief.restart_capture(repo.root, state)
            # An apply never saves the state on an error. A restart saves it only with the restart update.
            saves = {"allowed": args.command != "brief" and restart is None}
            state = state or fresh_state(repo)
            scripts = Path(__file__).resolve().parent
            control = Control(store)
            control.begin()
            register_members(repo, control, ownership)
            delivery = interaction or Interaction(PlainTerminal())
            delivery.bind(control, state, store.save)
            control.active["interactive"] = delivery.interactive
            control.controls.artifact("active.json", encode(control.active))
            if delivery.quit:
                control.submit_stop(now=True)
            progress = Progress(store, state, control.active["nonce"], live=args.output != "compact")
            delivery.progress = progress
            progress.on_update = delivery.tick
            progress.heartbeat_log = not delivery.interactive
            exit_code = 3
            try:
                lease_context = (ProjectLease(repo, scripts, state, store.save) if isinstance(repo, Project)
                                 else Lease(repo.root, scripts, state, store.save))
                with lease_context as lease:
                    retire = args.new_sessions
                    if args.handoff:
                        handoff = store.handoff(args.handoff)  # It validates the file before any state change.
                        archive = (store.artifact(f"brief-restarts/{uuid.uuid4().hex}.json", encode(state))
                                   if restart is not None and restart["malformed"] else None)
                        if handoff not in state["handoffs"]:
                            state["handoffs"].append(handoff)
                        if restart is not None:
                            # A changed brief must not remain in a reused conversation.
                            retire = retire or restart["changed"]
                            state.update(status="ready", coordinated=None, code_started=False)
                            focus_brief.record(state, restart["sha256"])
                            if archive:
                                saves["notice"] = "cc-focus: the restart replaced the damaged brief record of the stage. The earlier state is at " + archive
                    if retire:
                        store.artifact(f"sessions/generation-{state['session_generation']:06d}.json", encode(state["sessions"]))
                        state["sessions"] = {}
                        state["session_generation"] += 1
                        if state.get("pending"):
                            state["pending"].pop("turn_id", None)
                            state["pending"]["attempts"] = max(1, state["pending"].get("attempts", 0))
                        state["coordinated"] = None
                    if args.retry and state.get("blocker") and not Messages(store).unresolved(state["iteration"]):
                        signature = state["blocker"]["signature"]
                        state["healed"] = [item for item in state["healed"] if item != signature]
                        state.update(blocker=None, pending=None, status="ready", coordinated=None, recovery_unverified=False)
                        if state.get("published"):
                            retry_at = time.time()
                            state["published"]["at"] = retry_at
                            for name, published in state["published"].get("repositories", {}).items():
                                published["at"] = retry_at
                                state["publication_repositories"][name]["published"]["at"] = retry_at
                    quota = (state.get("pending") or {}).get("quota_wait")
                    if args.retry and quota and not Messages(store).unresolved(state["iteration"]):
                        # Keep the refusal evidence: invoke() still verifies the
                        # entry snapshot and decides whether clean credit survives.
                        # Only the explicit operator retry advances the deadline.
                        quota["retry_at"] = time.time()
                        print("cc-focus: explicit retry of Claude quota with the current login; same invocation and session preserved.", flush=True)
                    from focus_pair_profile import pair_nodes
                    if args.new_sessions and (state.get("pair_review") or {}).get("repair"):
                        # The operator explicitly discarded native history. Keep
                        # source/review evidence but allow the same-role continuation
                        # to reconstruct context, just like native session loss.
                        state["pair_review"]["repair"]["new_session_requested"] = True
                        for node in pair_nodes(state):
                            node["allow_new_self_session"] = True
                    for job in (j for node in pair_nodes(state) for j in node.get("jobs", {}).values()):
                        if args.new_sessions and not job.get("result"):
                            job["sessions"] = {}
                            job.pop("turn_id", None)
                        if args.retry and not job.get("result"):
                            job["retry_at"] = time.time()
                            job["transient_retries"] = 0
                            # The operator retries after a repeated invalid report: give it a new correction budget.
                            job.pop("report_repairs", None)
                    store.save(state)
                    saves["allowed"] = args.command != "brief"
                    if saves.get("notice"):
                        print(saves["notice"], flush=True)  # Only after the restart update is saved.
                    def tick():
                        delivery.tick()
                        control.poll()
                        lease.heartbeat()
                        progress.pulse()
                    progress.note("Runtime ready; use cc-focus status in another terminal for live state.")
                    lock_fds = (local_lock.stream.fileno(), *member_fds)
                    transport = Transport(repo.root, state, store.save, tick, lock_fds, progress=progress, control=control, interaction=delivery)
                    cycle_type = ((ProjectReviewCycle if isinstance(repo, Project) else ReviewCycle) if state.get("review_run")
                                  else ProjectCycle if isinstance(repo, Project) else Cycle)
                    cycle = cycle_type(repo, store, state, transport, tick, scripts, lease.pwsh, control=control, progress=progress)
                    saves["cycle"] = cycle
                    if args.command in ("retry-message", "discard-message"):
                        item = Messages(store).resolve(state["iteration"], args.id, args.command == "retry-message",
                                                       (state.get("pending") or {}).get("id"))
                        delivery.refresh_messages()
                        print(f"cc-focus: message {item['identity']['id']} is {item['status']}. No model was started.", flush=True)
                        exit_code = 0
                    elif args.command in ("recover", "correct", "reconcile", "brief"):
                        if repo.paused() or control.boundary():
                            raise Blocked("recovery-paused", "Recovery was not applied: clear the operator pause/stop before requesting this state transition.")
                        if args.command == "brief":
                            outcome = cycle.apply_brief(applied)
                            following = (cycle.retry_command() if outcome == "direct update" and state.get("blocker") else
                                         "cc-focus review --resume " + store.review_id if store.review_id else "cc-focus")
                            print(f"cc-focus: the command applied the brief {focus_brief.label(applied)} to the current {target} stage "
                                  f"by {outcome} and started no model. Then run {following}.", flush=True)
                        elif args.command == "reconcile":
                            import focus_publication_scope
                            if args.publication:
                                import focus_publication_recovery as focus_reconcile
                            else:
                                import focus_reconcile
                            if args.apply_plan:
                                if not args.publication:
                                    plan = focus_reconcile.read_plan(args.apply_plan, schema=(focus_reconcile.SCHEMA, focus_publication_scope.SCHEMA))
                                    if plan["schema"] == focus_publication_scope.SCHEMA:
                                        focus_reconcile = focus_publication_scope
                                focus_reconcile.apply(cycle, args.apply_plan)
                            else:
                                prepare_plan = focus_reconcile.prepare
                                if args.publication_scope:
                                    request = focus_reconcile.read_plan(args.publication_scope, schema=focus_publication_scope.REQUEST_SCHEMA)
                                    prepare_plan = lambda c: focus_publication_scope.prepare(c, request)
                                if not args.plan_out:
                                    plan = prepare_plan(cycle)
                                elif args.publication_scope:
                                    plan = focus_reconcile.write_plan(cycle, args.plan_out, prepare_plan=prepare_plan)
                                else:
                                    plan = focus_reconcile.write_plan(cycle, args.plan_out)
                                print(terminal_text(json.dumps(plan, ensure_ascii=False, indent=2)))
                                print("cc-focus: reconciliation plan prepared; no changes accepted and no model started.", flush=True)
                        elif args.command == "correct":
                            if args.file:
                                if not args.file.is_file():
                                    raise Blocked("correction-file", "The correction source must be a regular UTF-8 file.")
                                with args.file.open("rb") as source:
                                    data = source.read(65537)
                                if len(data) > 65536:
                                    raise Blocked("correction-file", "The correction file exceeds 64 KiB.")
                                message = data.decode("utf-8-sig")
                            else:
                                message = args.message
                            cycle.correct(message)
                        else:
                            cycle.recover_review(args.review_from)
                        exit_code = 0
                    else:
                        if isinstance(repo, Project):
                            cycle.admit_parallel()  # The member leases and the process control exist here.
                        exit_code = cycle.run()
            except MessagePending as error:
                role = (state.get("pending") or {}).get("role")
                if saves["allowed"]:
                    if role in (*REVIEW_ROLES, *FINAL_ROLES):
                        review_event(state, role, "приостановлено", "Нужно уточнить доставку сообщения")
                    state["status"] = "paused"
                    store.save(state)
                exit_code = 0
                print(terminal_text(f"cc-focus: paused: {error}"), flush=True)
            except (FocusStop, KeyboardInterrupt):
                role = (state.get("pending") or {}).get("role")
                if saves["allowed"]:
                    if role in (*REVIEW_ROLES, *FINAL_ROLES):
                        review_event(state, role, "прервано", "Проход не завершён")
                    state["status"] = "interrupted"
                    store.save(state)
                elif args.command == "brief" and getattr(saves.get("cycle"), "brief_save_started", False):
                    focus_brief.report_apply(store, {"iteration": state["iteration"], "sha256": applied})
                exit_code = 130
                print("cc-focus: interrupted; partial work and sessions preserved. Run cc-focus to recover the same stage.", flush=True)
            except (Blocked, OSError, ValueError):
                # In particular, a failed lease release is not an orderly stop,
                # even when the workflow itself had already returned success.
                exit_code = 3
                if saves["allowed"]:
                    state["status"] = "interrupted"
                    store.save(state)
                elif args.command == "brief" and getattr(saves.get("cycle"), "brief_save_started", False):
                    # Never overwrite a committed change with the earlier state. Report what the saved state contains.
                    focus_brief.report_apply(store, {"iteration": state["iteration"], "sha256": applied})
                raise
            finally:
                if saves.get("cycle"):
                    saves["cycle"].quota_probe.close()  # A quota check does not outlive a stop of the runtime.
                delivery.close_target()
                try:
                    progress.note(f"Runtime exited with code {exit_code}; phase={state['phase']} status={state['status']}.")
                finally:
                    try:
                        control.finish(state, exit_code)
                    finally:
                        delivery.unbind()
            return exit_code
    except (Blocked, OSError, ValueError) as error:
        print(terminal_text(f"cc-focus: stopped: {error}"), file=sys.stderr)
        return 3
    except KeyboardInterrupt:
        print("\ncc-focus: waiting interrupted; any submitted stop request remains active.", file=sys.stderr)
        return 130
    finally:
        # Even setup/progress persistence failures must leave an interactive
        # operator able to retry after fixing the filesystem or ownership issue.
        if interaction:
            interaction.unbind()


def interactive_main(argv, terminal, output, review_request=None, review_id=None):
    """Park the UI only after main has released the lease and runtime lock."""
    interaction = Interaction(terminal)
    interaction.review_run_id = review_id
    with terminal, contextlib.redirect_stdout(terminal), contextlib.redirect_stderr(terminal):
        interaction.note("Interactive terminal ready. /help lists commands; text addresses the current invocation.")
        result = main(argv, interaction=interaction, review_request=review_request)
        while True:
            if runtime_changed():
                interaction.runtime_notice = RUNTIME_UPDATED
                interaction.respond(RUNTIME_UPDATED)
                interaction.tick()
            action, argument = interaction.wait_action()
            if action == "/exit":
                break
            if runtime_changed():
                interaction.runtime_notice = RUNTIME_UPDATED
                interaction.respond(RUNTIME_UPDATED)
                interaction.tick()
                continue
            if action != "/resume" and not interaction.messages and review_request is not None and not interaction.review_run_id:
                interaction.respond("The selection has no saved review run. /resume retries admission. /exit closes this terminal.")
                continue
            if action == "/resume":
                if not interaction.messages and review_request is not None and not interaction.review_run_id:
                    # Admission failed before a campaign existed. Retry that selection,
                    # rather than silently starting the development workflow.
                    result = main(argv, interaction=interaction, review_request=review_request)
                    continue
                # Handoffs and session replacement are one-time launch options.
                resume = ["--output", output or "live"]
                selected = interaction.messages.store if interaction.messages else Store(Path.cwd(), interaction.review_run_id)
                if selected.review_id:
                    resume += ["--review-run", selected.review_id]
                if resume_retries(selected.read()):
                    resume.append("--retry")
                result = main(resume, interaction=interaction)
            elif action == "/correct":
                selected = interaction.messages.store if interaction.messages else Store(Path.cwd(), interaction.review_run_id)
                address = ["--review-run", selected.review_id] if selected.review_id else []
                result = main(["correct", "--message", argument, *address], interaction=interaction)
            else:
                selected = interaction.messages.store if interaction.messages else Store(Path.cwd(), interaction.review_run_id)
                address = ["--review-run", selected.review_id] if selected.review_id else []
                result = main([action[1:], "--id", argument, *address], interaction=interaction)
    print(f"cc-focus: terminal closed (last command exit {result}); saved work and sessions are preserved.")
    return result


if __name__ == "__main__":
    if sys.version_info < (3, 10):
        sys.exit("cc-focus requires Python 3.10 or newer.")
    sys.exit(main())
