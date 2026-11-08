"""Operator project brief: a verified import outside the stage diff, the reviews, and the publication."""

import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import time

from cycle_prompts import PROJECT_BRIEF_RULE
from cycle_state import Blocked, Repository, Store, atomic_write, digest
from focus_output import terminal_text
from focus_pair_profile import PAIR_WRITERS

SCHEMA = "orchestra/project-brief@1"
LIMIT = 8 * 1024
POINTER_LIMIT = 16 * 1024
POINTER = "project-brief.json"
COPIES = "briefs"
HASH = re.compile(r"[0-9a-f]{64}")
# The conversations of these roles can contain brief text. Reader sessions belong to pair jobs.
SESSION_ROLES = ("code", *PAIR_WRITERS)
# Pair readers that make no decision with the brief.
EXCLUDED_READERS = ("pair_complexity", "repair_evidence")
BEFORE_RUN = "the same cc-focus command"


def start_remedy(retry):
    return f"Run cc-focus brief set FILE or cc-focus brief clear. Then run {retry}."


def prompt_remedy(retry, review_id=None):
    apply, resume = ((f"cc-focus brief apply --review-run {review_id}", f"cc-focus review --resume {review_id}")
                     if review_id else ("cc-focus brief apply", "cc-focus"))
    return (f"Run cc-focus brief restore FILE with the same file. Then run {retry}. "
            f"Without that file, run cc-focus brief set FILE with another file or cc-focus brief clear. "
            f"Then run {apply}. Then run {resume}.")


def record_remedy(review_id=None):
    apply, resume = ((f"cc-focus brief apply --review-run {review_id}", f"cc-focus review --resume {review_id}")
                     if review_id else ("cc-focus brief apply", "cc-focus"))
    return (f"Run {apply}. Then run {resume}. To change the pointer, first run cc-focus brief set FILE or cc-focus brief clear. "
            "The apply command does not read the earlier brief text.")


def drift(detail, remedy):
    return Blocked("brief-drift", f"Project brief: {detail}. {remedy}".rstrip())


def redirected(path):
    """A link or a Windows reparse point. Path.is_symlink does not show a junction."""
    try:
        info = os.lstat(path)
    except FileNotFoundError:
        return False
    return stat.S_ISLNK(info.st_mode) or bool(getattr(info, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0))


def read_bounded(path, limit):
    """Read a regular file without following a link. The size check comes before any use of the content."""
    before = os.lstat(path)
    if redirected(path):
        raise ValueError("it is a symbolic link or a reparse point")
    if not stat.S_ISREG(before.st_mode):
        raise ValueError("it is not a regular file")
    # A FIFO fails the lstat check above. These flags also stop a swap between the check and the open.
    flags = os.O_RDONLY | getattr(os, "O_BINARY", 0) | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    descriptor = os.open(path, flags)
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
            raise ValueError("the file changed during the open")
        chunks, size = [], 0
        while size <= limit:
            chunk = os.read(descriptor, limit + 1 - size)
            if not chunk:
                break
            chunks.append(chunk)
            size += len(chunk)
    finally:
        os.close(descriptor)
    data = b"".join(chunks)
    if len(data) > limit:
        raise ValueError(f"it is larger than {limit} bytes")
    return data


def brief_text(data):
    """The prompt text of valid brief bytes. The hash covers the exact bytes, also a BOM."""
    if len(data) > LIMIT:
        raise ValueError(f"it is larger than {LIMIT} bytes")
    if b"\0" in data:
        raise ValueError("it contains NUL bytes")
    try:
        text = data.decode("utf-8-sig")
    except UnicodeDecodeError as error:
        raise ValueError("it is not valid UTF-8") from error
    if not text.strip():
        raise ValueError("it contains no text")
    return text


def read_source(path):
    """Validate an operator source file. Return its exact bytes."""
    try:
        data = read_bounded(path, LIMIT)
        brief_text(data)
    except FileNotFoundError as error:
        raise Blocked("brief-file", f"The brief file does not exist: {terminal_text(path)}") from error
    except (OSError, ValueError) as error:
        raise Blocked("brief-file", f"The command does not accept the brief file ({terminal_text(error)}). "
                      f"Use a regular UTF-8 file with text, no NUL bytes, at most {LIMIT} bytes.") from error
    return data


def control_directory(root):
    """The development control store. Store already refuses a state path outside the repository."""
    directory = Store(root).control_directory
    copies = directory / COPIES
    if redirected(copies) or copies.exists() and not copies.is_dir():
        raise Blocked("brief-path", f"The brief copies directory is a link, a reparse point, or not a directory: {terminal_text(copies)}. "
                      "Replace it with a regular directory. Then run cc-focus brief restore FILE or cc-focus brief set FILE. "
                      "Then run the retry command that the run names, or repeat the command.")
    if not copies.resolve().is_relative_to(directory.resolve()):
        raise Blocked("brief-path", "The brief copies resolve outside the control store. "
                      "Replace .work/cycle/briefs with a regular directory. Then run cc-focus brief restore FILE or "
                      "cc-focus brief set FILE. Then run the retry command that the run names, or repeat the command.")
    return directory


def copy_path(directory, sha):
    if not isinstance(sha, str) or not HASH.fullmatch(sha):
        raise ValueError("invalid brief hash")
    return directory / COPIES / f"{sha}.md"


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field " + key)
        result[key] = value
    return result


def read_pointer(directory, remedy=None):
    """The imported default, None without a pointer. A malformed pointer is not an empty default."""
    path = directory / POINTER
    remedy = remedy or start_remedy(BEFORE_RUN)
    try:
        data = read_bounded(path, POINTER_LIMIT)
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        raise drift(f"the pointer {terminal_text(path)} is not readable ({terminal_text(error)})", remedy) from error
    try:
        value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object)
        if not isinstance(value, dict) or set(value) != {"schema", "sha256", "source", "updated"}:
            raise ValueError("unexpected fields")
        if value["schema"] != SCHEMA:
            raise ValueError("unknown schema")
        sha, source, updated = value["sha256"], value["source"], value["updated"]
        if (sha is None) != (source is None):
            raise ValueError("sha256 and source must both be null or both have values")
        if sha is not None and not (isinstance(sha, str) and HASH.fullmatch(sha)):
            raise ValueError("invalid sha256")
        if source is not None and not (isinstance(source, str) and Path(source).is_absolute()):
            raise ValueError("source must be an absolute path")
        if type(updated) not in (int, float) or not math.isfinite(updated) or updated < 0:
            raise ValueError("updated must be a finite, nonnegative number")
    except (UnicodeDecodeError, ValueError, OverflowError, RecursionError) as error:
        # Overflow and recursion messages are long. Their type names the cause.
        reason = error if isinstance(error, ValueError) and not isinstance(error, UnicodeDecodeError) else type(error).__name__
        raise drift(f"the pointer {terminal_text(path)} is malformed ({terminal_text(reason)})", remedy) from error
    return {"sha256": sha, "source": source, "updated": updated}


def read_copy(directory, sha, remedy):
    """Verify the stored copy of a hash and return its prompt text."""
    try:
        path = copy_path(directory, sha)
        data = read_bounded(path, LIMIT)
        if digest(data) != sha:
            raise ValueError("its content does not match its hash")
        return brief_text(data)
    except FileNotFoundError as error:
        raise drift(f"the copy {sha} is missing", remedy) from error
    except (OSError, ValueError) as error:
        raise drift(f"the copy {sha} is not valid ({terminal_text(error)})", remedy) from error


def writable(path):
    """A destination must be absent or a regular file. Path integrity failures prevent writes."""
    if redirected(path) or path.exists() and not path.is_file():
        raise Blocked("brief-path", f"The brief destination is a link, a reparse point, or not a regular file: {terminal_text(path)}. "
                      "Remove it. Then repeat the command.")


def store_copy(directory, data):
    """Store verified bytes under their hash. Replace a damaged copy with the same name."""
    sha = digest(data)
    path = copy_path(directory, sha)
    writable(path)
    try:
        if read_bounded(path, LIMIT) == data:
            return sha
    except (OSError, ValueError):
        pass  # A missing or damaged copy gets the verified bytes.
    atomic_write(path, data)
    return sha


def pointer_bytes(sha, source):
    value = {"schema": SCHEMA, "sha256": sha, "source": source, "updated": time.time()}
    return json.dumps(value, ensure_ascii=False, sort_keys=True, indent=2).encode("utf-8") + b"\n"


def valid_record(record, iteration):
    return (isinstance(record, dict) and set(record) == {"iteration", "sha256"}
            and type(record["iteration"]) is int and record["iteration"] >= 1 and record["iteration"] == iteration
            and (record["sha256"] is None or isinstance(record["sha256"], str) and bool(HASH.fullmatch(record["sha256"]))))


def stage_hash(state, remedy=None):
    """The brief hash of the current stage. A state from an older runtime has no record and no brief."""
    if "project_brief" not in state:
        return None
    record = state["project_brief"]
    if not valid_record(record, state["iteration"]):
        raise drift("the stage record is damaged", remedy or record_remedy((state.get("review_run") or {}).get("id")))
    return record["sha256"]


def pair_hash(pair):
    """The brief hash of a pair record. An older pair has no field and no brief."""
    sha = pair.get("project_brief_sha256")
    if sha is not None and not (isinstance(sha, str) and HASH.fullmatch(sha)):
        raise Blocked("brief-drift", "Project brief: a pair record has an invalid brief hash. "
                      "Use the normal state recovery. The brief commands do not repair pair records.")
    return sha


def capture(root, remedy):
    """Read and verify the default once for a stage start or an application."""
    directory = control_directory(root)
    pointer = read_pointer(directory, remedy)
    sha = pointer["sha256"] if pointer else None
    if sha:
        read_copy(directory, sha, remedy)
    return sha


def record(state, sha):
    state["project_brief"] = {"iteration": state["iteration"], "sha256": sha}


def delivery(root, sha, remedy):
    """The field for a role that receives the brief. It contains the text, not a path."""
    return {"sha256": sha, "text": read_copy(control_directory(root), sha, remedy), "rule": PROJECT_BRIEF_RULE}


def check_root(root):
    """Brief commands run at a top-level directory. They do not need branch main."""
    root = Path(root).resolve()
    repository = Repository(root)
    if (root / ".git").exists():
        top = repository.git("rev-parse", "--show-toplevel", check=False)
        if top.returncode or Path(top.stdout.decode("utf-8").strip()).resolve() != root:
            raise Blocked("wrong-root", "Run the brief commands at the repository root or at the project root.")
        gitdir = Path(repository.text("rev-parse", "--absolute-git-dir"))
        if (gitdir / "commondir").exists():
            raise Blocked("unsupported-checkout", "Use the primary Git checkout, not a linked worktree. No run reads a pointer there.")
        return
    from focus_project import repository_paths
    if repository_paths(root) and repository.git("rev-parse", "--git-dir", check=False).returncode:
        return
    raise Blocked("wrong-root", "Run the brief commands at the repository root or at the project root.")


def named_hashes(root):
    """Hashes that a restore can accept, and the sources that could not be read."""
    from focus_review_run import pending_run
    names, skipped = set(), []
    directory = control_directory(root)
    try:
        pointer = read_pointer(directory)
        if pointer and pointer["sha256"]:
            names.add(pointer["sha256"])
    except Blocked as error:
        skipped.append(("pointer", error))
    try:
        state = Store(root).read()
        if state:
            sha = stage_hash(state)
            if sha:
                names.add(sha)
    except Blocked as error:
        skipped.append(("development state", error))
    try:
        unfinished = pending_run(root)
        if unfinished:
            sha = stage_hash(unfinished[1])
            if sha:
                names.add(sha)
    except Blocked as error:
        skipped.append(("unfinished campaign", error))
    return names, skipped


def record_view(state):
    if state is None:
        return {"stage": None, "note": "No stage has captured the default."}
    try:
        sha = stage_hash(state)
    except Blocked as error:
        return {"error": terminal_text(error)}
    view = {"iteration": state["iteration"], "stage": sha}
    if "project_brief" not in state:
        view["note"] = "This stage started before the brief feature. It has no brief."
    return view


def show(root, review_id=None):
    from focus_review_run import pending_run
    directory = control_directory(root)
    result = {}
    try:
        pointer = read_pointer(directory)
        result["pointer"] = pointer and {"sha256": pointer["sha256"], "source": terminal_text(pointer["source"])
                                         if pointer["source"] else None, "updated": pointer["updated"]}
        if pointer and pointer["sha256"]:
            try:
                read_copy(directory, pointer["sha256"], "")
                result["copy"] = "valid"
            except Blocked as error:
                result["copy_error"] = terminal_text(error)
            try:
                data = read_bounded(pointer["source"], LIMIT)
                result["source"] = "unchanged" if digest(data) == pointer["sha256"] else "changed since the import"
            except (OSError, ValueError) as error:
                result["source"] = terminal_text(f"not readable ({error}). The runtime still uses the saved copy.")
    except Blocked as error:
        result["pointer_error"] = terminal_text(error)
    records = {}
    if review_id:
        try:
            state = Store(root, review_id).read()
            if state is None:
                raise Blocked("review-state", "Review run does not exist: " + review_id)
            records["campaign " + review_id] = record_view(state)
        except Blocked as error:
            records["campaign " + review_id] = {"error": terminal_text(error)}
    else:
        try:
            records["development"] = record_view(Store(root).read())
        except Blocked as error:
            records["development"] = {"error": terminal_text(error)}
        try:
            unfinished = pending_run(root)
            if unfinished:
                records["campaign " + unfinished[0].review_id] = record_view(unfinished[1])
        except Blocked as error:
            records["campaign"] = {"error": terminal_text(error)}
    result["records"] = records
    return result


def status_entry(root, state):
    """The status entry. It never reads the original source file."""
    entry = {}
    try:
        directory = control_directory(root)
        pointer = read_pointer(directory)
        entry["default"] = pointer["sha256"] if pointer else None
        if pointer and pointer["sha256"]:
            try:
                read_copy(directory, pointer["sha256"], "")
            except Blocked as error:
                entry["default_copy_error"] = terminal_text(error)
    except Blocked as error:
        entry["pointer_error"] = terminal_text(error)
    if state is None:
        entry["stage"] = None
        entry["note"] = "No stage has captured the default."
        return entry
    view = record_view(state)
    if "error" in view:
        entry["stage_error"] = view["error"]
        return entry
    entry["stage"] = view["stage"]
    if view["stage"]:
        try:
            read_copy(control_directory(root), view["stage"], "")
        except Blocked as error:
            entry["stage_copy_error"] = terminal_text(error)
    if "default" in entry and entry["default"] != view["stage"]:
        entry["pending"] = "takes effect at the next stage"
    return entry


def refuse_apply(state, messages):
    """The saved-state refusals of brief apply. They run before the run starts."""
    if state["status"] == "complete":
        raise Blocked("correction-stage", "The plan of this run is complete. The pointer takes effect at the next stage.")
    if messages.unresolved(state["iteration"]):
        raise Blocked("correction-messages", "Resolve queued or uncertain messages first, with retry-message or discard-message.")
    if (state.get("published") or state.get("publication_started") or state["phase"] in ("publish", "ci")
            or state.get("stage_completed")):
        raise Blocked("correction-publication", "Publication, CI, or a stage pause is in progress. "
                      "The pointer takes effect at the next stage.")


def unchanged(state, sha):
    """An equal hash of a valid record needs no change. A damaged record always needs a replacement."""
    if "project_brief" not in state:
        return sha is None
    return valid_record(state["project_brief"], state["iteration"]) and state["project_brief"]["sha256"] == sha


def restart_capture(root, state):
    """The --handoff restart after complete: capture the default before any state change."""
    sha = capture(root, start_remedy(BEFORE_RUN))
    malformed = "project_brief" in state and not valid_record(state["project_brief"], state["iteration"])
    previous = None if malformed else (state.get("project_brief") or {}).get("sha256")
    return {"sha256": sha, "changed": malformed or previous != sha, "malformed": malformed}


def label(sha):
    return sha or "none"


def command(root, action, path=None, review_id=None):
    """set, restore, clear, and show. They take no lock and do not change the workflow state."""
    from focus_project import check_project_owner
    root = Path(root).resolve()
    check_root(root)
    check_project_owner(Store(root))
    directory = control_directory(root)
    if action == "show":
        print(terminal_text(json.dumps(show(root, review_id), ensure_ascii=False, indent=2)))
        return 0
    pointer = directory / POINTER
    if action == "clear":
        writable(pointer)
        atomic_write(pointer, pointer_bytes(None, None))
        print("cc-focus: the command cleared the brief default. The next stage has no brief. The command started no model.", flush=True)
        return 0
    if path is None:
        raise Blocked("brief-file", "The brief action needs a file.")
    source = Path(path).absolute()
    data = read_source(source)
    sha = digest(data)
    if action == "restore":
        names, skipped = named_hashes(root)
        for name, error in skipped:
            print(terminal_text(f"cc-focus: the command skipped the {name} as a hash source: {error}"), flush=True)
        if sha not in names:
            raise Blocked("brief-restore", "No pointer or stage record names this brief. Use cc-focus brief set to import a new brief.")
        store_copy(directory, data)
        print(f"cc-focus: the command restored the brief copy {sha}. The pointer did not change. The command started no model.", flush=True)
        return 0
    # set: prepare the pointer bytes first. Then store the copy. Then replace the pointer.
    value = pointer_bytes(sha, str(source))
    writable(pointer)
    store_copy(directory, data)
    atomic_write(pointer, value)
    print(f"cc-focus: the brief default is {sha}. The next stage uses it. The command started no model.", flush=True)
    return 0


def report_apply(store, intended):
    """After an apply error, report whether the saved state has the intended record."""
    try:
        saved = store.read()
    except Blocked as error:
        print(terminal_text(f"cc-focus: the apply result is uncertain ({error}). The command kept the artifacts."), file=sys.stderr)
        return
    committed = bool(saved) and saved.get("project_brief") == intended
    print("cc-focus: the saved state " + ("contains the applied brief." if committed else "does not contain the applied brief."),
          file=sys.stderr)
