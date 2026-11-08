"""Immutable source inputs and bounded artifact handoff for paired inspections."""

from collections import OrderedDict
import json
import difflib
import os
from pathlib import Path
import sys

from cycle_state import Blocked, digest, encode
from focus_project import instruction_entries
from focus_snapshot_archive import SnapshotWriter, open_archive, read_source


def artifact(store, relative, value):
    data = encode(value)
    path = Path(store.artifact(relative, data))
    return {"path": path.relative_to(store.directory).as_posix(), "sha256": digest(data)}


def evidence(value):
    """Indented JSON: focus_inspect pages by line and shows a long line in parts."""
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, indent=1) + "\n").encode("utf-8")


# Frozen inspector inputs hold source copies and diffs, not evidence records.
VIEW_MANIFESTS = ("view.json", "before.json")
RUNTIME_PROMPT = "__runtime__/prompt.txt"  # A Claude reader reads its recovery copy here after a compaction.
# UTF-8 bytes per inspection page and kept for the page notice. Claude shows an MCP
# result of up to 25,000 tokens, and Codex shortens long tool output; a page stays
# below both. A part of a long line has at most PART characters of up to 4 bytes each.
PAGE = 30000
NOTICE = 150
PART = 6000
# A frozen view holds this text for a link. The view kind, not the text, marks a link.
LINK_TEXT = "Symbolic link (not followed): "


def expose_records(cycle, writer, files, exposed, value, prefix):
    """Copy each runtime record that VALUE refers to. Keep each reference and add
    the name of its copy, or null for a record that changed or disappeared."""
    if isinstance(value, list):
        return [expose_records(cycle, writer, files, exposed, item, prefix) for item in value]
    if not isinstance(value, dict):
        return value
    if set(value) != {"path", "sha256"} or not isinstance(value["path"], str):
        return {key: expose_records(cycle, writer, files, exposed, item, prefix) for key, item in value.items()}
    if value["path"].rsplit("/", 1)[-1] in VIEW_MANIFESTS:
        return value
    if value["path"] not in exposed:
        try:
            record = read_record(cycle.store, value)
        except Blocked:
            return dict(value, exposed=None)
        name = f"{prefix}{sum(n.startswith(prefix) for n in exposed.values())}.json"
        if name in files:
            raise Blocked("pair-input", "Reserved inspection input path collides with source.")
        exposed[value["path"]] = name  # Before recursion: a cycle ends at this name.
        content = evidence(expose_records(cycle, writer, files, exposed, record, prefix))
        writer.write(name, content)
        files[name] = digest(content)
    return dict(value, exposed=exposed[value["path"]])


def read_record(store, record):
    try:
        path = store.directory / record["path"]
        if not path.resolve().is_relative_to(store.directory.resolve()):
            raise ValueError("outside runtime")
        data = path.read_bytes()
        if digest(data) != record["sha256"]:
            raise ValueError("changed record")
        return json.loads(data)
    except (OSError, ValueError, KeyError) as error:
        raise Blocked("pair-evidence", "A sealed pair artifact changed or disappeared; work was preserved.") from error


def materialize(cycle, pair):
    if pair.get("view"):
        manifest = read_record(cycle.store, pair["view"])
        return manifest
    base = f"pair-reviews/{cycle.state['iteration']}/{pair['id']}/view-{pair.get('view_generation', 0)}"
    root = cycle.store.directory / base / "source"
    writer = SnapshotWriter(root)
    try:
        return freeze_view(cycle, pair, base, root, writer)
    finally:
        writer.close()


def freeze_view(cycle, pair, base, root, writer):
    files = {}
    snapshot = pair["snapshot"]
    for name, fingerprint in snapshot["files"].items():
        parts = Path(name).parts
        if any(p in (".git", ".jj", ".work") for p in parts):
            continue
        source = cycle.repo.root / name
        if source.is_symlink():
            link = os.readlink(source)
            data = (LINK_TEXT + link + "\n").encode()
            observed = "link:" + digest(os.fsencode(link))
        else:
            data = source.read_bytes()
            observed = ("x:" if source.stat().st_mode & 0o111 else "f:") + digest(data)
        if observed != fingerprint:
            raise Blocked("pair-drift", "Source changed while copying frozen review input: " + name)
        target = root / name
        if not target.resolve().is_relative_to(root.resolve()):
            raise Blocked("pair-input", "Review input escapes its immutable source snapshot.")
        writer.write(name, data)
        files[name] = digest(data)
    paths = (cycle.changes(pair["repair_snapshot"], snapshot) if pair.get("repair_base") else cycle.publication_paths())
    diffs = {}
    repositories = getattr(cycle.repo, "repositories", {"": cycle.repo})
    for member, repo in (() if pair.get("repair_base") else repositories.items()):
        names = [p for p in paths if not member or p.startswith(member + "/")]
        baseline = cycle.state["baseline"]["head"]
        revision = baseline[member] if member else baseline
        for name in names:
            local = name[len(member) + 1:] if member else name
            diffs[name] = repo.git("--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-renames",
                                  revision, "--", local).stdout.decode("utf-8", errors="replace")
    if pair.get("repair_base"):
        original = read_record(cycle.store, pair["repair_base"])
        if original["candidate"] != digest(encode(pair["repair_snapshot"])):
            raise Blocked("repair-baseline", "Repair diff baseline does not match the frozen pre-fix candidate.")
        for name in paths:
            if name not in files and name not in original["files"]:
                raise Blocked("repair-input", "Repair changed a path unavailable to the frozen inspector: " + name)
            before = b""
            if name in original["files"]:
                try:
                    before = read_source(original, name)
                except (OSError, ValueError, KeyError) as error:
                    raise Blocked("repair-baseline", "Frozen repair baseline changed: " + name) from error
            after = writer.archive.read(name) if name in files else b""
            kinds = (pair["repair_snapshot"]["files"].get(name, "absent").split(":")[0], snapshot["files"].get(name, "absent").split(":")[0])
            header = f"Source kind: {kinds[0]} -> {kinds[1]}\n"
            if b"\0" in before or b"\0" in after:
                diffs[name] = header + f"Binary change: {digest(before)} -> {digest(after)}\n"
            else:
                diffs[name] = header + "".join(difflib.unified_diff(before.decode("utf-8", errors="replace").splitlines(True),
                    after.decode("utf-8", errors="replace").splitlines(True), fromfile="before/" + name, tofile="after/" + name))
    if RUNTIME_PROMPT in files:
        # A Claude reader reads its recovery copy at this path. A project file there would hide it.
        raise Blocked("pair-input", f"Reserved inspection input path collides with source: {RUNTIME_PROMPT}.")
    # Copy reports as data only for early pairs. Final tools cannot read them.
    # Inner repair views get the same records: an accepted assignment can
    # require a comparison with retained evidence.
    handoff = cycle.state.get("pair_handoff", []) if pair["phase"] != "final" else []
    exposed = {record["path"]: f"__review__/history-{i}.json" for i, record in enumerate(handoff)}
    if pair["phase"] != "final":
        if cycle.state.get("code_report"):
            from cycle_transport import parse_report
            try:
                coding = parse_report(cycle.state["code_report"], "code")
            except Blocked:
                coding = {"summary": "Historical coding account", "description": cycle.state["code_report"], "evidence": []}
            for name, value in (("__review__/coding.json", {"summary": coding["summary"], "checks": coding["evidence"], "full_account": "__review__/coding-full.json"}),
                                ("__review__/coding-full.json", coding)):
                if name in files:
                    raise Blocked("pair-input", "Reserved inspection input path collides with source.")
                data = evidence(value)
                writer.write(name, data)
                files[name] = digest(data)
        for i, record in enumerate(handoff):
            value = read_record(cycle.store, record)
            sources = []
            for j, source in enumerate(value.get("sources", [])):
                name = f"__review__/history-{i}-source-{j}.json"
                if name in files:
                    raise Blocked("pair-input", "Reserved inspection input path collides with source.")
                content = evidence(read_record(cycle.store, source))
                writer.write(name, content)
                files[name] = digest(content)
                sources.append(name)
            if sources:
                value = dict(value, sources=sources)
            # A repair seal names its fix and test reports, inner reviews and audits by runtime path.
            value = expose_records(cycle, writer, files, exposed, value, f"__review__/history-{i}-record-")
            data = evidence(value)
            name = f"__review__/history-{i}.json"
            if name in files:
                raise Blocked("pair-input", "Reserved inspection input path collides with a source file.")
            writer.write(name, data)
            files[name] = digest(data)
    if pair.get("repair_base"):
        # An open repair gate keeps its own fix, test and audit records until its seal.
        gate = (cycle.state.get("pair_review") or {}).get("repair") or {}
        value = {key: gate.get(key) or [] for key in ("executions", "tests", "evidence_changes")}
        value = expose_records(cycle, writer, files, exposed, value, "__review__/gate-record-")
        name = "__review__/gate.json"
        if name in files:
            raise Blocked("pair-input", "Reserved inspection input path collides with source.")
        data = evidence(value)
        writer.write(name, data)
        files[name] = digest(data)
    if cycle.snapshot() != snapshot:
        raise Blocked("pair-drift", "The project changed while freezing review inputs.")
    from focus_publication_scope import manifest as publication_manifest
    name = "__review__/publication.json"
    if name in files:
        raise Blocked("pair-input", "Reserved publication input path collides with source.")
    # A repair view diffs only the repair, but the manifest lists the planned publication.
    data = evidence(publication_manifest(cycle, snapshot, paths=None if pair.get("repair_base") else paths))
    writer.write(name, data)
    files[name] = digest(data)
    writer.finish()
    manifest = {"root": str(root), "storage": "zip", "files": files, "diffs": diffs, "stage_paths": paths,
                "candidate": digest(encode(snapshot)), "phase": pair["phase"],
                "source_kinds": {name: value.split(":", 1)[0] for name, value in snapshot["files"].items() if name in files}}
    if cycle.state.get("review_run") and not pair.get("repair_base"):
        manifest["review_scope"] = cycle.inspection_scope()
    manifest["publication"] = "__review__/publication.json"
    pair["view"] = artifact(cycle.store, base + "/view.json", manifest)
    cycle.save()
    return manifest


def view_instructions(manifest, repositories):
    """The instruction list of a frozen view. A saved reader prompt keeps it after the files change."""
    files, kinds = manifest["files"], manifest.get("source_kinds", {})

    def kind(name):
        return kinds.get(name) if name in files else None

    def link(name):
        try:
            text = read_source(manifest, name).decode("utf-8", errors="replace")
        except (OSError, ValueError, KeyError) as error:
            raise Blocked("pair-input", "A frozen review input changed or disappeared: " + name) from error
        return text[len(LINK_TEXT):-1] if text.startswith(LINK_TEXT) and text.endswith("\n") else None
    return instruction_entries(repositories, kind, link)


def page_rows(lines, counts, offset, limit):
    """Yield (row index, label, text) for the requested rows only."""
    index = 0
    for number, (line, count) in enumerate(zip(lines, counts), 1):
        if index + count <= offset:
            index += count
            continue
        for k in range(count):
            if index >= offset + limit:
                return
            if index >= offset:
                yield index, str(number) if count == 1 else f"{number} part {k + 1}/{count}", line[k * PART:(k + 1) * PART]
            index += 1


SEARCH_LIMIT, PATTERN_LIMIT, WINDOW = 200, 200, 400
TEXT_CACHE = 64 * 1024 * 1024  # Verified file text that one inspector keeps for searches.


class ViewInspector:
    """No arbitrary file paths, shell, VCS, project executables or archive access."""
    def __init__(self, manifest, recovery=None):
        self.manifest = manifest
        self.root = Path(manifest["root"]).resolve()
        self.recovery = Path(recovery) if recovery else None
        self.texts, self.cached = OrderedDict(), 0

    def text(self, name, archive):
        """The verified text of one view file, or None for a binary file. The oldest cached text goes first."""
        if name in self.texts:
            self.texts.move_to_end(name)
            return self.texts[name][0]
        data = read_source(self.manifest, name, archive)
        text = None if b"\0" in data else data.decode("utf-8", errors="replace")
        size = len(data) if text is not None else 0
        if size <= TEXT_CACHE:
            self.texts[name] = (text, size)
            self.cached += size
            while self.cached > TEXT_CACHE:
                _, (_, old) = self.texts.popitem(last=False)
                self.cached -= old
        return text

    def search(self, name, pattern, offset, limit):
        if not isinstance(pattern, str) or not 1 <= len(pattern) <= PATTERN_LIMIT or any(c in pattern for c in "\0\n\r"):
            raise ValueError(f"A search pattern is a literal text of 1 to {PATTERN_LIMIT} characters on one line")
        if limit > SEARCH_LIMIT:
            raise ValueError(f"A search shows at most {SEARCH_LIMIT} matches in one call")
        files, kinds = self.manifest["files"], self.manifest.get("source_kinds", {})
        prefix = name.rstrip("/")
        names = [name] if name in files else sorted(
            n for n in files if prefix in ("", ".") or n.startswith(prefix + "/"))
        if not names:
            raise ValueError("Path is not a file or a directory of the view")
        rows, found = [], 0
        with open_archive(self.root) as archive:
            for path in names:
                if kinds.get(path) == "link":
                    continue
                text = self.text(path, archive)
                if text is None:
                    continue  # A binary file has no lines to search.
                row = 0
                for number, line in enumerate(text.splitlines(), 1):
                    index = line.find(pattern)
                    if index >= 0:
                        if found >= offset:
                            start = max(0, index - (WINDOW - len(pattern)) // 2)
                            window = ("…" if start else "") + line[start:start + WINDOW] + ("…" if start + WINDOW < len(line) else "")
                            # Row N is the read offset of the part with the match. A long line has parts of PART characters.
                            rows.append((found, f"{path}:{number} (row {row + index // PART}): {window}"))
                        found += 1
                        if found > offset + limit:
                            break
                    row += max(1, -(-len(line) // PART))
                if found > offset + limit:
                    break
        more = found > offset + limit
        rows = rows[:limit]
        # The final header is at most this long without its stop fields, which NOTICE covers.
        longest = f"Matches shown: {len(rows)}; offset: {offset}; more matches exist"
        shown, size, stop = [], len(longest.encode("utf-8")) + 1, None
        for index, row in rows:
            if shown and size + len(row.encode("utf-8")) + NOTICE > PAGE:
                stop = index
                break
            shown.append(row)
            size += len(row.encode("utf-8")) + 1
        if stop is None and more:
            stop = offset + len(rows)
        # The header counts the rows of this page, so a page that the budget stops does not claim more rows.
        head = f"Matches shown: {len(shown)}; offset: {offset}"
        if stop is not None:
            head += f"; more matches exist; next offset: {stop}"
            shown.append(f"[The page stops before match {stop}. Continue at offset {stop}.]")
        return {"success": True, "contentItems": [{"type": "inputText", "text": head + "\n" + "\n".join(shown)}]}

    def call(self, params):
        try:
            if params.get("tool") != "focus_inspect" or params.get("namespace"):
                raise ValueError("Only focus_inspect is available")
            args = params["arguments"]
            if isinstance(args, str):
                args = json.loads(args)
            # A resumed Codex thread keeps the tool of its thread start, so it can send the older four fields.
            if set(args) not in ({"operation", "path", "offset", "limit"}, {"operation", "path", "pattern", "offset", "limit"}):
                raise ValueError("Invalid inspection fields")
            op, name, offset, limit = (args[k] for k in ("operation", "path", "offset", "limit"))
            pattern = args.get("pattern")
            if op != "search" and pattern is not None:
                raise ValueError("Set pattern to null for read, list, and diff")
            if not isinstance(name, str) or type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 500:
                raise ValueError("Invalid inspection range")
            if "\\" in name or ":" in name or Path(name).is_absolute() or ".." in Path(name).parts:
                raise ValueError("Use a snapshot-relative path")
            files = self.manifest["files"]
            if op == "search":
                return self.search(name, pattern, offset, limit)
            if op == "read" and name == RUNTIME_PROMPT and self.recovery:
                lines = self.recovery.read_text(encoding="utf-8", errors="replace").splitlines()
            elif op == "list":
                prefix = name.rstrip("/")
                lines = sorted(n for n in files if not prefix or prefix == "." or n == prefix or n.startswith(prefix + "/"))
            elif op == "diff":
                if name not in files and name not in self.manifest["stage_paths"]:
                    raise ValueError("Path is not in the candidate")
                lines = self.manifest["diffs"].get(name, "").splitlines()
            elif op == "read":
                if name not in files:
                    raise ValueError("Path is not an exposed source or evidence artifact")
                data = read_source(self.manifest, name)
                if b"\0" in data:
                    raise ValueError("Binary input: inspect its producer or diff")
                lines = data.decode("utf-8", errors="replace").splitlines()
            else:
                raise ValueError("Unknown inspection operation")
            # A long line (a JSON string of an evidence copy, a minified source line)
            # is shown in parts. Each part keeps the line number; offsets count rows.
            counts = [max(1, -(-len(line) // PART)) for line in lines]
            total = sum(counts)
            kind = self.manifest.get("source_kinds", {}).get(name, "f")
            head = ((f"Source kind: {kind} (f=file, x=executable, link=symlink)\n" if op == "read" else "")
                    # A resumed Codex thread can keep an older tool description, so a split file says it here.
                    + f"Total lines/paths: {len(lines)}" + (f"; rows: {total}, and offsets count rows" if total != len(lines) else "")
                    + f"; offset: {offset}")
            # NOTICE also covers the next offset that a stopped page adds to its header.
            shown, size, stop = [], len(head.encode("utf-8")) + 1, None
            for i, label, part in page_rows(lines, counts, offset, limit):
                row = f"{label}: {part}"
                # Clip a page at a whole row, so the next offset misses nothing.
                if shown and size + len(row.encode("utf-8")) + NOTICE > PAGE:
                    stop = (i, label)
                    break
                shown.append(row)
                size += len(row.encode("utf-8")) + 1
            if stop:
                head += f"; next offset: {stop[0]}"
                shown.append(f"[The page stops before line {stop[1]}. Continue at offset {stop[0]}.]")
            content = head + "\n" + "\n".join(shown)
            return {"success": True, "contentItems": [{"type": "inputText", "text": content}]}
        except (OSError, ValueError, KeyError, TypeError) as error:
            return {"success": False, "contentItems": [{"type": "inputText", "text": str(error)}]}


def serve(manifest_path, recovery=None):
    """Minimal stdio MCP read tool for Claude; no built-in filesystem tools. RECOVERY is the reader's recovery copy."""
    from focus_readonly import VIEW_TOOL
    inspector = ViewInspector(json.loads(Path(manifest_path).read_text(encoding="utf-8")), recovery)
    for line in sys.stdin:
        request = json.loads(line)
        if "id" not in request:
            continue
        method = request.get("method")
        if method == "initialize":
            result = {"protocolVersion": request.get("params", {}).get("protocolVersion", "2024-11-05"),
                      "capabilities": {"tools": {}}, "serverInfo": {"name": "focus-inspect", "version": "1"}}
        elif method == "ping":
            result = {}
        elif method == "tools/list":
            result = {"tools": [{"name": "inspect", "description": VIEW_TOOL["description"], "inputSchema": VIEW_TOOL["inputSchema"]}]}
        elif method == "tools/call":
            p = request.get("params", {})
            r = inspector.call({"tool": "focus_inspect" if p.get("name") == "inspect" else "invalid", "arguments": p.get("arguments")})
            result = {"content": [{"type": "text", "text": item["text"]} for item in r["contentItems"]], "isError": not r["success"]}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Unknown method"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


if __name__ == "__main__":
    serve(sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else None)
