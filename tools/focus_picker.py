"""Optional keyboard selector. No mouse capture and no provider calls."""

import os
from pathlib import Path
import subprocess
import sys
import venv

from cycle_state import Blocked
from focus_output import terminal_text
from focus_review_scope import make_request, select


def environment():
    return Path.home() / ".orchestra" / "venvs" / "focus-ui"


def install():
    path = environment()
    venv.EnvBuilder(with_pip=True).create(path)
    python = path / ("Scripts/python.exe" if os.name == "nt" else "bin/python")
    try:
        subprocess.run([str(python), "-m", "pip", "install", "--disable-pip-version-check", "-r",
                        str(Path(__file__).with_name("focus-picker-requirements.txt"))], check=True)
    except subprocess.CalledProcessError as error:
        raise Blocked("review-menu-install", "Menu installation failed. Correct the package installation error and retry.") from error
    print("cc-focus: menu dependencies installed in " + str(path))


def load_ui():
    path = environment()
    directory = (path / "Lib/site-packages" if os.name == "nt" else
                 path / "lib" / f"python{sys.version_info.major}.{sys.version_info.minor}" / "site-packages")
    if directory.is_dir():
        # The pinned environment must take precedence over unrelated system packages.
        sys.path.insert(0, str(directory))
    try:
        import prompt_toolkit
        import wcwidth
        if prompt_toolkit.__version__ != "3.0.52" or wcwidth.__version__ != "0.2.13":
            raise ImportError("Unexpected dependency versions")
    except ImportError as error:
        raise Blocked("review-menu", "Install the optional menu with cc-focus review --install-ui, or use --stages without --pick.") from error


class Selection:
    def __init__(self, index, selected=()):
        self.index = index
        self.rows = {r["id"]: r for r in index["items"]}
        self.selected = set(selected)
        self.anchor = None
        self.collapsed = set()
        self.eligible_ids = {}
        for row in reversed(index["items"]):
            self.eligible_ids[row["id"]] = (set().union(*(self.eligible_ids[i] for i in row["children"]))
                if row["children"] else {row["id"]} if row["completed"] else set())

    def visible(self, query=""):
        def hidden(row):
            parent = row["parent"]
            while parent:
                if parent in self.collapsed:
                    return True
                parent = self.rows[parent]["parent"]
            return False
        return [r for r in self.index["items"] if (query.casefold() in r["title"].casefold() if query else not hidden(r))]

    def eligible(self, identity):
        return self.eligible_ids[identity]

    def toggle(self, identity):
        ids = self.eligible(identity)
        if ids and ids <= self.selected:
            self.selected.difference_update(ids)
        else:
            self.selected.update(ids)

    def range(self, identity):
        if self.anchor is None:
            self.anchor = identity
            return
        order = list(self.rows)
        ends = sorted((self.anchor, identity), key=order.index)
        ids, _ = select(self.index, ["..".join(ends)])
        self.selected.update(ids)
        self.anchor = None


def picker_application(index, selected=(), scope="", integration=False, **application_options):
    load_ui()
    from prompt_toolkit import Application
    from prompt_toolkit.filters import Condition
    from prompt_toolkit.key_binding import KeyBindings
    from prompt_toolkit.layout import HSplit, Layout, Window
    from prompt_toolkit.layout.controls import FormattedTextControl
    from prompt_toolkit.layout.dimension import Dimension
    from prompt_toolkit.styles import Style
    from prompt_toolkit.widgets import Label, TextArea, Frame
    from prompt_toolkit.data_structures import Point
    selection = Selection(index, selected)
    position = [0]
    combined = [integration]
    error = [""]
    search = TextArea(height=1, multiline=False, prompt="Search: ")
    scope_input = TextArea(text=scope, height=3, multiline=True)
    def rows():
        visible = selection.visible(search.text)
        position[0] = min(position[0], max(0, len(visible) - 1))
        return visible
    def current():
        visible = rows()
        return visible[position[0]] if visible else None
    def render():
        fragments = []
        for i, row in enumerate(rows()):
            ids = selection.eligible(row["id"])
            mark = "x" if ids and ids <= selection.selected else "~" if ids & selection.selected else " " if ids else "-"
            depth, parent = 0, row["parent"]
            while parent:
                depth += 1
                parent = selection.rows[parent]["parent"]
            group = ("+ " if row["id"] in selection.collapsed else "- ") if row["children"] else "  "
            text = "  " * depth + group + "[" + mark + "] " + row["title"] + "  (" + row["status"] + ")"
            fragments.append(("class:cursor" if i == position[0] else "", terminal_text(text) + "\n"))
        return fragments or [("", "No matching items")]
    control = FormattedTextControl(render, focusable=True, get_cursor_position=lambda: Point(0, position[0]))
    listing = Window(control, height=Dimension(min=3, weight=1), wrap_lines=False)
    bindings = KeyBindings()
    focused = Condition(lambda: app.layout.current_control == control)
    @bindings.add("up", filter=focused)
    def up(event): position[0] = max(0, position[0] - 1)
    @bindings.add("down", filter=focused)
    def down(event): position[0] = min(max(0, len(rows()) - 1), position[0] + 1)
    @bindings.add(" ", filter=focused)
    def toggle(event):
        if current(): selection.toggle(current()["id"])
    @bindings.add("r", filter=focused)
    def span(event):
        if current(): selection.range(current()["id"])
    @bindings.add("left", filter=focused)
    def collapse(event):
        if current(): selection.collapsed.add(current()["id"])
    @bindings.add("right", filter=focused)
    def expand(event):
        if current(): selection.collapsed.discard(current()["id"])
    @bindings.add("i", filter=focused)
    def mode(event): combined[0] = not combined[0]
    @bindings.add("/", filter=focused)
    def find(event): app.layout.focus(search)
    @bindings.add("tab")
    def tab(event): app.layout.focus_next()
    @bindings.add("s-tab")
    def backtab(event): app.layout.focus_previous()
    @bindings.add("escape")
    @bindings.add("c-c")
    def cancel(event): app.exit(result=None)
    @bindings.add("enter", filter=focused)
    @bindings.add("c-s")
    def accept(event):
        ordered = [r["id"] for r in index["items"] if r["id"] in selection.selected]
        try:
            make_request(index, ordered, scope_input.text, combined[0])
        except Blocked as problem:
            error[0] = str(problem)
            return
        app.exit(result=(ordered, scope_input.text, combined[0]))
    content = HSplit([Label("Select completed plan items — " + terminal_text(index["path"])), search,
        listing, Window(FormattedTextControl(lambda: terminal_text((current() or {}).get("text", ""))[:3000]), height=4, wrap_lines=True),
        Frame(scope_input, "Additional scope (optional)"),
        Label(lambda: f"Selected: {len(selection.selected)} · {'Integration' if combined[0] else 'Separate targets'} · Range: {selection.anchor or 'none'}"),
        Label("Space: mark · arrows: move/tree · r: range endpoints · /: search · i: mode · Tab: fields"),
        Label("Enter / Ctrl-S: accept · Esc: cancel · --save-selection FILE saves the selection"), Label(lambda: error[0])])
    app = Application(layout=Layout(content, focused_element=control), key_bindings=bindings,
                      style=Style.from_dict({"cursor": "reverse"}), full_screen=True, mouse_support=False,
                      **application_options)
    return app


def pick(index, selected=(), scope="", integration=False):
    if not sys.stdin.isatty() or not sys.stdout.isatty():
        raise Blocked("review-menu", "The selection menu needs an interactive terminal. Use --stages or --scope-file instead.")
    return picker_application(index, selected, scope, integration).run()
