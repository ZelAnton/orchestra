"""Bounded inspection tools for final Codex reviewers; no command input or writes."""

import os
from pathlib import Path
import stat
import subprocess


READONLY_FEATURES = ("shell_tool", "unified_exec", "multi_agent", "multi_agent_v2", "memories",
                     "code_mode", "code_mode_only", "apps", "plugins", "hooks",
                     "browser_use", "computer_use", "image_generation", "view_image", "artifact", "goals")

# Some models route even dynamic read-only tools through Code Mode. Its host is
# the isolated tool-dispatch runtime, not permission to execute project commands.
# Pin it at process AND thread scope while keeping every execution tool disabled.
READONLY_FEATURE_OVERRIDES = {**{key: False for key in READONLY_FEATURES}, "code_mode_host": True}

READ_TOOL = {"type": "function", "name": "focus_inspect",
             "description": 'Read project files, list snapshot paths, or inspect a stage diff. Do not execute commands, write, build, or test. Offsets count lines or paths from zero. If a new file has an empty diff, read that file directly.',
             "inputSchema": {"type": "object", "additionalProperties": False,
                             "properties": {"operation": {"type": "string", "enum": ["read", "list", "diff"]},
                                            "path": {"type": "string"}, "offset": {"type": "integer", "minimum": 0},
                                            "limit": {"type": "integer", "minimum": 1, "maximum": 500}},
                             "required": ["operation", "path", "offset", "limit"]}}


class Inspector:
    def __init__(self, root, state):
        self.root, self.state = Path(root).resolve(), state

    def call(self, params):
        try:
            if params.get("tool") != "focus_inspect" or params.get("namespace"):
                raise ValueError("Only focus_inspect is available.")
            args = params["arguments"]
            if not isinstance(args, dict) or set(args) != {"operation", "path", "offset", "limit"}:
                raise ValueError("Invalid inspection arguments.")
            op, name, offset, limit = (args[k] for k in ("operation", "path", "offset", "limit"))
            if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 500:
                raise ValueError("Invalid inspection range.")
            if not isinstance(name, str) or "\0" in name or "\\" in name or ":" in name:
                raise ValueError("Use a project-relative path.")
            path = self.root / name
            if path.is_absolute() and not path.resolve().is_relative_to(self.root):
                raise ValueError("Inspection must stay inside this project.")
            relative = path.relative_to(self.root)
            if any(part in ("..", ".git", ".jj") for part in relative.parts):
                raise ValueError("VCS internals and parent traversal are not inspection inputs.")
            if op == "list":
                files = (self.state.get("final_review") or {}).get("snapshot", self.state["last_snapshot"])["files"]
                prefix = "" if relative == Path(".") else relative.as_posix()
                lines = sorted(p for p in files if p.startswith(prefix))
            elif op == "read":
                mode = path.stat().st_mode
                if not stat.S_ISREG(mode):
                    raise ValueError("Read requires a regular text file.")
                # Large stage diffs must remain pageable without loading the
                # whole file (or rejecting it solely because of its size).
                page, more = [], False
                with path.open("rb") as stream:
                    for number in range(offset + limit + 1):
                        line = stream.readline(1048577)
                        if not line:
                            break
                        if b"\0" in line or len(line) > 1048576:
                            raise ValueError("Binary/oversized line: inspect the relevant source or file diff instead.")
                        if number == offset + limit:
                            more = True
                        elif number >= offset:
                            page.append(f"{number + 1}: " + line.decode("utf-8", errors="replace").rstrip("\r\n"))
                content = f"Offset: {offset}; lines: {len(page)}; more: {more}\n" + "\n".join(page)
                if len(content) > 100000:
                    content = content[:100000] + "\n[Output clipped; repeat with a smaller line limit.]"
                return {"success": True, "contentItems": [{"type": "inputText", "text": content}]}
            elif op == "diff":
                baseline = self.state["baseline"]["head"]
                cwd, file = self.root, name
                if isinstance(baseline, dict):
                    member = next((m for m in baseline if name.startswith(m + "/")), None)
                    if member is None:
                        raise ValueError("Shared context is not a member repository diff.")
                    cwd, file, baseline = self.root / member, name[len(member) + 1:], baseline[member]
                result = subprocess.run(["git", "--no-optional-locks", "--literal-pathspecs", "-C", str(cwd),
                                         "diff", "--no-ext-diff", "--no-textconv", "--no-renames", baseline, "--", file],
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15,
                                        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"})
                if result.returncode:
                    raise ValueError("The stage diff could not be read.")
                lines = result.stdout.decode("utf-8", errors="replace").splitlines()
            else:
                raise ValueError("Unknown inspection operation.")
            content = "\n".join(f"{i + 1}: {line}" for i, line in enumerate(lines[offset:offset + limit], offset))
            if len(content) > 100000:
                content = content[:100000] + "\n[Output clipped; repeat with a smaller line limit.]"
            content = f"Total lines/paths: {len(lines)}; offset: {offset}\n" + content
            success = True
        except (OSError, ValueError, KeyError, TypeError, subprocess.TimeoutExpired) as error:
            content, success = str(error), False
        return {"success": success, "contentItems": [{"type": "inputText", "text": content}]}
