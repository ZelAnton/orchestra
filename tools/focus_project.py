"""Project roots containing independent Git repositories and their ownership."""

import contextlib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath

from cycle_state import Blocked, Lease, LocalLock, Repository, Store, digest, encode
from focus_control import check_parked_provider, container_identity, read_json, runtime_active, wait_container


MANIFEST = "focus-project.json"


def repository_paths(root):
    manifest = root / MANIFEST
    if manifest.exists():
        try:
            if manifest.is_symlink() or manifest.stat().st_size > 65536:
                raise ValueError("manifest must be a regular file, at most 64 KiB")
            value = json.loads(manifest.read_text(encoding="utf-8"))
            if set(value) != {"version", "repositories"} or type(value["version"]) is not int or value["version"] != 1:
                raise ValueError("expected version 1 and repositories")
            paths = value["repositories"]
            if not isinstance(paths, list) or not 1 <= len(paths) <= 64:
                raise ValueError("repositories must contain 1 to 64 paths")
        except (OSError, ValueError, TypeError) as error:
            raise Blocked("project-manifest", f"Cannot read {MANIFEST}: {error}") from error
    else:
        paths = [p.name for p in root.iterdir() if (p / ".git").exists()]
    if len(paths) > 64:
        raise Blocked("project-manifest", "At most 64 repositories may belong to one focus project.")
    names, real_paths = [], set()
    for name in paths:
        if (not isinstance(name, str) or not name or "\\" in name or
                PurePosixPath(name).is_absolute() or
                any(part in ("", ".", "..", ".git", ".jj", ".work") for part in name.split("/"))):
            raise Blocked("project-manifest", "Repository paths must be relative directories inside the project.")
        path = root / name
        if (not path.resolve().is_relative_to(root) or path.resolve() == root or
                any(p.is_symlink() for p in [path, *path.parents] if p != root and p.is_relative_to(root)) or
                not (path / ".git").is_dir() or (path / ".git").is_symlink()):
            raise Blocked("project-layout", f"{name} must be an independent Git repository inside this project; symlinks and linked worktrees are not supported.")
        if path.resolve() in real_paths:
            raise Blocked("project-layout", "Duplicate repository paths are not allowed.")
        real_paths.add(path.resolve())
        names.append(name)
    names.sort()
    if any(b.startswith(a + "/") for a in names for b in names if a != b):
        raise Blocked("project-layout", "Repository roots must not overlap.")
    return names


def open_project(root):
    root = Path(root).resolve()
    if (root / ".git").exists():
        if (root / MANIFEST).exists():
            raise Blocked("project-layout", "A multi-repository project root must be outside its member repositories.")
        return Repository(root)
    names = repository_paths(root)
    return Project(root, names) if names else Repository(root)


class Project:
    def __init__(self, root, names):
        self.root = Path(root).resolve()
        self.repositories = {name: Repository(self.root / name) for name in names}

    def assert_main(self):
        if (self.root / ".git").exists() or repository_paths(self.root) != list(self.repositories):
            raise Blocked("project-layout-changed", "The project's repository membership changed; preserve the saved cycle and restore its layout.")
        if Repository(self.root).git("rev-parse", "--git-dir", check=False).returncode == 0:
            raise Blocked("project-layout", "A multi-repository project root must not be inside another Git repository.")
        for name, repo in self.repositories.items():
            try:
                repo.assert_main()
            except Blocked as error:
                raise Blocked(error.code, f"{name}: {error}") from error

    def validate_state(self, state):
        if state and state.get("baseline", {}).get("repositories") != list(self.repositories):
            raise Blocked("project-layout-changed", "Saved cycle belongs to a different repository set.")

    def owner(self, path):
        return next((name for name in self.repositories if path.startswith(name + "/")), None)

    def local_paths(self, name, paths):
        return [path[len(name) + 1:] for path in paths if self.owner(path) == name]

    def member_snapshot(self, name, snapshot):
        return {"head": snapshot["head"][name], "index": snapshot["index"][name],
                "files": {path[len(name) + 1:]: value for path, value in snapshot["files"].items()
                          if self.owner(path) == name}}

    def loose_files(self):
        files = {}
        members = {repo.root for repo in self.repositories.values()}
        for directory, dirs, names in os.walk(self.root, followlinks=False):
            parent = Path(directory)
            links = [name for name in dirs if (parent / name).is_symlink()]
            dirs[:] = [name for name in dirs if name not in links and name not in (".work", ".git", ".jj")
                       and parent / name not in members]
            for name in names + links:
                path = parent / name
                relative = path.relative_to(self.root).as_posix()
                if path.is_symlink():
                    files[relative] = "link:" + digest(os.fsencode(os.readlink(path)))
                elif path.is_file():
                    hasher = hashlib.sha256()
                    with path.open("rb") as stream:
                        for part in iter(lambda: stream.read(1024 * 1024), b""):
                            hasher.update(part)
                    files[relative] = ("x:" if path.stat().st_mode & 0o111 else "f:") + hasher.hexdigest()
                else:
                    raise Blocked("unsupported-path", f"Cannot seal project context: {relative}")
        return files

    def snapshot(self):
        self.assert_main()
        result = {"head": {}, "index": {}, "files": self.loose_files(), "repositories": list(self.repositories)}
        for name, repo in self.repositories.items():
            snapshot = repo.snapshot()
            result["head"][name], result["index"][name] = snapshot["head"], snapshot["index"]
            result["files"].update({name + "/" + path: value for path, value in snapshot["files"].items()})
        return result

    def dirty_paths(self):
        return sorted(name + "/" + path for name, repo in self.repositories.items() for path in repo.dirty_paths())

    def index_entries(self, paths):
        return {name + "/" + path: value for name, repo in self.repositories.items()
                for path, value in repo.index_entries(self.local_paths(name, paths)).items()}

    def paused(self):
        return (self.root / ".work" / "PAUSE").exists() or any(repo.paused() for repo in self.repositories.values())


def check_project_owner(store, admitted_parent=None, record=None):
    """A crashed parent must not free a child while its provider still runs."""
    record = read_json(store.directory / "project-owner.json") if record is None else record
    if not record:
        return
    try:
        parent = Path(record["root"]).resolve()
        if parent == store.root or not store.root.is_relative_to(parent):
            raise ValueError("invalid parent project")
        parent_store = Store(parent)
        active = read_json(parent_store.directory / "active.json")
    except (KeyError, TypeError, ValueError) as error:
        raise Blocked("project-owner", f"Invalid project ownership record: {error}") from error
    if parent != admitted_parent and runtime_active(parent_store):
        raise Blocked("cycle-active", f"This repository belongs to the running project at {parent}. Use cc-focus there.")
    if active and active.get("provider_run"):
        provider = active["provider_run"]
        if not container_identity(provider):
            raise Blocked("cleanup-incomplete", f"Provider exit is unconfirmed for project {parent}.")
        try:
            wait_container(parent_store, provider, timeout=1)
        except Blocked as error:
            raise Blocked("cleanup-incomplete", f"Confirm provider cleanup at project {parent} before starting a member repository.") from error


def project_owner_status(store):
    record = read_json(store.directory / "project-owner.json")
    if not record:
        return None
    try:
        check_project_owner(store, record=record)
    except Blocked as error:
        if error.code not in ("cycle-active", "cleanup-incomplete"):
            raise
        return {"status": "project-owned", "project_root": record["root"],
                "detail": str(error)}
    return None


def lock_members(project, stack):
    fds = []
    if isinstance(project, Project):
        for repo in project.repositories.values():
            store = Store(repo.root)
            lock = stack.enter_context(LocalLock(store.directory))
            check_project_owner(store, project.root)
            check_parked_provider(store)
            fds.append(lock.stream.fileno())
    return fds


def register_members(project, control, stack):
    if not isinstance(project, Project):
        return
    record = {"root": str(project.root), "nonce": control.active["nonce"]}
    for repo in project.repositories.values():
        store = Store(repo.root)
        store.artifact("project-owner.json", encode(record))
        def release(store=store):
            if (control.active.get("finished") and not control.active.get("provider_run")
                    and read_json(store.directory / "project-owner.json") == record):
                (store.directory / "project-owner.json").unlink()
        stack.callback(release)


class ProjectLease:
    def __init__(self, project, scripts, state, save):
        self.project, self.scripts, self.state, self.save = project, scripts, state, save
        self.stack = contextlib.ExitStack()
        self.leases = []

    def __enter__(self):
        try:
            parent = self.stack.enter_context(Lease(self.project.root, self.scripts, self.state, self.save))
            self.leases.append(parent)
            self.pwsh = parent.pwsh
            for name, repo in self.project.repositories.items():
                state = self.state.setdefault("repository_leases", {}).setdefault(name, {})
                lease = Lease(repo.root, self.scripts, state, lambda _: self.save(self.state))
                self.leases.append(self.stack.enter_context(lease))
            return self
        except BaseException:
            self.stack.close()
            raise

    def heartbeat(self):
        for lease in self.leases:
            lease.heartbeat()

    def __exit__(self, *args):
        return self.stack.__exit__(*args)
