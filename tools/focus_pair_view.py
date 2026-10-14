"""Immutable source inputs and bounded artifact handoff for paired inspections."""

import json
import difflib
import os
from pathlib import Path
import sys

from cycle_state import Blocked, digest, encode
from focus_snapshot_archive import SnapshotWriter, read_source


def artifact(store, relative, value):
    data = encode(value)
    path = Path(store.artifact(relative, data))
    return {"path": path.relative_to(store.directory).as_posix(), "sha256": digest(data)}


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
            data = ("Symbolic link (not followed): " + link + "\n").encode()
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
    # Copy reports as data only for early pairs. Final tools cannot read them.
    if pair["phase"] != "final" and not pair.get("repair_base"):
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
                data = encode(value)
                writer.write(name, data)
                files[name] = digest(data)
        for i, record in enumerate(cycle.state.get("pair_handoff", [])):
            value = read_record(cycle.store, record)
            sources = []
            for j, source in enumerate(value.get("sources", [])):
                name = f"__review__/history-{i}-source-{j}.json"
                if name in files:
                    raise Blocked("pair-input", "Reserved inspection input path collides with source.")
                content = encode(read_record(cycle.store, source))
                writer.write(name, content)
                files[name] = digest(content)
                sources.append(name)
            if sources:
                value = dict(value, sources=sources)
            data = encode(value)
            name = f"__review__/history-{i}.json"
            if name in files:
                raise Blocked("pair-input", "Reserved inspection input path collides with a source file.")
            writer.write(name, data)
            files[name] = digest(data)
    if cycle.snapshot() != snapshot:
        raise Blocked("pair-drift", "The project changed while freezing review inputs.")
    writer.finish()
    manifest = {"root": str(root), "storage": "zip", "files": files, "diffs": diffs, "stage_paths": paths,
                "candidate": digest(encode(snapshot)), "phase": pair["phase"],
                "source_kinds": {name: value.split(":", 1)[0] for name, value in snapshot["files"].items() if name in files}}
    pair["view"] = artifact(cycle.store, base + "/view.json", manifest)
    cycle.save()
    return manifest


class ViewInspector:
    """No arbitrary file paths, shell, VCS, project executables or archive access."""
    def __init__(self, manifest):
        self.manifest = manifest
        self.root = Path(manifest["root"]).resolve()

    def call(self, params):
        try:
            if params.get("tool") != "focus_inspect" or params.get("namespace"):
                raise ValueError("Only focus_inspect is available")
            args = params["arguments"]
            if isinstance(args, str):
                args = json.loads(args)
            if set(args) != {"operation", "path", "offset", "limit"}:
                raise ValueError("Invalid inspection fields")
            op, name, offset, limit = (args[k] for k in ("operation", "path", "offset", "limit"))
            if not isinstance(name, str) or type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 500:
                raise ValueError("Invalid inspection range")
            if "\\" in name or ":" in name or Path(name).is_absolute() or ".." in Path(name).parts:
                raise ValueError("Use a snapshot-relative path")
            files = self.manifest["files"]
            if op == "list":
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
            kind = self.manifest.get("source_kinds", {}).get(name, "f")
            content = (f"Source kind: {kind} (f=file, x=executable, link=symlink)\n" if op == "read" else "") + f"Total lines/paths: {len(lines)}; offset: {offset}\n" + "\n".join(
                f"{i + 1}: {s}" for i, s in enumerate(lines[offset:offset + limit], offset))
            if len(content) > 100000:
                content = content[:100000] + "\n[Clipped; request a smaller page.]"
            return {"success": True, "contentItems": [{"type": "inputText", "text": content}]}
        except (OSError, ValueError, KeyError, TypeError) as error:
            return {"success": False, "contentItems": [{"type": "inputText", "text": str(error)}]}


def serve(manifest_path):
    """Minimal stdio MCP read tool for Claude; no built-in filesystem tools."""
    from focus_readonly import READ_TOOL
    inspector = ViewInspector(json.loads(Path(manifest_path).read_text(encoding="utf-8")))
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
            result = {"tools": [{"name": "inspect", "description": READ_TOOL["description"], "inputSchema": READ_TOOL["inputSchema"]}]}
        elif method == "tools/call":
            p = request.get("params", {})
            r = inspector.call({"tool": "focus_inspect" if p.get("name") == "inspect" else "invalid", "arguments": p.get("arguments")})
            result = {"content": [{"type": "text", "text": item["text"]} for item in r["contentItems"]], "isError": not r["success"]}
        else:
            print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "error": {"code": -32601, "message": "Unknown method"}}), flush=True)
            continue
        print(json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}), flush=True)


if __name__ == "__main__":
    serve(sys.argv[1])
