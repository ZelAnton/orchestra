"""Repository-scoped operator stop requests and exact-run process containment."""

import json
import os
from pathlib import Path
import re
import time
import threading
import uuid

from cycle_state import Blocked, LocalLock, command, encode


class FocusStop(Exception):
    """An operator interruption is never a model-resolvable blocker."""


def read_json(path):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (ValueError, OSError) as error:
        raise Blocked("invalid-control", f"Cannot read focus control file {path}: {error}") from error


def runtime_active(store):
    try:
        with LocalLock(store.directory, existing=True):
            return False
    except FileNotFoundError:
        return False
    except Blocked:
        return True


def owner_stamp(pid):
    """Native birth marker when available; PID reuse must not block crash resume."""
    try:
        if os.name == "nt":
            import ctypes
            from ctypes import wintypes
            kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
            kernel.OpenProcess.restype = wintypes.HANDLE
            kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
            kernel.CloseHandle.argtypes = [wintypes.HANDLE]
            handle = kernel.OpenProcess(0x1000, False, pid)
            if not handle:
                return None
            try:
                values = [wintypes.FILETIME() for _ in range(4)]
                if kernel.GetProcessTimes(handle, *(ctypes.byref(value) for value in values)):
                    return str((values[0].dwHighDateTime << 32) | values[0].dwLowDateTime)
            finally:
                kernel.CloseHandle(handle)
        else:
            stat = Path(f"/proc/{pid}/stat").read_text().rpartition(")")[2].split()
            boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
            return boot + ":" + stat[19]
    except (OSError, IndexError):
        pass
    return None


def owner_alive(active):
    """Conservative liveness, not identity authority; never signal on Windows."""
    pid = active.get("pid")
    if type(pid) is not int or pid <= 0:
        return True
    current_stamp = owner_stamp(pid) if active.get("owner_stamp") else None
    if current_stamp and current_stamp != active["owner_stamp"]:
        return False
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return ctypes.get_last_error() != 87  # Invalid PID; access denial is not death.
        try:
            code = wintypes.DWORD()
            return not kernel.GetExitCodeProcess(handle, ctypes.byref(code)) or code.value == 259
        finally:
            kernel.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def check_parked_provider(store):
    """A live parked UI must prove leaf exit before another epoch takes ownership."""
    active = read_json(store.directory / "active.json") or {}
    for provider in provider_records(active) if active.get("interactive") and owner_alive(active) else []:
        if not container_identity(provider):
            raise Blocked("cleanup-incomplete", "The parked UI has an unaddressable provider; no new processing may start.")
        try:
            wait_container(store, provider, timeout=1)
        except Blocked as error:
            raise Blocked("cleanup-incomplete", "The previous UI provider has not confirmed exit. Use cc-focus stop --now from another terminal before resuming.") from error


class Control:
    def __init__(self, store):
        self.store = store
        self.active = None
        self.announced = None
        self.provider_lock = threading.RLock()

    def begin(self):
        with LocalLock(self.store.directory, "control.lock"):
            self.active = {"nonce": uuid.uuid4().hex, "root": str(self.store.root),
                           "pid": os.getpid(), "started": time.time(), "finished": None,
                           "owner_stamp": owner_stamp(os.getpid()),
                           "processkit_run_id": os.environ.get("ORCHESTRA_PROCESSKIT_ROOT_RUN_ID", ""),
                           "processkit_cli": os.environ.get("ORCHESTRA_FOCUS_PROCESSKIT_CLI", "")}
            self.store.artifact("active.json", encode(self.active))

    def request(self):
        request = read_json(self.store.directory / "stop.json")
        return request if request and self.active and request.get("nonce") == self.active["nonce"] else None

    def submit_stop(self, now=False):
        """Nonblocking request from this run's terminal; never target a newer run."""
        with LocalLock(self.store.directory, "control.lock"):
            current = read_json(self.store.directory / "active.json")
            if not current or current.get("nonce") != self.active["nonce"] or current.get("finished"):
                raise Blocked("stop-target-changed", "This run has ended; no stop was sent to another run.")
            previous = self.request()
            mode = "now" if now or (previous and previous.get("mode") == "now") else "safe"
            self.store.artifact("stop.json", encode({"nonce": self.active["nonce"], "mode": mode, "requested": time.time()}))

    def child(self, slot, cwd=None):
        parent = self
        class Leaf:
            store = parent.store
            @property
            def active(self):
                with parent.provider_lock:
                    record = parent.active.get("provider_runs", {}).get(slot)
                    return {"provider_run": dict(record)} if record else {}
            def prepare_provider(self, log):
                return parent.prepare_provider(log, slot, cwd)
            def clear_provider(self):
                parent.clear_provider(slot)
        return Leaf()

    def prepare_provider(self, log, slot=None, cwd=None):
        with self.provider_lock:
            identity = container_identity(self.active)
            if not identity:
                return None
            cli, _ = identity
            run_id = "orchestra-focus-provider-" + uuid.uuid4().hex
            record = {"processkit_cli": cli, "processkit_run_id": run_id}
            if slot is None:
                self.active["provider_run"] = record
            else:
                self.active.setdefault("provider_runs", {})[slot] = record
            self.store.artifact("active.json", encode(self.active))
            return [cli, "run", "--run-id", run_id, "--cwd", str(cwd or self.store.root),
                    "--jsonl", str(Path(log).with_suffix(".processkit.jsonl")), "--inherit-stdio", "--"]

    def clear_provider(self, slot=None):
        with self.provider_lock:
            if slot is None:
                self.active["provider_run"] = None
            else:
                self.active.setdefault("provider_runs", {}).pop(slot, None)
            self.store.artifact("active.json", encode(self.active))

    def poll(self):
        request = self.request()
        if not request:
            return
        if request["mode"] != self.announced:
            self.announced = request["mode"]
            print("cc-focus: stop requested: " + ("interrupting now; partial work will be preserved."
                  if request["mode"] == "now" else "waiting for a safe boundary (publication includes CI)."), flush=True)
        if request["mode"] == "now":
            raise FocusStop("Emergency stop requested by the operator.")

    def boundary(self, publication_window=False):
        self.poll()
        return bool(self.request()) and not publication_window

    def finish(self, state, exit_code):
        if not self.active:
            return
        self.active.update(finished=time.time(), exit_code=exit_code,
                           phase=state.get("phase"), status=state.get("status"),
                           ui_parked=bool(self.active.get("interactive") and not provider_records(self.active)))
        self.store.artifact(f"runs/{self.active['nonce']}.json", encode(self.active))
        self.store.artifact("active.json", encode(self.active))


def status(store, state):
    brief = {key: state.get(key) for key in ("phase", "iteration", "status", "last", "blocker", "published", "corrections", "correction_pending")}
    pair = state.get("pair_review")
    if pair:
        repair = pair.get("repair") or {}
        readers = repair.get("evidence_reader") or repair.get("reader") or pair
        brief["pair_review"] = {k: pair[k] for k in ("phase", "round", "step", "discussion")}
        brief["pair_review"].update(executor_role=pair.get("executor_role"), findings=len(pair.get("issues", [])),
            participants=[{k: job.get(k) for k in ("role", "status", "retry_at", "live")}
                          for job in sorted(readers.get("jobs", {}).values(), key=lambda j: j.get("created", 0))][-5:])
        if repair:
            brief["pair_review"]["repair"] = {k: repair[k] for k in ("step", "mode", "reason", "clean", "round", "repeat_outer")}
        if pair.get("execution"):
            brief["pair_review"]["execution"] = {"remaining": pair["execution"]["remaining"],
                "completed": len(pair["execution"]["resolutions"]), "reports": len(pair["execution"]["reports"])}
    brief["pair_clean"] = state.get("pair_clean")
    brief["pair_completed"] = list(state.get("pair_completed", {}))
    final = state.get("final_review")
    if final:
        brief["final_review"] = {"round": final["round"], "step": final["step"],
                                 "completed_inspections": len(final.get("scans", [])),
                                 "confirmed_blockers": sum(bool(row.get("blocking")) for row in final.get("confirmed", [])),
                                 "cleanup_closed": len(final.get("confirmed", [])) if final.get("cleanup") else 0,
                                 "backlog": str(store.directory / "backlog.json")}
    active = read_json(store.directory / "active.json")
    live = runtime_active(store)
    progress = read_json(store.directory / "progress.json")
    if progress and (not active or progress.get("run_nonce") != active.get("nonce")):
        progress = None
    brief.update(running=live, active=active, progress=progress,
                 stop_request=read_json(store.directory / "stop.json"),
                 pause_switch=(store.root / ".work" / "PAUSE").exists())
    if progress:
        progress["age_seconds"] = max(0, int(time.time() - progress["updated"]))
        progress["live"] = live and not active.get("finished") and progress["age_seconds"] <= 30
        progress["stale"] = not progress["live"]
    from focus_status import build_panel
    brief.update(task=state.get("task"), review_events=state.get("display_review_events", []),
                 quota_wait=(state.get("pending") or {}).get("quota_wait"),
                 transient_wait=(state.get("pending") or {}).get("transient_wait"),
                 dashboard=list(build_panel(state, progress if progress and progress["live"] else None,
                                            paused=not live).lines))
    if state.get("baseline", {}).get("repositories"):
        brief.update(repositories=state["baseline"]["repositories"],
                     publication_repositories=state.get("publication_repositories", {}))
        brief["pause_switch"] = brief["pause_switch"] or any(
            (store.root / name / ".work" / "PAUSE").exists() for name in state["baseline"]["repositories"])
    return brief


def container_identity(active):
    run_id, cli = active.get("processkit_run_id", ""), active.get("processkit_cli", "")
    if re.fullmatch(r"orchestra-(?:focus|cycle|focus-provider)-[0-9a-f]{32}", run_id) and Path(cli).is_absolute():
        return cli, run_id
    return None


def provider_records(active):
    return ([active["provider_run"]] if active.get("provider_run") else []) + list(active.get("provider_runs", {}).values())


def kill_provider(store, active, timeout=30):
    started = time.monotonic()
    stopped = True
    for provider in provider_records(active):
        identity = container_identity(provider)
        if not identity:
            stopped = False
            continue
        cli, run_id = identity
        remaining = None if timeout is None else max(.01, timeout - (time.monotonic() - started))
        command([cli, "kill", "--run-id", run_id], store.root,
                timeout=min(5, remaining) if remaining is not None else 5, check=False)
        try:
            wait_container(store, provider, None if timeout is None else max(.01, timeout - (time.monotonic() - started)))
        except Blocked:
            stopped = False
    return stopped


def wait_container(store, active, timeout=30):
    identity = container_identity(active)
    if identity:
        cli, run_id = identity
        limit = min(30, timeout) if timeout is not None else 30
        if limit <= 0:
            raise Blocked("stop-timeout", "Stop request remains active; container exit is not yet confirmed.")
        command([cli, "wait", "--run-id", run_id, "--timeout", f"{max(1, int(limit * 1000))}ms"], store.root, timeout=limit + 2)


def request_stop(store, now=False, timeout=None):
    """Wait for the addressed run, never redirect a stop to a newer invocation."""
    if not runtime_active(store):
        previous = read_json(store.directory / "active.json") or {}
        if previous.get("interactive") and provider_records(previous):
            if not now:
                raise Blocked("cleanup-incomplete", "A previous UI provider has unconfirmed cleanup. Use cc-focus stop --now; this is not a safe-stop acknowledgement.")
        else:
            print("cc-focus: no active processing; nothing was stopped.", flush=True)
            return 0
    with LocalLock(store.directory, "control.lock"):
        active = read_json(store.directory / "active.json")
        if (not active or active.get("root") != str(store.root)
                or not re.fullmatch(r"[0-9a-f]{32}", active.get("nonce", ""))):
            raise Blocked("unaddressable-run", "No current focus control identity. For a running legacy cc-cycle use cc-pause and wait, or Ctrl+C, before updating.")
        previous = read_json(store.directory / "stop.json")
        mode = "now" if now or (previous and previous.get("nonce") == active["nonce"] and previous.get("mode") == "now") else "safe"
        store.artifact("stop.json", encode({"nonce": active["nonce"], "mode": mode, "requested": time.time()}))
    print(f"cc-focus: requested {mode} stop; waiting for run {active['nonce'][:12]}. Ctrl+C stops only this wait.", flush=True)
    started, announced, killed, leaf_stopped = time.monotonic(), 0, False, False
    while True:
        current = read_json(store.directory / "active.json")
        done = read_json(store.directory / "runs" / (active["nonce"] + ".json"))
        held = runtime_active(store)
        remaining = None if timeout is None else timeout - (time.monotonic() - started)
        cleanup_pending = bool(done and done.get("interactive") and provider_records(done))
        if done and not cleanup_pending and (not held or (current and current.get("nonce") != active["nonce"])):
            # An idle terminal can outlive a processing epoch. The runtime lock
            # and lease are released; no provider remains in the parked UI.
            if not done.get("ui_parked"):
                wait_container(store, active, remaining)
            if mode == "safe" and done.get("status") not in ("paused", "complete", "blocked"):
                raise Blocked("stop-not-clean", "Processing ended before a safe-boundary acknowledgement; partial work is preserved for crash recovery.")
            print(f"cc-focus: stopped; phase={done.get('phase')} status={done.get('status')}. Run cc-focus to continue.", flush=True)
            return 0
        if not held and killed and leaf_stopped:
            print("cc-focus: emergency termination confirmed; partial work remains. Run cc-focus to recover.", flush=True)
            return 0
        if not held and not (mode == "now" and cleanup_pending):
            raise Blocked("stop-unconfirmed", "The runtime exited without an orderly acknowledgement. Work is preserved; resume with crash recovery, not a clean-stop assumption.")
        if current and current.get("nonce") != active["nonce"]:
            raise Blocked("stop-target-changed", "The addressed run has ended; a newer run was left untouched.")
        elapsed = time.monotonic() - started
        if timeout is not None and elapsed >= timeout:
            raise Blocked("stop-timeout", "Stop is still pending; the request was preserved. Use status or stop --now; no safe-stop acknowledgement was received.")
        if mode == "now" and not killed and elapsed >= 5:
            identity = container_identity(active)
            if not identity:
                raise Blocked("emergency-unavailable", "Cooperative stop is pending, but no contained run identity is available for emergency termination. Use Ctrl+C in the processing terminal.")
            cli, run_id = identity
            # A run ID is immutable and single-use. Never kill by PID, name or --all.
            # A parked terminal may resume inside the same root container. Hold
            # the identity lock through termination so this cannot kill its next epoch.
            with LocalLock(store.directory, "control.lock"):
                latest = read_json(store.directory / "active.json") or {}
                if latest.get("nonce") != active["nonce"]:
                    raise Blocked("stop-target-changed", "A newer processing epoch was left untouched.")
                if not latest.get("finished") or provider_records(latest):
                    command([cli, "kill", "--run-id", run_id], store.root, timeout=min(15, remaining) if remaining is not None else 15, check=False)
                    wait_container(store, active, None if timeout is None else timeout - (time.monotonic() - started))
                    killed = True
        if killed:
            # Freeze the spawning root first, then use its last durable leaf intent.
            # This also covers a weak process-group root whose leaf has its own group.
            latest = read_json(store.directory / "active.json") or active
            if latest.get("nonce") == active["nonce"]:
                leaf_stopped = kill_provider(store, latest, None if timeout is None else max(0.01, timeout - (time.monotonic() - started)))
        if elapsed - announced >= 15:
            progress = read_json(store.directory / "progress.json") or {}
            print(f"cc-focus: waiting {int(elapsed)}s for stop; phase={progress.get('phase', '?')} activity={progress.get('activity', 'no current event')}", flush=True)
            announced = elapsed
        time.sleep(0.5)
