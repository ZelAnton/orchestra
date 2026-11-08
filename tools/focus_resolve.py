"""Merge resolvers of parallel members: operator commands that resolve text conflicts before a push.

The root manifest names the commands, for example a generator of fixture files. A command runs in a
temporary linked worktree with the merged tree, so the member checkout does not change. The runtime
checks the result after each command. Every other conflict still stops the stage.
"""

import os
from pathlib import Path
import re
import shlex
import shutil
import stat
import subprocess
import sys
import uuid

from cycle_state import Blocked, atomic_write, command, encode

TIMEOUT, TIMEOUTS = 1800, (60, 7200)  # Seconds of one command.
RULES, PATTERNS = 16, 16
CLEANUP_LIMIT = 3  # More worktrees that the runtime could not remove stop the next resolution.
TEXT_MODES = ("100644", "100755")
# With these attributes, the repository form of a file is not its text, or Git changes the text at a checkout.
ATTRIBUTES = ("filter", "working-tree-encoding", "ident")
NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}")
# A marker line starts with seven or more "<", "|", or ">" characters and a space. Text formats use "=" lines.
MARKER = re.compile(rb"^(?:<{7,}|\|{7,}|>{7,}) ", re.M)
OPERATION_STATE = ("MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "BISECT_LOG",
                   "rebase-merge", "rebase-apply", "sequencer")
# A temporary worktree adds its prefix to each path. Git on Windows then needs long paths.
LONG_PATHS = ("-c", "core.longpaths=true") if os.name == "nt" else ()
WORKTREE = re.compile(r"[0-9a-f]{8}")
# These variables select another repository. A resolver must use its worktree.
REPOSITORY_VARIABLES = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
                        "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR", "GIT_NAMESPACE")


# The manifest.

def check_pattern(pattern):
    """The matcher of one pattern. ValueError refuses every syntax outside the subset of the manifest."""
    if not isinstance(pattern, str) or not pattern:
        raise ValueError("each pattern must be a non-empty string")
    if any(char in pattern for char in "[]\\\0") or pattern.startswith("!"):
        raise ValueError(f"pattern {pattern!r} uses brackets, a backslash, or a ! at the start")
    parts = pattern.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise ValueError(f"pattern {pattern!r} has an empty part, a . or .. part, or a / at the start or the end")
    if any("**" in part and part != "**" for part in parts):
        raise ValueError(f"pattern {pattern!r} has ** inside a part")

    def part(text):
        return "".join("[^/]*" if char == "*" else "[^/]" if char == "?" else re.escape(char) for char in text)
    if len(parts) == 1:
        # A pattern without a slash matches the file name at any depth.
        return re.compile("(?:.*/)?" + ("[^/]*" if pattern == "**" else part(pattern)))
    regex = ""
    for index, text in enumerate(parts):
        last = index == len(parts) - 1
        if text == "**":
            # A last ** matches everything inside the directory. Another ** matches zero or more directories.
            regex += ".+" if last else "(?:[^/]+/)*"
        else:
            regex += part(text) + ("" if last else "/")
    return re.compile(regex)


def matches(pattern, path):
    return check_pattern(pattern).fullmatch(path) is not None


def check_process(value, where):
    argv = value["command"]
    if not isinstance(argv, list) or not argv or not argv[0] or any(not isinstance(item, str) or "\0" in item
                                                                     for item in argv):
        raise ValueError(f"{where}.command must be a non-empty list of strings")
    timeout = value.get("timeout", TIMEOUT)
    if type(timeout) is not int or not TIMEOUTS[0] <= timeout <= TIMEOUTS[1]:
        raise ValueError(f"{where}.timeout must be {TIMEOUTS[0]} to {TIMEOUTS[1]} seconds")
    return {"command": list(argv), "timeout": timeout}


def check_resolvers(resolvers, parallel):
    """The checked resolvers of the manifest, with the default timeouts. ValueError names the first problem."""
    if not isinstance(resolvers, dict) or not set(resolvers) <= set(parallel):
        raise ValueError("resolvers must map parallel members to their rules")
    checked = {}
    for member, entry in resolvers.items():
        where = "resolvers." + member
        if not isinstance(entry, dict) or "rules" not in entry or set(entry) - {"rules", "check"}:
            raise ValueError(f"{where} must have rules and an optional check")
        rules = entry["rules"]
        if not isinstance(rules, list) or not 1 <= len(rules) <= RULES:
            raise ValueError(f"{where}.rules must contain 1 to {RULES} rules")
        names, result = set(), {"rules": [], "check": None}
        for rule in rules:
            if (not isinstance(rule, dict) or not {"name", "paths", "command"} <= set(rule)
                    or set(rule) - {"name", "paths", "command", "timeout"}):
                raise ValueError(f"each rule of {where} must have name, paths, command, and an optional timeout")
            name = rule["name"]
            if not isinstance(name, str) or not NAME.fullmatch(name) or name in names:
                raise ValueError(f"{where}: each rule name must be a unique short identifier")
            names.add(name)
            paths = rule["paths"]
            if not isinstance(paths, list) or not 1 <= len(paths) <= PATTERNS:
                raise ValueError(f"{where}.{name}.paths must contain 1 to {PATTERNS} patterns")
            for pattern in paths:
                check_pattern(pattern)
            result["rules"].append({"name": name, "paths": list(paths), **check_process(rule, f"{where}.{name}")})
        if "check" in entry:
            check = entry["check"]
            if not isinstance(check, dict) or "command" not in check or set(check) - {"command", "timeout"}:
                raise ValueError(f"{where}.check must have a command and an optional timeout")
            result["check"] = check_process(check, where + ".check")
        checked[member] = {key: value for key, value in result.items() if value is not None}
    return checked


# Messages.

def shell(parts):
    return subprocess.list2cmdline(parts) if os.name == "nt" else " ".join(shlex.quote(part) for part in parts)


def listing(paths, limit=20):
    return ", ".join(paths[:limit]) + (f", and {len(paths) - limit} more" if len(paths) > limit else "")


def manual_merge(repo, head):
    return (f"in another clone, run {shell(('git', 'fetch', str(repo.root), head))}, merge FETCH_HEAD into main, "
            "and push the merge")


def conflict(cycle, name, repo, base, head, paths, uncovered=(), resolvers=False):
    """The parallel-merge-conflict stop. With RESOLVERS, UNCOVERED names the paths that no resolver can resolve."""
    command_text = shell(("git", "-C", str(repo.root), "diff", base[:12], head[:12], "--", *paths[:5]))
    where = listing(paths) if paths else "paths that Git does not name"
    note = (f" No resolver of focus-project.json can resolve {listing(list(uncovered)) or 'this conflict'}. "
            "No rule covers such a path, or its conflict is not a text conflict of one file. "
            "A filter, working-tree-encoding, or ident attribute also stops a resolver." if resolvers else "")
    return Blocked("parallel-merge-conflict", f"{name}: remote main conflicts with the stage commits in "
                   f"{where}.{note} Read the stage change with {command_text}. "
                   f"Change remote main in another clone so that it does not conflict. Or, {manual_merge(repo, head)}. "
                   f"Then run {cycle.retry_command()}.")


def failed(cycle, name, repo, head, detail, log):
    return Blocked("parallel-resolver-failed", f"{name}: {detail}. Read the log {log}. "
                   "Correct the resolver on remote main in another clone. The next attempt then uses it. "
                   "A change of a timeout in focus-project.json applies at the next stage. "
                   f"Or, {manual_merge(repo, head)}. Then run {cycle.retry_command()}.")


def scope(cycle, name, detail, paths):
    return Blocked("parallel-resolver-scope", f"{name}: {detail}: {listing(paths)}. "
                   "Correct the resolver on remote main in another clone, or undo the change of these paths. "
                   f"Then run {cycle.retry_command()}.")


# Git values.

def git(path, *args, data=None):
    """A Git command in the repository or the worktree at PATH. No hook runs for these commands."""
    try:
        result = subprocess.run(["git", "--literal-pathspecs", *LONG_PATHS, "-C", str(path), *args], cwd=path,
                                input=data if data is not None else b"", stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=300, check=False)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise Blocked("publication-git", f"git {args[0]} failed in {Path(path).name}: {type(error).__name__}") from error
    if result.returncode:
        raise Blocked("publication-git", f"git {args[0]} failed in {Path(path).name}: "
                      + result.stderr.decode("utf-8", errors="replace")[-2000:])
    return result.stdout


def conflict_entries(output):
    """The tree and the conflict entries of merge-tree --write-tree -z: {path: {stage: (mode, object)}}."""
    fields = output.split(b"\0")
    entries = {}
    for field in fields[1:]:
        if not field:
            break  # Messages follow an empty field. --no-messages gives none.
        meta, path = field.split(b"\t", 1)
        mode, oid, stage = meta.decode("ascii").split()
        entries.setdefault(os.fsdecode(path), {})[int(stage)] = (mode, oid)
    return fields[0].decode("ascii"), entries


def message_paths(output):
    """The paths of the CONFLICT messages of merge-tree --write-tree -z. Git names some conflicts only there."""
    fields = output.split(b"\0")
    try:
        index = fields.index(b"", 1) + 1  # The messages follow the empty field after the conflict entries.
        paths = set()
        while index < len(fields) and fields[index]:
            count = int(fields[index])
            names = fields[index + 1:index + 1 + count]
            kind = fields[index + 1 + count]
            if kind.startswith(b"CONFLICT"):
                paths.update(os.fsdecode(name) for name in names)
            index += count + 3
        return sorted(paths)
    except (ValueError, IndexError):
        return []


def tree_entries(path, tree):
    """{path: (mode, object)} for each entry of TREE, read in the repository at PATH."""
    entries = {}
    for field in git(path, "ls-tree", "-r", "-z", "--full-tree", tree).split(b"\0"):
        if field:
            meta, name = field.split(b"\t", 1)
            mode, _, oid = meta.decode("ascii").split()
            entries[os.fsdecode(name)] = (mode, oid)
    return entries


def blob(path, oid):
    return git(path, "cat-file", "blob", oid)


def attributes(path, paths):
    """The paths with a filter, working-tree-encoding, or ident attribute in the checkout at PATH."""
    if not paths:
        return []
    output = git(path, "check-attr", "-z", "--stdin", *ATTRIBUTES,
                 data=b"".join(os.fsencode(name) + b"\0" for name in paths)).split(b"\0")
    found = {os.fsdecode(name) for name, _, value in zip(output[0::3], output[1::3], output[2::3])
             if value not in (b"unspecified", b"unset")}
    return sorted(found)


# Classification.

def classify(repo, rules, target, head, tree, entries):
    """The resolvable paths with their rule and blobs, and the paths that no rule can resolve.

    A path is resolvable only for a text conflict at one path: stage 2 is the entry in remote main R,
    stage 3 is the entry in the stage commit H, both are files, and Git wrote conflict markers.
    """
    remote, stage, merged = (tree_entries(repo.root, value) for value in (target, head, tree))
    filtered = set(attributes(repo.root, sorted(entries)))  # The member checkout is H.
    plan, uncovered = {}, []
    for path in sorted(entries):
        stages = entries[path]
        rule = next((rule for rule in rules if any(matches(pattern, path) for pattern in rule["paths"])), None)
        entry = merged.get(path)
        if (rule and 2 in stages and 3 in stages and all(mode in TEXT_MODES for mode, _ in stages.values())
                and remote.get(path) == stages[2] and stage.get(path) == stages[3]
                and entry and entry[0] in TEXT_MODES and MARKER.search(blob(repo.root, entry[1]))
                and path not in filtered):
            plan[path] = {"rule": rule["name"], "mode": entry[0], "blob": entry[1],
                          "base": stages.get(1, (None, None))[1], "remote": stages[2][1], "stage": stages[3][1]}
        else:
            uncovered.append(path)
    return plan, uncovered


# The temporary worktree.

def valid_worktree(cycle, path):
    path = Path(path)
    return path.parent == cycle.repo.root / ".work" / "r" and WORKTREE.fullmatch(path.name) is not None


def side_files(path):
    path = Path(path)
    return sorted(path.parent.glob(path.name + ".*")) if path.parent.is_dir() else []


def gone(path):
    path = Path(path)
    return not path.exists() and not path.is_symlink() and not side_files(path)


def delete(path):
    """Delete a directory of the runtime. Build tools can write read-only files and directories.

    A failed removal of an entry makes its parent writable, and also the entry when it is not a link.
    Then it tries one time again. Another failure stays, and the caller keeps a cleanup entry.
    """
    def writable(function, name, *_):
        if function not in (os.unlink, os.remove, os.rmdir):
            return  # For example os.open or os.scandir of a directory without access.
        try:
            # chmod follows a link, so a link target outside the worktree keeps its mode.
            for item in (os.path.dirname(name), *(() if os.path.islink(name) else (name,))):
                os.chmod(item, stat.S_IWRITE | stat.S_IREAD | stat.S_IEXEC)
            function(name)
        except Exception:
            pass
    if Path(path).is_symlink() or not Path(path).is_dir():
        Path(path).unlink(missing_ok=True)
    elif sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=writable)
    else:
        shutil.rmtree(path, onerror=writable)


def prune(repo):
    command(["git", "-C", str(repo.root), "worktree", "prune"], repo.root, timeout=120, check=False)


def remove_worktree(cycle, repo, path):
    """Remove a temporary worktree and its files. Return True when nothing remains.

    The runtime removes only its own directories. A path outside them counts as removed when it is gone.
    """
    path = Path(path)
    try:
        if not valid_worktree(cycle, path):
            if repo is not None and gone(path):
                prune(repo)
            return gone(path)
        if path.exists() and repo is not None:
            command(["git", *LONG_PATHS, "-C", str(repo.root), "worktree", "remove", "--force", str(path)],
                    repo.root, timeout=300, check=False)
        if path.exists() or path.is_symlink():
            delete(path)  # A worktree without its .git file is a plain directory.
        if repo is not None:
            prune(repo)
        for side in side_files(path):
            side.unlink(missing_ok=True)
    except Exception:
        return False  # A cleanup must not replace the original error. The caller keeps an entry.
    return gone(path)


def keep_cleanup(cycle, name, path):
    entries = cycle.state.setdefault("resolver_cleanup", [])
    if not any(entry["path"] == str(path) for entry in entries):
        entries.append({"member": name, "path": str(path)})


def retry_cleanup(cycle, stage_start=False):
    """Remove the worktrees that an earlier removal left. A failure keeps the entry and does not stop the run.

    An entry goes when its directory is gone, also when its member left the project. At a stage start, the
    runtime also removes the other directories in .work/r, for example of a completed review campaign.
    One runtime owns the project, so no other process uses them.
    """
    entries = cycle.state.get("resolver_cleanup") or []
    remaining = [entry for entry in entries
                 if not remove_worktree(cycle, cycle.repo.repositories.get(entry["member"]), entry["path"])]
    if any(entry["member"] not in cycle.repo.repositories for entry in entries if entry not in remaining):
        for repo in cycle.repo.repositories.values():
            prune(repo)  # The member of a removed entry is not known, so each member forgets its registration.
    if remaining != entries:
        if remaining:
            cycle.state["resolver_cleanup"] = remaining
        else:
            cycle.state.pop("resolver_cleanup")
        cycle.save()
    folder = cycle.repo.root / ".work" / "r"
    if not stage_start or not folder.is_dir():
        return
    known = {entry["path"] for entry in remaining} | {
        record.get("worktree") for record in cycle.state.get("parallel_integrations", {}).values()}
    found = set()
    for path in sorted(folder.iterdir()):
        worktree = folder / path.name.split(".", 1)[0]
        if WORKTREE.fullmatch(worktree.name) and str(worktree) not in known:
            try:
                delete(path)
            except Exception:
                pass  # The entry below keeps the directory for a later removal.
            found.add(worktree)
    for repo in cycle.repo.repositories.values() if found else ():
        prune(repo)
    left = [worktree for worktree in sorted(found) if not gone(worktree)]
    for worktree in left:
        keep_cleanup(cycle, None, worktree)  # Its member is not known. The status and the limit count it.
    if left:
        cycle.save()


def discard(cycle, name, repo, path):
    """Remove the worktree and the open record. A removal that fails keeps a cleanup entry."""
    if not remove_worktree(cycle, repo, path):
        keep_cleanup(cycle, name, path)
    cycle.state.get("parallel_integrations", {}).pop(name, None)
    cycle.save()


def check_cleanup(cycle):
    entries = cycle.state.get("resolver_cleanup", [])
    if len(entries) > CLEANUP_LIMIT:
        raise Blocked("parallel-resolver-cleanup", "These temporary merge worktrees could not be removed: "
                      f"{listing([entry['path'] for entry in entries])}. Stop the process that keeps their files. "
                      "Remove the directories, and run git worktree prune in their member repositories. "
                      f"Then run {cycle.retry_command()}.")


# The resolution.

def resolve(cycle, name, repo, base, target, head, tree, plan):
    """Resolve the conflicts of PLAN in a temporary worktree. Return the resolved tree T2 and the evidence.

    The record step "resolving" stays until the caller saves the integration. Every failure removes
    the worktree and the record before it raises.
    """
    retry_cleanup(cycle)
    check_cleanup(cycle)
    spec = cycle.state["resolvers"][name]
    folder = cycle.repo.root / ".work" / "r"
    folder.mkdir(parents=True, exist_ok=True)
    while True:
        worktree = folder / uuid.uuid4().hex[:8]
        if not worktree.exists() and not side_files(worktree):
            break
    cycle.state.setdefault("parallel_integrations", {})[name] = {
        "base": base, "upstream": target, "local": head, "tree": tree, "worktree": str(worktree),
        "resolved": {path: item["rule"] for path, item in plan.items()}, "result": None, "step": "resolving"}
    cycle.save()
    evidence = {"member": name, "base": base, "remote": target, "stage": head, "tree": tree,
                "worktree": str(worktree), "paths": plan, "runs": [], "resolver_files": {}}
    try:
        result = run_rules(cycle, name, repo, spec, plan, worktree, evidence)
    except BaseException as error:
        evidence["error"] = f"{type(error).__name__}: {error}"
        try:
            discard(cycle, name, repo, worktree)
        finally:
            save_evidence(cycle, evidence)
        raise
    if not remove_worktree(cycle, repo, worktree):
        keep_cleanup(cycle, name, worktree)  # T2 is in the object store, so the publication continues.
        cycle.save()
    evidence["result_tree"] = result
    return result, evidence


def save_evidence(cycle, evidence):
    try:
        return cycle.store.artifact(f"resolve/resolution-{uuid.uuid4().hex}.json", encode(evidence))
    except OSError:
        return None  # The evidence must not hide the error of the resolution.


def run_rules(cycle, name, repo, spec, plan, worktree, evidence):
    from focus_commit import run_git  # focus_project imports this module before focus_commit exists.
    base, target, head, tree = (evidence[key] for key in ("base", "remote", "stage", "tree"))
    run_git(cycle, "worktree", "add", "--no-checkout", "--detach", str(worktree), head, repo=repo, options=LONG_PATHS)
    run_git(cycle, "read-tree", "--reset", "-u", tree, repo=repo, cwd=worktree, options=LONG_PATHS)
    filtered = attributes(worktree, sorted(plan))  # The attribute files of T.
    if filtered:
        raise conflict(cycle, name, repo, base, head, sorted(plan), filtered, True)
    inputs = worktree.with_name(worktree.name + ".inputs.json")
    atomic_write(inputs, encode({"version": 1, "member": name, "base": base, "remote": target, "stage": head,
                                 "tree": tree, "paths": {path: {key: item[key] for key in ("rule", "mode", "base", "remote", "stage")}
                                                         for path, item in plan.items()}}))
    files = tree_entries(repo.root, tree)
    for step in (*spec["rules"], spec.get("check") or {}):
        for argument in step.get("command", [])[1:]:
            relative = argument.replace("\\", "/").removeprefix("./")
            if relative in files:
                evidence["resolver_files"][relative] = files[relative][1]
    env = {key: value for key, value in os.environ.items() if key not in REPOSITORY_VARIABLES}
    env.update(CC_FOCUS_MERGE_INPUTS=str(inputs), CC_FOCUS_MERGE_BASE=base, CC_FOCUS_MERGE_REMOTE=target,
               CC_FOCUS_MERGE_STAGE=head, CC_FOCUS_PROJECT_ROOT=str(cycle.repo.root))
    project = cycle.repo.snapshot()
    current = tree
    for index, rule in enumerate(spec["rules"]):
        paths = sorted(path for path, item in plan.items() if item["rule"] == rule["name"])
        if not paths:
            continue
        run_step(cycle, name, repo, head, "resolver " + rule["name"], rule, worktree, index, paths, env, evidence)
        result = stage(cycle, repo, worktree)
        outside = sorted(set(changed(repo, current, result)) - set(paths))
        if outside:
            raise scope(cycle, name, f"resolver {rule['name']} changed paths outside its conflict files", outside)
        entries = tree_entries(repo.root, result)
        for path in paths:
            entry = entries.get(path)
            log = evidence["runs"][-1]["log"]
            if entry is None or entry[0] != plan[path]["mode"]:
                raise failed(cycle, name, repo, head, f"resolver {rule['name']} removed {path} or changed its file mode", log)
            if entry[1] == plan[path]["blob"]:
                raise failed(cycle, name, repo, head, f"resolver {rule['name']} did not change {path}", log)
            if MARKER.search(blob(repo.root, entry[1])):
                raise failed(cycle, name, repo, head, f"resolver {rule['name']} left conflict markers in {path}", log)
        check_outside(cycle, name, worktree, head, project, "resolver " + rule["name"])
        current = result
    if spec.get("check"):
        run_step(cycle, name, repo, head, "the check command", spec["check"], worktree, "check", sorted(plan), env, evidence)
        result = stage(cycle, repo, worktree)
        if result != current:
            raise scope(cycle, name, "the check command changed the resolved tree", changed(repo, current, result))
        check_outside(cycle, name, worktree, head, project, "the check command")
    return current


def run_step(cycle, name, repo, head, label, spec, worktree, index, paths, env, evidence):
    """One resolver or the check, under the process control of the run."""
    from focus_commit import run_contained
    listing_file = worktree.with_name(f"{worktree.name}.{index}.paths")
    listing_file.write_bytes(b"".join(os.fsencode(path) + b"\0" for path in paths))
    directory = cycle.store.directory / "resolve"
    directory.mkdir(parents=True, exist_ok=True)
    log = directory / (uuid.uuid4().hex + ".jsonl")
    run = {"name": label, "command": spec["command"], "timeout": spec["timeout"], "paths": paths,
           "log": str(log), "exit": None}
    evidence["runs"].append(run)
    if cycle.progress:
        cycle.progress.runtime("publish")
        cycle.progress.note(f"{label[0].upper() + label[1:]} for {name}; no model is running")
    control = cycle.control.child("resolver", worktree) if cycle.control else None
    try:
        code, tail = run_contained(cycle, spec["command"], worktree, log, lambda: failed(
            cycle, name, repo, head, f"{label} did not complete in {spec['timeout']} seconds", log),
            deadline=spec["timeout"], env=dict(env, CC_FOCUS_MERGE_PATHS=str(listing_file)), control=control)
    except OSError as error:
        raise failed(cycle, name, repo, head, f"{label} could not start: {error}", log) from error
    except Blocked as error:
        if error.code == "cleanup-incomplete":
            # A process that left the process group can still change the tree, so the hard stop stays.
            raise Blocked("cleanup-incomplete", f"{name}: {label} left a running process, for example a build server. "
                          f"{error} Stop that process, and turn off the build server in the command. "
                          f"Read the log {log}. Then run {cycle.retry_command()}.") from error
        if error.code != "native-cli-required":
            raise
        raise failed(cycle, name, repo, head, f"{label} names a batch file. Name a program, for example py", log) from error
    finally:
        if cycle.progress:
            cycle.progress.finish()
    run["exit"] = code
    if code:
        raise failed(cycle, name, repo, head, f"{label} exited with code {code}. The end of its output: "
                     + " ".join(tail[-600:].split()), log)


def stage(cycle, repo, worktree):
    """The tree of the worktree. Ignored files, for example build output, stay out of it."""
    from focus_commit import run_git
    run_git(cycle, "add", "-A", repo=repo, cwd=worktree, options=LONG_PATHS)
    return git(worktree, "write-tree").decode("ascii").strip()


def changed(repo, older, newer):
    output = git(repo.root, "diff-tree", "-r", "-z", "--no-renames", "--name-only", older, newer)
    return sorted(os.fsdecode(name) for name in output.split(b"\0") if name)


def check_outside(cycle, name, worktree, head, project, label):
    """The project outside the worktree did not change, and the worktree has no other HEAD or Git operation."""
    current = cycle.repo.snapshot()
    paths = sorted(set(cycle.changes(project, current))
                   | {member + " HEAD" for member in project["head"] if project["head"][member] != current["head"].get(member)}
                   | {member + " index" for member in project["index"] if project["index"][member] != current["index"].get(member)})
    if paths:
        raise scope(cycle, name, f"{label} changed the project outside the temporary worktree", paths)
    detached = subprocess.run(["git", "-C", str(worktree), "symbolic-ref", "-q", "HEAD"], cwd=worktree,
                              stdin=subprocess.DEVNULL, capture_output=True, timeout=60).returncode != 0
    moved = git(worktree, "rev-parse", "HEAD").decode("ascii").strip() != head or not detached
    gitdir = Path(git(worktree, "rev-parse", "--absolute-git-dir").decode("utf-8").strip())
    operations = [entry for entry in OPERATION_STATE if (gitdir / entry).exists()]
    if moved or operations:
        raise scope(cycle, name, f"{label} moved HEAD of the temporary worktree or left a Git operation",
                    (["HEAD"] if moved else []) + operations)
