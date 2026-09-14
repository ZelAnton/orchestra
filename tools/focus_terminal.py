"""A single-owner terminal composer with bounded scrollback; standard library only."""

import codecs
from collections import OrderedDict, deque
import os
import select
import shutil
import sys
import threading
import time
import unicodedata

from focus_output import terminal_text
from focus_status import StatusPanel


def cell_width(char):
    if unicodedata.combining(char):
        return 0
    return 2 if unicodedata.east_asian_width(char) in ("W", "F") else 1


def clip(text, width):
    result, used = [], 0
    for char in text:
        size = cell_width(char)
        if used + size > width:
            break
        result.append(char)
        used += size
    return "".join(result)


class Terminal:
    interactive = True

    def __init__(self, stdin=None, stdout=None):
        self.stdin, self.stdout = stdin or sys.stdin, stdout or sys.stdout
        self.lock = threading.RLock()
        self.lines = deque(maxlen=3000)
        self.tail = ""
        self.text, self.cursor = "", 0
        self.history, self.history_index = [], 0
        self.scroll = 0
        self.label = "cc-focus · starting · /help"
        self.panel = None
        self.status_tick = None
        self.callback = None
        self.stopping = threading.Event()
        self.changed = True
        self.escape, self.paste = "", False
        self.saved_modes = None
        self.encoding = "utf-8"
        self.output_revision = 0
        self.wrap_width = None
        self.wrapped_lines = OrderedDict()
        self.view_key, self.visible = None, []
        self.frame_size, self.frame_rows, self.frame_cursor = None, [], None
        self.frame_tone = None

    def available(self):
        return (self.stdin.isatty() and self.stdout.isatty()
                and (os.name == "nt" or os.environ.get("TERM", "") not in ("", "dumb")))

    def isatty(self):
        return True

    def flush(self):
        pass

    def write(self, text):
        # Sanitization can scan a large provider chunk; do it without holding the
        # composer's lock so the input thread can still process keystrokes.
        clean = terminal_text(text).replace("\r", "").replace("\t", "    ")
        if not clean:
            return len(text)
        with self.lock:
            value = self.tail + clean
            parts = value.split("\n")
            for part in parts[:-1]:
                # Bound both line count and individual physical line storage.
                for start in range(0, max(1, len(part)), 4000):
                    self.lines.append(part[start:start + 4000])
            self.tail = parts[-1]
            while len(self.tail) > 4000:
                self.lines.append(self.tail[:4000])
                self.tail = self.tail[4000:]
            self.output_revision += 1
            self.changed = True
        return len(text)

    def status(self, text):
        panel = None
        if isinstance(text, StatusPanel):
            sanitize = lambda lines: tuple(" ".join(terminal_text(str(line)[:4000]).split()) for line in lines)
            panel = StatusPanel(sanitize(text.lines[:6]), sanitize(text.compact[:3]), text.tone)
            label = panel.lines[0] if panel.lines else "cc-focus"
        else:
            label = terminal_text(text).replace("\n", " ")
        with self.lock:
            if self.label != label or self.panel != panel:
                self.label, self.panel = label, panel
                self.changed = True

    def __enter__(self):
        if not self.available():
            raise ValueError("Interactive mode requires terminal input/output and a capable TERM; use --ui off.")
        if os.name == "nt":
            import ctypes
            from ctypes import wintypes
            self.kernel = ctypes.WinDLL("kernel32", use_last_error=True)
            self.kernel.GetStdHandle.argtypes = [wintypes.DWORD]
            self.kernel.GetStdHandle.restype = wintypes.HANDLE
            self.kernel.GetConsoleMode.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
            self.kernel.SetConsoleMode.argtypes = [wintypes.HANDLE, wintypes.DWORD]
            self.output_handle = self.kernel.GetStdHandle(-11)
            self.input_handle = self.kernel.GetStdHandle(-10)
            mode = wintypes.DWORD()
            input_mode = wintypes.DWORD()
            if not self.kernel.GetConsoleMode(self.output_handle, ctypes.byref(mode)):
                raise ValueError("Cannot read console mode; use --ui off.")
            if not self.kernel.GetConsoleMode(self.input_handle, ctypes.byref(input_mode)):
                raise ValueError("Cannot read console input mode; use --ui off.")
            if not self.kernel.SetConsoleMode(self.output_handle, mode.value | 4):
                raise ValueError("Virtual terminal output is unavailable; use --ui off.")
            self.saved_modes = (mode.value, input_mode.value)
            if not self.kernel.SetConsoleMode(self.input_handle, input_mode.value & ~7):
                self.kernel.SetConsoleMode(self.output_handle, mode.value)
                raise ValueError("Cannot enable console key input; use --ui off.")
        else:
            import termios
            import tty
            self.saved_modes = termios.tcgetattr(self.stdin.fileno())
            tty.setraw(self.stdin.fileno())
        try:
            self.stdout.write("\x1b[?1049h\x1b[?2004h\x1b[2J")
            self.stdout.flush()
            self.thread = threading.Thread(target=self.loop, name="focus-terminal", daemon=True)
            self.thread.start()
        except BaseException:
            self.restore()
            raise
        return self

    def restore(self):
        try:
            self.stdout.write("\x1b[?2004l\x1b[?25h\x1b[?1049l")
            self.stdout.flush()
        finally:
            if self.saved_modes is not None:
                if os.name == "nt":
                    self.kernel.SetConsoleMode(self.output_handle, self.saved_modes[0])
                    self.kernel.SetConsoleMode(self.input_handle, self.saved_modes[1])
                else:
                    import termios
                    termios.tcsetattr(self.stdin.fileno(), termios.TCSANOW, self.saved_modes)

    def __exit__(self, *_):
        self.stopping.set()
        self.thread.join(timeout=2)
        self.restore()

    def wrap_line(self, line, width):
        if self.wrap_width != width:
            self.wrapped_lines.clear()
            self.wrap_width = width
        if line in self.wrapped_lines:
            self.wrapped_lines.move_to_end(line)
            return self.wrapped_lines[line]
        if line.isascii():
            parts = tuple(line[start:start + width] for start in range(0, len(line), width)) or ("",)
        else:
            parts, part, used = [], [], 0
            for char in line:
                size = cell_width(char)
                if used + size > width and part:
                    parts.append("".join(part))
                    part, used = [], 0
                part.append(char)
                used += size
            parts.append("".join(part))
            parts = tuple(parts)
        self.wrapped_lines[line] = parts
        # Bound the cache even as old output is evicted or a streaming tail grows.
        if len(self.wrapped_lines) > self.lines.maxlen + 1:
            self.wrapped_lines.popitem(last=False)
        return parts

    def log_rows(self, width, height):
        key = (width, height, self.scroll, self.output_revision)
        if self.view_key != key:
            wrapped = []
            for line in reversed(list(self.lines) + ([self.tail] if self.tail else [])):
                wrapped.extend(reversed(self.wrap_line(line, width)))
                if len(wrapped) >= height + self.scroll:
                    break
            self.scroll = min(self.scroll, max(0, len(wrapped) - height))
            self.visible = list(reversed(wrapped[self.scroll:self.scroll + height]))
            self.visible = [""] * (height - len(self.visible)) + self.visible
            self.view_key = (width, height, self.scroll, self.output_revision)
        return self.visible

    def render(self, columns, rows):
        with self.lock:
            width, height = max(1, columns - 1), max(1, rows - 3)
            if rows < 4 or columns < 8:
                self.frame_size = None
                self.changed = False
                return "\x1b[2J\x1b[H\x1b[K" + clip("Resize terminal", width)
            header = [clip(self.label, width)]
            if self.panel:
                chosen = self.panel.lines if rows >= 14 and columns >= 70 else self.panel.compact
                count = min(len(chosen), max(1, rows - 5))
                header = [clip(line, width) if sum(cell_width(c) for c in line) <= width
                          else clip(line, max(0, width - 1)) + "…" for line in chosen[:count]]
                if rows >= 6:
                    header.append("─" * width)
                height = rows - len(header) - 2
            visible = self.log_rows(width, height)
            # The viewport clamps an oversized PageUp offset. Use that final
            # offset so the next keystroke cannot change the header as well.
            if self.scroll:
                if self.panel:
                    row = -2 if rows >= 6 else -1
                    header[row] = clip(f"scrollback +{self.scroll} · " + header[row], width)
                else:
                    header[0] = clip(self.label + f" · scrollback +{self.scroll}", width)
            # Walk only the visible suffix; long pasted input must not cause a
            # quadratic redraw or prevent an emergency command from being read.
            suffix, used = [], 0
            for index in range(self.cursor - 1, -1, -1):
                char = self.text[index]
                size = cell_width(char)
                if used + size > max(1, width - 5):
                    break
                suffix.append(char)
                used += size
            left = "".join(reversed(suffix))
            composer = clip("> " + left + self.text[self.cursor:], width)
            content = [*header, *visible, "─" * width, composer]
            cursor = min(width, 3 + sum(cell_width(c) for c in left))
            resized = self.frame_size != (columns, rows)
            tone = self.panel.tone if self.panel else None
            updates = [(index + 1, line) for index, line in enumerate(content)
                       if resized or line != self.frame_rows[index] or (tone != self.frame_tone and index < len(header))]
            frame = ""
            if updates or cursor != self.frame_cursor:
                # Clear changed rows completely, including when text got shorter.
                # Typing only repaints the composer, not the entire log over SSH.
                frame = ("\x1b[2J" if resized else "") + "\x1b[?25l"
                for row, line in updates:
                    color = ""
                    if self.panel and row < len(header):
                        color = {"normal": "\x1b[36m", "good": "\x1b[32m", "warning": "\x1b[33m",
                                 "error": "\x1b[31m"}.get(self.panel.tone, "") if row == 2 else ""
                    frame += f"\x1b[{row};1H{color}{line}" + ("\x1b[0m" if color else "") + "\x1b[K"
                frame += f"\x1b[{rows};{cursor}H\x1b[?25h"
            self.frame_size, self.frame_rows, self.frame_cursor = (columns, rows), content, cursor
            self.frame_tone = tone
            self.changed = False
            return frame

    def key(self, char):
        submit = None
        with self.lock:
            if self.escape or char == "\x1b":
                self.escape += char
                sequences = {"\x1b[A": "up", "\x1b[B": "down", "\x1b[C": "right", "\x1b[D": "left",
                             "\x1b[H": "home", "\x1b[F": "end", "\x1b[3~": "delete",
                             "\x1b[5~": "page-up", "\x1b[6~": "page-down",
                             "\x1b[200~": "paste-start", "\x1b[201~": "paste-end"}
                action = sequences.get(self.escape)
                if action:
                    self.escape = ""
                    if action.startswith("paste-"):
                        self.paste = action == "paste-start"
                    elif not self.paste:
                        self.edit_key(action)
                elif len(self.escape) > 12 or not any(key.startswith(self.escape) for key in sequences):
                    self.escape = ""
                self.changed = True
                return
            if self.paste and char in "\r\n\t":
                char = " "
            if self.paste and ord(char) < 32:
                return
            if char in ("\r", "\n"):
                submit = self.text.strip()
                self.text, self.cursor, self.scroll = "", 0, 0
                if submit:
                    self.history.append(submit)
                    self.history = self.history[-100:]
                self.history_index = len(self.history)
            elif char == "\x03":
                submit = "/stop"
            elif char == "\x04" and not self.text:
                submit = "/exit"
            elif char in ("\x7f", "\b"):
                if self.cursor:
                    self.text = self.text[:self.cursor - 1] + self.text[self.cursor:]
                    self.cursor -= 1
            elif char == "\x15":
                self.text, self.cursor = "", 0
            elif char == "\x01":
                self.cursor = 0
            elif char == "\x05":
                self.cursor = len(self.text)
            elif not unicodedata.category(char).startswith("C") and len(self.text) < 65536:
                self.text = self.text[:self.cursor] + char + self.text[self.cursor:]
                self.cursor += len(char)
            self.changed = True
        if submit and self.callback:
            self.callback(submit)

    def edit_key(self, action):
        if action == "left":
            self.cursor = max(0, self.cursor - 1)
        elif action == "right":
            self.cursor = min(len(self.text), self.cursor + 1)
        elif action in ("home", "end"):
            self.cursor = 0 if action == "home" else len(self.text)
        elif action == "delete":
            self.text = self.text[:self.cursor] + self.text[self.cursor + 1:]
        elif action in ("page-up", "page-down"):
            self.scroll = max(0, self.scroll + (10 if action == "page-up" else -10))
        elif action in ("up", "down"):
            self.history_index = min(len(self.history), max(0, self.history_index + (-1 if action == "up" else 1)))
            self.text = self.history[self.history_index] if self.history_index < len(self.history) else ""
            self.cursor = len(self.text)

    def loop(self):
        decoder = codecs.getincrementaldecoder("utf-8")("replace")
        dimensions, last, last_status = None, 0, 0
        try:
            while not self.stopping.is_set():
                chars = ""
                if os.name == "nt":
                    import msvcrt
                    if msvcrt.kbhit():
                        chars = msvcrt.getwch()
                        if chars in ("\x00", "\xe0"):
                            code = msvcrt.getwch()
                            chars = {"H": "\x1b[A", "P": "\x1b[B", "K": "\x1b[D", "M": "\x1b[C",
                                     "G": "\x1b[H", "O": "\x1b[F", "I": "\x1b[5~", "Q": "\x1b[6~", "S": "\x1b[3~"}.get(code, "")
                    else:
                        self.stopping.wait(0.05)
                elif select.select([self.stdin.fileno()], [], [], 0.05)[0]:
                    data = os.read(self.stdin.fileno(), 4096)
                    if not data:
                        self.callback("/stop")
                        self.callback("/exit")
                        return
                    chars = decoder.decode(data)
                for char in chars:
                    self.key(char)
                if self.status_tick and time.monotonic() - last_status >= 1:
                    self.status_tick()
                    last_status = time.monotonic()
                size = shutil.get_terminal_size((80, 24))
                if (self.changed or dimensions != size) and time.monotonic() - last >= 0.05:
                    self.stdout.write(self.render(size.columns, size.lines))
                    self.stdout.flush()
                    dimensions, last = size, time.monotonic()
        except (OSError, ValueError) as error:
            if self.callback:
                self.callback("/stop")
                self.callback("/exit")
            self.write(f"\nTerminal input failed: {error}\n")
