"""Durable local state and read-only Git evidence for the sequential cycle."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time
import uuid


REMOTE_QUERY_BLOCKERS = frozenset(("remote-query-timeout", "remote-query-failed"))
REMOTE_QUERY_ATTEMPTS = 3
REMOTE_QUERY_TIMEOUT = 60


class Blocked(RuntimeError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


class ProviderQuota(Blocked):
    """A protocol-confirmed refusal with a server-advertised reset, not a report."""
    def __init__(self, resets_at, no_work=False):
        self.resets_at, self.no_work = resets_at, no_work
        reset = time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(resets_at))
        super().__init__("claude-quota", f"Claude quota rejected; advertised reset: {reset}.")


def digest(value):
    return hashlib.sha256(value).hexdigest()


def encode(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")


def atomic_write(path, data):
    """Flush the file before rename, then the directory where supported."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        if os.name != "nt":
            directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(directory)
            finally:
                os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def command(argv, cwd, timeout=60, check=True, env=None):
    try:
        result = subprocess.run(argv, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                timeout=timeout, check=False, env=env)
    except subprocess.TimeoutExpired as error:
        # TimeoutExpired includes argv, which can contain a credential-bearing URL.
        raise Blocked("command-timeout", f"{argv[0]} timed out after {timeout} seconds.") from error
    except OSError as error:
        raise Blocked("command-unavailable", f"{argv[0]}: {error}") from error
    if check and result.returncode:
        raise Blocked("command-failed", f"{argv[0]} {' '.join(argv[1:3])}: "
                      + result.stderr.decode("utf-8", errors="replace")[-4000:])
    return result


class Repository:
    def __init__(self, root):
        self.root = Path(root).resolve()

    def git(self, *args, check=True):
        return command(["git", *args], self.root, check=check)

    def text(self, *args):
        return self.git(*args).stdout.decode("utf-8").strip()

    def assert_main(self):
        top = self.git("rev-parse", "--show-toplevel", check=False)
        if top.returncode:
            detail = top.stderr.decode("utf-8", errors="replace")[-2000:].strip()
            raise Blocked("repository-unavailable", f"Cannot open a Git repository at {self.root}. "
                          "Run cc-focus from one existing repository's root on branch main. "
                          "--handoff imports context; it does not select or create a repository.\n" + detail)
        if Path(top.stdout.decode("utf-8").strip()).resolve() != self.root:
            raise Blocked("wrong-root", "Run cc-focus at the repository root.")
        branch = self.git("symbolic-ref", "--quiet", "--short", "HEAD", check=False)
        if branch.returncode == 1:
            raise Blocked("wrong-branch", "HEAD is detached. cc-focus requires the existing Git main checkout; "
                          "detached colocated Jujutsu checkouts are not supported. No checkout was changed.")
        if branch.returncode:
            raise Blocked("repository-unavailable", "Cannot determine the current Git branch: "
                          + branch.stderr.decode("utf-8", errors="replace")[-2000:].strip())
        if branch.stdout.decode("utf-8").strip() != "main":
            raise Blocked("wrong-branch", "cc-focus requires the existing main checkout; no branch is created.")
        gitdir = Path(self.text("rev-parse", "--absolute-git-dir"))
        if (gitdir / "commondir").exists():
            raise Blocked("unsupported-checkout", "Use the primary Git main checkout, not a linked worktree.")
        for name in ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply"):
            if (gitdir / name).exists():
                raise Blocked("vcs-operation", f"Finish the existing Git operation first: {name}")
        if self.text("ls-files", "--unmerged"):
            raise Blocked("vcs-conflict", "The index contains unresolved conflicts.")

    @staticmethod
    def runtime_path(name):
        return (name == ".work/PAUSE" or name.startswith((
            ".work/cycle/", ".work/orchestrator.lock/", ".work/processes/"))
            or name in (".work/state-tx.lock", ".work/control_state.json"))

    def snapshot(self):
        self.assert_main()
        files = {}
        paths = self.git("ls-files", "-z", "--cached", "--others", "--exclude-standard").stdout
        for raw in sorted(set(paths.split(b"\0")) - {b""}):
            name = os.fsdecode(raw)
            if self.runtime_path(name):
                continue
            path = self.root / name
            if path.is_symlink():
                files[name] = "link:" + digest(os.fsencode(os.readlink(path)))
            elif not path.exists():
                continue
            elif path.is_file():
                hasher = hashlib.sha256()
                with path.open("rb") as stream:
                    for part in iter(lambda: stream.read(1024 * 1024), b""):
                        hasher.update(part)
                files[name] = ("x:" if path.stat().st_mode & 0o111 else "f:") + hasher.hexdigest()
            else:
                raise Blocked("unsupported-path", f"Cannot seal directory/submodule: {name}")
        return {"head": self.text("rev-parse", "HEAD"), "files": files,
                "index": digest(self.git("diff", "--cached", "--binary", "--no-ext-diff").stdout)}

    def dirty_paths(self):
        tracked = self.git("diff", "HEAD", "--name-only", "-z", "--no-renames").stdout
        others = self.git("ls-files", "--others", "--exclude-standard", "-z").stdout
        return sorted({os.fsdecode(p) for p in (tracked + others).split(b"\0")
                       if p and not self.runtime_path(os.fsdecode(p))})

    def index_entries(self, names):
        wanted, entries = set(names), {}
        for raw in self.git("ls-files", "--stage", "-z").stdout.split(b"\0"):
            if not raw:
                continue
            metadata, name = raw.split(b"\t", 1)
            decoded = os.fsdecode(name)
            if decoded in wanted:
                entries[decoded] = metadata.decode("ascii")
        return entries

    def paused(self):
        return (self.root / ".work" / "PAUSE").exists()

    def remote(self):
        remote = self.git("config", "--get", "branch.main.remote", check=False).stdout.decode().strip()
        merge = self.git("config", "--get", "branch.main.merge", check=False).stdout.decode().strip()
        if not remote or remote == "." or merge != "refs/heads/main":
            raise Blocked("missing-upstream", "Configure main's remote upstream to refs/heads/main before publication.")
        return remote

    def remote_head(self, remote, progress=None):
        url = self.push_url(remote)
        # Keep existing credential helpers, but do not wait for terminal/GCM login.
        # These settings affect only this read-only query, never provider commands.
        env = dict(os.environ, GIT_TERMINAL_PROMPT="0", GCM_INTERACTIVE="Never", LC_ALL="C")
        for attempt in range(1, REMOTE_QUERY_ATTEMPTS + 1):
            if progress:
                progress(attempt, REMOTE_QUERY_ATTEMPTS)
            try:
                result = command(["git", "ls-remote", "--refs", url, "refs/heads/main"],
                                 self.root, timeout=REMOTE_QUERY_TIMEOUT, check=False, env=env)
            except Blocked as error:
                if error.code != "command-timeout":
                    raise
                code = "remote-query-timeout"
                detail = f"Git ls-remote timed out after {REMOTE_QUERY_TIMEOUT} seconds."
                retryable = True
            else:
                if not result.returncode:
                    break
                code = "remote-query-failed"
                detail = result.stderr.decode("utf-8", errors="replace").replace(url, "<push URL>")[-4000:]
                retryable = any(text in detail.lower() for text in (
                    "could not resolve host", "could not resolve proxy", "could not resolve hostname",
                    "temporary failure in name resolution", "failed to connect", "connection timed out",
                    "connection reset", "connection refused", "operation timed out",
                    "the requested url returned error: 502", "the requested url returned error: 503",
                    "the requested url returned error: 504"))
            if not retryable or attempt == REMOTE_QUERY_ATTEMPTS:
                raise Blocked(code, f"Cannot verify remote main at the configured push URL "
                              f"({attempt}/{REMOTE_QUERY_ATTEMPTS} attempts). {detail}\n"
                              "Check network/proxy access and Git credentials in the launcher environment, "
                              "then run cc-focus --retry. Publication is unconfirmed; saved work and reviews are preserved.")
            time.sleep(2)
        lines = result.stdout.decode("utf-8").strip().splitlines()
        if len(lines) != 1:
            raise Blocked("remote-main", "Remote main is missing or ambiguous.")
        return lines[0].split()[0]

    def push_url(self, remote):
        urls = self.text("remote", "get-url", "--push", "--all", remote).splitlines()
        if len(urls) != 1:
            raise Blocked("ambiguous-push", "cc-focus requires exactly one push URL for the selected remote.")
        return urls[0]


def changed(before, after):
    return sorted(name for name in set(before["files"]) | set(after["files"])
                  if before["files"].get(name) != after["files"].get(name))


class Store:
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.directory = self.root / ".work" / "cycle"
        if not self.directory.resolve().is_relative_to(self.root):
            raise Blocked("external-state-path", "The cycle state directory resolves outside the repository.")
        self.path = self.directory / "state.json"

    def read(self):
        if not self.path.exists():
            return None
        try:
            envelope = json.loads(self.path.read_text(encoding="utf-8"))
            state = envelope["state"]
            if envelope["sha256"] != digest(encode(state)) or state["version"] != 1:
                raise ValueError("checksum/schema mismatch")
            if Path(state["root"]).resolve() != self.root:
                raise ValueError("state belongs to a different repository; import a handoff into fresh local state")
            return state
        except (ValueError, KeyError, TypeError) as error:
            raise Blocked("invalid-state", f"Preserved invalid state at {self.path}: {error}") from error

    def save(self, state):
        state["updated"] = time.time()
        atomic_write(self.path, encode({"state": state, "sha256": digest(encode(state))}) + b"\n")

    def artifact(self, relative, data):
        path = self.directory / relative
        atomic_write(path, data)
        return str(path)

    def handoff(self, source):
        source = Path(source).resolve(strict=True)
        data = source.read_bytes()
        if len(data) > 4 * 1024 * 1024 or not data.decode("utf-8-sig").strip():
            raise Blocked("invalid-handoff", "Handoff must be nonempty UTF-8, at most 4 MiB.")
        name = f"handoffs/{digest(data)}.md"
        self.artifact(name, data)
        return {"path": str(self.directory / name), "sha256": digest(data), "source": str(source)}


class LocalLock:
    """OS lock, never delete-and-recreate. POSIX provider children inherit it."""
    def __init__(self, directory, name="runtime.lock", existing=False):
        self.directory = Path(directory)
        self.name, self.existing = name, existing
        self.stream = None

    def __enter__(self):
        if not self.existing:
            self.directory.mkdir(parents=True, exist_ok=True)
        self.stream = (self.directory / self.name).open("r+b" if self.existing else "a+b")
        try:
            if os.name == "nt":
                import msvcrt
                if not self.existing and self.stream.tell() == 0:
                    self.stream.write(b"\0")
                    self.stream.flush()
                self.stream.seek(0)
                msvcrt.locking(self.stream.fileno(), msvcrt.LK_NBLCK, 1)
            else:
                import fcntl
                fcntl.flock(self.stream.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self.stream.close()
            raise Blocked("cycle-active", f"Another owner holds {self.name}; a provider may still be running.") from error
        return self

    def __exit__(self, *_):
        self.stream.close()


class Lease:
    def __init__(self, root, scripts, state, save):
        self.root, self.scripts = Path(root), Path(scripts)
        self.state, self.save = state, save
        self.owner = uuid.uuid4().hex
        self.last_heartbeat = 0
        self.held = False
        self.pwsh = os.environ.get("ORCHESTRA_CYCLE_PWSH") or shutil.which("pwsh") or shutil.which("powershell.exe")
        if not self.pwsh:
            raise Blocked("missing-powershell", "PowerShell is required for the shared processor lease.")

    def run(self, *args, check=True):
        return command([self.pwsh, "-NoProfile", "-File", str(self.scripts / "state-tx.ps1"),
                        *args, "--work", str(self.root / ".work")], self.root, check=check)

    def __enter__(self):
        previous_owners = self.state.get("lease_owners", [])
        if self.state.get("lease_owner"):
            previous_owners = list(set(previous_owners + [self.state["lease_owner"]]))
        self.state["lease_owners"] = previous_owners + [self.owner]
        self.save(self.state)  # Recover the acquire/save crash window by owner intent.
        args = ["--root", str(self.root), "--role", "processor", "--owner", self.owner,
                "--session", "cc-focus", "--pid", str(os.getpid())]
        result = self.run("acquire", *args, check=False)
        if result.returncode == 11:
            lease_path = self.root / ".work" / "orchestrator.lock" / "lease.json"
            existing = json.loads(lease_path.read_text(encoding="utf-8-sig"))
            if existing.get("owner_id") in previous_owners:
                result = self.run("takeover", *args, "--require-root", str(self.root),
                                  "--require-role", "processor", "--require-owner", existing["owner_id"], check=False)
        if result.returncode:
            raise Blocked("lease-unavailable", result.stderr.decode("utf-8", errors="replace")[-3000:])
        self.held = True
        try:
            self.state["lease_owner"] = self.owner
            self.state["lease_owners"] = [self.owner]
            self.save(self.state)
        except BaseException:
            self.run("release", "--owner", self.owner)
            raise
        self.last_heartbeat = time.monotonic()
        return self

    def heartbeat(self):
        if time.monotonic() - self.last_heartbeat >= 60:
            self.run("heartbeat", "--owner", self.owner)
            self.last_heartbeat = time.monotonic()

    def __exit__(self, *_):
        if self.held:
            self.run("release", "--owner", self.owner)
