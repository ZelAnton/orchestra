"""Durable independent pair participants; only the owner drives control and writes state."""

from concurrent.futures import ThreadPoolExecutor
import copy
import json
from pathlib import Path
import threading
import time
import uuid

from cycle_state import Blocked, ProviderQuota, ProviderTransient, transient_exhausted, encode, digest
from focus_pair_protocol import LEGACY_ARBITER_ERROR, LEGACY_CONSENSUS_ERROR, consensus_error
from cycle_transport import parse_report
from focus_control import FocusStop
from focus_pair_view import artifact, read_record
from focus_progress import Progress
from focus_review_contract import SCANNERS as PAIR_SCOPED_SCANNERS, review_contract
from cycle_prompts import PAIR_CONTRACT
from focus_brief import EXCLUDED_READERS


# Only these reviewed contract revisions can match an older saved pair job.
# Each digest names the form of the contract: plain, or with the review-mode scope.
_EARLIER_CONTRACTS = {
    '35f5c3c483f3294cc106b5f5cc6c951f526545f96efbf1da23b1a73988c47721': False,  # Instruction style revision.
    'e3b989d16224b92d07263eb2b2bdc11ed445181e41f077ba63b647840d696ee7': False,  # Before the test scope rules.
    'efaba581ccc6d8f7695842c07d6e95ef2f48f0f686c6c0e35d9a1f980dbaf27e': True,
}
# The test scope revision added these assignment fields. An older saved job has none of them.
_ADDED_FIELDS = ('full_run', 'final_gate')
_STYLE_TEXT = (
    (('independence',), 'ad38cb9a54219afc5b4bee0a24ba04ae6876de48b7a8d2b7608788144a3631b4', '6acb65188ee89e5a09eebcc31dabb444f0a4c39addf46b47e7f0e66575e86bd6'),
    (('inspection',), 'dd350639f05d541310aa892f4e92004af7ffe4198c331bc91878d1a6e0464c04', 'abe1288aef40b013c17fe94d364f1049ae82be63cf4ea684821396cff5891055'),
    # The search revision: both earlier inspection texts map to the current text, because an entry needs its target hash.
    (('inspection',), 'dd350639f05d541310aa892f4e92004af7ffe4198c331bc91878d1a6e0464c04', '1fc15df8e4969f864203a10d8ce7d35ed25b3463729867605b7f0d3bb1a40a98'),
    (('inspection',), 'abe1288aef40b013c17fe94d364f1049ae82be63cf4ea684821396cff5891055', '1fc15df8e4969f864203a10d8ce7d35ed25b3463729867605b7f0d3bb1a40a98'),
    (('assignment', 'closure_rule'), '699532682ce382cfffe6c4d876c8761c5439c593260a8f39dd502582ef778a38', 'a9b23f24a58c2c0a427d6ed91771db030664cecd29b28ad42a1ec14e168027ac'),
    (('assignment', 'rule'), '3aa06575d4b48a207fd1c617f94bb394c0d2aeb7763c3f2ce0acd149d4067497', 'e11c4e91e32aec45a75cc3cffbbb2a91a3fdecbd5bb65810cc1bba956d96b9ae'),
    (('assignment', 'rule'), '8e36a96eaac8a6cf2e6868b0dd1c918ea30f749d74f668d734e1e71c835666ee', '6498c52dc490afe49c819917aaa48949404a44c4ac57c2017fd5077320d71ead'),
    (('repair_review', 'focus'), 'f4ebb700ac9f36159a19e34799a13222a4af12e63159e0d8776389146cc220b6', '2ff1c2ad0079f8ac53af986e27641cc22723ad96e6a4c3864426781bfaab7122'),
    (('repair_review', 'rule'), 'bbe79e715a111c91bfee35efd58e8253f7c93b52d7123631cfa6a49382038a8b', '66fe8b0e35f299e5e4cdd604cee47e3ed22d25485066928501ba5506bf805440'),
    (('repair_review', 'scope'), '9e5ac107c53b266ed12a0cb12dd293ddaf44a9c6b5eecaa4a55f9670f98b4778', 'a50739f67bd1518c1fe5f1d9533590b82a128cb0341817b8f45591f3cd0b370e'),
    (('assignment', 'rule'), 'df9a882985c1d7d26e5da73a9a7589e38022116401a762339108f7e86cf905ad', 'da1937bb77d4b4c9ef0f3b97703b4067b3607b0f287e367345ff2867f958ae56'),
    # The catch-up revision: changes of other writers also arrive when a blocked step needs them.
    (('parallel_repositories', 'rule'), 'd53e07e7e9970f72f69b59075e51952f9da33925a1f8d2db98a1cf2b056dc782', '76c579c8dbffe92a5c03757fc52128e9c57d90075acfe814d8d7652db9ed31d7'),
)

def same_pair_prompt(saved, current):
    """Accept one known prose revision. Keep all task data and saved bytes exact."""
    if saved == current:
        return True

    def unique_object(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError('Duplicate prompt field')
            result[key] = value
        return result

    try:
        old_prefix, old_json = saved.split('\nRuntime assignment:\n', 1)
        new_prefix, new_json = current.split('\nRuntime assignment:\n', 1)
        scoped = _EARLIER_CONTRACTS.get(digest(old_prefix.encode()))
        if old_prefix != new_prefix and (scoped is None or new_prefix != review_contract(PAIR_CONTRACT, scoped)):
            return False
        old = json.loads(old_json, object_pairs_hook=unique_object)
        new = json.loads(new_json, object_pairs_hook=unique_object)
        if old_prefix != new_prefix:
            for key in _ADDED_FIELDS:
                if key not in old:
                    new.pop(key, None)
        for path, old_hash, new_hash in _STYLE_TEXT:
            left, right = old, new
            for part in path[:-1]:
                left = left.get(part, {})
                right = right.get(part, {})
            key = path[-1]
            before, after = left.get(key), right.get(key)
            if isinstance(before, str) and isinstance(after, str):
                if digest(before.encode()) == old_hash and digest(after.encode()) == new_hash:
                    left[key] = after
        return encode(old) == encode(new)
    except (AttributeError, TypeError, ValueError):
        return False


# A renewed legacy view adds only these inspection inputs to an unchanged assignment.
_VIEW_FIELDS = ("history", "publication_manifest", "publication_rule")


def without_view_fields(prompt):
    try:
        prefix, assignment = prompt.split('\nRuntime assignment:\n', 1)
        value = json.loads(assignment)
        for key in _VIEW_FIELDS:
            value.pop(key, None)
        return prefix + '\nRuntime assignment:\n' + json.dumps(value, ensure_ascii=False, sort_keys=True)
    except (AttributeError, TypeError, ValueError):
        return prompt


def same_saved_job(job, prompt):
    """A report kept from a renewed legacy view keeps its assignment check."""
    if same_pair_prompt(job["prompt"], prompt):
        return True
    return bool(job.get("frozen_view")) and same_pair_prompt(without_view_fields(job["prompt"]), without_view_fields(prompt))


def renew_report_marker(job, report_only=True):
    # A completed native Codex turn must not be recovered as the next attempt.
    job.update(native_id=uuid.uuid4().hex, attempts=0, report_repair=report_only)
    job.pop("turn_id", None)


def run_jobs(cycle, pair, requests, manifest):
    """Run one or two readers. Persist each result before joining the barrier."""
    jobs = pair.setdefault("jobs", {})
    for key, role, prompt in requests:
        if key not in jobs:
            owner = pair.get("session_owner") if role.startswith("repair_self") else None
            session = cycle.state["sessions"].get(owner) if owner else None
            if owner and not session and not pair.get("allow_new_self_session"):
                raise Blocked("repair-session", "The same-agent review requires its executor's saved native session.")
            jobs[key] = {"id": uuid.uuid4().hex, "role": role, "prompt": prompt,
                         "sessions": {role: session} if session else {}, "status": "ready", "attempts": 0, "created": time.time()}
            if "project_brief_sha256" in pair and role not in EXCLUDED_READERS:
                # Evidence only. Saved-prompt equality compares the prompt, not this field.
                jobs[key]["project_brief_sha256"] = pair["project_brief_sha256"]
        elif not same_saved_job(jobs[key], prompt) or jobs[key]["role"] != role:
            raise Blocked("pair-intent", "A saved participant cannot be replayed against another assignment.")
        elif jobs[key].get("frozen_view") and jobs[key]["prompt"] != prompt:
            # A rerun of a kept report reads the evidence of the renewed view. Keep the first prompt:
            # each attempt writes its prompt.txt again.
            jobs[key].setdefault("frozen_prompt", jobs[key]["prompt"])
            jobs[key]["prompt"] = prompt
    pending = cycle.state.get("pending")
    if pending and pending["role"] != "pair_group":
        raise Blocked("pair-intent", "An unfinished writer must complete before pair readers start.")
    if not pending:
        pending = {"id": uuid.uuid4().hex, "role": "pair_group", "iteration": cycle.state["iteration"],
                   "before": pair["snapshot"], "started": time.time(),
                   "participants": {key: jobs[key]["id"] for key, _, _ in requests}, "pair": pair["id"]}
        cycle.state["pending"] = pending
        artifact(cycle.store, f"invocations/{pending['id']}/intent.json", pending)
    cycle.save()
    cancel = threading.Event()
    interaction = getattr(cycle.transport, "interaction", None)
    if interaction:
        interaction.begin(pending)
    if cycle.progress:
        cycle.progress.runtime("pair")
    running = {}
    launched = []

    def worker(key):
        job = jobs[key]
        directory = cycle.store.directory / "invocations" / job["id"]
        directory.mkdir(parents=True, exist_ok=True)
        # The child knows every refused conversation, so it cannot resume one of them.
        child = {"sessions": copy.deepcopy(job["sessions"]), "iteration": cycle.state["iteration"],
                 "refused_sessions": list(cycle.state.get("refused_sessions", [])),
                 "phase": pair["phase"], "inspection": manifest,
                 "inspection_path": str(cycle.store.directory / pair["view"]["path"])}
        if manifest.get("review_scope") and not pair.get("repair_base"):
            child["review_scope"] = manifest["review_scope"]
        intent = {k: copy.deepcopy(v) for k, v in job.items() if k not in ("live", "result", "prompt")}
        intent["id"] = job.get("native_id", job["id"])
        child["pending"] = intent
        def save(state):
            with cycle.state_lock:
                job.update({k: v for k, v in intent.items() if k not in ("id", "sessions", "status")})
                job["sessions"] = copy.deepcopy(state["sessions"])
                # A refusal restart or a refused conversation of a pair participant also belongs to the cycle state.
                for key in ("refusal_restarts", "refused_sessions"):
                    rows = cycle.state.setdefault(key, [])
                    rows.extend(copy.deepcopy(r) for r in state.get(key, []) if r not in rows)
                    if not rows:
                        cycle.state.pop(key)
                if pair.get("session_owner") and job["role"].startswith("repair_self") and state["sessions"].get(job["role"]):
                    cycle.state["sessions"][pair["session_owner"]] = state["sessions"][job["role"]]
                cycle.save()
        def heartbeat():
            if cancel.is_set():
                raise FocusStop("Pair readers stopped together; completed peer reports are preserved.")
        class LocalArtifacts:
            def artifact(self, name, data):
                return cycle.store.artifact(f"invocations/{job['id']}/{name}", data)
        progress = Progress(LocalArtifacts(), child, live=bool(cycle.progress and cycle.progress.live))
        def update():
            with cycle.state_lock:
                job["live"] = progress.view()
        progress.on_update = update
        # Claude stores native conversations by cwd. A self review resumes the
        # executor in its original cwd, but its ONLY tool still reads the sealed
        # inspection manifest. Independent peers use isolated view directories.
        # A job kept from a renewed legacy view resumes in that view's directory.
        if pair.get("session_owner") and job["role"].startswith("repair_self"):
            native_root = cycle.repo.root
        elif job.get("frozen_view"):
            # materialize freezes a view as <view-dir>/view.json with its root in <view-dir>/source.
            native_root = cycle.store.directory / Path(job["frozen_view"]["path"]).parent / "source"
            native_root.mkdir(parents=True, exist_ok=True)
        else:
            native_root = Path(manifest["root"])
        transport = cycle.transport.fork(native_root, child, save, heartbeat,
            control=cycle.control.child(job["id"], native_root) if cycle.control else None, progress=progress)
        with cycle.state_lock:
            job["status"] = "running"
            cycle.save()
        progress.start(job["role"], directory)
        try:
            if job.get("report_error") == LEGACY_ARBITER_ERROR and job.get("report_source"):
                # The current parser can accept the refused report. Then its new findings join the
                # registry without another provider call, which could drop them.
                try:
                    report = parse_report(read_record(cycle.store, job["report_source"])["raw"], job["role"],
                                          bool(child.get("review_scope")))
                    current = ('Complete the arbitration. Return status=done with evidence. Keep your decisions '
                               'and new findings. If you cannot complete it, return blocked and name the obstacle.')
                except Blocked as error:
                    report, current = None, str(error)
                if not (report and report["status"] == "done" and report["evidence"]):
                    with cycle.state_lock:
                        job["report_error"] = current  # The correction prompt names the current problem.
                        cycle.save()
                else:
                    with cycle.state_lock:
                        job["result"] = artifact(cycle.store, f"invocations/{job['id']}/reports/{uuid.uuid4().hex}.json", report)
                        artifact(cycle.store, f"invocations/{job['id']}/result.json", report)
                        job.pop("report_error")
                        job["status"] = "done"
                        job.pop("retry_at", None)
                        cycle.save()
                    return
            prompt = job["prompt"]
            if job.get("incomplete_report") and not job.get("report_repair"):
                prompt += ('\nThe prior completed attempt could not finish inspection. Repeat this same review in full with the current inspection tools. Do not advance the stage.')
            if job.get("report_error"):
                error = job["report_error"]
                if error == LEGACY_CONSENSUS_ERROR:
                    # Older runtimes saved this text. It asked readers to name the impact in consensus.
                    key = pair.get("proposal_hash")
                    error = consensus_error(key, key and (pair.get("proposal") or {}).get("impact"))
                prompt += '\nCorrect the prior report with this validation error. Do not repeat side effects: ' + error
                if job.get("report_source"):
                    prompt += "\nPrevious public report to correct:\n" + json.dumps(read_record(cycle.store, job["report_source"]), ensure_ascii=False)
            heartbeat()
            previous_turn = intent.get("turn_id")
            raw = transport.run(job["role"], prompt, intent, directory)
            with cycle.state_lock:
                # The provider answered. A later server error, e.g. in a report correction, gets new retries.
                job.pop("transient_retries", None)
            # Save raw output even if schema validation fails; repair can inspect it.
            artifact(cycle.store, f"invocations/{job['id']}/response.json", {"raw": raw, "native_id": intent["id"]})
            try:
                report = parse_report(raw, job["role"], bool(child.get("review_scope")))
                if child.get("review_scope") and job["role"] in PAIR_SCOPED_SCANNERS:
                    from focus_review_contract import validate_coverage
                    validate_coverage(report, child["review_scope"], manifest["files"])
            except Blocked as error:
                with cycle.state_lock:
                    job["report_source"] = artifact(cycle.store, f"invocations/{job['id']}/reports/{uuid.uuid4().hex}.json", {"raw": raw})
                    job["report_error"] = str(error)
                    job["report_repairs"] = job.get("report_repairs", 0) + 1
                    job["status"] = "ready"
                    renew_report_marker(job)
                    cycle.save()
                    if job["report_repairs"] <= 2:
                        return  # Retry only this report; a completed peer stays sealed.
                raise
            if report["status"] != "done" or not report["evidence"]:
                with cycle.state_lock:
                    job["incomplete_report"] = artifact(cycle.store,
                        f"invocations/{job['id']}/reports/{uuid.uuid4().hex}.json",
                        {"raw": raw, "native_id": intent["id"], "turn_id": intent.get("turn_id")})
                    renew_report_marker(job, report_only=False)
                    job.pop("report_error", None)
                    job["status"] = "ready"
                    cycle.save()
                if previous_turn and previous_turn == intent.get("turn_id"):
                    # Codex recovered an already completed refusal. No new model
                    # work ran: continue once with a fresh marker. Do not infer
                    # completion from stale response files or retire active turns.
                    return
                raise Blocked("pair-incomplete", report["summary"] + "\n" + report["description"])
            with cycle.state_lock:
                job["result"] = artifact(cycle.store, f"invocations/{job['id']}/reports/{uuid.uuid4().hex}.json", report)
                artifact(cycle.store, f"invocations/{job['id']}/result.json", report)
                job["status"] = "done"
                job.pop("retry_at", None)
                cycle.save()
        except (ProviderQuota, ProviderTransient) as error:
            with cycle.state_lock:
                count = job.get("transient_retries", 0)
                if isinstance(error, ProviderTransient) and count >= 3:
                    job["status"] = "failed"
                    cycle.save()
                    # The blocker names the pair group invocation. The failure is in the participant's own.
                    raise Blocked(error.code, str(error) + " The runtime used all 3 retries of this pair participant. "
                                  + transient_exhausted(f"The invocation of participant {job['role']}", cycle.retry_command())) from error
                delay = (15, 30, 60)[count] if isinstance(error, ProviderTransient) else 60
                if isinstance(error, ProviderTransient):
                    job["transient_retries"] = count + 1
                job.update(status="waiting", retry_at=max(time.time() + delay, getattr(error, "resets_at", 0) + 5),
                           wait_reason=error.code, wait_account=getattr(error, "account", None))
                cycle.save()
        except BaseException:
            with cycle.state_lock:
                job["status"] = "interrupted"
                cycle.save()
            raise
        finally:
            progress.finish()

    pool = ThreadPoolExecutor(max_workers=2, thread_name_prefix="focus-review")
    try:
        try:
            while True:
                cycle.heartbeat()
                # Input is a group instruction. Stop both before accepting it;
                # the next pass gets it in both independent prompts.
                if interaction and cycle.messages.unresolved(cycle.state["iteration"], pending["id"]):
                    cancel.set()
                    for future in running.values():
                        try:
                            future.result()
                        except FocusStop:
                            pass
                    cycle.accept_pair_input(pair, pending)
                    return None
                for key, _, _ in requests:
                    job = jobs[key]
                    if (key not in running and not job.get("result") and job.get("status") == "waiting"
                            and job.get("wait_reason") == "claude-quota" and time.time() < job.get("retry_at", 0)
                            and cycle.login_watch.changed(job.get("wait_account"))):
                        # A new Claude login can have quota now. Pending input stopped the group above.
                        with cycle.state_lock:
                            job["retry_at"] = time.time()
                            cycle.save()
                        print(f"cc-focus: the Claude login changed after the quota refusal of {job['role']}; retrying it now.", flush=True)
                    if key not in running and not job.get("result") and time.time() >= job.get("retry_at", 0):
                        running[key] = pool.submit(worker, key)
                        launched.append(running[key])
                for key, future in list(running.items()):
                    if future.done():
                        future.result()
                        del running[key]
                if all(jobs[key].get("result") for key, _, _ in requests):
                    break
                # A participant can wait hours for quota. When no participant runs, a stop request
                # takes effect now: an emergency stop raises FocusStop, and a safe stop returns to the
                # run boundary. Completed reports and the saved wait deadlines stay in the state.
                if cycle.control and not running:
                    cycle.control.poll()
                    if cycle.control.request():
                        return None
                if cycle.progress:
                    cycle.progress.activity = "; ".join(jobs[k]["role"] + ": " + jobs[k]["status"] for k, _, _ in requests)
                    cycle.progress.pulse()
                time.sleep(.1)
        finally:
            cancel.set()
            # Inspect every exit, including peers cancelled after another failed.
            pool.shutdown(wait=True)
            unsafe = []
            for future in launched:
                try:
                    future.result()
                except Blocked as error:
                    if error.code in ("cleanup-incomplete", "turn-active"):
                        unsafe.append(error)
                except BaseException:
                    pass  # The primary failure still propagates.
            if unsafe:
                raise unsafe[0]
        if cycle.snapshot() != pair["snapshot"]:
            raise Blocked("pair-drift", "Source, HEAD or staging changed during read-only pair inspection; no credit granted.")
        cycle.check_protected(pair["snapshot"])
        results = [read_record(cycle.store, jobs[key]["result"]) for key, _, _ in requests]
        if interaction:
            with interaction.lock:
                if cycle.messages.unresolved(cycle.state["iteration"], pending["id"]):
                    cycle.accept_pair_input(pair, pending)
                    return None
                interaction.close_target()
        cycle.state["pending"] = None
        cycle.save()
        return results
    finally:
        if interaction:
            interaction.close_target()
