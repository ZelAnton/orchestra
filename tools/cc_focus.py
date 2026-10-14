"""Entry point for cc-focus; Python 3.10+, standard library only."""

import argparse
import contextlib
import hashlib
import json
from pathlib import Path
import sys
import time

from cycle_prompts import REVIEW_ROLES, FINAL_ROLES
from cycle_state import Blocked, Lease, LocalLock, Repository, Store, encode
from cycle_transport import Transport
from cycle_workflow import Cycle, fresh_state
from focus_control import Control, FocusStop, check_parked_provider, request_stop, status
from focus_progress import Progress
from focus_output import terminal_text
from focus_input import Interaction, PlainTerminal
from focus_messages import MessagePending, Messages
from focus_terminal import Terminal
from focus_status import review_event
from focus_project import Project, ProjectLease, check_project_owner, lock_members, open_project, project_owner_status, register_members
from focus_publication import ProjectCycle


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


def main(argv=None, interaction=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    parser = argparse.ArgumentParser(prog="cc-focus", description="Sequential main-branch Claude/Codex cycle with durable local sessions.")
    parser.add_argument("command", nargs="?", choices=("run", "status", "diagnose", "stop", "recover", "correct", "reconcile", "messages", "retry-message", "discard-message"), default="run")
    parser.add_argument("--invocation", help="With diagnose: read public metadata for this invocation ID; no state or provider changes.")
    parser.add_argument("--public-output", action="store_true", help="With diagnose: display public messages and tool results instead of metadata.")
    parser.add_argument("--native-log", type=Path, help="With diagnose: inspect instruction and tool-schema metadata in this matching native Claude session log.")
    parser.add_argument("--refusals", action="store_true", help="With diagnose: correlate saved Claude refusals with sessions and instruction changes; no state or provider changes.")
    parser.add_argument("--handoff", type=Path, help="Import a UTF-8 handoff file (no session ID import).")
    parser.add_argument("--new-sessions", action="store_true", help="Start clean conversations, preserving work and phase progress.")
    parser.add_argument("--retry", action="store_true", help="Retry a preserved blocker or immediately recheck a saved Claude quota wait after changing accounts.")
    parser.add_argument("--now", action="store_true", help="With stop: interrupt now instead of waiting for a safe boundary.")
    parser.add_argument("--timeout", type=float, help="With stop: maximum wait in seconds; the stop request survives timeout.")
    parser.add_argument("--review-from", type=Path, help="With recover: validate a saved coding result and pause before mandatory reviews; starts no model.")
    parser.add_argument("--output", choices=("live", "compact"), help="With run: live public messages/actions/results (default), or compact activity only.")
    parser.add_argument("--ui", choices=("auto", "on", "off"), help="With run: persistent terminal composer (auto on a capable TTY); off preserves plain output.")
    parser.add_argument("--id", help="With retry-message/discard-message: an unambiguous saved message ID.")
    correction = parser.add_mutually_exclusive_group()
    correction.add_argument("--message", help="With correct: save an operator correction for the stopped current stage.")
    correction.add_argument("--file", type=Path, help="With correct: import a UTF-8 correction file, at most 64 KiB.")
    reconciliation = parser.add_mutually_exclusive_group()
    parser.add_argument("--publication", action="store_true", help="With reconcile: explicitly accept a preserved already-pushed protected scope and restart all required reviews.")
    reconciliation.add_argument("--plan-out", type=Path, help="With reconcile: write a reviewable handover plan to a new file; accept no changes yet.")
    reconciliation.add_argument("--apply-plan", type=Path, help="With reconcile: explicitly accept this exact plan, transfer its protected files to the cycle, and restart coding/reviews.")
    args = parser.parse_args(argv)
    if (args.command == "diagnose") != bool(args.invocation or args.refusals) or args.public_output and args.command != "diagnose":
        parser.error("diagnose requires --invocation or --refusals; these options and --public-output are only valid with diagnose")
    if args.refusals and (args.invocation or args.public_output or args.native_log is not None):
        parser.error("--refusals cannot combine with --invocation, --public-output or --native-log")
    if args.native_log is not None and (args.command != "diagnose" or args.public_output):
        parser.error("--native-log requires diagnose and cannot combine with --public-output")
    if args.command != "stop" and (args.now or args.timeout is not None):
        parser.error("--now and --timeout require stop")
    if args.timeout is not None and (not 0 < args.timeout < float("inf")):
        parser.error("--timeout must be a finite positive number")
    if args.command != "run" and (args.handoff or args.new_sessions or args.retry or args.output or args.ui):
        parser.error("Only run accepts --handoff, --new-sessions, --retry, --output or --ui")
    if (args.command == "recover") != bool(args.review_from):
        parser.error("recover requires --review-from; that option is only valid with recover")
    if (args.command == "correct") != (args.message is not None or args.file is not None):
        parser.error("correct requires --message or --file; those options are only valid with correct")
    if (args.command in ("retry-message", "discard-message")) != bool(args.id):
        parser.error("retry-message/discard-message require --id; that option is only valid with these commands")
    if args.command != "reconcile" and (args.plan_out or args.apply_plan or args.publication):
        parser.error("--plan-out, --apply-plan and --publication require reconcile")
    repo = Repository(Path.cwd())
    try:
        store = Store(repo.root)
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
            brief = project_owner_status(store) or (status(store, state) if state else {"status": "not-started"})
            print(json.dumps(brief, ensure_ascii=False, indent=2))
            return 0
        if args.command == "messages":
            state = store.read()
            records = Messages(store).records(state["iteration"]) if state else []
            print(terminal_text(json.dumps(records, ensure_ascii=False, indent=2)))
            return 0
        if args.command == "stop":
            check_project_owner(store)
            return request_stop(store, args.now, args.timeout)
        repo = open_project(repo.root)
        repo.assert_main()
        # Repository errors must remain in normal terminal scrollback. Opening
        # the composer first leaves a failed admission parked at "starting".
        # The inner main call checks again before taking ownership.
        if interaction is None and args.command == "run" and args.ui != "off":
            terminal = Terminal()
            if args.ui == "on" or terminal.available():
                return interactive_main(argv, terminal, args.output)
        with contextlib.ExitStack() as ownership:
            local_lock = ownership.enter_context(LocalLock(store.directory))
            check_project_owner(store)
            check_parked_provider(store)
            member_fds = lock_members(repo, ownership)
            state = store.read()
            if isinstance(repo, Project):
                repo.validate_state(state)
            elif state and state.get("baseline", {}).get("repositories"):
                raise Blocked("project-layout-changed", "A saved multi-repository cycle cannot resume as a single repository.")
            blocker = (state or {}).get("blocker") or {}
            keeps_sessions = args.command in ("correct", "recover") or args.command == "reconcile" and args.apply_plan
            if blocker.get("code") == "claude-refusal" and (keeps_sessions or args.retry and not args.new_sessions):
                # The provider sees the whole saved history again. Do not bill a known refusal.
                from focus_diagnostics import selected_refusals
                if keeps_sessions:
                    # These commands record an operator correction: they reset reviews and pairs but keep role sessions.
                    if selected_refusals(store.directory, state, correction=True):
                        raise Blocked("refusal-retry", (
                            "Claude refused the saved conversation of a role. This command keeps role sessions, "
                            "and the next run of that role sends the refused history again. Run cc-focus "
                            "--new-sessions first. It starts new conversations and keeps work, phase and blocker. "
                            "Then repeat this command."))
                elif selected_refusals(store.directory, state):
                    raise Blocked("refusal-retry", (
                        "Claude refused this saved conversation. A plain --retry sends the same history again, "
                        "and the provider bills each repeated refusal. Remove the cause from the instructions. "
                        "Then run cc-focus --new-sessions --retry. To compare sessions and instructions, run "
                        "cc-focus diagnose --refusals. Work, phase and blocker are preserved."))
            if args.command in ("recover", "correct", "reconcile", "retry-message", "discard-message") and not state:
                raise Blocked("recovery-state", "No saved focus state exists; there is no coding result to recover.")
            state = state or fresh_state(repo)
            scripts = Path(__file__).resolve().parent
            control = Control(store)
            control.begin()
            register_members(repo, control, ownership)
            delivery = interaction or Interaction(PlainTerminal())
            delivery.bind(control, state, store.save)
            control.active["interactive"] = delivery.interactive
            store.artifact("active.json", encode(control.active))
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
                    if args.handoff:
                        handoff = store.handoff(args.handoff)
                        if handoff not in state["handoffs"]:
                            state["handoffs"].append(handoff)
                        if state["status"] == "complete":
                            state.update(status="ready", coordinated=None, code_started=False)
                    if args.new_sessions:
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
                    def tick():
                        delivery.tick()
                        control.poll()
                        lease.heartbeat()
                        progress.pulse()
                    progress.note("Runtime ready; use cc-focus status in another terminal for live state.")
                    lock_fds = (local_lock.stream.fileno(), *member_fds)
                    transport = Transport(repo.root, state, store.save, tick, lock_fds, progress=progress, control=control, interaction=delivery)
                    cycle_type = ProjectCycle if isinstance(repo, Project) else Cycle
                    cycle = cycle_type(repo, store, state, transport, tick, scripts, lease.pwsh, control=control, progress=progress)
                    if args.command in ("retry-message", "discard-message"):
                        item = Messages(store).resolve(state["iteration"], args.id, args.command == "retry-message",
                                                       (state.get("pending") or {}).get("id"))
                        delivery.refresh_messages()
                        print(f"cc-focus: message {item['identity']['id']} is {item['status']}. No model was started.", flush=True)
                        exit_code = 0
                    elif args.command in ("recover", "correct", "reconcile"):
                        if repo.paused() or control.boundary():
                            raise Blocked("recovery-paused", "Recovery was not applied: clear the operator pause/stop before requesting this state transition.")
                        if args.command == "reconcile":
                            if args.publication:
                                import focus_publication_recovery as focus_reconcile
                            else:
                                import focus_reconcile
                            if args.apply_plan:
                                focus_reconcile.apply(cycle, args.apply_plan)
                            else:
                                plan = (focus_reconcile.write_plan(cycle, args.plan_out) if args.plan_out
                                        else focus_reconcile.prepare(cycle))
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
                        exit_code = cycle.run()
            except MessagePending as error:
                role = (state.get("pending") or {}).get("role")
                if role in (*REVIEW_ROLES, *FINAL_ROLES):
                    review_event(state, role, "приостановлено", "Нужно уточнить доставку сообщения")
                state["status"] = "paused"
                store.save(state)
                exit_code = 0
                print(terminal_text(f"cc-focus: paused: {error}"), flush=True)
            except (FocusStop, KeyboardInterrupt):
                role = (state.get("pending") or {}).get("role")
                if role in (*REVIEW_ROLES, *FINAL_ROLES):
                    review_event(state, role, "прервано", "Проход не завершён")
                state["status"] = "interrupted"
                store.save(state)
                exit_code = 130
                print("cc-focus: interrupted; partial work and sessions preserved. Run cc-focus to recover the same stage.", flush=True)
            except (Blocked, OSError, ValueError):
                # In particular, a failed lease release is not an orderly stop,
                # even when the workflow itself had already returned success.
                exit_code = 3
                state["status"] = "interrupted"
                store.save(state)
                raise
            finally:
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


def interactive_main(argv, terminal, output):
    """Park the UI only after main has released the lease and runtime lock."""
    interaction = Interaction(terminal)
    with terminal, contextlib.redirect_stdout(terminal), contextlib.redirect_stderr(terminal):
        interaction.note("Interactive terminal ready. /help lists commands; text addresses the current invocation.")
        result = main(argv, interaction=interaction)
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
            if action == "/resume":
                # Handoffs and session replacement are one-time launch options.
                resume = ["--output", output or "live"]
                state = Store(Path.cwd()).read()
                if state and ((state.get("blocker") or {}).get("status") == "blocked"
                              or (state.get("pending") or {}).get("quota_wait")):
                    resume.append("--retry")
                result = main(resume, interaction=interaction)
            elif action == "/correct":
                result = main(["correct", "--message", argument], interaction=interaction)
            else:
                result = main([action[1:], "--id", argument], interaction=interaction)
    print(f"cc-focus: terminal closed (last command exit {result}); saved work and sessions are preserved.")
    return result


if __name__ == "__main__":
    if sys.version_info < (3, 10):
        sys.exit("cc-focus requires Python 3.10 or newer.")
    sys.exit(main())
