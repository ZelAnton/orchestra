"""Resolve completed plan items and operator scopes without starting a provider."""

import json
from pathlib import Path
import re

from cycle_state import Blocked, digest, encode


ID = r"[A-Za-z][A-Za-z0-9]*(?:[.-][A-Za-z0-9]+)*"
HEADING = re.compile(r"^(#{1,6})\s+(.+?)\s*#*\s*$")
ITEM = re.compile(r"^(?:\[([ xX])\]\s*)?(" + ID + r")(?=[\s.:—–-]|$)[.:]?\s*(.*)$")
DONE = re.compile(r"^(?:✅\s*)?(?:done|complete(?:d)?|published|closed|заверш[её]н[аоы]?|опубликован[аоы]?|выполнен[аоы]?|закрыт[аоы]?)(?:\b|$)", re.I)
STATUS = re.compile(r"^(?:status|статус)\s*[:—-]\s*(.*)$", re.I)


def plain(text):
    text = re.sub(r"\[([^\]]+)\]\([^)]*\)", r"\1", text)
    return text.replace("**", "").replace("`", "").strip()


def source_file(root, name):
    path = Path(name)
    path = path if path.is_absolute() else Path(root) / path
    if path.is_symlink() or not path.resolve().is_relative_to(Path(root).resolve()):
        raise Blocked("review-scope", "The plan must be a regular file inside the project.")
    if not path.is_file() or path.stat().st_size > 32 * 1024 * 1024:
        raise Blocked("review-scope", "The plan must be a UTF-8 file of at most 32 MiB.")
    data = path.read_bytes()
    return path.resolve().relative_to(Path(root).resolve()).as_posix(), data


def is_parent(parent, child):
    if not child.startswith(parent) or child == parent:
        return False
    tail = child[len(parent):]
    return tail[0] in ".-" or parent[-1].isdigit() != tail[0].isdigit()


def plan_index(root, name):
    relative, data = source_file(root, name)
    lines = data.decode("utf-8-sig").splitlines()
    headings, tables, checks, fence = [], {}, [], None
    table_status = None
    for number, line in enumerate(lines, 1):
        stripped = line.strip()
        marker = re.match(r"^(`{3,}|~{3,})", stripped)
        if marker:
            token = marker[1]
            if fence is None:
                fence = token
            elif token[0] == fence[0] and len(token) >= len(fence):
                fence = None
            continue
        if fence:
            continue
        heading = HEADING.match(line)
        if heading:
            match = ITEM.match(plain(heading[2]))
            headings.append({"line": number, "level": len(heading[1]), "match": match})
        if stripped.startswith("|"):
            cells = [plain(c) for c in stripped.strip("|").split("|")]
            status_columns = [i for i, c in enumerate(cells) if c.casefold() in ("status", "статус")]
            if status_columns:
                table_status = status_columns[0]
            elif table_status is not None and len(cells) > table_status:
                key = cells[0]
                if re.fullmatch(ID, key) and any(c.isdigit() for c in key):
                    value = cells[table_status]
                    if key in tables and tables[key] != value:
                        raise Blocked("review-plan", "Conflicting status rows for " + key)
                    tables[key] = value
        else:
            table_status = None
        check = re.match(r"^\s*[-*+]\s+(\[[ xX]\].+)$", line)
        if check:
            match = ITEM.match(plain(check[1]))
            if match and any(c.isdigit() for c in match[2]):
                checks.append({"line": number, "level": 7, "match": match})
    entries = [h for h in headings if h["match"] and any(c.isdigit() for c in h["match"][2])]
    heading_ids = {h["match"][2] for h in entries}
    entries += [h for h in checks if h["match"][2] not in heading_ids]
    entries.sort(key=lambda row: row["line"])
    items, identities = [], set()
    for entry in entries:
        match, start, level = entry["match"], entry["line"], entry["level"]
        identity = match[2]
        if identity in identities:
            raise Blocked("review-plan", "Duplicate plan item ID: " + identity)
        identities.add(identity)
        end = next((h["line"] - 1 for h in headings if h["line"] > start and h["level"] <= level), len(lines))
        if level == 7:
            end = start
        text = "\n".join(lines[start - 1:end])
        status = tables.get(identity, "")
        if not status:
            for line in lines[start:min(end, start + 12)]:
                found = STATUS.match(plain(line))
                if found:
                    status = found[1]
                    break
        checked = match[1] and match[1].lower() == "x"
        done = bool(checked or DONE.match(status))
        items.append({"id": identity, "title": (identity + " " + match[3]).strip(), "line": start,
                      "end": end, "level": level, "status": status or ("completed" if checked else "unknown"),
                      "completed": done, "text": text, "parent": None, "children": []})
    for item in items:
        candidates = [p for p in items if p["line"] < item["line"] and (
            is_parent(p["id"], item["id"]) or p["line"] < item["line"] <= p["end"] and p["level"] < item["level"])]
        if candidates:
            parent = max(candidates, key=lambda p: p["line"])
            item["parent"] = parent["id"]
            parent["children"].append(item["id"])
    if not items:
        raise Blocked("review-plan", "No plan items found. Use ID headings or checklists, or supply --scope-file.")
    return {"path": relative, "sha256": digest(data), "items": items}


def descendants(index, identity):
    items = {row["id"]: row for row in index["items"]}
    if identity not in items:
        raise Blocked("review-selection", "Unknown plan item: " + identity)
    pending, leaves = [identity], []
    while pending:
        key = pending.pop()
        if items[key]["children"]:
            pending.extend(reversed(items[key]["children"]))
        else:
            leaves.append(key)
    return leaves


def select(index, expressions=(), sections=()):
    rows = index["items"]
    ids = [row["id"] for row in rows]
    requested, explicit = set(), set()
    for expression in expressions:
        for token in expression.split(","):
            token = token.strip()
            if not token:
                raise Blocked("review-selection", "Empty stage selector.")
            ends = token.split("..")
            if len(ends) > 2 or any(end not in ids for end in ends):
                raise Blocked("review-selection", "Unknown or invalid stage selector: " + token)
            if len(ends) == 1:
                requested.update(descendants(index, token))
                if not rows[ids.index(token)]["children"]:
                    explicit.add(token)
            else:
                left, right = map(ids.index, ends)
                if left > right:
                    raise Blocked("review-selection", "Range endpoints are reversed in the plan: " + token)
                # Do not expand an interior parent beyond the right endpoint.
                right = max(ids.index(leaf) for leaf in descendants(index, ends[1]))
                requested.update(row["id"] for row in rows[left:right + 1] if not row["children"])
    for section in sections:
        requested.update(descendants(index, section))
    unfinished = [row for row in rows if row["id"] in requested and not row["completed"]]
    invalid = [row["id"] for row in unfinished if row["id"] in explicit]
    if invalid:
        raise Blocked("review-selection", "These explicit items are not complete: " + ", ".join(invalid))
    selected = [row["id"] for row in rows if row["id"] in requested and row["completed"] and not row["children"]]
    return selected, [{"id": row["id"], "status": row["status"]} for row in unfinished]


def scope_title(text):
    """The first line of a scope without a Markdown heading marker."""
    line = text.splitlines()[0]
    return (line.lstrip("#").strip() or line)[:160]


def make_request(index=None, selected=(), scope="", integration=False, excluded=(), scopes=()):
    """A sealed review request. SCOPES with more than one text gives one target for each text, in this order."""
    if scopes and scope:
        raise Blocked("review-selection", "Give the scope text or the scope files, not both.")
    if len(scopes) > 1:
        if index or selected or integration:
            raise Blocked("review-selection", "Several scopes are separate targets. They cannot have plan items "
                          "or --integration.")
        texts = [text.strip() for text in scopes]
        if any(not text or "\0" in text or len(text.encode()) > 65536 for text in texts):
            raise Blocked("review-scope", "Each scope must be non-empty text of at most 64 KiB.")
        request = {"version": 1, "plan": None, "integration": False, "excluded": list(excluded),
                   "targets": [{"id": f"scope-{number}", "title": scope_title(text), "items": [], "scope": text}
                               for number, text in enumerate(texts, 1)]}
        if len(encode(request)) > 4 * 1024 * 1024:
            raise Blocked("review-scope", "The combined selection exceeds 4 MiB. Use fewer or shorter scopes.")
        return request
    scope = (scopes[0] if scopes else scope).strip()
    if "\0" in scope or len(scope.encode()) > 65536:
        raise Blocked("review-scope", "Scope text exceeds 64 KiB.")
    chosen = [row for row in (index or {}).get("items", []) if row["id"] in selected]
    if len(chosen) != len(set(selected)) or any(not r["completed"] or r["children"] for r in chosen):
        raise Blocked("review-selection", "Select completed leaf items from the indexed plan.")
    if not chosen and not scope:
        raise Blocked("review-selection", "Select at least one completed item or supply a scope.")
    def target(rows):
        return {"id": rows[0]["id"] if len(rows) == 1 else "integration" if rows else "scope",
                "title": rows[0]["title"] if len(rows) == 1 else "Integration: " + ", ".join(r["id"] for r in rows) if rows else scope_title(scope),
                "items": [{k: r[k] for k in ("id", "title", "line", "text")} for r in rows], "scope": scope}
    targets = [target(chosen)] if integration or not chosen else [target([r]) for r in chosen]
    request = {"version": 1, "plan": {k: index[k] for k in ("path", "sha256")} if index else None,
            "integration": bool(integration or not chosen), "targets": targets, "excluded": list(excluded)}
    if len(encode(request)) > 4 * 1024 * 1024:
        raise Blocked("review-scope", "The combined selection exceeds 4 MiB. Select fewer items or use a shorter scope.")
    return request


def load_request(path):
    with Path(path).open("rb") as stream:
        data = stream.read(4 * 1024 * 1024 + 1)
    if len(data) > 4 * 1024 * 1024:
        raise Blocked("review-scope", "Saved selection exceeds 4 MiB.")
    value = json.loads(data)
    if (not isinstance(value, dict) or set(value) != {"version", "plan", "integration", "targets", "excluded"}
            or type(value.get("version")) is not int or value["version"] != 1
            or type(value.get("integration")) is not bool or not isinstance(value.get("excluded"), list)
            or not isinstance(value.get("targets"), list) or not value["targets"]):
        raise Blocked("review-scope", "Invalid saved review selection.")
    for target in value["targets"]:
        if (not isinstance(target, dict) or set(target) != {"id", "title", "scope", "items"}
                or any(not isinstance(target.get(k), str) or "\0" in target[k] for k in ("id", "title", "scope"))
                or not target["id"].strip() or not target["title"].strip() or len(target["scope"].encode()) > 65536):
            raise Blocked("review-scope", "Invalid saved review target.")
        if not isinstance(target.get("items"), list) or any(not isinstance(i, dict) or set(i) != {"id", "title", "text", "line"}
                or not all(isinstance(i.get(k), str) and i[k].strip() for k in ("id", "title", "text"))
                or type(i["line"]) is not int or i["line"] < 1 for i in target["items"]):
            raise Blocked("review-scope", "Invalid saved plan items.")
        if not target["items"] and not target["scope"].strip():
            raise Blocked("review-scope", "A review target must contain items or a scope.")
    plan = value["plan"]
    if plan is not None and (not isinstance(plan, dict) or set(plan) != {"path", "sha256"}
            or not isinstance(plan["path"], str) or not isinstance(plan["sha256"], str)
            or not re.fullmatch(r"[0-9a-f]{64}", plan["sha256"])):
        raise Blocked("review-scope", "Invalid saved plan reference.")
    all_ids = [item["id"] for t in value["targets"] for item in t["items"]]
    if len(all_ids) != len(set(all_ids)) or (value["integration"] and len(value["targets"]) != 1) or all_ids and not plan:
        raise Blocked("review-scope", "Saved targets contain duplicate items or inconsistent integration scope.")
    return value


def verify_plan(root, request):
    plan = request.get("plan")
    if plan:
        name, data = source_file(root, plan["path"])
        if name != plan["path"] or digest(data) != plan["sha256"]:
            raise Blocked("review-plan-changed", "The plan changed after selection. Select the items again before starting a new review.")
        indexed = {r["id"]: r for r in plan_index(root, plan["path"])["items"]}
        for target in request["targets"]:
            for item in target["items"]:
                row = indexed.get(item["id"])
                if not row or not row["completed"] or row["children"] or any(item[k] != row[k] for k in item):
                    raise Blocked("review-selection", "Saved requirements do not match a completed item in the plan.")


def save_request(path, request):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as output:
        output.write(encode(request) + b"\n")
