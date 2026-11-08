"""Project roots containing independent Git repositories and their ownership."""

import contextlib
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import posixpath

from cycle_state import Blocked, Lease, LocalLock, Repository, Store, digest, encode
from focus_control import check_parked_provider, container_identity, read_json, runtime_active, wait_container
from focus_resolve import check_resolvers


MANIFEST = "focus-project.json"
# Version 1 of the instruction list. Saved reader prompts contain the list, so a change
# of the names, the depth, or the entries needs a new project_instructions_version.
INSTRUCTION_NAMES = ("AGENTS.md", "CLAUDE.md", ".claude/CLAUDE.md")
LINK_DEPTH = 40  # A longer link chain or a loop gives no target.


def instruction_entries(repositories, kind, link):
    """The instruction files of the project root and of each member, with project-relative paths.

    KIND gives "f", "x", "link" or None for a path. LINK gives the text of a link, or None.
    A relative link to a regular file of the same source gets its target. Other links are left out.
    """
    entries = []
    for repository in (None, *repositories):
        for name in INSTRUCTION_NAMES:
            path = name if repository is None else repository + "/" + name
            entry = {"path": path, "repository": repository}
            if kind(path) == "link":
                target = link_target(path, kind, link)
                if target is None:
                    continue
                entry["target"] = target
            elif kind(path) not in ("f", "x"):
                continue
            entries.append(entry)
    return entries


def link_target(path, kind, link):
    for _ in range(LINK_DEPTH):
        text = link(path)
        if text and os.name == "nt":
            text = text.replace("\\", "/")  # Windows gives a relative link with backslashes.
        if not text or text.startswith("/") or "\\" in text or (os.name == "nt" and ":" in text):
            return None
        try:
            text.encode("utf-8")
        except UnicodeEncodeError:
            return None  # A prompt holds only UTF-8 text.
        path = posixpath.normpath(posixpath.join(posixpath.dirname(path), text))
        if path == ".." or path.startswith("../"):
            return None
        if kind(path) in ("f", "x"):
            return path
        if kind(path) != "link":
            return None
    return None


def read_manifest(root):
    """The checked manifest value, or None for a project without a manifest."""
    manifest = Path(root) / MANIFEST
    if not manifest.exists():
        return None
    try:
        if manifest.is_symlink() or manifest.stat().st_size > 65536:
            raise ValueError("manifest must be a regular file, at most 64 KiB")
        value = json.loads(manifest.read_text(encoding="utf-8"))
        # An older runtime rejects the parallel and resolvers keys, so it cannot ignore their rules.
        if (not isinstance(value, dict) or not {"version", "repositories"} <= set(value)
                or set(value) - {"version", "repositories", "parallel", "resolvers"}
                or type(value["version"]) is not int or value["version"] != 1):
            raise ValueError("expected version 1, repositories, an optional parallel list, and optional resolvers")
        paths = value["repositories"]
        if not isinstance(paths, list) or not 1 <= len(paths) <= 64:
            raise ValueError("repositories must contain 1 to 64 paths")
        parallel = value.get("parallel", [])
        if (not isinstance(parallel, list) or any(not isinstance(name, str) for name in parallel)
                or len(set(parallel)) != len(parallel) or not set(parallel) <= set(p for p in paths if isinstance(p, str))):
            raise ValueError("parallel must list repositories of the manifest, each one time")
        if "resolvers" in value:
            value["resolvers"] = check_resolvers(value["resolvers"], parallel)
    except (OSError, ValueError, TypeError) as error:
        raise Blocked("project-manifest", f"Cannot read {MANIFEST}: {error}") from error
    return value


def parallel_members(root):
    """The member repositories with parallel writers. A project without the key has none."""
    return parallel_config(root)[0]


def parallel_config(root):
    """The parallel members and their resolvers from one read of the manifest. A stage saves both together."""
    value = read_manifest(root) or {}
    return sorted(value.get("parallel", [])), value.get("resolvers", {})


def repository_paths(root):
    value = read_manifest(root)
    if value is not None:
        paths = value["repositories"]
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
        # The manifest values at admission. A stage records its own values in state["parallel"] and state["resolvers"].
        self.parallel, self.resolvers = parallel_config(self.root)

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

    def instruction_entries(self):
        """The instruction files on disk. A frozen review view lists its own files with the same rules.

        A file that Git ignores is on disk, but no view contains it.
        """
        def link(relative):
            try:
                return os.readlink(self.root / relative)
            except OSError:
                return None
        return instruction_entries(self.repositories, self.source_kind, link)

    def source_kind(self, relative):
        """The kind of a project file, with the kinds of a frozen view. A file in .git, .jj, .work,
        or below a linked directory has None, as in a view."""
        if any(part in (".git", ".jj", ".work") for part in relative.split("/")):
            return None
        path = self.root / relative
        # A view contains no file below a linked directory.
        if any(parent.is_symlink() for parent in path.parents if parent != self.root and parent.is_relative_to(self.root)):
            return None
        if path.is_symlink():
            return "link"
        if path.is_file():
            return "x" if path.stat().st_mode & 0o111 else "f"
        return None

    def local_paths(self, name, paths):
        return [path[len(name) + 1:] for path in paths if self.owner(path) == name]

    def member_snapshot(self, name, snapshot):
        return {"head": snapshot["head"][name], "index": snapshot["index"][name],
                "files": {path[len(name) + 1:]: value for path, value in snapshot["files"].items()
                          if self.owner(path) == name}}

    def handoff_sources(self, state):
        """Imported loose files are disposable inputs, not live project documents."""
        sources = set()
        plan = (state.get("task") or {}).get("plan")
        for handoff in state.get("handoffs", []):
            if not isinstance(handoff.get("source"), str):
                continue
            source = Path(handoff["source"])
            if not source.is_absolute() or not source.is_relative_to(self.root):
                continue
            relative = source.relative_to(self.root)
            name = relative.as_posix()
            if (not relative.parts or any(part in ("..", ".git", ".work") for part in relative.parts)
                    or self.owner(name) is not None or name == plan
                    or relative.name.casefold() in ("agents.md", "claude.md", "plan.md", MANIFEST.casefold())):
                continue
            sources.add(name)
        return sources

    def loose_files(self, exclude_context=()):
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
                if relative in exclude_context:
                    continue
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

    def snapshot(self, exclude_context=()):
        self.assert_main()
        result = {"head": {}, "index": {}, "files": self.loose_files(exclude_context), "repositories": list(self.repositories)}
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
